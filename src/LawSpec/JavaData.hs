-- Native data declarations follow the resolved-plan/renderer separation used
-- by Go+. Public fields retain native types; runtime Value is only the bridge
-- for primitive domains with no faithful Java representation.
module LawSpec.JavaData (schemaSource, emitJavaData, emitJavaDataWithProfile, emitJavaSchema, javaDataType, javaCodec, javaTypeReference, javaDataKey, javaDataTypeDoc, javaCodecDoc, javaCodecDocWithContext, javaDataName, identifier) where

import LawSpec.DataNames (qualifiedDataName)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub)
import Numeric (showHex)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as Schema
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.JavaExpr (javaDataKey)
import qualified LawSpec.JavaExpr as E
import LawSpec.Core.Total (constructorProofContracts)
import Data.Aeson (encode)
import qualified Data.Text.Lazy as Text
import qualified Data.Text.Lazy.Encoding as Text
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Common (Artifact(..))
import LawSpec.Scalar (nativeRepresentation, primitive)
import qualified LawSpec.Code.Doc as D

type Names = [(String, String)]

-- Plan names across the complete declaration set before emitting recursive
-- references, as Go+ does. Qualify only ambiguous short names. If qualification
-- itself collides, a lossless identity suffix handles case-insensitive paths.
namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let sourceNames = [(C.idText (C.dataId d), C.dataName d) | d <- declarations]
      duplicated name candidates = length (filter ((== map toLower name) . map toLower . snd) candidates) > 1
      qualified = [(identity, if duplicated name sourceNames then qualifiedDataName identity else name)
        | (identity,name) <- sourceNames]
      names = [(identity, if duplicated name qualified then name ++ "_" ++ encodeIdentity identity else name)
        | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names)))
    (Left "Java data declarations have conflicting identities")
  pure names
  where
    encodeIdentity = concatMap (\c -> showHex (ord c) "_")

nativeName :: Names -> C.DataDeclaration -> String
nativeName names declaration = case lookup (C.idText (C.dataId declaration)) names of
  Just name -> name
  Nothing -> error "unplanned Java data declaration"

identifier :: String -> Either String ()
identifier name = unless (valid && name `notElem` keywords)
  (Left ("invalid Java data identifier: " ++ name))
  where
    valid = case name of
      [] -> False
      first:rest -> isAscii first && (isLetter first || first == '_') &&
        all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest
    keywords = words "_ abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null record sealed permits var yield"

javaDataType :: [C.DataDeclaration] -> C.Type -> Either String String
javaDataType declarations ty = D.render (D.Pretty 100) <$> javaDataTypeDoc declarations ty

javaDataName :: [C.DataDeclaration] -> C.Id -> Either String String
javaDataName declarations identity = do
  names <- namesFor declarations
  maybe (Left "unknown Java data identity") (Right . ("lawspec.data." ++))
    (lookup (C.idText identity) names)

javaDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
javaDataTypeDoc declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDoc names [] ty

typeDoc :: Names -> [(C.Id, String)] -> C.Type -> Either String D.Doc
typeDoc names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Java data parameter")
    (Right . D.text) (lookup variable parameters)
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup name names of
      Just native -> pure (applied ("lawspec.data." ++ native) args)
      Nothing -> case (name, args) of
        ("List", [_]) -> pure (applied "java.util.List" args)
        ("Maybe", [_]) -> pure (applied "lawspec.runtime.LawSpecRuntime.Maybe" args)
        ("Either", [_, _]) -> pure (applied "lawspec.runtime.LawSpecRuntime.Either" args)
        ("Nullable", [_]) -> pure support
        ("Optional", [_]) -> pure support
        (_, []) | Just _ <- primitive name -> pure (D.text
          (boxed (maybe "lawspec.runtime.LawSpecRuntime.Value" id
            (nativeRepresentation "java" name))))
        _ -> Left ("no Java data representation for " ++ show ty)
  _ -> Left ("no Java data representation for " ++ show ty)
  where
    support = D.text "lawspec.runtime.LawSpecRuntime.Value"
    argument (C.TypeArgument t) = typeDoc names parameters t
    argument _ = Left "indexed Java data is not supported"
    boxed value = case value of
      "byte" -> "java.lang.Byte"
      "short" -> "java.lang.Short"
      "int" -> "java.lang.Integer"
      "long" -> "java.lang.Long"
      "float" -> "java.lang.Float"
      "double" -> "java.lang.Double"
      "char" -> "java.lang.Character"
      "boolean" -> "java.lang.Boolean"
      "String" -> "java.lang.String"
      "Number" -> "java.lang.Number"
      "void" -> "lawspec.runtime.LawSpecRuntime.Value"
      _ -> value

