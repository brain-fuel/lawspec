module PayloadTransportSpec (test_payloadTransport) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Binary as Binary
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Vector as Vector
import qualified LawSpec.Core as C
import qualified LawSpec.Compile as Compile
import qualified LawSpec.Frontend as Frontend
import LawSpec.Core.Definitions (prepareHookedDefinitions,prepareDefinitions)
import LawSpec.Core.Migration (normalizedProgram,transformProgram,migrationSnapshot)
import LawSpec.Core.PayloadTransport
import LawSpec.Core.Value (Value(..),compareValues)
import qualified LawSpec.Core.Value as CV
import LawSpec.Core.Validate (validateProgram)
import LawSpec.MigrationPayloads (payloadCorrespondenceWithPlan)
import LawSpec.MigrationDomains (withTransportDomains)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Scalar (Scalar(..))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

checked canonical bits text = do
  (units,laws,_,captured)<-either (fail.show) pure
    (Compile.compileWithMigrationCapture canonical (\_ name->name) (\_ _->Nothing) bits defaultGeneration
      [Source "transport.lawspec" text])
  core<-either (fail.show) pure ((if canonical then Frontend.elaborateCanonical else Frontend.elaborate) bits units laws)
  templates<-maybe (fail "missing checked templates") pure captured
  pure (core,templates)

pair bits old new=do
  (before,a)<-checked False bits ("unit transport\n"++old)
  (after,b)<-checked True bits ("unit transport\n"++new)
  (_,certificate)<-either fail pure (payloadCorrespondenceWithPlan a b)
  plan<-maybe (fail "payload shapes did not establish a transport plan") pure certificate
  pure (plan,before,after)

field key (Object value)=KM.lookup key value
field _ _=Nothing
domainRows key view=case field key view >>= field "inputDomains" >>= field "domains" of
  Just (Array rows)->Vector.toList rows
  _->[]
domainComparison bits before after=do
  (plan,old,new)<-pair bits before after
  (copy,view)<-either fail pure (transportComparisonWithProgram plan [] old [] new)
  pure (withTransportDomains [] copy [] new view)
correspondence bits old new=do
  (plan,before,after)<-pair bits old new
  either fail pure (transportComparison plan [] before [] after)
matched bits old new=do
  result<-correspondence bits old new
  field "copyValidated" result `shouldBe` Just (Bool True)
  field "status" result `shouldBe` Just (String "matched")
  pure result

oldType="type Capsule is | Packed last :: Bool first :: Bool end\n"
newType="type Capsule is one of | Packed of type record{last :: Bool first :: Bool} end type\n"
oldMake="definition make (flag :: Bool) :: Capsule is Packed flag false end\n"
newMake="function make (flag :: Bool) -> Capsule is Packed record{last = flag, first = false} end function\n"
oldRead="definition read (input :: Capsule) :: Bool is match input with | Packed last first -> last end end\n"
newRead="function read (input :: Capsule) -> Bool is first matching case of input: when Packed record{last = last, first = first} then last end case end function\n"

-- The same closed dispatcher and effect-hook mechanism used by spec handlers.
-- Logging changes neither the interpreter nor the program's representation.
recordOperation :: IORef [Bool] -> [CV.Value] -> Either String CV.Value
recordOperation trace [value@(ScalarValue (SBool flag))]=unsafePerformIO $ do
  modifyIORef' trace (++[flag])
  pure (Right value)
