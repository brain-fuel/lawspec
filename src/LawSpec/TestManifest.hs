-- Which generated tests check which law, for running a subset of them.
--
-- Every target writes one test file per unit, and names a law's tests after
-- its label (LawSpec.TestNames), or, in JavaScript and TypeScript, by the
-- label itself. The manifest gives each law its tests' name, its position,
-- its unit's test file, the law's dependency key (the plan key of
-- LawSpec.Dependencies), and its harness: tags, and whether it is skipped or
-- known to fail. A runner can tell which laws an edit affects, select their
-- tests by name and by tag, and knows which tests not to expect.
module LawSpec.TestManifest (TestEntry(..), testManifest, unitTestPath) where

import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, stripPrefix)
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Dependencies (dependencyGraph, keyOf, lawReferences)
import LawSpec.TestNames (unitTestNames)

data TestEntry = TestEntry
  { entryLaw :: Id, entryUnit :: String, entryLabel :: String, entryIndex :: Int
  , entryFile :: FilePath, entryKey :: String, entryCallsAdapters :: Bool
  -- The harness plane: the tests' base name, tags, skip and known failing.
  , entryName :: String, entryTags :: [String], entrySkip :: Maybe String
  , entryKnownFailing :: Maybe String }
  deriving (Eq, Show)

-- The manifest for one target, with its test directory if not the default.
testManifest :: String -> Maybe String -> Program -> [TestEntry]
testManifest target testDir program =
  [ TestEntry (propertyId p) unit (unit ++ "::" ++ propertyName p) index
      (relocated (unitTestPath target unit)) (keyOf graph (show (programMachineBits program, p)) (lawReferences graph p))
      (any (`S.notMember` definitions) (concatMap callees (propertyExpressions p)) ||
        -- A native production handler is native code too.
        any (native . snd) [h | h@(a, _) <- propertyHandlers p, not (isFail a)])
      testName (harnessTags (propertyHarness p)) (harnessSkip (propertyHarness p)) (harnessKnownFailing (propertyHarness p))
  | u <- programUnits program
  , let unit = idText (unitId u)
        names = if target `elem` ["javascript", "typescript"] then [unit ++ "::" ++ propertyName p | p <- unitProperties u]
          else unitTestNames target (map propertyName (unitProperties u))
  , (index, p, testName) <- zip3 [0 ..] (unitProperties u) names ]
  where
    graph = dependencyGraph (programDataDeclarations program) (programUnits program)
    native h = case h of
      ProductionHandler -> True
      RecordingHandler inner -> native inner
      SpecHandler _ -> False
    definitions = S.fromList [declarationId (definitionDeclaration d) | u <- programUnits program, d <- unitDefinitions u]
    -- A custom test directory replaces the default one, as the emitters' layout does.
    relocated path = case testDir of
      Just directory | Just rest <- stripPrefix (defaultTestDirectory target ++ "/") path -> directory ++ "/" ++ rest
      _ -> path

defaultTestDirectory :: String -> String
defaultTestDirectory target = case target of
  "java" -> "src/test/java"
  "kotlin" -> "src/test/kotlin"
  "python" -> "tests"
  "rust" -> "tests"
  "go" -> ""
  _ -> "test"

-- The test file each target generates for a unit, in the default layout.
unitTestPath :: String -> String -> FilePath
unitTestPath target unit = case target of
  "python" -> "tests/test_" ++ intercalate "_" parts ++ "_lawspec.py"
  "javascript" -> "test/" ++ intercalate "_" parts ++ ".lawspec.test.mjs"
  "typescript" -> "test/" ++ intercalate "_" parts ++ ".lawspec.test.ts"
  "go" -> intercalate "/" parts ++ "/lawspec_test.go"
  "haskell" -> "test/" ++ intercalate "/" (map capitalWords parts) ++ "Spec.hs"
  "rust" -> "tests/" ++ map (\c -> if isAlphaNum c || c == '_' then c else '_') unit ++ "_lawspec.rs"
  jvm -> "src/test/" ++ jvm ++ "/" ++ intercalate "/" (init parts ++ [capitalWords (last parts)]) ++ "LawSpecTest" ++
    (if jvm == "kotlin" then ".kt" else ".java")
  where
    parts = splitOn '.' unit
    capitalWords = concatMap capital . splitOn '_'
    capital (c : rest) = toUpper c : rest
    capital [] = []
    splitOn c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : b) -> a : splitOn c b

-- The declarations a law calls directly; definitions cannot call adapters.
callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall callee args -> callee : concatMap callees args
  _ -> concatMap callees (children e)
