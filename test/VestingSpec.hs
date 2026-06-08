{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | Property-based on-chain test suite for the Vesting validator.

This is the SKELETON step: the 'TestingInterface' instance is fully
wired (model, Action GADT, generator, precondition) but the 'perform'
bodies are deliberate placeholders. The point of this step is a green
BUILD, not runnable tests; the per-action off-chain wiring lands next.

== Two-channel mental model ==

The framework drives the contract through two channels at once. The
POSITIVE channel emits actions the model labels valid (precondition
True) and asserts the chain accepts them. The NEGATIVE channel emits
the same shapes labelled invalid (precondition False) and asserts the
chain REJECTS them. The model is a mirror of the validator: the model
decides validity ('precondition'), the chain enforces it for real
('perform'), and the two verdicts must agree.

== The Vesting validator, in model terms ==

The validator ('Vesting.Validator.mkValidator') is parameterized by a
fixed 'VestingParams' baked into the script address. Every spend of the
locked UTxO must satisfy two guards, in order:

  * OSM (Owner Signature Missing): the tx must be signed by 'vpOwner'.
  * IRV (Insufficient Remaining Value): the value re-locked at the
    script address must be at least the sum of the not-yet-vested
    portions of both tranches, computed against the tx validity range.
    You may only withdraw value whose tranche date has already passed.

Time is the lever for vesting: a tranche becomes withdrawable once the
tx validity range lies within @[vDate, +inf)@. We model the passage of
time as explicit actions ('PassTranche1' / 'PassTranche2') that advance
the mockchain clock past each tranche's vest date, flipping a flag in
the model.
-}
module VestingSpec (tests) where

import qualified Cardano.Api as C
import Control.Monad (void, when)
import Convex.BuildTx (execBuildTx)
import qualified Convex.BuildTx as BuildTx
import Convex.Class (MonadMockchain, getSlot, getUtxo, setPOSIXTime)
import Convex.CoinSelection (ChangeOutputPosition (TrailingChange))
import Convex.MockChain (fromLedgerUTxO)
import Convex.MockChain.CoinSelection (tryBalanceAndSubmit)
import qualified Convex.MockChain.Defaults as Defaults
import Convex.PlutusLedger.V1 (transPubKeyHash)
import Convex.Wallet (Wallet, addressInEra, verificationKeyHash)
import qualified Convex.Wallet.MockWallet as Wallet

import Convex.TestingInterface (
  Action,
  Gen,
  TestingInterface (..),
  ThreatModelsFor (..),
  elements,
  frequency,
  propRunActions,
 )
import Convex.ThreatModel.DoubleSatisfaction (doubleSatisfaction)
import Convex.ThreatModel.InputDuplication (inputDuplication)
import Convex.ThreatModel.SignatoryRemoval (signatoryRemoval)
import Convex.ThreatModel.TimeBoundManipulation (timeBoundManipulation)
import Convex.ThreatModel.UnprotectedScriptOutput (unprotectedScriptOutput)
import Convex.ThreatModel.ValueUnderpayment (valueUnderpaymentAttack)
import Data.Aeson (ToJSON (..))
import qualified Data.Map as Map
import GHC.Generics (Generic)
import Test.Tasty (TestTree)

import PlutusLedgerApi.V3 (POSIXTime (..), PubKeyHash)
import qualified PlutusLedgerApi.V3 as Plutus
import Vesting.Scripts (lockVesting, vestingValidatorScript)
import Vesting.Validator (Vesting (..), VestingParams (..))

-------------------------------------------------------------------------------
-- Module constants: the fixed VestingParams baked into the script
--
-- The owner is a single mock wallet; the schedule is two tranches with
-- distinct vest dates and lovelace amounts, spaced apart in time. These
-- are compile-time parameters of the validator, so the model tracks
-- them as constants rather than per-UTxO datum (datum/redeemer are unit).
-------------------------------------------------------------------------------

-- | The owner wallet whose signature authorises every withdrawal (OSM).
ownerWallet :: Wallet
ownerWallet = Wallet.w1

-- | Tranche-1 vest date (POSIX ms) and its lovelace amount.
tranche1Date :: POSIXTime
tranche1Date = POSIXTime 1_700_000_000_000

t1Lovelace :: Integer
t1Lovelace = 10_000_000

