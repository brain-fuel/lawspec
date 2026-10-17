module MigrationSnapshotSpec (test_migrationSnapshot) where

import Test.Hspec
import Data.Aeson (Value(..),object,(.=),encode,eitherDecode)
import qualified Data.Aeson.KeyMap as KM
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (migrationSnapshot,normalizedProgram)
import LawSpec.Frontend (compileCore,compileCoreCanonical)
import LawSpec.Model (Source(..),defaultGeneration)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Api (dispatch)

checked canonical text = either (fail . show) pure $
  (if canonical then compileCoreCanonical else compileCore) 64 defaultGeneration [Source "migration.lawspec" ("unit migration\n" ++ text)]
snapshot canonical program = either fail pure (migrationSnapshot canonical [] program)
field name (Object value) = KM.lookup name value
field _ _ = Nothing
origin = C.GeneratedFrom (C.Id "example")
boolean value = C.Expr (C.scalarType "Bool") (C.Constant (SBool value)) origin
integer value = C.Expr (C.scalarType "Integer") (C.Constant (SInteger "Integer" value)) origin
local binder = C.Expr (C.binderType binder) (C.Local (C.binderId binder)) origin
synthetic expression = C.Program 64 [] [C.Unit (C.Id "migration") [declaration] [] []
  [C.Definition declaration [] expression] []]
  where declaration=C.Declaration (C.Id "migration::value") "value" (C.expressionType expression) origin
response fields = either fail pure (eitherDecode (dispatch (encode (object fields))) :: Either String Value)
canonicalFields text=["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
  "verification" .= object ["layers" .= ([]::[String])],
  "sources" .= [Source "wire.lawspec" ("unit wire\n" ++ text)]]

