-- | Source references are chosen from output-directory metadata before code
-- is printed. Relocating files must never rewrite a generated string literal.
-- ref:DEC-readable-output-default ref:DEC-adapter-ownership
module LawSpec.OutputLayout (defaultDirectories, sourceImportRoot) where

import Data.List (intercalate, isPrefixOf)

defaultDirectories :: String -> (FilePath, FilePath)
defaultDirectories target = case target of
  "java" -> ("src/main/java", "src/test/java")
  "kotlin" -> ("src/main/kotlin", "src/test/kotlin")
  "scala" -> ("src/main/scala", "src/test/scala")
  "python" -> ("src", "tests")
  "rust" -> ("src", "tests")
  "elixir" -> ("lib", "test")
  "fsharp" -> ("src", "tests")
  "csharp" -> ("src", "tests")
  "swift" -> ("src", "tests")
  "go" -> ("", "")
  _ -> ("src", "test")

-- | The source directory relative to a test artifact's enclosing directories.
-- Both canonical and custom layouts use this before assembling import nodes.
sourceImportRoot :: String -> Maybe FilePath -> Maybe FilePath -> [FilePath] -> FilePath
sourceImportRoot target givenSource givenTests nested = normalize $
  relative (parts tests ++ nested) (parts source)
  where
    defaults = defaultDirectories target
    source = maybe (fst defaults) id givenSource
    tests = maybe (snd defaults) id givenTests
    parts "" = []
    parts text = case break (== '/') text of
      (part, []) -> [part]
      (part, _ : rest) -> part : parts rest
    relative (a : as) (b : bs) | a == b = relative as bs
    relative from to = intercalate "/" (replicate (length from) ".." ++ to)
    normalize "" = "."
    normalize value | ".." `isPrefixOf` value = value
                    | otherwise = "./" ++ value
