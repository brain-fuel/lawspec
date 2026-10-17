module MigrationPayloadSpec (test_migrationPayloads) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as Vector
import LawSpec.Api (dispatch)
import LawSpec.Model (Source(..))
import Test.Hspec

field key (Object value)=KM.lookup key value
field _ _=Nothing
rows key value=case field key value of Just (Array values)->Vector.toList values;_->[]
source body=[Source "payloads.lawspec" ("unit payloads\n"++body)]
options=["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
  "verification" .= object ["layers" .= ([]::[String])]]
request before after=object (options++["method" .= ("migrationComparison"::String),"from" .= ("0.24"::String),
  "sources" .= source before,"migrated" .= object (options++["sources" .= source after])])
response value=either fail pure (eitherDecode (dispatch (encode value)) :: Either String Value)
replace key value (Object fields)=Object (KM.insert key value fields)
replace _ _ value=value
comparison value=field "migrationComparison" value
shape value=comparison value >>= field "payloadShapes"
accepted before after=do
  result<-response (request before after)
  field "diagnostics" result `shouldBe` Just (Array mempty)
  (comparison result >>= field "status") `shouldBe` Just (String "not-established")
  pure result
shapesMatch before after=do
  result<-accepted before after
  (shape result >>= field "status") `shouldBe` Just (String "matched")
  pure result
singleOld="type Variant is | Empty | Item flag :: Bool end"
singleNew="type Variant is one of | Empty | Item of type Bool end type"
groupOld="type Variant is | Empty | Item last :: Bool first :: UInt8 end"
groupNew="type Variant is one of | Empty | Item of type record{last :: Bool first :: UInt8} end type"

