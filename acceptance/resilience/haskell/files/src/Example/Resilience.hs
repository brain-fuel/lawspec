-- User-owned LawSpec adapter: the workflow runtime under test.
module Example.Resilience where

import Data.IORef (readIORef)
import qualified Data.Int as I
import qualified Data.Word as W
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecRuntime as LS

retry :: String -> Integer -> Integer -> Integer -> LS.Retry
retry strategy delay step factor = LS.Retry strategy delay step factor (-1) 0 "none" Nothing Nothing

runtimeExponentialDelay :: Integer -> Integer -> Integer -> LS.IntegerValue
runtimeExponentialDelay base factor attempt = LS.integerValue (LS.retryDelay (retry "exponential" base 0 factor) attempt)

runtimeLinearDelay :: Integer -> Integer -> Integer -> LS.IntegerValue
runtimeLinearDelay base step attempt = LS.integerValue (LS.retryDelay (retry "linear" base step 0) attempt)

runtimeFibonacciDelay :: Integer -> Integer -> LS.IntegerValue
runtimeFibonacciDelay base attempt = LS.integerValue (LS.retryDelay (retry "fibonacci" base 0 0) attempt)

splitMix :: W.Word64 -> I.Int32 -> [W.Word64]
splitMix seed count = take (fromIntegral count) (go seed)
  where go state = let (value, next) = LS.splitMix64 state in value : go next

fullJitter :: W.Word64 -> Integer -> LS.IntegerValue
fullJitter seed delay = LS.integerValue $ unsafePerformIO $ do
  (clock, _) <- LS.virtualClock
  runtime <- LS.newWorkflowRuntime clock seed
  LS.jittered runtime "full" delay 0 0

waits :: I.Int32 -> Maybe (LS.Scalar -> Bool) -> [Integer]
waits attempts when = unsafePerformIO $ do
  (clock, _) <- LS.virtualClock
  runtime <- LS.newWorkflowRuntime clock 0
  symbols <- LS.workflowContext runtime
  let policy = LS.StagePolicy "stage" (Just (LS.Retry "exponential" 100000 0 2 (-1) (toInteger attempts) "none" when Nothing)) (-1)
  _ <- pure $! LS.runStage symbols policy (\() -> LS.SData "Either::Left" [LS.SInteger "Integer" 0])
  events <- readIORef (LS.runtimeTrace runtime)
  pure [LS.traceNumber event | event <- events, LS.traceKind event == "sleep"]

retriedWaits :: I.Int32 -> [Integer]
retriedWaits attempts = waits attempts Nothing

rejectedWaits :: I.Int32 -> [Integer]
rejectedWaits attempts = waits attempts (Just (const False))
