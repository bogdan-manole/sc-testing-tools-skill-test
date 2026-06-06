{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
-- 1.1.0.0 will be enabled in conway
{-# OPTIONS_GHC -fobject-code -fno-ignore-interface-pragmas -fno-omit-interface-pragmas -fplugin-opt PlutusTx.Plugin:target-version=1.1.0.0 #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:defer-errors #-}

-- | Scripts used for testing, plus minimal off-chain transaction-building helpers.
module Auction.Scripts (
  -- * Compiled script
  auctionValidatorScript,
  saveAuctionValidatorScript,

  -- * Off-chain helpers
  lockAuction,
  placeBid,
  payout,
) where

import Auction.Validator (AuctionDatum (..), AuctionParams, AuctionRedeemer (..), Bid)
import Auction.Validator qualified as Auction
import Cardano.Api (NetworkId)
import Cardano.Api qualified as C
import Convex.BuildTx (MonadBuildTx)
import Convex.BuildTx qualified as BuildTx
import Convex.PlutusTx (compiledCodeToScript)
import PlutusTx (BuiltinData, CompiledCode)
import PlutusTx qualified
import PlutusTx.Prelude (BuiltinUnit)

-- | Compiling a parameterized validator for 'Scripts.Auction.auctionUntypedValidator'
auctionValidatorCompiled :: Auction.AuctionParams -> CompiledCode (BuiltinData -> BuiltinUnit)
auctionValidatorCompiled params =
  case $$(PlutusTx.compile [||Auction.auctionUntypedValidator||])
    `PlutusTx.applyCode` PlutusTx.liftCodeDef params of
    Left err -> error err
    Right cc -> cc

-- | Serialized validator for 'Scripts.Auction.auctionUntypedValidator'
auctionValidatorScript :: Auction.AuctionParams -> C.PlutusScript C.PlutusScriptV3
auctionValidatorScript = compiledCodeToScript . auctionValidatorCompiled

-- | Save the validator script to a file
saveAuctionValidatorScript :: Auction.AuctionParams -> FilePath -> IO ()
saveAuctionValidatorScript params filePath = do
  let script = auctionValidatorScript params
  C.writeFileTextEnvelope (C.File filePath) Nothing script >>= \case
    Left err -> print $ C.displayError err
    Right () -> putStrLn $ "Serialized script to: " ++ filePath

-------------------------------------------------------------------------------
-- Off-chain transaction-building helpers
--
-- The upstream Auction tests inline the full lock/bid/payout transaction
-- bodies into Spec/Unit.hs. These helpers extract just the script-touching
-- fragments (mirroring the PingPong / Escrow off-chain style): each is a
-- single 'MonadBuildTx' action that the caller composes with bidder/seller
-- payouts, refunds, validity ranges, and balancing.
-------------------------------------------------------------------------------

{- | Lock the auctioned asset at the auction script with an initial datum
(typically @AuctionDatum Nothing@) and the asset value.

The caller is responsible for ensuring @value@ already contains the NFT and
for setting the min-Ada deposit after composing the transaction.
-}
lockAuction
  :: forall era m
   . (C.IsBabbageBasedEra era)
  => (MonadBuildTx era m)
  => NetworkId
  -> AuctionParams
  -> AuctionDatum
  -- ^ Initial datum (use @AuctionDatum Nothing@ before any bids)
  -> C.Value
  -- ^ Value to lock (NFT + any initial Ada)
  -> m ()
lockAuction networkId params datum value = do
  let scriptHash = C.hashScript (C.PlutusScript C.plutusScriptVersion (auctionValidatorScript params))
  BuildTx.payToScriptInlineDatum
    networkId
    scriptHash
    datum
    C.NoStakeAddress
    value

{- | Spend the current script UTxO with a 'NewBid' redeemer and recreate the
script UTxO with the new datum and value.

Refund of the previous highest bidder, validity range, and balancing are left
to the caller — those depend on the scenario (first bid vs replacement).
-}
placeBid
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , C.HasScriptLanguageInEra C.PlutusScriptV3 era
     )
  => (MonadBuildTx era m)
  => NetworkId
  -> AuctionParams
  -> C.TxIn
  -- ^ Current script UTxO to spend
  -> Bid
  -- ^ The new bid (becomes the redeemer payload and the new highest bid)
  -> C.Value
  -- ^ New script-output value (NFT + new bid amount)
  -> m ()
placeBid networkId params txIn bid newValue = do
  let scriptHash = C.hashScript (C.PlutusScript C.plutusScriptVersion (auctionValidatorScript params))
  BuildTx.spendPlutusInlineDatum txIn (auctionValidatorScript params) (NewBid bid)
  BuildTx.payToScriptInlineDatum
    networkId
    scriptHash
    (AuctionDatum (Just bid))
    C.NoStakeAddress
    newValue

{- | Spend the script UTxO with the 'Payout' redeemer. The caller is
responsible for:

* paying the highest-bid Ada to the seller,
* paying the NFT to the highest bidder (or back to the seller if there were no bids),
* setting a validity range that starts at or after the auction end time.
-}
payout
  :: forall era m
   . ( C.IsBabbageBasedEra era
     , C.HasScriptLanguageInEra C.PlutusScriptV3 era
     )
  => (MonadBuildTx era m)
  => AuctionParams
  -> C.TxIn
  -- ^ Script UTxO holding the asset (and possibly the highest bid)
  -> m ()
payout params txIn =
  BuildTx.spendPlutusInlineDatum txIn (auctionValidatorScript params) Payout
