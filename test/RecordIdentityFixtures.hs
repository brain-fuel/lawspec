-- Shared semantic probes for native/WASM parity and native backend execution.
module RecordIdentityFixtures (recordSmokeProgram, recordInteroperabilityProgram, recordIdentityProbes) where

import LawSpec.Common (Location(..), InputDomain(..), defaultGeneration, emptyLawMetadata)
import LawSpec.Core
import LawSpec.Core.RecordIdentity
import LawSpec.Scalar

origin :: Origin
origin = GeneratedFrom (Id "records.fixtures")
integerType, boolean :: Type
integerType = scalarType "Integer"
boolean = scalarType "Bool"
field :: String -> Type -> RecordField
field name ty = RecordField (Binder (Id ("field::" ++ name)) name ty) []
make :: [Id] -> [RecordField] -> DataDeclaration
make parameters fields = fst (either error id (makeRecordDeclaration parameters fields origin))
integer :: Integer -> Expr
integer n = Expr integerType (Constant (SInteger "Integer" n)) origin
true :: Expr
true = Expr boolean (Constant (SBool True)) origin
construct :: String -> DataDeclaration -> [Type] -> [(String,Expr)] -> Expr
construct name declaration arguments fields = either error id (constructRecord (Id name) declaration arguments fields origin)
project :: DataDeclaration -> Int -> Type -> Expr -> Expr
project declaration index ty value = Expr ty (Project (constructorId (head (dataConstructors declaration))) index value) origin

recordSmokeProgram :: Int -> Program
recordSmokeProgram bits = Program bits [empty,plain,generic,nested,plain{dataOrigin=GeneratedFrom (Id "another-source")}] [unit]
  where
    empty = make [] []
    plain = make [] [field "ready" boolean,field "count" integerType]
    generic = make [Id "a",Id "b"] [field "value" (TypeVariable (Id "a")),field "flag" (TypeVariable (Id "b"))]
    ty declaration = scalarType (idText (dataId declaration))
    nested = make [] [field "empty" (ty empty),field "child" (ty plain)]
    emptyValue = construct "empty" empty [] []
    plainValue = construct "plain" plain [] [("ready",true),("count",integer 7)]
    genericValue = construct "generic" generic [boolean,integerType] [("value",integer 9),("flag",true)]
    nestedValue = construct "nested" nested [] [("empty",emptyValue),("child",plainValue)]
    properties =
      [ property "count follows its label" (project plain 0 integerType plainValue) (integer 7)
      , property "ready follows its label" (project plain 1 boolean plainValue) true
      , property "generic parameters follow canonical field order" (project generic 1 integerType genericValue) (integer 9)
      , property "nested records preserve their products" (project plain 0 integerType (project nested 0 (ty plain) nestedValue)) (integer 7)
      , property "empty records have one value" emptyValue emptyValue ]
    property name actual expected = Property (Id ("records.fixtures::law::" ++ name)) name (Location "records.fixtures" 1 1)
      [] (Equation (if expressionType actual == integerType then Numeric integerType else Structural (expressionType actual))
        (lowerFieldNodes [empty,plain,generic,nested] ("actual::" ++ name) actual)
        (lowerFieldNodes [empty,plain,generic,nested] ("expected::" ++ name) expected))
      [] defaultGeneration "" "" [] [] [] [] noHarness UniversalDomain emptyLawMetadata
    unit = Unit (Id "records.fixtures") [] [] properties [] []