applied :: String -> [D.Doc] -> D.Doc
applied name [] = D.text name
applied name arguments = D.group $ D.text (name ++ "<") <>
  D.nest 8 (D.softbreak <> D.group (D.commaSep arguments)) <> D.text ">"

emitJavaData :: D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitJavaData = emitJavaDataWithProfile 64

emitJavaDataWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitJavaDataWithProfile bits layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  native <- mapM (definition names) declarations
  schema <- emitJavaSchema bits layout declarations
  codecs <- codecSource layout names declarations
  pure (native ++
    [Artifact "src/main/java/lawspec/runtime/LawSpecDataCodecs.java" codecs "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecDataSchema.java"
      schema "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecSchema.java"
      (runtimeSource "java-schema") "generated" "source"])
  where
    definition names declaration = do
      let name = nativeName names declaration
          parameters = zip (C.dataParameters declaration)
            [candidate | n <- [0 :: Int ..], let candidate = "T" ++ show n,
              candidate /= name]
          args = map (D.text . snd) parameters
          variants = C.dataConstructors declaration
          variantName value = C.constructorName value ++ "Case"
      mapM_ (identifier . variantName) variants
      -- Empty types still need a legal Java declaration. No implementation is
      -- exposed; the private constructor prevents manufacturing inhabitants.
      body <- if null variants then pure (D.text ("private " ++ name ++ "() {}"))
        else D.joinWith (D.hardline <> D.hardline) <$> mapM
          (variant names parameters name args . (\v -> (variantName v, v))) variants
      let header = if null variants then D.text "public final class " <> applied name args
            else D.text "public sealed interface " <> applied name args <>
              D.text " permits " <> D.commaSep
                [D.text (name ++ "." ++ variantName v) | v <- variants]
          source = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "package lawspec.data;" <> D.hardline <> D.hardline <>
            D.group header <> D.text " " <> D.block 2 body <> D.hardline
      pure (Artifact ("src/main/java/lawspec/data/" ++ name ++ ".java")
        (D.render layout source) "generated" "source")
    variant names parameters owner args (name, value) = do
      fieldDocs <- mapM (\field -> do
        identifier (C.binderName field)
        ty <- typeDoc names parameters (C.binderType field)
        pure (C.binderName field, ty)) (C.constructorFields value)
      let fields = [D.group (D.text "public final " <> ty <>
            D.nest 4 (D.softline <> D.text (field ++ ";")))
            | (field, ty) <- fieldDocs]
          signature = D.group $ D.text ("public " ++ name ++ "(") <>
            D.nest 4 (D.softbreak <> D.group (D.commaSep
              [D.group (ty <> D.nest 4 (D.softline <> D.text field))
                | (field, ty) <- fieldDocs])) <> D.text ")"
          assignments = [D.text ("this." ++ field ++ " = " ++ field ++ ";")
            | (field, _) <- fieldDocs]
          constructor = signature <> D.text " " <>
            (if null assignments then D.text "{}" else D.block 2 (D.joinWith D.hardline assignments))
          body = D.joinWith D.hardline fields <>
            (if null fields then mempty else D.hardline <> D.hardline) <> constructor
      pure (D.text "final class " <> applied name args <> D.text " implements " <>
        applied owner args <> D.text " " <> D.block 2 body)

-- The same structural schema is consumed by Rust and Java. This renderer never
-- reparses a pretty-printed type or reconstructs generic arguments from text.
schemaSource :: D.Layout -> [Schema.DataSchema] -> String
schemaSource layout = renderSchema layout [] []

