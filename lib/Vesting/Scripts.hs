{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
-- 1.1.0.0 will be enabled in conway
{-# OPTIONS_GHC -fobject-code -fno-ignore-interface-pragmas -fno-omit-interface-pragmas -fplugin-opt PlutusTx.Plugin:target-version=1.1.0.0 #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:defer-errors #-}

-- | Scripts used for testing, plus minimal off-chain transaction-building helpers.
module Vesting.Scripts (
  -- * Compiled script
  vestingValidatorScript,
  Vesting.VestingParams (..),
  saveVestingValidatorScript,

  -- * Off-chain helpers
  lockVesting,
  withdrawVesting,
) where

import Cardano.Api (NetworkId)
import Cardano.Api qualified as C
import Convex.BuildTx (MonadBuildTx)
import Convex.BuildTx qualified as BuildTx
import Convex.PlutusTx (compiledCodeToScript)
import PlutusTx (BuiltinData, CompiledCode)
import PlutusTx qualified
import PlutusTx.Prelude (BuiltinUnit)
import Vesting.Validator qualified as Vesting

-- | Compiling a parameterized validator for 'Scripts.Vesting.validator'
vestingValidatorCompiled :: Vesting.VestingParams -> CompiledCode (BuiltinData -> BuiltinUnit)
vestingValidatorCompiled params =
  case $$(PlutusTx.compile [||Vesting.validator||])
    `PlutusTx.applyCode` PlutusTx.liftCodeDef params of
    Left err -> error err
    Right cc -> cc

-- | Serialized validator for 'Scripts.Vesting.validator'
vestingValidatorScript :: Vesting.VestingParams -> C.PlutusScript C.PlutusScriptV3
vestingValidatorScript = compiledCodeToScript . vestingValidatorCompiled

-- | Save the validator script to a file
saveVestingValidatorScript :: Vesting.VestingParams -> FilePath -> IO ()
saveVestingValidatorScript params filePath = do
  let script = vestingValidatorScript params
  C.writeFileTextEnvelope (C.File filePath) Nothing script >>= \case
    Left err -> print $ C.displayError err
    Right () -> putStrLn $ "Serialized script to: " ++ filePath

-------------------------------------------------------------------------------
-- Off-chain transaction-building helpers
--
-- The upstream Vesting tests (Spec/Unit.hs and Spec/Prop.hs in
-- sc-tools-experiments) inline the lock / withdraw transaction bodies
-- verbatim into every test case. These helpers extract just the
-- script-touching fragments (mirroring the PingPong / Escrow / Auction
-- off-chain style): each is a single 'MonadBuildTx' action that the caller
-- composes with validity ranges, change outputs, and balancing.
--
-- Note: the validator datum and redeemer are both unit (), as in the upstream
-- tests; the script enforces the vesting schedule purely via the parameter
-- 'VestingParams' baked into the script's address.
-------------------------------------------------------------------------------

{- | Lock vesting value at the script address with the unit inline datum.

The caller is responsible for calling 'BuildTx.setMinAdaDepositAll' (or
otherwise ensuring the output meets min-Ada) after composing the transaction.
-}
lockVesting
  :: forall era m
   . (C.IsBabbageBasedEra era)
  => (MonadBuildTx era m)
  => NetworkId
  -> Vesting.VestingParams
  -- ^ Compile-time parameters baked into the script address
  -> C.Value
  -- ^ Value to lock (typically tranche1.vAmount + tranche2.vAmount)
  -> m ()
lockVesting networkId params value = do
  let scriptHash = C.hashScript (C.PlutusScript C.plutusScriptVersion (vestingValidatorScript params))
  BuildTx.payToScriptInlineDatum
    networkId
    scriptHash
    ()
    C.NoStakeAddress
    value

{- | Spend a vesting script UTxO with the unit redeemer and add the owner's
key hash as a required signature.

The caller is responsible for:

* setting a validity range that satisfies the tranche containment check
  (via 'BuildTx.addValidityRangeSlots'),
* paying the withdrawn amount to the owner,
* re-locking any value that is still under vesting back at the script
  address (e.g. via a second 'lockVesting' call), and
* balancing / submitting the transaction.
-}
withdrawVesting
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , C.HasScriptLanguageInEra C.PlutusScriptV3 era
     )
  => (MonadBuildTx era m)
  => Vesting.VestingParams
  -> C.TxIn
  -- ^ The vesting script UTxO to spend
  -> C.Hash C.PaymentKey
  -- ^ Owner key hash (must match 'vpOwner' in the params)
  -> m ()
withdrawVesting params txIn ownerKeyHash = do
  BuildTx.addRequiredSignature ownerKeyHash
  BuildTx.spendPlutusInlineDatum txIn (vestingValidatorScript params) ()
