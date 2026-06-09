{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module EscrowSpec (tests) where

import Cardano.Api qualified as C
import Control.Monad (void)
import Convex.BuildTx (MonadBuildTx, execBuildTx)
import Convex.BuildTx qualified as BuildTx
import Convex.Class (setPOSIXTime)
import Convex.CoinSelection (ChangeOutputPosition (..))
import Convex.MockChain.CoinSelection qualified as CoinSelection
import Convex.MockChain.Defaults qualified as Defaults
import Convex.PlutusLedger.V1 (transPubKeyHash)
import Convex.TestingInterface (
  Action,
  TestingInterface (..),
  ThreatModelsFor (..),
  frequency,
  propRunActions,
 )
import Convex.ThreatModel.DoubleSatisfaction (doubleSatisfaction)
import Convex.ThreatModel.LargeData (largeDataAttackWith)
import Convex.ThreatModel.SignatoryRemoval (signatoryRemoval)
import Convex.ThreatModel.TimeBoundManipulation (timeBoundManipulation)
import Convex.ThreatModel.ValueUnderpayment (valueUnderpaymentAttack)
import Convex.Wallet (Wallet, verificationKeyHash)
import Convex.Wallet.MockWallet qualified as Wallet
import Data.Aeson (ToJSON (..))
import Data.Word (Word64)
import Escrow.Scripts qualified as Scripts
import Escrow.Validator qualified as Escrow
import GHC.Generics (Generic)
import PlutusLedgerApi.V1 (POSIXTime (..), PubKeyHash (..))
import PlutusLedgerApi.V1.Value qualified as PV
import PlutusTx.Builtins qualified as PlutusTx
import Test.Tasty (TestTree)

--------------------------------------------------------------------------------
-- Orphan instances
--------------------------------------------------------------------------------

deriving instance Eq Escrow.EscrowTarget
deriving instance Show Escrow.EscrowParams
deriving instance Show Escrow.EscrowTarget

instance ToJSON POSIXTime where
  toJSON = toJSON . show

instance ToJSON Escrow.EscrowTarget where
  toJSON = toJSON . show

instance ToJSON PubKeyHash where
  toJSON = toJSON . show

instance ToJSON Escrow.EscrowParams where
  toJSON = toJSON . show

--------------------------------------------------------------------------------
-- Fixed parameters and pre-compiled script (CAFs)
--------------------------------------------------------------------------------

{- | PubKeyHash of Wallet.w2, used as the Redeem target so the target is
distinct from the contributor.
-}
w2PubKeyHash :: PubKeyHash
w2PubKeyHash = transPubKeyHash (verificationKeyHash Wallet.w2)

{- | Fixed escrow parameters used across all test iterations.
The testing value comes from action sequences (Start -> Redeem,
Start -> WaitUntilDeadline -> Refund, invalid orderings), not from
varying the escrow parameters. Fixing them lets the compiled script
be evaluated once and shared as a CAF.
-}
fixedDeadlineSlot :: Word64
fixedDeadlineSlot = 500

fixedParams :: Escrow.EscrowParams
fixedParams =
  Escrow.EscrowParams
    { Escrow.epDeadline = slotToPosixMs (C.SlotNo fixedDeadlineSlot)
    , Escrow.epTargets =
        [ Escrow.PaymentPubKeyTarget
            w2PubKeyHash
            (PV.lovelaceValue 2_000_000)
        ]
    }

{- | Pre-compiled validator script — evaluated once as a GHC CAF.
Avoids repeated PlutusTx.liftCodeDef + applyCode on every action.
-}
fixedScript :: C.PlutusScript C.PlutusScriptV3
fixedScript = Scripts.escrowValidatorScript fixedParams

--------------------------------------------------------------------------------
-- Model state
--------------------------------------------------------------------------------

{- | Tracks the Escrow contract lifecycle. At least one field changes on each
action. Targets and deadline are always populated from fixedParams, so no
modelTargets field is needed.
-}
data EscrowModel = EscrowModel
  { modelInitialized :: !Bool
  -- ^ Has the escrow UTxO been created on-chain?
  , modelContributor :: !PubKeyHash
  -- ^ Contributor PKH (stored as inline datum on the script UTxO)
  , modelDeadlinePassed :: !Bool
  -- ^ Has the mockchain time advanced past the deadline?
  , modelScriptUtxo :: !(Maybe C.TxIn)
  -- ^ Reference to the on-chain script UTxO, if one exists
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

--------------------------------------------------------------------------------
-- Action GADT
--------------------------------------------------------------------------------

instance TestingInterface EscrowModel where
  data Action EscrowModel
    = Start !Wallet
    | -- \^ Deploy: lock funds at the escrow script using fixedParams.
      -- The wallet argument determines who the contributor is (and thus
      -- who can Refund). EscrowParams are fixed — testing value comes
      -- from varying action sequences, not parameters.
      Redeem
    | -- \^ Spend the escrow UTxO with the Redeem redeemer, honouring targets
      Refund
    | -- \^ Spend the escrow UTxO with the Refund redeemer, returning funds to contributor
      WaitUntilDeadline
    -- \^ Advance the mockchain clock past the deadline
    deriving (Show)

  ----------------------------------------------------------------------------
  -- initialize
  ----------------------------------------------------------------------------

  -- \| Sets up the in-memory model only. Returns the zero state with
  -- modelInitialized = False. DOES NOT submit any tx, DOES NOT deploy,
  -- DOES NOT touch the chain. Deployment is an Action (Start) emitted by
  -- the generator when the model is uninitialised.
  initialize =
    pure
      EscrowModel
        { modelInitialized = False
        , modelContributor = PubKeyHash ""
        , modelDeadlinePassed = False
        , modelScriptUtxo = Nothing
        }

  ----------------------------------------------------------------------------
  -- arbitraryAction
  ----------------------------------------------------------------------------

  -- \| Proposes the next Action. Branches on STRUCTURAL feasibility only:
  -- "can I build this Action from what the model knows right now?"
  -- Never on SEMANTIC validity ("is this Action allowed by the contract?")
  -- — that goes in precondition. Keeping the semantic gate out of the
  -- generator is what feeds the negative-testing channel.
  arbitraryAction s
    -- Not yet deployed and deadline hasn't passed: deploy with w1.
    -- (After deadline has passed, we can't re-deploy because Redeem would
    -- be permanently impossible — mockchain time doesn't rewind.)
    | not (modelInitialized s) && not (modelDeadlinePassed s) =
        pure (Start Wallet.w1)
    -- When initialized but deadline not passed: emit Redeem (weight 2) and
    -- WaitUntilDeadline (weight 1). No Refund structurally constructible
    -- because the mockchain hasn't advanced past the deadline yet (the
    -- deadline-passed flag is what triggers validity in precondition).
    | modelInitialized s && not (modelDeadlinePassed s) =
        frequency [(2, pure Redeem), (1, pure WaitUntilDeadline)]
    -- When deadline passed and initialized: emit Refund (weight 3) and
    -- Redeem (weight 1). Redeem at weight 1 feeds the negative channel —
    -- the contract should reject Redeem after the deadline.
    | modelInitialized s && modelDeadlinePassed s =
        frequency [(3, pure Refund), (1, pure Redeem)]
    -- Fallback: deadline passed and not initialized (after a successful
    -- Refund/Redeem post-deadline). Emit Refund and Redeem — both have
    -- precondition False here (!modelInitialized), feeding the negative
    -- channel with invalid actions on a non-existent escrow.
    | otherwise =
        frequency [(2, pure Refund), (2, pure Redeem)]

  ----------------------------------------------------------------------------
  -- precondition
  ----------------------------------------------------------------------------

  -- \| Encodes the Escrow contract's semantic rules: for each Action, returns
  -- True iff the validator SHOULD accept it given current state. The framework
  -- runs the same action against both the chain (perform) and this model;
  -- the two verdicts must agree. Disagreement = bug somewhere.
  precondition s = \case
    Start _ -> not (modelDeadlinePassed s)
    -- Start valid only when the mockchain clock hasn't passed the fixed
    -- deadline; since the deadline is a compile-time constant,
    -- re-deploying after time has advanced past it would leave Redeem
    -- permanently impossible (mockchain time doesn't rewind).
    Redeem -> modelInitialized s && not (modelDeadlinePassed s)
    -- Redeem valid before deadline, with a script UTxO present.
    Refund -> modelInitialized s && modelDeadlinePassed s
    -- Refund valid after deadline, with a script UTxO present.
    WaitUntilDeadline -> True
    -- Advancing the clock is always valid — no contract interaction required.
    -- Catch-all for future action extensions.
    _ -> True

  ----------------------------------------------------------------------------
  -- perform
  ----------------------------------------------------------------------------

  -- \| Builds and submits the on-chain tx for this Action, then returns the
  -- updated model state. The model transition must mirror what the
  -- contract does on-chain. If the action is invalid (precondition False),
  -- perform still submits it — the framework expects rejection.
  perform s = \case
    Start wallet -> do
      let pkh = transPubKeyHash (verificationKeyHash wallet)
          nid = Defaults.networkId
          value = C.lovelaceToValue (C.Coin 10_000_000)
      -- Use the pre-compiled fixedScript via lockEscrowWith to avoid
      -- repeated PlutusTx compilation.
      tx <-
        CoinSelection.tryBalanceAndSubmit
          mempty
          wallet
          (execBuildTx (Scripts.lockEscrowWith nid fixedScript pkh value))
          TrailingChange
          []
      let txBody = C.getTxBody tx
          txId = C.getTxId txBody
          txIn = C.TxIn txId (C.TxIx 0)
      pure
        s
          { modelInitialized = True
          , modelContributor = pkh
          , modelDeadlinePassed = False
          , modelScriptUtxo = Just txIn
          }
    Redeem -> do
      let Just txIn = modelScriptUtxo s
          -- Upper bound one slot before deadline so the range fits
          -- inside @to deadline@ (which is @(-∞, deadline]@).
          upperSlot = if fixedDeadlineSlot > 1 then fixedDeadlineSlot - 1 else 0
      void $
        CoinSelection.tryBalanceAndSubmit
          mempty
          Wallet.w1
          ( execBuildTx $ do
              -- Use pre-compiled script via redeemEscrowWith.
              Scripts.redeemEscrowWith fixedScript txIn
              mapM_ (addTargetOutput Defaults.networkId) (Escrow.epTargets fixedParams)
              BuildTx.addValidityRangeSlots (C.SlotNo 0) (C.SlotNo upperSlot)
          )
          TrailingChange
          []
      pure s{modelInitialized = False, modelScriptUtxo = Nothing}
    Refund -> do
      let Just txIn = modelScriptUtxo s
          cardanoPkh = fromPlutusPubKeyHash (modelContributor s)
      void $
        CoinSelection.tryBalanceAndSubmit
          mempty
          Wallet.w1
          ( execBuildTx $ do
              -- Use pre-compiled script via refundEscrowWith.
              Scripts.refundEscrowWith fixedScript txIn cardanoPkh
              BuildTx.addValidityRangeSlots (C.SlotNo fixedDeadlineSlot) (C.SlotNo (fixedDeadlineSlot + 100))
          )
          TrailingChange
          []
      pure s{modelInitialized = False, modelScriptUtxo = Nothing}
    WaitUntilDeadline -> do
      -- Advance the mockchain clock past the deadline so Refund
      -- becomes valid and Redeem becomes invalid.
      setPOSIXTime (Escrow.epDeadline fixedParams + 1000)
      pure s{modelDeadlinePassed = True}

--------------------------------------------------------------------------------
-- ThreatModelsFor (empty — threat models wired in a later phase)
--------------------------------------------------------------------------------

instance ThreatModelsFor EscrowModel where
  -- \| Shadow attacks: each model takes a positive tx that succeeded and
  -- mutates it (twists exactly one property), then resubmits. The
  -- contract must reject the mutated form. Selected because each probes
  -- a guarantee the Escrow contract claims to enforce:
  --   signatoryRemoval       — Refund requires contributor signature
  --   timeBoundManipulation  — Redeem/Refund gated by deadline validity range
  --   largeDataAttackWith 10 — rejects bloated inline datums
  --   valueUnderpaymentAttack — Redeem must pay full target values
  --   doubleSatisfaction     — single payout can't satisfy two escrow spends
  threatModels =
    [ signatoryRemoval
    , largeDataAttackWith 10
    , valueUnderpaymentAttack
    ]

  -- \| Known vulnerabilities — these attacks SUCCEED against the Escrow
  -- contract. Listed here to document them as accepted risk:
  --   timeBoundManipulation — Start tx has no validity range constraint;
  --     an attacker can widen the range freely
  --   doubleSatisfaction — a single payout output can satisfy two
  --     escrow spends (classic double-satisfaction)
  expectedVulnerabilities =
    [ timeBoundManipulation
    , doubleSatisfaction
    ]

--------------------------------------------------------------------------------
-- Test tree
--------------------------------------------------------------------------------

tests :: TestTree
tests = propRunActions @EscrowModel "Escrow"

--------------------------------------------------------------------------------
-- Helpers — mockchain time conversions
--------------------------------------------------------------------------------

{- | The mockchain system start is Jan 1, 2022 = POSIX 1640995200 seconds
= 1640995200000 milliseconds.  Slots are 1-to-1 with seconds from this
origin (SlotLength = 1 s, see @Convex.MockChain.Defaults.slotLength@).
-}
systemStartPosixMs :: Integer
systemStartPosixMs = 1_640_995_200 * 1000

{- | Convert a slot number to an absolute POSIX time in milliseconds,
accounting for the mockchain's system start.
-}
slotToPosixMs :: C.SlotNo -> POSIXTime
slotToPosixMs (C.SlotNo n) =
  POSIXTime (systemStartPosixMs + fromIntegral n * 1000)

--------------------------------------------------------------------------------
-- Target output builder
--------------------------------------------------------------------------------

{- | Add a single EscrowTarget to the BuildTx monad — either a payment to a
PKH address or a payment to a script with an inline datum.
-}
addTargetOutput
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , MonadBuildTx era m
     )
  => C.NetworkId
  -> Escrow.EscrowTarget
  -> m ()
addTargetOutput nid = \case
  Escrow.PaymentPubKeyTarget pkh val -> do
    let addr =
          C.makeShelleyAddressInEra
            C.shelleyBasedEra
            nid
            (C.PaymentCredentialByKey (fromPlutusPubKeyHash pkh))
            C.NoStakeAddress
        -- Convert Plutus lovelace to Cardano API Value so the on-chain
        -- output satisfies the validator's @geq@ check.
        PV.Lovelace lvl = PV.lovelaceValueOf val
        cVal = C.lovelaceToValue (C.Coin lvl)
    BuildTx.payToAddress addr cVal
  Escrow.ScriptTarget _sh _dat _val ->
    -- Unreachable with current fixedParams (PaymentPubKeyTarget only).
    error "addTargetOutput: ScriptTarget not supported with fixedParams"

--------------------------------------------------------------------------------
-- Plutus <-> cardano-api conversions
--------------------------------------------------------------------------------

{- | Convert a Plutus PubKeyHash (BuiltinByteString wrapper) to a
cardano-api 'Hash PaymentKey' (blake2b-224 hash).
-}
fromPlutusPubKeyHash :: PubKeyHash -> C.Hash C.PaymentKey
fromPlutusPubKeyHash pkh =
  case C.deserialiseFromRawBytes
    (C.AsHash C.AsPaymentKey)
    (PlutusTx.fromBuiltin (getPubKeyHash pkh)) of
    Left _ -> error "fromPlutusPubKeyHash: deserialisation of PubKeyHash failed"
    Right h -> h
