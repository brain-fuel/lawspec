-- | Native Scala declarations from checked Core; no surface syntax or inference.
-- Products are case classes, sums are enums, and the built-in types are
-- Scala's own immutable ones: List, Option, Either, Set, Map and BigInt.
-- ref:DEC-scala-on-the-jvm-runtime
module LawSpec.ScalaData (emitScalaDataWithProfile, scalaCodecDocWithContext, scalaDataType, scalaCodec, scalaTypeReference, requiresSchema, scalaDataTypeDoc, scalaCodecDoc, scalaTypeReferenceDoc, identifier, emitScalaNativeCodecs, scalaNativeCodecDoc, scalaNativeTypeDoc, scalaKeywords, escaped, scalaQuoted, scalaScalars, symbolsType, rootQualified) where

import LawSpec.DataNames (qualifiedDataName, isProduct, caseNames, caseInsensitiveCounts, ambiguous)
import LawSpec.Scalar (primitives, primitiveName)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub, find, intercalate)
import LawSpec.NativeBinding
import Numeric (showHex)
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry, checkType, freeExistentials)
import LawSpec.Collections (collectionContainer)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Core.Schema as S
import LawSpec.Common (Artifact(..))
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.JavaData as JVM
import qualified LawSpec.Code.Doc as D

type Names = [(C.Id, String)]

-- | Scala's reserved words, hard and soft, in the positions LawSpec names.
scalaKeywords :: [String]
scalaKeywords = words "abstract case catch class def do else enum export extends false final finally for forSome given if implicit import lazy macro match new null object override package private protected return sealed super then this throw trait true try type val var while with yield as derives end extension infix inline opaque open transparent using"

-- | A keyword is escaped in backticks, Scala's own way to use one as a name.
escaped :: String -> String
escaped name
  | name `elem` scalaKeywords = "`" ++ name ++ "`"
  | otherwise = name

-- | Fully qualified names from the root: inside lawspec.definitions or
-- lawspec.abilities, a sibling package named lawspec (the built-in units')
-- would otherwise take lawspec.runtime for its own. String literals and the
-- package clause are left alone.
rootQualified :: String -> String
rootQualified = unlines . map line . lines
  where
    line l | take 8 l == "package " = l
           | otherwise = go ' ' l
    go _ [] = []
    go _ ('"' : rest) = '"' : literal rest
    go previous text@(c : rest)
      | take 8 text == "lawspec." && not (isAlphaNum previous || previous `elem` ("._`" :: String)) = "_root_." ++ c : go c rest
      | otherwise = c : go c rest
    literal ('\\' : c : rest) = '\\' : c : literal rest
    literal ('"' : rest) = '"' : go '"' rest
    literal (c : rest) = c : literal rest
    literal [] = []

-- | The type of the symbols map generated code passes along.
symbolsType :: String
symbolsType = "lawspec.runtime.LawSpecScala.Symbols"

-- | A data name must be a valid Scala identifier, or the generated file would
-- not compile.
identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid Scala data identifier: " ++ name))
  where
    valid = case name of
      first:rest -> isAscii first && isLetter first &&
        all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest
      [] -> False

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let source = [(C.dataId d, C.dataName d) | d <- declarations]
      sourceCounts = caseInsensitiveCounts source
      qualifiedCounts = caseInsensitiveCounts qualified
      qualified = [(identity, if ambiguous sourceCounts name || name `elem` scalaKeywords then qualifiedDataName (C.idText identity) else name)
        | (identity,name) <- source]
      names = [(identity, if ambiguous qualifiedCounts name
        then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity)
        else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names)))
    (Left "conflicting Scala data identities")
  pure names

applied :: String -> [D.Doc] -> D.Doc
applied name [] = D.text name
applied name args = D.group (D.text (name ++ "[") <>
  D.nest 2 (D.softbreak <> D.commaSep args) <> D.text "]")

-- | The identities of handle declarations: their values are adapters' native
-- objects, an Any in generated code unless the handle's binding names its
-- native type in full.
handlesOf :: [C.DataDeclaration] -> [(String, Maybe String)]
handlesOf declarations = [(C.idText (C.dataId d), C.dataNative d) | d <- declarations, C.dataHandle d]

typeDoc :: [(String, Maybe String)] -> Names -> [(C.Id, String)] -> C.Type -> Either String D.Doc
typeDoc handles = typeDocWithNative handles []

