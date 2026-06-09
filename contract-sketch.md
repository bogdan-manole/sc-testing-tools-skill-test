# Escrow Contract Sketch

## 1. Validators

A single PlutusV3 **spending validator**, parameterized at compile time by `EscrowParams`:

| Aspect | Detail |
|---|---|
| Script type | `PlutusScriptV3` (spending) |
| Parameter | `EscrowParams { epDeadline, epTargets }` |
| Datum | Inline datum: `PubKeyHash` of the contributor |
| Redeemer | `Action` — either `Redeem` or `Refund` |
| Datum mode | `spendPlutusInlineDatum` (the datum lives on the script UTxO, not hashed) |
| Error codes (trace) | `"DLP"`, `"TGT"`, `"DNP"`, `"SNS"`, `"SNF"`, `"WDT"` |

The compiled artefact is `escrowValidatorScript :: EscrowParams -> PlutusScript PlutusScriptV3`, produced via `PlutusTx.compile` / `PlutusTx.applyCode` / `compiledCodeToScript`.

## 2. Datum / Redeemer types

### EscrowParams (compile-time parameter)

```haskell
data EscrowParams = EscrowParams
  { epDeadline :: POSIXTime    -- exclusive upper bound for Redeem; exclusive lower bound for Refund
  , epTargets  :: [EscrowTarget]   -- outputs that must appear in a Redeem tx
  }
```

Baked into the script address at compilation time. Not part of the UTxO datum.

### EscrowDatum — inline datum on the UTxO

There is no named `EscrowDatum` type. The datum stored inline is a **bare `PubKeyHash`** — the contributor's payment key hash (the party who locked the funds and the only party who can Refund).

The validator decodes it as:

```haskell
contributor = case scriptInfo of
  SpendingScript _ (Just (Datum d)) ->
    case PlutusTx.fromBuiltinData d of
      Just pkh -> pkh        -- PubKeyHash
      Nothing  -> traceError "..."
  _ -> traceError "..."
```

### EscrowTarget (part of EscrowParams)

```haskell
data EscrowTarget
  = PaymentPubKeyTarget PubKeyHash Value
  | ScriptTarget ScriptHash Datum Value
```

- **`PaymentPubKeyTarget pkh vl`** — the Redeem tx must pay at least `vl` to `pkh` (summed across all outputs whose payment credential matches `pkh`).
- **`ScriptTarget vh dat vl`** — the Redeem tx must produce an output to script hash `vh` carrying inline datum `dat` and value at least `vl`.

### Action (redeemer)

```haskell
data Action = Redeem | Refund
```
Indexed as `Redeem → 0`, `Refund → 1`.

## 3. Valid actions

### Redeem

- **When**: strictly *before* the deadline (`to deadline \`contains\` validRange`).
  - The tx validity range must have its upper bound ≤ deadline, and `to deadline` (the infinite past up to deadline) must contain the entire validity range.
- **What**: all targets in `epTargets` must be satisfied in the transaction outputs (see `meetsTarget` below).
- **Signatures**: none required from a script perspective (the contributor does *not* need to sign for Redeem).
- **Target checks**:
  - `PaymentPubKeyTarget`: aggregate value paid to the PKH across all tx outputs must be ≥ target value.
  - `ScriptTarget`: at least one output sent to the script hash must carry the exact expected inline `Datum` and value ≥ target value.

Error trace codes:
- `"DLP"` — Deadline passed (tried to Redeem after or at deadline)
- `"TGT"` — Targets not met (one or more targets unsatisfied)
- `"SNF"` — Script target output not found in tx outputs
- `"WDT"` — Wrong datum type on a script output (not inline)

### Refund

- **When**: strictly *after* the deadline (`(deadline - 1) \`before\` validRange`).
  - The tx validity range must start at or after `deadline - 1` (exclusive lower bound), meaning `deadline` itself is the earliest point at which Refund is valid.
- **Signatures**: the contributor (PubKeyHash from the inline datum) **must sign** the transaction.
- **Outputs**: none constrained by the validator — the caller is free to route the returned value anywhere.

Error trace codes:
- `"DNP"` — Deadline not passed yet (tried to Refund before deadline)
- `"SNS"` — Signature missing (contributor did not sign)

## 4. Invariants

| # | Invariant | Enforced by |
|---|---|---|
| I1 | Before deadline, only Redeem is valid; Refund is rejected (`"DNP"`) | `mkValidator` Refund branch |
| I2 | After deadline, only Refund is valid (with contributor sig); Redeem is rejected (`"DLP"`) | `mkValidator` Redeem branch |
| I3 | Redeem requires all `epTargets` satisfied in the tx outputs | `all (meetsTarget txI) targets` |
| I4 | Refund requires the contributor's signature | `txSignedBy txI contributor` |
| I5 | The UTxO must carry an inline datum (not datum hash) | pattern match on `SpendingScript _ (Just (Datum d))` |
| I6 | That inline datum must be a valid `PubKeyHash` | `fromBuiltinData d` must succeed |
| I7 | The redeemer must be a valid `Action` value | `fromBuiltinData` on the redeemer |
| I8 | For `ScriptTarget`, the target script output must use inline datum (`OutputDatum (Datum d)`) | pattern match in `scriptOutputAt` → `meetsTarget` |
| I9 | For `PaymentPubKeyTarget`, value is aggregated across *all* outputs to the PKH | `valuePaidToPkh` uses `foldr` over all outputs |

