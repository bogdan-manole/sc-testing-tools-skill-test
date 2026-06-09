# testing-interface skill trial

This branch is a trial run of the [`testing-interface`](.claude/skills/testing-interface/SKILL.md) skill (v2.0.4) — a phase-aware agent workflow that builds and maintains a `convex-testing-interface` property-test suite for Cardano contracts.

## Trial subject

**Escrow** — a minimal PlutusV3 spending validator that locks funds under a script address and allows Redeem (pay targets before deadline) or Refund (contributor reclaims after deadline with signature). The contract itself is unremarkable; it exists here as test material for the skill.

## Agent

| Field | Value |
|---|---|
| Model (steps 1–6) | deepseek-v4-pro |
| Model (steps 7–8) | claude-opus-4-6 |
| ID (steps 1–6) | `deepseek/deepseek-v4-pro` |
| ID (steps 7–8) | `anthropic/claude-opus-4-6` |
| Mode | Agent Workflow (orchestrator) |
| Date | 2026-06-07 |

## Cost

| Token type | Count |
|---|---|
| Input (Cache hit) | 5,778,944 |
| Input (Cache miss) | 212,461 |
| Output | 90,793 |
| **Total** | **6,082,198** |
| USD | $0.20 |

## Calibration — user profile

Asked at the Fresh phase. Each profile changes verbosity and default threat-model count:

| Profile | Meaning | Effect |
|---|---|---|
| Author | Building the contract themselves. | Skips blueprint, fast loops, conservative defaults. |
| Auditor | Reviewing someone else's contract. | Full threat menu, thorough confirms, shows diffs. |
| Explorer | Learning the framework. | Blueprint first, explained step-by-step, conservative. |

**Pick: Explorer** — the skill showed the onboarding blueprint, explained each method as it was written, and started with the conservative threat-model set.

## Calibration — threat model approach

| Approach | Meaning |
|---|---|
| Conservative defaults | Agent picks ~5 safe models without per-model discussion. |
| Walk through each | Agent discusses each model choice before wiring it. |

**Pick: Figure it out** — the skill decided based on user profile (Explorer) and contract shape. Walked the decision tree internally, proposed 5 models tailored to the Escrow contract's characteristics (deadline checks, signatory requirement, target payments, double-satisfaction risk).

## Decisions across the session

| # | Question | Options | Pick |
|---|---|---|---|
| 1 | New to convex-testing-interface, or just need me to get on with it? | Quick intro first / Skip, just work / Figure it out | Quick intro first |
| 2 | Are you the author of this contract, an auditor reviewing it, or learning the framework? | Author / Auditor / Explorer / Figure it out | Explorer |
| 3 | Should I propose the conservative threat-model set or walk through each? | Propose conservative set / Walk through each / Figure it out | Figure it out |
| 4 | Shall I proceed with adding the test stanza and creating test/Spec.hs skeleton? | Proceed with cabal setup / Let's discuss the design | Proceed with cabal setup |
| 5 | Shall I implement the full EscrowSpec with the Action GADT, model, generator, precondition, and perform? | Implement the design / Let's discuss first | Implement the design |
| 6 | Shall I fix the performance by using fixed EscrowParams + cached compiled script? | Proceed with the fix / Let's discuss first | Proceed with the fix |
| 7 | Two vulnerabilities found. How should we handle them? | Add to expectedVulnerabilities / Fix the contract / Both / Figure it out | Add to expectedVulnerabilities |

## Phase progression

| Phase | What the skill drove |
|---|---|
| Fresh | Phase-0 probe, intro gate, calibration |
| Fresh → Setup-done | Contract discovery → `cabal.project` pin + test stanza → `Spec.hs` → build |
| Setup-done → Implemented | Model → `TestingInterface` with `Start` + `Redeem` + `Refund` + `WaitUntilDeadline` → green |
| Red-repair | Fixed deadline generation (mockchain time), fixed performance (CAF-cached script) |
| Implemented → Threat-models-wired | 5 threat models + 2 expected vulnerabilities |

## Key design decisions

- **Deployment is an action** — `Start` in the Action GADT, not hidden in `initialize`.
- **Generator stays dumb** — `Redeem` emitted even past deadline; `Refund` emitted even before deadline; `precondition` does semantic gating.
- **Fixed EscrowParams as CAF** — pre-compiled script evaluated once and shared across all iterations (avoids repeated runtime UPLC lifting). Added `*With` helper variants to `Scripts.hs`.
- **`expectedVulnerabilities`** — `TimeBoundManipulation` (Start tx validity range unconstrained) and `DoubleSatisfaction` (single payout satisfies two spends) listed as accepted risk.
- **Model↔chain mirror** — model and validator rules stay in sync; disagreement = bug.

## Final test output

```
escrow tests
  Escrow
    Positive tests:                                OK (2.82s)
      +++ OK, passed 100 tests.
    Negative tests:                                OK (1.61s)
      +++ OK, passed 100 tests; 18 discarded.
    Threat models
      Signatory Removal:                           OK
        Tested 81/100 transactions (19 skipped, 0 errors)
      Large Data Attack (max 10 fields):           OK
        SKIPPED: Precondition never met (0/100 transactions applicable)
      Value Underpayment Attack (50.0% reduction): OK
        Tested 100/100 transactions (0 skipped, 0 errors)
    Expected vulnerabilities
      Time Bound Manipulation (slot 0):            OK
        Vulnerability detected (100/100 transactions, 0 skipped, 0 errors)
      Double Satisfaction:                         OK
        Vulnerability detected (56/56 transactions, 44 skipped, 0 errors)

All 7 tests passed (4.43s)
Test suite escrow-test: PASS
```