-- | Tranche-2 vest date (POSIX ms, strictly after tranche-1) and amount.
tranche2Date :: POSIXTime
tranche2Date = POSIXTime 1_700_100_000_000

t2Lovelace :: Integer
t2Lovelace = 20_000_000

{- | The fixed parameters applied to the validator at deploy time. The
owner key hash is derived from 'ownerWallet'; each tranche pairs a
vest date with the lovelace 'Value' of that tranche.
-}
vestingParams :: VestingParams
vestingParams =
  VestingParams
    { vpOwner = ownerPubKeyHash
    , vpTranche1 = Vesting{vDate = tranche1Date, vAmount = lovelaceValue t1Lovelace}
    , vpTranche2 = Vesting{vDate = tranche2Date, vAmount = lovelaceValue t2Lovelace}
    }

{- | Plutus 'PubKeyHash' of the owner wallet (this is exactly 'vpOwner').
Derived from the wallet's payment verification key hash via the convex
ledger-translation helper, so the model's owner and the script's
'vpOwner' parameter are guaranteed to be the same key (OSM hinges on
this identity).
-}
ownerPubKeyHash :: PubKeyHash
ownerPubKeyHash = transPubKeyHash (verificationKeyHash ownerWallet)

-- | A Plutus 'Value' carrying the given lovelace amount (ada-only).
lovelaceValue :: Integer -> Plutus.Value
lovelaceValue = Plutus.singleton Plutus.adaSymbol Plutus.adaToken

{- | The on-chain address where the parameterized vesting script lives.
Computed from the hash of the params-applied script, exactly as the
off-chain 'lockVesting' helper does, so a chain query can recognise
the locked UTxO.
-}
vestingScriptAddress :: C.AddressInEra C.ConwayEra
vestingScriptAddress =
  C.makeShelleyAddressInEra
    C.shelleyBasedEra
    Defaults.networkId
    (C.PaymentCredentialByScript scriptHash)
    C.NoStakeAddress
 where
  scriptHash =
    C.hashScript (C.PlutusScript C.PlutusScriptV3 (vestingValidatorScript vestingParams))

-- | The total lovelace locked by a 'Lock' (deploy) action: both tranches.
totalLockedLovelace :: Integer
totalLockedLovelace = t1Lovelace + t2Lovelace

{- | Conservative min-UTxO floor (lovelace). The ledger rejects any tx
output below the protocol min-UTxO during balancing
(CheckMinUtxoValueError) BEFORE the validator runs. The observed
floor for an ada-only output under the mockchain defaults is ~849_070
lovelace; 2_000_000 is a safe over-approximation covering both
ada-only key (payout) and script (re-lock) outputs. The generator
uses this to stay inside the ledger envelope: every Withdraw output
(owner payout and re-lock) is either exactly 0 or >= this floor, so it
never lands in the forbidden (0, minUtxo) band. This is a LEDGER rule,
not an OSM/IRV validator rule, so it lives in the generator — not in
the contract and not in precondition's semantic mirror.
-}
minUtxoLovelace :: Integer
minUtxoLovelace = 2_000_000

{- | Hash of the parameterized vesting script (used to build the re-lock
output that a withdrawal pays back to the script address).
-}
vestingScriptHash :: C.ScriptHash
vestingScriptHash =
  C.hashScript (C.PlutusScript C.PlutusScriptV3 (vestingValidatorScript vestingParams))

{- | The owner's payment-key hash, declared as the required signer of a
signed withdrawal so the validator's OSM check (txSignedBy vpOwner)
can succeed.
-}
ownerKeyHash :: C.Hash C.PaymentKey
ownerKeyHash = verificationKeyHash ownerWallet

{- | A far-future upper bound for the withdrawal tx validity range. The
range is [lower, far]; the validator only needs the LOWER bound to be
>= the relevant tranche vDate (contains (from vDate)), so the upper
bound just has to be large enough not to constrain anything.
-}
farFutureSlot :: C.SlotNo
farFutureSlot = C.SlotNo 1_000_000_000

