# sc-testing-tools-skill-test

Trial workspace for the `testing-interface` Claude skill — a phase-aware skill that guides an agent to add a `convex-testing-interface` property-test suite to a Cardano contract.

This repo records four contract trials (PingPong, Escrow, Auction, Vesting). **The trial is a control measure.** The central artefacts are the reports captured in each final branch's README — start there.

---

## Trial reports

| Contract | Report                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| PingPong | https://github.com/bogdan-manole/sc-testing-tools-skill-test/blob/ping-pong/with-offchain-testing-interface/README.md |
| Escrow   | https://github.com/bogdan-manole/sc-testing-tools-skill-test/blob/escrow/with-offchain-testing-interface/README.md    |
| Auction  | https://github.com/bogdan-manole/sc-testing-tools-skill-test/blob/auction/with-offchain-testing-interface/README.md   |
| Vesting  | https://github.com/bogdan-manole/sc-testing-tools-skill-test/blob/vesting/with-offchain-testing-interface/README.md   |

---

## How the trial works

Each contract follows the same ladder:

1. **`<contract>/naked`** — validator + script compilation only. The minimum that compiles.
2. **`<contract>/with-offchain`** — adds off-chain helpers (`MonadBuildTx` style).
3. **`<contract>/with-offchain-testing-interface`** — the agent ran the skill against `with-offchain`, produced a TestingInterface, and committed the result.

For Vesting only, there's an extra intermediate stage `vesting/with-offchain-skill` between the offchain and final branches — it pins the exact skill version used.

Each agent run was pointed at a **different source-of-truth branch** of `input-output-hk/sc-testing-tools` so the agent couldn't peek at the canonical TestingInterface for the contract under test. (See "Source-of-truth mapping" below.)

---

## Contract trials

### PingPong
| Stage    | Branch                                                                                                      | What it adds        |
| -------- | ----------------------------------------------------------------------------------------------------------- | ------------------- |
| naked    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/ping-pong/naked                           | validator + scripts |
| offchain | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/ping-pong/with-offchain                   | off-chain helpers   |
| final    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/ping-pong/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-p` of `input-output-hk/sc-testing-tools` (PingPong stripped).

### Escrow
| Stage    | Branch                                                                                                   | What it adds        |
| -------- | -------------------------------------------------------------------------------------------------------- | ------------------- |
| naked    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/escrow/naked                           | validator + scripts |
| offchain | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/escrow/with-offchain                   | off-chain helpers   |
| final    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/escrow/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-e` (Escrow stripped).

### Auction
| Stage    | Branch                                                                                                    | What it adds        |
| -------- | --------------------------------------------------------------------------------------------------------- | ------------------- |
| naked    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/auction/naked                           | validator + scripts |
| offchain | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/auction/with-offchain                   | off-chain helpers   |
| final    | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/auction/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-a` (Auction stripped).

### Vesting
| Stage     | Branch                                                                                                    | What it adds                          |
| --------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| naked     | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/vesting/naked                           | validator + scripts                   |
| offchain  | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/vesting/with-offchain                   | off-chain helpers                     |
| skill-pin | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/vesting/with-offchain-skill             | pinned skill version for reproduction |
| final     | https://github.com/bogdan-manole/sc-testing-tools-skill-test/tree/vesting/with-offchain-testing-interface | TestingInterface                      |

Skill pointed at: `chore/without-v` (Vesting stripped).

---

## Source-of-truth mapping

| Contract | Source branch (sc-testing-tools)                                         | Why                                            |
| -------- | ------------------------------------------------------------------------ | ---------------------------------------------- |
| PingPong | https://github.com/input-output-hk/sc-testing-tools/tree/chore/without-p | PingPong stripped — agent can't copy canonical |
| Escrow   | https://github.com/input-output-hk/sc-testing-tools/tree/chore/without-e | Escrow stripped                                |
| Auction  | https://github.com/input-output-hk/sc-testing-tools/tree/chore/without-a | Auction stripped                               |
| Vesting  | https://github.com/input-output-hk/sc-testing-tools/tree/chore/without-v | Vesting stripped                               |

Same skill, different source pin per contract.

---

## Running it yourself

This trial is a control measure, not a recipe. An agent rerun will not produce the same output — LLM nondeterminism guarantees that. What you can do is run the skill on the same starting point and compare your result against the report on the final branch to see whether the skill led you down a similar path.

```bash
git clone https://github.com/bogdan-manole/sc-testing-tools-skill-test
cd sc-testing-tools-skill-test
git checkout <contract>/with-offchain
NIX_CONFIG="system = x86_64-linux" nix develop -c cabal test all
```

Then launch a Claude agent in the repo. The skill is at `.claude/skills/testing-interface/`. Compare against the corresponding `with-offchain-testing-interface` branch and its report.

---

## Layout (per branch)

- `lib/<Contract>/` — Haskell modules (validator, scripts, offchain, sometimes TestingInterface)
- `test/` — appears only on the `with-offchain-testing-interface` branches
- `.claude/skills/testing-interface/` — the skill source (variant per contract on the final branches)
- `flake.nix`, `cabal.project`, `<contract>.cabal` — build wiring
