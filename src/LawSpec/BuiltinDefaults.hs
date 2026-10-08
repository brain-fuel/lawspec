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
import Data.List (intercalate, isPrefixOf)
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
      adapters <- concat <$> mapM adapter present
      copies <- concat <$> mapM packageCopies (if target == "go" then units else [])
      tests <- sequence
        [ if null source then Left ("no vector test " ++ file ++ " for " ++ target)
          else (\c -> Artifact path c "generated" "test") <$> resolve target datas (fill target datas "crypto" source)
        | "lawspec.crypto" `elem` map name present, (path, file) <- vectorTests target
        , let source = defaultSource (directory target ++ "/" ++ file) ]
      companions <- sequence
        [ (\c -> Artifact path c "generated" "source") <$> resolve target datas (fill target datas (shortName (name u)) source)
        | u <- present, (path, file) <- companionFiles target (name u)
        , let source = defaultSource (directory target ++ "/" ++ file), not (null source) ]
      let replaced = map artifactPath (adapters ++ copies ++ tests ++ companions)
      pure ([a | a <- artifacts, artifactPath a `notElem` replaced] ++ adapters ++ copies ++ tests ++ companions)
  where
    name = C.idText . C.unitId
    present = [u | u <- units, name u `elem` defaultedUnits, not (null (ownAbilities u))]
    adapter u = do
      let short = shortName (name u)
          source = defaultSource (directory target ++ "/" ++ short ++ extension target)
      if null source then Left ("no default handlers of " ++ name u ++ " for " ++ target) else do
        content <- resolve target datas (fill target datas (shortName (name u)) source)
        pure [Artifact (adapterPath target (name u)) content "generated" "source"]
    -- Each Go package has its own copy of the abilities it uses, so a unit
    -- that imports a built-in unit gets its default handlers in its package.
    packageCopies u
      | name u `elem` defaultedUnits = pure []
      | otherwise = sequence
          [ (\c -> Artifact (goDirectory (name u) ++ "/lawspec_defaults_" ++ shortName owner ++ ".go") c "generated" "source")
              <$> resolve target datas (fill target datas (shortName (name u)) source)
          | owner <- nubOrd [C.idText (C.abilityOwner a) | a <- C.unitAbilities u]
          , owner `elem` defaultedUnits
          , let source = defaultSource ("go/" ++ shortName owner ++ ".go"), not (null source) ]
    nubOrd = foldr (\x seen -> if x `elem` seen then seen else x : seen) []

goDirectory :: String -> String
goDirectory = map (\c -> if c == '.' then '/' else c)

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
  "erlang" -> "src/lawspec_" ++ short ++ ".erl"
  "elixir" -> "lib/lawspec_" ++ short ++ ".ex"
  "gleam" -> "src/lawspec/" ++ short ++ ".gleam"
  _ -> short
  where short = shortName unit

-- Files a unit's default handlers keep beside their module: Rust's crypto
-- primitives, which the vector test includes on its own.
companionFiles :: String -> String -> [(String, String)]
companionFiles target unit = case (target, unit) of
  ("rust", "lawspec.crypto") -> [("src/lawspec/crypto_primitives.rs", "crypto_primitives.rs")]
  _ -> []

-- The vector tests: where each goes, and its source. Go's encapsulation
-- vectors need Go 1.26's crypto/mlkem/mlkemtest, so they have a file of their
-- own, built only by Go 1.26 and later.
vectorTests :: String -> [(String, String)]
vectorTests target = case target of
  "go" -> [("lawspec/crypto/vectors_test.go", "crypto_vectors.go"), ("lawspec/crypto/vectors_go126_test.go", "crypto_vectors_go126.go")]
  -- Python's library lacks deterministic encapsulation and signing and
  -- expanded keys, so its test also gets a plain reference of both standards.
  "python" -> [("tests/test_lawspec_crypto_vectors.py", "crypto_vectors.py"), ("tests/lawspec_crypto_reference.py", "crypto_reference.py")]
  _ -> [(p, "crypto_vectors" ++ extension target) | Just p <- [vectorTestPath target]]

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
-- @@PACKAGE@@ is the Go package the file is in.
-- @@VECTOR_LINES@@ is the vectors without their comments, as string
-- literals separated by commas, for targets whose string constants are
-- bounded (the JVM's are at most 65535 bytes).
fill :: String -> [C.DataDeclaration] -> String -> String -> String
fill _ _ package = replace "@@PACKAGE@@" package . replace "@@VECTORS@@" vectors . replace "@@VECTOR_LINES@@" vectorLines
  where
    vectors = defaultSource "vectors.txt"
    vectorLines = intercalate ",\n" ["    \"" ++ l ++ "\"" | l <- lines vectors, not (null l), take 1 l /= "#"]

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
