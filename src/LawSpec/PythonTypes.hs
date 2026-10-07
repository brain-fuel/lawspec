-- | Python names, type representations and schema references shared by emitters.
module LawSpec.PythonTypes where

import LawSpec.DataNames (flatDataCandidates, productConstructors, caseInsensitiveCounts, ambiguous)
import Control.Monad (unless)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub, stripPrefix)
import LawSpec.Collections (collectionsUnit)
import LawSpec.Time (isDurationType)
import Numeric (showHex)
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D

q :: String -> String
q = T.unpack . T.decodeUtf8 . encode

-- | Generated Python names for each data declaration, planned once so every
-- module of a project uses the same name.
type Names = [(C.Id,String)]

-- | Two declarations whose names differ only in case would collide on
-- case-insensitive file systems, so they are refused.
namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let qualifiedCounts = caseInsensitiveCounts qualified
      qualified = flatDataCandidates id (const False) declarations
      names = [(identity, if ambiguous qualifiedCounts name then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting Python data identities")
  pure (names ++ productConstructors declarations names)

-- | A data name must be a valid identifier and not a keyword, or the generated
-- module would not import.
identifier :: String -> Either String ()
identifier name = unless (valid && name `notElem` reserved)
  (Left ("invalid Python data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && (isLetter c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
      [] -> False
    reserved = words "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield _builtins _dataclasses _schema ls make_schema"

-- | A built-in collection container's short name.
collectionContainer :: String -> Maybe String
collectionContainer name = case stripPrefix (collectionsUnit ++ "::type::") name of
  Just short | short `elem` ["Set", "KeyVal", "Queue", "Stack", "Deque"] -> Just short
  _ -> Nothing

-- | Scalars whose Python natives compare and hash by value.
pythonHashable :: String -> Bool
pythonHashable n = isInteger n || n `elem` ["Bool", "Char", "Text", "Bytes", "Decimal", "Rational", "CodePoint", "CodeUnit16", "Unit"]

-- | Every name used was planned; a miss is a compiler bug.
lookupName :: Names -> C.Id -> Either String String
lookupName names identity = maybe (Left "unplanned Python data name") Right (lookup identity names)

application :: String -> [D.Doc] -> D.Doc
application name [] = D.text name
application name args = D.text name <> D.delimit 4 "[" "]" args

-- | A handle's native type: its bound native type, or any object.
type Handles = [(C.Id,D.Doc)]

-- | LawSpec never looks inside a handle, so Python types it as any object unless
-- a binding names its native type.
handleTypes :: [C.DataDeclaration] -> Handles
handleTypes declarations = [(C.dataId d, D.text "_builtins.object") | d <- declarations, C.dataHandle d]

typeDoc :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDoc = typeDocWith []

-- | Type hints mirror LawSpec's types, so a type checker sees the same shapes the
-- laws use. ref:DEC-idiomatic-generated-types
typeDocWith :: Handles -> String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDocWith handles scope names parameters ty = case ty of
  C.Constructor name [] | Just native <- lookup (C.Id name) handles -> pure native
  C.TypeVariable variable -> maybe (Left "unbound Python data parameter") (Right . D.text) (lookup variable parameters)
  -- A Duration is a timedelta: see runtime/lawspec_schema.py.
  C.Constructor name [] | isDurationType name -> pure (D.text "ls.timedelta")
  -- Built-in collections are native: see runtime/lawspec_schema.py.
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    let byValue = case arguments of C.TypeArgument (C.Constructor n []) : _ -> pythonHashable n; _ -> False
    pure $ case (short, args) of
      ("Set", [a]) | byValue -> application "_builtins.frozenset" [a]
                   | otherwise -> application "_builtins.tuple" [a, D.text "..."]
      ("KeyVal", [k, v]) | byValue -> application "_builtins.dict" [k, v]
                         | otherwise -> application "_builtins.tuple" [application "_builtins.tuple" [k, v], D.text "..."]
      (_, [a]) -> application "ls.deque" [a]
      _ -> D.text "_builtins.object"
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (application (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (application "_builtins.list" args)
        ("Maybe",[_]) -> pure (application "_schema.Maybe" args)
        ("Either",[_,_]) -> pure (application "_schema.Either" args)
        (n,[_]) | n `elem` ["Nullable","Optional"] -> pure (D.text "ls.Presence")
        (_,[]) | Just _ <- primitive name -> D.text <$> nativeScalar name
        _ -> Left ("no Python representation for " ++ show ty)
  _ -> Left ("no Python data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeDocWith handles scope names parameters value
    argument _ = Left "indexed Python data is not supported"
    nativeScalar name
      | isInteger name || name `elem` ["CodePoint","CodeUnit16"] = Right "_builtins.int"
      | otherwise = case name of
          "Bool" -> Right "_builtins.bool"
          "Char" -> Right "_builtins.str"
          "Text" -> Right "_builtins.str"
          "Bytes" -> Right "_builtins.bytes"
          "Float32" -> Right "_builtins.float"
          "Float64" -> Right "_builtins.float"
          "Complex64" -> Right "_builtins.complex"
          "Complex128" -> Right "_builtins.complex"
          "Decimal" -> Right "ls.Decimal"
          "Rational" -> Right "ls.Fraction"
          "Symbol" -> Right "ls.Symbol"
          "Unit" -> Right "ls.Absence"
          "Null" -> Right "ls.Absence"
          "Undefined" -> Right "ls.Absence"
          "CodePointText" -> Right "ls.Raw"
          "Utf16Text" -> Right "ls.Raw"
          _ -> Left ("no Python scalar representation for " ++ name)

-- | Values of these types need the runtime's schema to cross the adapter
-- boundary; plain scalars do not.
requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

-- | Python output is laid out at 79 columns, as PEP 8 asks. ref:pep-8
pythonDataType :: [C.DataDeclaration] -> C.Type -> Either String String
pythonDataType declarations ty = D.render (D.Pretty 79) <$> pythonDataTypeDoc declarations ty

-- | Types are checked against the registry before rendering, so an unknown type
-- is a compiler error rather than an invalid hint.
pythonDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
pythonDataTypeDoc declarations = pythonDataTypeDocWith declarations []

-- | Bound handles name their native types; other handles are any object.
pythonDataTypeDocWith :: [C.DataDeclaration] -> Handles -> C.Type -> Either String D.Doc
pythonDataTypeDocWith declarations bound ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDocWith (bound ++ handleTypes declarations) "data." names [] ty

reference :: S.TypeRef -> D.Doc
reference (S.Parameter n) = D.text ("_schema.Parameter(" ++ show n ++ ")")
reference (S.Named name arguments) = invoke "_schema.Named"
  ([quotedName name] ++ [array (map reference arguments) | not (null arguments)])

-- | Adjacent string tokens preserve identity while allowing narrow nested types.
quotedName :: String -> D.Doc
quotedName name = D.prefixChoice (q name) (D.text (q name))
  (D.group (D.text "(" <> D.nest 4
    (D.softbreak <> D.joinWith D.softline (map (D.text . q) (chunks name))) <>
    D.softbreak <> D.text ")"))
  where
    chunks [] = []
    chunks rest = take 4 rest : chunks (drop 4 rest)

-- | The runtime validates values against a schema reference built from the type.
pythonTypeReference :: C.Type -> Either String String
pythonTypeReference ty = D.render (D.Pretty 79) <$> pythonTypeReferenceDoc ty

pythonTypeReferenceDoc :: C.Type -> Either String D.Doc
pythonTypeReferenceDoc ty = reference <$> S.typeReference [] ty

invoke :: String -> [D.Doc] -> D.Doc
invoke name values = D.text name <> D.delimitTrailing 4 "(" ")" values

array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 4 "[" "]"

-- | Python blocks are a colon and an indented body, four spaces as PEP 8 asks.
-- ref:pep-8
suite :: D.Doc -> D.Doc -> D.Doc
suite header body = header <> D.text ":" <> D.nest 4 (D.hardline <> body)

