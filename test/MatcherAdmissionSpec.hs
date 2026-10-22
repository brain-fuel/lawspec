-- | Mandatory admission keeps a text matcher's predicate. A refinement such
-- as v matches regex "[a-z]+" is a fact the internal checker knows, so a
-- value that carries it, a guard that tests it, or a literal that satisfies
-- it proves the same refinement again. Z3 takes no part.
module MatcherAdmissionSpec (test_matcherFactsAreKeptInAdmission) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

program :: [String] -> Either [Diagnostic] C.Program
program body = compileCore 64 defaultGeneration
  [Source "matchers.lawspec" (unlines (["unit gate5.matchers", ""] ++ body ++ ["", "end unit"]))]

refused :: Either [Diagnostic] a -> Bool
refused = either (any (("could not be proved" `isInfixOf`) . message)) (const False)

pet :: String -> String
pet predicate = "type Pet is a record{ name :: (v :: Text where " ++ predicate ++ ") } end type\n"

test_matcherFactsAreKeptInAdmission :: Spec
test_matcherFactsAreKeptInAdmission = describe "matcher facts in admission" $ do
  it "proves a field regex from an argument of a refinement alias" $
    program
      [ "refinement Name is (v :: Text where v matches regex \"[a-z]+\") end refinement\n"
      , "type Pet is a record{ name :: Name } end type\n"
      , "function mk (n :: Name) -> Pet is Pet record{ name = n } end function" ]
      `shouldSatisfy` isRight
  it "proves a field regex from an identical inline argument refinement" $
    program
      [ pet "v matches regex \"[a-z]+\""
      , "function mk (n :: (v :: Text where v matches regex \"[a-z]+\")) -> Pet is Pet record{ name = n } end function" ]
      `shouldSatisfy` isRight
  it "proves a field regex from a guard that tests it" $
    program
      [ pet "v matches regex \"[a-z]+\""
      , "function mk (n :: Text) -> Pet is if n matches regex \"[a-z]+\" then Pet record{ name = n } else Pet record{ name = \"a\" } end if end function" ]
      `shouldSatisfy` isRight
  it "proves a field regex in the other branch of a negated guard" $
    program
      [ pet "v matches regex \"[a-z]+\""
      , "function mk (n :: Text) -> Pet is if not (n matches regex \"[a-z]+\") then Pet record{ name = \"a\" } else Pet record{ name = n } end if end function" ]
      `shouldSatisfy` isRight
  it "decides a matcher on literal text" $
    program
      [ pet "v matches regex \"[a-z]+\""
      , "function mk (u :: Unit) -> Pet is Pet record{ name = \"abc\" } end function" ]
      `shouldSatisfy` isRight
  it "proves prefix, suffix and part facts the same way" $ do
    program
      [ pet "v starts with \"a\""
      , "function mk (n :: (v :: Text where v starts with \"a\")) -> Pet is Pet record{ name = n } end function" ]
      `shouldSatisfy` isRight
    program
      [ pet "v ends with \"z\""
      , "function mk (n :: Text) -> Pet is if n ends with \"z\" then Pet record{ name = n } else Pet record{ name = \"z\" } end if end function" ]
      `shouldSatisfy` isRight
    program
      [ pet "v contains \"-\""
      , "function mk (u :: Unit) -> Pet is Pet record{ name = \"a-b\" } end function" ]
      `shouldSatisfy` isRight
  it "proves a matcher fact joined with other facts" $
    program
      [ pet "v matches regex \"[a-z]+\" and v != \"x\""
      , "function mk (n :: (v :: Text where v matches regex \"[a-z]+\" and v != \"x\")) -> Pet is Pet record{ name = n } end function" ]
      `shouldSatisfy` isRight
  describe "negative controls" $ do
    it "refuses a different regex" $
      program
        [ pet "v matches regex \"[a-z]+\""
        , "function mk (n :: (v :: Text where v matches regex \"[a-y]+\")) -> Pet is Pet record{ name = n } end function" ]
        `shouldSatisfy` refused
    it "refuses a different prefix" $
      program
        [ pet "v starts with \"a\""
        , "function mk (n :: (v :: Text where v starts with \"b\")) -> Pet is Pet record{ name = n } end function" ]
        `shouldSatisfy` refused
    it "refuses unguarded text" $
      program
        [ pet "v matches regex \"[a-z]+\""
        , "function mk (n :: Text) -> Pet is Pet record{ name = n } end function" ]
        `shouldSatisfy` refused
    it "refuses a literal the regex rejects" $
      program
        [ pet "v matches regex \"[a-z]+\""
        , "function mk (u :: Unit) -> Pet is Pet record{ name = \"ABC\" } end function" ]
        `shouldSatisfy` refused
    it "refuses the guard's own branch when the guard is negated" $
      program
        [ pet "v matches regex \"[a-z]+\""
        , "function mk (n :: Text) -> Pet is if not (n matches regex \"[a-z]+\") then Pet record{ name = n } else Pet record{ name = \"a\" } end if end function" ]
        `shouldSatisfy` refused
  describe "membership and tolerance" $ do
    it "proves a field membership from an identical argument refinement" $
      program
        [ "type Pet is a record{ kind :: (v :: Text where v in [\"cat\", \"dog\"]) } end type\n"
        , "function mk (n :: (v :: Text where v in [\"cat\", \"dog\"])) -> Pet is Pet record{ kind = n } end function" ]
        `shouldSatisfy` isRight
    it "proves a field membership from a narrower one and from a literal" $ do
      program
        [ "type Pet is a record{ kind :: (v :: Text where v in [\"cat\", \"dog\"]) } end type\n"
        , "function mk (n :: (v :: Text where v in [\"dog\"])) -> Pet is Pet record{ kind = n } end function" ]
        `shouldSatisfy` isRight
      program
        [ "type Pet is a record{ kind :: (v :: Text where v in [\"cat\", \"dog\"]) } end type\n"
        , "function mk (u :: Unit) -> Pet is Pet record{ kind = \"cat\" } end function" ]
        `shouldSatisfy` isRight
    it "proves an integer membership by arithmetic" $
      program
        [ "type Box is a record{ size :: (v :: Int32 where v in [1, 2, 3]) } end type\n"
        , "function mk (n :: (v :: Int32 where v >= 1 and v <= 2)) -> Box is Box record{ size = n } end function" ]
        `shouldSatisfy` isRight
    it "proves an exact tolerance by arithmetic" $
      program
        [ "type Box is a record{ size :: (v :: Int32 where v is within prelude.Int32 2 of prelude.Int32 10) } end type\n"
        , "function mk (n :: (v :: Int32 where v >= 9 and v <= 11)) -> Box is Box record{ size = n } end function" ]
        `shouldSatisfy` isRight
    it "refuses a wider membership and a literal outside it" $ do
      program
        [ "type Pet is a record{ kind :: (v :: Text where v in [\"cat\", \"dog\"]) } end type\n"
        , "function mk (n :: (v :: Text where v in [\"cat\", \"cow\"])) -> Pet is Pet record{ kind = n } end function" ]
        `shouldSatisfy` refused
      program
        [ "type Pet is a record{ kind :: (v :: Text where v in [\"cat\", \"dog\"]) } end type\n"
        , "function mk (u :: Unit) -> Pet is Pet record{ kind = \"cow\" } end function" ]
        `shouldSatisfy` refused
    it "refuses a tolerance the argument can exceed" $
      program
        [ "type Box is a record{ size :: (v :: Int32 where v is within prelude.Int32 2 of prelude.Int32 10) } end type\n"
        , "function mk (n :: (v :: Int32 where v >= 7 and v <= 11)) -> Box is Box record{ size = n } end function" ]
        `shouldSatisfy` refused
