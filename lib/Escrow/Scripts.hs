{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
-- 1.1.0.0 will be enabled in conway
{-# OPTIONS_GHC -fobject-code -fno-ignore-interface-pragmas -fno-omit-interface-pragmas -fplugin-opt PlutusTx.Plugin:target-version=1.1.0.0 #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:defer-errors #-}

-- | Scripts used for testing, plus minimal off-chain transaction-building helpers.
module Escrow.Scripts (
  -- * Compiled script
  escrowValidatorScript,
  Escrow.EscrowParams (..),
  saveEscrowValidatorScript,

  -- * Off-chain helpers
  lockEscrow,
  redeemEscrow,
  refundEscrow,
) where

import Cardano.Api (NetworkId)
import Cardano.Api qualified as C
import Convex.BuildTx (MonadBuildTx)
import Convex.BuildTx qualified as BuildTx
import Convex.PlutusTx (compiledCodeToScript)
import Escrow.Validator (Action (..))
import Escrow.Validator qualified as Escrow
import PlutusLedgerApi.V1 (PubKeyHash)
import PlutusTx (BuiltinData, CompiledCode)
import PlutusTx qualified
import PlutusTx.Prelude (BuiltinUnit)

-- | Compiling a parameterized validator for 'Scripts.Escrow.validator'
escrowValidatorCompiled :: Escrow.EscrowParams -> CompiledCode (BuiltinData -> BuiltinUnit)
escrowValidatorCompiled params =
  case $$(PlutusTx.compile [||Escrow.validator||])
    `PlutusTx.applyCode` PlutusTx.liftCodeDef params of
    Left err -> error err
    Right cc -> cc

-- | Serialized validator for 'Scripts.Escrow.validator'
escrowValidatorScript :: Escrow.EscrowParams -> C.PlutusScript C.PlutusScriptV3
escrowValidatorScript = compiledCodeToScript . escrowValidatorCompiled

-- | Save the validator script to a file
saveEscrowValidatorScript :: Escrow.EscrowParams -> FilePath -> IO ()
saveEscrowValidatorScript params filePath = do
  let script = escrowValidatorScript params
  C.writeFileTextEnvelope (C.File filePath) Nothing script >>= \case
    Left err -> print $ C.displayError err
    Right () -> putStrLn $ "Serialized script to: " ++ filePath

-------------------------------------------------------------------------------
-- Off-chain transaction-building helpers
--
-- These mirror the lock / redeem / refund flow exercised across the
-- upstream Escrow unit tests. Each helper composes a single fragment of a
-- 'TxBodyContent BuildTx' via the 'MonadBuildTx' writer; outputs to targets
-- (for Redeem) and any change handling are intentionally left to the caller,
-- because targets are scenario-specific.
-------------------------------------------------------------------------------

{- | Lock funds at the escrow script with the contributor's PKH as the inline
datum. The validator expects exactly this shape.
-}
lockEscrow
  :: forall era m
   . (C.IsBabbageBasedEra era)
  => (MonadBuildTx era m)
  => NetworkId
  -> Escrow.EscrowParams
  -- ^ Compile-time parameters baked into the script address
  -> PubKeyHash
  -- ^ Contributor PKH — stored as inline datum on the script UTxO
  -> C.Value
  -- ^ Value to lock
  -> m ()
lockEscrow networkId params contributorPkh value = do
  let scriptHash = C.hashScript (C.PlutusScript C.plutusScriptVersion (escrowValidatorScript params))
  BuildTx.payToScriptInlineDatum
    networkId
    scriptHash
    contributorPkh
    C.NoStakeAddress
    value

{- | Spend an escrow UTxO with the 'Redeem' redeemer. The caller is responsible
for adding the per-target outputs (PaymentPubKeyTarget / ScriptTarget) and a
validity range ending before the deadline.
-}
redeemEscrow
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , C.HasScriptLanguageInEra C.PlutusScriptV3 era
     )
  => (MonadBuildTx era m)
  => Escrow.EscrowParams
  -> C.TxIn
  -- ^ The escrow UTxO to spend
  -> m ()
redeemEscrow params txIn =
  BuildTx.spendPlutusInlineDatum txIn (escrowValidatorScript params) Redeem

{- | Spend an escrow UTxO with the 'Refund' redeemer and add the contributor's
key hash as a required signature. The caller is responsible for setting a
validity range that starts strictly after the deadline.
-}
refundEscrow
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , C.HasScriptLanguageInEra C.PlutusScriptV3 era
     )
  => (MonadBuildTx era m)
  => Escrow.EscrowParams
  -> C.TxIn
  -- ^ The escrow UTxO to spend
  -> C.Hash C.PaymentKey
  -- ^ Contributor key hash (must match the inline datum)
  -> m ()
refundEscrow params txIn contributorKeyHash = do
  BuildTx.addRequiredSignature contributorKeyHash
  BuildTx.spendPlutusInlineDatum txIn (escrowValidatorScript params) Refund
