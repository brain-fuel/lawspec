module PreludeResolutionSpec (test_preludeResolution) where

import Test.Hspec
import Control.Monad (forM_)
import Data.Either (isLeft,isRight)
import Data.List (isInfixOf)
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation(..),Status(..))
import LawSpec.Core.Verification (Verification(..),Layer(..))
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Testing (planTestingWith)

compile sources = compileCoreCanonical 64 defaultGeneration sources
body text = compile [Source "prelude-names.lawspec" ("unit names\n" ++ text)]
checked result = case result of
  Left diagnostics -> expectationFailure (show diagnostics)
  Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
    (dischargeEvidenceWith (Verification [Exhaustive,Examples]) program)
      `shouldSatisfy` either (const False) (all (== ExhaustivelyChecked))

test_preludeResolution = describe "unqualified prelude resolution" $ do
  it "uses the ordinary checked collection, matcher and duration providers" $ do
    source <- readFile "test/fixtures/canonical-prelude-names.lawspec"
    let result = compile [Source "prelude-names.lawspec" source]
    checked result
    case result of
      Left _ -> pure ()
      Right program -> case planTestingWith (Verification [Exhaustive,Examples]) program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right plan -> forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "gives local declarations precedence and keeps explicit prelude access" $
    checked (body "function length (value :: Bool) -> Integer is 7 end function\nlaw local is definition: length true = 7 and prelude.length [] = 0 end end")
  it "does not retry a local name as a prelude helper when its types disagree" $
    body "function length (value :: Bool) -> Bool is value end function\nlaw invalid is definition: length [] = true end end" `shouldSatisfy` isLeft
  it "keeps lexical parameters and quantifier binders" $
    checked (body "function echo (length :: Bool) -> Bool is length end function\nlaw scoped is definition: for all (member :: Bool) => echo member = member end end end")
  it "keeps function parameters of reusable laws ahead of prelude helpers" $
    checked (body "function identity (value :: Bool) -> Bool is value end function\nlaw preserves (length :: Bool -> Bool) is definition: for all (member :: Bool) => length member = member end end end\nlaw instance is definition: apply law preserves identity end end")
  it "does not reinterpret an ordinary local function called any" $
    checked (body "function any (first :: Bool) (second :: Bool) -> Bool is false end function\nlaw local is definition: any true true = false end end")
  it "keeps reserved public operation names available through qualification" $
    checked (body "function accept (value :: Bool) -> Either Text Bool is Right value end function\nlaw linked is definition: prelude.then (Right true :: Either Text Bool) accept = Right true end end")
  it "does not optimize user constructors as built-in Either alternatives" $
    forM_ ["bind (Right value) selected","prelude.bind (Right value) selected","(Right value) >>= selected"] $ \expression ->
      body ("type Choice is one of | Right of type Bool end type\nfunction selected (value :: Bool) -> Bool is value end function\nfunction invalid (value :: Bool) -> Bool is " ++ expression ++ " end function") `shouldSatisfy` isLeft
  it "lets explicit imported definitions take precedence over prelude names" $ do
    let domain = Source "domain.lawspec" "unit domain\nfunction setOf (value :: Bool) -> Bool is not value end function"
        use = Source "use.lawspec" "unit use\nimport domain as domain (setOf)\nlaw imported is definition: setOf true = false end end"
    checked (compile [domain,use])
  it "reports ambiguous explicit imports instead of choosing the prelude" $ do
    let library unit = Source (unit ++ ".lawspec") ("unit " ++ unit ++ "\nfunction length (value :: Bool) -> Bool is value end function")
        use = Source "use.lawspec" "unit use\nimport first as first (length)\nimport second as second (length)\nlaw ambiguous is definition: length true = true end end"
    case compile [library "first",library "second",use] of
      Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf "imported from more than one unit"
      Right _ -> expectationFailure "ambiguous imports were silently resolved"
  it "keeps a local constructor ahead of a same-spelled numeric conversion" $
    checked (body "type Choice is one of | Int32 of type Bool end type\nlaw constructor is definition: Int32 true = Int32 true end end")
  it "keeps an imported constructor ahead of a same-spelled numeric conversion" $ do
    let domain = Source "domain.lawspec" "unit domain\ntype Choice is one of | Int32 of type Bool end type"
        use = Source "use.lawspec" "unit use\nimport domain as domain (Choice)\nlaw constructor is definition: Int32 true = Int32 true end end"
    checked (compile [domain,use])
  it "retains the existing rejection of uppercase function declarations" $
    body "function Int32 (value :: Bool) -> Bool is not value end function\nlaw local is definition: Int32 true = false end end" `shouldSatisfy` isLeft
  it "loads operation providers while keeping every same-spelled local type nominal" $
    checked (body "type Regex is one of | OwnRegex end type\ntype Duration is one of | OwnDuration end type\ntype RetryDecision is one of | OwnRetry end type\nfunction identity (value :: Regex) -> Regex is value end function\nlaw separate is definition: identity OwnRegex = OwnRegex and OwnDuration = OwnDuration and OwnRetry = OwnRetry and sameItems [true, false] [false, true] and prelude.sameItems [false] [false] and toMicroseconds (seconds 2) = 2000000 and prelude.toMicroseconds (prelude.seconds 1) = 1000000 end end")
  it "keeps explicitly imported type names while loading only the provider namespace" $ do
    let domain = Source "domain.lawspec" "unit domain\ntype Regex is one of | OwnRegex end type\ntype Duration is one of | OwnDuration end type\ntype RetryDecision is one of | OwnRetry end type"
        use = Source "use.lawspec" "unit use\nimport domain as domain (Regex, Duration, RetryDecision)\nfunction identity (value :: Regex) -> Regex is value end function\nlaw separate is definition: identity OwnRegex = OwnRegex and OwnDuration = OwnDuration and OwnRetry = OwnRetry and sameItems [true] [true] and toMicroseconds (seconds 1) = 1000000 end end"
    checked (compile [domain,use])
  it "does not unwrap or substitute a local nominal type for a provider type" $
    forM_ ["Duration","Regex"] $ \name ->
      body ("type " ++ name ++ " is one of | Own end type\nfunction invalid (unused :: Bool) -> " ++ name ++ " is " ++ (if name == "Duration" then "seconds 1" else "regex \"a\"") ++ " end function") `shouldSatisfy` isLeft
  it "keeps an uppercase lexical binding ahead of a numeric conversion" $
    checked (body "function echo (Int32 :: Bool) -> Bool is Int32 end function\nlaw local is definition: echo true = true end end")
  it "keeps a named infix call in the same local namespace as its prefix call" $
    checked (body "function member (left :: Bool) (right :: Bool) -> Bool is false end function\nlaw local is definition: member true false = false and (true `member false) = false end end")
  it "keeps a binder visible in its own restriction" $
    checked (body "law scoped is definition: for all (length :: Bool where length = true) => length end end end")
  it "retains explicit numeric-conversion definedness" $
    body "function invalid (unused :: Bool) -> Int8 is Int8 128 end function" `shouldSatisfy` isLeft
  it "requires Eq for generic membership but not predicate iteration" $ do
    body "function includes (value :: a) (items :: List a) -> Bool is member value items end function" `shouldSatisfy` isLeft
    body "function includes (value :: a) (items :: List a) -> Bool requires Eq a is member value items end function" `shouldSatisfy` isRight
    body "function selected (value :: a) -> Bool is true end function\nfunction scan (items :: List a) -> Bool is any selected items end function" `shouldSatisfy` isRight
  it "keeps strict arguments and predicate captures checked on empty collections" $ do
    body "function invalid (unused :: Bool) -> Bool is member (1 / 0) ([] :: List Integer) end function" `shouldSatisfy` isLeft
    body "function exceeds (limit :: Integer) (value :: Integer) -> Bool is value > limit end function\nfunction invalid (unused :: Bool) -> Bool is any (exceeds (1 / 0)) ([] :: List Integer) end function" `shouldSatisfy` isLeft
  it "does not export internal helpers or repair misspellings" $
    forM_ ["incompleteSearch ()","acquireResource ()","lenght [true]"] $ \expression ->
      body ("law invalid is definition: " ++ expression ++ " = true end end") `shouldSatisfy` isLeft
  it "ignores helper words inside comments, strings and phrase-name bodies during discovery" $ do
    let result = body "-- setOf seconds sameItems\nfunction \"|setOf seconds sameItems| (unused :: Bool) -> Bool is true end function\nlaw text is description: \"setOf seconds sameItems\" end definition: true = true end end"
    checked result
    case result of
      Right program -> map (C.idText . C.unitId) (C.programUnits program)
        `shouldSatisfy` all (`notElem` ["lawspec.collections","lawspec.time","lawspec.matchers"])
      Left _ -> pure ()
