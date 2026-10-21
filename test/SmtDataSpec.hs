-- | Data in Z3 tasks (lawspec-smtlib-v2): enums, records, alternatives,
-- Maybe and List become SMT datatypes, a datum's field refinements are its
-- well-formedness, and a counterexample over data is read back and
-- confirmed by the reference evaluator.
module SmtDataSpec (test_smtDataTasks) where

import Control.Monad (forM_)
import Data.Either (isLeft)
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

compile :: String -> Either String C.Program
compile body = either (Left . show) Right (compileCoreCanonical 64 S.defaultGeneration
  [S.Source "data.lawspec" ("unit smt.data\n\n" ++ body ++ "\nend unit\n")])

tasks :: String -> IO (C.Program, [SMT.ProofTask])
tasks body = do
  program <- either fail pure (compile body)
  prepared <- either (fail . show) pure (SMT.proofTasks program)
  pure (program, prepared)

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

run :: FilePath -> String -> IO String
run binary script = do
  (status, output, errors) <- readProcessWithExitCode binary ["-in", "-smt2", "-t:10000"] script
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure output

answers :: FilePath -> String -> IO [String]
answers binary body = do
  (_, prepared) <- tasks body
  mapM (\task -> either fail (fmap (head . lines) . run binary . (++ "(check-sat)\n")) (SMT.taskQuery task)) prepared

-- | Z3's values for a satisfiable task's counterexample query, checked.
confirmed :: FilePath -> String -> IO String
confirmed binary body = do
  (program, [task]) <- tasks body
  query <- either fail pure (SMT.taskCounterexample task)
  let names = map fst (SMT.counterexampleInputs query)
  output <- run binary (SMT.counterexampleScript query ++ "(check-sat)\n(get-value (" ++ unwords names ++ "))\n")
  let (verdict, rest) = break (== '\n') output
  verdict `shouldBe` "sat"
  pure (checkStatus (validateCounterexample program task rest))

refunds :: String
refunds = unlines
  [ "type Decision is one of | Approved | ReviewRequired | Rejected end type\n"
  , "type Request is a record{ captured of type Whole requested of type Whole flagged of type Bool } end type\n"
  , "function decide (request of type Request) -> Decision is"
  , "  first matching case of request:"
  , "    when record{requested = 0} then Approved"
  , "    when it.requested > it.captured then Rejected"
  , "    when it.flagged then ReviewRequired"
  , "    otherwise Approved"
  , "  end case"
  , "end function\n" ]

law :: String -> String
law text = "law selected is definition: " ++ text ++ " end definition end law\n"

test_smtDataTasks :: Spec
test_smtDataTasks = describe "SMT data tasks" $ do
  it "declares data types only in v2 tasks, leaving integer tasks v1" $ do
    (_, [plain]) <- tasks (law "for all (n :: Integer) => n + 1 > n end for all")
    SMT.taskEncoding plain `shouldBe` SMT.SmtLibV1
    (_, [datum]) <- tasks (refunds ++ law "for all (request :: Request) => request.requested > request.captured implies decide request = Rejected end for all")
    SMT.taskEncoding datum `shouldBe` SMT.SmtLibV2
    script <- either fail pure (SMT.taskQuery datum)
    script `shouldSatisfy` isInfixOf "(declare-datatypes"
    script `shouldSatisfy` isInfixOf "lawspec-smtlib-v2"
  it "refuses a type with no finite value instead of declaring an empty SMT datatype" $ do
    (_, [task]) <- tasks ("type Endless is a record{ next of type Endless } end type\n" ++
      law "for all (e :: Endless) => false end for all")
    SMT.taskQuery task `shouldSatisfy` either (isInfixOf "no finite value") (const False)
  it "proves record and enum laws, including a match over a record" $ solver $ \binary -> do
    verdicts <- answers binary (refunds ++ concat
      [ law "for all (request :: Request) => request.requested > request.captured implies decide request = Rejected end for all"
          `withName` "rejects"
      , law "for all (captured :: Whole) (flagged :: Bool) => decide (Request record{captured = captured, requested = 0, flagged = flagged}) = Approved end for all"
          `withName` "zero" ])
    verdicts `shouldBe` ["unsat", "unsat"]
  it "proves laws over Maybe and List values" $ solver $ \binary -> do
    verdicts <- answers binary (concat
      [ law "for all (m :: Maybe Int32) => (first matching case of m: when Just x then x >= -2147483648 when Nothing then true end case) end for all"
          `withName` "maybe"
      , law "for all (xs :: List Int8) => (first matching case of xs: when Cons h rest then h <= 127 when Nil then true end case) end for all"
          `withName` "list" ])
    verdicts `shouldBe` ["unsat", "unsat"]
  it "keeps field refinements: a datum's field always satisfies its type" $ solver $ \binary -> do
    let positive = "type Pos is a record{ n of type (v :: Int32 where v > 0) } end type\n"
    answers binary (positive ++ law "for all (p :: Pos) => p.n > 0 end for all") `shouldReturn` ["unsat"]
    answers binary (positive ++ law "for all (p :: Pos) => p.n > 1 end for all") `shouldReturn` ["sat"]
    confirmed binary (positive ++ law "for all (p :: Pos) => p.n > 1 end for all") `shouldReturn` "refuted"
  it "refutes a mutant transition with a counterexample the evaluator confirms" $ solver $ \binary -> do
    let orders mutant = unlines
          [ "type State is one of | Pending | Shipped | Cancelled end type\n"
          , "type Action is one of | Ship | Cancel end type\n"
          , "function next (state of type State) (action of type Action) -> State is"
          , "  first matching case of action:"
          , "    when Ship then if state = Pending then Shipped else state end if"
          , "    when Cancel then " ++ (if mutant then "Cancelled" else "if state = Shipped then Shipped else Cancelled end if")
          , "  end case"
          , "end function\n"
          , law "for all (state :: State) (action :: Action) => state = Shipped implies next state action = Shipped end for all" ]
    answers binary (orders False) `shouldReturn` ["unsat"]
    confirmed binary (orders True) `shouldReturn` "refuted"
  it "leaves v1 tasks with no datatype declarations" $ do
    (_, prepared) <- tasks (law "for all (n :: Int8) => n * n >= 0 end for all")
    forM_ prepared $ \task -> SMT.taskQuery task `shouldSatisfy` either (const True) (not . isInfixOf "declare-datatypes")
    map SMT.taskQuery prepared `shouldSatisfy` all (not . isLeft)
  where
    withName text name = case break (== ' ') (drop (length ("law " :: String)) text) of
      (_, rest) -> "law " ++ name ++ rest
