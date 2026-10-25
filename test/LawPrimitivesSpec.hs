-- | Law primitives: matchers and portable regexes, typed failures, tables,
-- examples in descriptions, recorded values and resources.
module LawPrimitivesSpec (test_lawPrimitivesCheckWhatTheyReadAs) where

import Data.Char (ord)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.CoreEmit (emitPlanWithFormat)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Regex (parseRegex, regexMatchesText)
import LawSpec.Testing (planTesting)

program :: String -> Either [Diagnostic] C.Program
program source = compileCore 64 defaultGeneration [Source "laws.lawspec" ("unit example.laws\n\n" ++ source ++ "\n\nend unit\n")]

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

-- The evidence of a program's laws, by law name.
evidence :: String -> Either [Diagnostic] [(String, Status)]
evidence source = do
  compiled <- program source
  obligations <- dischargeEvidence compiled
  pure [ (C.propertyName p, obligationStatus o) | o <- obligations, u <- C.programUnits compiled
       , p <- C.unitProperties u, C.propertyId p == obligationDeclaration o ]

-- The examples of each law, by name.
examples :: String -> Either [Diagnostic] [(String, [String])]
examples source = do
  compiled <- program source
  pure [(C.propertyName p, map C.exampleName (C.propertyExamples p)) | u <- C.programUnits compiled, p <- C.unitProperties u]

closed :: String -> String -> String
closed name body = "law \"|" ++ name ++ "| is definition: " ++ body ++ " end definition end law\n"

matches :: String -> String -> Either String Bool
matches pattern text = regexMatchesText pattern (map ord text)

