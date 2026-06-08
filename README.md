# testing-interface skill trial

This branch is a trial run of the `testing-interface` skill — a phase-aware agent workflow that builds and maintains a `convex-testing-interface` property-test suite for Cardano contracts.

## Trial subject

**Vesting** — a parameterized PlutusV3 spending validator that locks funds under a script address on a two-tranche schedule. Each tranche has a vest date and an amount. To withdraw, a transaction must (OSM) be signed by the owner, and (IRV) re-lock enough value so the amount remaining at the script is at least the sum of the not-yet-vested tranche amounts (a tranche counts as vested once the tx validity range starts after its date). Datum and redeemer are both unit `()`. The contract itself is unremarkable; it exists here as test material for the skill.

## Agent

| Field | Value |
|---|---|
| Model | claude-opus-4-8 |
| ID | `anthropic/claude-opus-4-8` |
| Mode | Agent Workflow (orchestrator) |
| Date | 2026-06-08 |

## Calibration — user profile

Asked at the Fresh phase. Each profile changes verbosity and default threat-model count:

| Profile | Meaning | Effect |
|---|---|---|
| Author | Building the contract themselves. | Skips blueprint, fast loops, conservative defaults. |
| Auditor | Reviewing someone else's contract. | Full threat menu, thorough confirms, shows diffs. |
| Explorer | Learning the framework. | Blueprint first, explained step-by-step, conservative. |

**Pick: Explorer** — the skill showed the onboarding blueprint, explained each method as it was written, and implemented one action at a time with a green build between each.

## Calibration — threat model approach

| Approach | Meaning |
|---|---|
| Conservative defaults | Agent picks ~5 safe models without per-model discussion. |
| Walk through each | Agent discusses each model choice before wiring it. |

**Pick: Figure it out** — the skill decided based on user profile (Explorer) and contract shape. Walked the decision tree internally, proposing models tailored to the Vesting contract's characteristics (continuation re-lock output, owner signature check, IRV value + time gate; unit datum so datum-shape attacks mostly skip).

## Decisions across the session

| # | Question | Options | Pick |
|---|---|---|---|
| 1 | New to convex-testing-interface, or just need me to get on with it? | Quick intro first / Skip, just work / Figure it out | Quick intro first |
| 2 | Are you the author of this contract, an auditor reviewing it, or learning the framework? | Author / Auditor / Explorer | Explorer |
| 3 | Should I propose the conservative threat-model set or walk through each? | Propose conservative set / Walk through each / Figure it out | Figure it out |
| 4 | How should we model the passage of time so tranches can vest? | Explicit PassTranche actions / Fold time into Withdraw / Figure it out | Figure it out |
| 5 | Shall I proceed with the cabal pin and test-suite skeleton? | Proceed / Let's discuss | Proceed |
| 6 | The two failing threat models look like false positives. How should I handle them? | Drop both / Move to expectedVulnerabilities / Keep wired (red) / Investigate deeper | Move to expectedVulnerabilities |
| 7 | A specific seed exposed a negative-test failure. (See "Seed-specific negative failure" below.) | Triage and repair | Repaired generator (ledger-envelope fix) |

## Phase progression

| Phase | What the skill drove |
|---|---|
| Fresh | Phase-0 probe, intro gate, calibration |
| Fresh → Setup-done | Contract discovery → `cabal.project` pin + test stanza → `Spec.hs` → build |
| Setup-done → Implemented | Model → `TestingInterface` with `Lock` + `PassTranche1` + `PassTranche2` + `Withdraw` → green, implemented one action at a time |
| Implemented (first run) | Model-bug fix: precondition was too tight (`amount <= locked` had no on-chain counterpart) |
| Implemented → Threat-models-wired | 7 tailored threat models wired and run |
| Threat-models-wired | 2 failing models adjudicated as false positives → moved to `expectedVulnerabilities`; suite 9/9 green |
| Red-repair | A specific QuickCheck seed exposed a generator bug (ledger-malformed `Withdraw`); fixed in `arbitraryAction` |
| Red-repair → Green-maintenance | `largeDataAttack` no longer fits `expectedVulnerabilities` after the seed fix → dropped; suite fully green at 8/8 |

## Key design decisions

