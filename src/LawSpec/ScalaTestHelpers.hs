-- | Scala generators for the scalars and structural types, downstream of
-- checked Core, on LawSpec's shrink trees (lawspec.testing.Arb).
module LawSpec.ScalaTestHelpers (generatorDoc, generatorDocWithin, assertionDoc, dataHelpersDoc) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import LawSpec.ScalaData (scalaQuoted)

text :: String -> D.Doc
text = D.text

quoted :: String -> D.Doc
quoted = text . scalaQuoted

number :: Show a => a -> D.Doc
number = text . show

call :: String -> [D.Doc] -> D.Doc
call name values = text name <> D.delimitTrailing 2 "(" ")" values

runtime :: String -> [D.Doc] -> D.Doc
runtime name = call ("LawSpecRuntime." ++ name)

statements :: [D.Doc] -> D.Doc
statements = D.joinWith D.hardline

-- | A braced function literal: { parameters => body }.
lambda :: String -> D.Doc -> D.Doc
lambda parameters body = text (" { " ++ parameters ++ " =>") <>
  D.nest 2 (D.hardline <> D.multiline body) <> D.hardline <> text "}"

mapped :: D.Doc -> String -> D.Doc -> D.Doc
mapped source name body = D.multiline (source <> text ".map" <> lambda name body)

-- | The generator of a type: scalars from their own generators, data and
-- other structural types from the schema (LawSpecScalaStrategies).
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget structural reference key = generatorDocBounded (integerBounds bits) bits budget structural reference key

