-- | Clojure runs over Java, as Groovy and C# run over their hosts' models:
-- the program's model is the Java target's, compiled by the JDK's compiler
-- from java/src, and what a user writes is Clojure. Each unit's adapters
-- are functions of a namespace, called through a generated Java bridge that
-- converts the model's records to maps, lists to vectors and failures to
-- ex-info; each unit's laws are clojure.test tests whose properties run on
-- test.check with LawSpec's generators.
-- ref:DEC-clojure-over-java ref:DEC-clojure-property-library
module LawSpec.Clojure.Emit (clojureFromJava, clojureLayout, clojureTestTitle) where

import Data.Char (toUpper)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, stripPrefix)
import Data.Maybe (listToMaybe)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..), PlannedProperty(..))
import LawSpec.TestNames (unitTestNames, lawWords, kindSuffix)
import LawSpec.Clojure.Bridge
import LawSpec.Clojure.Tests
import LawSpec.ClojureSources (clojureSource)

-- | The Clojure project from the Java target's files for the same plan.
clojureFromJava :: Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
clojureFromJava plan javaFiles = do
  converted <- concat <$> mapM convert javaFiles
  pure (converted ++ runtime)
  where
    units = [C.idText (C.unitId (plannedUnit pu)) | pu <- plannedUnits plan]
    -- The Java class of a unit: example.parse_port is example.ParsePort.
    javaClass unit = let parts = splitOn '.' unit
                     in intercalate "/" (init parts ++ [concatMap capital (splitOn '_' (last parts))])
    unitOfClass path = listToMaybe [u | u <- units, javaClass u ++ ".java" == path]
    diagnose message = Left [Diagnostic "target" message Nothing]
    convert a
      | path `elem` ["src/test/java/lawspec/testing/LawSpecOrder.java", "src/test/resources/junit-platform.properties"] = pure []
      -- The built-in units' default handlers stay Java.
      | ownership a == "user", Just rest <- stripPrefix "src/main/java/" path, "lawspec/" `isPrefixOf` rest =
          pure [a { artifactPath = "java/src/" ++ rest }]
      | ownership a == "user", Just rest <- stripPrefix "src/main/java/" path, ".java" `isSuffixOf` rest = do
          stub <- either (\e -> diagnose ("Clojure bridge for " ++ rest ++ ": " ++ e)) Right (parseStub (artifactContent a))
          let unit = maybe (classUnit rest) id (unitOfClass rest)
              ns = namespaceOf unit
              user = clojureStub unit ns stub
          pure [ Artifact ("java/src/" ++ rest) (bridgeJava ns stub) "generated" "source"
               , AdapterArtifact ("src/" ++ clojurePath ns) user "user" "source" user ]
      | Just rest <- stripPrefix "src/main/java/" path = pure [a { artifactPath = "java/src/" ++ rest }]
      | Just rest <- stripPrefix "src/test/java/" path, ".java" `isSuffixOf` rest, "@Test" `isInfixOf` artifactContent a = do
          let className = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse rest)))
              directory = take (length rest - length className - 5) rest
              package = intercalate "." (filter (not . null) (splitOn '/' directory))
              cases = lawCases className (artifactContent a)
              casesClass = (if null package then "" else package ++ ".") ++ casesClassName className
              unitTest = listToMaybe [pu | pu <- plannedUnits plan, javaTestPath (C.idText (C.unitId (plannedUnit pu))) == path]
              ns = case unitTest of
                Just pu -> namespaceOf (C.idText (C.unitId (plannedUnit pu))) ++ "-lawspec-test"
                Nothing -> (if null package then "" else package ++ ".") ++ kebab className
              title name = maybe (kebab name) (`clojureTestTitle` name) unitTest
          pure [ Artifact ("java/test/" ++ directory ++ casesClassName className ++ ".java") (casesJava cases) "generated" "test"
               , Artifact ("test/" ++ clojurePath ns) (testNamespace ns unitTest casesClass title cases) "generated" "test" ]
      | Just rest <- stripPrefix "src/test/java/" path =
          pure [a { artifactPath = "java/test/" ++ rest
                  , artifactContent = replaceAll "org.jetbrains.jetCheck." "lawspec.testing.check." (artifactContent a) }]
      | otherwise = pure [a]
      where path = artifactPath a
    -- A class no unit names: its package and kebab name.
    classUnit rest = let parts = splitOn '/' (take (length rest - 5) rest)
                     in intercalate "." (init parts ++ [kebab (last parts)])
    runtime =
      [ Artifact "src/lawspec/clojure.clj" (clojureSource "src/lawspec/clojure.clj") "generated" "source"
      , Artifact "src/lawspec/build.clj" (clojureSource "src/lawspec/build.clj") "generated" "source"
      , Artifact "java/src/lawspec/clojure/LawSpecClojure.java" (clojureSource "java/lawspec/clojure/LawSpecClojure.java") "generated" "source"
      , Artifact "test/lawspec/check.clj" (clojureSource "test/lawspec/check.clj") "generated" "test"
      , Artifact "test/lawspec/test.clj" (clojureSource "test/lawspec/test.clj") "generated" "test"
      , Artifact "test/lawspec/test_runner.clj" (clojureSource "test/lawspec/test_runner.clj") "generated" "test" ] ++
      [ Artifact ("java/test/lawspec/testing/check/" ++ file) (clojureSource ("java-test/lawspec/testing/check/" ++ file)) "generated" "test"
      | file <- ["Assertions.java", "Draws.java", "GenerationEnvironment.java", "Generator.java", "IntDistribution.java", "PropertyChecker.java"] ]

