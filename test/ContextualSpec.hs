-- | Contextual wording must preserve lexical scope and ordinary name resolution.
-- ref:DEC-readable-notation
module ContextualSpec (test_articlesPreserveOrdinaryNamesAndScope) where

import Data.Either (isLeft, isRight)
import Test.Hspec
import LawSpec.Common (Artifact(..))
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Frontend (compileCore, compileCoreCanonical)
import LawSpec.Model (Source(..), defaultGeneration, message)
import LawSpec.SourceText (formatSource)
import LawSpec.Testing (planTesting)
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S
import qualified LawSpec.Core.Evidence as E
import qualified LawSpec.Core.Verification as V

source :: String -> Source
source body = Source "articles.lawspec" ("unit articles\n" ++ body)

test_articlesPreserveOrdinaryNamesAndScope :: Spec
test_articlesPreserveOrdinaryNamesAndScope = describe "contextual articles" $ do
  let law proposition = "law selected is definition: " ++ proposition ++ " end end"
      checked body = compileCoreCanonical 64 defaultGeneration [source body]
      verified sources = case compileCoreCanonical 64 defaultGeneration sources >>= dischargeEvidenceWith (V.Verification [V.Exhaustive]) of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right evidence -> map E.obligationStatus (filter ((== "law") . E.obligationStage) evidence)
          `shouldSatisfy` all (== E.ExhaustivelyChecked)
  it "resolves the current and earlier universal binders in their restrictions" $
    verified [source (law "for all (enabled :: Bool where the enabled) (confirmed :: Bool where the confirmed = the enabled) => confirmed = true end")]
  it "keeps enclosing binders available to restricted existential witnesses" $
    verified [source (law "for all (enabled :: Bool) => there must exist a (reply :: Bool where the reply = the enabled) such that reply = enabled end end")]
  it "resolves given restrictions without changing the obligation" $
    verified [source (law "given (enabled :: Bool) when the enabled then enabled = true end")]
  it "retains the operand's original span after elaborating an article" $ do
    let input = source (unlines
          [ "law selected is", "  definition:", "    for all (enabled :: Bool where the enabled) =>", "      enabled = true", "    end", "  end", "end" ])
    case compileCoreCanonical 64 defaultGeneration [input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let predicates = [p | unit <- C.programUnits program, property <- C.unitProperties unit,
              q <- C.propertyInputs property, p <- C.quantifiedPredicates q]
        map C.expressionOrigin predicates `shouldBe`
          [C.SourceSpan (S.Span (S.Location "articles.lawspec" 4 40) (S.Location "articles.lawspec" 4 47))]
  it "resolves the existing local it inside a harness filter" $
    verified [source (unlines
      [ law "there exists (reply :: Bool) such that reply = true end"
      , "harness articles.testing for articles is"
      , "strategy replies :: Bool is (one of false, true) such that the it end"
      , "for law selected", "use replies for reply", "end" ])]
  it "preserves the bound record identity before field projection" $
    verified [source (unlines
      [ "type Authorization is a record{ granted :: Bool } end type"
      , law "for all (authorization :: Authorization where the authorization.granted) => authorization.granted = true end" ])]
  it "accepts articles before bound function arguments without changing application order" $
    verified [source (unlines
      [ "function allowed (first :: Bool) (second :: Bool) -> Bool is first and second end function"
      , law "for all (first :: Bool) (second :: Bool where allowed the first the second) => first and second end" ])]
  it "accepts a bound operand after named infix application inside a restriction" $
    verified [source (unlines
      [ "function authorizes (active :: Bool) (eligible :: Bool) -> Bool is active and eligible end function"
      , law "given (active :: Bool) (eligible :: Bool) when the active is `authorizes the eligible then active and eligible end" ])]
  it "keeps the single typed alternative payload when its argument has an article" $
    verified [source (unlines
      [ "type Decision is one of | Allowed of type Bool end type"
      , law "for all (flag :: Bool where Allowed the flag = Allowed true) => flag = true end" ])]
  it "preserves ordinary variables named the, a and an" $
    verified [source (law "for all (the :: Bool) (a :: Bool) (an :: Bool where the or an) => the or an end")]
  it "preserves application of a checked function named the inside a restriction" $
    verified [source (unlines
      [ "function the (flag :: Bool) -> Bool is not flag end function"
      , law "for all (flag :: Bool where the flag) => flag = false end" ])]
  it "preserves an imported function named the and its explicit qualified form" $ do
    let library = Source "library.lawspec" "unit library\nfunction the (flag :: Bool) -> Bool is not flag end function\n"
        caller = source (unlines
          [ "import library as predicates (the)"
          , law "for all (flag :: Bool where the flag and predicates.the flag) => flag = false end" ])
    verified [library,caller]
  it "preserves a law parameter named the during reusable-law expansion" $
    verified [source (unlines
      [ "law restricted (the :: Bool) is definition: for all (flag :: Bool where the or flag) => the or flag end end end"
      , "law selected is definition: apply law restricted false end end" ])]
  it "retains intrinsic purity checks for a function parameter named the" $
    case checked "law restricted (the :: Bool -> Bool) is definition: for all (flag :: Bool where the flag) => flag = false end end end" of
      Left diagnostics -> map message diagnostics `shouldContain` ["adapter calls are forbidden in refinement predicates"]
      Right _ -> expectationFailure "a law parameter must not become an article or bypass refinement purity"
  it "does not invent references to later, sibling or missing binders" $
    mapM_ (\proposition -> checked (law proposition) `shouldSatisfy` isLeft)
      [ "for all (early :: Bool where the later) (later :: Bool) => early end"
      , "(for all (other :: Bool) => other = other end) and (for all (flag :: Bool where the other) => flag end)"
      , "there exists (reply :: Bool where the missing) such that reply end" ]
  it "keeps the article contextual to restrictions" $ do
    checked (law "for all (flag :: Bool) => the flag = flag end") `shouldSatisfy` isLeft
    checked "function the (flag :: Bool) -> Bool is flag end function" `shouldSatisfy` isRight
  it "retains legacy application and does not enable article sugar in legacy input" $ do
    let legacy body = compileCore 64 defaultGeneration [source body]
    legacy "definition the (flag :: Bool) :: Bool is !flag end\nlaw `selected` is definition is `for all` (flag :: Bool where the flag). flag = false end end" `shouldSatisfy` isRight
    legacy "law `selected` is definition is `for all` (flag :: Bool where the flag). flag = true end end" `shouldSatisfy` isLeft
  it "formats without dropping wording and emits the same checked programs on every target" $ do
    let worded = source (law "for all (enabled :: Bool where the enabled) => enabled = true end")
        plain = source (law "for all (enabled :: Bool where enabled) => enabled = true end")
        generated bits input = compileCoreCanonical bits defaultGeneration [input] >>= planTesting
        contents target plan = fmap (map (\a -> (artifactPath a,artifactContent a))) (emitPlan target plan)
    formatSource (formatSource worded) `shouldBe` formatSource worded
    verified [formatSource worded]
    mapM_ (\bits -> case (generated bits worded,generated bits plain) of
      (Right a,Right b) -> mapM_ (\target -> contents target a `shouldBe` contents target b) targets
      (a,b) -> expectationFailure (show a ++ "\n" ++ show b)) [32,64]