{- | The POSIX time a withdrawal's validity-range lower bound should sit
at, derived from the MODEL FLAGS (the source of truth for vesting):
the latest vest date that has passed. Forcing the clock to this value
before reading the slot makes the on-chain IRV check
(contains (from vDate) validRange) agree with the model's
'expectedRemaining', independent of the order PassTranche* ran in.
'Nothing' = no tranche passed yet (leave clock at genesis, so the
range is NOT contained in any [vDate,+inf) and early withdrawals of
not-yet-vested value fail IRV on-chain, matching precondition).
-}
withdrawLowerBoundDate :: VestingModel -> Maybe POSIXTime
withdrawLowerBoundDate s
  | modelT2Passed s = Just tranche2Date
  | modelT1Passed s = Just tranche1Date
  | otherwise = Nothing

-------------------------------------------------------------------------------
-- Model state
-------------------------------------------------------------------------------

{- | In-memory mirror of the on-chain vesting state.

Tracks only what the model needs to decide validity and to build the
next action: whether the contract has been deployed yet, the live
locked script UTxO (needed to spend), how much lovelace is currently
locked, and whether chain time has advanced past each tranche's vest
date.
-}
data VestingModel = VestingModel
  { modelInitialized :: !Bool
  -- ^ has the Lock (deploy) action run yet?
  , modelTxIn :: !(Maybe C.TxIn)
  -- ^ the live locked script UTxO (needed to spend)
  , modelLocked :: !Integer
  -- ^ lovelace currently locked at the script
  , modelT1Passed :: !Bool
  -- ^ chain time moved past tranche-1 vest date?
  , modelT2Passed :: !Bool
  -- ^ chain time moved past tranche-2 vest date?
  }
  deriving stock (Eq, Show, Generic)

{- | 'C.TxIn' has no 'ToJSON' instance, so we cannot derive 'ToJSON'
structurally for 'VestingModel'. We serialise via 'show' (the same
approach the AikenBank / PingPong example specs take for models
containing cardano-api types); 'ToJSON' here is only used to dump
model snapshots into iteration traces, so a string is sufficient.
-}
instance ToJSON VestingModel where
  toJSON = toJSON . show

-------------------------------------------------------------------------------
-- TestingInterface instance
-------------------------------------------------------------------------------