-- | Bound native types replace generated ones wherever the type appears.
-- ref:DEC-native-bindings-typed-identity
scalaNativeTypeDoc :: [C.DataDeclaration] -> [ResolvedTypeBinding] -> [(C.Id,String)] -> C.Type -> Either String D.Doc
scalaNativeTypeDoc declarations mappings parameters ty = do
  names <- namesFor declarations
  typeDocWithNative (handlesOf declarations) mappings names parameters ty

-- | Scala's type for each scalar.
scalaScalars :: [(String, String)]
scalaScalars = [("Bool","scala.Boolean"),("Int8","scala.Byte"),("Int16","scala.Short"),
  ("Int32","scala.Int"),("Int64","scala.Long"),("UInt8","scala.Short"),("UInt16","scala.Int"),
  ("UInt32","scala.Long"),("Float32","scala.Float"),("Float64","scala.Double"),
  ("Decimal","scala.math.BigDecimal"),("Rational","lawspec.runtime.LawSpecRuntime.Ratio"),
  ("Complex64","lawspec.runtime.LawSpecRuntime.Complex"),
  ("Complex128","lawspec.runtime.LawSpecRuntime.Complex"),
  ("Char","java.lang.String"),("CodePoint","scala.Int"),("CodeUnit16","scala.Char"),
  ("Text","java.lang.String"),("Utf16Text","java.lang.String"),("CodePointText","scala.IArray[scala.Int]"),
  ("Bytes","scala.IArray[scala.Byte]"),("Symbol","lawspec.runtime.LawSpecScala.Symbol"),
  ("Unit","scala.Unit"),("Null","lawspec.runtime.LawSpecScala.Null"),
  ("Undefined","lawspec.runtime.LawSpecScala.Undefined")] ++
  [(name,"scala.math.BigInt") | name <- ["Integer","BigInt","BigUInt","UInt64","IntSize","UIntSize","UIntPtr"]]