test_migrationSnapshot = describe "full Core migration comparison snapshots" $ do
  it "matches checked computation syntax without weakening law policy" $ do
    before <- checked False "definition double (value :: Integer) :: Integer is value + value end"
    after <- checked True "function double (value :: Integer) -> Integer is value + value end function"
    snapshot False before >>= \old -> snapshot True after >>= \new -> old `shouldBe` new
  it "compares ordered cases and explicit nominal record construction through strict single-use lets" $ do
    before <- checked False ("type Pair is Pair first :: Bool second :: Bool end\n" ++
      "definition make (value :: Bool) :: Pair is Pair value false end\n" ++
      "definition first (value :: Pair) :: Bool is match value with | Pair first second -> first end end")
    after <- checked True ("type Pair is a record{first :: Bool second :: Bool} end type\n" ++
      "function make (value :: Bool) -> Pair is Pair record{first = value, second = false} end function\n" ++
      "function first (value :: Pair) -> Bool is first matching case of value: when Pair record{first = first, second = second} then first end case end function")
    old <- snapshot False before
    new <- snapshot True after
    field "programDigest" new `shouldBe` field "programDigest" old
  it "keeps universal and nonempty domains distinct even when their law bodies match" $ do
    before <- checked False "law `same` is definition is `for all` (value :: Bool) . value = value end end"
    after <- checked True "law \"|same| is definition: for all (value :: Bool) => value = value end end end"
    old <- snapshot False before
    new <- snapshot True after
    field "definitionPlaneDigest" new `shouldBe` field "definitionPlaneDigest" old
    field "lawBodiesDigest" new `shouldBe` field "lawBodiesDigest" old
    field "programDigest" new `shouldNotBe` field "programDigest" old
    field "domainPolicies" new `shouldNotBe` field "domainPolicies" old
  it "detects a changed checked function body rather than treating compilation as correspondence" $ do
    before <- checked False "definition double (value :: Integer) :: Integer is value + value end"
    after <- checked True "function double (value :: Integer) -> Integer is value + 1 end function"
    old <- snapshot False before
    new <- snapshot True after
    field "definitionPlaneDigest" new `shouldNotBe` field "definitionPlaneDigest" old
  it "includes nominal constructor restrictions omitted by the documentary type view" $ do
    before <- checked False "type Pair is Pair first :: UInt8 second :: (value :: UInt8 where value >= first) end"
    after <- checked False "type Pair is Pair first :: UInt8 second :: (value :: UInt8 where value > first) end"
    old <- snapshot False before
    new <- snapshot False after
    field "definitionPlaneDigest" new `shouldNotBe` field "definitionPlaneDigest" old
  it "includes GADT equations even when constructor field types and names are unchanged" $ do
    before <- checked False "type Term (a :: Type) is | Number value :: Integer where a = Integer end"
    after <- checked False "type Term (a :: Type) is | Number value :: Integer where a = Bool end"
    old <- snapshot False before
    new <- snapshot False after
    field "definitionPlaneDigest" new `shouldNotBe` field "definitionPlaneDigest" old
  it "retains orchestration and policy metadata beyond a definition's body" $ do
    program <- checked False "definition same (value :: Bool) :: Bool is value end"
    let altered=program{C.programUnits=[unit{C.unitDefinitions=
          [definition{C.definitionOrchestrates=True} | definition<-C.unitDefinitions unit]} | unit<-C.programUnits program]}
    old <- snapshot False program
    new <- snapshot False altered
    field "definitionPlaneDigest" new `shouldNotBe` field "definitionPlaneDigest" old
  it "does not erase an initializer with a repeated or unused binding" $ do
    let binder=C.Binder (C.Id "original") "value" (C.scalarType "Integer")
        value=integer 3
        duplicate=C.Expr (C.Constructor "Pair" []) (C.Construct (C.Id "Pair::Pair") [local binder,local binder]) origin
        repeated=C.Expr (C.expressionType duplicate) (C.Let binder value duplicate) origin
    normalized <- either fail pure (normalizedProgram False False [] (synthetic repeated))
    let nodes=[C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
    nodes `shouldSatisfy` all (\node -> case node of C.Let{} -> True; _ -> False)
  it "does not reorder strict field initialization or erase dependent uses" $ do
    let a=C.Binder (C.Id "a") "first" (C.scalarType "Integer")
        b=C.Binder (C.Id "b") "second" (C.scalarType "Integer")
        constructor args=C.Expr (C.Constructor "Pair" []) (C.Construct (C.Id "Pair::Pair") args) origin
        reordered=C.Expr (C.Constructor "Pair" []) (C.Let a (integer 1)
          (C.Expr (C.Constructor "Pair" []) (C.Let b (integer 2) (constructor [local b,local a])) origin)) origin
        dependent=C.Expr (C.Constructor "Pair" []) (C.Let a (integer 1)
          (C.Expr (C.Constructor "Pair" []) (C.Let b (local a) (constructor [local a,local b])) origin)) origin
    mapM_ (\expression -> do
      normalized <- either fail pure (normalizedProgram False False [] (synthetic expression))
      [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
        `shouldSatisfy` all (\node -> case node of C.Let{} -> True; _ -> False)) [reordered,dependent]
  it "cancels a unary product projection while retaining its effectful payload exactly once" $ do
    let tag=C.Id "Box::Box"
        ty=C.Constructor "Box" []
        binder=C.Binder (C.Id "field") "value" (C.scalarType "Bool")
        constructor=C.DataConstructor tag "Box" [binder] [] origin [] []
        declaration=C.DataDeclaration (C.Id "Box") "Box" [] [constructor] origin Nothing
        payload=C.Expr (C.scalarType "Bool") (C.ExternalCall (C.Id "effect") []) origin
        value=C.Expr ty (C.Construct tag [payload]) origin
        expression=C.Expr (C.scalarType "Bool") (C.Project tag 0 value) origin
    normalized <- either fail pure (normalizedProgram False False [] (synthetic expression){C.programDataDeclarations=[declaration]})
    [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
      `shouldBe` [C.ExternalCall (C.Id "effect") []]
  it "never cancels a product projection that would discard another field's evaluation" $ do
    let tag=C.Id "Pair::Pair"
        ty=C.Constructor "Pair" []
        fields=[C.Binder (C.Id name) name (C.scalarType "Bool") | name<-["first","second"]]
        constructor=C.DataConstructor tag "Pair" fields [] origin [] []
        declaration=C.DataDeclaration (C.Id "Pair") "Pair" [] [constructor] origin Nothing
        effect=C.Expr (C.scalarType "Bool") (C.ExternalCall (C.Id "effect") []) origin
        value=C.Expr ty (C.Construct tag [boolean True,effect]) origin
        expression=C.Expr (C.scalarType "Bool") (C.Project tag 0 value) origin
    normalized <- either fail pure (normalizedProgram False False [] (synthetic expression){C.programDataDeclarations=[declaration]})
    [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
      `shouldSatisfy` all (\node -> case node of C.Project{}->True;_->False)
  it "does not turn a non-product case into an unchecked projection" $ do
    let tag=C.Id "Choice::One"
        ty=C.Constructor "Choice" []
        binder=C.Binder (C.Id "field") "value" (C.scalarType "Bool")
        constructors=[C.DataConstructor tag "One" [binder] [] origin [] [],
          C.DataConstructor (C.Id "Choice::None") "None" [] [] origin [] []]
        declaration=C.DataDeclaration (C.Id "Choice") "Choice" [] constructors origin Nothing
        selected=C.Expr ty (C.ExternalCall (C.Id "choose") []) origin
        expression=C.Expr (C.scalarType "Bool") (C.Match selected [C.MatchCase tag [binder] (local binder)]) origin
    normalized <- either fail pure (normalizedProgram False False [] (synthetic expression){C.programDataDeclarations=[declaration]})
    [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
      `shouldSatisfy` all (\node -> case node of C.Match{}->True;_->False)
  it "retains opaque symbol identity strings that resemble a renamed law" $ do
    let value=C.Expr (C.scalarType "Symbol") (C.Constant (SSymbol "migration::law::\"|same|" "label")) origin
    normalized <- either fail pure (normalizedProgram True False [(C.Id "migration::law::\"|same|","\"|same|")] (synthetic value))
    [C.expressionNode (C.definitionBody definition) | unit<-C.programUnits normalized,definition<-C.unitDefinitions unit]
      `shouldBe` [C.Constant (SSymbol "migration::law::\"|same|" "label")]
  it "refuses ambiguous normalization between distinct authored law identities" $ do
    let result=normalizedProgram True False
          [(C.Id "migration::law::same","same"),(C.Id "migration::law::\"|same|","\"|same|")]
          (synthetic (boolean True))
    result `shouldBe` Left "migration normalization collides law identities"
  it "does not derive model identities by slicing unrelated display names" $ do
    program <- checked False "law `same` is definition is true end end"
    let identity=C.Id "migration::model::state::step0"
        modified=program{C.programUnits=[unit{C.unitProperties=
          [property{C.propertyId=identity,C.propertyName="an unrelated generated display label"} | property<-C.unitProperties unit]}
            | unit<-C.programUnits program]}
    normalized <- either fail pure (normalizedProgram True False [] modified)
    [C.propertyId property | unit<-C.programUnits normalized,property<-C.unitProperties unit] `shouldBe` [identity]
  it "retains the deferred runtime-postcondition enforcement plane" $ do
    program <- checked False "definition same (value :: Bool) :: Bool is value end"
    let identity=C.Id "migration::same"
        binder=C.Binder (C.Id "argument") "value" (C.scalarType "Bool")
        result=C.Binder (C.Id "result") "result" (C.scalarType "Bool")
        contract=C.Contract identity [binder] result [] [] [boolean True]
        withPost value=program{C.programUnits=[unit{C.unitContracts=[contract{C.contractRuntimePostconditions=[boolean value]}]} | unit<-C.programUnits program]}
    old <- snapshot False (withPost True)
    new <- snapshot False (withPost False)
    field "definitionPlaneDigest" new `shouldNotBe` field "definitionPlaneDigest" old
  it "publishes snapshots only for explicit schema-5 canonical requests and migration baselines" $ do
    let request=canonicalFields "function same (value :: Bool) -> Bool is value end function"
    ordinary <- response request
    field "diagnostics" ordinary `shouldBe` Just (Array mempty)
    field "migrationSemantics" ordinary `shouldBe` Nothing
    requested <- response (("migrationSnapshot" .= True):request)
    field "diagnostics" requested `shouldBe` Just (Array mempty)
    (field "migrationSemantics" requested >>= field "status") `shouldBe` Just (String "available")
    repeated <- response request
    repeated `shouldBe` ordinary
    let legacy=Source "wire.lawspec" "unit wire\ndefinition same (value :: Bool) :: Bool is value end"
    baseline <- response ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
      "method" .= ("migrationBaseline"::String),"from" .= ("0.24"::String),"sources" .= [legacy]]
    (field "migrationSemantics" baseline >>= field "status") `shouldBe` Just (String "available")
    (field "migrationSemantics" baseline >>= field "programDigest")
      `shouldBe` (field "migrationSemantics" requested >>= field "programDigest")
  it "rejects invalid snapshot switches without bypassing canonical syntax or intrinsic validation" $ do
    mapM_ (\version -> do
      result <- response ["schemaVersion" .= (version::Int),"migrationSnapshot" .= True,"sources" .= ([]::[Source])]
      field "diagnostics" result `shouldNotBe` Just (Array mempty)) [3,4]
    malformed <- response (("migrationSnapshot" .= ("yes"::String)):canonicalFields "")
    field "diagnostics" malformed `shouldNotBe` Just (Array mempty)
    invalid <- response (("migrationSnapshot" .= True):canonicalFields "function invalid (value :: Integer) -> Integer is 1 / value end function")
    field "diagnostics" invalid `shouldNotBe` Just (Array mempty)
    field "migrationSemantics" invalid `shouldBe` Nothing