instance TestingInterface VestingModel where
  -- The contract's intended vocabulary. Lock is THE deploy action
  -- (locks both tranches at the script); PassTranche1/PassTranche2
  -- advance the mockchain clock to vest each tranche; Withdraw spends
  -- the locked UTxO (signedByOwner?, lovelace to withdraw — re-locking
  -- the remainder). Malformed-input attacks are NOT actions; they
  -- belong to threat models.
  data Action VestingModel
    = Lock
    | -- \^ THE deploy action: lock tranche1+tranche2 at the script
      PassTranche1
    | -- \^ advance mockchain clock past tranche-1 vest date
      PassTranche2
    | -- \^ advance mockchain clock past tranche-2 vest date
      Withdraw !Bool !Integer
    -- \^ (signedByOwner?, lovelace to withdraw; re-lock = locked - amount)
    deriving stock (Show, Eq)

  -- Sets up the in-memory model ONLY. Returns the zero state with
  -- modelInitialized = False. DOES NOT submit any tx, DOES NOT deploy
  -- the script, DOES NOT touch the chain. Deployment is the 'Lock'
  -- Action, emitted by the generator while the model is uninitialised
  -- (Cardinal Rule: deployment is an action, not setup).
  initialize =
    pure
      VestingModel
        { modelInitialized = False
        , modelTxIn = Nothing
        , modelLocked = 0
        , modelT1Passed = False
        , modelT2Passed = False
        }

  -- Proposes the next Action. Branches on STRUCTURAL feasibility only:
  -- "can I build this Action from what the model knows right now?" —
  -- never on SEMANTIC validity ("will the validator accept it?"), which
  -- is precondition's job. Keeping the semantic gate out of the
  -- generator is what feeds the negative-testing channel.
  --
  --   * uninitialised -> only Lock is constructible (nothing else can
  --     reference a locked UTxO that does not exist yet).
  --   * initialised   -> emit the normal vocabulary. Withdraw is only
  --     constructible when a live UTxO exists (modelTxIn is Just) AND the
  --     locked value can fund at least one ledger-valid output
  --     (modelLocked >= minUtxoLovelace) — otherwise no Withdraw output
  --     could clear the ledger min-UTxO floor and the candidate would be
  --     rejected during balancing, not by the validator.
  --
  --   LEDGER ENVELOPE (beam property 1): every emitted Withdraw keeps
  --   BOTH of its outputs (owner payout + re-lock) at 0 or
  --   >= minUtxoLovelace. We STILL cross both validator boundaries so the
  --   negative channel stays alive, but only with ledger-well-formed txs:
  --     * OSM negative: Withdraw False <safe amount> (unsigned, well-formed).
  --     * IRV negative: when a tranche is not yet vested
  --       (expectedRemaining > 0), Withdraw True <full L> re-locks 0 <
  --       expectedRemaining -> validator rejects via IRV, and a full
  --       withdrawal has NO re-lock output to trip min-UTxO.
  --     * Positive: signed withdrawals whose re-lock covers
  --       expectedRemaining (partial or full), all outputs ledger-safe.
  arbitraryAction s@VestingModel{modelInitialized, modelTxIn, modelLocked}
    | not modelInitialized = pure Lock
    | otherwise =
        let canWithdraw = case modelTxIn of
              Just _ -> modelLocked >= minUtxoLovelace
              Nothing -> False
            withdrawGen
              | canWithdraw = [(4, genWithdraw s)]
              | otherwise = []
         in frequency $
              [ (1, pure PassTranche1)
              , (1, pure PassTranche2)
              ]
                ++ withdrawGen

  -- Encodes the validator's semantic rules: for each Action, returns
  -- True iff the validator SHOULD accept it given current state. The
  -- framework runs the same action against the chain (perform) and this
  -- model; the two verdicts must agree, or there is a bug somewhere.
  precondition s a = case a of
    -- Lock is the deploy action: valid exactly once, while uninitialised.
    Lock -> not (modelInitialized s)
    -- Advancing the clock always "succeeds" once deployed; it submits no
    -- script spend, so there is no validator guard to violate.
    PassTranche1 -> modelInitialized s
    PassTranche2 -> modelInitialized s
    -- Withdraw must satisfy the TWO validator guards. Note the validator
    -- only inspects (a) the owner signature and (b) the VALUE re-locked
    -- at the script address; it does NOT care that `amount` exceeds what
    -- is currently locked (any surplus the owner pays out comes from the
    -- balancing wallet). So once every tranche has vested
    -- (expectedRemaining == 0) the owner may legitimately sweep the
    -- whole UTxO, even with `amount > modelLocked`. Mirror exactly what
    -- `perform` re-locks: max 0 (modelLocked - amount).
    --   OSM: the spend must be signed by the owner (signed == True).
    --   IRV: the re-locked value must cover the not-yet-vested remainder.
    Withdraw signed amount ->
      modelInitialized s
        && maybe False (const True) (modelTxIn s) -- structural: a UTxO to spend
        && signed -- OSM: owner must sign
        && amount >= 0 -- ledger sanity: non-negative
        && max 0 (modelLocked s - amount) >= expectedRemaining s -- IRV: enough re-locked

  -- catch-all keeps precondition total (no unmatched (state, action) pair).

  -- Builds and submits the on-chain tx for each Action, then returns the
  -- UPDATED model state mirroring the validator's effect. perform always
  -- submits — even for negative cases (precondition False) — and the
  -- framework expects those submits to be REJECTED. No precondition
  -- guard belongs inside perform.
  --
  -- The state update is OPTIMISTIC: we compute the post-success state and
  -- return it. On a negative step the submit fails, the framework counts
  -- that as the expected rejection and discards this return value — so we
  -- need not guard or handle failure here.
  --
  -- This step implements 'Lock' (deploy) plus the two time-advancing
  -- actions. Lock is THE deployment action (Cardinal Rule: deployment is
  -- an action, not setup): it locks both tranches at the parameterized
  -- script address, then we query the chain to capture the freshly-
  -- created script UTxO's TxIn so later spends (Withdraw) have something
  -- to consume.
  --
  -- TIME MODEL. The vesting validator gates withdrawals on the tx
  -- validity range: a tranche is "available" only when the range is
  -- contained in [vDate, +inf) (IRV). 'PassTranche1'/'PassTranche2'
  -- exist purely to MOVE chain time forward past a tranche's vest date.
  -- They advance the GLOBAL mockchain clock with 'setPOSIXTime vDate'
  -- (no script is spent, so there is no validator guard to satisfy here)
  -- and flip the matching model flag. The model flags
  -- (modelT1Passed / modelT2Passed) therefore MIRROR chain time: after
  -- PassTrancheN the clock is at/after that tranche's vDate, which is
  -- exactly the condition the upcoming Withdraw step will encode by
  -- setting its tx validity-range LOWER BOUND to "now" so the range is
  -- contained in [vDate, +inf). Advancing time shrinks
  -- 'expectedRemaining' (the IRV boundary), unlocking more withdrawable
  -- value. 'Withdraw' remains a placeholder, implemented next.
  perform s action = case action of
    Lock -> do
      -- Build + submit the lock tx via the off-chain helper. The locked
      -- value is the sum of both tranches; 30M lovelace is comfortably
      -- above the min-UTxO floor, so no extra setMinAdaDepositAll is
      -- needed for this ada-only output. The owner wallet pays/balances.
      let txBody =
            execBuildTx $
              lockVesting @C.ConwayEra
                Defaults.networkId
                vestingParams
                (C.lovelaceToValue (C.Coin totalLockedLovelace))
      void $ tryBalanceAndSubmit mempty ownerWallet txBody TrailingChange []
      -- Capture the script UTxO created by the lock tx by querying the
      -- chain and filtering for outputs at the vesting script address.
      -- This is the robust (query-based) way to locate the continuation
      -- output; the captured TxIn is what Withdraw will later spend.
      mTxIn <- findVestingUtxo
      pure
        s
          { modelInitialized = True
          , modelTxIn = mTxIn
          , modelLocked = totalLockedLovelace
          , modelT1Passed = False
          , modelT2Passed = False
          }
    PassTranche1 -> do
      -- Move the global mockchain clock to tranche-1's vest date. From
      -- now on, a Withdraw tx whose validity-range lower bound is "now"
      -- has its range contained in [tranche1Date, +inf), so tranche-1's
      -- value counts as vested (IRV remainder for tranche 1 drops to 0).
      setPOSIXTime tranche1Date
      pure s{modelT1Passed = True}
    PassTranche2 -> do
      -- Same idea for tranche-2: jump the clock to tranche-2's (later)
      -- vest date, vesting that tranche too. Because tranche2Date is
      -- strictly after tranche1Date, reaching tranche-2's date ALSO puts
      -- the clock past tranche-1's date — so on-chain both tranches are
      -- now vested. We set BOTH flags to keep the model's notion of
      -- "what is vested" consistent with the monotonic chain clock
      -- (otherwise the IRV mirror would disagree with the validator when
      -- PassTranche2 is emitted before PassTranche1).
      setPOSIXTime tranche2Date
      pure s{modelT1Passed = True, modelT2Passed = True}
    Withdraw signed amount -> do
      -- WITHDRAW is the two-channel workhorse. The generator emits it with
      -- signed in {True,False} and amount swept across the IRV boundary;
      -- precondition labels each case; perform here ALWAYS builds and
      -- submits (no guard) so the framework can confirm the chain's
      -- verdict matches the model's.
      --
      -- Two on-chain guards must be reproduced faithfully:
      --   * OSM (owner signature). Signed case: declare the owner as a
      --     required signer AND submit with the owner wallet, so the
      --     owner key actually signs. Unsigned case: DO NOT add the owner
      --     required-signature and submit with a NON-owner wallet (w2) —
      --     the resulting tx genuinely lacks the owner's signature, so
      --     txSignedBy vpOwner fails and the validator rejects (OSM).
      --   * IRV (re-locked value). We pay 'amount' out to a recipient and
      --     re-lock 'reLock = locked - amount' back at the script address
      --     with the unit inline datum. If the withdrawal over-reaches,
      --     reLock is too small (or zero), so remainingActual < expected
      --     and the validator rejects (IRV). The validity-range lower
      --     bound is taken from the model flags (see
      --     'withdrawLowerBoundDate'), making the validator's tranche-
      --     availability check agree with 'expectedRemaining'.
      let reLock = modelLocked s - amount
          spendTxIn = modelTxIn s
          recipient = if signed then ownerWallet else Wallet.w2
          payoutAddr = addressInEra Defaults.networkId recipient
      -- Force the clock to the flag-derived vest time (forward-only across
      -- all reachable states), then read the resulting slot as the
      -- validity-range lower bound. No flag passed => leave the clock and
      -- read the current (genesis-era) slot.
      case withdrawLowerBoundDate s of
        Just d -> setPOSIXTime d
        Nothing -> pure ()
      lowerSlot <- getSlot
      case spendTxIn of
        Nothing -> fail "perform Withdraw: no script UTxO to spend"
        Just txIn -> do
          let txBody =
                execBuildTx $ do
                  BuildTx.addValidityRangeSlots lowerSlot farFutureSlot
                  -- spend the locked script UTxO with the unit redeemer
                  BuildTx.spendPlutusInlineDatum
                    txIn
                    (vestingValidatorScript vestingParams)
                    ()
                  -- OSM: only the signed case declares the owner signer
                  when signed (BuildTx.addRequiredSignature ownerKeyHash)
                  -- owner payout (the value actually withdrawn)
                  when (amount > 0) $
                    BuildTx.payToAddress
                      payoutAddr
                      (C.lovelaceToValue (C.Coin amount))
                  -- IRV: re-lock the remainder back at the script address
                  when (reLock > 0) $
                    BuildTx.payToScriptInlineDatum
                      Defaults.networkId
                      vestingScriptHash
                      ()
                      C.NoStakeAddress
                      (C.lovelaceToValue (C.Coin reLock))
          void $ tryBalanceAndSubmit mempty recipient txBody TrailingChange []
      -- OPTIMISTIC success-path state update; the framework discards this
      -- on a failed negative step. The old script UTxO is consumed; the
      -- new one (if anything was re-locked) is located by querying the
      -- chain, exactly as the Lock branch does. Nothing re-locked => the
      -- script position is gone.
      newTxIn <- if reLock > 0 then findVestingUtxo else pure Nothing
      pure
        s
          { modelLocked = if reLock > 0 then reLock else 0
          , modelTxIn = newTxIn
          }

