module Main where

import Convex.Tasty.Streaming (defaultMainStreaming)
import PingPongSpec qualified
import Test.Tasty (testGroup)

main :: IO ()
main =
  defaultMainStreaming $
    testGroup "pingpong tests" [PingPongSpec.tests]
