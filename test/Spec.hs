module Main where

import qualified AuctionSpec
import Convex.Tasty.Streaming (defaultMainStreaming)
import Test.Tasty (testGroup)

main :: IO ()
main =
  defaultMainStreaming $
    testGroup "auction tests" [AuctionSpec.tests]