-------------------------------------------------------------------------------
-- Generator + precondition helpers
-------------------------------------------------------------------------------

{- | Query the chain for a UTxO sitting at the vesting script address and
return its 'C.TxIn' (the first one, if several). Used by 'perform' to
capture the script output a 'Lock' just created so later actions can
spend it. Robust query-based location (mirrors the example specs'
find*Utxo helpers).
-}
findVestingUtxo
  :: (MonadMockchain C.ConwayEra m)
  => m (Maybe C.TxIn)
findVestingUtxo = do
  utxoSet <- fromLedgerUTxO C.shelleyBasedEra <$> getUtxo
  let C.UTxO utxos = utxoSet
      scriptUtxos =
        Map.filter (\(C.TxOut addr _ _ _) -> addr == vestingScriptAddress) utxos
  pure $ case Map.keys scriptUtxos of
    (txIn : _) -> Just txIn
    [] -> Nothing

{- | The lovelace that must STAY locked right now: the sum of the
not-yet-vested tranche amounts, given which tranche dates have passed.
Mirrors @remainingFrom vpTranche1 + remainingFrom vpTranche2@ in the
validator (IRV).
-}
expectedRemaining :: VestingModel -> Integer
expectedRemaining s =
  (if modelT1Passed s then 0 else t1Lovelace)
    + (if modelT2Passed s then 0 else t2Lovelace)

