-- | What generated Hspec tests share: their assertion and how a Hedgehog
-- property is checked. Generated test modules hold only their laws.
-- ref:DEC-readable-output-default
module LawSpecTesting (assertEqual, check, holds, holdsFor) where

import Control.Exception (SomeException, catch, displayException)
import Data.Char (chr)
import Data.List (intercalate)
import qualified Hedgehog
import qualified Hedgehog.Internal.Config as Config
import qualified Hedgehog.Internal.Region as Region
import qualified Hedgehog.Internal.Report as Report
import qualified Hedgehog.Internal.Runner as Runner
import qualified Hedgehog.Internal.Seed as Seed
import LawSpecRuntime (Scalar (..))
import qualified LawSpecRuntime as LS
import qualified System.Environment as Environment
import Test.Hspec (expectationFailure, shouldBe)

-- | Fails unless two values are equal, naming the law, the case and its
-- source line, both sides and where they differ.
assertEqual :: String -> Scalar -> Scalar -> IO ()
assertEqual context actual expected = catch action handler
  where
    action =
      if LS.equal actual expected
        then pure ()
        else
          expectationFailure $
            context
              ++ " | actual="
              ++ shown actual
              ++ " expected="
              ++ shown expected
              ++ LS.difference actual expected
    handler :: SomeException -> IO ()
    handler e = expectationFailure (context ++ " | " ++ displayException e)

-- | Checks a property directly with Hedgehog. LAWSPEC_SEED fixes its seed;
-- hspec's HSPEC_SEED seeds the others. lawspec test sets both, and records
-- the seed of every passing run.
check :: Hedgehog.Property -> IO Bool
check property = do
  seed <- Environment.lookupEnv "LAWSPEC_SEED"
  color <- Config.detectColor
  Region.displayRegion $ \region ->
    (== Report.OK) . Report.reportStatus
      <$> Runner.checkNamed region color Nothing (fmap (Seed.from . read) seed) property

-- | Fails unless a property holds for its number of cases, discarding and
-- shrinking at most as many times as given.
holds :: Int -> Int -> Int -> Hedgehog.PropertyT IO () -> IO ()
holds tests discards shrinks body = do
  passed <-
    check
      $ Hedgehog.withTests (fromIntegral tests)
      $ Hedgehog.withDiscards (fromIntegral discards)
      $ Hedgehog.withShrinks (fromIntegral shrinks)
      $ Hedgehog.property body
  passed `shouldBe` True

-- | As holds, with Hedgehog's discard and shrink limits.
holdsFor :: Int -> Hedgehog.PropertyT IO () -> IO ()
holdsFor tests body = do
  passed <- check (Hedgehog.withTests (fromIntegral tests) (Hedgehog.property body))
  passed `shouldBe` True

-- | A value as a reader writes it: text as a string, lists and data with
-- their parts.
shown :: Scalar -> String
shown value = case value of
  SSequence "Text" units -> show (map chr units)
  SList items -> "[" ++ intercalate ", " (map shown items) ++ "]"
  SData tag fields -> unwords (tag : map parenthesised fields)
  SInteger _ n -> show n
  SBool b -> show b
  _ -> show value
  where
    parenthesised field = case field of
      SData _ (_ : _) -> "(" ++ shown field ++ ")"
      _ -> shown field
