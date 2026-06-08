module Main where

import Convex.Tasty.Streaming (defaultMainStreaming)
import Test.Tasty (testGroup)
import qualified VestingSpec

main :: IO ()
main =
  defaultMainStreaming $
    testGroup "vesting tests" [VestingSpec.tests]