-- Callback emission is profile-aware and consumes audited typed Core contracts.
emitJavaSchema :: Int -> D.Layout -> [C.DataDeclaration] -> Either String String
emitJavaSchema bits layout declarations = do
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas,contracts) <- Schema.dataSchemasWithContracts declarations
  let entries = zip [0 :: Int ..] [(contract,predicate) | contract <- contracts,
        predicate <- Schema.contractPredicates contract]
      name index = "fieldPredicate" ++ show index
      bindings = [(Schema.contractTag contract,name index) | (index,(contract,_)) <- entries]
  callbacks <- forM entries $ \(index,(contract,predicate)) -> do
    let fields = zip (map C.binderId (Schema.contractFields contract))
          ["_fields.get(" ++ show i ++ ")" | i <- [0 :: Int ..]]
        nested = zip (nub (nestedIds predicate)) ["_local" ++ show i | i <- [0 :: Int ..]]
        local identity = maybe "_invalid_field" id (lookup identity (fields ++ nested))
        reference ty = do
          ref <- renderReference <$> Schema.typeReference (Schema.contractParameters contract) ty
          pure (if variable ty then D.group (D.text "(LawSpecSchema.Named)" <>
            D.nest 4 (D.softline <> E.call "_schema.substitute" [ref,D.text "_types"])) else ref)
        key ty | variable ty = E.call "LawSpecSchema.key" . pure <$> reference ty
               | otherwise = pure (E.quoted (javaDataKey ty))
    body <- E.renderExpressionWithContext declarations (D.text "bits") reference key local
      (\_ _ -> Left "external call in constructor predicate") predicate
    pure (D.text ("private static boolean " ++ name index ++ "(") <>
      D.nest 4 (D.softbreak <> D.group (D.commaSep (map D.text
        ["LawSpecSchema _schema", "List<LawSpecSchema.TypeRef> _types", "List<Value> _fields",
         "int bits", "java.util.Map<String, Object> symbols"]))) <> D.text ") " <>
      D.block 2 (D.text "return " <> E.call "LawSpecRuntime.truth" [body] <> D.text ";"))
  pure (renderSchema layout callbacks bindings schemas)
  where
    nestedIds term = (case C.expressionNode term of
      C.AllElements _ binder _ -> [C.binderId binder]
      C.AllPayloads _ predicates -> map (C.binderId . fst) predicates
      C.Match _ branches -> concatMap (map C.binderId . C.caseBinders) branches
      _ -> []) ++ concatMap nestedIds (C.children term)
    variable (C.TypeVariable _) = True
    variable (C.Constructor _ args) = any (\arg -> case arg of C.TypeArgument ty -> variable ty; _ -> False) args
    variable (C.Arrow a b) = variable a || variable b
    renderReference (Schema.Parameter index) = E.call "new LawSpecSchema.Parameter" [D.text (show index)]
    renderReference (Schema.Named name args) = E.call "new LawSpecSchema.Named"
      (E.quoted name : map renderReference args)