test_migrationPayloads=describe "checked constructor payload shape correspondence" $ do
  it "retains indexed and GADT equations when renaming one payload formal" $ do
    mapM_ (\(before,after) -> do
      result<-shapesMatch before after
      (comparison result >>= field "executableTransport" >>= field "status") `shouldBe` Just (String "matched")
      (comparison result >>= field "executableTransport" >>= field "copyValidated") `shouldBe` Just (Bool True))
      [("type Expr (a :: Type) is | Truth flag :: Bool where a = Bool end",
        "type Expr (a :: Type) is one of | Truth of type Bool where a = Bool end type"),
       ("type Chain (n :: Natural) is | Stop where n = 0 | Next link :: Chain m where n = m + 1 end",
        "type Chain (n :: Whole) is one of | Stop where n = 0 | Next of type Chain m where n = m + 1 end type"),
       ("type Box (a :: Type) is Box held :: Bool where a = Bool end",
        "type Box (a :: Type) is one of Box of type Bool where a = Bool end type"),
       ("type Shown is Shown held :: a end",
        "type Shown is one of Shown of type a end type")]
  it "compares unused generic law parameters without choosing implementations" $ do
    result<-shapesMatch "law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end"
      "law \"|same| (operation :: a -> a) requires Eq a is definition: for all (value :: a) => operation value must be value end end end"
    let evidence=comparison result >>= field "lawTemplates"
    (evidence >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "lawBodiesEvaluated") `shouldBe` Just (Bool False)
    (evidence >>= field "typedCore" >>= field "copyValidated") `shouldBe` Just (Bool True)
    (evidence >>= field "typedCore" >>= field "program" >>= field "status") `shouldBe` Just (String "not-established")
  it "retains changed reusable law bodies and metadata independently of concrete instances" $ do
    let before="law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end"
    result<-shapesMatch before
      "law \"|same| (operation :: a -> a) requires Eq a is definition: for all (value :: a) => value must be value end end end"
    (comparison result >>= field "lawTemplates" >>= field "status") `shouldBe` Just (String "not-established")
    description<-shapesMatch before
      "law \"|same| (operation :: a -> a) requires Eq a is description: \"Changed requirement\" end definition: for all (value :: a) => operation value must be value end end end"
    (comparison description >>= field "lawTemplates" >>= field "metadata" >>= field "status") `shouldBe` Just (String "not-established")
  it "keeps Eq-only law-template membership independent from portable ordering" $ do
    result<-shapesMatch "law `member` (needle :: a) requires Eq a is definition is `for all` (items :: List a) . (items contains needle) = (items contains needle) end end"
      "law \"|member| (needle :: a) requires Eq a is definition: for all (items :: List a) => (items contains needle) must be (items contains needle) end end end"
    (comparison result >>= field "lawTemplates" >>= field "status") `shouldBe` Just (String "matched")
  it "compares the full unused generic definition plane without choosing an instantiation" $ do
    let before="type Capsule (a :: Type) is | Packed last :: Bool first :: a end\n"++
          "definition read (input :: Capsule a) :: a is match input with | Packed last first -> first end end"
        after="type Capsule (a :: Type) is one of | Packed of type record{last :: Bool first :: a} end type\n"++
          "function read (input :: Capsule a) -> a is first matching case of input: when Packed record{last = last, first = first} then first end case end function"
    result<-shapesMatch before after
    let evidence=comparison result >>= field "definitionTemplates"
    (evidence >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "typeVariables") `shouldBe` Just (String "symbolic; no sample instantiations")
    (evidence >>= field "interfaces" >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "typedCore" >>= field "copyValidated") `shouldBe` Just (Bool True)
  it "keeps unused generic behavior mutants visible after payload regrouping" $ do
    let before="type Capsule (a :: Type) is | Packed first :: a second :: a end\n"++
          "definition pick (input :: Capsule a) :: a is match input with | Packed first second -> first end end"
        after="type Capsule (a :: Type) is one of | Packed of type record{first :: a second :: a} end type\n"++
          "function pick (input :: Capsule a) -> a is input.value.second end function"
    result<-shapesMatch before after
    let evidence=comparison result >>= field "definitionTemplates"
    (evidence >>= field "interfaces" >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "status") `shouldBe` Just (String "not-established")
    (evidence >>= field "typedCore" >>= field "definitionPlane" >>= field "status") `shouldBe` Just (String "not-established")
  it "retains unused capability requirements beside a matching symbolic Core" $ do
    result<-shapesMatch "definition same (value :: a) :: a requires Eq a is value end"
      "function same (value :: a) -> a requires Keyed a is value end function"
    let evidence=comparison result >>= field "definitionTemplates"
    (evidence >>= field "typedCore" >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "interfaces" >>= field "status") `shouldBe` Just (String "not-established")
    (evidence >>= field "status") `shouldBe` Just (String "not-established")
  it "compares transitive generic dependencies even when concrete Core has no instantiations" $ do
    let before="definition helper (left :: a) (right :: a) :: a is left end\n"++
          "definition choose (left :: a) (right :: a) :: a is helper left right end"
        after="function helper (left :: a) (right :: a) -> a is right end function\n"++
          "function choose (left :: a) (right :: a) -> a is helper left right end function"
    result<-shapesMatch before after
    let evidence=comparison result >>= field "definitionTemplates"
    (evidence >>= field "status") `shouldBe` Just (String "not-established")
    (evidence >>= field "typedCore" >>= field "copyValidated") `shouldBe` Just (Bool True)
    (comparison result >>= field "executableTransport" >>= field "status") `shouldBe` Just (String "matched")
  it "retains the declared Eq scope while comparing a generic equality definition" $ do
    result<-shapesMatch "definition same (left :: a) (right :: a) :: Bool requires Eq a is left == right end"
      "function same (left :: a) (right :: a) -> Bool requires Eq a is left = right end function"
    let evidence=comparison result >>= field "definitionTemplates"
    (evidence >>= field "status") `shouldBe` Just (String "matched")
    (evidence >>= field "typedCore" >>= field "copyValidated") `shouldBe` Just (Bool True)
  it "checks single-payload field renaming while keeping native correspondence separate" $ do
    result<-shapesMatch singleOld singleNew
    (comparison result >>= field "validated") `shouldBe` Just (Bool False)
    (comparison result >>= field "lawVerification") `shouldBe` Just (String "not-established-by-payload-shapes")
    mapM_ (\key -> (comparison result >>= field key >>= field "status") `shouldBe` Just (String "not-established"))
      ["dependencyBehavior","nativeBindings"]
  it "derives the complete grouped descriptor and records the field permutation" $ do
    result<-shapesMatch groupOld groupNew
    let changes=maybe [] (rows "changes") (shape result)
        constructors=concatMap (rows "constructors") changes
        fields=concatMap (rows "fields") constructors
    map (field "fromIndex") fields `shouldBe` [Just (Number 0),Just (Number 1)]
    map (field "toIndex") fields `shouldBe` [Just (Number 1),Just (Number 0)]
    (shape result >>= field "introducedRecords") `shouldSatisfy` (\value -> case value of Just (Array xs)->Vector.length xs==1;_->False)
  it "checks unused generic payloads and retains repeated parameter relationships" $ do
    _<-shapesMatch "type Variant (a :: Type) is | Empty | Item first :: a second :: a end"
      "type Variant (a :: Type) is one of | Empty | Item of type record{first :: a second :: a} end type"
    result<-accepted "type Variant (a :: Type) (b :: Type) is | Empty | Item first :: a second :: a end"
      "type Variant (a :: Type) (b :: Type) is one of | Empty | Item of type record{first :: a second :: b} end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "preserves dependent restrictions and their original field association" $ do
    _<-shapesMatch "type Variant is | Empty | Item first :: UInt8 second :: (n :: UInt8 where n >= first) end"
      "type Variant is one of | Empty | Item of type record{first :: UInt8 second :: (n :: UInt8 where n >= first)} end type"
    result<-accepted "type Variant is | Empty | Item first :: UInt8 second :: (n :: UInt8 where n >= first) end"
      "type Variant is one of | Empty | Item of type record{first :: UInt8 second :: (n :: UInt8 where n > first)} end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "retains a single payload's intrinsic restriction" $ do
    _<-shapesMatch "type Variant is | Empty | Item amount :: (n :: UInt8 where n > 0) end"
      "type Variant is one of | Empty | Item of type (n :: UInt8 where n > 0) end type"
    result<-accepted "type Variant is | Empty | Item amount :: (n :: UInt8 where n > 0) end"
      "type Variant is one of | Empty | Item of type UInt8 end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "preserves nominal record fields without introducing an anonymous wrapper" $ do
    _<-shapesMatch "type Pair is Pair first :: Bool second :: Bool end"
      "type Pair is a record{first :: Bool second :: Bool} end type"
    result<-accepted "type Pair is Pair first :: Bool second :: Bool end"
      "type Pair is a record{first :: Bool second :: UInt8} end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "rejects renamed labels, extra fields, changed types and constructor identities" $ do
    mapM_ (\after -> do
      result<-accepted groupOld after
      (shape result >>= field "status") `shouldBe` Just (String "not-established"))
      ["type Variant is one of | Empty | Item of type record{renamed :: Bool first :: UInt8} end type",
       "type Variant is one of | Empty | Item of type record{last :: Bool first :: UInt8 extra :: Bool} end type",
       "type Variant is one of | Empty | Item of type record{last :: Bool first :: UInt16} end type",
       "type Variant is one of | Empty | Renamed of type record{last :: Bool first :: UInt8} end type"]
  it "does not unwrap nominal types with identical fields" $ do
    result<-accepted groupOld
      "type Payload is a record{last :: Bool first :: UInt8} end type\ntype Variant is one of | Empty | Item of type Payload end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "keeps removed and unrelated added types visible" $ do
    removed<-accepted groupOld ""
    added<-accepted singleOld (singleNew++"\ntype Extra is one of | Extra end type")
    mapM_ (\result -> (shape result >>= field "status") `shouldBe` Just (String "not-established")) [removed,added]
  it "keeps changed GADT equations unestablished" $ do
    result<-accepted "type Term (a :: Type) is | Number value :: Integer where a = Integer end"
      "type Term (a :: Type) is one of | Number of type Integer where a = Bool end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
  it "validates both inputs intrinsically even with all law checks unselected" $ do
    mapM_ (\value -> do
      result<-response value
      field "diagnostics" result `shouldNotBe` Just (Array mempty)
      comparison result `shouldBe` Nothing)
      [request (singleOld++"\ndefinition unsafe (n :: Integer) :: Integer is 1 / n end") singleNew,
       request singleOld (singleNew++"\nfunction unsafe (n :: Integer) -> Integer is 1 / n end function")]
  it "detects changed inlined predicate calls and keeps dependency behavior separate" $ do
    result<-accepted
      "definition allowed (n :: UInt8) :: Bool is n > 0 end\ntype Variant is | Empty | Item amount :: (n :: UInt8 where allowed n) end"
      "function allowed (n :: UInt8) -> Bool is n > 1 end function\ntype Variant is one of | Empty | Item of type (n :: UInt8 where allowed n) end type"
    (shape result >>= field "status") `shouldBe` Just (String "not-established")
    (comparison result >>= field "dependencyBehavior" >>= field "status") `shouldBe` Just (String "not-established")
  it "requires explicit migration entry, schema, profile and equal widths" $ do
    let base=request singleOld singleNew
        nested=object (options++["sources" .= source singleNew])
    mapM_ (\value -> do
      result<-response value
      field "diagnostics" result `shouldNotBe` Just (Array mempty)
      comparison result `shouldBe` Nothing)
      [replace "from" (String "0.23") base,replace "schemaVersion" (Number 4) base,
       replace "migrated" (replace "schemaVersion" (Number 4) nested) base,
       replace "migrated" (object ["sources" .= source singleNew]) base,
       replace "migrated" (replace "machineBits" (Number 32) nested) base]
  it "validates each independently supplied native binding request" $ do
    let base=request singleOld singleNew
        native=object ["types" .= [object ["type" .= ("missing::Type"::String),"native" .= ["Missing"::String]]]]
        nested=object (options++["sources" .= source singleNew])
    mapM_ (\value -> do
      result<-response value
      field "diagnostics" result `shouldNotBe` Just (Array mempty)
      comparison result `shouldBe` Nothing)
      [replace "nativeBindings" native base,replace "migrated" (replace "nativeBindings" native nested) base]
  it "rejects optional law-check selections on either input rather than silently dropping them" $ do
    let selected=object ["layers" .= ["examples"::String]]
        base=request singleOld singleNew
        nested=object (options++["sources" .= source singleNew])
    mapM_ (\value -> do
      result<-response value
      field "diagnostics" result `shouldNotBe` Just (Array mempty))
      [replace "verification" selected base,replace "migrated" (replace "verification" selected nested) base]
  it "does not populate ordinary check responses or relax the canonical grammar" $ do
    ordinary<-response (object (options++["sources" .= source singleNew]))
    field "diagnostics" ordinary `shouldBe` Just (Array mempty)
    comparison ordinary `shouldBe` Nothing
    invalid<-response (request singleOld singleOld)
    field "diagnostics" invalid `shouldNotBe` Just (Array mempty)
    field "migrationComparisonInput" invalid `shouldBe` Just (String "migrated")
