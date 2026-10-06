-- | Which generated tests check which law, for running a subset of them.
--
-- Every target writes one test file per unit, and names a law's tests by the
-- law's position among the unit's executable laws (law0, law1, ...), or, in
-- JavaScript and TypeScript, by its label. The manifest gives each law that
-- position, its unit's test file, and the law's dependency key (the plan key
-- of LawSpec.Dependencies), so a runner can tell which laws an edit affects
-- and select their tests by name.
module LawSpec.TestManifest (TestEntry(..), testManifest, unitTestPath) where

import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, stripPrefix)
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Dependencies (dependencyGraph, keyOf, lawReferences)

-- | Each generated test is keyed by the law it checks and the digest of what the
-- law reaches, so lawspec test runs only the tests an edit can affect.
-- ref:DEC-incremental-compilation
data TestEntry = TestEntry
  { entryLaw :: Id, entryUnit :: String, entryLabel :: String, entryIndex :: Int
  , entryFile :: FilePath, entryKey :: String, entryCallsAdapters :: Bool }
  deriving (Eq, Show)

-- | The manifest for one target, with its test directory if not the default.
testManifest :: String -> Maybe String -> Program -> [TestEntry]
testManifest target testDir program =
  [ TestEntry (propertyId p) unit (unit ++ "::" ++ propertyName p) index
      (relocated (unitTestPath target unit)) (keyOf graph (show (programMachineBits program, p)) (lawReferences graph p))
      (any (`S.notMember` definitions) (concatMap callees (propertyExpressions p)))
  | u <- programUnits program
  , let unit = idText (unitId u)
  , (index, p) <- zip [0 ..] (unitProperties u) ]
  where
    graph = dependencyGraph (programDataDeclarations program) (programUnits program)
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

-- | The test file each target generates for a unit, in the default layout.
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

-- | The declarations a law calls directly; definitions cannot call adapters.
callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall callee args -> callee : concatMap callees args
  _ -> concatMap callees (children e)
