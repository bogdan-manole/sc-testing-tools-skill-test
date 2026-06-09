# Auction contract sketch

Library: `auction` (lib/), exposes `Auction.Validator`, `Auction.Scripts`, `Auction.Utils`.

## Validator (Plutus V3, parameterized)
`Auction.Validator.auctionTypedValidator :: AuctionParams -> ScriptContext -> Bool`

### Params (AuctionParams, makeLift)
- apSeller        :: PubKeyHash
- apCurrencySymbol:: CurrencySymbol   (auctioned token)
- apTokenName     :: TokenName
- apMinBid        :: Lovelace
- apEndTime       :: POSIXTime        (bid deadline)

### Datum (AuctionDatum)
- newtype AuctionDatum { adHighestBid :: Maybe Bid }
- Bid { bAddr :: BuiltinByteString, bPkh :: PubKeyHash, bAmount :: Lovelace }

### Redeemer (AuctionRedeemer)
- NewBid Bid   (index 0)
- Payout       (index 1)

## On-chain rules
- NewBid: bid sufficient (> current highest, or >= apMinBid if first);
  within bid time (validRange before apEndTime); previous highest bidder refunded;
  exactly one continuing output recreating datum (Just bid) with NFT + bid amount.
- Payout: validRange at/after apEndTime; seller gets highest bid Ada;
  highest bidder gets NFT (asset returns to seller if no bids).

## Compiled scripts
- auctionValidatorScript :: AuctionParams -> PlutusScript PlutusScriptV3
- Also hugeValidator / hugeValidatorScript (oversized padding variant for size testing).

## Off-chain helpers (Scripts.hs, MonadBuildTx)
- lockAuction  : pay NFT to script with inline initial datum (AuctionDatum Nothing)
- placeBid     : spend script UTxO with NewBid, recreate UTxO with new datum/value
- payout       : spend script UTxO with Payout redeemer