- **Deployment is an action** — `Lock` in the Action GADT (`lockVesting` of tranche1 + tranche2 at the script address with the captured script `TxIn`), not hidden in `initialize`. `initialize` is model-only: zero state, `modelInitialized = False`, no chain calls.
- **Generator stays dumb** — `Withdraw` emitted with the `signed` flag straddling {True, False} and amounts swept across the IRV boundary; `precondition` does the semantic gating (OSM via `signed`, IRV via re-lock vs `expectedRemaining`). This is what feeds the negative channel.
- **Time as explicit actions** — `PassTranche1` / `PassTranche2` advance the mockchain clock via `setPOSIXTime` and flip model flags (`PassTranche2` sets both, since reaching the later date implies the earlier is past). The model flags are the source of truth for vesting; `Withdraw` derives its tx validity-range lower bound from them so the on-chain IRV time check agrees with the model.
- **Fixed VestingParams as module constants** — one vesting config pinned for the suite (owner = `w1`, two tranche dates/amounts); `ownerPubKeyHash` derived from the owner wallet's verification key hash so the model owner equals the script's `vpOwner`.
- **Model↔chain mirror** — model and validator rules stay in sync; disagreement = bug. The first run's "too-tight precondition" was caught exactly this way and fixed in the model, not the contract.
- **`expectedVulnerabilities`** — `TimeBoundManipulation` (IRV time check is a lower-bound floor the mutation only tightens) and `LargeData` (validator ignores the unit datum) listed as benign-accepted mutations rather than dropped silently.

## First green run — model bug caught by the mirror

The very first `propRunActions` run failed on the negative channel and the model↔chain mirror pinned it immediately: the `precondition` carried an over-tight `amount <= modelLocked` clause that has **no on-chain counterpart** — the validator only enforces OSM + IRV, and a fully-vested owner is allowed to sweep everything. Fix (model side, contract untouched): mirror `perform`'s clamped re-lock with `max 0 (modelLocked - amount) >= expectedRemaining`. Both channels then went green (Positive 100 OK, Negative 100 OK, 424 discarded).

## Threat models — green at 9/9

The conservative decision-tree set was wired: `unprotectedScriptOutput`, `valueUnderpaymentAttack`, `signatoryRemoval`, `timeBoundManipulation`, `doubleSatisfaction`, `inputDuplication`, `largeDataAttackWith 10`. The three core guards the contract claims were confirmed held — `signatoryRemoval` (OSM), `valueUnderpaymentAttack` (IRV value), `unprotectedScriptOutput` (continuation re-lock) all PASS. `doubleSatisfaction` and `inputDuplication` SKIP (never applicable — this contract never confuses payouts across script inputs). `timeBoundManipulation` and `largeDataAttackWith 10` FAILed on benign full-re-lock/no-withdraw transactions; analysis showed both are false positives (the unit datum is ignored; the IRV time check is a lower-bound floor), so per the user's call they were moved to `expectedVulnerabilities` — where, under inverted semantics, both passed (consistently-accepted, value-neutral mutations). Suite: 9/9 green.

```
vesting tests
  Vesting
    Positive tests:                                OK
      +++ OK, passed 100 tests.
    Negative tests:                                OK
      +++ OK, passed 100 tests.
    Threat models
      Unprotected Script Output:                   OK
        Tested 72/100 transactions
      Value Underpayment Attack (50.0% reduction): OK
        Tested 100/100 transactions
      Signatory Removal:                           OK
        Tested 100/100 transactions
      Double Satisfaction:                         OK (skipped)
      Input Duplication:                           OK (skipped)
    Expected vulnerabilities
      Time Bound Manipulation (slot 0):            OK
        Vulnerability detected (100/100 transactions)
      Large Data Attack (max 10 fields):           OK
        Vulnerability detected (20/72 transactions, 28 skipped)

All 9 tests passed
Test suite vesting-test: PASS
```

## Seed-specific negative failure

After the suite was green, a specific QuickCheck seed surfaced a negative-test failure that did not reproduce on other seeds. The exact prompt that opened the triage:

