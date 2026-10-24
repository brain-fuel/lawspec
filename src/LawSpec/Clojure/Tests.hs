-- | A generated JUnit test class as Clojure tests: the class becomes a plain
-- Java class of law cases (its test methods public, its properties run by
-- test.check through lawspec.testing.check), and a clojure.test namespace
-- has a test per case, named in words, with the unit's schedule: its order,
-- or one its seed chooses, and whether its tests run at the same time.
-- ref:DEC-clojure-over-java ref:DEC-clojure-property-library
module LawSpec.Clojure.Tests (LawCases(..), lawCases, casesClassName) where

import Data.Char (isAlphaNum)
import Data.List (isSuffixOf, stripPrefix)

data LawCases = LawCases
  { casesJava :: String
  -- Each test: the case method, and the reason it is skipped.
  , casesTests :: [(String, Maybe String)]
  , casesOrderRandom :: Bool
  , casesParallel :: Bool }

-- | FooLawSpecTest's cases are FooLawCases; FooTest's FooCases.
casesClassName :: String -> String
casesClassName name
  | "LawSpecTest" `isSuffixOf` name = take (length name - 11) name ++ "LawCases"
  | "Test" `isSuffixOf` name = take (length name - 4) name ++ "Cases"
  | otherwise = name ++ "Cases"

-- | The law cases of a test class.
lawCases :: String -> String -> LawCases
lawCases className source =
  let ls = lines (rename (replaceAll "org.jetbrains.jetCheck." "lawspec.testing.check." (replaceAll "org.junit.jupiter.api.Assertions" "lawspec.testing.check.Assertions" source)))
      (java, tests) = go Nothing ls
      ordered = any (("@org.junit.jupiter.api.TestMethodOrder(" `isPrefixOf'`) . trimmed) ls
      parallel = any (("@org.junit.jupiter.api.parallel.Execution(" `isPrefixOf'`) . trimmed) ls
      metadataSize = sum [length name + maybe 0 length skipped | (name,skipped) <- tests]
  -- The Java body is emitted before the Clojure namespace. Resolve its small
  -- metadata projections first, so their thunks do not retain every parsed
  -- Java line alongside the body while it is emitted.
  in ordered `seq` parallel `seq` metadataSize `seq`
       LawCases (unlines java) tests ordered parallel
  where
    rename = replaceWord className (casesClassName className)
    trimmed = dropWhile (== ' ')
    isPrefixOf' p s = take (length p) s == p
    go skip ls = case ls of
      [] -> ([], [])
      l : rest
        | isPrefixOf' "@org.junit.jupiter.api.Disabled(" (trimmed l) ->
            -- The annotation may span lines, its message joined by +.
            let (annotation, after) = closed (l : rest)
            in go (Just (unquote (unwords annotation))) after
        | any (`isPrefixOf'` trimmed l) ["@org.junit.jupiter.api.TestMethodOrder(", "@org.junit.jupiter.api.parallel.Execution("] -> go skip rest
        | trimmed l == "import org.junit.jupiter.api.Test;" -> go skip rest
        -- The cases are made by reflection, so their class is public.
        | Just rest' <- stripPrefix ("class " ++ casesClassName className ++ " ") l ->
            let (java, tests) = go skip rest in (("public class " ++ casesClassName className ++ " " ++ rest') : java, tests)
        -- Its brace on the next line (Allman).
        | l == "class " ++ casesClassName className ->
            let (java, tests) = go skip rest in (("public class " ++ casesClassName className) : java, tests)
        | trimmed l == "@Test", next : rest' <- rest, Just name <- testMethod next ->
            let (java, tests) = go Nothing rest' in (public next : java, (name, skip) : tests)
        | Just after <- stripPrefix "@Test " (trimmed l), Just name <- testMethod after ->
            let (java, tests) = go Nothing rest in ((takeWhile (== ' ') l ++ public after) : java, (name, skip) : tests)
        | otherwise -> let (java, tests) = go skip rest in (l : java, tests)
    -- Lines up to the one that closes the first's parentheses.
    closed ls' = let depths = scanl1 (+) [parens x | x <- ls']
                     n = length (takeWhile (> 0) depths) + 1
                 in splitAt n ls'
    parens x = sum [if c == '(' then 1 else if c == ')' then -1 else 0 | c <- stripStrings x] :: Int
    stripStrings x = case x of
      '"' : more -> stripStrings (snd (literal more))
      c : more -> c : stripStrings more
      [] -> []
    -- void name() {, void name() throws Throwable {, void name() {}.
    testMethod l = do
      rest <- stripPrefix "void " (trimmed l)
      let name = takeWhile (\c -> isAlphaNum c || c == '_') rest
      if null name then Nothing else Just name
    public l = takeWhile (== ' ') l ++ "public " ++ trimmed l
    -- The annotation's message: Java string literals joined by +.
    unquote s = concatMap fst (literals s)
    literals s = case dropWhile (/= '"') s of
      '"' : rest -> let (body, after) = literal rest in (body, ()) : literals after
      _ -> []
    literal s = case s of
      '\\' : c : rest -> let (b, a) = literal rest in (c : b, a)
      '"' : rest -> ([], rest)
      c : rest -> let (b, a) = literal rest in (c : b, a)
      [] -> ([], [])

replaceAll :: String -> String -> String -> String
replaceAll old new = go
  where
    go [] = []
    go s@(c : rest)
      | Just after <- stripPrefix old s = new ++ go after
      | otherwise = c : go rest

-- | Whole identifiers only.
replaceWord :: String -> String -> String -> String
replaceWord old new = go ' '
  where
    word c = isAlphaNum c || c == '_' || c == '$'
    go _ [] = []
    go before s@(c : rest)
      | not (word before), Just after <- stripPrefix old s, not (any word (take 1 after)) = new ++ go (last old) after
      | otherwise = c : go c rest
