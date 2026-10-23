-- | Framework-specific Java generators downstream of checked Core.
module LawSpec.JavaTestHelpers (generatorDoc, generatorDocWithin, scalarsDoc, scalarsClass) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.Code.Doc as D

text = D.text
call = E.call
quoted = E.quoted
number :: Show a => a -> D.Doc
number = text . show
statements = D.joinWith D.hardline
block = D.block 2
statement value = value <> text ";"
returned value = statement (text "return " <> value)
bind name value = D.group (text ("var " ++ name ++ " =") <> D.nest 4 (D.softline <> value) <> text ";")
runtime name = call ("LawSpecRuntime." ++ name)
chain base methods = D.group (D.nest 4 base <> D.nest 4
  (mconcat [D.softbreak <> call ("." ++ name) args | (name,args) <- methods]))
method base name args = chain base [(name,args)]
lambda parameter body = D.group (text (parameter ++ " ->") <> D.nest 4 (D.softline <> body))
mapped source parameter body = method source "map" [lambda parameter body]
custom env body = call "Generator.from" [D.multiline (text (env ++ " -> ") <> block (statements body))]

-- | The scalar generators' class, the runtime's for a machine width.
scalarsClass :: String
scalarsClass = "lawspec.testing.LawSpecScalars"

-- | Byte magnitude/sign choices and collection combinators deliberately retain
-- the native JetCheck generation tree and its shrinker.
generatorDoc :: Int -> Integer -> String -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget className structural reference key = generatorDocBounded (integerBounds bits) bits budget className structural reference key

