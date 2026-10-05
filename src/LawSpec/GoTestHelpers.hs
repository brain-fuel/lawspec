-- Framework-specific generator documents, downstream of checked Core.
module LawSpec.GoTestHelpers (generatorDoc, generatorDocWithin, assertionDoc, dataHelpersDoc) where

import LawSpec.Core (Type(..), Argument(..), scalarType)
import LawSpec.Scalar
import qualified LawSpec.GoData as Native
import qualified LawSpec.GoExpr as E
import qualified LawSpec.Code.Doc as D

line :: String -> D.Doc
line = D.text
statements :: [D.Doc] -> D.Doc
statements = D.joinWith D.hardline
block :: D.Doc -> D.Doc
block = D.block 8
call :: String -> [D.Doc] -> D.Doc
call = E.call
quoted :: String -> D.Doc
quoted = E.quoted
value :: String -> D.Doc
value = line
returned :: D.Doc -> D.Doc
returned expression = line "return " <> expression
bind :: String -> D.Doc -> D.Doc
bind name expression = line (name ++ " := ") <> expression
custom :: [D.Doc] -> D.Doc
custom body = call "rapid.Custom" [line "func(t *rapid.T) LawSpecValue " <> block (statements body)]
mapped :: D.Doc -> String -> D.Doc -> D.Doc
mapped source argumentType body = call "rapid.Map" [source,
  line ("func(value " ++ argumentType ++ ") LawSpecValue ") <> block (returned body)]
draw :: D.Doc -> String -> D.Doc
draw generator name = generator <> line ".Draw(t, " <> quoted name <> line ")"

-- These domains and Rapid combinators are shared by structural test generation
-- and the scalar registry consumed by schema strategies.
generatorDoc :: Int -> Integer -> (Type -> Bool) -> (Type -> D.Doc) -> Type -> D.Doc
generatorDoc bits budget structural reference = generatorDocBounded (integerBounds bits) bits budget structural reference

