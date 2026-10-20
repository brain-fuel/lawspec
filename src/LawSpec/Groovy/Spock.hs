-- | A generated JUnit test class as a Spock specification: each test method
-- is a feature named in words, its body the feature's setup block, which
-- fails the feature by throwing; JUnit's skip, order and concurrency marks
-- become Spock's. Properties run on JetCheck, as on Java.
-- ref:DEC-groovy-over-java ref:DEC-groovy-property-library
module LawSpec.Groovy.Spock (spockSpecification, specClassName, needsJavaBody, javaBodySpecification) where

import Data.Char (isAlphaNum)
import Control.Monad (msum)
import Data.List (isSuffixOf, stripPrefix)
import LawSpec.Groovy.Source (groovyLiterals)

-- | A test class's name as a specification's: FooLawSpecTest is
-- FooLawSpec, FooTest is FooSpec.
specClassName :: String -> String
specClassName name
  | "LawSpecTest" `isSuffixOf` name = take (length name - 4) name
  | "Test" `isSuffixOf` name = take (length name - 4) name ++ "Spec"
  | otherwise = name ++ "Spec"

-- Large finite searches contain thousands of nested, typed Java callbacks.
-- Passing those bodies through Groovy's parser exhausts its prediction cache.
-- Keep the existing Java execution body and expose each independent test as a
-- Spock feature. This changes only the host-language bridge, never the search.
-- Count callbacks and independent tests rather than bytes. Shared assertions
-- reduce callback duplication without reducing a large suite's test count.
needsJavaBody :: String -> Bool
needsJavaBody source = count (128 :: Int) "LawSpecRuntime.let(" source ||
  count (512 :: Int) "\n  @Test\n" source
  where
    count 0 _ _ = True
    count _ _ [] = False
    count remaining marker input@(_:rest) = case stripPrefix marker input of
      Just after -> count (remaining - 1) marker after
      Nothing -> count remaining marker rest

javaBodySpecification :: String -> (String -> String) -> String -> (String, String)
javaBodySpecification className title source =
  -- The wrapper follows the large Java body in the emitted project. Resolve
  -- its small feature list first, so its deferred scan cannot retain every
  -- original Java line while the rewritten body is being consumed.
  length specification `seq` (body, specification)
  where
    specification = spockSpecification className title (groovyLiterals wrapper)
    helper = className ++ "Body"
    sourceLines = lines source
    classHeader line = any (`stripStarts` line)
      ["public final class " ++ className ++ " ", "public class " ++ className ++ " ",
       "final class " ++ className ++ " ", "class " ++ className ++ " "]
    stripStarts prefix line = case stripPrefix prefix line of Just _ -> True; Nothing -> False
    (prefix,rest) = break classHeader sourceLines
    wrapper = unlines (prefix ++ take 1 rest ++ features (drop 1 rest) ++ ["}"])
    features [] = []
    features (line:next:remaining)
      | dropWhile (== ' ') line == "@Test"
      , Just after <- stripPrefix "void " (dropWhile (== ' ') next) =
          let name = takeWhile (\c -> isAlphaNum c || c == '_') after
          in ["  @Test", "  void " ++ name ++ "() {", "    new " ++ helper ++ "()." ++ name ++ "();", "  }"] ++ features remaining
    features (line:remaining)
      | "@org.junit.jupiter.api.Disabled(" `stripStarts` dropWhile (== ' ') line = line : features remaining
      | otherwise = features remaining
    -- The helper has no JUnit entry points. Spock owns discovery, skipping,
    -- ordering and reporting; each feature gets a fresh execution instance.
    body = replaceWord className helper (unlines (publicTests sourceLines))
    publicTests [] = []
    publicTests (line:next:remaining)
      | dropWhile (== ' ') line == "@Test" =
          (takeWhile (== ' ') next ++ "public " ++ dropWhile (== ' ') next) : publicTests remaining
    publicTests (line:remaining) = line : publicTests remaining

-- | A Java test class (already in Groovy's literals) as a specification;
-- title names each test method's feature.
spockSpecification :: String -> (String -> String) -> String -> String
spockSpecification className title source =
  unlines (go (lines (typedLists (castLambdas (renamed source)))))
  where
    renamed = replaceWord className (specClassName className)
    -- Thousands of dynamic feature call sites exceed Groovy's invokedynamic
    -- machinery. The generated Java bodies are already statically typed;
    -- keep every Spock feature while compiling large suites statically.
    largeSuite = length [() | line <- lines source, Just _ <- [stripPrefix "@Test" (dropWhile (== ' ') line)]] >= 1024
    go ls = case ls of
      [] -> []
      l : rest
        | Just indent <- annotationLine "@Test" l, next : rest' <- rest, Just (name, empty) <- testHeader next ->
            header indent name empty rest'
        | Just (indent, after) <- inlineTest l, Just (name, empty) <- testHeader (indent ++ after) ->
            header indent name empty rest
        | otherwise -> rewrite l : go rest
    -- A method whose body is empty closes on the next line.
    header indent name empty rest = case dropWhile (all (== ' ')) rest of
      closing : rest' | not empty, dropWhile (== ' ') closing == "}" -> feature indent name True ++ go rest'
      _ -> feature indent name empty ++ go rest
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
      let unthrown = case stripPrefix " throws " body of
            Just thrown -> dropWhile (\c -> isAlphaNum c || c `elem` (".," :: String)) (dropWhile (== ' ') thrown)
            Nothing -> body
      case dropWhile (== ' ') unthrown of
        "{" -> Just (name, False)
        "{}" -> Just (name, True)
        _ -> Nothing
    rewrite l
      | Just rest <- msum (map (`stripPrefix` l) ["public final class ", "public class ", "final class ", "class "])
      , takeWhile (/= ' ') rest == specClassName className =
          (if largeSuite then "@groovy.transform.CompileStatic\n" else "") ++
          "class " ++ takeWhile (/= ' ') rest ++ " extends spock.lang.Specification" ++ dropWhile (/= ' ') rest
      -- Groovy has no bare array initializer: T[] x = { ... } is new T[] { ... }.
      | "= {" `isSuffixOf` l, (declared, _) <- break (== '=') (dropWhile (== ' ') l)
      , [arrayType, _] <- lastTwo (words declared), "[]" `isSuffixOf` arrayType =
          take (length l - 1) l ++ "new " ++ arrayType ++ " {"
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

-- | java.util.List.<T>of(x, y) as LawSpecGroovy.listOf(T, x, y), which
-- coerces each closure to T: a list's elements are not.
typedLists :: String -> String
typedLists s = case s of
  [] -> []
  _ | Just rest <- stripPrefix "java.util.List.<" s, (witness, '>' : 'o' : 'f' : '(' : after) <- bracketed 0 rest ->
        "lawspec.testing.LawSpecGroovy.listOf(" ++ takeWhile (/= '<') witness ++ (if take 1 after == ")" then "" else ", ") ++ typedLists after
  c : rest -> c : typedLists rest
  where
    -- The type argument, up to its closing angle bracket.
    bracketed :: Int -> String -> (String, String)
    bracketed depth t = case t of
      '>' : _ | depth == 0 -> ([], t)
      c : rest ->
        let depth' = if c == '<' then depth + 1 else if c == '>' then depth - 1 else depth
            (inside, after) = bracketed depth' rest
        in (c : inside, after)
      [] -> ([], [])

lastTwo :: [a] -> [a]
lastTwo xs = drop (length xs - 2) xs

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