-- | The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocWithin within bits budget structural reference key ty = generatorDocBounded boundsOf bits budget structural reference key ty
  where
    boundsOf name = case (within, ty) of
      (Just range, C.Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorDocBounded :: (String -> Maybe (Integer, Integer)) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocBounded boundsOf bits budget structural reference key = gen
  where
    gen ty | structural ty = call "LawSpecScalaStrategies.generator"
      [text "_schema",reference ty,number bits,number budget,text "_lawspecScalarGenerator"]
    gen ty@(C.Constructor "List" [C.TypeArgument inner]) =
      mapped (call "Arb.list" [gen inner,text "0 to 64"]) "_values"
        (runtime "list" [quoted (key ty),text "_values.asJava"])
    gen ty@(C.Constructor "Maybe" [C.TypeArgument inner]) = call "Arb.choice"
      [call "Arb.constant" [runtime "construct" [quoted (key ty),quoted "Maybe::Nothing",text "Array[LawSpecRuntime.Value]()"]],
       sumGen ty "Maybe::Just" inner]
    gen ty@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = call "Arb.choice"
      [sumGen ty "Either::Left" a,sumGen ty "Either::Right" b]
    gen ty@(C.Constructor _ [C.TypeArgument inner]) = call "Arb.choice"
      [call "Arb.constant" [runtime "present" [quoted (key ty),text "null"]],
       mapped (gen inner) "_value" (runtime "present" [quoted (key ty),text "_value"])]
    gen (C.Constructor name []) | Just (lo,hi) <- boundsOf name =
      if lo >= -2147483648 && hi <= 2147483647
      then mapped (call "Arb.int" [text (show lo ++ " to " ++ show hi)]) "_number"
        (runtime "integer" [quoted name,text "_number.toString"])
      else let width = byteWidth hi in integerGen name width width (lo < 0)
    gen (C.Constructor name []) | name `elem` ["BigInt","BigUInt","Integer"] =
      integerGen name 0 32 (name /= "BigUInt")
    gen (C.Constructor "Bool" []) = mapped (text "Arb.boolean") "_value" (runtime "bool" [text "_value"])
    gen (C.Constructor name []) | name `elem` ["Char","CodePoint","CodeUnit16"] =
      mapped (unitGen name) "_point" (runtime "character" [quoted name,text "_point"])
    gen (C.Constructor name []) | name `elem` ["Text","Bytes","Utf16Text","CodePointText"] =
      mapped (call "Arb.list" [unitGen name,text "0 to 100"]) "_units"
        (runtime "sequence" [quoted name,text "_units.toArray"])
    gen (C.Constructor name []) | name `elem` ["Float32","Float64"] = call "Arb.choice"
      [mapped (text ("Arb." ++ (if name == "Float32" then "float" else "double"))) "_number"
        (runtime "fromNative" [quoted name,text "_number",number bits]),
       call "Arb.element" [call "List" (map floating (scalarBoundaries bits name))]]
    gen (C.Constructor name []) | name `elem` ["Complex64","Complex128"] =
      let inner = gen (C.scalarType (if name == "Complex64" then "Float32" else "Float64"))
      in call "Arb.bind" [inner,inner] <> lambda "(_real, _imaginary)"
        (runtime "complex" [quoted name,text "_real",text "_imaginary"])
    gen (C.Constructor "Decimal" []) = call "Arb.bind" [gen (C.scalarType "BigInt"),text "Arb.int(-20 to 20)"] <>
      lambda "(_coefficient, _exponent)" (runtime "decimal"
        [text "_coefficient.data().asInstanceOf[java.math.BigInteger].toString",text "_exponent.toString"])
    gen (C.Constructor "Rational" []) = call "Arb.bind" [gen (C.scalarType "BigInt"),gen (C.scalarType "BigUInt")] <>
      lambda "(_numerator, _denominator)" (statements
        [text "val positive = _denominator.data().asInstanceOf[java.math.BigInteger].add(java.math.BigInteger.ONE)",
         runtime "rational" [text "_numerator.data().asInstanceOf[java.math.BigInteger].toString",text "positive.toString"]])
    gen (C.Constructor "Symbol" []) = mapped (gen (C.scalarType "Text")) "_description"
      (call "LawSpecRuntime.Value" [quoted "Symbol",call "LawSpecRuntime.SymbolValue"
        [runtime "toNative" [quoted "Text",text "_description",number bits] <> text ".asInstanceOf[String]"]])
    gen (C.Constructor name []) | name `elem` ["Unit","Null","Undefined"] =
      call "Arb.constant" [runtime "absent" [quoted name]]
    gen ty = error ("unsupported Scala structural generator: " ++ show ty)
    sumGen ty tag inner = mapped (gen inner) "_sumValue"
      (runtime "construct" [quoted (key ty),quoted tag,text "Array[LawSpecRuntime.Value](_sumValue)"])
    unitGen name = (if name `elem` ["Text","Char"] then D.multiline else id) $ call "Arb.int" [text ("0 to " ++
      if name == "Bytes" then "255" else if name `elem` ["Utf16Text","CodeUnit16"] then "65535" else "1114111")] <>
      (if name `elem` ["Text","Char"] then text ".filter" <> lambda "_point" (text "_point < 55296 || _point > 57343") else mempty)
    byteWidth hi = walk (1 :: Int) where walk n | hi < 256 ^ n = n | otherwise = walk (n+1)
    integerGen name lo hi signed = mapped
      (call "Arb.list" [text "Arb.int(0 to 255)",text (show lo ++ " to " ++ show hi)]) "_raw" (statements
        [text "val _bytes = _raw.map(_.toByte).toArray",
         text "val _integer = " <> D.multiline (text "if (_bytes.isEmpty) java.math.BigInteger.ZERO else " <>
           call "java.math.BigInteger" ([text "1" | not signed] ++ [text "_bytes"])),
         runtime "integer" [quoted name,text "_integer.toString"]])
    floating (SFloat name pattern) = runtime "floating" [quoted name,quoted pattern]
    floating _ = error "non-floating Scala boundary"

assertion :: Int -> Bool -> D.Doc
assertion bits structural =
  call ("def " ++ if structural then "_lawspecDataAssert" else "_lawspecAssert")
    ([text "context: String"] ++ (if structural then [text "tpe: LawSpecSchema.Named",text "symbols: LawSpecScala.Symbols"] else []) ++
     [text "actual: => LawSpecRuntime.Value",text "expected: => LawSpecRuntime.Value"]) <>
  text ": Unit = " <> D.block 2 (statements
    [ text "val failure = " <> D.block 2 (text "try " <> D.block 2 (statements
        [text "val a = actual",text "val b = expected",
         text "if " <> call "" [if structural then call "_schema.equal" [text "tpe",text "a",text "b",number bits,text "symbols"]
           else runtime "equal" [text "a",text "b"]] <> text " null else " <>
           text "s\"$context | actual=$a expected=$b${LawSpecRuntime.difference(a, b)}\""]) <>
        text " catch " <> D.block 2 (text "case error: Exception => throw AssertionError(s\"$context: $error\", error)"))
    , text "if (failure != null) throw AssertionError(failure)" ])

-- | Assertions report the law, the inputs and both sides, so a failure
-- explains itself.
assertionDoc :: D.Doc
assertionDoc = assertion 64 False

-- | Data values are built and compared through helpers emitted once per test
-- object rather than at every use.
dataHelpersDoc :: Int -> (C.Type -> D.Doc) -> D.Doc
dataHelpersDoc bits generator = statements
  [text "val _schema: LawSpecSchema = LawSpecDataSchema.create()",mempty,
   text "def _lawspecScalarGenerator(name: String): Arb[LawSpecRuntime.Value] = " <>
     text "name match " <> D.block 2 (statements
       ([text ("case " ++ scalaQuoted (primitiveName p) ++ " => ") <>
         D.block 2 (generator (C.scalarType (primitiveName p))) | p <- primitives] ++
        [text "case _ => throw IllegalArgumentException(name)"])),mempty,assertion bits True]
