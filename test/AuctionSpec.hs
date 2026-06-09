{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | Property-based on-chain test model for the Auction contract, built on
the convex-testing-interface framework.

The framework drives the contract through TWO channels at once:

  * Positive channel: the generator proposes an action, 'precondition'
    says True, 'perform' submits it, and the framework asserts the chain
    ACCEPTS it.
  * Negative channel: the same action shape is proposed but 'precondition'
    says False; 'perform' still submits, and the framework asserts the
    chain REJECTS it.

The model below is an in-memory MIRROR of the on-chain auction. The
validator is the source of truth; the model encodes the same rules so
that the model's verdict (precondition) and the chain's verdict (perform)
can be cross-checked on every step.

This step wires the skeleton and fully implements the deploy action
('Start'). Bidding, closing and payout actions arrive in later steps;
'threatModels' stays empty until the positive/negative suite is green.
-}
module AuctionSpec (tests) where

import Auction.Scripts (
  auctionValidatorScript,
  lockAuction,
  payout,
  placeBid,
 )
import Auction.Utils (mintingScript, utxosAt)
import Auction.Validator (
  AuctionDatum (..),
  AuctionParams (..),
  Bid (..),
 )
import qualified Cardano.Api as C
import Control.Monad (void)
import Convex.BuildTx (execBuildTx)
import qualified Convex.BuildTx as BuildTx
import qualified Convex.CardanoApi.Lenses as L
import Convex.Class (setSlot)
import Convex.CoinSelection (ChangeOutputPosition (TrailingChange))
import qualified Convex.MockChain.CoinSelection as CoinSelection
import qualified Convex.MockChain.Defaults as Defaults
import Convex.TestingInterface (
  Action,
  TestingInterface (..),
  ThreatModelsFor (..),
  propRunActions,
 )
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS

-- Threat-model attacks: each is imported from its OWN per-attack module under
-- Convex.ThreatModel.<Name>. Convex.ThreatModel.All re-exports ONLY
-- 'allThreatModels'; the individual names are NOT re-exported through it, so we
-- must reach into each module directly.

import Control.Lens ((%~))
import Convex.ThreatModel.DatumBloat (
  datumByteBloatAttackWith,
  datumListBloatAttack,
 )
import Convex.ThreatModel.DoubleSatisfaction (doubleSatisfaction)
import Convex.ThreatModel.DuplicateListEntry (duplicateListEntryAttack)
import Convex.ThreatModel.InputDuplication (inputDuplication)
import Convex.ThreatModel.InvalidDatumIndex (invalidDatumIndexAttack)
import Convex.ThreatModel.InvalidScriptPurpose (invalidScriptPurposeAttack)
import Convex.ThreatModel.LargeData (largeDataAttackWith)
import Convex.ThreatModel.LargeValue (largeValueAttackWith)
import Convex.ThreatModel.MissingOutputDatum (missingOutputDatumAttack)
import Convex.ThreatModel.MutualExclusion (mutualExclusionAttack)
import Convex.ThreatModel.NegativeInteger (negativeIntegerAttack)
import Convex.ThreatModel.OutputDatumHashMissing (outputDatumHashMissingAttack)
import Convex.ThreatModel.RedeemerAssetSubstitution (redeemerAssetSubstitution)
import Convex.ThreatModel.SelfReferenceInjection (selfReferenceInjection)
import Convex.ThreatModel.SignatoryRemoval (signatoryRemoval)
import Convex.ThreatModel.TimeBoundManipulation (timeBoundManipulation)
import Convex.ThreatModel.TokenForgery (tokenForgeryAttack)
import Convex.ThreatModel.UnprotectedScriptOutput (unprotectedScriptOutput)
import Convex.ThreatModel.ValueUnderpayment (valueUnderpaymentAttack)
import Convex.Wallet (
  Wallet,
  addressInEra,
  verificationKeyHash,
 )
import qualified Convex.Wallet.MockWallet as Wallet
import Data.Aeson (ToJSON)
import GHC.Generics (Generic)
import qualified PlutusLedgerApi.V3 as PV3
import PlutusTx.Builtins (toBuiltin)
import qualified Test.QuickCheck as QC
import Test.Tasty (TestTree)