> it fails in this case, is about the specific seed i guess because i couldn't rproduce without that seed
>
> ```
> vesting tests
>   Vesting
>     Positive tests:                                OK (4.70s)
>       +++ OK, passed 100 tests.
>     Negative tests:                                FAIL (2.08s)
>       *** Failed! Falsified (after 25 tests):
>       Just Lock
>       Just PassTranche2
>       Just (Withdraw True 7500000)
>       Just PassTranche2
>       Just (Withdraw True 11250000)
>       Just (Withdraw True 5625000)
>       Just (Withdraw True 2812500)
>       Just (Withdraw True 1406250)
>       Just (Withdraw True 703125)
>       Valid prefix failed: ABalancingError (CheckMinUtxoValueError (TxOut (AddressInEra (ShelleyAddressInEra ShelleyBasedEraConway) (ShelleyAddress Testnet (KeyHashObj (KeyHash {unKeyHash = "65a685a77e9117bfb729c0c04530483c26e5ab49ed228dbc1e5fa5c7"})) StakeRefNull)) (TxOutValueShelleyBased ShelleyBasedEraConway (MaryValue (Coin 703125) (MultiAsset (fromList [])))) TxOutDatumNone ReferenceScriptNone) 849070)
>       Use --quickcheck-replay="(SMGen 6314965472026089517 15052571453967905469,24)" to reproduce.
>       Use -p '/Negative tests/' to rerun this test only.
>     Threat models
>       Unprotected Script Output:                   OK
>         Tested 71/100 transactions (29 skipped, 0 errors)
>       Value Underpayment Attack (50.0% reduction): OK
>         Tested 100/100 transactions (0 skipped, 0 errors)
>       Signatory Removal:                           OK
>         Tested 100/100 transactions (0 skipped, 0 errors)
>       Double Satisfaction:                         OK
>         SKIPPED: Precondition never met (0/100 transactions applicable)
>       Input Duplication:                           OK
>         SKIPPED: Precondition never met (0/100 transactions applicable)
>     Expected vulnerabilities
>       Time Bound Manipulation (slot 0):            OK
>         Vulnerability detected (100/100 transactions, 0 skipped, 0 errors)
>       Large Data Attack (max 10 fields):           OK
>         Vulnerability detected (24/71 transactions, 29 skipped, 0 errors)
> ```

### Diagnosis — a generator bug, not a contract bug

The error is `ABalancingError (CheckMinUtxoValueError ... Coin 703125 ...)` at a key address with no datum: an owner-payout / re-lock output of **0.703 ADA — below the ledger min-UTxO floor (~1 ADA)**. After `PassTranche2`, both tranches are vested, so `expectedRemaining = 0` and every signed `Withdraw` is IRV-valid in the model. The generator then walked a repeated-halving chain (`7.5M → 11.25M → 5.625M → 2.8125M → 1.40625M → 703125`), and the final `Withdraw` split a 1.40625M UTxO into two outputs that each land in the forbidden `(0, minAda)` band. The **ledger** rejects the transaction during balancing — before the validator ever runs.

This is the classic "generator emits ledger-malformed candidates" row of the failure-mode matrix. `precondition` mirrors only the validator's OSM/IRV rules; it knows nothing about min-UTxO, so the framework treated the step as a valid prefix and expected acceptance → **"Valid prefix failed."** min-UTxO is a **ledger** rule, not an OSM/IRV rule — so the fix belongs in `arbitraryAction` (the "stay inside the ledger envelope" property of the beam metaphor), **not** in the contract and **not** in the precondition's semantic mirror.

### The fix

`arbitraryAction` now only emits `Withdraw` candidates that are ledger-safe: every owner-payout and re-lock output is either exactly `0` (full sweep, no re-lock output) or `>= minUtxoLovelace (2_000_000)`; the partial-withdrawal region is `[minUtxo, L - minUtxo]`; and `Withdraw` is only generated when `modelLocked >= minUtxo` (which also kills the infinite-halving recursion). The negative channel is preserved and stays ledger-safe: OSM negatives via `signed = False` on a well-formed amount, IRV negatives via a full sweep when a tranche is not yet vested (re-lock 0 < expectedRemaining → validator rejects, ledger is happy). The contract under `lib/` was not touched.

### Result — repaired and seed-robust

The replayed seed `(SMGen 6314965472026089517 15052571453967905469,24)` now passes, and at 500 tests both channels are green and alive: **Positive 500 OK, Negative 500 OK (1660 discarded, ~3.3:1)**, with the negative channel still exercising unsigned (OSM) and full-sweep (IRV) rejections.

