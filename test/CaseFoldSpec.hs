-- | Check the upstream data independently of the generated lookup tree.
-- ref:DEC-readable-notation
module CaseFoldSpec (test_caseFold) where

import Data.Char (chr)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import Numeric (readHex)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Model (Source(..),defaultGeneration,message)
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Core.Evidence (obligationStatus,obligationStage,Status(..))
import qualified LawSpec.Core.Verification as V
import LawSpec.CaseFold (caseFoldDemand,caseFoldSource,usesCaseFold)
import LawSpec.PreludeNames (preludeDependencyText)
import LawSpec.CaseFoldData (caseFoldMappings)
import LawSpec.Testing (planTestingWith)
import LawSpec.CoreEmit (emitPlan)

test_caseFold :: Spec
test_caseFold = describe "pinned full default Unicode case folding" $ do
  it "emits the compiler-owned text module through Gleam while rejecting user namespace collisions" $ do
    let verify source outcome = case compileCoreCanonical 64 defaultGeneration [source] >>=
          planTestingWith (V.Verification []) of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right plan -> outcome (emitPlan "gleam" plan)
    verify (Source "folding.lawspec" "unit folding\n\nfunction folded (text :: Text) -> Text is prelude.caseFold text end function\nend unit\n")
      (`shouldSatisfy` isRight)
    verify (Source "intruder.lawspec" "unit lawspec.intruder\n\nfunction same (flag :: Bool) -> Bool is flag end function\nend unit\n")
      (`shouldSatisfy` isLeft)
  it "embeds every C/F mapping from Unicode 17 and excludes simple and Turkic overrides" $ do
    original <- readFile "vendor/unicode/17.0.0/CaseFolding.txt"
    let fields line = case break (== ';') line of
          (a,';':rest) -> a : fields rest
          (a,[]) -> [a]
        code text = case readHex text of [(value,"")] -> chr value; _ -> error "invalid upstream code point"
        expected = [(map code (words key),map code (words value)) |
          line <- lines original,not (null line),head line /= '#',
          key:status:value:_ <- [fields line],words status `elem` [["C"],["F"]]]
    caseFoldMappings `shouldBe` expected
    length expected `shouldBe` 1585
  it "uses checked decreasing spans and portable text operations, without a target Unicode API" $ do
    caseFoldSource `shouldSatisfy` isInfixOf "textFoldSpan text start half"
    usesCaseFold "function ordinary (x :: Text) -> Text is prelude.caseFold x end function\n" `shouldBe` True
    usesCaseFold "function ordinary (x :: Text) -> Text is x end function -- caseFold\n" `shouldBe` False
    usesCaseFold "law documented is description: \"caseFold\" end description definition: true end definition end law" `shouldBe` False
  it "leaves the text unit out for a unit's own caseFold, unless it also names the prelude's" $ do
    let own = "function caseFold (value :: Text) -> Text is value end function\n"
        demand text = caseFoldDemand text (preludeDependencyText text)
    demand (own ++ "function twice (x :: Text) -> Text is caseFold (caseFold x) end function\n") `shouldBe` False
    demand (own ++ "function both (x :: Text) -> Text is prelude.caseFold (caseFold x) end function\n") `shouldBe` True
    demand "function ordinary (x :: Text) -> Text is caseFold x end function\n" `shouldBe` True
    demand (own ++ "function found (x :: Text) -> Bool is textContains x \"a\" end function\n") `shouldBe` True
    demand "function ordinary (x :: Text) -> Text is x end function\n" `shouldBe` False
    demand ("function textContains (a :: Text) (b :: Text) -> Bool is true end function\n" ++
      "function found (x :: Text) -> Bool is x `prelude.textContains` \"a\" end function\n") `shouldBe` True
    demand ("function textContains (a :: Text) (b :: Text) -> Bool is true end function\n" ++
      "function found (x :: Text) -> Bool is x `textContains` \"a\" end function\n") `shouldBe` False
    let compiled content = compileCoreCanonical 64 defaultGeneration [Source "own.lawspec" ("unit own\n\n" ++ content ++ "end unit\n")]
        units = either (const []) (map (C.idText . C.unitId) . C.programUnits)
    units (compiled (own ++ "law folded is definition: caseFold \"BRM\" = \"BRM\" end definition end law\n"))
      `shouldSatisfy` (\names -> "own" `elem` names && "lawspec.text" `notElem` names)
    units (compiled (own ++ "law folded is definition: prelude.caseFold \"BRM\" = \"brm\" and caseFold \"BRM\" = \"BRM\" end definition end law\n"))
      `shouldSatisfy` (elem "lawspec.text")
  it "checks expansions, supplementary code points, default I, identity and no normalization" $ do
    let cases = [("Straße Σς ﬃ İ I 𐐀", "strasse σσ ffi i\x307 i 𐐨"),
          ("é e\x301", "é e\x301"),("🙂\NUL", "🙂\NUL"),("", "")]
        law (input,expected) = "prelude.caseFold " ++ show input ++ " = " ++ show expected
        content = "unit folding\nlaw exact is definition: " ++
          foldr1 (\a b -> a ++ " and " ++ b) (map law cases) ++ " end definition end law\nend unit\n"
    case compileCoreCanonical 64 defaultGeneration [Source "folding.lawspec" content] >>=
        dischargeEvidenceWith (V.Verification [V.Exhaustive]) of
      Left diagnostics -> expectationFailure (show (map message diagnostics))
      Right evidence -> map obligationStatus (filter ((== "law") . obligationStage) evidence)
        `shouldBe` [ExhaustivelyChecked]
