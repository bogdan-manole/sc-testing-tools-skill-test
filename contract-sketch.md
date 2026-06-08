# Contract Sketch — Vesting

Discovery date: 2026-06-08
Phase: Fresh (read-only; no source/cabal edits, no build)

## Package / cabal facts

- **Package name:** `vesting` (single `vesting.cabal`, cabal-version 3.0).
- **Structure:** Library only. No executable, no test-suite. No existing test directory.
- **Exposed modules:** `Vesting.Scripts`, `Vesting.Validator` (in `lib/`).
- **Build wrapper:** nix (`flake.nix` present; `nix/` dir has outputs.nix, pkgs.nix, project.nix, shell.nix, utils.nix). flake.lock present.
- **GHC pin:** `with-compiler: ghc-9.6.6` (cabal.project). flake.nix bootstraps via nixpkgs-2411/ghc945 for haskell.nix.
- **index-state:** hackage.haskell.org 2026-02-09; cardano-haskell-packages 2026-02-09.
- **CHaP:** repository `cardano-haskell-packages` at https://chap.intersectmbo.org/ (with root-keys). flake input `CHaP` from IntersectMBO/cardano-haskell-packages?ref=repo.
- **allow-newer:** `maestro-sdk:containers`.
- **test-show-details:** direct.
- **sc-tools stanza (source-repository-package):**
  - location: https://github.com/input-output-hk/sc-tools.git
  - tag: `c50e9edf2606d149820d41c2d4f82fae54eb21dd`
  - sha256: sha256-aTNDfYbmrFzp+R+lAVlDWPES7EYj3nDiZCeoF7jSBc0=
  - subdirs: src/base, src/coin-selection, src/mockchain, src/node-client, src/optics, src/wallet
  - (provides convex-base, convex-coin-selection, convex-mockchain, convex-node-client, convex-optics, convex-wallet)
- **No forks** beyond the sc-tools source-repository-package above.
- **build-depends (library):** base, cardano-api, convex-base, convex-coin-selection, convex-mockchain, convex-wallet, plutus-ledger-api, plutus-tx, plutus-tx-plugin.
- **Plutus version:** V3 (validator imports `PlutusLedgerApi.V3`; scripts use `PlutusScriptV3`). Plugin target-version 1.1.0.0.

## Validator — `Vesting.Validator`

- **Entry point:** `validator :: VestingParams -> BuiltinData -> BuiltinUnit` = `mkValidator`.
- **Datum type:** unit `()` — supplied as an **inline** datum off-chain (`payToScriptInlineDatum`); the validator ignores it.
- **Redeemer type:** unit `()` — the on-chain code receives a single `BuiltinData` (the ScriptContext) and does not consume a separate redeemer value; off-chain spends with unit redeemer.
- **Parameter type:** `VestingParams` (compile-time, baked into script address; `makeLift`):
  - `vpOwner    :: PubKeyHash`
  - `vpTranche1 :: Vesting`
  - `vpTranche2 :: Vesting`
- **Helper type `Vesting`:**
  - `vDate   :: POSIXTime`  (the date the tranche becomes available / vests)
  - `vAmount :: Value`      (the full amount of the tranche)

### Schedule helpers
- `availableFrom (Vesting d v) range = if (from d) \`contains\` range then v else zero`
  — the tranche's value `v` is **available** (releasable) only once the tx validity range lies entirely within `[d, +inf)`; otherwise `zero`.
- `remainingFrom t range = vAmount t - availableFrom t range`
  — value of the tranche that must **stay locked**: full amount before its date, `zero` once vested.

### On-chain guards / invariants (in order)
1. **OSM — Owner signature missing.** `txSignedBy txI (vpOwner params)` MUST hold. RULE: every spend of the vesting UTxO must be signed by the owner key (`vpOwner`).
2. **IRV — Insufficient remaining value.** `remainingActual \`geq\` remainingExpected` MUST hold, where:
   - `remainingActual`  = total `Value` paid back to the script's own address in this tx (`valueLockedByAddress` over `txInfoOutputs`, matching `ownScriptAddress`).
   - `remainingExpected` = `remainingFrom vpTranche1 validRange + remainingFrom vpTranche2 validRange` using the tx `validRange`.
   RULE: the value re-locked at the script address must be at least the sum of the not-yet-vested portions of both tranches for the current time; you may only withdraw value whose tranche date has passed (relative to the tx validity range). Withdrawing more than vested leaves too little re-locked and fails.
3. Otherwise succeeds (`unitval`).

### Internal helpers (errors)
- `ownInputRef` — extracts the spent `TxOutRef` from `SpendingScript`; else `traceError "NSS"` (not a spending script).
- `ownScriptAddress` — finds the resolved address of the own input by matching `ownInputRef`; else `traceError "INF"` (input not found).
- `valueLockedByAddress` — folds `txInfoOutputs`, summing `txOutValue` of outputs whose address equals the script address.

## Off-chain helpers — `Vesting.Scripts`

- `vestingValidatorScript :: VestingParams -> C.PlutusScript C.PlutusScriptV3`
  — compiles+applies params to produce the serialized V3 script. (`vestingValidatorCompiled` is the internal `CompiledCode` step.)
- `saveVestingValidatorScript :: VestingParams -> FilePath -> IO ()`
  — writes the script text envelope to disk (utility, not for the model).
- `lockVesting :: (C.IsBabbageBasedEra era, MonadBuildTx era m) => NetworkId -> VestingParams -> C.Value -> m ()`
  — builds an output paying the given `Value` to the script address (hash of `vestingValidatorScript params`) with a **unit inline datum**, `NoStakeAddress`. Caller must set min-Ada (`setMinAdaDepositAll`) afterwards. Constructs: script address (from script hash), inline datum `()`, locked value.
- `withdrawVesting :: (C.IsBabbageBasedEra era, C.HasScriptLanguageInEra C.PlutusScriptV3 era, MonadBuildTx era m) => VestingParams -> C.TxIn -> C.Hash C.PaymentKey -> m ()`
  — adds the owner key hash as a required signature (`addRequiredSignature`) and spends the given script UTxO with the unit redeemer / inline datum (`spendPlutusInlineDatum`). Caller is responsible for: validity range (to satisfy tranche containment), paying withdrawn amount to owner, re-locking still-vesting value (e.g. a second `lockVesting`), and balancing/submitting.

## Candidate user-facing operations (named only; model NOT designed yet)

- **Deploy / Lock** — submit the initial on-chain tx locking value at the vesting script address (the deployment action; e.g. lock tranche1.vAmount + tranche2.vAmount).
- **Withdraw tranche-1** — after tranche1 date, withdraw tranche1 amount to owner, re-lock tranche2.
- **Withdraw tranche-2** — after tranche2 date, withdraw the remainder.
- (Possible negative/expected-failure shapes: withdraw before date, withdraw without owner signature, withdraw too much — each should hit IRV or OSM.)

## Open questions about contract semantics

- Datum and redeemer are both unit; the entire schedule is enforced via the `VestingParams` baked into the script address. A model must therefore track params per deployed instance rather than per-UTxO datum.
- The validator only checks the **aggregate** value re-locked at the script address, not a specific UTxO split; need to confirm how withdraw composes lock+withdraw in one tx (the helper expects a re-lock output).
- `availableFrom` requires the validity range to be fully `contains`-ed by `[date, +inf)`; exact slot/POSIXTime conversion and how validity-range lower bound is set off-chain affects when a tranche is "available".
