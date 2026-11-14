-- | Recovery collects independent grammar failures without admitting its
-- temporary terms to formatting, compilation or verification evidence.
-- ref:DEC-parser-error-recovery
module ParserDiagnosticsSpec (test_parserDiagnostics) where

import Test.Hspec
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf, nub)
import Control.Exception (evaluate)
import System.Timeout (timeout)
import LawSpec.Api (dispatch)
import LawSpec.Model
import LawSpec.Parser (parseSourceCanonical)

diagnostics :: Source -> [Diagnostic]
diagnostics = either id (const []) . parseSourceCanonical

test_parserDiagnostics :: Spec
test_parserDiagnostics = describe "parser error recovery" $ do
  it "reports every bad literal in sibling fields and rows, and continues to later declarations" $ do
    text <- readFile "test/fixtures/parser-multiple-errors.lawspec"
    let errors = diagnostics (Source "chronology.lawspec" text)
    length errors `shouldBe` 6
    length [() | err <- errors, "unknown literal constructor" `isInfixOf` message err] `shouldBe` 4
    length [() | err <- errors, "MadeUp" `isInfixOf` last (lines (message err))] `shouldBe` 1
    map (fmap line . at) errors `shouldBe` map Just [7,7,8,8,11,12]
    length (nub (map at errors)) `shouldBe` 6
  it "points at rejected constructor names even when whitespace reaches the next row or closer" $ do
    let rows = ["    row \"first\", Nothing", "    row \"second\", Nothing",
                "    row \"third\", Just 0", "    row \"fourth\", MadeUp"]
        text = unlines $ ["unit locations", "law samples is definition: true end definition",
          "expect true = expected in table (value,expected):"] ++ rows ++
          ["end table end law end unit"]
        errors = diagnostics (Source "locations.lawspec" text)
        names = ["Nothing", "Nothing", "Just", "MadeUp"]
    map (fmap (\location -> (line location,column location)) . at) errors `shouldBe`
      [Just (row,length textLine - length suffix + 1) |
        (row,textLine,suffix) <- zip3 [4..] rows (["Nothing","Nothing","Just 0","MadeUp"] :: [String])]
    sequence_ [message err `shouldSatisfy` isInfixOf ("unknown literal constructor: " ++ name) |
      (err,name) <- zip errors names]
  it "collects errors across files in checked and parse-only API requests without exposing recovered trees" $ do
    text <- readFile "test/fixtures/parser-multiple-errors.lawspec"
    let sources = [Source "chronology.lawspec" text,
          Source "second.lawspec" "unit second\nfunction bad (x :: Bool) -> Bool is ? end function\nend unit\n"]
    mapM_ (\(method,compile) -> do
      let response = either error id (eitherDecode (dispatch (encode (object
            ["languageProfile" .= ("1.0-rc.2"::String),"method" .= method,"compile" .= compile,
             "sources" .= sources,"verification" .= object ["layers" .= ([]::[String])]])))) :: Value
      case response of
        Object fields -> do
          case KM.lookup "diagnostics" fields of
            Just (Array errors) -> length errors `shouldBe` 7
            other -> expectationFailure (show other)
          mapM_ (\key -> KM.lookup key fields `shouldBe` Nothing)
            ["formattedSources","definitions","evidence","sourceSyntax"]
        other -> expectationFailure (show other))
      [("format"::String,False),("format",True),("check",True)]
  it "recovers malformed types and signatures, not only constructor spelling" $ do
    let source = Source "types.lawspec" $ unlines
          [ "unit broken"
          , "type Bad is a record{a :: List , b :: Maybe , c :: Bool} end type"
          , "function f (x :: ) -> Bool is x end function"
          , "function g (x :: ) -> Bool is x end function"
          , "end unit" ]
    map (fmap line . at) (diagnostics source) `shouldBe` map Just [2,2,3,4]
  it "keeps quoted tokens opaque after lexical errors and resumes at following literals" $ do
    let source = Source "quoted.lawspec" $ unlines
          [ "unit quoted"
          , "law samples is definition: true end definition"
          , "expect true = expected in table (value,expected):"
          , "row record{a = \"bad\\q end unit, function bogus\", b = MadeUp},true"
          , "row record{a = \"fine\", b = Invented},true"
          , "end table end law end unit" ]
        errors = diagnostics source
    map (fmap line . at) errors `shouldBe` map Just [4,4,5]
    length [() | err <- errors, "unknown literal constructor" `isInfixOf` message err] `shouldBe` 2
  it "preserves opener diagnostics for independent malformed block closers" $ do
    let errors = diagnostics (Source "closers.lawspec" $ unlines
          [ "unit broken"
          , "function f (x :: Bool) -> Bool is x end type"
          , "function g (x :: Bool) -> Bool is x end type"
          , "end unit" ])
    map code errors `shouldBe` ["block-close-mismatch","block-close-mismatch"]
    map (fmap line . at) errors `shouldBe` map Just [2,3]
  it "keeps a malformed triple-quoted literal opaque while recovering later field errors" $ do
    let source = Source "triple-errors.lawspec" $ unlines
          [ "unit quoted"
          , "law samples is definition: true end definition"
          , "expect true = expected in table (value,expected):"
          , "row record{a = \"\"\"bad\\q end unit,"
          , "function bogus\"\"\", b = MadeUp},true"
          , "row record{a = \"fine\", b = Invented},true"
          , "end table end law end unit" ]
        errors = diagnostics source
    map (fmap line . at) errors `shouldBe` map Just [4,5,6]
    length [() | err <- errors, "unknown literal constructor" `isInfixOf` message err] `shouldBe` 2
  it "resumes at later sections of a law after a malformed definition" $ do
    let errors = diagnostics (Source "sections.lawspec" $ unlines
          [ "unit broken", "law samples is", "definition: ? end definition"
          , "expect true = expected in table (value,expected):"
          , "row MadeUp,true", "row Invented,true", "end table end law end unit" ])
    map (fmap line . at) errors `shouldBe` map Just [3,5,6]
  it "reports failures in several harness settings without inheriting previous region errors" $ do
    let source = Source "harness.lawspec" $ unlines
          [ "unit tested", "law holds is definition: true end definition end law"
          , "harness testing for tested is", "label ?", "label record{a = ?, b = @}"
          , "label true", "label @", "end harness", "end unit" ]
        errors = diagnostics source
    map (fmap line . at) errors `shouldBe` map Just [4,5,5,7]
  it "reports a bad escape in a text or regex literal alone, at the backslash" $ do
    let unit body = Source "escape.lawspec" (unlines
          ["unit escapes", "function blank (text :: Text) -> Bool is", body, "end function", "end unit"])
        regex = diagnostics (unit "  text matches regex \"\\s*\"")
        plain = diagnostics (unit "  text = \"a\\qb\" or text = \"\"")
    map (fmap (\location -> (line location,column location)) . at) regex `shouldBe` [Just (3,23)]
    map (fmap (\location -> (line location,column location)) . at) plain `shouldBe` [Just (3,12)]
    case regex of
      [err] -> do
        message err `shouldSatisfy` isInfixOf "invalid escape \\s in a text literal"
        message err `shouldSatisfy` isInfixOf "\"\\\\s\""
        message err `shouldSatisfy` isInfixOf "Valid escapes: \\\\ \\\" \\' \\n \\t \\r \\0"
        message err `shouldSatisfy` (not . isInfixOf "expecting")
      other -> expectationFailure (show other)
    diagnostics (unit "  text matches regex \"\\\\s*\\n\"") `shouldBe` []
  it "terminates on truncated or delimiter-only inputs" $ do
    let inputs = ["unit x\nfunction f (x :: Bool) -> Bool is \"unterminated",
          "unit x\nfunction f (x :: Bool) -> Bool is [,,,",
          "unit x\nend\n", "unit x\nfunction f (x :: ) -> Bool is ) end function\nend unit"]
    mapM_ (\text -> do
      result <- timeout 2000000 (evaluate (length (diagnostics (Source "truncated.lawspec" text))))
      result `shouldSatisfy` maybe False (>0)) inputs
  it "refuses a reserved word as a declared name once, at the word, and names it" $ do
    let unit body = Source "reserved.lawspec" (unlines (["unit reserved"] ++ body ++ ["end unit"]))
        places source = map (fmap (\location -> (line location,column location)) . at) (diagnostics source)
        says role word source = mapM_ (\err -> do
          message err `shouldSatisfy` isInfixOf (word ++ " is a reserved word, so it cannot name " ++ role)
          message err `shouldSatisfy` isInfixOf "no escape"
          message err `shouldSatisfy` isInfixOf "Reserved words: unit, law,"
          message err `shouldSatisfy` (not . isInfixOf "expecting")) (diagnostics source)
        record = unit ["type Risk is a record{", "  description :: Text", "  rationale :: Text", "  level :: Integer", "}", "end type"]
        payload = unit ["type Risk is one of", "  | Known of type record{ level :: Integer, rationale :: Text }", "end type"]
        -- Each later use of the name fails for the same reason and is not reported again.
        parameter = unit ["function describe (description :: Text) -> Text is", "  description ++ description", "end function"]
        variable = unit ["law named is", "  definition:", "    for all (type :: Integer) => type = type end for all", "  end definition", "end law"]
    places record `shouldBe` [Just (3,3), Just (4,3)]
    map (takeWhile (/= ' ') . last . lines . message) (diagnostics record) `shouldBe` ["description", "rationale"]
    says "a field" "" record
    places payload `shouldBe` [Just (3,45)]
    says "a field" "rationale" payload
    places parameter `shouldBe` [Just (2,20)]
    says "a parameter" "description" parameter
    places variable `shouldBe` [Just (4,14)]
    says "a variable" "type" variable
    -- A word that only begins like a reserved one is an ordinary name.
    diagnostics (unit ["type Risk is a record{", "  descriptions :: Text", "  typed :: Integer", "}", "end type"]) `shouldBe` []

