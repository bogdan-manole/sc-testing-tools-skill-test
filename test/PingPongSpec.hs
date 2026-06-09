{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module PingPongSpec (tests) where

import Cardano.Api qualified as C
import Convex.BuildTx (execBuildTx)
import Convex.BuildTx qualified as BuildTx
import Convex.Class (getUtxo)
import Convex.CoinSelection (ChangeOutputPosition (..))
import Convex.MockChain (fromLedgerUTxO)
import Convex.MockChain.CoinSelection (tryBalanceAndSubmit)
import Convex.MockChain.Defaults qualified as Defaults
import Convex.TestingInterface (
  Action,
  Gen,
  TestingInterface (..),
  ThreatModelsFor (..),
  propRunActions,
 )
import Convex.ThreatModel.DatumBloat (datumByteBloatAttack, datumListBloatAttack)
import Convex.ThreatModel.DoubleSatisfaction (doubleSatisfaction)
import Convex.ThreatModel.DuplicateListEntry (duplicateListEntryAttack)
import Convex.ThreatModel.InputDuplication (inputDuplication)
import Convex.ThreatModel.InvalidDatumIndex (invalidDatumIndexAttack)
import Convex.ThreatModel.InvalidScriptPurpose (invalidScriptPurposeAttack)
import Convex.ThreatModel.LargeData (largeDataAttack, largeDataAttackWith)
import Convex.ThreatModel.LargeValue (largeValueAttack)
import Convex.ThreatModel.MissingOutputDatum (missingOutputDatumAttack)
import Convex.ThreatModel.MutualExclusion (mutualExclusionAttack)
import Convex.ThreatModel.NegativeInteger (negativeIntegerAttack)
import Convex.ThreatModel.OutputDatumHashMissing (outputDatumHashMissingAttack)
import Convex.ThreatModel.RedeemerAssetSubstitution (redeemerAssetSubstitution)
import Convex.ThreatModel.SelfReferenceInjection (selfReferenceInjection)
import Convex.ThreatModel.SignatoryRemoval (signatoryRemoval)
import Convex.ThreatModel.TimeBoundManipulation (timeBoundManipulation)
import Convex.ThreatModel.UnprotectedScriptOutput (unprotectedScriptOutput)
import Convex.ThreatModel.ValueUnderpayment (valueUnderpaymentAttack)
import Convex.Wallet.MockWallet qualified as Wallet
import Data.Aeson (ToJSON (..))
import Data.Map qualified as Map
import GHC.Generics (Generic)
import Scripts (pingPongValidatorScript, playPingPongRound)
import Scripts.PingPong qualified as PingPong
import Test.QuickCheck qualified as QC
import Test.Tasty (TestTree)

-- | Model state for the PingPong contract.
data PingPongModel = PingPongModel
  { modelInitialized :: !Bool
  , modelScriptUtxo :: !(Maybe C.TxIn)
  , modelState :: !PingPong.PingPongState
  , modelUtxoValue :: !C.Lovelace
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance ToJSON PingPong.PingPongState where
  toJSON = toJSON . show

-- Sets up the in-memory model only. Returns the zero state with
-- modelInitialized = False. DOES NOT submit any tx, DOES NOT deploy,
-- DOES NOT touch the chain. Deployment is the Start Action, emitted
-- by the generator when the model is uninitialised.
instance TestingInterface PingPongModel where
  data Action PingPongModel
    = Start !C.Lovelace
    | PlayRound !PingPong.PingPongRedeemer
    deriving (Show)

  initialize =
    pure
      PingPongModel
        { modelInitialized = False
        , modelScriptUtxo = Nothing
        , modelState = PingPong.Pinged
        , modelUtxoValue = C.Coin 5_000_000
        }

  -- Proposes the next Action. Branches on STRUCTURAL feasibility only:
  -- when not initialized the script UTxO doesn't exist yet, so only
  -- Start can be constructed. When initialized, all three redeemers are
  -- always constructible regardless of state — semantic gating lives
  -- in precondition, not here.
  arbitraryAction PingPongModel{modelInitialized} =
    if not modelInitialized
      then Start <$> genLovelace
      else PlayRound <$> QC.elements [PingPong.Ping, PingPong.Pong, PingPong.Stop]

  -- Encodes the PingPong validator's transition rules exactly.
  -- The validator accepts exactly 4 transitions:
  --   (Pinged, Pong, Ponged)   (Ponged, Ping, Pinged)
  --   (Pinged, Stop, Stopped)  (Ponged, Stop, Stopped)
  -- Stopped is terminal. The model mirrors these rules here.
  precondition _s (Start _) = True
  -- Deploy: always valid on-chain — no script state exists yet.
  precondition s (PlayRound PingPong.Ping) = modelState s == PingPong.Ponged
  -- Ping only valid when in Ponged state (transition: Ponged → Pinged).
  precondition s (PlayRound PingPong.Pong) = modelState s == PingPong.Pinged
  -- Pong only valid when in Pinged state (transition: Pinged → Ponged).
  precondition s (PlayRound PingPong.Stop) =
    modelState s == PingPong.Pinged || modelState s == PingPong.Ponged

  -- Stop valid from either active state (Pinged or Ponged, not Stopped).

  -- Builds and submits the on-chain tx for this Action, then returns the
  -- updated model state. The model transition mirrors what the validator
  -- does on-chain. If the action is invalid (precondition False), perform
  -- still submits it — the framework expects rejection.
  perform _ (Start lovelace) = do
    let scriptHash =
          C.hashScript $ C.PlutusScript C.plutusScriptVersion pingPongValidatorScript
        scriptAddr =
          C.makeShelleyAddressInEra
            C.shelleyBasedEra
            Defaults.networkId
            (C.PaymentCredentialByScript scriptHash)
            C.NoStakeAddress
        tx =
          execBuildTx $
            BuildTx.payToScriptInlineDatum
              Defaults.networkId
              scriptHash
              PingPong.Pinged
              C.NoStakeAddress
              (C.lovelaceToValue lovelace)
    _ <- tryBalanceAndSubmit mempty Wallet.w1 tx TrailingChange []
    allUtxos <- fromLedgerUTxO C.shelleyBasedEra <$> getUtxo
    let txIn = findScriptUtxo scriptAddr allUtxos
    pure
      PingPongModel
        { modelInitialized = True
        , modelScriptUtxo = Just txIn
        , modelState = PingPong.Pinged
        , modelUtxoValue = lovelace
        }
  perform PingPongModel{modelScriptUtxo = Just txIn, modelUtxoValue} (PlayRound redeemer) = do
    let tx = execBuildTx $ playPingPongRound Defaults.networkId modelUtxoValue redeemer txIn
    _ <- tryBalanceAndSubmit mempty Wallet.w1 tx TrailingChange []
    let scriptHash =
          C.hashScript $ C.PlutusScript C.plutusScriptVersion pingPongValidatorScript
        scriptAddr =
          C.makeShelleyAddressInEra
            C.shelleyBasedEra
            Defaults.networkId
            (C.PaymentCredentialByScript scriptHash)
            C.NoStakeAddress
    allUtxos <- fromLedgerUTxO C.shelleyBasedEra <$> getUtxo
    let newTxIn = findScriptUtxo scriptAddr allUtxos
        newState = case redeemer of
          PingPong.Ping -> PingPong.Pinged
          PingPong.Pong -> PingPong.Ponged
          PingPong.Stop -> PingPong.Stopped
    pure
      PingPongModel
        { modelInitialized = True
        , modelScriptUtxo = Just newTxIn
        , modelState = newState
        , modelUtxoValue = modelUtxoValue
        }
  perform _ _ = error "PlayRound called without script UTxO"

instance ThreatModelsFor PingPongModel where
  threatModels =
    [ unprotectedScriptOutput
    , doubleSatisfaction
    , signatoryRemoval
    , valueUnderpaymentAttack
    , invalidDatumIndexAttack
    , missingOutputDatumAttack
    , largeValueAttack
    , inputDuplication
    , selfReferenceInjection
    , datumByteBloatAttack
    , datumListBloatAttack
    , duplicateListEntryAttack
    , negativeIntegerAttack
    , outputDatumHashMissingAttack
    , mutualExclusionAttack
    , redeemerAssetSubstitution
    , largeDataAttack
    , invalidScriptPurposeAttack pingPongValidatorScript
    , largeDataAttackWith 10
    ]

  -- TimeBoundManipulation is an accepted gap: PingPong is a pure state
  -- machine with no deadlines, timeouts, or time-gated transitions.
  -- The contract intentionally uses an always-valid range
  -- (setScriptsValid). An attacker widening the validity window has no
  -- effect on the contract's core guarantees. Listed here to document
  -- the gap and catch accidental regressions.
  expectedVulnerabilities = [timeBoundManipulation]

tests :: TestTree
tests = propRunActions @PingPongModel "PingPong"

genLovelace :: Gen C.Lovelace
genLovelace = C.Coin . fromIntegral <$> QC.choose (2_000_000 :: Int, 10_000_000)

findScriptUtxo :: C.AddressInEra C.ConwayEra -> C.UTxO C.ConwayEra -> C.TxIn
findScriptUtxo scriptAddr utxoSet =
  let C.UTxO utxos = utxoSet
      scriptUtxos = Map.filter (\(C.TxOut addr _ _ _) -> addr == scriptAddr) utxos
   in fst $ head $ Map.toList scriptUtxos
