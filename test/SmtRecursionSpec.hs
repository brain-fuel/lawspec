-- | Recursive definitions in Z3 tasks (lawspec-smtlib-v2): guarded defining
-- axioms with fuel, and define-fun-rec as the alternative the host tries
-- next. Only definitions admission proved total are given to Z3.
module SmtRecursionSpec (test_smtRecursion, test_smtInduction) where

import Control.Monad (forM, forM_)
import Data.Aeson (Value(..), object, (.=), decode, encode, toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import qualified LawSpec.Api as API
import LawSpec.SourceText (formatSource)
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
    script `shouldSatisfy` isInfixOf "(=> (|wf#List<Int32>| lawspec_argument_0) (= (|lawspec_function_fuel smt.recursion::count| (lawspec_fuel_next lawspec_fuel) lawspec_argument_0)"
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

-- | The proof tasks of a unit with a harness, through the API.
proofTasksOf :: String -> String -> IO (Maybe Value)
proofTasksOf body harness = pure (decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
  , "verification" .= object ["layers" .= ["proof" :: String]]
  , "sources" .= [object ["path" .= ("induction.lawspec" :: String), "content" .= ("unit smt.induction\n\n" ++ inductionDefinitions ++ body ++
      "\nharness smt.induction.proofs for smt.induction is\n" ++ harness ++ "end harness\nend unit\n")]] ]))))

inductionDefinitions :: String
inductionDefinitions = definitions ++ unlines
  [ "function reverse (xs :: List Int32) -> List Int32 is"
  , "  first matching case of xs :"
  , "    when Nil then []"
  , "    when Cons head tail then append (reverse tail) [head]"
  , "  end case"
  , "end function\n"
  , "function sumTo (n :: Whole) -> Whole is"
  , "  if n = 0 then 0 else n + sumTo (n - 1) end if"
  , "end function\n"
  , "law \"|append adds lengths| is definition: for all (xs :: List Int32) (ys :: List Int32) => count (append xs ys) = count xs + count ys end for all end definition end law"
  , "law \"|append nil| is definition: for all (xs :: List Int32) => append xs [] = xs end for all end definition end law"
  , "law \"|append associates| is definition: for all (xs :: List Int32) (ys :: List Int32) (zs :: List Int32) => append (append xs ys) zs = append xs (append ys zs) end for all end definition end law"
  , "law \"|reverse of append| is definition: for all (xs :: List Int32) (ys :: List Int32) => reverse (append xs ys) = append (reverse ys) (reverse xs) end for all end definition end law"
  , "law \"|reverse twice| is definition: for all (xs :: List Int32) => reverse (reverse xs) = xs end for all end definition end law"
  , "law \"|sum doubles| is definition: for all (n :: Whole) => 2 * sumTo n = n * (n + 1) end for all end definition end law\n" ]

field :: K.Key -> Value -> Maybe Value
field k (Object o) = K.lookup k o
field _ _ = Nothing

textOf :: K.Key -> Value -> String
textOf k v = case field k v of Just (String t) -> T.unpack t; _ -> ""

taskFor :: String -> Maybe Value -> Maybe Value
taskFor law response = case response >>= field "proofTasks" of
  Just (Array ts) -> case [t | t <- toList ts, ("::law::" ++ law) `isSuffixOf` textOf "declaration" t] of
    t : _ -> Just t
    [] -> Nothing
  _ -> Nothing

diagnosticsOf :: Maybe Value -> [String]
diagnosticsOf response = case response >>= field "diagnostics" of
  Just (Array ds) -> map (textOf "message") (toList ds)
  _ -> []

-- | Each case's outcome: its first encoding's, else its alternative's.
caseOutcomes :: FilePath -> Value -> IO [(String, String)]
caseOutcomes z3 task = case field "induction" task >>= field "cases" of
  Just (Array cs) -> forM (toList cs) $ \c -> do
    first <- solve (textOf "script" c)
    outcome <- if first == "unsat" then pure first else maybe (pure first) (solve . textOf "script") (field "alternative" c)
    pure (textOf "case" c, outcome)
  _ -> fail "no induction cases"
  where
    solve script = do
      (status, output, errors) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] (script ++ "(check-sat)\n")
      (status, errors) `shouldBe` (ExitSuccess, "")
      pure (takeWhile (/= '\n') output)