-- | The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> String -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocWithin within bits budget className structural reference key ty = generatorDocBounded boundsOf bits budget className structural reference key ty
  where
    boundsOf name = case (within, ty) of
      (Just range, C.Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorDocBounded :: (String -> Maybe (Integer, Integer)) -> Int -> Integer -> String -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocBounded boundsOf bits budget className structural reference key = gen 0
  where
    gen depth ty = renderGenerator (generatorChain depth ty)
    renderGenerator (base,[]) = base
    renderGenerator (base,methods) = chain base methods
    generatorChain depth ty | structural ty = (baseGenerator depth ty,[])
    generatorChain depth ty@(C.Constructor "List" [C.TypeArgument inner]) =
      (call "Generator.listsOf" [gen (depth+1) inner],
       [("map",[lambda "values" (runtime "list" [quoted (key ty),text "values"])])])
    generatorChain _ (C.Constructor name []) | Just (lo,hi) <- boundsOf name,
      lo >= -2147483648 && hi <= 2147483647 =
      (call "Generator.integers" [number lo,number hi],
       [("map",[lambda "number" (runtime "integer" [quoted name,text "number.toString()"])])])
    generatorChain _ (C.Constructor "Bool" []) =
      (text "Generator.booleans()",[("map",[text "LawSpecRuntime::bool"])])
    generatorChain _ (C.Constructor name []) | name `elem` ["Char","CodePoint","CodeUnit16"] =
      (unitBase name,unitFilter name ++ [("map",[lambda "point" (runtime "character" [quoted name,text "point"])])])
    generatorChain _ (C.Constructor name []) | name `elem` ["Text","Bytes","Utf16Text","CodePointText"] =
      (listGen 0 100 (unitGen name),[("map",[textMapping name])])
    generatorChain _ (C.Constructor "Symbol" []) =
      (listGen 0 100 (unitGen "Text"),[("map",[textMapping "Text"]),
       ("map",[lambda "description" (call "new Value" [quoted "Symbol",call "new LawSpecRuntime.SymbolValue"
         [text "(String) " <> runtime "toNative" [quoted "Text",text "description",text "MACHINE_BITS"]]])])])
    generatorChain depth ty = (baseGenerator depth ty,[])
    baseGenerator _ ty | structural ty = call "lawspec.testing.LawSpecDataStrategies.sizedGenerator"
      [text "SCHEMA",reference ty,text "MACHINE_BITS",number budget,text (scalarsClass ++ "::generator")]
    baseGenerator depth ty@(C.Constructor "Maybe" [C.TypeArgument inner]) = call "Generator.anyOf"
      [call "Generator.constant" [runtime "construct" [quoted (key ty),quoted "Maybe::Absent",E.array []]],
       sumGen depth ty "Maybe::Present" inner]
    baseGenerator depth ty@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = call "Generator.anyOf"
      [sumGen depth ty "Either::Left" a,sumGen depth ty "Either::Right" b]
    baseGenerator depth ty@(C.Constructor _ [C.TypeArgument inner]) =
      let env = "environment" ++ show depth
      in custom env [text ("if (" ++ env ++ ".generate(Generator.booleans()))") <> D.hardline <>
          block (returned (runtime "present" [quoted (key ty),call (env ++ ".generate") [gen (depth+1) inner]])),
        returned (runtime "present" [quoted (key ty),text "null"])]
    baseGenerator depth (C.Constructor name []) | Just (lo,hi) <- boundsOf name =
      let width = byteWidth hi in integerGen depth name width width (lo < 0)
    baseGenerator depth (C.Constructor name []) | name `elem` ["BigInt","BigUInt","Integer"] =
      integerGen depth name 0 32 (name /= "BigUInt")
    baseGenerator _ (C.Constructor name []) | name `elem` ["Float32","Float64"] = call "Generator.anyOf"
      [mapped (text "Generator.doubles()") "number" (runtime "fromNative"
        [quoted name,text (if name == "Float32" then "number.floatValue()" else "number"),text "MACHINE_BITS"]),
       call "Generator.sampledFrom" (map floating (scalarBoundaries bits name))]
    baseGenerator depth (C.Constructor name []) | name `elem` ["Complex64","Complex128"] =
      let env = "environment" ++ show depth
          inner = gen (depth+1) (C.scalarType (if name == "Complex64" then "Float32" else "Float64"))
          component = call (env ++ ".generate") [inner]
      in call "Generator.from" [lambda env (runtime "complex" [quoted name,component,component])]
    baseGenerator depth (C.Constructor "Decimal" []) =
      let env = "environment" ++ show depth
      in custom env
        [bind "coefficient" (call (env ++ ".generate") [gen (depth+1) (C.scalarType "BigInt")]),
         bind "exponent" (text (env ++ ".generate(Generator.integers(-20, 20))")),
         returned (runtime "decimal" [text "((java.math.BigInteger) coefficient.data()).toString()",
           text "java.lang.Integer.toString(exponent)"])]
    baseGenerator depth (C.Constructor "Rational" []) =
      let env = "environment" ++ show depth
      in custom env
        [bind "numerator" (call (env ++ ".generate") [gen (depth+1) (C.scalarType "BigInt")]),
         bind "denominator" (call (env ++ ".generate") [gen (depth+1) (C.scalarType "BigUInt")]),
         bind "positive" (call "((java.math.BigInteger) denominator.data()).add" [text "java.math.BigInteger.ONE"]),
         returned (runtime "rational" [text "((java.math.BigInteger) numerator.data()).toString()",text "positive.toString()"])]
    baseGenerator _ (C.Constructor name []) | name `elem` ["Unit","Null","Undefined"] =
      call "Generator.constant" [runtime "absent" [quoted name]]
    baseGenerator _ ty = error ("unsupported Java structural generator: " ++ show ty)
    sumGen depth ty tag inner =
      let (base,methods) = generatorChain (depth+1) inner
      in renderGenerator (base,methods ++ [("map",[lambda "payload"
        (runtime "construct" [quoted (key ty),quoted tag,E.array [text "payload"]])])])

    textMapping name = lambda "units"
      (runtime "sequence" [quoted name,chain (text "units.stream()") [("mapToInt",[text "unit -> unit"]),("toArray",[])]])
    unitBase name = call "Generator.integers" [text "0",text
      (if name == "Bytes" then "255" else if name `elem` ["Utf16Text","CodeUnit16"] then "65535" else "1114111")]
    unitFilter name = [("suchThat",[lambda "point" (text "point < 55296 || point > 57343")]) | name `elem` ["Text","Char"]]
    unitGen name = if null (unitFilter name) then unitBase name else chain (unitBase name) (unitFilter name)
    listGen lo hi inner = call "Generator.listsOf"
      [D.prefixChoice "org.jetbrains.jetCheck.IntDistribution.uniform("
        (call "org.jetbrains.jetCheck.IntDistribution.uniform" [number (lo :: Int),number hi])
        (chain (text "org.jetbrains.jetCheck.IntDistribution") [("uniform",[number lo,number hi])]),inner]
    byteWidth hi = walk 1 where walk n | hi < 256 ^ n = n | otherwise = walk (n+1)
    integerGen depth name lo hi signed =
      let env = "environment" ++ show depth
      in custom env
        [bind "raw" (call (env ++ ".generate") [listGen lo hi (text "Generator.integers(0, 255)")]),
         text "byte[] bytes = new byte[raw.size()];",
         text "for (int index = 0; index < bytes.length; index++)" <> D.hardline <>
           block (text "bytes[index] = raw.get(index).byteValue();"),
         bind "integer" (D.group (text "bytes.length == 0" <> D.nest 4
           (D.softline <> text "? java.math.BigInteger.ZERO" <> D.softline <> text ": " <>
            call "new java.math.BigInteger" ([text "1" | not signed] ++ [text "bytes"])))),
         returned (runtime "integer" [quoted name,text "integer.toString()"])]
    floating (SFloat name pattern) = runtime "floating" [quoted name,quoted pattern]
    floating _ = error "non-floating Java boundary"

-- | The runtime's scalar generators for a machine width: one class per
-- project, so test files hold only their laws. ref:DEC-readable-output-default
scalarsDoc :: Maybe String -> Int -> (C.Type -> D.Doc) -> D.Doc
scalarsDoc header bits generator = statements
  [ maybe mempty (\h -> text ("// " ++ h) <> D.hardline <> D.hardline) header <> text "package lawspec.testing;"
  , mempty
  , text "import lawspec.runtime.LawSpecRuntime;"
  , text "import lawspec.runtime.LawSpecRuntime.Value;"
  , text "import org.jetbrains.jetCheck.Generator;"
  , mempty
  , text ("// LawSpec's generators of scalar values, for a " ++ show bits ++ "-bit machine.")
  , text "public final class LawSpecScalars"
  , block (statements
      [ text ("private static final int MACHINE_BITS = " ++ show bits ++ ";")
      , mempty
      , text "private LawSpecScalars()" <> D.hardline <> text "{" <> D.hardline <> text "}"
      , mempty
      , text "public static Generator<Value> generator(String type)" <> D.hardline <>
          block (text "return switch (type)" <> D.hardline <> block (statements
            ([D.group (text "case " <> quoted (primitiveName p) <> text " ->" <>
               D.nest 4 (D.softline <> generator (C.scalarType (primitiveName p)))) <> text ";" | p <- primitives] ++
             [text "default -> throw new IllegalArgumentException(type);"])) <> text ";") ])
  ] <> D.hardline