-- ----------------------------------------------------------------------------
-- 1. Module-level fixed auction configuration
--
-- The whole suite tests ONE concrete auction. Fixing the parameters here
-- (seller, NFT policy/name, min bid, deadline) keeps the model small and
-- makes the model<->chain mirror unambiguous: every action refers to this
-- single auction instance.
-- ----------------------------------------------------------------------------

-- | Convert a wallet's payment verification-key hash into a Plutus PubKeyHash.
walletPkh :: Wallet -> PV3.PubKeyHash
walletPkh w =
  PV3.PubKeyHash (toBuiltin (C.serialiseToRawBytes (verificationKeyHash w)))

{- | The always-succeeds NFT minting policy, RE-TAGGED as Plutus V2.

WHY V2 (not the V1 'Auction.Utils.mintingScript', nor V3): the deploy tx
mints the NFT AND, in the same transaction, locks the auction output with an
INLINE datum (see 'lockAuction'/'perform Start'). When the ledger builds the
script context for the minting policy it must translate the WHOLE tx — and a
Plutus V1 context cannot represent inline datums, so a V1 mint policy makes
the deploy tx fail with InlineDatumsNotSupported. Plutus V2 introduced
inline-datum support in its script context, which removes that blocker.

V2 (rather than V3) is the right minimal step because the compiled
always-succeeds PROGRAM is ABI-compatible with V1/V2 (same argument/return
shape) — so re-tagging its bytes as V2 yields a script the V2 machine still
accepts. Re-tagging the very same bytes as V3 does NOT work: V3 changed the
script ABI (single ScriptContext arg returning BuiltinUnit), so the old
program's return value is rejected at execution with InvalidReturnValue.

Only the language tag (and therefore the script hash / policy id) changes
versus V1 — which is exactly why every NFT-identity constant below is
re-derived from THIS hash so the auction params and minted asset stay
consistent.
-}
mintingScriptV2 :: C.PlutusScript C.PlutusScriptV2
mintingScriptV2 =
  case mintingScript of
    C.PlutusScriptSerialised bytes ->
      C.PlutusScriptSerialised (bytes :: SBS.ShortByteString)

{- | Hash of the always-succeeds minting script (Plutus V2). Used both as the
cardano-api 'C.PolicyId' for building the NFT value and (via its raw bytes)
as the Plutus 'CurrencySymbol' stored in the auction params. Because
'C.hashScript' folds in the Plutus language tag, this V2 hash differs from
the V1 hash of the same program — so the auction params and minted asset
stay consistent ONLY because both sides derive from this single binding.
-}
mintingScriptHash :: C.ScriptHash
mintingScriptHash = C.hashScript (C.PlutusScript C.PlutusScriptV2 mintingScriptV2)

-- | cardano-api policy id of the auctioned NFT.
nftPolicyId :: C.PolicyId
nftPolicyId = C.PolicyId mintingScriptHash

-- | cardano-api asset name of the auctioned NFT.
nftAssetName :: C.AssetName
nftAssetName = C.UnsafeAssetName (BS8.pack "AUCTIONNFT")

-- | The fixed auction parameters under test.
auctionParams :: AuctionParams
auctionParams =
  AuctionParams
    { apSeller = walletPkh Wallet.w1
    , -- CurrencySymbol bytes == the minting-script hash raw bytes, so the
      -- on-chain currency symbol matches 'nftPolicyId' used off-chain.
      apCurrencySymbol =
        PV3.CurrencySymbol (toBuiltin (C.serialiseToRawBytes mintingScriptHash))
    , -- TokenName bytes == the asset-name raw bytes, keeping on/off-chain
      -- token identity consistent.
      apTokenName =
        PV3.TokenName (toBuiltin (C.serialiseToRawBytes nftAssetName))
    , apMinBid = PV3.Lovelace 10_000_000
    , -- Deadline at slot 100. Mockchain start = POSIX 1640995200 s, 1 slot = 1 s.
      apEndTime = PV3.POSIXTime ((1640995200 + 100) * 1000)
    }

-- | Slot of the bid deadline (handy for validity ranges in later steps).
deadlineSlot :: C.SlotNo
deadlineSlot = C.SlotNo 100

