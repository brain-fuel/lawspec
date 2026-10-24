-- | Spock specifications, emitted from the plan. A unit's laws are run by
-- the Java model's JUnit test class, which Gradle compiles beside the Groovy
-- sources; its specification has a feature per test, named in words, that
-- says what the test checks (the law's statement, with source names) and
-- runs it. JUnit's skip, order and concurrency marks are Spock's. Other
-- generated Java test classes run through one feature per test method.
-- Nothing is rewritten from Java text. ref:DEC-groovy-over-java
-- ref:DEC-groovy-property-library
module LawSpec.Groovy.Spock (Feature(..), specClassName, spockSpecification, classSpecification) where

import Data.List (intercalate, isSuffixOf)
import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)

-- | A feature: its title, the comment above it (a law's first feature says
-- the law and what it checks), why it is skipped, and the test method it
-- runs.
data Feature = Feature
  { featureTitle :: String
  , featureComment :: [String]
  , featureSkipped :: Maybe String
  , featureMethod :: String
  }

-- | A test class's name as a specification's: FooLawSpecTest is
-- FooLawSpec, FooTest is FooSpec.
specClassName :: String -> String
specClassName name
  | "LawSpecTest" `isSuffixOf` name = take (length name - 4) name
  | "Test" `isSuffixOf` name = take (length name - 4) name ++ "Spec"
  | otherwise = name ++ "Spec"

string :: String -> D.Doc
string = D.text . literalFor "groovy"

header :: String -> String -> [String] -> D.Doc
header generated package imports =
  D.text ("// " ++ generated) <> D.hardline <> D.hardline <>
  (if null package then mempty else D.text ("package " ++ package) <> D.hardline <> D.hardline) <>
  D.joinWith D.hardline [D.text ("import " ++ i) | i <- imports] <> D.hardline <> D.hardline

-- | A specification over a Java test class: a feature per test, in order.
-- order random and parallel are the unit's.
spockSpecification :: String -> String -> String -> String -> Bool -> Bool -> [Feature] -> String
spockSpecification generated package testClass description orderRandom parallel features =
  D.render (D.Pretty 100) $ header generated package ["spock.lang.Specification"] <>
    D.text ("// " ++ description) <> D.hardline <>
    (if orderRandom then D.text "@lawspec.testing.LawSpecRandomOrder" <> D.hardline else mempty) <>
    (if parallel then D.text "@spock.lang.Execution(org.spockframework.runtime.model.parallel.ExecutionMode.CONCURRENT)" <> D.hardline else mempty) <>
    D.text ("class " ++ specClassName testClass ++ " extends Specification") <> D.hardline <>
    D.block 2 (D.joinWith (D.hardline <> D.hardline) (map feature features)) <> D.hardline
  where
    feature f =
      mconcat (map (D.lineComment 98 "// ") (featureComment f)) <>
      maybe mempty (\reason -> D.text "@spock.lang.Ignore(" <> reasonText reason <> D.text ")" <> D.hardline) (featureSkipped f) <>
      D.text "def " <> string (featureTitle f) <> D.text "()" <> D.hardline <>
      D.block 2 (case featureSkipped f of
        Just _ -> D.text "expect: true"
        Nothing -> D.text "setup:" <> D.hardline <>
          D.group (D.text ("new " ++ testClass ++ "()") <> D.nest 2 (D.softbreak <> D.text ("." ++ featureMethod f ++ "()"))))

-- | A specification running every JUnit test of a Java test class, one
-- feature each.
classSpecification :: String -> String -> String -> String
classSpecification generated package testClass =
  D.render (D.Pretty 100) $ header generated package ["lawspec.testing.LawSpecGroovy", "spock.lang.Specification"] <>
    D.text ("// The JUnit tests of " ++ testClass ++ ", a feature each.") <> D.hardline <>
    D.text ("class " ++ specClassName testClass ++ " extends Specification") <> D.hardline <>
    D.block 2 (D.text "def \"#method\"()" <> D.hardline <> D.block 2 (D.joinWith D.hardline
      [ D.text "setup:"
      , D.text ("LawSpecGroovy.run(" ++ testClass ++ ", method)")
      , mempty
      , D.text "where:"
      , D.text ("method << LawSpecGroovy.tests(" ++ testClass ++ ")") ])) <> D.hardline

-- | An annotation's text: a long one is a triple-quoted literal continued
-- with \ at its line ends, its later lines unindented (a continued literal
-- keeps their spaces), so each line stays within 100 columns.
reasonText :: String -> D.Doc
reasonText reason
  | length reason <= 70 = string reason
  | otherwise = D.text ("\'\'\'" ++ intercalate "\\\n" (pieces (concatMap escape reason)) ++ "\'\'\'")
  where
    escape c = case c of
      '\\' -> "\\\\"
      '\'' -> "\\'"
      _ -> [c]
    -- Words to about 70 characters a line, each line ending in a space.
    pieces text = go (words' text)
      where
        go [] = []
        go ws = let (line, rest) = fill [] 0 ws in concat line : go rest
        fill acc n (w : more) | null acc || n + length w <= 70 = fill (acc ++ [w]) (n + length w) more
        fill acc _ more = (acc, more)
    words' t = case break (== ' ') t of
      (w, ' ' : more) -> (w ++ " ") : words' more
      (w, _) -> [w | not (null w)]
