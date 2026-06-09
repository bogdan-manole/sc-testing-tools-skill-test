module Main where

import Convex.Tasty.Streaming (defaultMainStreaming)
import qualified EscrowSpec
import Test.Tasty (testGroup)

main :: IO ()
main =
  defaultMainStreaming $
    testGroup "escrow tests" [EscrowSpec.tests]
