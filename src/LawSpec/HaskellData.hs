-- Native algebraic declarations are rendered from resolved Core identities.
module LawSpec.HaskellData (requiresSchema, emitHaskellData, haskellDataType, haskellDataTypeWithRepresentations, haskellNativeTypeWithParameters, emitHaskellSchema, emitHaskellSchemaWithProfile, haskellTypeReference, emitHaskellCodecs, emitHaskellCodecsWithRepresentations, emitHaskellCodecsWithHooks, haskellCodec, haskellCodecDoc, haskellCodecDocWithContext, haskellCodecDocIn, haskellTypeReferenceDoc) where

import LawSpec.DataNames (flatDataCandidates, productConstructors)
import LawSpec.HaskellTypeRefs
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.Backend as Backend
import LawSpec.Core.Total (constructorProofContracts)
import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlphaNum, isLetter, toUpper, toLower, ord)
import Data.List (nub, isInfixOf, zip4)
import Numeric (showHex)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Scalar (primitives, primitiveName, isInteger)
import LawSpec.Core.Types (makeRegistry, checkType)
import qualified LawSpec.Code.Doc as D

type Names = [(C.Id,String)]

capitalize :: String -> String
capitalize [] = []
capitalize (c:cs) = toUpper c:cs

identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid Haskell data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && isLetter c && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
      [] -> False

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let duplicate name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
      qualified = flatDataCandidates capitalize (const False) declarations
      names = [(identity, if duplicate name qualified then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting Haskell data identities")
  pure (names ++ productConstructors declarations names)

application :: String -> [String] -> String
application name [] = name
application name arguments = "(" ++ unwords (name : arguments) ++ ")"

typeText :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String String
typeText scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Haskell data parameter") Right (lookup variable parameters)
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (application (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[inner]) -> pure ("[" ++ inner ++ "]")
        ("Maybe",[_]) -> pure (application "P.Maybe" args)
        ("Either",[_,_]) -> pure (application "P.Either" args)
        ("Nullable",[_]) -> pure (application "LS.Nullable" args)
        ("Optional",[_]) -> pure (application "LS.Optional" args)
        (_,[]) -> maybe (Left ("no Haskell data representation for " ++ name)) Right (lookup name scalars)
        _ -> Left ("no Haskell data representation for " ++ show ty)
  _ -> Left ("no Haskell data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeText scope names parameters value
    argument _ = Left "indexed Haskell data is not supported"
    scalars = [("Bool","P.Bool"),("Integer","P.Integer"),("BigInt","P.Integer"),("BigUInt","P.Integer"),
      ("Int8","I.Int8"),("Int16","I.Int16"),("Int32","I.Int32"),("Int64","I.Int64"),
      ("UInt8","W.Word8"),("UInt16","W.Word16"),("UInt32","W.Word32"),("UInt64","W.Word64"),
      ("IntSize","P.Int"),("UIntSize","P.Word"),("UIntPtr","P.Word"),
      ("Decimal","LS.Decimal"),("Rational","P.Rational"),("Float32","P.Float"),("Float64","P.Double"),
      ("Complex64","(C.Complex P.Float)"),("Complex128","(C.Complex P.Double)"),
      ("Char","P.Char"),("CodePoint","P.Char"),("CodeUnit16","W.Word16"),
      ("Text","T.Text"),("CodePointText","LS.CodePointText"),("Utf16Text","LS.Utf16Text"),
      ("Bytes","B.ByteString"),("Symbol","LS.Symbol"),("Unit","()"),("Null","LS.Null"),("Undefined","LS.Undefined")]

haskellDataType :: [C.DataDeclaration] -> C.Type -> Either String String
haskellDataType declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeText "Data." names [] ty

haskellDataTypeWithRepresentations :: [C.DataDeclaration] -> [(C.Id,String)] -> C.Type -> Either String String
haskellDataTypeWithRepresentations declarations representations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  haskellNativeTypeWithParameters declarations representations [] ty

haskellNativeTypeWithParameters :: [C.DataDeclaration] -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String String
haskellNativeTypeWithParameters declarations representations parameters ty = do
  names <- namesFor declarations
  typeText "" [(identity, maybe ("Data." ++ name) id (lookup identity representations)) |
    (identity,name) <- names] parameters ty

emitHaskellData :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellData layout declarations = do
  _ <- makeRegistry declarations
  names <- namesFor declarations
  selectors <- selectorsFor names declarations
  definitions <- mapM (definition names selectors) declarations
  let body = D.joinWith (D.hardline <> D.hardline) definitions
      rendered = D.render layout body
      imports = [D.text ("import qualified " ++ moduleName ++ " as " ++ alias) |
        (moduleName,alias) <- [("Prelude","P"),("Data.Int","I"),("Data.Word","W"),
          ("Data.Text","T"),("Data.ByteString","B"),("Data.Complex","C"),("LawSpecRuntime","LS")],
        (alias ++ ".") `isInfixOf` rendered]
  pure (D.render layout (D.text "{-# LANGUAGE EmptyDataDecls, EmptyDataDeriving #-}" <> D.hardline <>
    D.text "-- Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "module LawSpecData where" <> D.hardline <> D.hardline <>
    D.joinWith D.hardline imports <> D.hardline <> D.hardline <> body <> D.hardline))
  where
    definition names selectors declaration = do
      name <- lookupName names (C.dataId declaration)
      let parameters = zip (C.dataParameters declaration) ["a" ++ show n | n <- [0::Int ..]]
          header = D.text (unwords ("data":name:map snd parameters))
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        constructor <- lookupName names (C.constructorId variant)
        let fieldNames = map (capitalize . C.binderName) (C.constructorFields variant)
        unless (length fieldNames == length (nub fieldNames)) (Left "Haskell constructor fields collide after naming")
        fields <- forM (C.constructorFields variant) $ \field -> do
          identifier (C.binderName field)
          native <- typeText "" names parameters (C.binderType field)
          selector <- maybe (Left "unplanned Haskell record selector") Right
            (lookup (C.constructorId variant, C.binderId field) selectors)
          pure (selector,native)
        unless (length fields == length (nub (map fst fields))) (Left "Haskell constructor fields collide after naming")
        pure (D.text constructor <> if null fields then mempty else D.nest 2 (D.hardline <>
          D.text "{ " <> D.joinWith (D.hardline <> D.text ", ")
            [D.text (field ++ " :: " ++ ty) | (field,ty) <- fields] <> D.hardline <> D.text "}"))
      pure (header <>
        (if null variants then mempty else D.nest 2 (D.hardline <> D.text "= " <>
          D.joinWith (D.hardline <> D.text "| ") variants)) <>
        D.nest 2 (D.hardline <> D.text "deriving (P.Eq, P.Show)"))
    lookupName names identity = maybe (Left "unplanned Haskell data name") Right (lookup identity names)

apply :: String -> [D.Doc] -> D.Doc
apply name arguments = D.group (D.text name <> D.nest 2
  (mconcat [D.softline <> argument | argument <- arguments]))

list :: [D.Doc] -> D.Doc
list = D.delimit 2 "[" "]"

parenthesize :: D.Doc -> D.Doc
parenthesize value = D.text "(" <> value <> D.text ")"

emitHaskellSchema :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellSchema = emitHaskellSchemaWithProfile 64

emitHaskellSchemaWithProfile :: Int -> D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellSchemaWithProfile bits layout declarations = do
  _ <- emitHaskellData layout declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas,contracts) <- S.dataSchemasWithContracts declarations
  callbacks <- forM contracts $ \contract -> do
    predicates <- forM (S.contractPredicates contract) $ \predicate -> do
      let fields = zip (map C.binderId (S.contractFields contract))
            ["fields P.!! " ++ show i | i <- [0 :: Int ..]]
          nested = zip (nub (nestedIds predicate)) ["local" ++ show i | i <- [0 :: Int ..]]
          local identity = maybe "invalidField" id (lookup identity (fields ++ nested))
          ref ty = do
            value <- reference <$> S.typeReference (S.contractParameters contract) ty
            pure (E.apply "Schema.substitute" [D.text "types",value])
          key ty
            | variable ty = Left "unresolved Haskell generic conversion target"
            | otherwise = pure (E.quoted (Backend.scalarTypeKey ty))
      body <- E.renderExpressionWithContext declarations (D.text "bits") "_schema"
        (D.text "symbols") ref key local
        (\_ _ -> Left "external call in constructor predicate") predicate
      pure (D.group (D.text "\\_schema types fields bits symbols ->" <>
        D.nest 2 (D.softline <> E.apply "P.Right" [E.apply "LS.truth" [body]])))
    pure (D.group (D.text "(" <> D.text (show (S.contractTag contract)) <> D.text "," <>
      D.nest 2 (D.softline <> list predicates) <> D.text ")"))
  let field value = apply "Schema.Field"
        [D.text (show (S.fieldName value)), parenthesize (reference (S.fieldType value))]
      constructor value = apply "Schema.Constructor"
        [D.text (show (S.constructorTag value)), list (map field (S.fields value))]
      definition value = apply "Schema.Definition"
        [D.text (show (S.typeName value)), D.text (show (S.parameterCount value)),
         list (map constructor (S.constructors value))]
      expression = apply "Schema.createWithContracts"
        [list (map definition schemas), list (map (D.text . show . primitiveName) primitives),list callbacks]
  pure (D.render layout (D.text "-- Generated by LawSpec. Do not edit." <> D.hardline <>
    D.text "module LawSpecDataSchema (schema) where" <> D.hardline <> D.hardline <>
    D.text "import qualified LawSpecSchema as Schema" <> D.hardline <>
    (if null callbacks then mempty else D.joinWith D.hardline (map D.text
      ["import qualified Prelude as P", "import LawSpecRuntime (Scalar(..))",
       "import qualified LawSpecRuntime as LS"]) <> D.hardline) <> D.hardline <>
    D.text (if null callbacks then "schema :: Either String Schema.Schema" else "schema :: P.Either P.String Schema.Schema") <> D.hardline <>
    D.text "schema =" <> D.nest 2 (D.hardline <> expression) <> D.hardline))

  where
    nestedIds term = (case C.expressionNode term of
      C.AllElements _ binder _ -> [C.binderId binder]
      C.AllPayloads _ predicates -> map (C.binderId . fst) predicates
      C.Match _ branches -> concatMap (map C.binderId . C.caseBinders) branches
      _ -> []) ++ concatMap nestedIds (C.children term)
    variable (C.TypeVariable _) = True
    variable (C.Constructor _ args) = any (\arg -> case arg of C.TypeArgument ty -> variable ty; _ -> False) args
    variable (C.Arrow a b) = variable a || variable b

-- Record selectors occupy one value namespace across the generated module.
-- Constructor-qualified names can still collide at concatenation boundaries.
selectorsFor :: Names -> [C.DataDeclaration] -> Either String [((C.Id,C.Id),String)]
selectorsFor names declarations = do
  candidates <- sequence
    [do constructor <- maybe (Left "unplanned Haskell constructor") Right
          (lookup (C.constructorId variant) names)
        let prefix = case constructor of c:cs -> toLower c:cs; [] -> ""
        pure ((C.constructorId variant, C.binderId field), prefix ++ capitalize (C.binderName field))
    | declaration <- declarations, variant <- C.dataConstructors declaration,
      field <- C.constructorFields variant]
  let duplicated name = length (filter ((== name) . snd) candidates) > 1
      unique (constructor,field) name = if duplicated name
        then "field_" ++ concatMap (\c -> showHex (ord c) "_")
          (C.idText constructor ++ "\0" ++ C.idText field)
        else name
      result = [(identity,unique identity name) | (identity,name) <- candidates]
  unless (length result == length (nub (map snd result)))
    (Left "conflicting Haskell field identities")
  pure result

codecName :: String -> String
codecName [] = "dataCodec"
codecName (c:cs) = toLower c : cs ++ "Codec"

codecExpression :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
codecExpression = codecExpressionWith Nothing "schema" "bits"

codecExpressionWith :: Maybe D.Doc -> String -> String -> String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
codecExpressionWith context schema bits scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Haskell codec parameter") (Right . D.text) (lookup variable parameters)
  C.Constructor name arguments -> do
    children <- mapM argument arguments
    values <- mapM (codecExpressionWith context schema bits scope names parameters) children
    case lookup (C.Id name) names of
      Just native -> pure (contextual (scope ++ codecName native) (map parenthesize values))
      Nothing -> case lookup name [("List","listCodec"),("Maybe","maybeCodec"),
          ("Either","eitherCodec"),("Nullable","nullableCodec"),("Optional","optionalCodec")] of
        Just constructor -> pure (contextual ("Codec." ++ constructor) (map parenthesize values))
        Nothing | not (null children) -> Left "unsupported Haskell codec application"
                | isInteger name -> pure (invoke "Codec.integerCodec" [D.text (show name)])
                | name `elem` ["Char","CodePoint"] -> pure (invoke "Codec.characterCodec" [D.text (show name)])
                | otherwise -> case lookup name helpers of
                    Just helper -> pure (invoke ("Codec." ++ helper) [])
                    Nothing -> Left ("no Haskell scalar codec for " ++ name)
  _ -> Left "unsupported Haskell codec type"
  where
    argument (C.TypeArgument value) = Right value
    argument _ = Left "indexed Haskell codec is not supported"
    invoke name arguments = apply name (map D.text [schema,bits] ++ arguments)
    contextual name arguments = case context of
      Nothing -> invoke name arguments
      Just value -> apply (name ++ "With")
        (parenthesize value : map D.text [schema,bits] ++ arguments)
    helpers = [("Bool","boolCodec"),("Decimal","decimalCodec"),("Rational","rationalCodec"),
      ("Float32","float32Codec"),("Float64","float64Codec"),("Complex64","complex64Codec"),
      ("Complex128","complex128Codec"),("CodeUnit16","codeUnitCodec"),("Text","textCodec"),
      ("Bytes","bytesCodec"),("CodePointText","codePointTextCodec"),("Utf16Text","utf16TextCodec"),
      ("Symbol","symbolCodec"),("Unit","unitCodec"),("Null","nullCodec"),("Undefined","undefinedCodec")]

haskellCodec :: [C.DataDeclaration] -> C.Type -> Either String String
haskellCodec declarations ty = D.render D.Compact <$> haskellCodecDoc declarations "schema" "bits" ty

haskellCodecDoc :: [C.DataDeclaration] -> String -> String -> C.Type -> Either String D.Doc
haskellCodecDoc = haskellCodecDocUsing Nothing

haskellCodecDocWithContext :: D.Doc -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String D.Doc
haskellCodecDocWithContext context = haskellCodecDocUsing (Just context)

haskellCodecDocUsing :: Maybe D.Doc -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String D.Doc
haskellCodecDocUsing context = haskellCodecDocIn context "Codecs."

haskellCodecDocIn :: Maybe D.Doc -> String -> [C.DataDeclaration] -> String -> String -> C.Type -> Either String D.Doc
haskellCodecDocIn context scope declarations schema bits ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  codecExpressionWith context schema bits scope names [] ty

emitHaskellCodecs :: D.Layout -> [C.DataDeclaration] -> Either String String
emitHaskellCodecs layout declarations =
  emitHaskellCodecsWithRepresentations layout declarations "LawSpecDataCodecs" [] [] []

-- Codec identities remain canonical even when their Haskell representations
-- come from application modules. Field mappings use record syntax in both
-- directions, so native declaration order cannot change the logical payload.
emitHaskellCodecsWithRepresentations
  :: D.Layout -> [C.DataDeclaration] -> String -> [String]
  -> [(C.Id, String)] -> [(C.Id, (String, [String]))]
  -> Either String String
emitHaskellCodecsWithRepresentations layout declarations owner imports representations constructors =
  emitHaskellCodecsWithHooks layout declarations owner imports representations constructors []

emitHaskellCodecsWithHooks
  :: D.Layout -> [C.DataDeclaration] -> String -> [String]
  -> [(C.Id, String)] -> [(C.Id, (String, [String]))] -> [(C.Id, (String, String))]
  -> Either String String
emitHaskellCodecsWithHooks layout declarations owner imports representations constructors hooks = do
  _ <- emitHaskellData layout declarations
  names <- namesFor declarations
  definitions <- mapM (definition names) declarations
  pure (D.render layout (D.joinWith D.hardline (map D.text $
    ["{-# LANGUAGE EmptyCase #-}", "-- Generated by LawSpec. Do not edit.",
     "module " ++ owner ++ " where", "", "import qualified Prelude as P",
     "import qualified LawSpecRuntime as LS", "import qualified LawSpecSchema as Schema",
     "import qualified LawSpecCodecs as Codec", "import qualified LawSpecData as Data", ""] ++
     map ("import qualified " ++) imports ++
     ["import qualified LawSpecDataCodecs as Canonical" | owner /= "LawSpecDataCodecs"]) <>
    D.hardline <> D.joinWith (D.hardline <> D.hardline) definitions <> D.hardline))
  where
    definition names declaration = do
      native <- maybe (Left "unplanned Haskell codec type") Right (lookup (C.dataId declaration) names)
      let parameters = zip (C.dataParameters declaration) ["a" ++ show n | n <- [0::Int ..]]
          codecs = zip (C.dataParameters declaration) ["element" ++ show n | n <- [0::Int ..]]
          result = application (maybe ("Data." ++ native) id
            (lookup (C.dataId declaration) representations)) (map snd parameters)
          types = map D.text (["Schema.Schema", "P.Int"] ++
            ["Codec.Codec " ++ name | (_,name) <- parameters] ++ ["Codec.Codec " ++ result])
          signature = D.group (D.text (codecName native ++ " :: ") <>
            D.nest 2 (D.joinWith (D.softline <> D.text "-> ") types)) <>
            D.hardline <> D.text (codecName native ++ " = " ++ codecName native ++ "With P.Nothing") <>
            D.hardline <> D.hardline <>
            D.group (D.text (codecName native ++ "With :: ") <>
              D.nest 2 (D.joinWith (D.softline <> D.text "-> ")
                (D.text "P.Maybe LS.SymbolContext" : types)))
          typeRef = apply "Schema.Named" [D.text (show (C.idText (C.dataId declaration))),
            list [apply "Codec.reference" [D.text value] | (_,value) <- codecs]]
          header = D.text (unwords ((codecName native ++ "With") : "symbols" : "schema" : "bits" : map snd codecs) ++ " =")
          expression = apply "Codec.codecWith" [D.text "symbols",D.text "schema",D.text "bits",parenthesize typeRef,
            D.text "decodeValue", D.text "encodeValue"]
      variants <- forM (C.dataConstructors declaration) $ \variant -> do
        constructor <- maybe (Left "unplanned Haskell codec constructor") Right
          (lookup (C.constructorId variant) names)
        let mapped = lookup (C.constructorId variant) constructors
        case mapped of
          Just (_, selectors) -> unless (length selectors == length (C.constructorFields variant))
            (Left ("Haskell native field mapping arity mismatch: " ++ C.idText (C.constructorId variant)))
          Nothing -> pure ()
        fields <- mapM (codecExpressionWith (Just (D.text "symbols")) "schema" "bits"
          (if owner /= "LawSpecDataCodecs" && lookup (C.dataId declaration) representations == Nothing then "Canonical." else "") names codecs . C.binderType) (C.constructorFields variant)
        let tag = C.idText (C.constructorId variant)
            values = ["value" ++ show n | n <- [0::Int .. length fields - 1]]
            converted = ["field" ++ show n | n <- [0::Int .. length fields - 1]]
            bindings method =
              [D.group (D.text (field ++ " <- ") <> D.nest 2
                (apply "Codec.context" [D.text (show (tag ++ "." ++ C.binderName binder)),
                  parenthesize (apply ("Codec." ++ method) [parenthesize converter,D.text value])]))
              | (binder,converter,value,field) <- zip4 (C.constructorFields variant) fields values converted]
            construct arguments = case mapped of
              Nothing -> apply ("Data." ++ constructor) (map D.text arguments)
              Just (name, []) -> D.text name
              Just (name, selectors) -> D.group (D.text (name ++ " {") <>
                D.nest 2 (D.softline <> D.joinWith (D.text "," <> D.softline)
                  [D.text (selector ++ " = " ++ value) | (selector,value) <- zip selectors arguments]) <>
                D.softline <> D.text "}")
            decodeHeader = D.text "decodeValue " <>
              parenthesize (apply "LS.SData" [D.text (show tag),list (map D.text values)]) <> D.text " = do"
            encodeHeader = D.text "encodeValue " <>
              parenthesize (construct values) <> D.text " = do"
            decodeBody = bindings "decode" ++
              [apply "P.pure" [parenthesize (construct converted)]]
            encodeBody = bindings "encode" ++
              [apply "P.pure" [parenthesize (apply "LS.SData" [D.text (show tag),list (map D.text converted)])]]
        pure (decodeHeader <> D.nest 2 (D.hardline <> D.joinWith D.hardline decodeBody),
          encodeHeader <> D.nest 2 (D.hardline <> D.joinWith D.hardline encodeBody))
      let decoders = map fst variants ++ [D.text "decodeValue _ = P.Left \"invalid checked constructor\""]
          encoders = if null variants then [D.text "encodeValue value = case value of {}"] else map snd variants
      implementations <- case lookup (C.dataId declaration) hooks of
        Nothing -> pure (decoders ++ encoders)
        Just (toNative,fromNative) -> do
          -- Type parameters stay opaque to the hook. Their checked logical
          -- values cross the supplied directional child converters.
          let logicalChild element = E.apply "Codec.codecWith"
                [D.text "symbols",D.text "schema",D.text "bits",apply "Codec.reference" [D.text element],
                 D.text "P.Right",D.text "P.Right"]
              canonical = E.apply ("Canonical." ++ codecName native ++ "With")
                ([D.text "symbols",D.text "schema",D.text "bits"] ++ map (logicalChild . snd) codecs)
              converters method = [D.group (D.text "\\child ->" <> D.nest 2 (D.softline <>
                E.checked (apply ("Codec." ++ method) [D.text element,D.text "child"]))) | (_,element) <- codecs]
              context direction statements = apply "Codec.context"
                [D.text (show ("native codec " ++ C.idText (C.dataId declaration) ++ " " ++ direction))] <>
                D.text " P.$ do" <> D.nest 2 (D.hardline <> D.joinWith D.hardline statements)
              binding name value = D.group (D.text (name ++ " <-") <> D.nest 2 (D.softline <> value))
          pure [D.group (D.text "logicalCodec =" <> D.nest 2 (D.softline <> canonical)),
            D.text "decodeValue value =" <> D.nest 2 (D.hardline <> context "toNative"
              [binding "canonical" (apply "Codec.decode" [D.text "logicalCodec",D.text "value"]),
               E.apply toNative (D.text "canonical" : converters "decode")]),
            D.text "encodeValue value =" <> D.nest 2 (D.hardline <> context "fromNative"
              [binding "canonical" (E.apply fromNative (D.text "value" : converters "encode")),
               apply "Codec.encode" [D.text "logicalCodec",D.text "canonical"]])]
      pure (signature <> D.hardline <> header <> D.nest 2 (D.hardline <> expression <>
        D.hardline <> D.text "where" <> D.nest 2 (D.hardline <>
          D.joinWith D.hardline implementations)))
