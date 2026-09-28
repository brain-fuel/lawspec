-- Native JVM declarations from checked Core; no surface syntax or inference.
module LawSpec.KotlinData (emitKotlinData, emitKotlinDataWithProfile, kotlinCodecDocWithContext, kotlinDataType, emitKotlinCodecs, kotlinCodec, kotlinTypeReference, requiresSchema, kotlinDataTypeDoc, kotlinCodecDoc, kotlinTypeReferenceDoc) where

import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toUpper, toLower, ord)
import Data.List (nub)
import Numeric (showHex)
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Common (Artifact(..))
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.JavaData as JVM
import qualified LawSpec.Code.Doc as D

type Names = [(C.Id, String)]

identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid Kotlin data identifier: " ++ name))
  where
    valid = case name of
      first:rest -> isAscii first && isLetter first &&
        all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest &&
        name `notElem` words "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while"
      [] -> False

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let source = [(C.dataId d, C.dataName d) | d <- declarations]
      duplicated name entries = length (filter ((== map toLower name) . map toLower . snd) entries) > 1
      qualified = [(identity, if duplicated name source then qualify (C.idText identity) else name)
        | (identity,name) <- source]
      names = [(identity, if duplicated name qualified
        then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity)
        else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names)))
    (Left "conflicting Kotlin data identities")
  pure names
  where
    qualify = concatMap capitalize . words . map (\c -> if isAlphaNum c then c else ' ')
    capitalize [] = []
    capitalize (c:cs) = toUpper c : cs

applied :: String -> [D.Doc] -> D.Doc
applied name [] = D.text name
applied name args = D.group (D.text (name ++ "<") <>
  D.nest 4 (D.softbreak <> D.commaSep args) <> D.text ">")

