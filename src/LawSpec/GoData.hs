-- Native sealed interfaces and variants follow Go+'s resolved enum lowering.
module LawSpec.GoData (emitGoData, goDataType, goTypeReference, emitGoSchema, emitGoSchemaWithProfile, goCodec, goCodecWithContext, emitGoCodecs, requiresSchema, goDataKey, validateGoBindings, identifier, goNativeCodec, emitGoNativeCodecs, goGeneratedNames, goNativeTypeWithParameters) where

import LawSpec.DataNames (flatDataCandidates, productConstructors, isProduct)
import LawSpec.GoTypeRefs
import qualified LawSpec.GoExpr as E
import LawSpec.Core.Total (constructorProofContracts)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toUpper, toLower, ord)
import Data.List (intercalate, nub, find)
import LawSpec.NativeBinding
import Numeric (showHex)
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry, checkType, freeExistentials)
import LawSpec.Collections (collectionContainer, entryTypeName)
import LawSpec.Time (isDurationType)
import LawSpec.Scalar (nativeRepresentation, primitives, primitiveName)
import qualified LawSpec.Core.Schema as S
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import qualified LawSpec.Code.Doc as D

type Names = [(C.Id, String)]

capitalize :: String -> String
capitalize [] = []
capitalize (c:cs) = toUpper c:cs

identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid Go data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && isLetter c && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
      [] -> False

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let duplicate name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
      reserved name = take 7 name == "LawSpec"
      qualified = flatDataCandidates capitalize reserved declarations
      names = [(identity, if duplicate name qualified || reserved name then "Data" ++ name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting Go data identities")
  pure (names ++ productConstructors declarations names)

goGeneratedNames :: [C.DataDeclaration] -> Either String [String]
goGeneratedNames declarations = map snd <$> namesFor declarations

applied :: String -> [String] -> String
applied name [] = name
applied name args = name ++ "[" ++ intercalate ", " args ++ "]"

typeText :: Names -> [(C.Id, String)] -> C.Type -> Either String String
typeText names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Go data parameter") Right (lookup variable parameters)
  -- A Duration is a time.Duration (lawspec_codecs.go).
  C.Constructor name [] | isDurationType name -> pure "LawSpecDuration"
  -- Built-in collections are slices in canonical order (lawspec_codecs.go).
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    case (short, args) of
      ("KeyVal", [_, _]) -> do
        entry <- maybe (Left "no Go Entry type") Right (lookup (C.Id entryTypeName) names)
        pure ("[]" ++ applied entry args)
      (_, [item]) -> pure ("[]" ++ item)
      _ -> Left ("no Go data representation for " ++ show ty)
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (applied native args)
      Nothing -> case (name,args) of
        ("List",[inner]) -> pure ("[]" ++ inner)
        ("Maybe",[_]) -> pure (applied "LawSpecMaybe" args)
        ("Either",[_,_]) -> pure (applied "LawSpecEither" args)
        ("Nullable",[_]) -> pure (applied "LawSpecNullable" args)
        ("Optional",[_]) -> pure (applied "LawSpecOptional" args)
        ("Integer",[]) -> pure "*LawSpecBigInt"
        (_,[]) -> maybe (Left ("no Go data representation for " ++ name)) Right
          (case lookup name [("Decimal","LawSpecDecimal"),("Symbol","*LawSpecSymbol"),
                            ("Unit","LawSpecUnit"),("Null","LawSpecNull"),("Undefined","LawSpecUndefined")] of
            Just native -> Just native
            Nothing -> nativeRepresentation "go" name)
        _ -> Left ("no Go data representation for " ++ show ty)
  _ -> Left ("no Go data representation for " ++ show ty)
  where
    argument (C.TypeArgument t) = typeText names parameters t
    argument _ = Left "indexed Go data is not supported"

goDataType :: [C.DataDeclaration] -> C.Type -> Either String String
goDataType declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeText names [] ty

emitGoData :: D.Layout -> String -> [C.DataDeclaration] -> Either String String
emitGoData layout packageName declarations = do
  _ <- makeRegistry declarations
  identifier packageName
  unless (packageName `notElem` words "break default func interface select case defer go map struct chan else goto package switch const fallthrough if range type continue for import return var")
    (Left "reserved Go package name")
  names <- namesFor declarations
  definitions <- mapM (definition names) [d | d <- declarations, native d]
  pure (D.render (if layout == D.Compact then D.CompactTabs else layout) (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text ("package " ++ packageName) <>
    (if null definitions then mempty else D.hardline <> D.hardline <>
      D.joinWith (D.hardline <> D.hardline) definitions) <> D.hardline))
  where
    definition names declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration)
            [candidate | n <- [0::Int ..], let candidate = "T" ++ show n, candidate `notElem` map snd names]
          args = map snd parameters
          generic = applied name [arg ++ " any" | arg <- args]
          marker = "lawSpec" ++ name
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        variantName <- lookupName names (C.constructorId variant)
        -- A GADT variant is generic in the parameters it leaves open and in
        -- its existentials; its marker method's arguments apply its
        -- refinements, so it implements only the refined interface.
        let existentials = zip (C.constructorExistentials variant)
              [candidate | n <- [0::Int ..], let candidate = "E" ++ show n, candidate `notElem` map snd names]
            scope = parameters ++ existentials
            equations = C.constructorEquations variant
            open = [v | (p, v) <- parameters, p `notElem` map fst equations]
            -- Go cannot construct a variant at existential types inside a
            -- generic codec, so such a variant keeps every parameter and holds
            -- existential fields as checked dynamic values.
            own = if null equations || not (null existentials) then args else open
        markerArguments <- if not (null existentials) then pure args else
          forM parameters $ \(p, v) -> maybe (pure v) (typeText names scope) (lookup p equations)
        fields <- forM (C.constructorFields variant) $ \field -> do
          let fieldName = capitalize (C.binderName field)
          identifier fieldName
          fieldType <- if mentionsAny (map fst existentials) (C.binderType field) then pure "LawSpecValue"
            else typeText names scope (C.binderType field)
          pure (fieldName,fieldType)
        -- Each field-only existential's type travels as a witness string.
        let free = length (freeExistentials declaration variant)
            witnessFields = [(capitalize (S.witnessFieldName free k), "string") | k <- [0 .. free - 1]]
        unless (length fields == length (nub (map fst fields))) (Left "Go constructor fields collide after export capitalization")
        let header = "type " ++ applied variantName [arg ++ " any" | arg <- own] ++ " struct"
            allFields = fields ++ witnessFields
            width = maximum (0 : map (length . fst) allFields)
            field (n,t) = D.text (n ++ replicate (width - length n + 1) ' ' ++ t)
            body = if null allFields then D.text "{}" else D.text " " <> D.block 8 (D.joinWith D.hardline (map field allFields))
            method = "func (" ++ applied variantName own ++ ") " ++ marker ++ "(" ++ intercalate ", " markerArguments ++ ") {}"
        pure (D.text header <> body, D.text method)
      -- A product is a plain struct named after its type; a sum is a sealed
      -- interface whose variants carry the marker method.
      if isProduct declaration then pure (D.joinWith mempty (map fst variants)) else
       pure (D.text ("type " ++ generic ++ " interface ") <>
        D.block 8 (D.text (marker ++ "(" ++ intercalate ", " args ++ ")")) <>
        (if null variants then mempty else D.hardline <> D.hardline <>
          D.joinWith (D.hardline <> D.hardline) [d <> D.hardline <> D.hardline <> m | (d,m) <- variants]))
    lookupName names identity = maybe (Left "unplanned Go data name") Right (lookup identity names)

-- Whether a type mentions any of these (existential) variables.
mentionsAny :: [C.Id] -> C.Type -> Bool
mentionsAny variables ty = case ty of
  C.TypeVariable v -> v `elem` variables
  C.Constructor _ arguments -> or [mentionsAny variables t | C.TypeArgument t <- arguments]
  C.Arrow a b -> mentionsAny variables a || mentionsAny variables b

-- Schema descriptions and native declarations share resolved Core identities.
q :: String -> String
q = T.unpack . T.decodeUtf8 . encode

emitGoSchema :: D.Layout -> String -> [C.DataDeclaration] -> Either String String
emitGoSchema = emitGoSchemaWithProfile 64

emitGoSchemaWithProfile :: Int -> D.Layout -> String -> [C.DataDeclaration] -> Either String String
emitGoSchemaWithProfile bits layout packageName declarations = do
  -- Reuse declaration validation, including exported name planning.
  _ <- emitGoData layout packageName declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas,contracts) <- S.dataSchemasWithContracts declarations
  callbacks <- forM contracts $ \contract -> do
    predicates <- forM (S.contractPredicates contract) $ \predicate -> do
      let fields = zip (map C.binderId (S.contractFields contract))
            ["fields[" ++ show i ++ "]" | i <- [0 :: Int ..]]
          nested = zip (nub (nestedIds predicate)) ["local" ++ show i | i <- [0 :: Int ..]]
          local identity = maybe "invalidField" id (lookup identity (fields ++ nested))
          ref ty = do
            value <- reference <$> S.typeReference (S.contractParameters contract) ty
            pure (E.call "lsSubstitute" [D.text value,D.text "types"])
          key ty = do
            value <- ref ty
            pure (value <> D.text ".key()")
      body <- E.renderExpressionWithContext declarations (D.text "bits") "schema" ref key local
        (\_ _ -> Left "external call in constructor predicate") predicate
      pure (D.text "func(schema *lawSpecSchema, types []lawSpecTypeRef, fields []LawSpecValue, bits int, symbols map[string]*lawSpecSymbol) bool " <>
        D.block 8 (D.text "return " <> E.call "lsTruth" [body]))
    pure (D.text ("{" ++ q (S.contractTag contract) ++ ", []lawSpecFieldPredicate") <>
      D.block 8 (D.joinWith D.hardline [predicate <> D.text "," | predicate <- predicates]) <> D.text "}")
  let array ty [] = D.text ("[]" ++ ty ++ "{}")
      array ty values = D.text ("[]" ++ ty) <> D.block 8
        (D.joinWith D.hardline [value <> D.text "," | value <- values])
      field value = D.text ("{" ++ q (S.fieldName value) ++ ", " ++ reference (S.fieldType value) ++ "}")
      constructor value = D.text ("{" ++ q (S.constructorTag value) ++ ", ") <>
        array "lawSpecFieldSchema" (map field (S.fields value)) <> D.text ", " <>
        (if null (S.constructorIndex value) then D.text "nil"
         else D.text ("[]string{" ++ intercalate ", " (map q (S.constructorIndex value)) ++ "}")) <> D.text ", " <>
        (if null (S.constructorRefinements value) then D.text "nil"
         else D.text ("[]lawSpecRefinement{" ++ intercalate ", " ["{" ++ show index ++ ", " ++ reference pattern ++ "}" | (index, pattern) <- S.constructorRefinements value] ++ "}")) <>
        D.text (", " ++ show (S.constructorExistentials value)) <>
        (if null (S.constructorWitnesses value) then D.text ", nil"
         else D.text (", []int{" ++ intercalate ", " (map show (S.constructorWitnesses value)) ++ "}")) <> D.text "}"
      definition value = D.text ("{" ++ q (S.typeName value) ++ ", " ++ show (S.parameterCount value) ++ ", ") <>
        array "lawSpecConstructorSchema" (map constructor (S.constructors value)) <> D.text "}"
      body = D.text "return lsNewSchemaWithContracts(" <> D.nest 8 (D.hardline <>
        array "lawSpecDataSchema" (map definition schemas) <> D.text "," <> D.hardline <>
        array "string" (map (D.text . q . primitiveName) primitives) <> D.text "," <> D.hardline <>
        array "lawSpecConstructorContract" callbacks <> D.text ",") <>
        D.hardline <> D.text ")"
  pure (D.render (if layout == D.Compact then D.CompactTabs else layout) (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text ("package " ++ packageName) <> D.hardline <> D.hardline <>
    D.text "func lawSpecDataSchemaRegistry() *lawSpecSchema " <> D.block 8 body <> D.hardline))

  where
    nestedIds term = (case C.expressionNode term of
      C.AllElements _ binder _ -> [C.binderId binder]
      C.AllPayloads _ predicates -> map (C.binderId . fst) predicates
      C.Match _ branches -> concatMap (map C.binderId . C.caseBinders) branches
      _ -> []) ++ concatMap nestedIds (C.children term)

