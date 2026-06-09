# sc-testing-tools-skill-test

Trial workspace for the `testing-interface` Claude skill — a phase-aware skill that guides an agent to add a `convex-testing-interface` property-test suite to a Cardano contract.

This repo records four contract trials (PingPong, Escrow, Auction, Vesting). **The trial is a control measure.** The central artefacts are the reports captured in each final branch's README — start there.

---

## Trial reports

| Contract | Report                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| PingPong | https://github.com/input-output-hk/sc-testing-tools-skill-test/blob/ping-pong/with-offchain-testing-interface/README.md |
| Escrow   | https://github.com/input-output-hk/sc-testing-tools-skill-test/blob/escrow/with-offchain-testing-interface/README.md    |
| Auction  | https://github.com/input-output-hk/sc-testing-tools-skill-test/blob/auction/with-offchain-testing-interface/README.md   |
| Vesting  | https://github.com/input-output-hk/sc-testing-tools-skill-test/blob/vesting/with-offchain-testing-interface/README.md   |

---

## Branch lineage

```
                       common base (initial scaffold)
                                    │
       ┌─────────────────┬──────────┴──────────┬─────────────────┐
       ▼                 ▼                     ▼                 ▼
  ping-pong/         escrow/              auction/          vesting/
   naked              naked                naked             naked
       │                 │                     │                 │
       ▼                 ▼                     ▼                 ▼
  ping-pong/         escrow/              auction/          vesting/
   with-offchain      with-offchain        with-offchain     with-offchain
       │                 │                     │                 │
       ▼                 ▼                     ▼                 ▼
  ping-pong/         escrow/              auction/          vesting/
   with-offchain-     with-offchain-       with-offchain-    with-offchain-
   skill              skill                skill             skill
       │                 │                     │                 │
       ▼                 ▼                     ▼                 ▼
  ping-pong/         escrow/              auction/          vesting/
   with-offchain-     with-offchain-       with-offchain-    with-offchain-
   testing-interface  testing-interface    testing-interface testing-interface
```

`main` branches off the same common base and only carries this overview README.

---

## How the trial works

Each contract follows the same ladder:

1. **`<contract>/naked`** — validator + script compilation only. The minimum that compiles.
2. **`<contract>/with-offchain`** — adds off-chain helpers (`MonadBuildTx` style).
3. **`<contract>/with-offchain-skill`** — pins the exact skill copy used for the trial. **This is the recommended starting point if you want to run the skill yourself.**
4. **`<contract>/with-offchain-testing-interface`** — the agent ran the skill against the skill-pin branch, produced a TestingInterface, and committed the result.

Each agent run was pointed at a **different source-of-truth branch** of `input-output-hk/sc-testing-tools` so the agent couldn't peek at the canonical TestingInterface for the contract under test. (See "Source-of-truth mapping" below.)

The prompt given to the agent for every trial was:

> You have a skill at `.claude/skills/testing-interface/`. Load it and follow it. Help me work on the property-test suite for the contract in this repo.
>
> Keep a short running log at `./SESSION.md` (phase, last step, open question), append only.

---

## Contract trials

### PingPong
| Stage     | Branch                                                                                                      | What it adds        |
| --------- | ----------------------------------------------------------------------------------------------------------- | ------------------- |
| naked     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/ping-pong/naked                           | validator + scripts |
| offchain  | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/ping-pong/with-offchain                   | off-chain helpers   |
| skill-pin | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/ping-pong/with-offchain-skill             | skill copy pinned   |
| final     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/ping-pong/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-p` of `input-output-hk/sc-testing-tools` (PingPong stripped).

### Escrow
| Stage     | Branch                                                                                                   | What it adds        |
| --------- | -------------------------------------------------------------------------------------------------------- | ------------------- |
| naked     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/escrow/naked                           | validator + scripts |
| offchain  | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/escrow/with-offchain                   | off-chain helpers   |
| skill-pin | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/escrow/with-offchain-skill             | skill copy pinned   |
| final     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/escrow/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-e` (Escrow stripped).

### Auction
| Stage     | Branch                                                                                                    | What it adds        |
| --------- | --------------------------------------------------------------------------------------------------------- | ------------------- |
| naked     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/auction/naked                           | validator + scripts |
| offchain  | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/auction/with-offchain                   | off-chain helpers   |
| skill-pin | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/auction/with-offchain-skill             | skill copy pinned   |
| final     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/auction/with-offchain-testing-interface | TestingInterface    |

Skill pointed at: `chore/without-a` (Auction stripped).

### Vesting
| Stage     | Branch                                                                                                    | What it adds        |
| --------- | --------------------------------------------------------------------------------------------------------- | ------------------- |
| naked     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/vesting/naked                           | validator + scripts |
| offchain  | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/vesting/with-offchain                   | off-chain helpers   |
| skill-pin | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/vesting/with-offchain-skill             | skill copy pinned   |
| final     | https://github.com/input-output-hk/sc-testing-tools-skill-test/tree/vesting/with-offchain-testing-interface | TestingInterface    |

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

This trial is a control measure, not a recipe. An agent rerun will not produce the same output — LLM nondeterminism guarantees that. What you can do is start from the **skill-pin branch** (which holds the exact skill copy that was used) and run your own agent against it. Then compare your result against the corresponding final branch and its report to see whether the skill led you down a similar path.

```bash
git clone https://github.com/input-output-hk/sc-testing-tools-skill-test
cd sc-testing-tools-skill-test
git checkout <contract>/with-offchain-skill
NIX_CONFIG="system = x86_64-linux" nix develop -c cabal build all
```

Then launch a Claude agent in the repo with this prompt:

> You have a skill at `.claude/skills/testing-interface/`. Load it and follow it. Help me work on the property-test suite for the contract in this repo.
>
> When the suite is green, write a short report into the repo `README.md` covering: the model and action set you chose, threat models wired, anything notable that came up while running the skill.

Compare your agent's output against the corresponding `with-offchain-testing-interface` branch and its report.

---

## Testing the results yourself

If you just want to see what the agent produced — build the suite on the final branch and run the property tests.

```bash
git clone https://github.com/input-output-hk/sc-testing-tools-skill-test
cd sc-testing-tools-skill-test
git checkout <contract>/with-offchain-testing-interface
NIX_CONFIG="system = x86_64-linux" nix develop -c cabal build all
NIX_CONFIG="system = x86_64-linux" nix develop -c cabal test all
```

Inspect `test/<Contract>Spec.hs` for the model, action set, generator, precondition, perform, and threat-model list the agent chose. Compare against the final branch's README to read the agent's own write-up.

---

## Layout (per branch)

- `lib/<Contract>/` — Haskell modules (validator, scripts, offchain, sometimes TestingInterface)
- `test/` — appears only on the `with-offchain-testing-interface` branches
- `.claude/skills/testing-interface/` — the skill source (appears on the skill-pin and final branches)
- `flake.nix`, `cabal.project`, `<contract>.cabal` — build wiring