renderSchema :: D.Layout -> [D.Doc] -> [(String,String)] -> [Schema.DataSchema] -> String
renderSchema layout callbacks bindings schemas = D.render layout $
  D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
  D.text "package lawspec.runtime;" <> D.hardline <> D.hardline <>
  D.joinWith D.hardline (map D.text
    (["import java.util.List;"] ++
     ["import lawspec.runtime.LawSpecRuntime.Value;" | not (null callbacks)] ++
     ["import lawspec.runtime.LawSpecSchema.Constructor;" | not (null allConstructors)] ++
     ["import lawspec.runtime.LawSpecSchema.Definition;" | not (null schemas)] ++
     ["import lawspec.runtime.LawSpecSchema.Field;" | not (null allFields)] ++
     ["import lawspec.runtime.LawSpecSchema.Named;" | any hasNamed allTypes] ++
     ["import lawspec.runtime.LawSpecSchema.Parameter;" | any hasParameter allTypes])) <>
  D.hardline <> D.hardline <> D.text "public final class LawSpecDataSchema " <>
  D.block 2 (D.text "private LawSpecDataSchema() {}" <> D.hardline <> D.hardline <>
    mconcat [callback <> D.hardline <> D.hardline | callback <- callbacks] <>
    D.text "public static LawSpecSchema create() " <> D.block 2
      (D.text "return " <> call "new LawSpecSchema" [list (map definition schemas)] <> D.text ";")) <>
  D.hardline
  where
    allConstructors = concatMap Schema.constructors schemas
    allFields = concatMap Schema.fields allConstructors
    allTypes = map Schema.fieldType allFields
    hasNamed (Schema.Named _ _) = True
    hasNamed _ = False
    hasParameter (Schema.Parameter _) = True
    hasParameter (Schema.Named _ args) = any hasParameter args
    quoted = D.text . Text.unpack . Text.decodeUtf8 . encode
    list = call "List.of"
    call name args = D.group $ D.text (name ++ "(") <>
      D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")"
    definition value = call "new Definition"
      [quoted (Schema.typeName value), D.text (show (Schema.parameterCount value)),
       list (map constructor (Schema.constructors value))]
    constructor value = call "new Constructor"
      ([quoted (Schema.constructorTag value), list (map field (Schema.fields value))] ++
       [list [D.text ("LawSpecDataSchema::" ++ name) | (tag,name) <- bindings,
          tag == Schema.constructorTag value] | any ((== Schema.constructorTag value) . fst) bindings])
    field value = call "new Field" [quoted (Schema.fieldName value), reference (Schema.fieldType value)]
    reference (Schema.Parameter index) = call "new Parameter" [D.text (show index)]
    reference (Schema.Named name arguments) = call "new Named" (quoted name : map reference arguments)

codecName :: String -> String
codecName [] = "dataCodec"
codecName (first:rest) = toLower first : rest ++ "Codec"

