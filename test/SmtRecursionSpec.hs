-- | Recursive definitions in Z3 tasks (lawspec-smtlib-v2): guarded defining
-- axioms with fuel, and define-fun-rec as the alternative the host tries
-- next. Only definitions admission proved total are given to Z3.
module SmtRecursionSpec (test_smtRecursion) where

import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Smt as SMT
import LawSpec.Frontend (compileCoreCanonical)
import qualified LawSpec.Model as S

source :: String -> [S.Source]
source body = [S.Source "recursion.lawspec" ("unit smt.recursion\n\n" ++ definitions ++ body ++ "\nend unit\n")]

definitions :: String
definitions = unlines
  [ "function count (xs :: List Int32) -> Whole is"
  , "  first matching case of xs :"
  , "    when Nil then 0"
  , "    when Cons head tail then 1 + count tail"
  , "  end case"
  , "end function\n"
  , "function append (xs :: List Int32) (ys :: List Int32) -> List Int32 is"
  , "  first matching case of xs :"
  , "    when Nil then ys"
  , "    when Cons head tail then Cons head (append tail ys)"
  , "  end case"
  , "end function\n"
  , "function countdown (n :: Whole) -> Whole is"
  , "  if n = 0 then 0 else 1 + countdown (n - 1) end if"
  , "end function\n" ]

law :: String -> String
law text = "law selected is definition: " ++ text ++ " end definition end law\n"

task :: String -> IO SMT.ProofTask
task body = do
  program <- either (fail . show) pure (compileCoreCanonical 64 S.defaultGeneration (source body))
  prepared <- either (fail . show) pure (SMT.proofTasks program)
  case [t | t <- prepared, C.idText (SMT.taskLaw t) == "smt.recursion::law::selected"] of
    [t] -> pure t
    _ -> fail "expected one task"

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

-- | Z3's answer for each encoding: the task's, then its alternative's.
answers :: FilePath -> String -> IO (String, String)
answers binary body = do
  t <- task body
  script <- either fail pure (SMT.taskQuery t)
  alternative <- maybe (fail "no alternative") (pure . snd) (SMT.taskAlternative t)
  (,) <$> run binary script <*> run binary alternative
  where
    run z3 script = do
      (status, output, errors) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] (script ++ "(check-sat)\n")
      (status, errors) `shouldBe` (ExitSuccess, "")
      pure (takeWhile (/= '\n') output)

test_smtRecursion :: Spec
test_smtRecursion = describe "SMT recursive definitions" $ do
  it "gives a law over a recursive definition guarded axioms with fuel, and define-fun-rec next" $ do
    t <- task (law "for all (x :: Int32) (xs :: List Int32) => count (Cons x xs) = 1 + count xs end for all")
    SMT.taskEncoding t `shouldBe` SMT.SmtLibV2
    SMT.taskRecursion t `shouldBe` Just (SMT.GuardedAxioms SMT.defaultFuel)
    fmap fst (SMT.taskAlternative t) `shouldBe` Just SMT.DefineFunRec
    script <- either fail pure (SMT.taskQuery t)
    -- The axiom holds only on the definition's domain, and a call in the
    -- law starts at the recorded fuel.
    script `shouldSatisfy` isInfixOf "(=> (|wf#List<Int32>| lawspec_argument_0) (= (|lawspec_function smt.recursion::count| (lawspec_fuel_next lawspec_fuel) lawspec_argument_0)"
    script `shouldSatisfy` isInfixOf "(lawspec_fuel_next (lawspec_fuel_next lawspec_fuel_zero))"
    fmap snd (SMT.taskAlternative t) `shouldSatisfy` maybe False (isInfixOf "(define-funs-rec ((|lawspec_function smt.recursion::count|")
  it "keeps a law without recursion as it was" $ do
    t <- task (law "for all (n :: Int32) => n + 1 > n end for all")
    SMT.taskRecursion t `shouldBe` Nothing
    SMT.taskAlternative t `shouldBe` Nothing
    SMT.taskEncoding t `shouldBe` SMT.SmtLibV1
  it "refuses a definition that does not terminate before any task" $
    either show (const "admitted") (compileCoreCanonical 64 S.defaultGeneration
      [S.Source "spin.lawspec" "unit smt.spin\nfunction spin (n :: Integer) -> Integer is spin n end function\nend unit\n"])
      `shouldSatisfy` isInfixOf "no strict structural descent"
  it "proves by unfolding within the fuel" $ solver $ \z3 -> do
    answers z3 (law "for all (x :: Int32) (xs :: List Int32) => count (Cons x xs) = 1 + count xs end for all")
      >>= (`shouldBe` ("unsat", "unsat"))
    answers z3 (law "for all (ys :: List Int32) => append [] ys = ys end for all") >>= (`shouldBe` ("unsat", "unsat"))
  it "knows a recursive result lies in its type, as admission proved" $ solver $ \z3 ->
    answers z3 (law "for all (xs :: List Int32) => count xs >= 0 end for all") >>= (`shouldBe` ("unsat", "unsat"))
  it "leaves deeper inputs to define-fun-rec" $ solver $ \z3 -> do
    answers z3 (law "count [1, 2, 3] = 3") >>= (`shouldBe` ("unknown", "unsat"))
    answers z3 (law "countdown 5 = 5") >>= (`shouldBe` ("unknown", "unsat"))
    answers z3 (law "for all (x :: Int32) => count (append [x] [x, x]) = 3 end for all") >>= (`shouldBe` ("unknown", "unsat"))
  it "never proves a false law, and leaves induction to a later step" $ solver $ \z3 -> do
    answers z3 (law "for all (xs :: List Int32) => count xs > 0 end for all") >>= (`shouldBe` ("unknown", "unknown"))
    answers z3 (law "count [1, 2] = 3") >>= (`shouldSatisfy` (\(a, b) -> a /= "unsat" && b /= "unsat"))
    answers z3 (law "for all (xs :: List Int32) (ys :: List Int32) => count (append xs ys) = count xs + count ys end for all")
      >>= (`shouldBe` ("unknown", "unknown"))
