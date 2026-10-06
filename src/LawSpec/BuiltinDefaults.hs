-- The default handlers of the built-in abilities (LawSpec.Builtins), on each
-- target. A built-in unit's adapter module, where a user unit's production
-- handlers would be written by hand, is generated instead from the reviewed
-- sources under runtime/defaults/<target>/<unit>, and owned by the compiler.
-- A program that uses lawspec.crypto also gets a test of the primitives
-- against NIST's known-answer vectors (runtime/defaults/vectors.txt).
--
-- The sources name the units' data types as @@Type@@ and constructors as
-- @@Type/Constructor@@; each becomes the target's native name, which depends
-- on the program (a type a user unit also declares is qualified by its
-- unit). @@VECTORS@@ is the vectors' text, inside a raw string literal.
module LawSpec.BuiltinDefaults (withBuiltinDefaults, adapterPath, vectorTestPath) where

import Data.Char (toUpper)
import Data.List (isPrefixOf)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.AbilityNames (ownAbilities)
import LawSpec.Builtins (defaultedUnits)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.PythonTypes (pythonDataType)
import LawSpec.WebTypes (webDataType)
import LawSpec.GoData (goDataType)
import LawSpec.JavaData (javaDataType)
import LawSpec.KotlinData (kotlinDataType)
import LawSpec.HaskellData (haskellDataType)
import LawSpec.RustData (rustDataType)

-- Replace each built-in unit's adapter module with its default handlers, and
-- add the vector test when lawspec.crypto is used.
withBuiltinDefaults :: String -> [C.DataDeclaration] -> [C.Unit] -> [Artifact] -> Either String [Artifact]
withBuiltinDefaults target datas units artifacts
  | null present = Right artifacts
  | otherwise = do
      adapters <- mapM adapter present
      let vectors = [ Artifact path (fill target datas (defaultSource (directory target ++ "/" ++ file))) "generated" "test"
                    | "lawspec.crypto" `elem` map name present, Just (path, file) <- [vectorTest target] ]
      tests <- mapM (\a -> (\c -> a { artifactContent = c }) <$> resolve target datas (artifactContent a)) vectors
      let replaced = map artifactPath (adapters ++ tests)
      pure ([a | a <- artifacts, artifactPath a `notElem` replaced] ++ adapters ++ tests)
  where
    name = C.idText . C.unitId
    present = [u | u <- units, name u `elem` defaultedUnits, not (null (ownAbilities u))]
    adapter u = do
      let short = shortName (name u)
          source = defaultSource (directory target ++ "/" ++ short ++ extension target)
      if null source then Left ("no default handlers of " ++ name u ++ " for " ++ target) else do
        content <- resolve target datas (fill target datas source)
        pure (Artifact (adapterPath target (name u)) content "generated" "source")

shortName :: String -> String
shortName = reverse . takeWhile (/= '.') . reverse

capital :: String -> String
capital (c : cs) = toUpper c : cs
capital [] = []

directory :: String -> String
directory target = target

extension :: String -> String
extension target = case target of
  "python" -> ".py"
  "javascript" -> ".mjs"
  "typescript" -> ".ts"
  "go" -> ".go"
  "java" -> ".java"
  "kotlin" -> ".kt"
  "haskell" -> ".hs"
  "rust" -> ".rs"
  _ -> ""

-- Where each target keeps a unit's adapter module.
adapterPath :: String -> String -> String
adapterPath target unit = case target of
  "python" -> "src/lawspec/" ++ short ++ ".py"
  "javascript" -> "src/lawspec/" ++ short ++ ".mjs"
  "typescript" -> "src/lawspec/" ++ short ++ ".ts"
  "go" -> "lawspec/" ++ short ++ "/adapter.go"
  "java" -> "src/main/java/lawspec/" ++ capital short ++ ".java"
  "kotlin" -> "src/main/kotlin/lawspec/" ++ capital short ++ ".kt"
  "haskell" -> "src/Lawspec/" ++ capital short ++ ".hs"
  "rust" -> "src/lawspec/" ++ short ++ ".rs"
  _ -> short
  where short = shortName unit

-- The vector test: where it goes, and its source.
vectorTest :: String -> Maybe (String, String)
vectorTest target = (\p -> (p, "crypto_vectors" ++ extension target)) <$> vectorTestPath target

vectorTestPath :: String -> Maybe String
vectorTestPath target = case target of
  "python" -> Just "tests/test_lawspec_crypto_vectors.py"
  "javascript" -> Just "test/lawspec_crypto_vectors.test.mjs"
  "typescript" -> Just "test/lawspec_crypto_vectors.test.ts"
  "go" -> Just "lawspec/crypto/vectors_test.go"
  "java" -> Just "src/test/java/lawspec/CryptoVectorsTest.java"
  "kotlin" -> Just "src/test/kotlin/lawspec/CryptoVectorsTest.kt"
  "haskell" -> Just "test/Lawspec/CryptoVectorsSpec.hs"
  "rust" -> Just "tests/lawspec_crypto_vectors.rs"
  _ -> Nothing

-- @@VECTORS@@ first: the vectors are hex and comments, so a raw string
-- literal holds them on every target.
fill :: String -> [C.DataDeclaration] -> String -> String
fill _ _ = replace "@@VECTORS@@" (defaultSource "vectors.txt")

replace :: String -> String -> String -> String
replace old new = go
  where
    go text@(c : rest)
      | old `isPrefixOf` text = new ++ go (drop (length old) text)
      | otherwise = c : go rest
    go [] = []

-- Each @@Type@@ and @@Type/Constructor@@, named as the target names the
-- built-in unit's declaration.
resolve :: String -> [C.DataDeclaration] -> String -> Either String String
resolve target datas = go
  where
    go ('@' : '@' : rest) = case break (== '@') rest of
      (placeholder, '@' : '@' : after) | not (null placeholder) -> (++) <$> named placeholder <*> go after
      _ -> ('@' :) . ('@' :) <$> go rest
    go (c : rest) = (c :) <$> go rest
    go [] = Right []
    named placeholder = case break (== '/') placeholder of
      (typeName, '/' : constructor) -> do
        native <- typeNamed typeName
        pure (case target of
          _ | target `elem` ["java", "kotlin"] -> native ++ "." ++ constructor
            | target == "rust" -> native ++ "::" ++ constructor
            | otherwise -> native ++ constructor)
      (typeName, _) -> typeNamed typeName
    typeNamed short = case [d | d <- datas, builtin (C.idText (C.dataId d)), shortName' (C.idText (C.dataId d)) == short] of
      d : _ -> nativeType (C.Constructor (C.idText (C.dataId d)) [])
      [] -> Left ("no built-in type " ++ short)
    builtin identity = any (\u -> (u ++ "::type::") `isPrefixOf` identity) defaultedUnits
    shortName' = reverse . takeWhile (/= ':') . reverse
    nativeType t = case target of
      "python" -> pythonDataType datas t
      "javascript" -> webDataType datas t
      "typescript" -> webDataType datas t
      "go" -> goDataType datas t
      "java" -> javaDataType datas t
      "kotlin" -> kotlinDataType datas t
      "haskell" -> haskellDataType datas t
      "rust" -> rustDataType datas t
      _ -> Left ("no default handlers for " ++ target)