-- Generic and directly written products cross checked function, contract,
-- nested product and nominal payload boundaries in this program. Its scalar
-- expectations are independent of the normalizer's descriptor calculation.
recordInteroperabilityProgram :: Int -> Program
recordInteroperabilityProgram bits = Program bits [inner,integerInner,outer,integerOuter,envelope,positiveRecord,positiveRecord]
  [Unit (Id "records.interoperability") (map definitionDeclaration definitions) [makeContract] properties definitions []]
  where
    parameter=Id "parameter"
    inner=make [parameter] [field "value" (TypeVariable parameter)]
    integerInner=make [] [field "value" integerType]
    applied d arguments=Constructor (idText (dataId d)) (map TypeArgument arguments)
    innerType=applied inner [integerType]
    concreteInner=applied integerInner []
    outer=make [parameter] [field "inner" (applied inner [TypeVariable parameter]),field "flag" boolean]
    integerOuter=make [] [field "inner" concreteInner,field "flag" boolean]
    outerType=applied outer [integerType]
    concreteOuter=applied integerOuter []
    envelopeType=scalarType "records.interoperability::type::Envelope"
    envelopeConstructor=Id "records.interoperability::type::Envelope::Envelope"
    envelope=DataDeclaration (Id "records.interoperability::type::Envelope") "Envelope" []
      [DataConstructor envelopeConstructor "Envelope" [Binder (Id "envelope.payload") "payload" outerType] [] origin [] []] origin Nothing
    positiveField=field "amount" integerType
    positiveRecord=make [] [positiveField{recordFieldPredicates=[Expr boolean
      (Binary Greater (Numeric integerType) (local (recordFieldBinder positiveField)) (integer 0)) origin]}]
    positiveValue=construct "interoperability.positive" positiveRecord [] [("amount",integer 2)]
    float=scalarType "Float64"
    floatRecordType=applied inner [float]
    floatRecord prefix bits=construct prefix inner [float]
      [("value",Expr float (Constant (SFloat "Float64" bits)) origin)]
    nanValue=floatRecord "interoperability.nan" "7ff8000000000001"
    positiveZero=floatRecord "interoperability.positiveZero" "0000000000000000"
    negativeZero=floatRecord "interoperability.negativeZero" "8000000000000000"
    finiteValue=floatRecord "interoperability.finite" "3ff4000000000000"
    floatEqual a b=Expr boolean (Binary Equal (Structural floatRecordType) a b) origin
    local b=Expr (binderType b) (Local (binderId b)) origin
    identity name=Id ("records.interoperability::"++name)
    call name wanted arguments=Expr wanted (ExternalCall (identity name) arguments) origin
    define name input output body=
      let argument=Binder (Id (idText (identity name)++"::input::0")) "value" input
      in Definition (Declaration (identity name) name (Arrow input output) origin) [argument] (body argument)
    makeInner=define "makeInner" integerType innerType $ \b -> construct "interoperability.makeInner" inner [integerType] [("value",local b)]
    readInner=define "readInner" concreteInner integerType $ \b -> project integerInner 0 integerType (local b)
    makeOuter=define "makeOuter" integerType outerType $ \b -> construct "interoperability.makeOuter" outer [integerType]
      [("inner",call "makeInner" innerType [local b]),("flag",true)]
    readOuter=define "readOuter" concreteOuter integerType $ \b ->
      project integerInner 0 integerType (project integerOuter 1 concreteInner (local b))
    pack=define "pack" integerType envelopeType $ \b -> Expr envelopeType
      (Construct envelopeConstructor [call "makeOuter" outerType [local b]]) origin
    unpack=define "unpack" envelopeType integerType $ \b -> call "readOuter" integerType
      [Expr outerType (Project envelopeConstructor 0 (local b)) origin]
    replaceValue=define "replaceValue" innerType innerType $ \b -> Expr innerType
      (Update (constructorId (head (dataConstructors inner))) 0 (local b) (integer 5)) origin
    definitions=[makeInner,readInner,makeOuter,readOuter,pack,unpack,replaceValue]
    argument=head (definitionArguments makeInner)
    result=Binder (Id "records.interoperability::contract::result") "result" innerType
    makeContract=Contract (identity "makeInner") [argument] result []
      [Expr boolean (Binary Equal (Numeric integerType) (project inner 0 integerType (local result)) (local argument)) origin] []
    concrete n=construct "interoperability.concrete" integerOuter []
      [("flag",true),("inner",construct "interoperability.concrete.inner" integerInner [] [("value",integer n)])]
    tag=head (dataConstructors inner)
    matched=let b=Binder (Id "records.interoperability::match::value") "value" integerType
      in Expr integerType (Match (call "makeInner" innerType [integer 7])
        [MatchCase (constructorId tag) [b] (local b)]) origin
    updated=call "replaceValue" innerType [call "makeInner" innerType [integer 4]]
    properties=
      [ property "generic inputs meet concrete function parameters" (call "readInner" integerType [call "makeInner" innerType [integer 7]]) (integer 7)
      , property "nested generic inputs meet concrete parameters" (call "readOuter" integerType [call "makeOuter" outerType [integer 9]]) (integer 9)
      , property "generic and concrete products compare" (call "makeOuter" outerType [integer 3]) (concrete 3)
      , property "nominal payloads retain their product semantics" (call "unpack" integerType [call "pack" envelopeType [integer 11]]) (integer 11)
      , property "patterns follow the instantiated constructor" matched (integer 7)
      , property "updates follow the instantiated constructor" (call "readInner" integerType [updated]) (integer 5)
      , property "shared refined products retain their constructor checks" positiveValue positiveValue
      , property "NaN fields retain nonreflexive equality" (floatEqual nanValue nanValue) (Expr boolean (Constant (SBool False)) origin)
      , property "signed zero fields retain IEEE equality" (floatEqual negativeZero positiveZero) true
      , property "finite float fields retain reflexive equality" (floatEqual finiteValue finiteValue) true ]
    property name actual expected=Property (Id ("records.interoperability::law::"++name)) name (Location "records.interoperability" 1 1)
      [] (Equation (if expressionType actual==integerType then Numeric integerType else Structural (expressionType actual)) actual expected)
      [] defaultGeneration "" "" [] [] [] [] noHarness UniversalDomain emptyLawMetadata