-- | A law written with a matcher, a table or a resource must check exactly what
-- it reads as, the same on every target. ref:REQ-law-primitives
test_lawPrimitivesCheckWhatTheyReadAs :: Spec
test_lawPrimitivesCheckWhatTheyReadAs = describe "law primitives" $ do
  describe "portable regexes" $ do
    it "match whole texts by code point" $ do
      matches "a+b" "aaab" `shouldBe` Right True
      matches "a+b" "aaab!" `shouldBe` Right False
      matches "(ab|cd)*" "abcdab" `shouldBe` Right True
      matches "[a-z]{2,3}" "abcd" `shouldBe` Right False
      matches "\\d+(\\.\\d+)?" "3.14" `shouldBe` Right True
      matches "." "\n" `shouldBe` Right False
      matches "(a*)*" "aaaa" `shouldBe` Right True
      matches "é{2}" "éé" `shouldBe` Right True
      matches "[^\\w]" "_" `shouldBe` Right False
    it "reject what engines read differently, or a whole match does not need" $
      mapM_ (\p -> parseRegex p `shouldSatisfy` isLeft)
        ["^a", "a$", "a**", "a*?", "(?=a)", "(?<n>a)", "(?i)a", "\\b", "\\1", "\\p{L}", "[z-a]", "a{3", "a{5,2}", "a{1001}", "(a", "a)", "[]", "\\q"]
  describe "matchers" $ do
    it "evaluate as the prelude defines them" $ do
      let laws = concat
            [ closed "same items" "([1, 2, 2] has same items as [2, 1, 2]) = true"
            , closed "not the same items" "([1, 2] has same items as [1, 2, 2]) = false"
            , closed "contains" "([1, 2] contains 2 && !([1, 2] contains 3)) = true"
            , closed "contains all of" "([1, 2, 3] contains all of [3, 1] && [1] is subset of [1, 2]) = true"
            , closed "text" "(\"hello\" starts with \"he\" && \"hello\" ends with \"lo\" && \"hello\" contains \"ll\") = true"
            , closed "within" "(10 is within 2 of 11 && !(10 is within 2 of 13)) = true"
            , closed "regex" "(\"a-b\" matches regex \"[a-z]+(-[a-z]+)*\") = true"
            , "type Order is one of | Pending  of type Int32 | Shipped of type record{ id :: Int32 carrier :: Text} end type\n"
            , closed "pattern" "(Shipped record{id = 1, carrier = \"post\"} matches Shipped record{carrier = \"post\"} && !(Pending 1 matches Shipped _)) = true" ]
      statuses <- either (fail . show) pure (evidence laws)
      map fst statuses `shouldBe` map (\name -> "|" ++ name ++ "|") ["same items", "not the same items", "contains", "contains all of", "text", "within", "regex", "pattern"]
      map snd statuses `shouldSatisfy` all (`elem` [Proved, ExhaustivelyChecked])
    it "refute a false law" $
      evidence (closed "wrong" "([1, 2] has same items as [2, 2]) = true") `shouldSatisfy` failsWith "is false"
    it "check types" $ do
      program (closed "text within" "(\"a\" is within 1 of \"b\") = true") `shouldSatisfy` failsWith "compares numbers"
      program (closed "contains a number" "(1 contains 1) = true") `shouldSatisfy` failsWith "List or a Text"
    it "leave a function named contains alone" $
      program "function contains (xs :: List Int32) (x :: Int32) -> Bool is xs contains x end function\nlaw \"|own| is definition : contains [1] 1 = true end definition end law\n"
        `shouldSatisfy` isRight
    it "reject a regex literal outside the dialect, a Regex made from text, and quantifying over Regex" $ do
      program "name :: Text -> Text\nlaw r is definition: for all (t :: Text) => name t matches regex \"^a\" end for all end definition end law\n"
        `shouldSatisfy` failsWith "not portable"
      program "function pattern (t :: Text) -> Regex is Regex t end function\n" `shouldSatisfy` failsWith "made from a literal"
      program "name :: Text -> Text\nlaw \"|r| is definition : for all (t :: Text) (r :: Regex) => name t matches r end for all end definition end law\n"
        `shouldSatisfy` failsWith "quantifies over r"
  describe "typed failures" $ do
    let errors = "type PaymentError is one of | Declined of type record{ message :: Text} | Blocked end type\n" ++
          "procedure pay (cents :: Int32) -> Int32 fails with PaymentError is if cents < 0 then raise (Declined record{message = \"negative\"}) else cents end if end procedure\n"
    it "match a failure by constructor and message" $ do
      evidence (errors ++ closed "declined" "for all (cents :: Int32 where cents < 0) => pay cents fails with Declined _ message contains \"neg\" end for all")
        `shouldSatisfy` isRight
      evidence (errors ++ closed "minus one declined" "(pay -1 fails with Declined _ && !(pay -1 fails with Blocked)) = true")
        `shouldSatisfy` isRight
    it "need a message field" $
      program ("type Error is one of | Refused end type\nprocedure no (x :: Int32) -> Int32 fails with Error is raise Refused end procedure\n" ++
        closed "message" "for all (x :: Int32) => no x fails with Refused message contains \"x\" end for all")
        `shouldSatisfy` failsWith "has none"
  describe "tables and examples in descriptions" $ do
    let law tables = "add :: Int32 -> Int32 -> Int32\nlaw \"|adds| is definition: for all (a :: Int32) (b :: Int32) => add a b = add b a end for all end definition\n" ++ tables ++ "end law\n"
    it "make one example per row" $
      examples (law "expect add a b = sum\nin table (a, b, sum):\n row 1, 2, 3\n row 2, 2, 4\nend table\n")
        `shouldBe` Right [("|adds|", ["row 1: 1, 2, 3", "row 2: 2, 2, 4"])]
    it "name rows by table when a law has several" $
      examples (law "expect add a b = 3\nin table (a, b): row 1, 2 end table\nexpect add a b = 7\nin table (b, a): row 3, 4 end table\n")
        `shouldBe` Right [("|adds|", ["table 1, row 1: 1, 2", "table 2, row 1: 3, 4"])]
    it "reject a row with the wrong number of values" $
      program (law "expect add a b = sum\nin table (a, b, sum):\n row 1, 2\nend table\n") `shouldSatisfy` failsWith "has 2 values"
    it "make examples of fenced examples in a description" $
      examples ("add :: Int32 -> Int32 -> Int32\nlaw \"|adds| is definition: for all (a :: Int32) (b :: Int32) => add a b = add b a end for all end definition\n" ++
        "description : \"Adding.\n```example\na = 1\nb = 2\nexpect add a b = 3\n```\n```example `zero`\na = 0\nb = 0\n```\" end description\nend law\n")
        `shouldBe` Right [("|adds|", ["description example 1", "description: zero"])]
  describe "recorded values" $ do
    mapM_ (\(target, call) -> mapM_ (\compact ->
      it (target ++ " records nested fields with a schema" ++ if compact then " (compact)" else "") $ do
        input <- readFile "test/fixtures/recorded.lawspec"
        artifacts <- either (fail . show) pure
          (compileCore (if compact then 32 else 64) defaultGeneration [Source "recorded.lawspec" input]
            >>= planTesting >>= emitPlanWithFormat compact target)
        concatMap artifactContent artifacts `shouldSatisfy` isInfixOf call
      ) [False, True])
      [("javascript", "_lawspec_schema.recorded("), ("typescript", "_lawspec_schema.recorded("),
       ("python", "_lawspec_schema.recorded("), ("erlang", "lawspec_beam_runtime:recorded("),
       ("elixir", "lawspec_beam_runtime:recorded("), ("gleam", "lawspec_beam_runtime:recorded(")]
    it "key a recording by unit and name" $ do
      compiled <- either (fail . show) pure (program "label :: Int32 -> Text\nlaw \"|first| is definition : label 1 = recorded \"first label\" end definition end law\n")
      show compiled `shouldSatisfy` (show (map ord "example.laws/first label") `isInfixOf`)
    it "keep recordings out of laws that quantify" $
      program "label :: Int32 -> Text\nlaw \"|all| is definition : for all (x :: Int32) => label x = recorded \"x\" end for all end definition end law\n"
        `shouldSatisfy` failsWith "every input would need its own recording"
    it "reject a name that is not a file name" $
      program "label :: Int32 -> Text\nlaw first is definition: label 1 = recorded \"../x\" end definition end law\n" `shouldSatisfy` isLeft
  describe "resources" $ do
    let store = "handle Store\nopenStore :: Unit -> Store\ncloseStore :: Store -> Unit\nsize :: Store -> Int32\n"
        declared = store ++ "resource Store is\n acquire is openStore unitValue end acquire\n release s is closeStore s end release\nend resource\n"
    it "bind a law's resources, acquired and released around each case" $ do
      compiled <- either (fail . show) pure (program (declared ++ "law \"|empty| for store :: Store is definition : size store = 0 end definition end law\n"))
      let resources = [r | u <- C.programUnits compiled, p <- C.unitProperties u, r <- C.propertyResources p]
      map (C.binderName . C.resourceBinder) resources `shouldBe` ["store"]
    it "need a declared resource" $
      program (store ++ "law \"|empty| for store :: Store is definition : size store = 0 end definition end law\n")
        `shouldSatisfy` failsWith "no resource is declared"
    it "keeps resource binders in specialization scopes" $ do
      input <- readFile "acceptance/beam-resource-owners/owners.lawspec"
      compileCore 64 defaultGeneration [Source "owners.lawspec" input] `shouldSatisfy` isRight
    it "reject a law that releases its own resource" $
      program (declared ++ "law \"|closes| for store :: Store is definition : closeStore store = unitValue and size store = 0 end definition end law\n")
        `shouldSatisfy` failsWith "could use store after its release"
    -- Checked definitions cannot call adapters, so a definition releases a
    -- resource through an ability operation its release clause performs.
    let stores = "handle Store\nability Stores is\n  openStore :: Unit -> Store\n  closeStore :: Store -> Unit\n  size :: Store -> Int32\nend ability\n" ++
          "resource Store is\n acquire is openStore unitValue end acquire\n release s is closeStore s end release\nend resource\n"
    it "reject a law that releases its resource through an ability operation" $
      program (stores ++ "law \"|closes| for store :: Store is definition : closeStore store = unitValue end definition end law\n")
        `shouldSatisfy` failsWith "could use store after its release"
    it "reject a law that hands its resource to a definition that releases it" $
      program (stores ++ "procedure finish (s :: Store) -> Unit uses Stores is closeStore s end procedure\n" ++
        "procedure shut (s :: Store) -> Unit uses Stores is let t = s in finish t end let end procedure\n" ++
        "law \"|closes later| for store :: Store is definition : shut store = unitValue end definition end law\n")
        `shouldSatisfy` failsWith "could use store after its release"
    it "accept a law that hands its resource to a definition that only reads it" $ do
      compiled <- either (fail . show) pure (program (stores ++ "procedure peek (s :: Store) -> Int32 uses Stores is size s end procedure\n" ++
        "law \"|reads| for store :: Store is definition : peek store = 0 end definition end law\n"))
      length [p | u <- C.programUnits compiled, p <- C.unitProperties u] `shouldSatisfy` (> 0)
    it "provide built-in resources" $ do
      compiled <- either (fail . show) pure (program
        "readNote :: Text -> Int32\nlaw \"|notes| for dir :: TemporaryDirectory, port :: FreePort is definition : readNote (directoryPath dir) = portNumber port end definition end law\n")
      -- lawspec.host comes along, with its abilities' laws.
      [length (C.propertyResources p) | u <- C.programUnits compiled, not ("lawspec." `isPrefixOf` C.idText (C.unitId u)), p <- C.unitProperties u] `shouldBe` [2]
      -- They acquire and release through lawspec.host's abilities.
      [C.abilityKey a | u <- C.programUnits compiled, p <- C.unitProperties u, not (null (C.propertyResources p)), (a, C.ProductionHandler) <- C.propertyHandlers p]
        `shouldBe` ["lawspec.host::ability::FileSystem", "lawspec.host::ability::Ports"]