codecSource :: D.Layout -> Names -> [C.DataDeclaration] -> Either String String
codecSource layout names declarations = do
  methods <- mapM definition declarations
  pure $ D.render layout $ D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "package lawspec.runtime;" <> D.hardline <> D.hardline <>
    (if null declarations then mempty else
    D.text "import java.util.List;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecRuntime.Data;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Codec;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Named;" <> D.hardline <> D.hardline) <>
    D.text "public final class LawSpecDataCodecs " <>
    D.block 2 (D.joinWith (D.hardline <> D.hardline)
      (D.text "private LawSpecDataCodecs() {}" : methods)) <> D.hardline
  where
    quoted = D.text . Text.unpack . Text.decodeUtf8 . encode
    call name args = D.group $ D.text (name ++ "(") <>
      D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")"
    variable parameters v = maybe (Left "unbound Java codec parameter") Right (lookup v parameters)
    reference parameters ty = case ty of
      C.TypeVariable v -> (D.text . (++ ".type()") . snd) <$> variable parameters v
      C.Constructor name args -> call "new Named" . (quoted name :) <$> mapM (argument (reference parameters)) args
      _ -> Left "function fields cannot cross a data codec"
    argument f (C.TypeArgument t) = f t
    argument _ _ = Left "indexed Java data codec is not supported"
    codec parameters ty = case ty of
      C.TypeVariable v -> (D.text . snd) <$> variable parameters v
      C.Constructor name args -> do
        children <- mapM (argument (codec parameters)) args
        case lookup name names of
          Just native -> pure (call (codecName native) (D.text "schema" : D.text "bits" : D.text "symbols" : children))
          Nothing | name `elem` ["List", "Maybe", "Either"] ->
            pure (call ("schema." ++ map toLower name) (children ++ [D.text "bits",D.text "symbols"]))
          Nothing | name `elem` ["Nullable", "Optional", "Unit"] || nativeRepresentation "java" name == Nothing -> do
            ref <- reference parameters ty
            pure (call "schema.supported" [ref, D.text "bits",D.text "symbols"])
          Nothing -> do
            native <- typeDoc names [] ty
            pure (call "schema.scalar" [quoted name, D.text "bits", native <> D.text ".class"])
      _ -> Left "function fields cannot cross a data codec"
    definition declaration = do
      let parameters = zip (C.dataParameters declaration)
            [("T" ++ show i, "type" ++ show i) | i <- [0::Int ..]]
          typeParams = [(v,t) | (v,(t,_)) <- parameters]
          args = [D.text t | (_, (t,_)) <- parameters]
          native = applied ("lawspec.data." ++ nativeName names declaration) args
          typeArguments = [C.TypeArgument (C.TypeVariable v) | (v,_) <- parameters]
          method = codecName (nativeName names declaration)
          generics = if null args then mempty else applied "" args <> D.text " "
          signature contexts = D.group $ D.text ("public static " ++ D.render D.Compact (generics <> applied "Codec" [native])) <>
            D.text " " <> call method
              ([D.text "LawSpecSchema schema", D.text "int bits"] ++ contexts ++
                [applied "Codec" [D.text t] <> D.text (" " ++ v) | (_,(t,v)) <- parameters])
      ref <- reference parameters (C.Constructor (C.idText (C.dataId declaration)) typeArguments)
      encodeArms <- mapM (encodeArm parameters args) (C.dataConstructors declaration)
      decodeArms <- mapM (decodeArm parameters) (C.dataConstructors declaration)
      let failure = D.text "throw new IllegalArgumentException(\"uninhabited or invalid native data\");"
          encoder = if null encodeArms then D.text "value -> " <> D.block 2 failure
            else D.text "value ->" <> D.nest 4 (D.hardline <>
              D.text "switch (value) " <> D.block 2 (D.joinWith D.hardline encodeArms))
          decoder = if null decodeArms then D.text "value -> " <> D.block 2 failure
            else D.text "value -> " <> D.block 2
            (D.text "var data = (Data) value.data();" <> D.hardline <>
             D.text "return switch (data.tag()) " <> D.block 2 (D.joinWith D.hardline
               (decodeArms ++ [D.text "default -> " <> failure])) <> D.text ";")
          body = D.text "var type = " <> ref <> D.text ";" <> D.hardline <>
            D.text "return schema.codec(" <> D.nest 4
              (D.hardline <> D.joinWith (D.text "," <> D.hardline)
                [D.text "type", D.text "bits", D.text "symbols", encoder, decoder]) <> D.text ");"
      -- Keep the parameter scope in the type renderer independent of value names.
      _ <- typeDoc names typeParams (C.Constructor (C.idText (C.dataId declaration)) typeArguments)
      let forward = call method ([D.text "schema",D.text "bits",D.text "new java.util.HashMap<>()"] ++
            [D.text v | (_,(_,v)) <- parameters])
      pure (signature [] <> D.text " " <> D.block 2 (D.text "return " <> forward <> D.text ";") <>
        D.hardline <> D.hardline <>
        signature [D.text "java.util.Map<String, Object> symbols"] <> D.text " " <> D.block 2 body)
      where
        variantName value = "lawspec.data." ++ nativeName names declaration ++ "." ++ C.constructorName value ++ "Case"
        fieldBindings parameters value = mapM (\(i,field) -> do
          bridge <- codec parameters (C.binderType field)
          pure ("field" ++ show i, C.binderName field,
            D.group (D.text ("var field" ++ show i ++ " =") <>
              D.nest 4 (D.softline <> bridge) <> D.text ";")))
          (zip [0::Int ..] (C.constructorFields value))
        encodeArm parameters args value = do
          bindings <- fieldBindings parameters value
          let fields = [call "LawSpecSchema.encodeField"
                [D.text name, D.text ("item." ++ field), quoted (C.idText (C.constructorId value) ++ "." ++ field)]
                | (name,field,_) <- bindings]
              result = D.text "yield " <> call "schema.construct"
                [D.text "type", quoted (C.idText (C.constructorId value)), call "List.of" fields, D.text "bits",D.text "symbols"] <> D.text ";"
          pure (D.text "case " <> applied (variantName value) args <> D.text " item -> " <>
            D.block 2 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [result])))
        decodeArm parameters value = do
          bindings <- fieldBindings parameters value
          let fields = [D.text (name ++ ".decode(data.fields().get(" ++ show i ++ "))")
                | (i,(name,_,_)) <- zip [0::Int ..] bindings]
              result = D.text "yield " <>
                call ("new " ++ variantName value ++ if null parameters then "" else "<>") fields <> D.text ";"
          pure (D.text "case " <> quoted (C.idText (C.constructorId value)) <> D.text " -> " <>
            D.block 2 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [result])))