-- The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> (Type -> Bool) -> (Type -> D.Doc) -> Type -> D.Doc
generatorDocWithin within bits budget structural reference ty = generatorDocBounded boundsOf bits budget structural reference ty
  where
    boundsOf name = case (within, ty) of
      (Just range, Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorDocBounded :: (String -> Maybe (Integer, Integer)) -> Int -> Integer -> (Type -> Bool) -> (Type -> D.Doc) -> Type -> D.Doc
generatorDocBounded boundsOf bits budget structural reference = gen
  where
    width = line (show bits)
    key = quoted . Native.goDataKey
    native name = call "lsFromNative" [quoted name,value "value",width]
    gen ty | structural ty = call "lsDataStrategy"
      [value "_lawspecSchema",reference ty,width,line (show budget),value "_lawspecScalarGenerator"]
    gen ty@(Constructor "List" [TypeArgument inner]) = mapped
      (call "rapid.SliceOfN" [gen inner,value "0",value "64"]) "[]LawSpecValue"
      (call "lsList" [key ty,value "value"])
    gen ty@(Constructor "Maybe" [TypeArgument inner]) = call "rapid.OneOf"
      [call "rapid.Just" [call "lsConstruct" [key ty,quoted "Maybe::Nothing",E.array []]],
       sumGen ty "Maybe::Just" inner]
    gen ty@(Constructor "Either" [TypeArgument a,TypeArgument b]) = call "rapid.OneOf"
      [sumGen ty "Either::Left" a,sumGen ty "Either::Right" b]
    gen ty@(Constructor _ [TypeArgument inner]) = custom
      [line "if rapid.Bool().Draw(t, \"present\") " <> block (statements
        [bind "value" (draw (gen inner) "payload"),returned (call "lsPresent" [key ty,value "&value"])]),
       returned (call "lsPresent" [key ty,value "nil"])]
    gen (Constructor name []) | Just (lo,hi) <- boundsOf name =
      let signed = maybe (lo < 0) ((< 0) . fst) (integerBounds bits name)
      in mapped (call (if signed then "rapid.Int64Range" else "rapid.Uint64Range") [line (show lo),line (show hi)])
        (if signed then "int64" else "uint64")
        (call (if signed then "lsSignedInteger" else "lsUnsignedInteger") [quoted name,value "value"])
    gen (Constructor "Bool" []) = mapped (value "rapid.Bool()") "bool" (value "lsBool(value)")
    gen (Constructor name []) | name `elem` ["BigInt","BigUInt","Integer"] = custom
      ([bind "bytes" (draw (value "rapid.SliceOfN(rapid.Byte(), 0, 32)") "magnitude"),
        value "value := new(LawSpecBigInt).SetBytes(bytes)"] ++
       [line "if rapid.Bool().Draw(t, \"negative\") " <> block (value "value.Neg(value)") | name /= "BigUInt"] ++
       [returned (line "LawSpecValue{" <> quoted name <> line ", value}")])
    gen (Constructor "Text" []) = mapped
      (call "rapid.StringOfN" [value "rapid.Int32Range(0, 1114111)" <>
        line ".Filter(func(value rune) bool " <> block (value "return value < 55296 || value > 57343") <>
        line ")",value "0",value "100",value "400"]) "string" (native "Text")
    gen (Constructor name []) | name `elem` ["Char","CodePoint","CodeUnit16"] = mapped
      (call "rapid.IntRange" [value "0",value (if name == "CodeUnit16" then "65535" else "1114111")] <>
        if name == "Char" then line ".Filter(func(value int) bool " <>
          block (value "return value < 55296 || value > 57343") <> line ")" else mempty)
      "int" (call "lsCharacter" [quoted name,value "value"])
    gen (Constructor name []) | name `elem` ["Bytes","Utf16Text","CodePointText"] =
      let (element,elementType) = case name of
            "Bytes" -> ("rapid.Byte()","byte")
            "Utf16Text" -> ("rapid.Uint16()","uint16")
            _ -> ("rapid.Int32Range(0, 1114111)","rune")
      in mapped (call "rapid.SliceOfN" [value element,value "0",value "100"])
        ("[]" ++ elementType) (native name)
    gen (Constructor name []) | name `elem` ["Float32","Float64"] = call "rapid.OneOf"
      [mapped (line ("rapid." ++ name ++ "()")) (if name == "Float32" then "float32" else "float64") (native name),
       call "rapid.SampledFrom" [E.array (map floating (scalarBoundaries bits name))]]
    gen (Constructor name []) | name `elem` ["Complex64","Complex128"] =
      let inner = gen (scalarType (if name == "Complex64" then "Float32" else "Float64"))
      in custom [bind "real" (draw inner "real"),bind "imaginary" (draw inner "imaginary"),
        returned (call "lsComplex" [quoted name,value "real",value "imaginary"])]
    gen (Constructor "Decimal" []) = custom
      [bind "coefficient" (draw (gen (scalarType "BigInt")) "coefficient"),
       bind "exponent" (draw (value "rapid.IntRange(-20, 20)") "exponent"),
       value "return LawSpecValue{\"Decimal\", lawSpecDecimal{coefficient.Data.(*LawSpecBigInt), exponent}}"]
    gen (Constructor "Rational" []) = custom
      [bind "numerator" (draw (gen (scalarType "BigInt")) "numerator"),
       bind "denominator" (draw (gen (scalarType "BigUInt")) "denominator"),
       value "positive := new(LawSpecBigInt).Add(denominator.Data.(*LawSpecBigInt), new(LawSpecBigInt).SetInt64(1))",
       value "return LawSpecValue{\"Rational\", new(LawSpecRational).SetFrac(numerator.Data.(*LawSpecBigInt), positive)}"]
    gen (Constructor "Symbol" []) = mapped (value "rapid.StringN(0, 100, 400)") "string"
      (value "LawSpecValue{\"Symbol\", &lawSpecSymbol{description: value}}")
    gen (Constructor name []) | name `elem` ["Unit","Null","Undefined"] =
      call "rapid.Just" [call "lsAbsent" [quoted name]]
    gen ty = error ("unsupported Go structural generator: " ++ show ty)
    sumGen ty tag inner = mapped (gen inner) "LawSpecValue"
      (call "lsConstruct" [key ty,quoted tag,E.array [value "value"]])
    floating (SFloat name pattern) = call "lsFloating" [quoted name,quoted pattern]
    floating _ = error "non-floating Go boundary"

assertionDoc :: D.Doc
assertionDoc = line "func _lawspecAssert(t interface{ Fatalf(string, ...any) }, context string, actual, expected func() LawSpecValue) " <>
  block (value "lsAssert(context, actual, expected)")

dataHelpersDoc :: Int -> (Type -> D.Doc) -> D.Doc
dataHelpersDoc bits generator = statements
  [value "var _lawspecSchema = lawSpecDataSchemaRegistry()",mempty,
   line "func _lawspecScalarGenerator(name string) *rapid.Generator[LawSpecValue] " <>
     block (line "switch name {" <> D.hardline <>
       statements ([line "case " <> quoted (primitiveName p) <> line ":" <>
         D.nest 8 (D.hardline <> returned (generator (scalarType (primitiveName p)))) | p <- primitives] ++
         [line "default:" <> D.nest 8 (D.hardline <> value "panic(\"unknown scalar generator: \" + name)")]) <>
       D.hardline <> line "}"),mempty,
   line "func _lawspecDataAssert(context string, ty lawSpecTypeRef, symbols map[string]*lawSpecSymbol, actual, expected func() LawSpecValue) " <>
     block (statements [line "defer func() " <> block
       (line "if problem := recover(); problem != nil " <> block (value "panic(context + \" | \" + fmt.Sprint(problem))")) <> line "()",
       line ("if !_lawspecSchema.equal(ty, actual(), expected(), " ++ show bits ++ ", symbols) ") <>
         block (value "panic(context)")])]
