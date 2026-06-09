# testing-interface skill trial

This branch is a trial run of the
[`testing-interface`](.claude/skills/testing-interface/SKILL.md) skill
(v2.0.4) — a phase-aware agent workflow that builds and maintains a
`convex-testing-interface` property-test suite for Cardano contracts.

## Trial subject

**PingPong** — a minimal PlutusV3 state-machine validator (Pinged/Ponged/Stopped)
with 6 documented security guards. The contract itself is unremarkable; it
exists here as test material for the skill.

## Agent

| Field  | Value                           |
| ------ | ------------------------------- |
| Model  | deepseek-v4-pro                 |
| ID     | `deepseek/deepseek-v4-pro`      |
| Mode   | Agent Workflow (orchestrator)   |
| Date   | 2026-06-03                      |

## Cost

| Token type          | Count      |
| ------------------- | ---------- |
| Input (cache hit)   | 3,562,368  |
| Input (cache miss)  |   301,178  |
| Output              |    90,453  |
| **Total**           | **3,953,999** |
| USD                 | $0.22      |

## Calibration — user profile

Asked at the Fresh phase. Each profile changes verbosity and default
threat-model count:

| Profile  | Meaning                                                                | Effect                                                |
| -------- | ---------------------------------------------------------------------- | ----------------------------------------------------- |
| Author   | Building the contract themselves.                                      | Skips blueprint, fast loops, conservative defaults.   |
| Auditor  | Reviewing someone else's contract.                                     | Full threat menu, thorough confirms, shows diffs.     |
| Explorer | Learning the framework.                                                | Blueprint first, explained step-by-step, conservative. |

**Pick: Explorer** — the skill showed the onboarding blueprint, explained
each method as it was written, and started with the conservative
threat-model set.

## Calibration — threat model approach

| Approach              | Meaning                                                   |
| --------------------- | --------------------------------------------------------- |
| Conservative defaults | Agent picks ~5 safe models without per-model discussion.  |
| Walk through each     | Agent discusses each model choice before wiring it.       |

**Pick: Conservative defaults** — the skill picked the 5-model starter set
and walked the decision tree for state-machine extras. The user later
opted to max out to all 19 possible models.

## Decisions across the session

| # | Question| Options| Pick|
| - | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------- |
| 1 | New to convex-testing-interface, or just need me to get on with it? | Quick intro first / Skip, just work / Figure it out       | Quick intro first            |
| 2 | Are you the author of this contract, an auditor reviewing it, or learning the framework?| Author / Auditor / Explorer / Figure it out               | Explorer                     |
| 3 | Should I propose the conservative threat-model ? | Conservative defaults / Walk through each / Figure it out | Conservative defaults        |
| 4 | Does this look right? Validator = Scripts.PingPong, test dir = test/, test suite = pingpong-test.| Looks good — proceed / Something off                      | Looks good — proceed         |
| 5 | Does this model design look right? 4 actions, inline-datum only, no wallet tracking… | Looks good — proceed / Tweak something                    | free-text: keep it simple |
| 6 | Start with just Start + PlayRound (2 actions), or keep all 4?| Just Start+PlayRound / Keep all 4                         | Just Start+PlayRound         |
| 7 | Conservative 5 only, or include the 3 state-machine extras (8 total)?| Conservative 5 / All 8                                    | All 8                        |
| 8 | Add all 11 remaining threat models? 2 that'll fire + 9 that'll SKIP?| Add all 11 — let's see                                    | Yes — show me which SKIP     |
| 9 | TimeBoundManipulation failed. Expected vulnerability, leave as failing, or fix the validator?| Expected vulnerability / Leave as failing / Fix validator | Expected vuln with comment   |

## Phase progression

| Phase                     | What the skill drove                                                          |
| ------------------------- | ----------------------------------------------------------------------------- |
| Fresh                     | Phase-0 probe, intro gate, calibration                                       |
| Fresh → Setup-done        | Contract discovery → `cabal.project` pin + test stanza → `Spec.hs` → build    |
| Setup-done → Implemented  | Model → `TestingInterface` with `Start` + `PlayRound` → 200/200 green          |
| Implemented → Threat-models-wired | 19 threat models + 1 expected vulnerability                      |

## Key design decisions

- **Deployment is an action** — `Start` in the Action GADT, not hidden in `initialize`.
- **Generator stays dumb** — `PlayRound` emits all 3 redeemers regardless of state; `precondition` does semantic gating.
- **`expectedVulnerabilities`** — `TimeBoundManipulation` listed as accepted gap (no time logic in PingPong).
- **Model↔chain mirror** — model and validator rules stay in sync; disagreement = bug.

## Final test output

```
PingPong
  Positive tests:                                 OK (7.50s)
    +++ OK, passed 100 tests.
  Negative tests:                                 OK (1.09s)
    +++ OK, passed 100 tests.
  Threat models
    Unprotected Script Output:                    OK  (100/100)
    Double Satisfaction:                          OK  SKIPPED
    Signatory Removal:                            OK  SKIPPED
    Value Underpayment Attack:                    OK  (100/100)
    Invalid Datum Index Attack:                   OK  (100/100)
    Missing Output Datum Attack:                  OK  (100/100)
    Large Value Attack:                           OK  (100/100)
    Input Duplication:                            OK  SKIPPED
    Self-Reference Injection:                     OK  SKIPPED
    Datum Byte Bloat Attack:                      OK  SKIPPED
    Datum List Bloat Attack:                      OK  SKIPPED
    Duplicate List Entry Attack:                  OK  SKIPPED
    Negative Integer Attack:                      OK  SKIPPED
    Output Datum Hash Missing Attack:             OK  (100/100)
    Mutual Exclusion Attack:                      OK  (100/100)
    Redeemer Asset Substitution:                  OK  SKIPPED
    Large Data Attack (1000 fields):              OK  (100/100)
    Invalid Script Purpose Attack:                OK  (100/100)
    Large Data Attack (10 fields):                OK  (100/100)
  Expected vulnerabilities
    Time Bound Manipulation:                      OK  (100/100 confirmed)
```
