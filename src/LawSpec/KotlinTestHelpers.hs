-- Framework-specific Kotlin generators downstream of checked Core.
module LawSpec.KotlinTestHelpers (generatorDoc, assertionDoc, dataHelpersDoc) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

text = D.text
quoted = text . concatMap escapeDollar . T.unpack . T.decodeUtf8 . encode
  where escapeDollar '$' = "\\$"; escapeDollar c = [c]
number :: Show a => a -> D.Doc
number = text . show
call name values = text name <> D.delimitTrailing 4 "(" ")" values
runtime name = call ("LawSpecRuntime." ++ name)
statements = D.joinWith D.hardline
block = D.block 4
bind name value = D.group (text ("val " ++ name ++ " =") <> D.nest 4 (D.softline <> value))
lambda parameters body = text (" { " ++ parameters ++ " ->") <>
  D.nest 4 (D.hardline <> D.multiline body) <> D.hardline <> text "}"
mapped source name body = D.multiline (source <> text ".map" <> lambda name body)

-- Keep native Kotest choices, binding, list budgets and shrinkers unchanged.
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget structural reference key = gen
  where
    gen ty | structural ty = call "LawSpecKotlinStrategies.generator"
      [text "_schema",reference ty,number bits,number budget,text "::_lawspecScalarGenerator"]
    gen ty@(C.Constructor "List" [C.TypeArgument inner]) =
      mapped (call "lawspecList" [gen inner,text "0..64"]) "_values"
        (runtime "list" [quoted (key ty),text "_values"])
    gen ty@(C.Constructor "Maybe" [C.TypeArgument inner]) = call "lawspecChoice"
      [call "Arb.constant" [runtime "construct" [quoted (key ty),quoted "Maybe::Nothing",call "arrayOf" []]],
       sumGen ty "Maybe::Just" inner]
    gen ty@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = call "lawspecChoice"
      [sumGen ty "Either::Left" a,sumGen ty "Either::Right" b]
    gen ty@(C.Constructor _ [C.TypeArgument inner]) = call "lawspecChoice"
      [call "Arb.constant" [runtime "present" [quoted (key ty),text "null"]],
       mapped (gen inner) "_value" (runtime "present" [quoted (key ty),text "_value"])]
    gen (C.Constructor name []) | Just (lo,hi) <- integerBounds bits name =
      if lo >= -2147483648 && hi <= 2147483647
      then mapped (call "Arb.int" [text (show lo ++ ".." ++ show hi)]) "_number"
        (runtime "integer" [quoted name,text "_number.toString()"])
      else let width = byteWidth hi in integerGen name width width (lo < 0)
    gen (C.Constructor name []) | name `elem` ["BigInt","BigUInt","Integer"] =
      integerGen name 0 32 (name /= "BigUInt")
    gen (C.Constructor "Bool" []) = mapped (text "Arb.boolean()") "_value" (runtime "bool" [text "_value"])
    gen (C.Constructor name []) | name `elem` ["Char","CodePoint","CodeUnit16"] =
      mapped (unitGen name) "_point" (runtime "character" [quoted name,text "_point"])
    gen (C.Constructor name []) | name `elem` ["Text","Bytes","Utf16Text","CodePointText"] =
      mapped (call "lawspecList" [unitGen name,text "0..100"]) "_units"
        (runtime "sequence" [quoted name,text "_units.toIntArray()"])
    gen (C.Constructor name []) | name `elem` ["Float32","Float64"] = call "lawspecChoice"
      [mapped (text ("Arb." ++ (if name == "Float32" then "float" else "double") ++ "()")) "_number"
        (runtime "fromNative" [quoted name,text "_number",number bits]),
       call "Arb.element" [call "listOf" (map floating (scalarBoundaries bits name))]]
    gen (C.Constructor name []) | name `elem` ["Complex64","Complex128"] =
      let inner = gen (C.scalarType (if name == "Complex64" then "Float32" else "Float64"))
      in call "Arb.bind" [inner,inner] <> lambda "_real, _imaginary"
        (runtime "complex" [quoted name,text "_real",text "_imaginary"])
    gen (C.Constructor "Decimal" []) = call "Arb.bind" [gen (C.scalarType "BigInt"),text "Arb.int(-20..20)"] <>
      lambda "_coefficient, _exponent" (runtime "decimal"
        [text "(_coefficient.data() as java.math.BigInteger).toString()",text "_exponent.toString()"])
    gen (C.Constructor "Rational" []) = call "Arb.bind" [gen (C.scalarType "BigInt"),gen (C.scalarType "BigUInt")] <>
      lambda "_numerator, _denominator" (statements
        [bind "positive" (call "(_denominator.data() as java.math.BigInteger).add" [text "java.math.BigInteger.ONE"]),
         runtime "rational" [text "(_numerator.data() as java.math.BigInteger).toString()",text "positive.toString()"]])
    gen (C.Constructor "Symbol" []) = mapped (gen (C.scalarType "Text")) "_description"
      (call "LawSpecRuntime.Value" [quoted "Symbol",call "LawSpecRuntime.SymbolValue"
        [runtime "toNative" [quoted "Text",text "_description",number bits] <> text " as String"]])
    gen (C.Constructor name []) | name `elem` ["Unit","Null","Undefined"] =
      call "Arb.constant" [runtime "absent" [quoted name]]
    gen ty = error ("unsupported Kotlin structural generator: " ++ show ty)
    sumGen ty tag inner = mapped (gen inner) "_sumValue"
      (runtime "construct" [quoted (key ty),quoted tag,call "arrayOf" [text "_sumValue"]])
    unitGen name = (if name `elem` ["Text","Char"] then D.multiline else id) $ call "Arb.int" [text ("0.." ++
      if name == "Bytes" then "255" else if name `elem` ["Utf16Text","CodeUnit16"] then "65535" else "1114111")] <>
      (if name `elem` ["Text","Char"] then text ".filter" <> lambda "_point" (text "_point < 55296 || _point > 57343") else mempty)
    byteWidth hi = walk (1 :: Int) where walk n | hi < 256 ^ n = n | otherwise = walk (n+1)
    integerGen name lo hi signed = mapped
      (call "lawspecList" [text "Arb.int(0..255)",text (show lo ++ ".." ++ show hi)]) "_raw" (statements
        [text "val _bytes = _raw.map { it.toByte() }.toByteArray()",
         bind "_integer" (D.multiline (text "if (_bytes.isEmpty()) " <> block (text "java.math.BigInteger.ZERO") <>
           text " else " <> block (call "java.math.BigInteger" ([text "1" | not signed] ++ [text "_bytes"])))),
         runtime "integer" [quoted name,text "_integer.toString()"]])
    floating (SFloat name pattern) = runtime "floating" [quoted name,quoted pattern]
    floating _ = error "non-floating Kotlin boundary"