test_smtInduction :: Spec
test_smtInduction = describe "SMT induction" $ do
  let forLaw law settings = "for law " ++ law ++ "\n" ++ concatMap (\s -> "  " ++ s ++ "\n") settings ++ "end for law\n"
  it "plans one task per case of induction on an input, with the cited laws" $ do
    response <- proofTasksOf "" (forLaw "\"|reverse twice|" ["prove by induction on xs", "  using \"|reverse of append|"])
    let plan = taskFor "\"|reverse twice|" response >>= field "induction"
    fmap (textOf "on") plan `shouldBe` Just "xs"
    (plan >>= field "using") `shouldBe` Just (toJSON ["smt.induction::law::\"|reverse of append|" :: String])
    case plan >>= field "cases" of
      Just (Array cs) -> map (textOf "case") (toList cs) `shouldBe` ["xs = Nil", "xs = Cons"]
      _ -> expectationFailure "no cases"
  it "tries induction once on a single structural input by default, and not when told" $ do
    response <- proofTasksOf "" (forLaw "\"|append adds lengths|" ["prove without induction"])
    (taskFor "\"|append nil|" response >>= field "induction" >>= field "asked") `shouldBe` Just (Bool False)
    (taskFor "\"|append adds lengths|" response >>= field "induction") `shouldBe` Nothing
    -- Two structural inputs: no default try.
    (taskFor "\"|append associates|" response >>= field "induction") `shouldBe` Nothing
  it "chooses the encoding and fuel the harness names" $ do
    response <- proofTasksOf "law \"|cons| is definition: for all (x :: Int32) (xs :: List Int32) => count (Cons x xs) = 1 + count xs end for all end definition end law\n"
      (concat [ forLaw "\"|cons|" ["prove by unfolding step by step up to 4 times"]
              , forLaw "\"|append nil|" ["prove by solver recursion"]
              , forLaw "\"|sum doubles|" ["prove by unfolding step by step up to 3 times, then solver recursion"] ])
    (taskFor "\"|cons|" response >>= field "recursion") `shouldBe` Just (object ["encoding" .= ("guarded-axioms" :: String), "fuel" .= (4 :: Int)])
    (taskFor "\"|cons|" response >>= field "alternative") `shouldBe` Nothing
    (taskFor "\"|append nil|" response >>= field "recursion") `shouldBe` Just (object ["encoding" .= ("define-fun-rec" :: String)])
    (taskFor "\"|sum doubles|" response >>= field "alternative" >>= field "recursion") `shouldBe` Just (object ["encoding" .= ("define-fun-rec" :: String)])
  it "refuses a cited law outside the unit, a law citing itself, and a cycle" $ do
    diagnosticsOf <$> proofTasksOf "" (forLaw "\"|reverse twice|" ["prove by induction on xs using \"|missing|"])
      >>= (`shouldSatisfy` any (isInfixOf "the unit has no law \"|missing|"))
    diagnosticsOf <$> proofTasksOf "" (forLaw "\"|reverse twice|" ["prove by induction on xs using \"|reverse twice|"])
      >>= (`shouldSatisfy` any (isInfixOf "cannot cite itself"))
    diagnosticsOf <$> proofTasksOf "" (forLaw "\"|reverse twice|" ["prove by induction on xs using \"|reverse of append|"] ++
                                        forLaw "\"|reverse of append|" ["prove by induction on xs using \"|reverse twice|"])
      >>= (`shouldSatisfy` any (isInfixOf "cite each other in a cycle"))
  it "refuses two encodings for one law" $
    diagnosticsOf <$> proofTasksOf "" (forLaw "\"|append nil|" ["prove by solver recursion", "prove by unfolding step by step"])
      >>= (`shouldSatisfy` any (isInfixOf "two prove by settings"))
  it "proves list laws by induction, citing proved laws" $ solver $ \z3 -> do
    response <- proofTasksOf "" (concat
      [ forLaw "\"|append adds lengths|" ["prove by induction on xs"]
      , forLaw "\"|append associates|" ["prove by induction on xs"]
      , forLaw "\"|reverse of append|" ["prove by induction on xs", "  using \"|append nil|, \"|append associates|"]
      , forLaw "\"|reverse twice|" ["prove by induction on xs", "  using \"|reverse of append|"] ])
    forM_ ["\"|append adds lengths|", "\"|append nil|", "\"|append associates|", "\"|reverse of append|", "\"|reverse twice|"] $ \law -> do
      task <- maybe (fail ("no task for " ++ law)) pure (taskFor law response)
      map snd <$> caseOutcomes z3 task >>= (`shouldBe` ["unsat", "unsat"])
  it "proves an integer countdown law by induction from the lower bound" $ solver $ \z3 -> do
    response <- proofTasksOf "" (forLaw "\"|sum doubles|" ["prove by induction on n"])
    task <- maybe (fail "no task") pure (taskFor "\"|sum doubles|" response)
    caseOutcomes z3 task >>= (`shouldBe` [("n = 0", "unsat"), ("n > 0", "unsat")])
  it "keeps a proof setting's continued lines indented when formatted" $ do
    let source = "unit smt.induction\n\n" ++ inductionDefinitions ++ "\nharness smt.induction.proofs for smt.induction is\n" ++
          forLaw "\"|reverse twice|" ["prove by induction on xs", "using \"|reverse of append|"] ++ "end harness\nend unit\n"
        S.Source _ formatted = formatSource (S.Source "induction.lawspec" source)
    formatted `shouldSatisfy` isInfixOf "    prove by induction on xs\n      using \"|reverse of append|\n  end for law"
  it "leaves a case open without the lemma it needs" $ solver $ \z3 -> do
    response <- proofTasksOf "" (forLaw "\"|reverse twice|" ["prove by induction on xs"])
    task <- maybe (fail "no task") pure (taskFor "\"|reverse twice|" response)
    caseOutcomes z3 task >>= (`shouldSatisfy` any ((/= "unsat") . snd))