-- Recursive codec factories are invoked inside conversion closures, so recursive
-- declarations do not recursively construct an infinite codec graph.
goCodec :: [C.DataDeclaration] -> C.Type -> Either String String
goCodec = goCodecUsing Nothing

goCodecWithContext :: String -> [C.DataDeclaration] -> C.Type -> Either String String
goCodecWithContext context = goCodecUsing (Just context)

goCodecUsing :: Maybe String -> [C.DataDeclaration] -> C.Type -> Either String String
goCodecUsing context declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  codec context names [] [] ty

codec :: Maybe String -> Names -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String String
codec = codecUsing "lawSpec" Nothing

codecUsing :: String -> Maybe Names -> Maybe String -> Names -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String String
codecUsing prefix nativeNames context names parameters codecs ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Go codec parameter") Right (lookup variable codecs)
  C.Constructor name arguments -> do
    types <- mapM argument arguments
    children <- mapM (codecUsing prefix nativeNames context names parameters codecs) types
    native <- typeText (maybe names id nativeNames) parameters ty
    let typeRefs = "[]lawSpecTypeRef{" ++ intercalate ", " [child ++ ".typeRef" | child <- children] ++ "}"
    if isDurationType name then pure (invoke "lsDurationCodec" (["schema", "bits"] ++ maybe [] pure context)) else case collectionContainer name of
     Just short -> do
      item <- if short == "KeyVal"
        then codecUsing prefix nativeNames context names parameters codecs (C.Constructor entryTypeName arguments)
        else pure (head children)
      pure (invoke "lsCollectionCodec" (["schema", "bits", q short, typeRefs, item] ++ maybe [] pure context))
     Nothing -> case lookup (C.Id name) names of
      Just dataName -> pure (invoke (prefix ++ dataName ++ "Codec") (["schema","bits"] ++ children ++ maybe [] pure context))
      Nothing -> case name of
        "List" -> pure (invoke "lsListCodec" (["schema","bits"] ++ children ++ maybe [] pure context))
        "Maybe" -> pure (invoke "lsMaybeCodec" (["schema","bits"] ++ children ++ maybe [] pure context))
        "Either" -> pure (invoke "lsEitherCodec" (["schema","bits"] ++ children ++ maybe [] pure context))
        "Nullable" -> pure (invoke "lsNullableCodec" (["schema","bits"] ++ children ++ maybe [] pure context))
        "Optional" -> pure (invoke "lsOptionalCodec" (["schema","bits"] ++ children ++ maybe [] pure context))
        _ | null types -> pure (invoke ("lsScalarCodec[" ++ native ++ "]") ["schema","bits",q name])
        _ -> Left "unsupported Go codec application"
  _ -> Left "unsupported Go codec type"
  where
    argument (C.TypeArgument value) = Right value
    argument _ = Left "indexed Go codec is not supported"
    invoke name arguments = name ++ "(" ++ intercalate ", " arguments ++ ")"