## 5. Off-chain helpers

Three helpers in `Escrow.Scripts`, all operating in `MonadBuildTx era m`:

### `lockEscrow`

```haskell
lockEscrow
  :: IsBabbageBasedEra era
  => MonadBuildTx era m
  => NetworkId
  -> EscrowParams         -- compile-time params baked into address
  -> PubKeyHash           -- contributor PKH → stored as inline datum
  -> Value                -- value to lock
  -> m ()
```

Pays the given value to the escrow script address, embedding the contributor PKH as an inline datum. Uses `BuildTx.payToScriptInlineDatum`.

### `redeemEscrow`

```haskell
redeemEscrow
  :: (IsBabbageBasedEra era, HasScriptLanguageInEra PlutusScriptV3 era)
  => MonadBuildTx era m
  => EscrowParams
  -> TxIn                -- escrow UTxO to spend
  -> m ()
```

Spends the escrow UTxO with `Redeem` as the redeemer. **The caller must separately add:**
- Per-target outputs (to satisfy `epTargets`)
- A validity range ending before the deadline

### `refundEscrow`

```haskell
refundEscrow
  :: (IsBabbageBasedEra era, HasScriptLanguageInEra PlutusScriptV3 era)
  => MonadBuildTx era m
  => EscrowParams
  -> TxIn                -- escrow UTxO to spend
  -> Hash PaymentKey     -- contributor key hash (must match inline datum PKH)
  -> m ()
```

Spends the escrow UTxO with `Refund` as the redeemer, and adds the contributor's key hash as a required signer. **The caller must separately add:**
- A validity range that starts strictly after the deadline

## 6. Testing notes

### PlutusV3 specifics

- **Inline datums only** — the script pattern-matches `SpendingScript _ (Just (Datum d))` and errors on anything else. Any test must ensure the escrow UTxO carries an `OutputDatum (Datum d)` and not a datum hash.
- **`spendPlutusInlineDatum`** is the Convex helper used on the off-chain side — it requires PlutusV3 support (`HasScriptLanguageInEra PlutusScriptV3 era`).
- **`target-version=1.1.0.0`** is set in GHC plugin options for both modules (Conway-ready).

### Edge cases

| Edge case | Behaviour |
|---|---|
| Redeem exactly at deadline | Fails — `to deadline` does not contain a range that includes/exceeds the deadline boundary. Redeem requires `to deadline \`contains\` validRange`, so the validity interval must be strictly inside the deadline. |
| Refund exactly at deadline | Succeeds — `(deadline - 1) \`before\` validRange` means the valid range must start after `deadline - 1`, so starting exactly at `deadline` is fine. |
| Redeem with no targets | Passes trivially — `all (meetsTarget txI) []` is `True`. |
| Partial target satisfaction | Fails — all targets must be met (`all`). |
| Overpayment to a target | Allowed — `geq` is used, not `==`. |
| Payment to PKH target across multiple outputs | Allowed — `valuePaidToPkh` sums all matching outputs. |
| ScriptTarget but script output uses datum hash | Fails with `"WDT"` — inline datum required. |
| Wrong redeemer encoding | Fails — `fromBuiltinData` on the redeemer returns `Nothing`. |
| Missing inline datum on spent UTxO | Fails — pattern match on `SpendingScript _ (Just _)` fails. |
| Time handling | Uses `contains` and `before` from `PlutusLedgerApi.V1.Interval`. The `deadline - 1` in the Refund check ensures that the lower bound for the validity range is `(deadline - 1)`, not `deadline`, so Refund becomes valid the instant `deadline` is crossed. |

### Testing the three phases

1. **Lock** — a transaction paying to the script with the contributor PKH as inline datum. The test should verify the script address is derived correctly from params and the UTxO datum is recoverable.
2. **Redeem** — a transaction within the validity window, spending the UTxO with `Redeem`, producing outputs that satisfy all targets. Failure modes to test: expired deadline, missing targets, wrong datum types on script targets.
3. **Refund** — a transaction after the deadline, spending the UTxO with `Refund`, signed by the contributor. Failure modes: before deadline, missing signature, wrong signer.

### No double-satisfaction

The validator only checks that each target is met — it does not check that value from the escrow UTxO is *completely consumed*. The caller or test harness must ensure the total input value matches total output value (standard Cardano ledger rule).

### Multi-target scenarios

A single `EscrowParams` can list multiple targets combining both `PaymentPubKeyTarget` and `ScriptTarget` entries. This enables interesting test scenarios: partial payment to a PKH, payment to multiple scripts, or a mix.