recordIdentityProbes :: [(String,RecordDescription)]
recordIdentityProbes =
  [ probe "empty" [] []
  , probe "field-order-one" [] [field "ready" boolean,field "count" integerType]
  , probe "field-order-two" [] [field "count" integerType,field "ready" boolean]
  , probe "parameters-one" [Id "a",Id "b"] [field "y" (TypeVariable (Id "b")),field "x" (TypeVariable (Id "a"))]
  , probe "parameters-two" [Id "beta",Id "alpha"] [field "x" (TypeVariable (Id "alpha")),field "y" (TypeVariable (Id "beta"))]
  , probe "nominal-reference" [] [field "amount" (scalarType "shop::type::Money")]
  ] ++ [probe name [] [(field "value" integerType){recordFieldPredicates=[condition scalar]}] | (name,scalar) <- scalars]
  where
    probe name parameters fields = (name,either error id (describeRecord parameters fields))
    condition scalar = let ty=scalarType (scalarName scalar); value=Expr ty (Constant scalar) origin
      in Expr boolean (Binary Equal (if isNumeric (scalarName scalar) then Numeric ty else Structural ty) value value) origin
    scalars =
      [ ("huge-integer",SInteger "Integer" (10^300))
      , ("decimal-one",SDecimal 100 (-2)),("decimal-two",SDecimal 1 0)
      , ("rational-one",SRational (-2) (-4)),("rational-two",SRational 1 2)
      , ("positive-zero",SFloat "Float64" "0000000000000000"),("negative-zero",SFloat "Float64" "8000000000000000")
      , ("nan-payload-one",SFloat "Float64" "7FF8000000000001"),("nan-payload-two",SFloat "Float64" "7ff8000000000002")
      , ("complex",SComplex "Complex128" (SFloat "Float64" "0000000000000000") (SFloat "Float64" "8000000000000000"))
      , ("boolean",SBool True),("bytes",SSequence "Bytes" [0,255]),("utf16",SSequence "Utf16Text" [55296,0,65535])
      , ("code-point",SCharacter "CodePoint" 128512),("symbol",SSymbol "α" "business amount")
      , ("unit",SAbsent "Unit"),("absent",SPresent "Optional" Nothing)
      , ("present",SPresent "Optional" (Just (SBool True))) ]