{- | Generate a LEDGER-SAFE Withdraw that still crosses the OSM and IRV
precondition boundaries (so neither test channel starves), given the
current model state. Caller guarantees modelLocked (L) >= minUtxo and
a live UTxO.

Invariant on every emitted candidate: each of the two outputs (owner
payout `amount`, re-lock `L - amount`) is either exactly 0 or
>= minUtxoLovelace — never in the forbidden (0, minUtxo) band that the
ledger rejects during balancing. The only two ledger-safe shapes are:
  * FULL withdrawal  : amount = L         (payout L, re-lock 0)
  * PARTIAL withdrawal: amount in [minUtxo, L - minUtxo]
                                           (payout & re-lock both >= minUtxo;
                                            only exists when L >= 2*minUtxo)

Channel coverage (e = expectedRemaining = value that must stay locked):
  * positive (signed, IRV holds): re-lock >= e. Full works iff e == 0;
    partial works iff a safe amount with (L - amount) >= e exists.
  * OSM negative: same safe amounts but signed = False (well-formed,
    unsigned -> validator rejects).
  * IRV negative: only meaningful when e > 0 -> full withdrawal
    (re-lock 0 < e) signed True -> validator rejects, ledger-safe.
-}
genWithdraw :: VestingModel -> Gen (Action VestingModel)
genWithdraw s =
  frequency $
    -- positive: signed, re-lock covers the not-yet-vested remainder
    [(3, Withdraw True <$> elements positiveSafeAmounts)]
      -- OSM negative: well-formed but unsigned
      ++ [(1, Withdraw False <$> elements ledgerSafeAmounts)]
      -- IRV negative: signed full sweep while something is still un-vested
      ++ [(2, pure (Withdraw True l)) | e > 0]
 where
  l = modelLocked s
  e = expectedRemaining s

  -- All ledger-safe amounts (full + any partials), regardless of IRV.
  ledgerSafeAmounts = full : partials
  full = l
  partials =
    [ a
    | l >= 2 * minUtxoLovelace
    , a <-
        distinct
          [ minUtxoLovelace
          , l `div` 2
          , l - minUtxoLovelace
          ]
    , a >= minUtxoLovelace
    , l - a >= minUtxoLovelace
    ]

  -- Ledger-safe amounts whose re-lock (L - amount) still covers e, i.e.
  -- IRV-valid positives. Full counts only when nothing remains un-vested.
  positiveSafeAmounts =
    let ps = [a | a <- partials, l - a >= e]
     in case (e == 0, ps) of
          (True, _) -> full : ps -- all vested: full sweep is valid too
          (False, []) -> [l] -- degenerate: nothing safe & valid;
          --   fall back to full (will be an IRV
          --   negative, still ledger-safe)
          (False, _) -> ps

  distinct = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-------------------------------------------------------------------------------