typeDoc :: Names -> [(C.Id, String)] -> C.Type -> Either String D.Doc
typeDoc names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Kotlin data parameter")
    (Right . D.text) (lookup variable parameters)
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (applied ("lawspec.data." ++ native) args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (applied "kotlin.collections.List" args)
        ("Maybe",[_]) -> pure (applied "lawspec.runtime.LawSpecRuntime.Maybe" args)
        ("Either",[_,_]) -> pure (applied "lawspec.runtime.LawSpecRuntime.Either" args)
        ("Nullable",[_]) -> pure (applied "lawspec.runtime.LawSpecKotlin.Nullable" args)
        ("Optional",[_]) -> pure (applied "lawspec.runtime.LawSpecKotlin.Optional" args)
        (_,[]) -> maybe (Left ("no Kotlin data representation for " ++ name))
          (Right . D.text . qualifyScalar) (lookup name scalars)
        _ -> Left ("no Kotlin data representation for " ++ show ty)
  _ -> Left ("no Kotlin data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeDoc names parameters value
    argument _ = Left "indexed Kotlin data is not supported"
    qualifyScalar native = if '.' `elem` native then native else "kotlin." ++ native
    scalars = [("Bool","Boolean"),("Int8","Byte"),("Int16","Short"),
      ("Int32","Int"),("Int64","Long"),("UInt8","Short"),("UInt16","Int"),
      ("UInt32","Long"),("Float32","Float"),("Float64","Double"),
      ("Decimal","java.math.BigDecimal"),("Rational","lawspec.runtime.LawSpecRuntime.Ratio"),
      ("Complex64","lawspec.runtime.LawSpecRuntime.Complex"),
      ("Complex128","lawspec.runtime.LawSpecRuntime.Complex"),
      ("Char","String"),("CodePoint","Int"),("CodeUnit16","Char"),
      ("Text","String"),("Utf16Text","String"),("CodePointText","IntArray"),
      ("Bytes","ByteArray"),("Symbol","lawspec.runtime.LawSpecKotlin.Symbol"),
      ("Unit","Unit"),("Null","lawspec.runtime.LawSpecKotlin.Null"),
      ("Undefined","lawspec.runtime.LawSpecKotlin.Undefined")] ++
      [(name,"java.math.BigInteger") | name <-
        ["Integer","BigInt","BigUInt","UInt64","IntSize","UIntSize","UIntPtr"]]

kotlinDataType :: [C.DataDeclaration] -> C.Type -> Either String String
kotlinDataType declarations ty = D.render D.Compact <$> kotlinDataTypeDoc declarations ty

kotlinDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
kotlinDataTypeDoc declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDoc names [] ty

emitKotlinData :: D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitKotlinData = emitKotlinDataWithProfile 64

emitKotlinDataWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitKotlinDataWithProfile bits layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  schema <- JVM.emitJavaSchema bits (D.Pretty 100) declarations
  codecs <- emitKotlinCodecs layout declarations
  native <- forM declarations $ \declaration -> do
    name <- maybe (Left "unplanned Kotlin data name") Right (lookup (C.dataId declaration) names)
    let parameters = zip (C.dataParameters declaration) [candidate | i <- [0::Int ..], let candidate = "T" ++ show i, candidate /= name]
        arguments = map (D.text . snd) parameters
        variants = C.dataConstructors declaration
    body <- forM variants $ \variant -> do
      let constructor = C.constructorName variant ++ "Case"
      identifier constructor
      fields <- forM (C.constructorFields variant) $ \field -> do
        identifier (C.binderName field)
        ty <- typeDoc names parameters (C.binderType field)
        pure (D.text ("val " ++ C.binderName field ++ ": ") <> ty)
      let signature = D.group (D.text "class " <> applied constructor arguments <>
            (if null fields then mempty else D.text "(" <>
              D.nest 4 (D.softbreak <> D.commaSep fields) <> D.text ")") <>
            D.text " : " <> applied ("lawspec.data." ++ name) arguments)
      pure signature
    let declarationDoc = if null variants
          then D.text "class " <> applied name arguments <> D.text " private constructor()"
          else D.text "sealed interface " <> applied name arguments <> D.text " " <>
            D.block 4 (D.joinWith (D.hardline <> D.hardline) body)
        source = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "package lawspec.data" <> D.hardline <> D.hardline <>
          declarationDoc <> D.hardline
    pure (Artifact ("src/main/kotlin/lawspec/data/" ++ name ++ ".kt")
      (D.render layout source) "generated" "source")
  pure (native ++
    [Artifact "src/main/kotlin/lawspec/runtime/LawSpecDataCodecs.kt" codecs "generated" "source",
     Artifact "src/main/kotlin/lawspec/runtime/LawSpecKotlinCodecs.kt"
      (runtimeSource "kotlin-codecs") "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecDataSchema.java"
      schema "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecSchema.java"
      (runtimeSource "java-schema") "generated" "source",
     Artifact "src/main/kotlin/lawspec/runtime/LawSpecKotlin.kt"
      (runtimeSource "kotlin-native") "generated" "source"])

quoted :: String -> D.Doc
quoted = D.text . concatMap escapeDollar . T.unpack . T.decodeUtf8 . encode
  where
    escapeDollar '$' = "\\$"
    escapeDollar c = [c]

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 4 "(" ")" args

codecName :: String -> String
codecName [] = "dataCodec"
codecName (c:cs) = toLower c : cs ++ "Codec"

referenceDoc :: [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
referenceDoc parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Kotlin codec parameter")
    (Right . D.text . (++ ".type()") . snd) (lookup variable parameters)
  C.Constructor name args -> call "LawSpecSchema.Named" . (quoted name :) <$>
    mapM (argument (referenceDoc parameters)) args
  _ -> Left "function fields cannot cross Kotlin codecs"

argument :: (C.Type -> Either String a) -> C.Argument -> Either String a
argument f (C.TypeArgument ty) = f ty
argument _ _ = Left "indexed Kotlin codec is not supported"

codecDoc :: Names -> [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
codecDoc = codecDocUsing Nothing

codecDocUsing :: Maybe D.Doc -> Names -> [(C.Id, (String, String))] -> C.Type -> Either String D.Doc
codecDocUsing context names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Kotlin codec parameter")
    (Right . D.text . snd) (lookup variable parameters)
  C.Constructor name args -> do
    children <- mapM (argument (codecDocUsing context names parameters)) args
    case lookup (C.Id name) names of
      Just native -> pure (call ("LawSpecDataCodecs." ++ codecName native)
        ([D.text "schema", D.text "bits"] ++ children ++ maybe [] pure context))
      Nothing | name `elem` ["List", "Maybe", "Either"] ->
        pure (call ("schema." ++ map toLower name) (children ++ [D.text "bits"] ++ maybe [] pure context))
      Nothing | name `elem` ["Nullable", "Optional"] ->
        pure (call ("LawSpecKotlinCodecs." ++ map toLower name)
          ([D.text "schema", D.text "bits"] ++ children ++ maybe [] pure context))
      Nothing | Just helper <- lookup name
        [("Unit","unit"),("Null","nullValue"),("Undefined","undefined"),
         ("Symbol","symbol"),("CodePointText","codePointText")] ->
        pure (call ("LawSpecKotlinCodecs." ++ helper) [D.text "schema", D.text "bits"])
      Nothing -> do
        native <- typeDoc names [] ty
        pure (call "schema.scalar" [quoted name, D.text "bits", D.group (native <> D.nest 4 (D.softbreak <> D.text "::class" <> D.softbreak <> D.text ".javaObjectType"))])
  _ -> Left "function fields cannot cross Kotlin codecs"

kotlinCodec :: [C.DataDeclaration] -> C.Type -> Either String String
kotlinCodec declarations ty = D.render D.Compact <$> kotlinCodecDoc declarations ty

kotlinCodecDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
kotlinCodecDoc declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  codecDoc names [] ty

kotlinCodecDocWithContext :: D.Doc -> [C.DataDeclaration] -> C.Type -> Either String D.Doc
kotlinCodecDocWithContext context declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  codecDocUsing (Just context) names [] ty

emitKotlinCodecs :: D.Layout -> [C.DataDeclaration] -> Either String String
emitKotlinCodecs layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  definitions <- mapM (definition names) declarations
  pure (D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "package lawspec.runtime" <> D.hardline <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Codec" <> D.hardline <> D.hardline <>
    D.text "object LawSpecDataCodecs " <>
    D.block 4 (D.joinWith (D.hardline <> D.hardline) definitions) <> D.hardline))
  where
    definition names declaration = do
      name <- maybe (Left "unplanned Kotlin codec") Right (lookup (C.dataId declaration) names)
      let parameters = zip (C.dataParameters declaration)
            [("T" ++ show i, "type" ++ show i) | i <- [0::Int ..]]
          native = applied ("lawspec.data." ++ name) [D.text t | (_,(t,_)) <- parameters]
          ty = C.Constructor (C.idText (C.dataId declaration))
            [C.TypeArgument (C.TypeVariable v) | (v,_) <- parameters]
          generic = if null parameters then mempty else
            D.text (D.render D.Compact (applied "" [D.text t | (_,(t,_)) <- parameters]) ++ " ")
          signature = D.group (D.text "fun " <> generic <>
            call (codecName name) ([D.text "schema: LawSpecSchema", D.text "bits: Int"] ++
              [D.text (v ++ ": ") <> applied "Codec" [D.text t] | (_,(t,v)) <- parameters] ++
              [D.text "symbols: MutableMap<String, Any> = mutableMapOf()"]) <>
            D.text ": " <> applied "Codec" [native])
      ref <- referenceDoc parameters ty
      encodeArms <- mapM (encodeArm names parameters name) (C.dataConstructors declaration)
      decodeArms <- mapM (decodeArm names parameters name) (C.dataConstructors declaration)
      let failure = D.text "throw IllegalArgumentException(\"uninhabited or invalid native data\")"
          encoder = D.text "{ value ->" <> D.nest 4 (D.hardline <>
            (if null encodeArms then failure else
              D.text "when (value) " <> D.block 4 (D.joinWith D.hardline encodeArms))) <>
            D.hardline <> D.text "}"
          decoder = D.text "{ value ->" <> D.nest 4 (D.hardline <>
            D.text "val data = value.data() as LawSpecRuntime.Data" <> D.hardline <>
            D.text "when (data.tag()) " <> D.block 4
              (D.joinWith D.hardline (decodeArms ++ [D.text "else -> " <> failure]))) <>
            D.hardline <> D.text "}"
          body = D.text "val type = " <> ref <> D.hardline <>
            D.text ("return schema.codec<" ++ D.render D.Compact native ++ ">(") <>
            D.nest 4 (D.hardline <> D.joinWith (D.text "," <> D.hardline)
              [D.text "type", D.text "bits", D.text "symbols", encoder, decoder] <> D.text ",") <>
            D.hardline <> D.text ")"
      pure (signature <> D.text " " <> D.block 4 body)
    fields names parameters variant = forM (zip [0::Int ..] (C.constructorFields variant)) $ \(i,field) -> do
      bridge <- codecDocUsing (Just (D.text "symbols")) names parameters (C.binderType field)
      pure ("field" ++ show i, C.binderName field,
        D.text ("val field" ++ show i ++ " = ") <> bridge)
    encodeArm names parameters owner variant = do
      bindings <- fields names parameters variant
      let payload = [call "LawSpecSchema.encodeField"
            [D.text local, D.text ("value." ++ field), quoted (C.idText (C.constructorId variant) ++ "." ++ field)]
            | (local,field,_) <- bindings]
      pure (D.text ("is lawspec.data." ++ owner ++ "." ++ C.constructorName variant ++ "Case -> ") <>
        D.block 4 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++
          [call "schema.construct" [D.text "type", quoted (C.idText (C.constructorId variant)),
            call "listOf" payload, D.text "bits", D.text "symbols"]])))
    decodeArm names parameters owner variant = do
      bindings <- fields names parameters variant
      let payload = [D.text (local ++ ".decode(data.fields()[" ++ show i ++ "])") |
            (i,(local,_,_)) <- zip [0::Int ..] bindings]
          constructor = D.render D.Compact (applied ("lawspec.data." ++ owner ++ "." ++
            C.constructorName variant ++ "Case") [D.text t | (_,(t,_)) <- parameters])
      pure (quoted (C.idText (C.constructorId variant)) <> D.text " -> " <>
        D.block 4 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [call constructor payload])))


kotlinTypeReference :: C.Type -> Either String String
kotlinTypeReference ty = D.render D.Compact <$> referenceDoc [] ty

requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name args -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\arg -> case arg of C.TypeArgument value -> requiresSchema declarations value; _ -> False) args
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

kotlinTypeReferenceDoc :: C.Type -> Either String D.Doc
kotlinTypeReferenceDoc = referenceDoc []