goNativeCodec :: [C.DataDeclaration] -> [ResolvedTypeBinding] -> C.Type -> Either String String
goNativeCodec declarations mappings ty = do
  names <- namesFor declarations
  codecUsing "lawSpecNative" (Just (nativeNamesFor names mappings)) (Just "symbols") names [] [] ty

goNativeTypeWithParameters :: [C.DataDeclaration] -> [ResolvedTypeBinding] -> [(C.Id,String)] -> C.Type -> Either String String
goNativeTypeWithParameters declarations mappings parameters ty = do
  names <- namesFor declarations
  typeText (nativeNamesFor names mappings) parameters ty

nativeNamesFor :: Names -> [ResolvedTypeBinding] -> Names
nativeNamesFor names mappings = [(identity, maybe name (intercalate "." . referenceParts)
  (lookup identity references)) | (identity,name) <- names]
  where
    references = [(C.dataId (resolvedDeclaration m), resolvedNativeType m) | m <- mappings] ++
      [(C.constructorId (resolvedConstructor c), resolvedNativeConstructor c) | m <- mappings, c <- resolvedConstructors m]

emitGoNativeCodecs :: D.Layout -> String -> [(String,String)] -> [C.DataDeclaration] -> [ResolvedTypeBinding] -> [C.Id] -> Either String String
emitGoNativeCodecs layout packageName imports declarations mappings needed =
  emitCodecs "lawSpecNative" mappings (Just needed) imports layout packageName declarations