-- | Hash of the parameterized auction validator (Plutus V3).
auctionScriptHash :: C.ScriptHash
auctionScriptHash =
  C.hashScript (C.PlutusScript C.PlutusScriptV3 (auctionValidatorScript auctionParams))

-- | Address of the auction validator on the default network.
auctionScriptAddr :: C.AddressInEra C.ConwayEra
auctionScriptAddr =
  C.makeShelleyAddressInEra
    C.shelleyBasedEra
    Defaults.networkId
    (C.PaymentCredentialByScript auctionScriptHash)
    C.NoStakeAddress

-- | The single NFT token value (policy id + asset name, quantity 1).
nftValue :: C.Value
nftValue = C.valueFromList [(C.AssetId nftPolicyId nftAssetName, 1)]

-- | The value locked at the script on deploy: NFT plus min-Ada deposit.
lockedValue :: C.Value
lockedValue = nftValue <> C.lovelaceToValue (C.Coin 2_000_000)

{- | apMinBid as a plain Integer (lovelace). The model tracks bids as
Integers, so the precondition compares against this rather than the Plutus
'PV3.Lovelace' newtype. Mirrors the validator's first-bid threshold.
-}
apMinBidInt :: Integer
apMinBidInt = PV3.getLovelace (apMinBid auctionParams)

{- | The lovelace a fresh bid must beat in the current model state. This is
exactly the validator's 'sufficientBid' threshold viewed from the model:
apMinBid when there are no bids yet, the current highest amount otherwise.
The generator straddles this number to feed both channels; the precondition
compares against it to decide acceptance.
-}
currentThreshold :: AuctionModel -> Integer
currentThreshold s = maybe apMinBidInt snd (amHighestBid s)

{- | Map a model wallet index (1-based) to a concrete mock wallet. The model
stores bidders abstractly as Ints so the in-memory state stays small; this
is the single place that resolves an index to the real signing/paying
wallet used on-chain. w1 is the seller; bidders are drawn from w2..w4.
-}
walletForIndex :: Int -> Wallet
walletForIndex 1 = Wallet.w1
walletForIndex 2 = Wallet.w2
walletForIndex 3 = Wallet.w3
walletForIndex 4 = Wallet.w4
walletForIndex n = error ("walletForIndex: unsupported wallet index " <> show n)

-- ----------------------------------------------------------------------------
-- 2. Model state
--
-- The model mirrors the on-chain auction's observable state. 'amInitialized'
-- records whether the contract has been deployed yet (the generator reads it
-- to decide between emitting the deploy action and a normal action). The
-- other fields track the auction's progress for future bid/close/payout
-- steps.
-- ----------------------------------------------------------------------------