-- | A project's own source and test directories, when it names them: the
-- namespaces move there; the Java model stays in java/.
clojureLayout :: Maybe String -> Maybe String -> [Artifact] -> [Artifact]
clojureLayout sourceDir testDir = map move
  where
    move a = maybe a (\p -> a { artifactPath = p }) (relocate (artifactPath a))
    relocate path =
      listToMaybe [ d ++ "/" ++ rest | (Just d, base) <- [(sourceDir, "src/"), (testDir, "test/")]
                  , Just rest <- [stripPrefix base path] ]

-- | A unit's clojure.test namespace over its law cases.
testNamespace :: String -> Maybe PlannedUnit -> String -> (String -> String) -> LawCases -> String
testNamespace ns unit casesClass title cases = unlines $
  [ ";; Generated by LawSpec. Do not edit."
  , "(ns " ++ ns
  , "  " ++ show (maybe ("Tests of " ++ casesClass ++ ".") (\pu -> "The laws of " ++ C.idText (C.unitId (plannedUnit pu)) ++ ".") unit)
  , "  (:require [clojure.test :refer [deftest]]"
  , "            [lawspec.test :as law]))"
  , ""
  , "(def ^:private cases (law/cases " ++ show casesClass ++ "))" ] ++
  concat [ [ ""
           , "(deftest " ++ (case skip of Just reason -> "^{:lawspec/skip " ++ show reason ++ "} "; Nothing -> "") ++ title name
           , "  " ++ maybe ("(law/holds cases " ++ show name ++ "))") (\reason -> "(law/skip " ++ show reason ++ "))") skip ]
         | (name, skip) <- casesTests cases ] ++
  [ ""
  , "(def lawspec-tests"
  , "  \"The tests in their order.\""
  , "  [" ++ intercalate "\n   " ["#'" ++ title name | (name, _) <- casesTests cases] ++ "])"
  , ""
  , "(def lawspec-schedule"
  , "  \"How the harness runs them: order random shuffles them by the run's seed; parallel runs them at once.\""
  , "  {:order " ++ (if casesOrderRandom cases then ":random" else ":declared") ++ ", :parallel " ++ (if casesParallel cases then "true" else "false") ++ "})"
  , ""
  , "(defn test-ns-hook []"
  , "  (law/run " ++ show ns ++ " lawspec-tests lawspec-schedule))" ]

-- | A law case's test: the law's words, a double dash and the kind of test
-- (example-0, boundary-1, property, skipped, known-failing).
clojureTestTitle :: PlannedUnit -> String -> String
clojureTestTitle pu name =
  case [ c ++ kindSuffix "clojure" kind | (j, c) <- zip (unitTestNames "java" labels) (unitTestNames "clojure" labels)
       , Just ('_' : kind) <- [stripPrefix j name] ] ++
       [ "benchmark--" ++ intercalate "-" (lawWords n) | (n, _) <- benchmarks, name == "benchmark" ++ concatMap capital (lawWords n) ] of
    t : _ -> t
    [] -> kebab name
  where
    labels = map (C.propertyName . plannedProperty) (plannedProperties pu)
    benchmarks = maybe [] C.harnessBenchmarks (C.unitHarnessSettings (plannedUnit pu))

capital :: String -> String
capital (c : cs) = toUpper c : cs
capital [] = []

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : b) -> a : splitOn c b

-- The Java test file of a unit (LawSpec.TestManifest's for Java).
javaTestPath :: String -> String
javaTestPath unit = "src/test/java/" ++ concatMap (++ "/") (init parts) ++ concatMap capital (splitOn '_' (last parts)) ++ "LawSpecTest.java"
  where parts = splitOn '.' unit

replaceAll :: String -> String -> String -> String
replaceAll old new = go
  where
    go [] = []
    go s@(c : rest)
      | Just after <- stripPrefix old s = new ++ go after
      | otherwise = c : go rest