typeDocWithNative :: [(String, Maybe String)] -> [ResolvedTypeBinding] -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDocWithNative handles mappings names parameters ty = case ty of
  C.Constructor name [] | Just native <- lookup name handles -> pure (D.text (maybe "scala.Any" id native))
  C.TypeVariable variable -> maybe (Left "unbound Scala data parameter")
    (Right . D.text) (lookup variable parameters)
  -- A Duration is a FiniteDuration (LawSpecScalaCodecs' duration).
  C.Constructor name [] | isDurationType name -> pure (D.text "scala.concurrent.duration.FiniteDuration")
  -- Built-in collections are Scala's immutable ones (LawSpecScalaCodecs).
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM typeArgument arguments
    pure $ case short of
      "Set" -> applied "scala.collection.immutable.Set" args
      "KeyVal" -> applied "scala.collection.immutable.Map" args
      "Queue" -> applied "scala.collection.immutable.Queue" args
      "Stack" -> applied "scala.collection.immutable.List" args
      _ -> applied "scala.collection.immutable.Vector" args
  C.Constructor name arguments -> do
    args <- mapM typeArgument arguments
    let nativeNames = [(C.dataId (resolvedDeclaration mapping),intercalate "." (referenceParts (resolvedNativeType mapping))) | mapping <- mappings]
        canonicalNames = [(identity,"lawspec.data." ++ native) | (identity,native) <- names]
    case lookup (C.Id name) (nativeNames ++ canonicalNames) of
      Just native -> pure (applied native args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (applied "scala.collection.immutable.List" args)
        ("Maybe",[_]) -> pure (applied "scala.Option" args)
        ("Either",[_,_]) -> pure (applied "scala.util.Either" args)
        ("Nullable",[_]) -> pure (applied "lawspec.runtime.LawSpecScala.Nullable" args)
        ("Optional",[_]) -> pure (applied "lawspec.runtime.LawSpecScala.Optional" args)
        (_,[]) -> maybe (Left ("no Scala data representation for " ++ name))
          (Right . D.text) (lookup name scalaScalars)
        _ -> Left ("no Scala data representation for " ++ show ty)
  _ -> Left ("no Scala data representation for " ++ show ty)
  where
    typeArgument (C.TypeArgument value) = typeDocWithNative handles mappings names parameters value
    typeArgument _ = Left "indexed Scala data is not supported"

-- | Type text for one-line uses, such as a stub's signature.
scalaDataType :: [C.DataDeclaration] -> C.Type -> Either String String
scalaDataType declarations ty = D.render D.Compact <$> scalaDataTypeDoc declarations ty

-- | Types are checked against the registry before rendering, so an unknown type
-- is a compiler error rather than uncompilable Scala.
scalaDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
scalaDataTypeDoc declarations =
  -- The registry and the names depend only on the declarations: a caller
  -- that applies this to them once shares them across every type.
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \ty -> do
  (registry, names) <- prepared
  checkType registry ty
  typeDoc (handlesOf declarations) names [] ty

-- | LawSpec data become case classes and enums, the shapes a Scala developer
-- would write. ref:DEC-idiomatic-generated-types
emitScalaDataWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitScalaDataWithProfile bits layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  schema <- JVM.emitJavaSchema bits (D.Pretty 100) declarations
  codecs <- emitScalaCodecs layout declarations
  native <- forM [d | d <- declarations, builtinFree d, not (C.dataHandle d)] $ \declaration -> do
    name <- maybe (Left "unplanned Scala data name") Right (lookup (C.dataId declaration) names)
    let parameters = zip (C.dataParameters declaration) [candidate | i <- [0::Int ..], let candidate = "T" ++ show i, candidate /= name]
        arguments = map (D.text . snd) parameters
        variants = C.dataConstructors declaration
        cases = caseNames name variants
        -- A GADT case is generic in the parameters it leaves open and in its
        -- existentials, and extends the enum at the type it refines to.
        declare keyword className enumCase variant = do
          identifier className
          -- A field-only existential is Any; its witness names its type.
          let free = freeExistentials declaration variant
              existentials = zip [e | e <- C.constructorExistentials variant, e `notElem` free]
                [candidate | i <- [0::Int ..], let candidate = "E" ++ show i, candidate /= name]
              scope = parameters ++ existentials ++ [(e, "scala.Any") | e <- free]
              equations = C.constructorEquations variant
              gadt = not (null equations) || not (null existentials)
              -- A product class is the public type itself, so it keeps the
              -- declaration's parameters even when its constructor fixes one.
              own = if not enumCase then arguments
                else if gadt then [D.text t | (p, t) <- parameters, p `notElem` map fst equations] ++ map (D.text . snd) existentials
                else []
          declared <- forM (C.constructorFields variant) $ \field -> do
            ty <- typeDoc (handlesOf declarations) names scope (C.binderType field)
            pure (D.text (escaped (C.binderName field) ++ ": ") <> ty)
          let fields = declared ++ [D.text (S.witnessFieldName (length free) k ++ ": java.lang.String") | k <- [0 .. length free - 1]]
          implemented <- mapM (\(p, t) -> maybe (pure (D.text t)) (typeDoc (handlesOf declarations) names scope) (lookup p equations)) parameters
          let inherits = if enumCase && gadt then D.text " extends " <> applied name implemented else mempty
              -- A case without fields of a generic enum is a class case, so
              -- it takes the enum's type parameters.
              parameterList = if null fields && enumCase && null parameters && not gadt then mempty
                else D.text "(" <> D.nest 2 (D.softbreak <> D.commaSep fields) <> D.softbreak <> D.text ")"
          pure (D.group (applied (keyword ++ className) own <> parameterList <> inherits))
    declarationDoc <- case variants of
      [] -> pure (D.text "final class " <> applied name arguments <> D.text " private ()")
      [only] | isProduct declaration -> declare "final case class " name False only
      _ -> do
        body <- forM variants $ \variant ->
          declare "case " (maybe (C.constructorName variant) id (lookup (C.constructorId variant) cases)) True variant
        pure (D.text "enum " <> applied name arguments <> D.text " " <>
          D.block 2 (D.joinWith D.hardline body))
    let source = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "package lawspec.data" <> D.hardline <> D.hardline <>
          declarationDoc <> D.hardline
    pure (Artifact ("src/main/scala/lawspec/data/" ++ name ++ ".scala")
      (D.render layout source) "generated" "source")
  pure (native ++
    [Artifact "src/main/scala/lawspec/runtime/LawSpecDataCodecs.scala" codecs "generated" "source",
     Artifact "src/main/scala/lawspec/runtime/LawSpecScalaCodecs.scala"
      (runtimeSource "scala-codecs") "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecDataSchema.java"
      schema "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecSchema.java"
      (runtimeSource "java-schema") "generated" "source",
     Artifact "src/main/scala/lawspec/runtime/LawSpecScala.scala"
      (runtimeSource "scala-native") "generated" "source"])

-- | Strings are escaped once, here: a JSON string is a valid Scala literal
-- once its non-ASCII characters are escaped, which encode already does for
-- control characters.
scalaQuoted :: String -> String
scalaQuoted = T.unpack . T.decodeUtf8 . encode

quoted :: String -> D.Doc
quoted = D.text . scalaQuoted

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 2 "(" ")" args

codecName :: String -> String
codecName [] = "dataCodec"
codecName (c:cs) = toLower c : cs ++ "Codec"

referenceDoc :: [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
referenceDoc parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Scala codec parameter")
    (Right . D.text . (++ ".`type`()") . snd) (lookup variable parameters)
  C.Constructor name args -> call "LawSpecSchema.Named" . (quoted name :) <$>
    mapM (argument (referenceDoc parameters)) args
  _ -> Left "function fields cannot cross Scala codecs"

argument :: (C.Type -> Either String a) -> C.Argument -> Either String a
argument f (C.TypeArgument ty) = f ty
argument _ _ = Left "indexed Scala codec is not supported"

codecDoc :: Names -> [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
codecDoc = codecDocUsing Nothing

codecDocUsing :: Maybe D.Doc -> Names -> [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
codecDocUsing = codecDocUsingOwner "LawSpecDataCodecs"

codecDocUsingOwner :: String -> Maybe D.Doc -> Names -> [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
codecDocUsingOwner owner context names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Scala codec parameter")
    (Right . D.text . snd) (lookup variable parameters)
  C.Constructor name [] | isDurationType name ->
    pure (call "lawspec.runtime.LawSpecScalaCodecs.duration" ([D.text "schema", D.text "bits"] ++ rest))
  C.Constructor name args | Just short <- collectionContainer name -> do
    children <- mapM (argument (codecDocUsingOwner owner context names parameters)) args
    let helper = case short of
          "Set" -> "set"
          "KeyVal" -> "keyVal"
          other -> map toLower other
    pure (call ("lawspec.runtime.LawSpecScalaCodecs." ++ helper) ([D.text "schema", D.text "bits"] ++ children ++ rest))
  C.Constructor name args -> do
    children <- mapM (argument (codecDocUsingOwner owner context names parameters)) args
    case lookup (C.Id name) names of
      Just native -> pure (call (owner ++ "." ++ codecName native)
        ([D.text "schema", D.text "bits"] ++ children ++ rest))
      Nothing | Just helper <- lookup name [("List","list"),("Maybe","option"),("Either","either"),("Nullable","nullable"),("Optional","optional")] ->
        pure (call ("lawspec.runtime.LawSpecScalaCodecs." ++ helper) ([D.text "schema", D.text "bits"] ++ children ++ rest))
      Nothing -> do
        native <- typeDoc [] names [] ty
        pure (call ("lawspec.runtime.LawSpecScalaCodecs.scalar[" ++ D.render D.Compact native ++ "]") [D.text "schema", quoted name, D.text "bits"])
  _ -> Left "function fields cannot cross Scala codecs"
  where rest = maybe [] pure context

-- | Codec text for one-line uses.
scalaCodec :: [C.DataDeclaration] -> C.Type -> Either String String
scalaCodec declarations = let codecFor = scalaCodecDoc declarations in fmap (D.render D.Compact) . codecFor

-- | Every value crossing the adapter boundary goes through a codec that checks
-- it against its declared domain. ref:DEC-portable-exact-arithmetic
scalaCodecDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
scalaCodecDoc declarations =
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \ty -> do
  (registry, names) <- prepared
  checkType registry ty
  codecDoc names [] ty

-- | As scalaCodecDoc, where the symbols come from the caller's scope.
scalaCodecDocWithContext :: D.Doc -> [C.DataDeclaration] -> C.Type -> Either String D.Doc
scalaCodecDocWithContext context declarations =
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \ty -> do
  (registry, names) <- prepared
  checkType registry ty
  codecDocUsing (Just context) names [] ty

-- | Codecs for generated types live in one generated object, so a test file
-- refers to them by one name.
emitScalaCodecs :: D.Layout -> [C.DataDeclaration] -> Either String String
emitScalaCodecs = emitCodecs [] "LawSpecDataCodecs"

-- | Codecs for bound native types are kept apart from generated ones, because
-- they call the user's constructors. ref:DEC-native-bindings-typed-identity
emitScalaNativeCodecs :: D.Layout -> [C.DataDeclaration] -> [ResolvedTypeBinding] -> Either String String
emitScalaNativeCodecs layout declarations mappings = emitCodecs mappings "LawSpecNativeCodecs" layout declarations

-- | As scalaCodecDoc, for a bound native type.
scalaNativeCodecDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
scalaNativeCodecDoc declarations ty = do
  names <- namesFor declarations
  codecDocUsingOwner "LawSpecNativeCodecs" (Just (D.text "symbols")) names [] ty

emitCodecs :: [ResolvedTypeBinding] -> String -> D.Layout -> [C.DataDeclaration] -> Either String String
emitCodecs mappings owner layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  definitions' <- mapM (definition names) [d | d <- declarations, builtinFree d]
  dynamicDispatch <- if owner == "LawSpecDataCodecs" && any existentialData declarations
    then (: []) <$> dynamicCodec names else pure []
  let definitions = definitions' ++ dynamicDispatch
  pure (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "package lawspec.runtime" <> D.hardline <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Codec" <> D.hardline <> D.hardline <>
    D.text ("object " ++ owner ++ " ") <>
    D.block 2 (D.joinWith (D.hardline <> D.hardline) definitions) <> D.hardline))
  where
    existentialData declaration = any (not . null . C.constructorExistentials) (C.dataConstructors declaration)
    symbolsParameter = D.text ("symbols: " ++ symbolsType ++ " = lawspec.runtime.LawSpecScala.symbols()")
    -- The native codec of any instantiated type, built at run time: a GADT
    -- case's existential fields learn their types from the value's own type.
    dynamicCodec names = do
      let arguments = [(C.Id ("dynamic" ++ show i), ("scala.Any", "arguments(" ++ show i ++ ")")) | i <- [0 :: Int .. 1]]
          variable i = C.TypeArgument (C.TypeVariable (C.Id ("dynamic" ++ show i)))
          caseFor key ty = do
            doc <- codecDocUsingOwner owner (Just (D.text "symbols")) names arguments ty
            pure (D.text ("case " ++ scalaQuoted key ++ " => ") <> doc)
      dataCases <- mapM (\d -> caseFor (C.idText (C.dataId d))
        (C.Constructor (C.idText (C.dataId d)) [variable i | i <- [0 .. length (C.dataParameters d) - 1]])) declarations
      structural <- mapM (\(name, arity) -> caseFor name (C.Constructor name [variable i | i <- [0 .. arity - 1]]))
        [("List", 1 :: Int), ("Maybe", 1), ("Either", 2)]
      scalars <- mapM (\p -> caseFor (primitiveName p) (C.Constructor (primitiveName p) []))
        [p | p <- primitives, primitiveName p `elem` map fst scalaScalars]
      pure (D.text ("def dynamic(schema: LawSpecSchema, bits: Int, symbols: " ++ symbolsType ++ ", tpe: LawSpecSchema.Named): Codec[Any] = ") <>
        D.block 2 (D.text "val arguments: IndexedSeq[Codec[Any]] = scala.jdk.CollectionConverters.ListHasAsScala(tpe.arguments()).asScala.toIndexedSeq.map(argument => dynamic(schema, bits, symbols, argument.asInstanceOf[LawSpecSchema.Named]))" <> D.hardline <>
          D.text "val codec: Codec[?] = tpe.name() match " <> D.block 2 (D.joinWith D.hardline
            (dataCases ++ structural ++ scalars ++ [D.text "case _ => schema.supported(tpe, bits, symbols)"])) <> D.hardline <>
          D.text "codec.asInstanceOf[Codec[Any]]"))
    mapping declaration = find ((== C.dataId declaration) . C.dataId . resolvedDeclaration) mappings
    nativeOwner declaration name = maybe ("lawspec.data." ++ name)
      (intercalate "." . referenceParts . resolvedNativeType) (mapping declaration)
    constructorMapping variant = find ((== C.constructorId variant) . C.constructorId . resolvedConstructor)
      [c | m <- mappings, c <- resolvedConstructors m]
    declarationOf variant = find (any ((== C.constructorId variant) . C.constructorId) . C.dataConstructors) declarations
    generatedName dataOwner variant = case declarationOf variant of
      Just d | isProduct d -> "lawspec.data." ++ dataOwner
      Just d -> "lawspec.data." ++ dataOwner ++ "." ++
        maybe (C.constructorName variant) id (lookup (C.constructorId variant) (caseNames dataOwner (C.dataConstructors d)))
      Nothing -> "lawspec.data." ++ dataOwner ++ "." ++ C.constructorName variant
    constructorName dataOwner variant = maybe (generatedName dataOwner variant)
      (intercalate "." . referenceParts . resolvedNativeConstructor) (constructorMapping variant)
    -- Generated cases without fields of non-generic enums are singletons.
    generatedObject variant = case (constructorMapping variant, declarationOf variant) of
      (Nothing, Just d) -> not (isProduct d) && null (C.constructorFields variant) && ownCount variant == 0 && not (gadtVariant variant)
      _ -> False
    unitConstructor variant = generatedObject variant ||
      maybe False ((== UnitConstructor) . resolvedConstructorStyle) (constructorMapping variant)
    fieldName variant field = maybe (escaped field) id (constructorMapping variant >>= lookup field . map (\(f,n) -> (C.binderName f,n)) . resolvedFields)
    -- A handle's codec passes its native object through, both ways.
    definition names declaration | C.dataHandle declaration = do
      name <- maybe (Left "unplanned Scala codec") Right (lookup (C.dataId declaration) names)
      pure (D.group (D.text "def " <> call (codecName name)
          [D.text "schema: LawSpecSchema", D.text "bits: Int", symbolsParameter] <>
          D.text (": Codec[" ++ handleType ++ "]")) <> D.text " = " <> D.block 2
        (D.text "val tpe = " <> call "LawSpecSchema.Named" [quoted (C.idText (C.dataId declaration))] <> D.hardline <>
         D.text ("schema.codec[" ++ handleType ++ "](") <> D.nest 2 (D.hardline <> D.joinWith (D.text "," <> D.hardline)
           [D.text "tpe", D.text "bits", D.text "symbols",
            D.text ("(value: " ++ handleType ++ ") => LawSpecRuntime.handle(LawSpecSchema.key(tpe), value)"),
            D.text ("(value: LawSpecRuntime.Value) => LawSpecRuntime.handleTarget(value).asInstanceOf[" ++ handleType ++ "]")] <>
            D.text ",") <> D.hardline <> D.text ")"))
      where handleType = maybe "scala.Any" id (C.dataNative declaration)
    definition names declaration = do
      name <- maybe (Left "unplanned Scala codec") Right (lookup (C.dataId declaration) names)
      let parameters = zip (C.dataParameters declaration)
            [("T" ++ show i, "type" ++ show i) | i <- [0::Int ..]]
          native = applied (nativeOwner declaration name) [D.text t | (_,(t,_)) <- parameters]
          nativeText = D.render D.Compact native
          ty = C.Constructor (C.idText (C.dataId declaration))
            [C.TypeArgument (C.TypeVariable v) | (v,_) <- parameters]
          generic = if null parameters then mempty else
            D.text (D.render D.Compact (applied "" [D.text t | (_,(t,_)) <- parameters]))
          signature = D.group (D.text ("def " ++ codecName name) <> generic <>
            D.delimitTrailing 2 "(" ")" ([D.text "schema: LawSpecSchema", D.text "bits: Int"] ++
              [D.text (v ++ ": ") <> applied "Codec" [D.text t] | (_,(t,v)) <- parameters] ++
              [symbolsParameter]) <>
            D.text ": " <> applied "Codec" [native])
      ref <- referenceDoc parameters ty
      encodeArms <- mapM (encodeArm names parameters name) (C.dataConstructors declaration)
      let directProduct = owner == "LawSpecDataCodecs" && isProduct declaration
      decodeArms <- mapM (decodeArm names parameters name) (C.dataConstructors declaration)
      let failure = D.text "throw IllegalArgumentException(\"uninhabited or invalid native data\")"
          encoder = D.text ("(value: " ++ nativeText ++ ") => {") <> D.nest 2 (D.hardline <>
            (if null encodeArms then failure else
              if directProduct then D.joinWith D.hardline [body | (_,body) <- encodeArms] else
              D.text "(value: Any) match " <>
              D.block 2 (D.joinWith D.hardline
                ([D.text ("case " ++ condition ++ " => ") <> D.block 2 body | (condition,body) <- encodeArms] ++ [D.text "case _ => " <> failure])))) <>
            D.hardline <> D.text "}"
          decoder = D.text "(value: LawSpecRuntime.Value) => {" <> D.nest 2 (D.hardline <>
            D.text "val data = value.data().asInstanceOf[LawSpecRuntime.Data]" <> D.hardline <>
            D.text "data.tag() match " <> D.block 2
              (D.joinWith D.hardline (decodeArms ++ [D.text "case _ => " <> failure]))) <>
            D.hardline <> D.text "}"
      (setup, encodeBody, decodeBody) <- case mapping declaration >>= resolvedCodec of
        Nothing -> pure (mempty, encoder, decoder)
        Just hook -> do
          let canonical = call ("LawSpecDataCodecs." ++ codecName name)
                ([D.text "schema",D.text "bits"] ++
                 [call "schema.supported" [D.text (v ++ ".`type`()"),D.text "bits",D.text "symbols"] |
                   (_,(_,v)) <- parameters] ++ [D.text "symbols"])
              converters method = [D.text ("(x => " ++ v ++ "." ++ method ++ "(x))") | (_,(_,v)) <- parameters]
              nativeRef = intercalate "." . referenceParts
              contextual direction parameter expression = D.text ("(value: " ++ parameter ++ ") => {") <> D.nest 2
                (D.hardline <> D.text "try " <> D.block 2 expression <>
                 D.text " catch " <> D.block 2
                   (D.text "case error: RuntimeException => throw " <> call "IllegalArgumentException"
                     [quoted ("native codec " ++ C.idText (C.dataId declaration) ++ " " ++ direction ++ ": ") <>
                       D.text " + error.getMessage",D.text "error"])) <> D.hardline <> D.text "}"
              encodeHook = call "canonicalCodec.encode"
                [call (nativeRef (codecFromNative hook)) (D.text "value" : converters "encode")]
              decodeHook = call "java.util.Objects.requireNonNull"
                [call (nativeRef (codecToNative hook))
                  (call "canonicalCodec.decode" [D.text "value"] : converters "decode")]
          pure (D.text "val canonicalCodec = " <> canonical <> D.hardline,
            contextual "fromNative" nativeText encodeHook, contextual "toNative" "LawSpecRuntime.Value" decodeHook)
      let body = D.text "val tpe = " <> ref <> D.hardline <> setup <>
            D.text ("schema.codec[" ++ nativeText ++ "](") <>
            D.nest 2 (D.hardline <> D.joinWith (D.text "," <> D.hardline)
              [D.text "tpe", D.text "bits", D.text "symbols", encodeBody, decodeBody] <> D.text ",") <>
            D.hardline <> D.text ")"
      pure (signature <> D.text " = " <> D.block 2 body)
    witnessCount variant = maybe 0 (\d -> length (freeExistentials d variant)) (declarationOf variant)
    -- keys: the value's witness keys, read from the native value or the data.
    fields names parameters keys variant = do
      declared <- forM (zip [0::Int ..] (C.constructorFields variant)) $ \(i,field) -> do
        -- An existential field's type comes from the value's own type, or
        -- from its witnesses.
        bridge <- if any (`elem` C.constructorExistentials variant) (typeVariablesIn (C.binderType field))
          then pure (call "dynamic" [D.text "schema", D.text "bits", D.text "symbols",
            call "schema.fieldType" ([D.text "tpe", quoted (C.idText (C.constructorId variant)), D.text (show i)] ++
              [keys | witnessCount variant > 0])])
          else codecDocUsingOwner owner (Just (D.text "symbols")) names parameters (C.binderType field)
        pure ("field" ++ show i, C.binderName field,
          D.text ("val field" ++ show i ++ " = ") <> bridge)
      text <- codecDocUsingOwner owner (Just (D.text "symbols")) names parameters (C.Constructor "Text" [])
      let n = length (C.constructorFields variant)
      pure (declared ++ [("field" ++ show (n + k), S.witnessFieldName (witnessCount variant) k,
        D.text ("val field" ++ show (n + k) ++ " = ") <> text) | k <- [0 .. witnessCount variant - 1]])
    nativeKeys variant = call "java.util.List.of" [D.text ("value." ++ S.witnessFieldName (witnessCount variant) k) | k <- [0 .. witnessCount variant - 1]]
    dataKeys variant = call "LawSpecSchema.witnessKeys" [D.text "data.fields()", D.text (show (witnessCount variant))]
    encodeArm names parameters dataOwner variant = do
      bindings <- fields names parameters (nativeKeys variant) variant
      let n = length (C.constructorFields variant)
          payload = [call "LawSpecSchema.encodeField"
            [D.text (fieldCodec local), D.text ("value." ++ (if i < n then fieldName variant field else field)), quoted (C.idText (C.constructorId variant) ++ "." ++ field)]
            | (i,(local,field,_)) <- zip [0 :: Int ..] bindings]
          -- A case of a generic type matches at the codec's own parameters;
          -- a GADT case at unknown ones, its fields going through Any.
          typeArguments
            | gadtVariant variant = if ownCount variant > 0 then "[" ++ intercalate ", " (replicate (ownCount variant) "?") ++ "]" else ""
            | null parameters = ""
            | otherwise = "[" ++ intercalate ", " [t | (_,(t,_)) <- parameters] ++ "]"
          condition = if unitConstructor variant then constructorName dataOwner variant
            else "value: " ++ constructorName dataOwner variant ++ typeArguments ++ (if null parameters || gadtVariant variant then "" else " @unchecked")
          fieldCodec local = if gadtVariant variant then local ++ ".asInstanceOf[Codec[Any]]" else local
          identityCheck = [call "require"
            [D.text ("value.getClass == classOf[" ++ constructorName dataOwner variant ++ typeArguments ++ "]"), quoted "invalid native constructor"] |
              owner /= "LawSpecDataCodecs", not (unitConstructor variant)]
          construct = call "schema.construct" [D.text "tpe", quoted (C.idText (C.constructorId variant)),
            call "java.util.List.of" payload, D.text "bits", D.text "symbols"]
      pure (condition,
        (D.joinWith D.hardline (identityCheck ++ [doc | (_,_,doc) <- bindings] ++ [construct])))
    decodeArm names parameters dataOwner variant = do
      bindings <- fields names parameters (dataKeys variant) variant
      let decoded i local = D.text (local ++ ".decode(data.fields().get(" ++ show i ++ "))")
          payload = [if existentialField variant field then call "LawSpecSchema.cast" [decoded i local] else decoded i local
            | (i,((local,_,_),field)) <- zip [0::Int ..] (zip bindings (C.constructorFields variant))] ++
            [decoded i local | (i,(local,_,_)) <- drop (length (C.constructorFields variant)) (zip [0::Int ..] bindings)]
          constructor = if gadtVariant variant
            then constructorName dataOwner variant ++ (if ownCount variant > 0 then "[" ++ intercalate ", " (replicate (ownCount variant) "Any") ++ "]" else "")
            else D.render D.Compact (applied (constructorName dataOwner variant) [D.text t | (_,(t,_)) <- parameters, not (generatedObject variant)])
          built = if unitConstructor variant then D.text (constructorName dataOwner variant) else call constructor payload
      -- A refined case extends its refined enum type; the schema has already
      -- checked it builds this type.
      pure (D.text ("case " ++ scalaQuoted (C.idText (C.constructorId variant)) ++ " => ") <>
        D.block 2 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++
          [if gadtVariant variant
             then call ("LawSpecSchema.cast[" ++ D.render D.Compact (applied ("lawspec.data." ++ dataOwner) [D.text t | (_,(t,_)) <- parameters]) ++ "]") [built]
             else built])))
    gadtVariant variant = not (null (C.constructorEquations variant)) || not (null (C.constructorExistentials variant))
    existentialField variant field = any (`elem` C.constructorExistentials variant) (typeVariablesIn (C.binderType field))
    ownCount variant = case declarationOf variant of
      Just d | gadtVariant variant -> length [p | p <- C.dataParameters d, p `notElem` map fst (C.constructorEquations variant)]
        + length [e | e <- C.constructorExistentials variant, e `notElem` freeExistentials d variant]
             | otherwise -> length (C.dataParameters d)
      Nothing -> 0

typeVariablesIn :: C.Type -> [C.Id]
typeVariablesIn ty = case ty of
  C.TypeVariable v -> [v]
  C.Constructor _ arguments -> concat [typeVariablesIn t | C.TypeArgument t <- arguments]
  C.Arrow a b -> typeVariablesIn a ++ typeVariablesIn b

-- | The runtime validates values against a schema reference built from the type.
scalaTypeReference :: C.Type -> Either String String
scalaTypeReference ty = D.render D.Compact <$> referenceDoc [] ty

-- | Values of these types need the runtime's schema to cross the adapter
-- boundary; plain scalars do not.
requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name args -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\arg -> case arg of C.TypeArgument value -> requiresSchema declarations value; _ -> False) args
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

-- | As scalaTypeReference, as a document.
scalaTypeReferenceDoc :: C.Type -> Either String D.Doc
scalaTypeReferenceDoc = referenceDoc []

-- | Built-in collections and durations are Scala's own types, not generated ones.
builtinFree :: C.DataDeclaration -> Bool
builtinFree d = collectionContainer (C.idText (C.dataId d)) == Nothing && not (isDurationType (C.idText (C.dataId d)))