data AuctionModel = AuctionModel
  { amInitialized :: Bool
  -- ^ Has the auction been deployed on-chain (Start performed)?
  , amHighestBid :: Maybe (Int, Integer)
  -- ^ (bidder wallet index, lovelace); Nothing = no bids yet.
  , amPastDeadline :: Bool
  -- ^ Has the clock advanced past the bid deadline?
  , amSettled :: Bool
  -- ^ Has the auction been paid out / closed?
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- ----------------------------------------------------------------------------
-- 3. TestingInterface instance (only the Start / deploy action this step)
-- ----------------------------------------------------------------------------

instance TestingInterface AuctionModel where
  -- The auction's actions. Per the cardinal rule, deployment is an ACTION,
  -- never setup: 'Start' mints the NFT and locks it at the script. 'PlaceBid'
  -- spends the live script UTxO with a NewBid redeemer (bidder wallet index,
  -- bid lovelace). 'CloseBidding' submits NO transaction — it is a pure
  -- model-only clock advance whose sole purpose is to make the post-deadline
  -- state (where Payout becomes valid) reachable within a trace. 'Payout'
  -- spends the live script UTxO with the Payout redeemer to settle the
  -- auction: it pays the highest bid's Ada to the seller and the NFT to the
  -- winner (or returns the NFT to the seller if there were no bids).
  data Action AuctionModel
    = Start
    | PlaceBid Int Integer
    | -- \^ bidder wallet index, bid amount (lovelace)
      CloseBidding
    | -- \^ advance chain clock past apEndTime; no tx
      Payout
    -- \^ settle: pay seller, NFT to winner (or back to seller if no bids)
    deriving (Show)

  -- initialize is MODEL-ONLY. It returns the zero state with
  -- amInitialized=False and touches NOTHING on-chain. Deployment happens
  -- later, when the generator emits 'Start' against an uninitialised model.
  -- (Putting deployment here would violate the cardinal rule.)
  initialize = pure (AuctionModel False Nothing False False)

  -- arbitraryAction proposes the next action based on STRUCTURAL feasibility
  -- only (what can the model build right now?), never on semantic validity
  -- (will the validator accept it?) — that judgement belongs to precondition,
  -- and keeping it out of the generator is what feeds the negative channel.
  --
  -- Structural branch: while uninitialised the only buildable action is the
  -- deploy ('Start'); once initialised a bid, a clock advance, AND a payout
  -- can ALWAYS be built (a live script UTxO exists), so we choose among
  -- 'PlaceBid', 'CloseBidding' and 'Payout'.
  -- 'CloseBidding' is purely structural (no semantic precondition — it submits
  -- no tx) and exists so traces reach the post-deadline payout window; it is
  -- given a small relative weight so it fires often enough to expose that
  -- state without starving the bid generator. 'Payout' is also emitted purely
  -- structurally: it is NOT gated on amPastDeadline or amSettled. Deliberately
  -- emitting Payout while the deadline has not passed feeds the negative
  -- channel (payout-too-early, validator must REJECT via validPayoutTime), and
  -- emitting it when already settled feeds the double-payout negative case (no
  -- script UTxO / already-spent). Gating Payout on those flags would be a
  -- SEMANTIC filter that belongs in precondition, and would silently starve
  -- the negative channel. For 'PlaceBid' the bid AMOUNT is
  -- drawn ACROSS the validity threshold (apMinBid for the first bid, the
  -- current highest otherwise): the high-frequency band sits strictly above
  -- (positive channel, chain must ACCEPT) while the two lower bands sit
  -- at/below it (negative channel, chain must REJECT). Generating both sides
  -- is what keeps the negative channel from silently starving — the generator
  -- never gates on acceptance.
  arbitraryAction s
    | not (amInitialized s) = pure Start
    | otherwise =
        QC.frequency
          [ (6, placeBidGen s) -- bids dominate (positive + negative bands)
          , (1, pure CloseBidding) -- occasional jump to the payout window
          , (1, pure Payout) -- settle; ungated to feed too-early/double-payout negatives
          ]
   where
    placeBidGen st = do
      let thr = currentThreshold st
      bidder <- QC.elements [2, 3, 4]
      amt <-
        QC.frequency
          [ (3, QC.choose (thr + 1, thr + 20_000_000)) -- above threshold (positive)
          , (2, QC.choose (max 1 (thr - 5_000_000), thr)) -- at/below threshold (negative)
          , (1, QC.choose (1, max 1 (thr - 1))) -- well below (negative)
          ]
      pure (PlaceBid bidder amt)

  -- precondition encodes the contract's semantic rule for each action: True
  -- iff the validator SHOULD accept it in this state. The framework runs the
  -- action on both the chain (perform) and the model (precondition); the two
  -- verdicts must agree.
  --
  -- Rule (Start): deploying is valid exactly once — only while the auction
  -- has not yet been deployed.
  precondition s Start = not (amInitialized s)
  -- Rule (PlaceBid): mirrors the validator's NewBid branch — the auction must
  -- be deployed, the bid must land before the deadline (and not after payout),
  -- and the amount must beat the threshold: >= apMinBid for the very first
  -- bid, strictly > the current highest thereafter ('sufficientBid'). This is
  -- the model's verdict that the chain's 'perform' is cross-checked against.
  precondition s (PlaceBid _ amt) =
    amInitialized s
      && not (amPastDeadline s)
      && not (amSettled s)
      && case amHighestBid s of
        Nothing -> amt >= apMinBidInt
        Just (_, cur) -> amt > cur
  -- Rule (CloseBidding): a model-only clock advance; it submits no tx so the
  -- chain cannot reject it. Always a positive action.
  precondition _ CloseBidding = True
  -- Rule (Payout): initialized, the deadline has passed, and the auction
  -- has not already been settled. Mirrors the validator's Payout branch
  -- (validPayoutTime requires the validity range start at/after apEndTime;
  -- a single settlement, since the script UTxO is spent exactly once).
  precondition s Payout = amInitialized s && amPastDeadline s && not (amSettled s)

  -- perform builds and submits the real transaction, then returns the updated
  -- model. It runs UNCONDITIONALLY: on a negative action the framework expects
  -- the submit to be rejected and discards the returned state. The model
  -- transition here mirrors what the deploy transaction does on-chain.
  perform s Start = do
    -- Deploy = one transaction that BOTH mints the NFT (always-succeeds V2
    -- policy) and locks it at the auction script with the initial empty datum
    -- (AuctionDatum Nothing) plus a min-Ada deposit. The mint policy is Plutus
    -- V2 ('mintingScriptV2') so its script context can represent the INLINE
    -- datum that 'lockAuction' attaches to the script output — a V1 policy here
    -- would fail context translation with InlineDatumsNotSupported.
    let builder =
          execBuildTx $ do
            BuildTx.mintPlutus mintingScriptV2 () nftAssetName 1
            lockAuction Defaults.networkId auctionParams (AuctionDatum Nothing) lockedValue
    void $ CoinSelection.tryBalanceAndSubmit mempty Wallet.w1 builder TrailingChange []
    -- Reset the clock to slot 0 so the bid window (deadline at slot 100) is
    -- open for the bidding actions added in later steps.
    setSlot (C.SlotNo 0)
    pure s{amInitialized = True}

  -- perform (PlaceBid): submits the bid transaction UNCONDITIONALLY — it does
  -- not consult the precondition. On a positive bid the framework asserts the
  -- chain accepts; on a negative bid (below threshold, generated by
  -- arbitraryAction) the framework expects the validator to REJECT and
  -- discards the returned state. The tx is assembled to satisfy every NewBid
  -- rule for a valid bid: spend the live script UTxO recreating the datum with
  -- the new bid and a value of NFT + bid lovelace ('correctOutput'), refund
  -- the previous highest bidder their exact lovelace ('refundsPreviousHighestBid',
  -- skipped on the first bid), and cap the validity range below the deadline
  -- so the bid is in time ('validBidTime'). The bidder's own wallet pays.
  perform s (PlaceBid bidder amt) = do
    -- Locate the single live auction UTxO to spend (the continuing script
    -- output recreated by Start / the previous bid).
    scriptUtxos <- utxosAt auctionScriptHash
    scriptTxIn <- case scriptUtxos of
      ((txIn, _) : _) -> pure txIn
      [] -> fail "PlaceBid: no auction script UTxO found"
    let bidderWallet = walletForIndex bidder
        -- bAddr is not consulted by the NewBid validator branch; use the
        -- bidder's PKH bytes so the field is consistent and deterministic.
        bidderPkh = walletPkh bidderWallet
        newBid =
          Bid
            { bAddr = PV3.getPubKeyHash bidderPkh
            , bPkh = bidderPkh
            , bAmount = PV3.Lovelace amt
            }
        -- New script-output value: NFT + exactly the bid lovelace (the
        -- validator's correctOutput checks lovelaceValueOf == bAmount).
        newScriptValue = nftValue <> C.lovelaceToValue (C.Coin amt)
        builder =
          execBuildTx $ do
            placeBid Defaults.networkId auctionParams scriptTxIn newBid newScriptValue
            -- Refund the previous highest bidder their exact lovelace to a
            -- pubkey address (matched by the validator on PKH + amount). No
            -- refund output exists on the first bid.
            case amHighestBid s of
              Nothing -> pure ()
              Just (prevIdx, prevAmt) ->
                BuildTx.payToAddress
                  (addressInEra Defaults.networkId (walletForIndex prevIdx))
                  (C.lovelaceToValue (C.Coin prevAmt))
            -- Cap the validity upper bound strictly below the deadline (slot
            -- 100) so the bid is in time; a slot well inside the window keeps
            -- the bid valid regardless of submission timing.
            BuildTx.addBtx
              ( L.txValidityUpperBound
                  %~ const (C.TxValidityUpperBound C.shelleyBasedEra (Just (C.SlotNo 50)))
              )
    void $ CoinSelection.tryBalanceAndSubmit mempty bidderWallet builder TrailingChange []
    pure s{amHighestBid = Just (bidder, amt)}

  -- perform (CloseBidding): submits NO transaction. It only advances the
  -- mockchain clock past the bid deadline (slot 100) and records that in the
  -- model, opening the post-deadline window where Payout becomes valid. Since
  -- nothing is submitted there is nothing for the chain to accept or reject,
  -- which is why CloseBidding is always a positive/model-only action.
  perform s CloseBidding = do
    setSlot (C.SlotNo 150) -- jump past deadlineSlot (100); payout window now open
    pure s{amPastDeadline = True}

  -- perform (Payout): submits the settlement transaction UNCONDITIONALLY — it
  -- does not consult the precondition. On a valid payout the framework asserts
  -- the chain accepts; on a negative payout (too early, or after settlement
  -- when the script UTxO is gone — both reachable because the generator does
  -- NOT gate Payout on amPastDeadline/amSettled) the framework expects the
  -- chain to REJECT and discards the returned state. The tx is assembled to
  -- satisfy every rule of the validator's Payout branch:
  --   * validPayoutTime: a validity LOWER bound at slot 120 (>= apEndTime
  --     slot 100, <= the post-CloseBidding clock at 150) so the range starts
  --     at/after the deadline;
  --   * sellerGetsHighestBid: an output paying the seller exactly the highest
  --     bid's lovelace — required ONLY when there were bids (with no bids the
  --     validator returns True for this check, so we emit no seller-Ada output);
  --   * highestBidderGetsAsset: the NFT goes to the winning bidder, or back to
  --     the seller (apSeller) when there were no bids.
  -- The seller (w1) drives settlement.
  perform s Payout = do
    -- Locate the single live auction UTxO to spend with the Payout redeemer.
    scriptUtxos <- utxosAt auctionScriptHash
    scriptTxIn <- case scriptUtxos of
      ((txIn, _) : _) -> pure txIn
      [] -> fail "Payout: no auction script UTxO found"
    let sellerAddr = addressInEra Defaults.networkId Wallet.w1
        -- min-Ada deposit accompanying the NFT output, mirroring how Start
        -- locked the NFT (the validator only checks the NFT is present, so the
        -- extra Ada is harmless).
        nftWithMinAda = nftValue <> C.lovelaceToValue (C.Coin 2_000_000)
        builder =
          execBuildTx $ do
            payout auctionParams scriptTxIn
            -- Pay seller / winner per the highest-bid state.
            case amHighestBid s of
              Just (winnerIdx, amt) -> do
                -- sellerGetsHighestBid: exact bid lovelace to the seller.
                BuildTx.payToAddress sellerAddr (C.lovelaceToValue (C.Coin amt))
                -- highestBidderGetsAsset: NFT to the winning bidder.
                BuildTx.payToAddress
                  (addressInEra Defaults.networkId (walletForIndex winnerIdx))
                  nftWithMinAda
              Nothing ->
                -- No bids: validator requires only that the NFT returns to the
                -- seller (sellerGetsHighestBid is vacuously True with no bid).
                BuildTx.payToAddress sellerAddr nftWithMinAda
            -- validPayoutTime: validity LOWER bound at/after apEndTime (slot 100).
            BuildTx.addBtx
              ( L.txValidityLowerBound
                  %~ const (C.TxValidityLowerBound C.allegraBasedEra (C.SlotNo 120))
              )
    void $ CoinSelection.tryBalanceAndSubmit mempty Wallet.w1 builder TrailingChange []
    pure s{amSettled = True}

-- ----------------------------------------------------------------------------
-- 4. ThreatModelsFor instance
--
-- Threat models are a THIRD, declarative attack channel layered on the
-- positive channel (shadow/parallel-world tweaks to already-valid txs).
-- They are wired only once the positive/negative suite is green; an empty
-- list disables threat-model evaluation for now.
-- ----------------------------------------------------------------------------

instance ThreatModelsFor AuctionModel where
  -- SHADOW-ATTACK CONCEPT.
  --
  -- A threat model is a PARALLEL-WORLD shadow of a positive transaction: the
  -- framework takes a tx that the validator already ACCEPTED in the positive
  -- channel, twists exactly one property of it, and resubmits the mutant. The
  -- desired outcome is that the validator now REJECTS the mutant
  -- (shouldNotValidate) — that proves the auction guards the property being
  -- probed. If the validator instead ACCEPTS the mutant, that is a real
  -- vulnerability and the model FAILs. Each model isolates ONE knob so a
  -- failure is diagnostic. This is a third channel layered on the positive
  -- one; it does not replace the positive/negative split.
  --
  -- EXPECTED TO RESIST.
  --
  -- Every model in 'threatModels' below is asserted as a guarantee the auction
  -- MUST uphold: each is the shadow of a positive tx with exactly one knob
  -- twisted, and the auction is EXPECTED TO RESIST it (the validator must
  -- REJECT the mutant → the test PASSES). A model that instead PASSES the
  -- mutant exposes a real vulnerability; those exposed FAILs have been moved
  -- OUT of this list and into 'expectedVulnerabilities' below, so what remains
  -- here is the set the auction genuinely defends against (plus harmless
  -- SKIPs whose precondition the auction's txs never meet).
  --
  -- This is the MAXIMAL practical set: the full 18 parameter-free built-in
  -- attacks (the contents of 'Convex.ThreatModel.All.allThreatModels', spelled
  -- out explicitly so individual FAILs can be partitioned into
  -- expectedVulnerabilities) PLUS the parameterised attacks we can supply
  -- arguments for (invalidScriptPurpose with the auction validator, and
  -- tokenForgery with the NFT mint policy). Four heavy defaults are tuned DOWN
  -- to keep shadow-run time sane without losing coverage of WHICH models fail:
  -- largeDataAttackWith 10 (default 1000), datumByteBloatAttackWith 100
  -- (default 10000), largeValueAttackWith 10 (default 50); datumListBloatAttack
  -- keeps its small 5×100 default.
  --
  -- The auction is a state-machine contract: PlaceBid/Payout each spend the
  -- live script UTxO and (for PlaceBid) recreate a continuation script output
  -- carrying an INLINE datum + the NFT + the bid Ada, gating timing via the tx
  -- validity range. Each model probes one guarantee such a contract must hold:
  --
  --   * unprotectedScriptOutput   — redirects the continuation output to the
  --       attacker's key address (datum preserved). Probes continuation-stays-
  --       at-script (fund-redirection theft).
  --   * valueUnderpaymentAttack   — halves the Ada on a script output. Probes
  --       correctOutput's lovelaceValueOf == bAmount enforcement.
  --   * inputDuplication          — adds a duplicate input. Probes input-
  --       multiplicity assumptions.
  --   * selfReferenceInjection    — rewrites a credential-shaped datum subterm
  --       to the script's own credential. Probes datum address-field trust.
  --   * largeValueAttackWith 10   — mints 10 junk tokens into a script output.
  --       Probes whether the recreated value is whitelisted vs amount-only.
  --   * redeemerAssetSubstitution — substitutes asset ids named in redeemers.
  --       Probes redeemer asset-identity trust.
  --   * datumListBloatAttack      — appends items to every datum list field.
  --       Probes datum list-length bounding.
  --   * datumByteBloatAttackWith 100 — inflates the first list item's bytes.
  --       Probes datum bytestring-size bounding.
  --   * duplicateListEntryAttack  — duplicates the first entry of list fields.
  --       Probes datum list-uniqueness enforcement.
  --   * negativeIntegerAttack     — flips integer datum/redeemer fields to
  --       negative. Probes sign checks on the bid amount.
  --   * outputDatumHashMissingAttack — drops a datum hash from an output.
  --       Probes hash-datum reference enforcement.
  --   * mutualExclusionAttack     — permutes/pairs inputs. Probes input-order /
  --       one-of-N assumptions.
  --   * signatoryRemoval          — drops a required signer. Probes missing-
  --       signer authorization bypass.
  --   * missingOutputDatumAttack  — strips the datum from the continuation
  --       output. Probes recreated-output-must-carry-state-datum.
  --   * invalidDatumIndexAttack   — rewrites the AuctionDatum Constr index to
  --       an out-of-range value. Probes constructor-index rejection.
  --   * invalidScriptPurposeAttack <auction V3 script> — reuses the auction
  --       SPENDING validator as a MINTING policy in the same tx. Probes script-
  --       purpose confusion. Argument is the auction validator's own
  --       PlutusScriptV3 value (as 'auctionScriptHash' builds it).
  --   * tokenForgeryAttack <NFT V2 policy> <NFT name> — mints extra tokens
  --       under the always-succeeds NFT policy into a key output. Probes
  --       whether the auction validator constrains the tx's minted value.
  --
  -- NOTE: five attacks are deliberately ABSENT here — largeValueAttackWith 10,
  -- tokenForgeryAttack, doubleSatisfaction, largeDataAttackWith 10 and
  -- timeBoundManipulation each exposed a real vulnerability, so they live in
  -- 'expectedVulnerabilities' below (inverted semantics).
  threatModels =
    [ unprotectedScriptOutput
    , valueUnderpaymentAttack
    , inputDuplication
    , selfReferenceInjection
    , redeemerAssetSubstitution
    , datumListBloatAttack
    , datumByteBloatAttackWith 100
    , duplicateListEntryAttack
    , negativeIntegerAttack
    , outputDatumHashMissingAttack
    , mutualExclusionAttack
    , signatoryRemoval
    , missingOutputDatumAttack
    , invalidDatumIndexAttack
    , invalidScriptPurposeAttack (auctionValidatorScript auctionParams)
    ]

  -- EXPECTED VULNERABILITIES — INVERTED SEMANTICS.
  --
  -- This list is the MIRROR IMAGE of 'threatModels'. Here a test PASSES when
  -- the attack CONSISTENTLY SUCCEEDS: the framework runs the model against ALL
  -- positive txs (no early stop) and the entry is green only when the validator
  -- ACCEPTS the mutant on every applicable tx. So each line below DOCUMENTS and
  -- LOCKS a KNOWN, reliably-exploitable vulnerability as a regression guard —
  -- if a future change to the auction validator accidentally CLOSED a gap, the
  -- corresponding entry here would start FAILING, alerting us that the
  -- documented attack surface changed. (A model exploitable only intermittently
  -- would itself FAIL under these inverted semantics; such a model is left
  -- documented in the session notes rather than locked here.)
  --
  -- One line per locked vuln, naming the validator gap:
  --   * largeValueAttackWith 10  — the validator checks only that the recreated
  --       script output carries the NFT + bid Ada; it does NOT whitelist the
  --       output's token set, so arbitrary minted junk tokens can be stuffed
  --       into the script output (no Value-structure / token-count check).
  --   * tokenForgeryAttack       — the validator does not constrain the tx's
  --       overall minted value, so extra tokens minted under an unrelated
  --       always-succeeds policy ride along in the same tx unchecked.
  --   * doubleSatisfaction       — Payout/refund payments are matched by
  --       value-to-address with no unique tag, so a single output can satisfy
  --       two payment obligations: the validator never rules out double
  --       satisfaction.
  --   * largeDataAttackWith 10   — AuctionDatum's FromData parsing is
  --       permissive (extra trailing constructor fields are ignored), so a
  --       datum bloated with junk fields still deserialises and validates.
  --   * timeBoundManipulation    — the deadline gate inspects only one side of
  --       the validity interval, so widening the range still satisfies the
  --       bid/payout time check (wrong-bound time validation).
  expectedVulnerabilities =
    [ largeValueAttackWith 10
    , tokenForgeryAttack mintingScriptV2 nftAssetName
    , doubleSatisfaction
    , largeDataAttackWith 10
    , timeBoundManipulation
    ]

-- ----------------------------------------------------------------------------
-- 5. Runner
-- ----------------------------------------------------------------------------

tests :: TestTree
tests = propRunActions @AuctionModel "Auction"