recordOperation _ _=Left "invalid test operation"
{-# NOINLINE recordOperation #-}
runObserved program = do
  trace<-newIORef []
  invoke<-either (fail.show) pure (prepareHookedDefinitions program)
  let hook _ identity
        | C.idText identity=="transport::ability::Trace::mark"=Just (recordOperation trace)
        | otherwise=Nothing
      answer=invoke hook (C.Id "transport::run") [ScalarValue (SBool True)]
  _<-evaluate (length (show answer))
  observed<-readIORef trace
  pure (observed,answer)

test_payloadTransport=describe "checked executable payload transport" $ do
  it "anchors the validated comparison copy to both original admitted programs" $ do
    (plan,old,new)<-pair 64 (oldType++oldMake) (newType++newMake)
    let original=Binary.encode old
    (copy,view)<-either fail pure (transportComparisonWithProgram plan [] old [] new)
    before<-either fail pure (migrationSnapshot False [] old)
    after<-either fail pure (migrationSnapshot True [] new)
    field "sourceBeforeDigest" view `shouldBe` field "programDigest" before
    (field "after" view >>= field "programDigest") `shouldBe` field "programDigest" after
    Binary.encode old `shouldBe` original
    validateProgram copy `shouldBe` Right ()
  it "verifies input tuples independently on both transported representations" $
    forM_ [32,64] $ \bits -> do
      view<-domainComparison bits (oldType++"law `same` is definition is `for all` (value :: Capsule) . value = value end end")
        (newType++"law \"|same| is definition: for all (value :: Capsule) => value = value end end end")
      let before=domainRows "before" view; after=domainRows "after" view
      length before `shouldBe` 1
      map (field "status") before `shouldBe` [Just (String "inhabited")]
      map (field "domainDigest") before `shouldBe` map (field "domainDigest") after
      map (field "status") after `shouldBe` [Just (String "inhabited")]
  it "retains changed transitive restriction dependencies after transport" $ do
    let before=oldType++"definition allowed (value :: Capsule) :: Bool is value.last end\n"++
          "law `same` is definition is `for all` (value :: Capsule where allowed value) . value = value end end"
        after=newType++"function allowed (value :: Capsule) -> Bool is not value.value.last end function\n"++
          "law \"|same| is definition: for all (value :: Capsule where allowed value) => value = value end end end"
    view<-domainComparison 64 before after
    map (field "status") (domainRows "before" view) `shouldBe` [Just (String "inhabited")]
    map (field "status") (domainRows "after" view) `shouldBe` [Just (String "inhabited")]
    map (field "domainDigest") (domainRows "before" view) `shouldNotBe` map (field "domainDigest") (domainRows "after" view)
  it "retains complete empty input domains rather than inventing transported witnesses" $ do
    view<-domainComparison 64 (oldType++"law `same` is definition is `for all` (value :: Capsule where false) . value = value end end")
      (newType++"law \"|same| is definition: for all (value :: Capsule where false) => value = value end end end")
    map (field "status") (domainRows "before" view) `shouldBe` [Just (String "empty")]
    map (field "status") (domainRows "after" view) `shouldBe` [Just (String "empty")]
  it "does not evaluate a false law body while establishing its input domain" $ do
    view<-domainComparison 64 (oldType++"law `same` is definition is `for all` (value :: Capsule) . value = value end end")
      (newType++"law \"|same| is definition: for all (value :: Capsule) => false end end end")
    (field "lawBodies" view >>= field "status") `shouldBe` Just (String "not-established")
    map (field "status") (domainRows "after" view) `shouldBe` [Just (String "inhabited")]
    (field "after" view >>= field "inputDomains" >>= field "lawBodiesEvaluated") `shouldBe` Just (Bool False)
  it "preserves complete Core byte-for-byte under an identity traversal" $ do
    forM_ ["examples/specs/abilities.lawspec","examples/specs/failures.lawspec",
        "test/fixtures/migration-chap06-0.24.lawspec"] $ \path -> do
      text<-readFile path
      (program,_)<-checked False 64 text
      made<-either fail pure (transformProgram M.empty Right Right program)
      Binary.encode made `shouldBe` Binary.encode program
  it "matches construction in source order while storage fields use canonical label order" $
    forM_ [32,64] $ \bits -> do
      _<-matched bits (oldType++oldMake) (newType++newMake)
      pure ()
  it "matches nested record destructuring with the original branch bindings" $ do
    (plan,before,after)<-pair 64 (oldType++oldRead) (newType++newRead)
    made<-either fail pure (transportProgram plan before)
    a<-either fail pure (normalizedProgram False False [] made)
    b<-either fail pure (normalizedProgram True False [] after)
    let bodies p=[C.definitionBody definition | unit<-C.programUnits p,definition<-C.unitDefinitions unit]
    bodies a `shouldBe` bodies b
    _<-matched 64 (oldType++oldRead) (newType++newRead)
    pure ()
  it "matches projections through the explicit record payload" $ do
    _<-matched 64 (oldType++"definition read (input :: Capsule) :: Bool is input.last end")
      (newType++"function read (input :: Capsule) -> Bool is input.value.last end function")
    pure ()
  it "matches updates without reversing replacement and subject evaluation" $ do
    _<-matched 64 (oldType++"definition change (input :: Capsule) (replacement :: Bool) :: Capsule is input with last = replacement end")
      (newType++"function change (input :: Capsule) (replacement :: Bool) -> Capsule is Packed (input.value with last = replacement) end function")
    pure ()
  it "detects actual value and field mutants after a valid shape transport" $ do
    forM_ [newMake' | newMake'<-[
      "function make (flag :: Bool) -> Capsule is Packed record{last = not flag, first = false} end function",
      "function make (flag :: Bool) -> Capsule is Packed record{last = false, first = flag} end function"]] $ \changed -> do
      result<-correspondence 64 (oldType++oldMake) (newType++changed)
      field "copyValidated" result `shouldBe` Just (Bool True)
      (field "definitionPlane" result >>= field "status") `shouldBe` Just (String "not-established")
  it "normalizes concrete record instances through checked generic nominal constructors" $ do
    _<-matched 64
      ("type Box (a :: Type) is | Empty | Pair last :: a first :: a end\ndefinition make (flag :: Bool) :: Box Bool is Pair flag false end")
      ("type Box (a :: Type) is one of | Empty | Pair of type record{last :: a first :: a} end type\nfunction make (flag :: Bool) -> Box Bool is Pair record{last = flag, first = false} end function")
    pure ()
  it "retains domain policies even when checked law bodies correspond" $ do
    result<-matched 64 (oldType++oldMake++"law `same` is definition is `for all` (flag :: Bool) . make flag = Packed flag false end end")
      (newType++newMake++"law \"|same| is definition: for all (flag :: Bool) => make flag = Packed record{last = flag, first = false} end end end")
    (field "program" result >>= field "status") `shouldBe` Just (String "not-established")
    (field "domainPolicies" result >>= field "status") `shouldBe` Just (String "not-established")
  it "retains strict once-only construction effects in the existing evaluator" $ do
    let ability="ability Trace is mark :: Bool -> Bool end\n"
        before=oldType++ability++"definition run (unused :: Bool) :: Bool is (Packed (mark true) (mark false)).last end"
        after=newType++ability++"procedure run (unused :: Bool) -> Bool is (Packed record{last = mark true, first = mark false}).value.last end procedure"
    (plan,old,new)<-pair 64 before after
    made<-either fail pure (transportProgram plan old)
    validateProgram made `shouldBe` Right ()
    runObserved old `shouldReturn` ([True,False],Right (ScalarValue (SBool True)))
    runObserved made `shouldReturn` ([True,False],Right (ScalarValue (SBool True)))
    normalized<-either fail pure (normalizedProgram False False [] made)
    runObserved normalized `shouldReturn` ([True,False],Right (ScalarValue (SBool True)))
    runObserved new `shouldReturn` ([True,False],Right (ScalarValue (SBool True)))
  it "keeps an update's effectful replacement before its effectful subject, each once" $ do
    let ability="ability Trace is mark :: Bool -> Bool end\n"
        before=oldType++ability++"definition create (flag :: Bool) :: Capsule is Packed (mark flag) (mark true) end\n"++
          "definition run (flag :: Bool) :: Bool is ((create flag) with last = mark false).last end"
        after=newType++ability++"procedure create (flag :: Bool) -> Capsule is Packed record{last = mark flag, first = mark true} end procedure\n"++
          "procedure run (flag :: Bool) -> Bool is (Packed ((create flag).value with last = mark false)).value.last end procedure"
    (plan,old,new)<-pair 64 before after
    made<-either fail pure (transportProgram plan old)
    normalized<-either fail pure (normalizedProgram False False [] made)
    forM_ [old,made,new,normalized] $ \program -> runObserved program `shouldReturn`
      ([False,True,True],Right (ScalarValue (SBool False)))
  it "cannot hide changed deferred postconditions behind unchanged bodies" $ do
    (plan,old,new)<-pair 64 (oldType++oldMake) (newType++newMake)
    let definition=head [d | u<-C.programUnits new,d<-C.unitDefinitions u]
        identity=C.declarationId (C.definitionDeclaration definition)
        result=C.Binder (C.Id "result") "result" (C.scalarType "transport::type::Capsule")
        truth=C.Expr (C.scalarType "Bool") (C.Constant (SBool False)) (C.GeneratedFrom identity)
        contract=C.Contract identity (C.definitionArguments definition) result [] [] [truth]
        changed=new{C.programUnits=[u{C.unitContracts=contract:C.unitContracts u} | u<-C.programUnits new]}
    compared<-either fail pure (transportComparison plan [] old [] changed)
    (field "definitionPlane" compared >>= field "status") `shouldBe` Just (String "not-established")
  it "refuses key-order correspondence when regrouping permutes constructor fields" $ do
    let before=oldType++"definition order (left :: Capsule) (right :: Capsule) :: Ordering is prelude.compare left right end"
        after=newType++"function order (left :: Capsule) (right :: Capsule) -> Ordering is prelude.compare left right end function"
    (plan,old,_)<-pair 64 before after
    transportProgram plan old `shouldSatisfy` (\value -> case value of Left reason->"legacy-order comparator" `isInfixOf` reason;_->False)

  it "exhibits the key-order counterexample independently of the transport checker" $ do
    let before=oldType++"definition left (unused :: Bool) :: Capsule is Packed false true end\ndefinition right (unused :: Bool) :: Capsule is Packed true false end"
        after=newType++"function left (unused :: Bool) -> Capsule is Packed record{last = false, first = true} end function\nfunction right (unused :: Bool) -> Capsule is Packed record{last = true, first = false} end function"
    (_,old,new)<-pair 64 before after
    let order program=do
          invoke<-either (fail.show) pure (prepareDefinitions program)
          a<-either fail pure (invoke (C.Id "transport::left") [ScalarValue (SBool True)])
          b<-either fail pure (invoke (C.Id "transport::right") [ScalarValue (SBool True)])
          pure (compareValues a b)
    order old `shouldReturn` Right LT
    order new `shouldReturn` Right GT
  it "does not overlook key observers in a replaced constructor's own predicates" $ do
    let before=oldType++"type Labelled is | Wrap original :: (v :: Capsule where prelude.compare v v == Equal) end"
        after=newType++"type Labelled is one of | Wrap of type (v :: Capsule where prelude.compare v v = Equal) end type"
    (plan,old,_)<-pair 64 before after
    transportProgram plan old `shouldSatisfy` (\value -> case value of Left reason->"legacy-order comparator" `isInfixOf` reason;_->False)
  it "keeps recorded values outside executable correspondence until their representation is migrated" $ do
    (plan,old,_)<-pair 64 (oldType++"law `snapshot` is definition is Packed true false = recorded \"shape\" end end")
      (newType++"law \"|snapshot| is definition: Packed record{last = true, first = false} must be recorded \"shape\" end end")
    transportProgram plan old `shouldSatisfy` (\value -> case value of Left reason->"recorded values" `isInfixOf` reason;_->False)
  it "does not equate concurrent construction after adding a payload layer" $ do
    let ability="ability Trace is mark :: Bool -> Bool end\n"
        before=oldType++ability++"definition run (flag :: Bool) :: Capsule is prelude.concurrently (Packed (mark flag) (mark true)) end"
        after=newType++ability++"procedure run (flag :: Bool) -> Capsule is prelude.concurrently (Packed record{last = mark flag, first = mark true}) end procedure"
    (plan,old,_)<-pair 64 before after
    transportProgram plan old `shouldSatisfy` (\value -> case value of Left reason->"scheduling-preserving" `isInfixOf` reason;_->False)
  it "exhibits changed payload visitation with a deliberately deferred postcondition" $ do
    let before="type Box (a :: Type) is | Empty | Payload last :: a first :: a end\ndefinition make (last :: Bool) (first :: Bool) :: Box Bool is Payload last first end"
        after="type Box (a :: Type) is one of | Empty | Payload of type record{last :: a first :: a} end type\nfunction make (last :: Bool) (first :: Bool) -> Box Bool is Payload record{last = last, first = first} end function"
    (plan,old,new)<-pair 64 before after
    let origin=C.GeneratedFrom (C.Id "visitation")
        boolean=C.scalarType "Bool"
        box=C.Constructor "transport::type::Box" [C.TypeArgument boolean]
        argument=C.Binder (C.Id "check::argument") "argument" boolean
        result=C.Binder (C.Id "check::result") "result" boolean
        input=C.Binder (C.Id "all::input") "input" box
        payload=C.Binder (C.Id "all::payload") "payload" boolean
        local binder=C.Expr (C.binderType binder) (C.Local (C.binderId binder)) origin
        check=C.Declaration (C.Id "transport::checked") "checked" (C.Arrow boolean boolean) origin
        allInputs=C.Declaration (C.Id "transport::all") "all" (C.Arrow box boolean) origin
        predicate=C.Expr boolean (C.ExternalCall (C.declarationId check) [local payload]) origin
        post=C.Expr boolean (C.Unary C.Not (local result)) origin
        contract=C.Contract (C.declarationId check) [argument] result [] [] [post]
        add program=program{C.programUnits=C.programUnits program++[
          C.Unit (C.Id "visitation") [check,allInputs] [contract] []
            [C.Definition check [argument] (local argument),
             C.Definition allInputs [input] (C.Expr boolean (C.AllPayloads (local input) [(payload,predicate)]) origin)] []]}
        oldObserved=add old
        newObserved=add new
        invokeAll program=do
          invoke<-either (fail.show) pure (prepareDefinitions program)
          value<-either fail pure (invoke (C.Id "transport::make") [ScalarValue (SBool False),ScalarValue (SBool True)])
          pure (invoke (C.Id "transport::all") [value])
    validateProgram oldObserved `shouldBe` Right ()
    validateProgram newObserved `shouldBe` Right ()
    invokeAll oldObserved `shouldReturn` Right (ScalarValue (SBool False))
    invokeAll newObserved >>= (\value -> value `shouldSatisfy` (\answer -> case answer of Left reason->"postcondition failed" `isInfixOf` reason;_->False))
    transportProgram plan oldObserved `shouldSatisfy` (\value -> case value of Left reason->"field visitation order" `isInfixOf` reason;_->False)

  it "preserves recorded scalar laws through every canonical equality wording" $ do
    let before="definition value (flag :: Bool) :: Bool is flag end\nlaw `snapshot` is definition is value true = recorded \"shape\" end end"
        declaration="function value (flag :: Bool) -> Bool is flag end function\nlaw \"|snapshot| is definition: "
        endings=" end end"
    forM_ ["value true must be", "value true is", "value true =", "value true must =", "must value true ="] $ \wording -> do
      _<-matched 64 before (declaration++wording++" recorded \"shape\""++endings)
      pure ()

  it "retains inconsistent annotations instead of erasing them as strict identity bindings" $ do
    let origin=C.GeneratedFrom (C.Id "identity")
        boolean=C.scalarType "Bool"
        binder=C.Binder (C.Id "identity::local") "local" boolean
        initializer=C.Expr boolean (C.Constant (SBool True)) origin
        wrong=C.Expr (C.scalarType "Integer") (C.Local (C.binderId binder)) origin
        body=C.Expr boolean (C.Let binder initializer wrong) origin
        declaration=C.Declaration (C.Id "identity::value") "value" boolean origin
        program=C.Program 64 [] [C.Unit (C.Id "identity") [declaration] [] [] [C.Definition declaration [] body] []]
    made<-either fail pure (normalizedProgram False False [] program)
    [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits made,definition<-C.unitDefinitions unit]
      `shouldSatisfy` all (\node -> case node of C.Let{}->True;_->False)

  it "checks intrinsic ordered-container types even in declarations with no comparison expression" $ do
    forM_ [("Set Capsule","SortedSet Capsule"),("KeyVal Capsule Bool","KeyVal Capsule Bool")] $ \(beforeType,afterType) -> do
      let before=oldType++"definition keep (input :: "++beforeType++") :: "++beforeType++" is input end"
          after=newType++"function keep (input :: "++afterType++") -> "++afterType++" is input end function"
      (plan,old,_)<-pair 64 before after
      transportProgram plan old `shouldSatisfy` (\value -> case value of Left reason->"intrinsic sortedness" `isInfixOf` reason;_->False)
  it "preserves ordered maps whose changed payloads are values while their keys retain their order" $ do
    _<-matched 64 (oldType++"definition keep (input :: KeyVal Text Capsule) :: KeyVal Text Capsule is input end")
      (newType++"function keep (input :: KeyVal Text Capsule) -> KeyVal Text Capsule is input end function")
    pure ()