javaTypeReference :: C.Type -> Either String String
javaTypeReference ty = render <$> Schema.typeReference [] ty
  where
    quoted = Text.unpack . Text.decodeUtf8 . encode
    render (Schema.Parameter _) = error "unbound concrete Java type"
    render (Schema.Named name args) = "new lawspec.runtime.LawSpecSchema.Named(" ++
      quoted name ++ concatMap ((", " ++) . render) args ++ ")"

javaCodec :: [C.DataDeclaration] -> Int -> C.Type -> Either String String
javaCodec declarations bits ty = do
  names <- namesFor declarations
  let go value@(C.Constructor name args) = do
        children <- mapM (\a -> case a of C.TypeArgument t -> go t; _ -> Left "indexed codec") args
        case lookup name names of
          Just native -> pure (invoke ("lawspec.runtime.LawSpecDataCodecs." ++ codecName native)
            ("_schema" : show bits : children))
          Nothing | name `elem` ["List", "Maybe", "Either"] -> pure
            (invoke ("_schema." ++ map toLower name) (children ++ [show bits]))
          Nothing | name `elem` ["Nullable", "Optional", "Unit"] || nativeRepresentation "java" name == Nothing -> do
            ref <- javaTypeReference value
            pure (invoke "_schema.supported" [ref, show bits])
          Nothing -> do
            native <- javaDataType declarations value
            pure (invoke "_schema.scalar" [quoted name, show bits, native ++ ".class"])
      go _ = Left "non-concrete native data codec"
  go ty
  where
    quoted = Text.unpack . Text.decodeUtf8 . encode
    invoke name args = name ++ "(" ++ concat (zipWith (++) ("" : repeat ", ") args) ++ ")"

-- A structured counterpart for source emitters; the existing string API remains
-- available to legacy property wrappers.
javaCodecDoc :: [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDoc = javaCodecDocUsing Nothing

javaCodecDocWithContext :: D.Doc -> [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDocWithContext symbols = javaCodecDocUsing (Just symbols)

javaCodecDocUsing :: Maybe D.Doc -> [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDocUsing context declarations bits ty = do
  names <- namesFor declarations
  let symbols = maybe [] pure context
      go value@(C.Constructor name args) = do
        children <- mapM (\a -> case a of C.TypeArgument t -> go t; _ -> Left "indexed codec") args
        case lookup name names of
          Just native -> pure (invoke ("lawspec.runtime.LawSpecDataCodecs." ++ codecName native)
            ([D.text "_schema", D.text (show bits)] ++ symbols ++ children))
          Nothing | name `elem` ["List", "Maybe", "Either"] ->
            pure (invoke ("_schema." ++ map toLower name) (children ++ [D.text (show bits)] ++ symbols))
          Nothing | name `elem` ["Nullable", "Optional", "Unit"] || nativeRepresentation "java" name == Nothing -> do
            ref <- reference value
            pure (invoke "_schema.supported" ([ref,D.text (show bits)] ++ symbols))
          Nothing -> do
            native <- typeDoc names [] value
            pure (invoke "_schema.scalar" [quoted name,D.text (show bits),native <> D.text ".class"])
      go _ = Left "non-concrete native data codec"
      reference (C.Constructor name args) = invoke "new lawspec.runtime.LawSpecSchema.Named" . (quoted name :) <$>
        mapM (\a -> case a of C.TypeArgument t -> reference t; _ -> Left "indexed codec") args
      reference _ = Left "non-concrete codec reference"
  go ty
  where
    quoted = D.text . Text.unpack . Text.decodeUtf8 . encode
    invoke name args = D.group (D.text (name ++ "(") <>
      D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")")
