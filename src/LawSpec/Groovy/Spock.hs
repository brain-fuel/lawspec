-- | A generated JUnit test class as a Spock specification: each test method
-- is a feature named in words, its body the feature's setup block, which
-- fails the feature by throwing; JUnit's skip, order and concurrency marks
-- become Spock's. Properties run on JetCheck, as on Java.
-- ref:DEC-groovy-over-java ref:DEC-groovy-property-library
module LawSpec.Groovy.Spock (spockSpecification, specClassName) where

import Data.Char (isAlphaNum)
import Data.List (isSuffixOf, stripPrefix)

-- | A test class's name as a specification's: FooLawSpecTest is
-- FooLawSpec, FooTest is FooSpec.
specClassName :: String -> String
specClassName name
  | "LawSpecTest" `isSuffixOf` name = take (length name - 4) name
  | "Test" `isSuffixOf` name = take (length name - 4) name ++ "Spec"
  | otherwise = name ++ "Spec"

-- | A Java test class (already in Groovy's literals) as a specification;
-- title names each test method's feature.
spockSpecification :: String -> (String -> String) -> String -> String
spockSpecification className title source =
  unlines (go (lines (castLambdas (renamed source))))
  where
    renamed = replaceWord className (specClassName className)
    go ls = case ls of
      [] -> []
      l : rest
        | Just indent <- annotationLine "@Test" l, next : rest' <- rest, Just (name, empty) <- testHeader next ->
            feature indent name empty ++ go rest'
        | Just (indent, after) <- inlineTest l, Just (name, empty) <- testHeader (indent ++ after) ->
            feature indent name empty ++ go rest
        | otherwise -> rewrite l : go rest
    feature indent name empty =
      [indent ++ "def " ++ show' (title name) ++ "() {"] ++
      (if empty then [indent ++ "  expect: true", indent ++ "}"] else [indent ++ "  setup:"])
    annotationLine annotation l =
      let (indent, rest) = span (== ' ') l in if rest == annotation then Just indent else Nothing
    inlineTest l =
      let (indent, rest) = span (== ' ') l in (\after -> (indent, after)) <$> stripPrefix "@Test " rest
    -- void name() {, void name() throws Throwable {, or void name() {}.
    testHeader l = do
      rest <- stripPrefix "void " (dropWhile (== ' ') l)
      let (name, after) = span (\c -> isAlphaNum c || c == '_') rest
      body <- stripPrefix "()" after
      case dropWhile (== ' ') (maybe body id (stripPrefix " throws Throwable" body)) of
        "{" -> Just (name, False)
        "{}" -> Just (name, True)
        _ -> Nothing
    rewrite l
      | Just rest <- stripPrefix "public final class " (dropWhile (== ' ') l) =
          takeWhile (== ' ') l ++ "class " ++ takeWhile (/= ' ') rest ++ " extends Specification" ++ dropWhile (/= ' ') rest
      | l == "import org.junit.jupiter.api.Test;" = "import spock.lang.Specification;"
      -- A nested record is static in Java; Groovy would make a closure pass
      -- the specification to its constructor.
      | Just rest <- stripPrefix "private record " (dropWhile (== ' ') l) = takeWhile (== ' ') l ++ "private static record " ++ rest
      | otherwise =
          replaceAll "@org.junit.jupiter.api.Disabled(" "@spock.lang.Ignore(" $
          replaceAll "@org.junit.jupiter.api.TestMethodOrder(lawspec.testing.LawSpecOrder.class)" "@lawspec.testing.LawSpecRandomOrder" $
          replaceAll "@org.junit.jupiter.api.parallel.Execution(org.junit.jupiter.api.parallel.ExecutionMode.CONCURRENT)"
            "@spock.lang.Execution(org.spockframework.runtime.model.parallel.ExecutionMode.CONCURRENT)" l
    show' t = "\"" ++ concatMap (\c -> if c `elem` ("\"\\$" :: String) then ['\\', c] else [c]) t ++ "\""

-- | Groovy parses a cast lambda only in parentheses: ((F) x -> e) becomes
-- ((F) (x -> e)), the lambda closed where the cast's group closes.
castLambdas :: String -> String
castLambdas = go
  where
    go s = case s of
      [] -> []
      '\'' : rest -> let (literal, after) = quoted rest in '\'' : literal ++ go after
      '(' : '(' : rest
        | (cast, ')' : ' ' : afterCast) <- break (== ')') rest, all typeChar cast, not (null cast)
        , (name, after) <- span identifier afterCast, not (null name), Just body <- stripPrefix " ->" after ->
            let (inner, closing) = enclosed 1 body
            in "((" ++ cast ++ ") (" ++ name ++ " ->" ++ go inner ++ ")" ++ go closing
      c : rest -> c : go rest
    typeChar c = isAlphaNum c || c `elem` ("._<>, ?[]" :: String)
    identifier c = isAlphaNum c || c == '_'
    quoted s = case s of
      '\\' : c : rest -> let (l, a) = quoted rest in ('\\' : c : l, a)
      '\'' : rest -> ("'", rest)
      c : rest -> let (l, a) = quoted rest in (c : l, a)
      [] -> ([], [])
    -- The text up to the parenthesis that closes an open group, and the rest
    -- from that parenthesis on.
    enclosed :: Int -> String -> (String, String)
    enclosed depth s = case s of
      [] -> ([], [])
      '\'' : rest -> let (literal, after) = quoted rest; (i, c) = enclosed depth after in ('\'' : literal ++ i, c)
      ')' : _ | depth == 1 -> ([], s)
      c : rest ->
        let depth' = if c == '(' then depth + 1 else if c == ')' then depth - 1 else depth
            (i, closing) = enclosed depth' rest
        in (c : i, closing)

replaceAll :: String -> String -> String -> String
replaceAll old new = go
  where
    go [] = []
    go s@(c : rest)
      | Just after <- stripPrefix old s = new ++ go after
      | otherwise = c : go rest

-- | Whole identifiers only, so FooTest does not rename FooTestHelper.
replaceWord :: String -> String -> String -> String
replaceWord old new = go ' '
  where
    word c = isAlphaNum c || c == '_' || c == '$'
    go _ [] = []
    go before s@(c : rest)
      | not (word before), Just after <- stripPrefix old s, not (any word (take 1 after)) = new ++ go (last old) after
      | otherwise = c : go c rest
