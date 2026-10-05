-- Native web type representations and schema references.
module LawSpec.WebTypes where

import LawSpec.DataNames (flatDataCandidates, productConstructors)
import Control.Monad (unless)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub, stripPrefix)
import LawSpec.Collections (collectionsUnit)
import Numeric (showHex)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.JavaScript as JS

q :: String -> String
q = JS.stringLiteral

type Names = [(C.Id,String)]

supportNames :: [String]
supportNames = words "Maybe Either Nothing Just Left Right Presence ls schema makeSchema Array Object Uint8Array Symbol Number String BigInt Math Map Set globalThis"

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let duplicate name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
      qualified = flatDataCandidates id (`elem` supportNames) declarations
      names = [(identity, if duplicate name qualified || name `elem` supportNames then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier True . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting JavaScript data identities")
  pure (names ++ productConstructors declarations names)

identifier :: Bool -> String -> Either String ()
identifier binding name = unless (valid && (not binding || name `notElem` reserved))
  (Left ("invalid JavaScript data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && (isLetter c || c == '_' || c == '$') && all (\x -> isAscii x && (isAlphaNum x || x `elem` ("_$" :: String))) cs
      [] -> False
    reserved = words "await break case catch class const continue debugger default delete do else enum export extends false finally for function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof var void while with yield any unknown never number bigint boolean string symbol object undefined intrinsic"

lookupName :: Names -> C.Id -> Either String String
lookupName names identity = maybe (Left "unplanned JavaScript data name") Right (lookup identity names)

application :: String -> [D.Doc] -> D.Doc
application name [] = D.text name
application name args = D.text name <> D.delimitTrailing 4 "<" ">" args

-- A handle's native type: its bound native type, or unknown.
type Handles = [(C.Id,D.Doc)]

handleTypes :: [C.DataDeclaration] -> Handles
handleTypes declarations = [(C.dataId d, D.text "unknown") | d <- declarations, C.dataHandle d]

typeDoc :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDoc = typeDocWith []

typeDocWith :: Handles -> String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDocWith handles scope names parameters ty = case ty of
  C.Constructor name [] | Just native <- lookup (C.Id name) handles -> pure native
  C.TypeVariable variable -> maybe (Left "unbound TypeScript data parameter") (Right . D.text) (lookup variable parameters)
  -- Built-in collections are native: see runtime/lawspec_schema.mjs.
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    let byValue = case arguments of C.TypeArgument (C.Constructor n []) : _ -> webByValue n; _ -> False
        readonly a = application "ReadonlyArray" [a]
    pure $ case (short, args) of
      ("Set", [a]) | byValue -> application "ReadonlySet" [a]
                   | otherwise -> readonly a
      ("KeyVal", [k, v]) | byValue -> application "ReadonlyMap" [k, v]
                         | otherwise -> readonly (D.text "readonly [" <> k <> D.text ", " <> v <> D.text "]")
      (_, [a]) -> readonly a
      _ -> D.text "unknown"
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (application (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (application "Array" args)
        ("Maybe",[_]) -> pure (application (scope ++ "Maybe") args)
        ("Either",[_,_]) -> pure (application (scope ++ "Either") args)
        (n,[_]) | n `elem` ["Nullable","Optional"] -> pure (application (scope ++ "Presence") args)
        (_,[]) | Just _ <- primitive name -> D.text <$> nativeScalar name
        _ -> Left ("no TypeScript representation for " ++ show ty)
  _ -> Left ("no TypeScript data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeDocWith handles scope names parameters value
    argument _ = Left "indexed JavaScript data is not supported"
    nativeScalar name
      | name `elem` ["Int8","Int16","Int32","UInt8","UInt16","UInt32","CodePoint","CodeUnit16","Float32","Float64"] = Right "number"
      | isInteger name = Right "bigint"
      | otherwise = case name of
          "Bool" -> Right "boolean"
          "Char" -> Right "string"
          "Text" -> Right "string"
          "Bytes" -> Right "Uint8Array"
          "Complex64" -> Right "ls.Complex"
          "Complex128" -> Right "ls.Complex"
          "Decimal" -> Right "ls.Decimal"
          "Rational" -> Right "ls.Rational"
          "Symbol" -> Right "symbol"
          "Unit" -> Right "typeof ls.UNIT"
          "Null" -> Right "null"
          "Undefined" -> Right "undefined"
          "CodePointText" -> Right "ls.Raw"
          "Utf16Text" -> Right "ls.Raw"
          _ -> Left ("no TypeScript scalar representation for " ++ name)

requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

webDataType :: [C.DataDeclaration] -> C.Type -> Either String String
webDataType declarations ty = D.render (D.Pretty 80) <$> webDataTypeDoc declarations ty

webDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
webDataTypeDoc declarations = webDataTypeDocWith declarations []

-- Bound handles name their native types; other handles are unknown.
webDataTypeDocWith :: [C.DataDeclaration] -> Handles -> C.Type -> Either String D.Doc
webDataTypeDocWith declarations bound ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDocWith (bound ++ handleTypes declarations) "data." names [] ty

reference :: S.TypeRef -> D.Doc
reference (S.Parameter n) = D.text ("new schema.Parameter(" ++ show n ++ ")")
reference (S.Named name arguments) = invoke "new schema.Named"
  ([D.text (q name)] ++ [array (map reference arguments) | not (null arguments)])

webTypeReference :: C.Type -> Either String String
webTypeReference ty = D.render (D.Pretty 80) <$> webTypeReferenceDoc ty

webTypeReferenceDoc :: C.Type -> Either String D.Doc
webTypeReferenceDoc ty = reference <$> S.typeReference [] ty

invoke :: String -> [D.Doc] -> D.Doc
invoke name values = D.text name <> D.delimitTrailing 4 "(" ")" values

array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 2 "[" "]"


-- A built-in collection container's short name.
collectionContainer :: String -> Maybe String
collectionContainer name = case stripPrefix (collectionsUnit ++ "::type::") name of
  Just short | short `elem` ["Set", "KeyVal", "Queue", "Stack", "Deque"] -> Just short
  _ -> Nothing

-- Scalars whose JavaScript natives compare by value.
webByValue :: String -> Bool
webByValue n = isInteger n || n `elem` ["Bool", "Char", "Text", "CodePoint", "CodeUnit16", "Unit"]