emitGoCodecs :: D.Layout -> String -> [C.DataDeclaration] -> Either String String
emitGoCodecs = emitCodecs "lawSpec" [] Nothing []

emitCodecs :: String -> [ResolvedTypeBinding] -> Maybe [C.Id] -> [(String,String)] -> D.Layout -> String -> [C.DataDeclaration] -> Either String String
emitCodecs prefix mappings needed imports layout packageName declarations = do
  _ <- emitGoData layout packageName declarations
  names <- namesFor declarations
  definitions <- mapM (definition names) [d | d <- declarations, maybe True (C.dataId d `elem`) needed, native d]
  pure (D.render (if layout == D.Compact then D.CompactTabs else layout) (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text ("package " ++ packageName) <>
    (if null imports then mempty else D.hardline <> D.hardline <>
      D.joinWith D.hardline [D.text ("import " ++ alias ++ " " ++ q path) | (alias,path) <- imports]) <>
    (if null definitions then mempty else D.hardline <> D.hardline <>
      D.joinWith (D.hardline <> D.hardline) definitions) <> D.hardline))
  where
    line = D.text
    linesDoc = D.joinWith D.hardline
    definition names declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration)
            [candidate | n <- [0::Int ..], let candidate = "T" ++ show n, candidate `notElem` map snd names]
          arguments = map snd parameters
          codecParameters = zip (C.dataParameters declaration) ["element" ++ show n | n <- [0::Int ..]]
          native = applied (maybe name id (lookup (C.dataId declaration) (nativeNamesFor names mappings))) arguments
          typeRef = "lsNamed(" ++ intercalate ", " (q (C.idText (C.dataId declaration)) : [value ++ ".typeRef" | (_,value) <- codecParameters]) ++ ")"
          params = ["schema *lawSpecSchema", "bits int"] ++
            [value ++ " lawSpecCodec[" ++ ty ++ "]" | ((_,ty),(_,value)) <- zip parameters codecParameters] ++
            ["contexts ...map[string]*lawSpecSymbol"]
          signature = "func " ++ applied (prefix ++ name ++ "Codec") [arg ++ " any" | arg <- arguments] ++
            "(" ++ intercalate ", " params ++ ") lawSpecCodec[" ++ native ++ "] "
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        variantName <- lookupName (nativeNamesFor names mappings) (C.constructorId variant)
        let existential = mentionsAny (C.constructorExistentials variant)
            refinedOnly = not (null (C.constructorEquations variant)) && null (C.constructorExistentials variant)
            openArguments = [v | (p, v) <- parameters, p `notElem` map fst (C.constructorEquations variant)]
        let free = length (freeExistentials declaration variant)
        declaredFields <- forM (zip [0 :: Int ..] (C.constructorFields variant)) $ \(position, field) -> do
          -- An existential field's type comes from the value's own type, or
          -- from its witnesses (@KEYS@: read from the value or native).
          expression <- if existential (C.binderType field)
            then pure (if free > 0
              then "lsLogicalCodec(schema, bits, lsFieldTypeWith(schema, typeRef, " ++ q (C.idText (C.constructorId variant)) ++ ", " ++ show position ++ ", @KEYS@), symbols)"
              else "lsLogicalCodec(schema, bits, lsFieldType(schema, typeRef, " ++ q (C.idText (C.constructorId variant)) ++ ", " ++ show position ++ "), symbols)")
            else codecUsing prefix (Just (nativeNamesFor names mappings)) (Just "symbols") names parameters codecParameters (C.binderType field)
          fieldType <- if existential (C.binderType field) then pure "LawSpecValue" else typeText names parameters (C.binderType field)
          let mapped = find ((== C.constructorId variant) . C.constructorId . resolvedConstructor)
                [c | m <- mappings,c <- resolvedConstructors m]
              fieldName = maybe (capitalize (C.binderName field)) id
                (mapped >>= lookup (C.binderId field) . map (\(f,n) -> (C.binderId f,n)) . resolvedFields)
          pure (fieldName,C.binderName field,fieldType,expression)
        textCodec <- codecUsing prefix (Just (nativeNamesFor names mappings)) (Just "symbols") names parameters codecParameters (C.Constructor "Text" [])
        let fields = declaredFields ++
              [(capitalize (S.witnessFieldName free k), S.witnessFieldName free k, "string", textCodec) | k <- [0 .. free - 1]]
            decodeKeys = "lsWitnessTail(data.fields, " ++ show free ++ ")"
            encodeKeys = "[]string{" ++ intercalate ", " ["native." ++ capitalize (S.witnessFieldName free k) | k <- [0 .. free - 1]] ++ "}"
            keyed keys expression = replaceKeys keys expression
        let mapped = find ((== C.constructorId variant) . C.constructorId . resolvedConstructor)
              [c | m <- mappings,c <- resolvedConstructors m]
            unit = maybe False ((== UnitConstructor) . resolvedConstructorStyle) mapped
            tag = C.idText (C.constructorId variant)
            concrete = applied variantName (if refinedOnly then openArguments else arguments)
            width = maximum (0 : [length n | (n,_,_,_) <- fields])
            construct = if unit then line variantName else if null fields then line (concrete ++ "{}") else
              line concrete <> D.block 8 (linesDoc
                [line (n ++ ":" ++ replicate (width - length n + 1) ' ' ++ keyed decodeKeys expression ++ ".toNative(data.fields[" ++ show index ++ "]),")
                | (index,(n,_,_,expression)) <- zip [0::Int ..] fields])
            encodeFields = if null fields then line "nil" else
              line "[]LawSpecValue" <> D.block 8 (linesDoc
                [line ("lsSchemaContext(" ++ q (tag ++ "." ++ original) ++ ", func() LawSpecValue ") <>
                  D.block 8 (line ("return " ++ keyed encodeKeys expression ++ ".encode(native." ++ n ++ ", path)")) <> line "),"
                | (n,original,_,expression) <- fields])
            -- A refined variant implements only its refined interface.
            decode = line ("case " ++ q tag ++ ":") <> D.nest 8 (D.hardline <> line "return " <>
              (if refinedOnly then line "any(" <> construct <> line (").(" ++ native ++ ")") else construct))
            result = line ("return schema.construct(typeRef, " ++ q tag ++ ", ") <> encodeFields <> line ", bits, symbols)"
            encodeValue = if prefix == "lawSpec" then
              line ("case " ++ concrete ++ ":") <> D.nest 8 (D.hardline <> result)
              else line (if unit then "if any(value) == any(" ++ variantName ++ ") "
                else "if native, ok := any(value).(" ++ concrete ++ "); ok ") <>
                D.block 8 ((if not unit && null fields then line "_ = native" <> D.hardline else mempty) <> result)
        pure (decode,encodeValue,result)
      let decode = line ("func(value LawSpecValue) " ++ native ++ " ") <> D.block 8
            (line "data := value.Data.(lawSpecData)" <> D.hardline <>
             line "switch data.tag {" <> D.hardline <>
             linesDoc ([d | (d,_,_) <- variants] ++ [line "default:" <> D.nest 8 (D.hardline <> line "panic(\"unknown checked constructor\")")]) <>
             D.hardline <> line "}")
          encodeValue = line ("func(value " ++ native ++ ", path lawSpecPath) LawSpecValue ") <> D.block 8
            (if prefix == "lawSpec" && isProduct declaration then
              line "native := value" <> D.hardline <>
              (if any (\v -> null (C.constructorFields v)) (C.dataConstructors declaration) then line "_ = native" <> D.hardline else mempty) <>
              linesDoc [r | (_,_,r) <- variants]
             else if prefix == "lawSpec" then
              line (if gadt then "switch native := any(value).(type) {" else "switch native := value.(type) {") <> D.hardline <>
              linesDoc ([e | (_,e,_) <- variants] ++ [line "default:" <> D.nest 8 (D.hardline <> line "_ = native" <> D.hardline <> failure)]) <>
              D.hardline <> line "}"
             else linesDoc ([e | (_,e,_) <- variants] ++ [failure]))
          failure = line ("panic(" ++ q ("unexpected native constructor for " ++ C.idText (C.dataId declaration)) ++ ")")
          gadt = any (not . null . C.constructorEquations) (C.dataConstructors declaration)
      (setup, hookDecode, hookEncode) <- case find ((== C.dataId declaration) . C.dataId . resolvedDeclaration) mappings >>= resolvedCodec of
        Nothing -> pure (mempty, decode, encodeValue)
        Just hook -> do
          let reference = intercalate "." . referenceParts
              invoke name args = name ++ "(" ++ intercalate ", " args ++ ")"
              logical = invoke ("lawSpec" ++ name ++ "Codec")
                (["schema","bits"] ++ [invoke "lsLogicalCodec" ["schema","bits",v ++ ".typeRef","symbols"] |
                  (_,v) <- codecParameters] ++ ["symbols"])
              context direction result expression =
                line ("return lsNativeContext(" ++ q ("native codec " ++ C.idText (C.dataId declaration) ++ " " ++ direction) ++ ", func() " ++ result ++ " ") <>
                D.block 8 (line "converted, err := " <> expression <> D.hardline <>
                  line "if err != nil " <> D.block 8 (line "panic(err)") <> D.hardline <>
                  line (if direction == "toNative" then "return converted" else "return canonical.encode(converted, path)")) <> line ")"
              decodeArgs = line "canonical.toNative(value)" : [line (v ++ ".toNative") | (_,v) <- codecParameters]
              encodeArgs = line "value" : [line ("func(child " ++ ty ++ ") LawSpecValue ") <>
                D.block 8 (line ("return " ++ v ++ ".encode(child, path)")) |
                  ((_,ty),(_,v)) <- zip parameters codecParameters]
              call name args = line (name ++ "(") <>
                D.nest 8 (D.hardline <> D.joinWith (line "," <> D.hardline) args <> line ",") <>
                D.hardline <> line ")"
          pure (line ("canonical := " ++ logical) <> D.hardline,
            line ("func(value LawSpecValue) " ++ native ++ " ") <> D.block 8
              (context "toNative" native (call (reference (codecToNative hook)) decodeArgs)),
            line ("func(value " ++ native ++ ", path lawSpecPath) LawSpecValue ") <> D.block 8
              (context "fromNative" "LawSpecValue" (call (reference (codecFromNative hook)) encodeArgs)))
      let body = line "symbols := lsSchemaSymbols(contexts)" <> D.hardline <> line ("typeRef := " ++ typeRef) <> D.hardline <> setup <>
            line "return lsCodec(schema, bits, typeRef," <>
            D.nest 8 (D.hardline <> hookDecode <> line "," <> D.hardline <> hookEncode <> line ", symbols)")
      pure (line signature <> D.block 8 body)
    lookupName names identity = maybe (Left "unplanned Go codec name") Right (lookup identity names)

validateGoBindings :: [C.DataDeclaration] -> [String] -> Either String ()
validateGoBindings declarations functions = do
  names <- namesFor declarations
  let collisions = [name | name <- functions, name `elem` map snd names || take 7 name == "LawSpec"]
  unless (null collisions) (Left ("Go adapter names collide with generated support: " ++ intercalate ", " collisions))

-- Replace each @KEYS@ placeholder with the witness keys' expression.
replaceKeys :: String -> String -> String
replaceKeys keys text = case text of
  [] -> []
  _ | take 6 text == "@KEYS@" -> keys ++ replaceKeys keys (drop 6 text)
  c : rest -> c : replaceKeys keys rest

-- Built-in collections and durations are Go's own types, not generated ones.
native :: C.DataDeclaration -> Bool
native d = collectionContainer (C.idText (C.dataId d)) == Nothing && not (isDurationType (C.idText (C.dataId d)))