One honest consequence surfaced and was **not** forced green: widening the positive distribution produces some valid `Withdraw`s with small re-lock outputs (near 2 ADA). When `largeDataAttackWith 10` (parked in `expectedVulnerabilities`) inflates the datum on such an output, the datum's bytes push the output's min-UTxO requirement above its coin, so the **ledger** rejects the mutation. The attack is therefore no longer *consistently* accepted, so the inverted `expectedVulnerabilities` check failed. This is a min-UTxO ledger artifact of the datum-bloat-vs-output-size interaction, **not** a contract finding — the validator still ignores the datum entirely. We resolved it by dropping `largeDataAttack` (see the next section); `timeBoundManipulation` continues to pass 500/500 in `expectedVulnerabilities`.

---

## Final resolution — dropping `largeDataAttack`, and why it flipped

**What we did.** We removed `largeDataAttackWith 10` from `expectedVulnerabilities` entirely (it was already out of `threatModels`). `timeBoundManipulation` stays in `expectedVulnerabilities`. No contract code under `lib/` was touched. The suite is now **fully green at 8/8**, stable across 500 tests.

```
vesting tests
  Vesting
    Positive tests:                                OK
      +++ OK, passed 500 tests.
    Negative tests:                                OK
      +++ OK, passed 500 tests (1703 discarded).
    Threat models
      Unprotected Script Output:                   OK
        Tested 424/500 transactions
      Value Underpayment Attack (50.0% reduction): OK
        Tested 500/500 transactions
      Signatory Removal:                           OK
        Tested 499/500 transactions
      Double Satisfaction:                         OK (skipped)
      Input Duplication:                           OK (skipped)
    Expected vulnerabilities
      Time Bound Manipulation (slot 0):            OK
        Vulnerability detected (500/500 transactions)

All 8 tests passed
Test suite vesting-test: PASS
```

### Why `largeDataAttack` "penetrated" before, and shows nothing now (LLM analysis)

The most important point first: **the validator never changed.** It ignores the unit (`()`) datum byte-for-byte in both states. So the flip from *vulnerability-detected* to *not-detected* is a property of the **test's transaction shapes**, not of the contract. The mechanism:

- `largeDataAttack` takes a successful transaction, **bloats the inline datum** on a script output, and resubmits. Under the inverted `expectedVulnerabilities` semantics, it only "passes" (i.e. registers as a stable vulnerability) if the mutated transaction is **consistently accepted** across the positive suite.
- A larger datum raises that output's **min-UTxO requirement** — on Cardano, min-UTxO is proportional to the serialized size of the output, and the datum is part of that size. So inflating the datum makes the output *cost more ADA to be valid*.
- **Before the seed-repair:** the old generator had no min-UTxO discipline, so re-lock outputs were comfortably large. The fatter datum raised their min-UTxO, but those outputs carried more than enough ADA to absorb the increase. The ledger accepted the mutated tx, and the validator (ignoring the datum) accepted it too → **consistently accepted → "Vulnerability detected."**
- **After the seed-repair:** the ledger-envelope fix deliberately produces *small* re-lock outputs sitting right at the ~2 ADA floor. Inflating the datum on one of those pushes its required min-UTxO **above the coin it actually carries**, so the **ledger** (not the validator) rejects the mutated tx during balancing → **not consistently accepted → the inverted check fails.**

So the original "penetration" was never measuring a contract weakness. It was measuring *"are the script outputs large enough to absorb a fatter datum?"* — a fact about the value distribution the generator happened to produce, entirely orthogonal to the validator's logic. That is exactly why `largeDataAttack` fits **neither** list for this contract: in `threatModels` it behaves inconsistently (ledger sometimes rejects, sometimes not), and in `expectedVulnerabilities` it is no longer a *stable* acceptance. It would be a meaningful attack only against a contract that actually **reads and trusts** its datum. For a unit-datum vesting validator, dropping it is the correct and honest resolution.

**Takeaway:** a threat-model verdict is only as meaningful as the transaction population it runs against. A change in the generator's value distribution can flip an `expectedVulnerabilities` result without any change to the contract — which is a feature, not a bug: it forces you to ask whether the "vulnerability" was ever about the validator at all.

---
