-- | Native data declarations follow the resolved-plan/renderer separation used
-- by Go+. Public fields retain native types; runtime Value is only the bridge
-- for primitive domains with no faithful Java representation.
module LawSpec.JavaData (schemaSource, javaConstructorClass, emitJavaData, emitJavaDataWithProfile, emitJavaSchema, javaDataType, javaCodec, javaTypeReference, javaDataKey, javaDataTypeDoc, javaCodecDoc, javaCodecDocWithContext, javaDataName, identifier) where

import LawSpec.DataNames (qualifiedDataName, isProduct, caseNames, caseInsensitiveCounts, ambiguous)
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
import LawSpec.Core.Types (makeRegistry, checkType, freeExistentials)
import LawSpec.Collections (collectionContainer)
import LawSpec.Time (isDurationType)
import LawSpec.Common (Artifact(..))
import LawSpec.Scalar (nativeRepresentation, primitive, primitives, primitiveName)
import qualified LawSpec.Code.Doc as D

type Names = [(String, String)]

-- | Plan names across the complete declaration set before emitting recursive
-- references, as Go+ does. Qualify only ambiguous short names. If qualification
-- itself collides, a lossless identity suffix handles case-insensitive paths.
namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let sourceNames = [(C.idText (C.dataId d), C.dataName d) | d <- declarations]
      sourceNamesCounts = caseInsensitiveCounts sourceNames
      qualifiedCounts = caseInsensitiveCounts qualified
      qualified = [(identity, if ambiguous sourceNamesCounts name then qualifiedDataName identity else name)
        | (identity,name) <- sourceNames]
      names = [(identity, if ambiguous qualifiedCounts name then name ++ "_" ++ encodeIdentity identity else name)
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

-- | A data name must be a valid Java identifier and not a keyword, or the
-- generated class would not compile.
identifier :: String -> Either String ()
identifier name = unless (valid && name `notElem` keywords)
  (Left ("invalid Java data identifier: " ++ name))
  where
    valid = case name of
      [] -> False
      first:rest -> isAscii first && (isLetter first || first == '_') &&
        all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest
    keywords = words "_ abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null record sealed permits var yield"

-- | Java output is laid out at 100 columns, as Google's Java style allows.
-- ref:google-style-guides
javaDataType :: [C.DataDeclaration] -> C.Type -> Either String String
javaDataType declarations ty = D.render (D.Pretty 100) <$> javaDataTypeDoc declarations ty

-- | Generated data classes live in the lawspec.data package, apart from user
-- code.
javaDataName :: [C.DataDeclaration] -> C.Id -> Either String String
javaDataName declarations identity = do
  names <- namesFor declarations
  maybe (Left "unknown Java data identity") (Right . ("lawspec.data." ++))
    (lookup (C.idText identity) names)

-- | Types are checked against the registry before rendering, so an unknown type
-- is a compiler error rather than uncompilable Java.
javaDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
javaDataTypeDoc declarations =
  -- The registry and the names depend only on the declarations: a caller
  -- that applies this to them once shares them across every type.
  let prepared = (,) <$> makeRegistry declarations <*> namesFor declarations
  in \ty -> do
  (registry, names) <- prepared
  checkType registry ty
  typeDoc (handlesOf declarations) names [] ty

-- | The identities of handle declarations: their values are adapters' native
-- objects, an Object in generated code.
-- Each handle, with its native type when its binding names it in full.
type Handles = [(String, Maybe String)]

handlesOf :: [C.DataDeclaration] -> Handles
handlesOf declarations = [(C.idText (C.dataId d), C.dataNative d) | d <- declarations, C.dataHandle d]

typeDoc :: Handles -> Names -> [(C.Id, String)] -> C.Type -> Either String D.Doc
typeDoc handles names parameters ty = case ty of
  C.Constructor name [] | Just native <- lookup name handles -> pure (D.text (maybe "java.lang.Object" id native))
  C.TypeVariable variable -> maybe (Left "unbound Java data parameter")
    (Right . D.text) (lookup variable parameters)
  -- A Duration is a java.time.Duration (LawSpecSchema's duration).
  C.Constructor name [] | isDurationType name -> pure (D.text "java.time.Duration")
  -- Built-in collections are native (LawSpecSchema's set, keyVal, sequence).
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    pure $ case short of
      "Set" -> applied "java.util.Set" args
      "KeyVal" -> applied "java.util.Map" args
      _ -> applied "java.util.ArrayDeque" args
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
    argument (C.TypeArgument t) = typeDoc handles names parameters t
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

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
emitJavaData :: D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitJavaData = emitJavaDataWithProfile 64

-- | LawSpec data become records and sealed interfaces of records, the shapes
-- modern Java uses. ref:DEC-idiomatic-generated-types
emitJavaDataWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String [Artifact]
emitJavaDataWithProfile bits layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  native <- mapM (definition names) [d | d <- declarations, builtinFree d, not (C.dataHandle d)]
  schema <- emitJavaSchema bits layout declarations
  codecs <- codecSource layout names declarations
  pure (native ++
    [Artifact "src/main/java/lawspec/runtime/LawSpecDataCodecs.java" codecs "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecDataSchema.java"
      schema "generated" "source",
     Artifact "src/main/java/lawspec/runtime/LawSpecSchema.java"
      (runtimeSource "java-schema") "generated" "source"])
  where
    -- A product is a record; a sum is a sealed interface of records, one per
    -- constructor, so adapters use accessors and exhaustive switches instead
    -- of casts.
    definition names declaration = do
      let name = nativeName names declaration
          parameters = zip (C.dataParameters declaration)
            [candidate | n <- [0 :: Int ..], let candidate = "T" ++ show n,
              candidate /= name]
          args = map (D.text . snd) parameters
          variants = C.dataConstructors declaration
          cases = caseNames name variants
          caseOf value = maybe (C.constructorName value) id (lookup (C.constructorId value) cases)
          file body = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "package lawspec.data;" <> D.hardline <> D.hardline <> body <> D.hardline
      source <- case variants of
        -- Empty types still need a legal Java declaration. No implementation is
        -- exposed; the private constructor prevents manufacturing inhabitants.
        [] -> pure (D.group (D.text "public final class " <> applied name args) <> D.text " " <>
          D.block 2 (D.text ("private " ++ name ++ "() {}")))
        [only] | isProduct declaration -> record names parameters ("public record " ++ name) args Nothing only
        _ -> do
          mapM_ (identifier . caseOf) variants
          body <- D.joinWith D.hardline <$> mapM (\v -> do
            -- A GADT case is generic in the parameters it leaves open and in
            -- its existentials, and implements the interface it refines to.
            -- A field-only existential is an Object; its witness names its type.
            let free = freeExistentials declaration v
                existentials = zip [e | e <- C.constructorExistentials v, e `notElem` free]
                  [candidate | n <- [0 :: Int ..], let candidate = "E" ++ show n, candidate /= name]
                scope = parameters ++ existentials
                equations = C.constructorEquations v
                own = if null equations && null existentials then args
                  else [D.text t | (p, t) <- parameters, p `notElem` map fst equations] ++ map (D.text . snd) existentials
            implemented <- mapM (\(p, t) -> maybe (pure (D.text t)) (typeDoc (handlesOf declarations) names scope) (lookup p equations)) parameters
            record names scope ("record " ++ caseOf v) own (Just (applied name implemented)) v) variants
          let header = D.text "public sealed interface " <> applied name args <>
                D.nest 4 (D.softline <> D.text "permits " <> D.nest 4 (D.commaSep [D.text (name ++ "." ++ caseOf v) | v <- variants]))
          pure (D.group header <> D.text " " <> D.block 2 body)
      pure (Artifact ("src/main/java/lawspec/data/" ++ name ++ ".java")
        (D.render layout (file source)) "generated" "source")
    record names scope keywordName args implements value = do
      let free = concat [freeExistentials d value | d <- declarations, value `elem` C.dataConstructors d]
          parameters = scope ++ [(e, "Object") | e <- free]
          witnesses = [D.text ("String " ++ Schema.witnessFieldName (length free) k) | k <- [0 .. length free - 1]]
      components <- (++ witnesses) <$> mapM (\field -> do
        identifier (C.binderName field)
        unless (C.binderName field `notElem` objectMethods)
          (Left ("Java record component " ++ C.binderName field ++ " of " ++ C.constructorName value ++
            " would override java.lang.Object." ++ C.binderName field ++ "(); rename the field"))
        ty <- typeDoc (handlesOf declarations) names parameters (C.binderType field)
        pure (D.group (ty <> D.nest 4 (D.softline <> D.text (C.binderName field))))) (C.constructorFields value)
      pure (D.group (D.text keywordName <> (if null args then mempty else applied "" args) <> D.text "(" <>
        D.nest 4 (D.softbreak <> D.group (D.commaSep components)) <> D.text ")" <>
        maybe mempty (\owner -> D.nest 4 (D.softline <> D.text "implements " <> owner)) implements) <> D.text " {}")
    objectMethods = ["hashCode", "toString", "equals", "getClass", "notify", "notifyAll", "wait", "clone", "finalize"]

-- | The class that holds one constructor's values: the record itself for a
-- product, or the sum's nested record.
javaConstructorClass :: [C.DataDeclaration] -> C.DataDeclaration -> C.DataConstructor -> Either String String
javaConstructorClass declarations declaration constructor = do
  names <- namesFor declarations
  pure (constructorClass names declaration constructor)

constructorClass :: Names -> C.DataDeclaration -> C.DataConstructor -> String
constructorClass names declaration constructor
  | isProduct declaration = "lawspec.data." ++ name
  | otherwise = "lawspec.data." ++ name ++ "." ++ maybe (C.constructorName constructor) id
      (lookup (C.constructorId constructor) (caseNames name (C.dataConstructors declaration)))
  where name = nativeName names declaration

-- | The same structural schema is consumed by Rust and Java. This renderer never
-- reparses a pretty-printed type or reconstructs generic arguments from text.
schemaSource :: D.Layout -> [Schema.DataSchema] -> String
schemaSource layout = renderSchema layout [] []

-- | Callback emission is profile-aware and consumes audited typed Core contracts.
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
  pure (renderSchemaWith (handlesOf declarations) layout callbacks bindings schemas)
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
renderSchema = renderSchemaWith []

renderSchemaWith :: Handles -> D.Layout -> [D.Doc] -> [(String,String)] -> [Schema.DataSchema] -> String
renderSchemaWith handles layout callbacks bindings schemas = D.render layout $
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
      ([quoted (Schema.typeName value), D.text (show (Schema.parameterCount value)),
        list (map constructor (Schema.constructors value))] ++
       [D.text "true" | Schema.typeName value `elem` map fst handles])
    constructor value = call "new Constructor"
      ([quoted (Schema.constructorTag value), list (map field (Schema.fields value))] ++
       [list [D.text ("LawSpecDataSchema::" ++ name) | (tag,name) <- bindings,
          tag == Schema.constructorTag value] | indexed value || refined value || any ((== Schema.constructorTag value) . fst) bindings] ++
       [list (map quoted (Schema.constructorIndex value)) | indexed value || refined value] ++
       concat [[list [call "new LawSpecSchema.Refinement" [D.text (show index), reference pattern]
                 | (index, pattern) <- Schema.constructorRefinements value],
                D.text (show (Schema.constructorExistentials value))] | refined value] ++
       [list (map (D.text . show) (Schema.constructorWitnesses value)) | not (null (Schema.constructorWitnesses value))])
    indexed value = not (null (Schema.constructorIndex value))
    refined value = not (null (Schema.constructorRefinements value)) || Schema.constructorExistentials value > 0
    field value = call "new Field" [quoted (Schema.fieldName value), reference (Schema.fieldType value)]
    reference (Schema.Parameter index) = call "new Parameter" [D.text (show index)]
    reference (Schema.Named name arguments) = call "new Named" (quoted name : map reference arguments)

-- | A built-in collection's codec: LawSpecSchema's set, keyVal or sequence.
collectionCodec :: (String -> [D.Doc] -> D.Doc) -> String -> String -> [D.Doc] -> [D.Doc] -> D.Doc
collectionCodec call schema short children rest = case short of
  "Set" -> call (schema ++ ".set") (children ++ rest)
  "KeyVal" -> call (schema ++ ".keyVal") (children ++ rest)
  _ -> call (schema ++ ".sequence") (D.text (show short) : children ++ rest)

codecName :: String -> String
codecName [] = "dataCodec"
codecName (first:rest) = toLower first : rest ++ "Codec"

codecSource :: D.Layout -> Names -> [C.DataDeclaration] -> Either String String
codecSource layout names declarations = do
  methods <- mapM definition [d | d <- declarations, builtinFree d]
  dynamicMethod <- if any existentialData declarations then (: []) <$> dynamicDispatch else pure []
  pure $ D.render layout $ D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "package lawspec.runtime;" <> D.hardline <> D.hardline <>
    (if null declarations then mempty else
    D.text "import java.util.List;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecRuntime.Data;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Codec;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecSchema.Named;" <> D.hardline <> D.hardline) <>
    D.text "public final class LawSpecDataCodecs " <>
    D.block 2 (D.joinWith (D.hardline <> D.hardline)
      (D.text "private LawSpecDataCodecs() {}" : methods ++ dynamicMethod)) <> D.hardline
  where
    existentialData declaration = any (not . null . C.constructorExistentials) (C.dataConstructors declaration)
    -- The native codec of any instantiated type, built at run time: a GADT
    -- case's existential fields learn their types from the value's own type.
    dynamicDispatch = do
      scalars <- fmap concat $ mapM (\p -> do
        let name = primitiveName p
            ty = C.Constructor name []
        if nativeRepresentation "java" name == Nothing then pure [] else do
          native <- typeDoc (handlesOf declarations) names [] ty
          pure [D.text ("case " ++ show name ++ " -> ") <> call "schema.scalar" [quoted name, D.text "bits", native <> D.text ".class"] <> D.text ";"]) primitives
      let dataCases = [D.text ("case " ++ show (C.idText (C.dataId d)) ++ " -> ") <>
            call (codecName (nativeName names d)) (map D.text ["schema", "bits", "symbols"] ++
              [D.text ("arguments.get(" ++ show i ++ ")") | i <- [0 .. length (C.dataParameters d) - 1]]) <> D.text ";"
            | d <- declarations]
          structural = map D.text
            [ "case \"List\" -> schema.list(arguments.get(0), bits, symbols);"
            , "case \"Maybe\" -> schema.maybe(arguments.get(0), bits, symbols);"
            , "case \"Either\" -> schema.either(arguments.get(0), arguments.get(1), bits, symbols);"
            , "default -> schema.supported(type, bits, symbols);" ]
      pure (D.text "@SuppressWarnings({\"unchecked\", \"rawtypes\"})" <> D.hardline <>
        D.text "public static Codec<Object> dynamic(LawSpecSchema schema, int bits, java.util.Map<String, Object> symbols, Named type) " <>
        D.block 2 (D.text "List<Codec<Object>> arguments = type.arguments().stream()" <> D.nest 8 (D.hardline <>
          D.text ".map(argument -> dynamic(schema, bits, symbols, (Named) argument))" <> D.hardline <> D.text ".toList();") <> D.hardline <>
          D.text "return (Codec) switch (type.name()) " <> D.block 2 (D.joinWith D.hardline (dataCases ++ scalars ++ structural)) <> D.text ";"))
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
      C.Constructor name [] | isDurationType name -> pure (call "schema.duration" [D.text "bits", D.text "symbols"])
      C.Constructor name args | Just short <- collectionContainer name -> do
        children <- mapM (argument (codec parameters)) args
        pure (collectionCodec call "schema" short children [D.text "bits", D.text "symbols"])
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
            native <- typeDoc (handlesOf declarations) names [] ty
            pure (call "schema.scalar" [quoted name, D.text "bits", native <> D.text ".class"])
      _ -> Left "function fields cannot cross a data codec"
    -- A handle's codec passes its native object through, both ways.
    definition declaration | C.dataHandle declaration = do
      let method = codecName (nativeName names declaration)
          signature contexts = D.group $ D.text "public static Codec<java.lang.Object> " <>
            call method ([D.text "LawSpecSchema schema", D.text "int bits"] ++ contexts)
          body = D.text ("var type = new Named(" ++ D.render D.Compact (quoted (C.idText (C.dataId declaration))) ++ ");") <> D.hardline <>
            D.text "return schema.codec(" <> D.nest 4
              (D.hardline <> D.joinWith (D.text "," <> D.hardline)
                [D.text "type", D.text "bits", D.text "symbols",
                 D.text "value -> LawSpecRuntime.handle(LawSpecSchema.key(type), value)",
                 D.text "LawSpecRuntime::handleTarget"]) <> D.text ");"
      pure (signature [] <> D.text " " <> D.block 2 (D.text "return " <>
          call method [D.text "schema", D.text "bits", D.text "new java.util.HashMap<>()"] <> D.text ";") <>
        D.hardline <> D.hardline <>
        signature [D.text "java.util.Map<String, Object> symbols"] <> D.text " " <> D.block 2 body)
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
      productEncoder <- case C.dataConstructors declaration of
        [single] | isProduct declaration -> Just <$> productEncode parameters single
        _ -> pure Nothing
      let failure = D.text "throw new IllegalArgumentException(\"uninhabited or invalid native data\");"
          encoder = case productEncoder of
            Just body' -> D.text "item -> " <> D.block 2 body'
            Nothing | null encodeArms -> D.text "value -> " <> D.block 2 failure
            Nothing -> D.text "value ->" <> D.nest 4 (D.hardline <>
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
      _ <- typeDoc (handlesOf declarations) names typeParams (C.Constructor (C.idText (C.dataId declaration)) typeArguments)
      let forward = call method ([D.text "schema",D.text "bits",D.text "new java.util.HashMap<>()"] ++
            [D.text v | (_,(_,v)) <- parameters])
      pure (signature [] <> D.text " " <> D.block 2 (D.text "return " <> forward <> D.text ";") <>
        D.hardline <> D.hardline <>
        signature [D.text "java.util.Map<String, Object> symbols"] <> D.text " " <> D.block 2 body)
      where
        variantName = constructorClass names declaration
        gadt = any (\c -> not (null (C.constructorEquations c)) || not (null (C.constructorExistentials c))) (C.dataConstructors declaration)
        -- A GADT case's own type arguments: none when its refinements fix
        -- every parameter, wildcards for open parameters and existentials.
        caseArguments args value
          | null (C.constructorEquations value) && null (C.constructorExistentials value) = args
          | otherwise = replicate (length [p | p <- C.dataParameters declaration, p `notElem` map fst (C.constructorEquations value)]
              + length [e | e <- C.constructorExistentials value, e `notElem` freeExistentials declaration value]) (D.text "?")
        existential value ty = any (`elem` C.constructorExistentials value) (typeVariablesOf ty)
        witnessCount value = length (freeExistentials declaration value)
        -- keys: the value's witness keys, read from the record or the data.
        fieldBindings parameters keys value = do
          declared <- mapM (\(i,field) -> do
            -- An existential field's type comes from the value's own type, or
            -- from its witnesses.
            bridge <- if existential value (C.binderType field)
              then pure (call "dynamic" [D.text "schema", D.text "bits", D.text "symbols",
                call "schema.fieldType" ([D.text "type", quoted (C.idText (C.constructorId value)), D.text (show i)] ++
                  [keys | witnessCount value > 0])])
              else codec parameters (C.binderType field)
            pure ("field" ++ show i, C.binderName field,
              D.group (D.text ("var field" ++ show i ++ " =") <>
                D.nest 4 (D.softline <> bridge) <> D.text ";")))
            (zip [0::Int ..] (C.constructorFields value))
          text <- codec parameters (C.Constructor "Text" [])
          let n = length (C.constructorFields value)
              witnesses = [("field" ++ show (n + k), Schema.witnessFieldName (witnessCount value) k,
                D.group (D.text ("var field" ++ show (n + k) ++ " =") <> D.nest 4 (D.softline <> text) <> D.text ";"))
                | k <- [0 .. witnessCount value - 1]]
          pure (declared ++ witnesses)
        recordKeys value = call "List.of" [D.text ("item." ++ Schema.witnessFieldName (witnessCount value) k ++ "()") | k <- [0 .. witnessCount value - 1]]
        dataKeys value = call "LawSpecSchema.witnessKeys" [D.text "data.fields()", D.text (show (witnessCount value))]
        encodeArm parameters args value = do
          bindings <- fieldBindings parameters (recordKeys value) value
          pure (D.text "case " <> applied (variantName value) (caseArguments args value) <> D.text " item -> " <>
            D.block 2 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [D.text "yield " <> construct value bindings <> D.text ";"])))
        -- A product needs no switch: the value is the record.
        productEncode parameters value = do
          bindings <- fieldBindings parameters (recordKeys value) value
          pure (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [D.text "return " <> construct value bindings <> D.text ";"]))
        construct value bindings = call "schema.construct"
          [D.text "type", quoted (C.idText (C.constructorId value)), call "List.of"
            [call "LawSpecSchema.encodeField" [D.text name, D.text ("item." ++ field ++ "()"), quoted (C.idText (C.constructorId value) ++ "." ++ field)]
            | (name,field,_) <- bindings], D.text "bits",D.text "symbols"]
        decodeArm parameters value = do
          bindings <- fieldBindings parameters (dataKeys value) value
          let decoded i name = D.text (name ++ ".decode(data.fields().get(" ++ show i ++ "))")
              fields = [if existential value (C.binderType field) then call "LawSpecSchema.cast" [decoded i name] else decoded i name
                | (i,((name,_,_),field)) <- zip [0::Int ..] (zip bindings (C.constructorFields value))] ++
                [decoded i name | (i,(name,_,_)) <- drop (length (C.constructorFields value)) (zip [0::Int ..] bindings)]
              generic = not (null (caseArguments [D.text "_" | _ <- parameters] value))
              built = call ("new " ++ variantName value ++ if generic then "<>" else "") fields
              -- A refined case implements its refined interface; the schema
              -- has already checked it builds this type.
              result = D.text "yield " <> (if gadt then call "LawSpecSchema.cast" [built] else built) <> D.text ";"
          pure (D.text "case " <> quoted (C.idText (C.constructorId value)) <> D.text " -> " <>
            D.block 2 (D.joinWith D.hardline ([doc | (_,_,doc) <- bindings] ++ [result])))

typeVariablesOf :: C.Type -> [C.Id]
typeVariablesOf ty = case ty of
  C.TypeVariable v -> [v]
  C.Constructor _ arguments -> concat [typeVariablesOf t | C.TypeArgument t <- arguments]
  C.Arrow a b -> typeVariablesOf a ++ typeVariablesOf b

-- | The runtime validates values against a schema reference built from the type.
javaTypeReference :: C.Type -> Either String String
javaTypeReference ty = render <$> Schema.typeReference [] ty
  where
    quoted = Text.unpack . Text.decodeUtf8 . encode
    render (Schema.Parameter _) = error "unbound concrete Java type"
    render (Schema.Named name args) = "new lawspec.runtime.LawSpecSchema.Named(" ++
      quoted name ++ concatMap ((", " ++) . render) args ++ ")"

-- | Every value crossing the adapter boundary goes through a codec that checks
-- it against its declared domain. ref:DEC-portable-exact-arithmetic
javaCodec :: [C.DataDeclaration] -> Int -> C.Type -> Either String String
javaCodec declarations =
  -- The names depend only on the declarations: a caller that applies this to
  -- them once shares them across every type.
  let prepared = namesFor declarations
  in \bits ty -> do
  names <- prepared
  let go value@(C.Constructor name args) = do
        children <- mapM (\a -> case a of C.TypeArgument t -> go t; _ -> Left "indexed codec") args
        case lookup name names of
          _ | isDurationType name -> pure (invoke "_schema.duration" [show bits, "new java.util.HashMap<>()"])
          _ | Just short <- collectionContainer name ->
            pure (case short of
              "Set" -> invoke "_schema.set" (children ++ [show bits, "new java.util.HashMap<>()"])
              "KeyVal" -> invoke "_schema.keyVal" (children ++ [show bits, "new java.util.HashMap<>()"])
              _ -> invoke "_schema.sequence" ([show short] ++ children ++ [show bits, "new java.util.HashMap<>()"]))
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

-- | A structured counterpart for source emitters; the existing string API remains
-- available to legacy property wrappers.
javaCodecDoc :: [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDoc = javaCodecDocUsing Nothing

-- | As javaCodec, where the symbol table comes from the caller's scope.
javaCodecDocWithContext :: D.Doc -> [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDocWithContext symbols = javaCodecDocUsing (Just symbols)

javaCodecDocUsing :: Maybe D.Doc -> [C.DataDeclaration] -> Int -> C.Type -> Either String D.Doc
javaCodecDocUsing context declarations =
  -- The names depend only on the declarations: a caller that applies this to
  -- them once shares them across every type.
  let prepared = namesFor declarations
  in \bits ty -> do
  names <- prepared
  let symbols = maybe [] pure context
      go value@(C.Constructor name args) = do
        children <- mapM (\a -> case a of C.TypeArgument t -> go t; _ -> Left "indexed codec") args
        case lookup name names of
          _ | isDurationType name ->
            pure (invoke "_schema.duration" [D.text (show bits), if null symbols then D.text "new java.util.HashMap<>()" else head symbols])
          _ | Just short <- collectionContainer name ->
            pure (collectionCodec invoke "_schema" short children
              [D.text (show bits), if null symbols then D.text "new java.util.HashMap<>()" else head symbols])
          Just native -> pure (invoke ("lawspec.runtime.LawSpecDataCodecs." ++ codecName native)
            ([D.text "_schema", D.text (show bits)] ++ symbols ++ children))
          Nothing | name `elem` ["List", "Maybe", "Either"] ->
            pure (invoke ("_schema." ++ map toLower name) (children ++ [D.text (show bits)] ++ symbols))
          Nothing | name `elem` ["Nullable", "Optional", "Unit"] || nativeRepresentation "java" name == Nothing -> do
            ref <- reference value
            pure (invoke "_schema.supported" ([ref,D.text (show bits)] ++ symbols))
          Nothing -> do
            native <- typeDoc (handlesOf declarations) names [] value
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

-- | Built-in collections and durations are Java's own types, not generated ones.
builtinFree :: C.DataDeclaration -> Bool
builtinFree d = collectionContainer (C.idText (C.dataId d)) == Nothing && not (isDurationType (C.idText (C.dataId d)))
