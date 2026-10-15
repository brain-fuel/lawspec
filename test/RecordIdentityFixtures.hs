-- Shared semantic probes for native/WASM parity and native backend execution.
module RecordIdentityFixtures (recordSmokeProgram, recordIdentityProbes) where

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
