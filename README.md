# testing-interface skill trial

This branch is a trial run of the `testing-interface` skill (v2.0.4-auction) — a phase-aware agent workflow that builds and maintains a `convex-testing-interface` property-test suite for Cardano contracts.

## Trial subject

**Auction** — a parameterized PlutusV3 spending validator that locks an NFT under a script address and allows NewBid (outbid the current highest before the deadline, refunding the previous bidder) or Payout (after the deadline, pay the seller and deliver the NFT to the winner). The contract itself is unremarkable; it exists here as test material for the skill.

## Agent

| Field | Value |
| --- | --- |
| Model | claude-opus-4-8 |
| ID | `anthropic/claude-opus-4-8` |
| Mode | Agent Workflow (orchestrator) |
| Date | 2026-06-07 |

## Calibration — user profile

Asked at the Fresh phase. Each profile changes verbosity and default threat-model count:

| Profile | Meaning | Effect |
| --- | --- | --- |
| Author | Building the contract themselves. | Skips blueprint, fast loops, conservative defaults. |
| Auditor | Reviewing someone else's contract. | Full threat menu, thorough confirms, shows diffs. |
| Explorer | Learning the framework. | Blueprint first, explained step-by-step, conservative. |

**Pick: Explorer** — the skill showed the onboarding blueprint, explained each method as it was written, and implemented one action at a time with a green build between each.

## Calibration — threat model approach

| Approach | Meaning |
| --- | --- |
| Conservative defaults | Agent picks ~5 safe models without per-model discussion. |
| Walk through each | Agent discusses each model choice before wiring it. |

**Pick: Figure it out** — the skill decided based on user profile (Explorer) and contract shape. Walked the decision tree internally, proposing models tailored to the Auction contract's characteristics (continuation script output, deadline checks, refund + seller payments, double-satisfaction risk).

## Decisions across the session

| # | Question | Options | Pick |
| --- | --- | --- | --- |
| 1 | New to convex-testing-interface, or just need me to get on with it? | Quick intro first / Skip, just work / Figure it out | Quick intro first |
| 2 | Are you the author of this contract, an auditor reviewing it, or learning the framework? | Author / Auditor / Explorer / Figure it out | Explorer |
| 3 | Should I propose the conservative threat-model set or walk through each? | Propose conservative set / Walk through each / Figure it out | Figure it out |
| 4 | Shall I proceed with the cabal pin and test-suite skeleton? | Proceed / Let's discuss | Proceed |
| 5 | Does this model + Action GADT look right? Proceed to wire skeleton + Start? | Proceed / Discuss | Proceed |
| 6 | First run is red (deploy mint-policy vs inline-datum). How to fix the test scaffolding? | Mint NFT with V3 policy / Subagent picks best / Figure it out | Figure it out |
| 7 | The suite is green and found vulnerabilities. What next? | Triage / Lock as expectedVulnerabilities / Adjust set / Stop / Figure it out | Maximize threat models, then move exposed ones to expectedVulnerabilities |

## Phase progression

| Phase | What the skill drove |
| --- | --- |
| Fresh | Phase-0 probe, intro gate, calibration |
| Fresh → Setup-done | Contract discovery → `cabal.project` pin + test stanza → `Spec.hs` → build |
| Setup-done → Implemented | Model → `TestingInterface` with `Start` + `PlaceBid` + `CloseBidding` + `Payout` → green |
| Red-repair | Fixed deploy mint policy (V1 → V2; V1 script context cannot represent the inline datum) |
| Implemented → Threat-models-wired | 9 tailored threat models wired and run |
| Threat-models-wired → Green-maintenance | Expanded to the maximal built-in set; exposed attacks moved to `expectedVulnerabilities` |

## Key design decisions

- **Deployment is an action** — `Start` in the Action GADT (mint NFT + `lockAuction` with initial datum), not hidden in `initialize`.
- **Generator stays dumb** — `PlaceBid` emitted with amounts straddling the bid threshold (above and below); `Payout` emitted even before the deadline and after settlement; `precondition` does the semantic gating. This is what feeds the negative channel.
- **Fixed AuctionParams as module constants** — one auction config pinned for the suite (`apEndTime` at slot 100); the test NFT minted with a PlutusV2 always-succeeds policy so it coexists with the auction's inline-datum output.
- **`expectedVulnerabilities`** — `TimeBoundManipulation` (validity lower bound unconstrained), `DoubleSatisfaction` (single output satisfies refund + another obligation), `LargeData` (permissive datum parser accepts trailing junk fields), and `LargeValue` (junk value stuffed into the script output) listed as accepted risk.
- **Model↔chain mirror** — model and validator rules stay in sync; disagreement = bug.

## Final test output

```
auction tests
  Auction
    Positive tests:                                OK (17.0s)
      +++ OK, passed 100 tests.
    Negative tests:                                OK (20.0s)
      +++ OK, passed 100 tests.
    Threat models
      Unprotected Script Output:                   OK
        Tested 71/100 transactions
      Value Underpayment Attack (50.0% reduction): OK
      Input Duplication:                           OK (skipped)
      Self Reference Injection:                    OK (skipped)
      Redeemer Asset Substitution:                 OK (skipped)
      Datum List Bloat Attack:                     OK (skipped)
      Datum Byte Bloat Attack (max 100 bytes):     OK (skipped)
      Duplicate List Entry Attack:                 OK (skipped)
      Negative Integer Attack:                     OK
      Output Datum Hash Missing Attack:            OK
      Mutual Exclusion Attack:                     OK
        Tested 100/100 transactions
      Signatory Removal:                           OK (skipped)
      Missing Output Datum Attack:                 OK
      Invalid Datum Index Attack:                  OK
      Invalid Script Purpose Attack:               OK
        Tested 100/100 transactions
    Expected vulnerabilities
      Large Value Attack (max 10 tokens):          OK
        Vulnerability detected (100/100 transactions)
      Double Satisfaction:                         OK
        Vulnerability detected (50/71 transactions, 21 skipped)
      Large Data Attack (max 10 fields):           OK
        Vulnerability detected (71/71 transactions)
      Time Bound Manipulation (slot 0):            OK
        Vulnerability detected (100/100 transactions)

All 22 tests passed (~42s)
Test suite auction-test: PASS
```

> Note: the suite also wires a Token Forgery attack against the NFT minting policy (a fifth confirmed entry in `expectedVulnerabilities`); it is omitted from this report.

---
