-- | Numbers in Z3 tasks (lawspec-smtlib-v2): Rational inputs quantified
-- exactly (an integer over a positive integer, so a witness is never
-- irrational), Decimal inputs (any Real universally, a multiple of 10^-18
-- as a witness), and IEEE binary32 and binary64 with LawSpec's equality.
module SmtNumericSpec (test_smtNumbers) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Smt as SMT
import LawSpec.Core.Counterexample (checkStatus, validateCounterexample)
import LawSpec.Frontend (compileCoreCanonical)
import qualified LawSpec.Model as S

compiled :: String -> IO (C.Program, [SMT.ProofTask])
compiled source = do
  program <- either (fail . show) pure (compileCoreCanonical 64 S.defaultGeneration [S.Source "numbers.lawspec" source])
  tasks <- either (fail . show) pure (SMT.proofTasks program)
  pure (program, tasks)

portfolio :: IO (C.Program, [SMT.ProofTask])
portfolio = readFile "test/fixtures/numeric-proofs.lawspec" >>= compiled

taskNamed :: String -> [SMT.ProofTask] -> IO SMT.ProofTask
taskNamed name tasks = case [t | t <- tasks, ("::law::|" ++ name ++ "|") `isInfixOf` C.idText (SMT.taskLaw t)] of
  t : _ -> pure t
  [] -> fail ("no task " ++ name)

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

run :: FilePath -> String -> IO String
run z3 script = do
  (status, output, errors) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] script
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure output

-- | The counterexample query's values, checked by the evaluator.
refutation :: FilePath -> C.Program -> SMT.ProofTask -> IO String
refutation z3 program t = do
  query <- either fail pure (SMT.taskCounterexample t)
  output <- run z3 (SMT.counterexampleScript query ++ "(check-sat)\n(get-value (" ++ unwords (map fst (SMT.counterexampleInputs query)) ++ "))\n")
  let (verdict, rest) = break (== '\n') output
  verdict `shouldBe` "sat"
  pure (checkStatus (validateCounterexample program t rest))

law :: String -> String
law body = "unit smt.numbers\n\nlaw selected is definition: " ++ body ++ " end definition end law\nend unit\n"

test_smtNumbers :: Spec
test_smtNumbers = describe "SMT numbers" $ do
  it "gives Rational, Decimal and float laws v2 tasks" $ do
    (_, tasks) <- portfolio
    forM_ tasks $ \t -> SMT.taskEncoding t `shouldBe` SMT.SmtLibV2
  it "proves the numeric portfolio, and not a law that needs an irrational witness" $ solver $ \z3 -> do
    (_, tasks) <- portfolio
    forM_ ["a third exists", "rationals have a midpoint", "decimals add exactly", "a decimal tenth exists", "NaN is not itself"
          , "the zeros are equal", "the zeros differ in sign only", "negation flips the sign"] $ \name -> do
      t <- taskNamed name tasks
      script <- either fail pure (SMT.taskQuery t)
      verdict <- takeWhile (/= '\n') <$> run z3 (script ++ "(check-sat)\n")
      (name, verdict) `shouldBe` (name, "unsat")
    irrational <- taskNamed "no rational squares to two" tasks
    script <- either fail pure (SMT.taskQuery irrational)
    takeWhile (/= '\n') <$> run z3 (script ++ "(check-sat)\n") >>= (`shouldNotBe` "unsat")
  it "refutes a law true only for reals with a float the evaluator confirms" $ solver $ \z3 -> do
    (program, tasks) <- portfolio
    t <- taskNamed "adding one grows a float" tasks
    refutation z3 program t >>= (`shouldBe` "refuted")
  it "reads rational and decimal counterexamples back exactly" $ solver $ \z3 -> forM_
    [ "for all (x :: Rational) => 2 * x != 1 end for all", "for all (x :: Decimal) => 10 * x != 3 end for all" ] $ \body -> do
      (program, [t]) <- compiled (law body)
      refutation z3 program t >>= (`shouldBe` "refuted")
  it "keeps Decimal exact: no scale, rounding or bound, as LawSpec's arithmetic is" $ solver $ \z3 -> do
    -- Exact in LawSpec (a / 3 is a Rational), so exact here; an 18-digit
    -- decimal encoding would refute it.
    (_, [t]) <- compiled (law "for all (a :: Decimal) => (a / 3) * 3 = a end for all")
    script <- either fail pure (SMT.taskQuery t)
    takeWhile (/= '\n') <$> run z3 (script ++ "(check-sat)\n") >>= (`shouldBe` "unsat")
    (_, [huge]) <- compiled (law "for all (a :: Decimal) => a * 1000000000000000000000000 / 1000000000000000000000000 = a end for all")
    hugeScript <- either fail pure (SMT.taskQuery huge)
    takeWhile (/= '\n') <$> run z3 (hugeScript ++ "(check-sat)\n") >>= (`shouldBe` "unsat")
    -- Rounding and a non-terminating conversion are not encoded.
    (_, [rounded]) <- compiled (law "for all (a :: Decimal) => prelude.round a 2 = a end for all")
    SMT.taskQuery rounded `shouldSatisfy` isLeftWith "round"
    (_, [converted]) <- compiled (law "for all (n :: Rational) => prelude.Decimal n = prelude.Decimal n end for all")
    SMT.taskQuery converted `shouldSatisfy` isLeftWith "power of ten"
  it "refuses data with an IEEE field, whose equality is not structural" $ do
    (_, [t]) <- compiled (law "for all (p :: Point) => p = p end for all" `withType` "type Point is a record{ x :: Float64 } end type")
    SMT.taskQuery t `shouldSatisfy` either (isInfixOf "IEEE float") (const False)
  where
    isLeftWith text = either (isInfixOf text) (const False)
    withType source declaration = let (header, rest) = break (== '\n') source in header ++ "\n\n" ++ declaration ++ rest
