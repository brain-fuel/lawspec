-- The kept-values store keys what it keeps by the definitions an input
-- reaches, so a changed restriction makes old values unreachable, and it keeps
-- nothing for a law with no restricted input or when switched off.
module KeptValuesSpec (test_keptValuesSpecs) where

import Test.Hspec
import Data.List (isInfixOf)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Search (Kept(..), keptFor)

program :: String -> C.Program
program body = case compileCoreCanonical 64 defaultGeneration [Source "kept.lawspec" ("unit example.kept\n\n" ++ body ++ "\nend unit\n")] of
  Right compiled -> compiled
  Left diagnostics -> error (show diagnostics)

wrapper :: String -> String
wrapper restriction = "wrapper Even is Integer where " ++ restriction ++ " end wrapper\n"
  ++ "law \"|even| is definition: for all (n :: Even) => valueOfEven n = valueOfEven n end for all end definition end law\n"

kept :: String -> Maybe Kept
kept body = case concatMap C.unitProperties (C.programUnits compiled) of
  p : _ -> keptFor 64 (C.programDataDeclarations compiled) p
  [] -> Nothing
  where compiled = program body

test_keptValuesSpecs :: Spec
test_keptValuesSpecs = describe "the kept-values spec of a law" $ do
  it "names a key, the cap and the restricted constructors" $
    fmap (words . keptSpec) (kept (wrapper "prelude.rem value 2 = 0")) `shouldSatisfy`
      maybe False (\ws -> case ws of key : "16" : tags -> length key == 32 && any ("Even" `isInfixOf`) tags; _ -> False)
  it "changes the key when the restriction changes" $
    fmap (take 1 . words . keptSpec) (kept (wrapper "prelude.rem value 2 = 0")) `shouldNotBe`
      fmap (take 1 . words . keptSpec) (kept (wrapper "prelude.rem value 4 = 0"))
  it "keeps the key when only a comment changes" $
    fmap (take 1 . words . keptSpec) (kept (wrapper "prelude.rem value 2 = 0")) `shouldBe`
      fmap (take 1 . words . keptSpec) (kept ("-- a comment\n" ++ wrapper "prelude.rem value 2 = 0"))
  it "describes no input of a law without a restricted type" $
    kept "law \"|plain| is definition: for all (n :: Integer) => n = n end for all end definition end law\n" `shouldBe` Nothing
  it "keeps nothing at a cap of 0" $
    case C.programUnits (program (wrapper "prelude.rem value 2 = 0")) of
      u : _ -> [keptFor 64 (C.programDataDeclarations (program (wrapper "prelude.rem value 2 = 0")))
                  p { C.propertyGeneration = (C.propertyGeneration p) { keptValues = 0 } } | p <- C.unitProperties u] `shouldBe` [Nothing]
      [] -> expectationFailure "no unit"
  it "keeps nothing for a law whose strategy may draw from part of the type" $
    case C.programUnits compiled of
      u : _ ->
        [ ( keptFor 64 (C.programDataDeclarations compiled) (drawn p (C.DrawOneOf evenType [])) == Nothing
          , keptFor 64 (C.programDataDeclarations compiled) (drawn p whole) /= Nothing )
        | p <- C.unitProperties u ] `shouldBe` [(True, True)]
      [] -> expectationFailure "no unit"
  where
    compiled = program (wrapper "prelude.rem value 2 = 0")
    evenType = C.Constructor "Even" []
    whole = C.DrawAny evenType Nothing
    drawn p d = p { C.propertyHarness = (C.propertyHarness p) { C.harnessDraws = [(C.Id "n", "s", d)] } }
