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
import LawSpec.Model (Source(..),Diagnostic,defaultGeneration)
import LawSpec.Testing (planTestingWith)

compile sources = compileCoreCanonical 64 defaultGeneration sources
body text = compile [Source "prelude-names.lawspec" ("unit names\n\n" ++ text ++ "\nend unit\n")]
checked :: Either [Diagnostic] C.Program -> Expectation
checked result = case result of
  Left diagnostics -> expectationFailure (show diagnostics)
  Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
    (dischargeEvidenceWith (Verification [Exhaustive,Examples]) program)
      `shouldSatisfy` either (const False) (all (== ExhaustivelyChecked))

test_preludeResolution = describe "unqualified prelude resolution" $ do
  it "does not load collection catalogues for shadowed operation names" $ do
    let result = body (unlines
          [ "function values (member :: Bool) -> Bool is member end function"
          , ""
          , "function echo (values :: a) -> a is values end function"
          , ""
          , "function head (items :: List Bool) -> Bool is first matching case of items: when Cons values remaining then values otherwise false end case end function"
          , ""
          , "law scoped is description: \"prelude.values prelude.setOf\" end description definition: for all (values :: Bool where values = true) => echo values and head [values] end for all end definition end law" ])
    checked result
    case result of
      Left _ -> pure ()
      Right program -> do
        map (C.idText . C.unitId) (C.programUnits program) `shouldSatisfy` (notElem "lawspec.collections")
        map (C.idText . C.dataId) (C.programDataDeclarations program)
          `shouldSatisfy` all (not . isInfixOf "lawspec.collections::")
  it "retains real map operations beside same-spelled lexical bindings" $ do
    let result = body (unlines
          [ "function echo (values :: Bool) -> Bool is values end function\n"
          , "function selected (items :: KeyVal Bool Integer) -> List Integer is values items end function\n"
          , "law mapped is definition: selected (keyValOf [Entry true 7]) = [7] and echo true end definition end law" ])
    checked result
    case result of
      Left _ -> pure ()
      Right program -> map (C.idText . C.dataId) (C.programDataDeclarations program)
        `shouldContain` ["lawspec.collections::type::Entry","lawspec.collections::type::KeyVal"]
  it "retains ordering and pairs introduced by primitive operations" $ do
    checked (body "law ordering is definition: compare 2 1 = Greater end definition end law\n")
    forM_ ["prelude.both (Right true :: Either Text Bool) (Right false :: Either Text Bool)",
           "(Right true :: Either Text Bool) <*> (Right false :: Either Text Bool)"] $ \expression ->
      case body ("law paired is definition: " ++ expression ++ " = " ++ expression ++ " end definition end law\n") of
        Left ds -> expectationFailure (show ds)
        Right program -> do
          map (C.idText . C.dataId) (C.programDataDeclarations program)
            `shouldContain` ["lawspec.collections::type::Pair"]
          checked (Right program)
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
    checked (body "function length (value :: Bool) -> Integer is 7 end function\nlaw local is definition: length true = 7 and prelude.length [] = 0 end definition end law\n")
  it "does not retry a local name as a prelude helper when its types disagree" $
    body "function length (value :: Bool) -> Bool is value end function\nlaw invalid is definition: length [] = true end definition end law\n" `shouldSatisfy` isLeft
  it "keeps lexical parameters and quantifier binders" $
    checked (body "function echo (length :: Bool) -> Bool is length end function\nlaw scoped is definition: for all (member :: Bool) => echo member = member end for all end definition end law\n")
  it "keeps function parameters of reusable laws ahead of prelude helpers" $
    checked (body "function identity (value :: Bool) -> Bool is value end function\nlaw preserves (length :: Bool -> Bool) is definition: for all (member :: Bool) => length member = member end for all end definition end law\nlaw instance is definition: apply law preserves identity end definition end law\n")
  it "does not reinterpret an ordinary local function called any" $
    checked (body "function any (first :: Bool) (second :: Bool) -> Bool is false end function\nlaw local is definition: any true true = false end definition end law\n")
  it "keeps reserved public operation names available through qualification" $
    checked (body "function accept (value :: Bool) -> Either Text Bool is Right value end function\nlaw linked is definition: prelude.then (Right true :: Either Text Bool) accept = Right true end definition end law\n")
  it "does not optimize user constructors as built-in Either alternatives" $
    forM_ ["bind (Right value) selected","prelude.bind (Right value) selected","(Right value) >>= selected"] $ \expression ->
      body ("type Choice is one of | Right of type Bool end type\nfunction selected (value :: Bool) -> Bool is value end function\nfunction invalid (value :: Bool) -> Bool is " ++ expression ++ " end function\n") `shouldSatisfy` isLeft
  it "lets explicit imported definitions take precedence over prelude names" $ do
    let domain = Source "domain.lawspec" "unit domain\n\nfunction setOf (value :: Bool) -> Bool is not value end function\nend unit\n"
        use = Source "use.lawspec" "unit use\nimport domain as domain (setOf)\nlaw imported is definition: setOf true = false end definition end law\nend unit\n"
    checked (compile [domain,use])
  it "reports ambiguous explicit imports instead of choosing the prelude" $ do
    let library unit = Source (unit ++ ".lawspec") ("unit " ++ unit ++ "\nfunction length (value :: Bool) -> Bool is value end function\nend unit\n")
        use = Source "use.lawspec" "unit use\nimport first as first (length)\nimport second as second (length)\nlaw ambiguous is definition: length true = true end definition end law\nend unit\n"
    case compile [library "first",library "second",use] of
      Left diagnostics -> show diagnostics `shouldSatisfy` isInfixOf "imported from more than one unit"
      Right _ -> expectationFailure "ambiguous imports were silently resolved"
  it "keeps a local constructor ahead of a same-spelled numeric conversion" $
    checked (body "type Choice is one of | Int32 of type Bool end type\nlaw constructor is definition: Int32 true = Int32 true end definition end law\n")
  it "keeps an imported constructor ahead of a same-spelled numeric conversion" $ do
    let domain = Source "domain.lawspec" "unit domain\n\ntype Choice is one of | Int32 of type Bool end type\nend unit\n"
        use = Source "use.lawspec" "unit use\nimport domain as domain (Choice)\nlaw constructor is definition: Int32 true = Int32 true end definition end law\nend unit\n"
    checked (compile [domain,use])
  it "retains the existing rejection of uppercase function declarations" $
    body "function Int32 (value :: Bool) -> Bool is not value end function\nlaw local is definition: Int32 true = false end definition end law\n" `shouldSatisfy` isLeft
  it "loads operation providers while keeping every same-spelled local type nominal" $
    checked (body "type Regex is one of | OwnRegex end type\ntype Duration is one of | OwnDuration end type\ntype RetryDecision is one of | OwnRetry end type\nfunction identity (value :: Regex) -> Regex is value end function\nlaw separate is definition: identity OwnRegex = OwnRegex and OwnDuration = OwnDuration and OwnRetry = OwnRetry and sameItems [true, false] [false, true] and prelude.sameItems [false] [false] and toMicroseconds (seconds 2) = 2000000 and prelude.toMicroseconds (prelude.seconds 1) = 1000000 end definition end law\n")
  it "keeps explicitly imported type names while loading only the provider namespace" $ do
    let domain = Source "domain.lawspec" "unit domain\n\ntype Regex is one of | OwnRegex end type\ntype Duration is one of | OwnDuration end type\ntype RetryDecision is one of | OwnRetry end type\nend unit\n"
        use = Source "use.lawspec" "unit use\nimport domain as domain (Regex, Duration, RetryDecision)\nfunction identity (value :: Regex) -> Regex is value end function\nlaw separate is definition: identity OwnRegex = OwnRegex and OwnDuration = OwnDuration and OwnRetry = OwnRetry and sameItems [true] [true] and toMicroseconds (seconds 1) = 1000000 end definition end law\nend unit\n"
    checked (compile [domain,use])
  it "does not unwrap or substitute a local nominal type for a provider type" $
    forM_ ["Duration","Regex"] $ \name ->
      body ("type " ++ name ++ " is one of | Own end type\nfunction invalid (unused :: Bool) -> " ++ name ++ " is " ++ (if name == "Duration" then "seconds 1" else "regex \"a\"") ++ " end function\n") `shouldSatisfy` isLeft
  it "keeps an uppercase lexical binding ahead of a numeric conversion" $
    checked (body "function echo (Int32 :: Bool) -> Bool is Int32 end function\nlaw local is definition: echo true = true end definition end law\n")
  it "keeps a named infix call in the same local namespace as its prefix call" $
    checked (body "function member (left :: Bool) (right :: Bool) -> Bool is false end function\nlaw local is definition: member true false = false and (true `member false) = false end definition end law\n")
  it "keeps a binder visible in its own restriction" $
    checked (body "law scoped is definition: for all (length :: Bool where length = true) => length end for all end definition end law\n")
  it "retains explicit numeric-conversion definedness" $
    body "function invalid (unused :: Bool) -> Int8 is Int8 128 end function\n" `shouldSatisfy` isLeft
  it "requires Eq for generic membership but not predicate iteration" $ do
    body "function includes (value :: a) (items :: List a) -> Bool is member value items end function\n" `shouldSatisfy` isLeft
    body "function includes (value :: a) (items :: List a) -> Bool requires Eq a is member value items end function\n" `shouldSatisfy` isRight
    body "function selected (value :: a) -> Bool is true end function\nfunction scan (items :: List a) -> Bool is any selected items end function\n" `shouldSatisfy` isRight
  it "keeps strict arguments and predicate captures checked on empty collections" $ do
    body "function invalid (unused :: Bool) -> Bool is member (1 / 0) ([] :: List Integer) end function\n" `shouldSatisfy` isLeft
    body "function exceeds (limit :: Integer) (value :: Integer) -> Bool is value > limit end function\nfunction invalid (unused :: Bool) -> Bool is any (exceeds (1 / 0)) ([] :: List Integer) end function\n" `shouldSatisfy` isLeft
  it "does not export internal helpers or repair misspellings" $
    forM_ ["incompleteSearch ()","acquireResource ()","lenght [true]"] $ \expression ->
      body ("law invalid is definition: " ++ expression ++ " = true end definition end law\n") `shouldSatisfy` isLeft
  it "ignores helper words inside comments, strings and phrase-name bodies during discovery" $ do
    let result = body "-- setOf seconds sameItems\nfunction \"|setOf seconds sameItems| (unused :: Bool) -> Bool is true end function\nlaw text is description: \"setOf seconds sameItems\" end description definition: true = true end definition end law"
    checked result
    case result of
      Right program -> map (C.idText . C.unitId) (C.programUnits program)
        `shouldSatisfy` all (`notElem` ["lawspec.collections","lawspec.time","lawspec.matchers"])
      Left _ -> pure ()
