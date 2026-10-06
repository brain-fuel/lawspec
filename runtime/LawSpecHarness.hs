-- The harness plane at run time (see docs/reference/language/harness.md):
-- how a law's tests run, never what the law means. Generated tests call it
-- for strategies' refinement checks, adequacy (cover, classify, label), run
-- metadata (known failing, timeout, repeat, retry flaky) and benchmarks.
--
-- Statistics go to standard output, and, when LAWSPEC_STATS names a
-- directory, to one JSON file per test there, which lawspec test reads.
module LawSpecHarness
  ( HarnessError(..), checkDrawn, observe, target, run, knownFailing, benchmark, record
  ) where

import Control.Exception (Exception, SomeException, evaluate, fromException, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.Char (isAlphaNum)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (intercalate, sortOn)
import qualified Data.Map.Strict as M
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import LawSpecRuntime (Scalar(..))
import qualified LawSpecRuntime as LS

-- A harness requirement failed: a strategy or an adequacy check.
newtype HarnessError = HarnessError String

instance Show HarnessError where
  show (HarnessError message) = message

instance Exception HarnessError

data Json = JString String | JNumber Double | JInt Integer | JBool Bool | JList [Json] | JObject [(String, Json)]

json :: Json -> String
json value = case value of
  JString s -> show s
  JNumber d -> show d
  JInt n -> show n
  JBool b -> if b then "true" else "false"
  JList xs -> "[" ++ intercalate "," (map json xs) ++ "]"
  JObject fields -> "{" ++ intercalate "," [show k ++ ":" ++ json v | (k, v) <- fields] ++ "}"

record :: String -> [(String, Json)] -> IO ()
record name entry = do
  directory <- lookupEnv "LAWSPEC_STATS"
  case directory of
    Just d | not (null d) -> do
      let safe = map (\c -> if isAlphaNum c || c `elem` "-_" then c else '_') name
      _ <- try (writeFile (d ++ "/" ++ safe ++ ".json") (json (JObject entry))) :: IO (Either SomeException ())
      pure ()
    _ -> pure ()

-- A drawn value must satisfy its input's refinements: a strategy may only
-- produce values the law is about.
checkDrawn :: String -> String -> Bool -> Scalar -> IO ()
checkDrawn strategy name holds value = unless holds $ throwIO (HarnessError ("the strategy " ++ strategy ++ " produced " ++
  LS.renderValue value ++ " for " ++ name ++ ", which is outside the input's refinement; a strategy may only produce values of its type"))

data Stats = Stats { cases :: Int, covered :: M.Map String Int, classes :: M.Map String Int, labels :: M.Map String Int, best :: Maybe Double }

emptyStats :: Stats
emptyStats = Stats 0 M.empty M.empty M.empty Nothing

statistics :: IORef (M.Map String Stats)
statistics = unsafePerformIO (newIORef M.empty)
{-# NOINLINE statistics #-}

-- What one generated case covers, classifies and labels.
observe :: String -> [(String, Bool)] -> [(String, Bool)] -> [Scalar] -> IO ()
observe law covers classified labelled = atomicModifyIORef' statistics $ \table ->
  let s = M.findWithDefault emptyStats law table
      count xs m = foldr (\(l, holds) acc -> if holds then M.insertWith (+) l 1 acc else acc) m xs
      s' = s { cases = cases s + 1, covered = count covers (covered s), classes = count classified (classes s)
             , labels = foldr (\v acc -> M.insertWith (+) (text v) 1 acc) (labels s) labelled }
  in (M.insert law s' table, ())
  where
    text v = case v of
      SSequence _ units -> map toEnum units
      other -> LS.renderValue other

-- target maximize: Hedgehog has no targeted search, so the best score is
-- reported with the law's statistics.
target :: Scalar -> String -> IO ()
target score law = atomicModifyIORef' statistics $ \table ->
  let s = M.findWithDefault emptyStats law table
      value = number score
  in (M.insert law s { best = Just (maybe value (max value) (best s)) } table, ())
  where
    number v = case v of
      SInteger _ n -> fromIntegral n
      SDecimal c e -> fromIntegral c * 10 ^^ e
      SRational n d -> fromIntegral n / fromIntegral d
      _ -> LS.floatValue v

adequacy :: String -> [(Int, String)] -> IO [(String, Json)]
adequacy law covers = do
  s <- atomicModifyIORef' statistics (\table -> (M.delete law table, M.findWithDefault emptyStats law table))
  let n = cases s
      percent k = if n == 0 then 0 else fromIntegral (round (10000 * fromIntegral k / fromIntegral n :: Double)) / 100 :: Double
      results = [(p, l, percent (M.findWithDefault 0 l (covered s))) | (p, l) <- covers]
      met (p, _, observed) = n > 0 && observed >= fromIntegral p
      shown d = showFFloat (Just 1) d ""
  putStrLn (intercalate "\n" (
    [law ++ ": " ++ show n ++ " generated case(s)"] ++
    ["  cover " ++ show p ++ "% " ++ show l ++ ": " ++ shown o ++ "%" ++ (if met r then "" else " (not met)") | r@(p, l, o) <- results] ++
    ["  " ++ l ++ ": " ++ shown (percent k) ++ "%" | (l, k) <- M.toList (classes s)] ++
    ["  label " ++ l ++ ": " ++ shown (percent k) ++ "%" | (l, k) <- sortOn (negate . snd) (M.toList (labels s))] ++
    ["  best target score: " ++ show b | Just b <- [best s]]))
  let unmet = [law ++ ": cover " ++ show p ++ "% " ++ show l ++ " was not met (" ++ shown o ++ "% of " ++ show n ++ " generated cases)" | r@(p, l, o) <- results, not (met r)]
  unless (null unmet) (throwIO (HarnessError (intercalate "; " unmet)))
  pure [ ("law", JString law), ("cases", JInt (fromIntegral n))
       , ("cover", JList [JObject [("label", JString l), ("required", JInt (fromIntegral p)), ("observed", JNumber o), ("met", JBool (met r))] | r@(p, l, o) <- results])
       , ("classes", JObject [(k, JInt (fromIntegral v)) | (k, v) <- M.toList (classes s)])
       , ("labels", JObject [(k, JInt (fromIntegral v)) | (k, v) <- M.toList (labels s)]) ]

once :: String -> Int -> IO () -> IO ()
once law milliseconds test
  | milliseconds <= 0 = test
  | otherwise = do
      finished <- timeout (milliseconds * 1000) test
      case finished of
        Just () -> pure ()
        Nothing -> throwIO (HarnessError (law ++ " took longer than its timeout of " ++ show milliseconds ++ " ms"))

-- Run one generated test of a law under its harness settings.
run :: String -> String -> Int -> Int -> Int -> [(Int, String)] -> Bool -> IO () -> IO ()
run law name milliseconds repeats retries covers observed test = go 1 False
  where
    attempt = fmap concat $ forM [1 .. repeats] $ \_ -> do
      atomicModifyIORef' statistics (\table -> (M.delete law table, ()))
      once law milliseconds test
      if observed then adequacy law covers else pure []
    go attempts flaky = do
      outcome <- try attempt
      case outcome of
        Right report -> do
          record name ([("law", JString law), ("test", JString name), ("attempts", JInt attempts),
            ("outcome", JString (if flaky then "flaky" else "passed"))] ++ report)
          when flaky (putStrLn (law ++ " is flaky: it failed, then passed on attempt " ++ show attempts))
        Left error'
          | harness error' || attempts > fromIntegral retries -> do
              record name [("law", JString law), ("test", JString name), ("outcome", JString "failed"), ("attempts", JInt attempts)]
              throwIO error'
          | otherwise -> go (attempts + 1) True
    harness :: SomeException -> Bool
    harness e = case fromException e of
      Just (HarnessError _) -> True
      Nothing -> False

-- A known-failing law's tests must fail. One that passes is reported: the
-- harness should no longer say it is known to fail.
knownFailing :: String -> String -> String -> [IO ()] -> IO ()
knownFailing law name reason tests = go tests
  where
    go [] = do
      record name [("law", JString law), ("test", JString name), ("outcome", JString "known-failing-passed"), ("reason", JString reason)]
      throwIO (HarnessError (law ++ " is marked known failing (" ++ reason ++ "), but it passes; remove `known failing` from its harness"))
    go (test : rest) = do
      outcome <- try test :: IO (Either SomeException ())
      case outcome of
        Left e -> do
          record name [("law", JString law), ("test", JString name), ("outcome", JString "known-failing"), ("reason", JString reason)]
          putStrLn (law ++ " is known to fail (" ++ reason ++ "): " ++ takeWhile (/= '\n') (show e))
        Right () -> go rest

-- Measured, never asserted: the mean and fastest time of body.
benchmark :: String -> IO a -> IO ()
benchmark name body = do
  started <- getMonotonicTimeNSec
  let loop times = do
        now <- getMonotonicTimeNSec
        if length times >= 100000 || (now - started > 200000000 && length times >= 3) then pure times else do
          before <- getMonotonicTimeNSec
          _ <- body >>= evaluate
          after <- getMonotonicTimeNSec
          loop ((after - before) : times)
  times <- loop []
  let mean = fromIntegral (sum times) / fromIntegral (length times) :: Double
      fastest = fromIntegral (minimum times) :: Double
  putStrLn ("benchmark " ++ name ++ ": " ++ show (length times) ++ " iteration(s), mean " ++ showFFloat (Just 2) (mean / 1000) "" ++
    " us, fastest " ++ showFFloat (Just 2) (fastest / 1000) "" ++ " us")
  record ("benchmark " ++ name) [("benchmark", JString name), ("iterations", JInt (fromIntegral (length times))),
    ("mean_ns", JInt (round mean)), ("min_ns", JInt (round fastest))]