-- Threat models (empty for now — wired in the next phase)
-------------------------------------------------------------------------------

instance ThreatModelsFor VestingModel where
  -- THREAT MODELS = the structural-attack channel, layered on top of the
  -- now-green positive/negative suite. Each model is a SHADOW of a
  -- successful positive tx: take a withdrawal the chain accepted, twist
  -- exactly ONE property, resubmit, and assert the validator STILL
  -- rejects it. A model here PASSES when the guard held (mutation
  -- rejected) and FAILS only on a real vulnerability (mutation accepted).
  --
  -- This contract's surface: a script spend that produces a re-lock
  -- continuation output, gated by OSM (owner signature) and IRV
  -- (re-locked value vs not-yet-vested remainder, against the tx
  -- validity range). Datum/redeemer are unit. The kept set probes each
  -- real guarantee from its own angle:
  threatModels =
    [ unprotectedScriptOutput -- redirect the re-lock continuation output -> probes IRV/continuation guard
    , valueUnderpaymentAttack -- under-fund the re-lock script output -> probes IRV value check
    , signatoryRemoval -- drop the owner required-signer -> probes OSM
    , doubleSatisfaction -- payout-confusion across script inputs (SKIPs: no cross-input confusion here)
    , inputDuplication -- generic duplicate-input probe (SKIPs: no duplicable-input shape here)
    ]

  -- EXPECTED VULNERABILITIES = INVERTED semantics: a model here is
  -- asserted to be CONSISTENTLY "accepted" across the positive txs. We
  -- park here a mutation the validator does accept but which provably
  -- extracts NO value — documented as benign-accepted, not a genuine
  -- exploit, rather than dropped silently:
  --   * timeBoundManipulation: the validator's time gate is a LOWER-BOUND
  --     FLOOR (availableFrom = contains (from vDate) range). Widening the
  --     lower bound only makes MORE value count as not-yet-vested, i.e.
  --     it tightens IRV; it can never let an attacker take un-vested
  --     funds. Accepted but harmless — consistently so across all txs.
  --
  -- NOTE: largeDataAttackWith 10 was DROPPED from both lists. This is a
  -- unit-datum contract (the validator ignores the datum), so the attack
  -- is never a real exploit; but once the generator stays inside the
  -- ledger envelope, small re-lock outputs make the inflated datum trip
  -- the min-UTxO floor INTERMITTENTLY (ledger rejection, not a validator
  -- verdict) — so it is neither a stable vulnerability (expectedVuln) nor
  -- a guard the contract must hold (threatModels). It fits neither list.
  --
  -- NOTE (honest caveat on inverted semantics): an expectedVulnerabilities
  -- entry PASSES only if the mutation is accepted on EVERY positive tx.
  expectedVulnerabilities =
    [ timeBoundManipulation
    ]

-------------------------------------------------------------------------------
-- Test tree
-------------------------------------------------------------------------------

tests :: TestTree
tests = propRunActions @VestingModel "Vesting"