assertion :: Int -> Bool -> D.Doc
assertion bits structural =
  call ("private fun " ++ if structural then "_lawspecDataAssert" else "_lawspecAssert")
    ([text "context: String"] ++ (if structural then [text "type: LawSpecSchema.Named",text "symbols: MutableMap<String, Any>"] else []) ++
     [text "actual: () -> LawSpecRuntime.Value",text "expected: () -> LawSpecRuntime.Value"]) <>
  text " " <> block (text "try " <> block (statements
    [text "val a = actual()",text "val b = expected()",
     call "check" [if structural then call "_schema.equal" [text "type",text "a",text "b",number bits,text "symbols"]
       else runtime "equal" [text "a",text "b"]] <> text " " <>
       block (text "\"$context | actual=$a expected=$b\"")]) <>
    text " catch (error: Exception) " <> block (text "throw AssertionError(context, error)"))

assertionDoc :: D.Doc
assertionDoc = assertion 64 False

dataHelpersDoc :: Int -> (C.Type -> D.Doc) -> D.Doc
dataHelpersDoc bits generator = statements
  [text "private val _schema = LawSpecDataSchema.create()",mempty,
   text "private fun _lawspecScalarGenerator(type: String): Arb<LawSpecRuntime.Value> =" <>
     D.nest 4 (D.hardline <> text "when (type) " <> block (statements
       ([quoted (primitiveName p) <> text " -> " <>
         block (generator (C.scalarType (primitiveName p))) | p <- primitives] ++
        [text "else -> throw IllegalArgumentException(type)"]))),mempty,assertion bits True]
