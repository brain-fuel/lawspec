-- | Native web type representations and schema references.
module LawSpec.WebTypes where

import LawSpec.DataNames (flatDataCandidates, productConstructors)
import LawSpec.RecordNames (recordDisplayNames)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Control.Monad (unless)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower)
import Data.List (nub, stripPrefix)
import LawSpec.Collections (collectionsUnit)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Core.Types (makeRegistry, checkType)
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.ECMAScript as E

-- | A string literal as Prettier writes it.
q :: String -> String
q = E.javascriptLiteral

-- | Generated JavaScript names for each data declaration, planned once so every
-- file of a project uses the same name.
type Names = [(C.Id,String)]

-- | Names the generated support code already uses, which no data type may take.
supportNames :: [String]
supportNames = words "Maybe Either Absent Present Left Right Presence ls schema makeSchema Array Object Uint8Array Symbol Number String BigInt Math Map Set globalThis"

-- | Two declarations whose names differ only in case would collide on
-- case-insensitive file systems, so they are refused.
namesFor :: [C.DataDeclaration] -> Either String Names
namesFor given = do
  -- An anonymous record shows a name from where it is used (LawSpec.RecordNames).
  let display = recordDisplayNames given
      declarations = [maybe d (\n -> d {C.dataName = n}) (M.lookup (C.dataId d) display) | d <- given]
      qualified = flatDataCandidates id (`elem` supportNames) declarations
      -- A name still taken, ignoring case, gets _2, _3 in declaration order.
      names = snd (foldl (\(taken, acc) (identity, name) ->
        let chosen = case [c | c <- name : [name ++ "_" ++ show n | n <- [2 :: Int ..]], map toLower c `Set.notMember` taken] of
              c : _ -> c
              [] -> name
        in (Set.insert (map toLower chosen) taken, acc ++ [(identity, chosen)]))
        (Set.fromList (map (map toLower) supportNames), []) qualified)
  mapM_ (identifier True . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting JavaScript data identities")
  pure (names ++ productConstructors declarations names)

-- | A data name must be a valid identifier and, where it binds, not a reserved
-- word, or the generated module would not load.
identifier :: Bool -> String -> Either String ()
identifier binding name = unless (valid && (not binding || name `notElem` reserved))
  (Left ("invalid JavaScript data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && (isLetter c || c == '_' || c == '$') && all (\x -> isAscii x && (isAlphaNum x || x `elem` ("_$" :: String))) cs
      [] -> False
    reserved = words "await break case catch class const continue debugger default delete do else enum export extends false finally for function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof var void while with yield any unknown never number bigint boolean string symbol object undefined intrinsic"

-- | Every name used was planned; a miss is a compiler bug.
lookupName :: Names -> C.Id -> Either String String
lookupName names identity = maybe (Left "unplanned JavaScript data name") Right (lookup identity names)

application :: String -> [E.Type] -> E.Type
application = E.TRef

-- | A handle's native type: its bound native type, or unknown.
type Handles = [(C.Id,E.Type)]

-- | LawSpec never looks inside a handle, so TypeScript types it unknown unless a
-- binding names its native type.
handleTypes :: [C.DataDeclaration] -> Handles
handleTypes declarations = [(C.dataId d, E.TKeyword "unknown") | d <- declarations, C.dataHandle d]

typeDoc :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String E.Type
typeDoc = typeDocWith []

-- | TypeScript types mirror LawSpec's, so the compiler checks adapters against
-- the same shapes the laws use. ref:DEC-idiomatic-generated-types
typeDocWith :: Handles -> String -> Names -> [(C.Id,String)] -> C.Type -> Either String E.Type
typeDocWith handles scope names parameters ty = case ty of
  C.Constructor name [] | Just native <- lookup (C.Id name) handles -> pure native
  C.TypeVariable variable -> maybe (Left "unbound TypeScript data parameter") (Right . E.TKeyword) (lookup variable parameters)
  -- Built-in collections are native: see runtime/lawspec_schema.mjs.
  C.Constructor name arguments | Just short <- collectionContainer name -> do
    args <- mapM argument arguments
    let byValue = case arguments of C.TypeArgument (C.Constructor n []) : _ -> webByValue n; _ -> False
        readonly a = application "ReadonlyArray" [a]
    pure $ case (short, args) of
      ("Set", [a]) | byValue -> application "ReadonlySet" [a]
                   | otherwise -> readonly a
      ("KeyVal", [k, v]) | byValue -> application "ReadonlyMap" [k, v]
                         | otherwise -> readonly (E.TReadonly (E.TTuple [k, v]))
      (_, [a]) -> readonly a
      _ -> E.TKeyword "unknown"
  C.Constructor name arguments -> do
    args <- mapM argument arguments
    case lookup (C.Id name) names of
      Just native -> pure (application (scope ++ native) args)
      Nothing -> case (name,args) of
        ("List",[_]) -> pure (application "Array" args)
        ("Maybe",[_]) -> pure (application (scope ++ "Maybe") args)
        ("Either",[_,_]) -> pure (application (scope ++ "Either") args)
        (n,[_]) | n `elem` ["Nullable","Optional"] -> pure (application (scope ++ "Presence") args)
        (_,[]) | Just _ <- primitive name -> nativeScalar name
        _ -> Left ("no TypeScript representation for " ++ show ty)
  _ -> Left ("no TypeScript data representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeDocWith handles scope names parameters value
    argument _ = Left "indexed JavaScript data is not supported"
    nativeScalar name
      | name `elem` ["Int8","Int16","Int32","UInt8","UInt16","UInt32","CodePoint","CodeUnit16","Float32","Float64"] = Right (E.TKeyword "number")
      | isInteger name = Right (E.TKeyword "bigint")
      | otherwise = case name of
          "Bool" -> Right (E.TKeyword "boolean")
          "Char" -> Right (E.TKeyword "string")
          "Text" -> Right (E.TKeyword "string")
          "Bytes" -> Right (E.TRef "Uint8Array" [])
          "Complex64" -> Right (E.TRef "ls.Complex" [])
          "Complex128" -> Right (E.TRef "ls.Complex" [])
          "Decimal" -> Right (E.TRef "ls.Decimal" [])
          "Rational" -> Right (E.TRef "ls.Rational" [])
          "Symbol" -> Right (E.TKeyword "symbol")
          "Unit" -> Right (E.TKeyword "typeof ls.UNIT")
          "Null" -> Right (E.TKeyword "null")
          "Undefined" -> Right (E.TKeyword "undefined")
          "CodePointText" -> Right (E.TRef "ls.Raw" [])
          "Utf16Text" -> Right (E.TRef "ls.Raw" [])
          _ -> Left ("no TypeScript scalar representation for " ++ name)

-- | Values of these types need the runtime's schema to cross the adapter
-- boundary; plain scalars do not.
requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

-- | A data type as TypeScript writes it, on one line.
webDataType :: [C.DataDeclaration] -> C.Type -> Either String String
webDataType declarations ty = E.printType <$> webDataTypeOf declarations ty

-- | Types are checked against the registry before rendering, so an unknown type
-- is a compiler error rather than invalid TypeScript.
webDataTypeOf :: [C.DataDeclaration] -> C.Type -> Either String E.Type
webDataTypeOf declarations = webDataTypeOfWith declarations []

-- | Bound handles name their native types; other handles are unknown.
webDataTypeOfWith :: [C.DataDeclaration] -> Handles -> C.Type -> Either String E.Type
webDataTypeOfWith declarations bound ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDocWith (bound ++ handleTypes declarations) "data." names [] ty

-- | As webDataTypeOf, as one-line text in a layout document.
webDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
webDataTypeDoc declarations ty = D.text <$> webDataType declarations ty

webDataTypeDocWith :: [C.DataDeclaration] -> Handles -> C.Type -> Either String D.Doc
webDataTypeDocWith declarations bound ty = D.text . E.printType <$> webDataTypeOfWith declarations bound ty

-- | A schema reference: new schema.Named("T", [arguments]).
reference :: S.TypeRef -> E.Expr
reference (S.Parameter n) = E.new' "schema.Parameter" [E.num (toInteger n)]
reference (S.Named name arguments) = E.new' "schema.Named"
  ([E.Str name] ++ [E.Array (map reference arguments) | not (null arguments)])

-- | The runtime validates values against a schema reference built from the type.
webTypeReference :: C.Type -> Either String E.Expr
webTypeReference ty = reference <$> S.typeReference [] ty

-- | A reference for a type Core has checked.
referenceExpr' :: C.Type -> E.Expr
referenceExpr' = either error id . webTypeReference

-- | As webTypeReference, as one-line text in a layout document.
webTypeReferenceDoc :: C.Type -> Either String D.Doc
webTypeReferenceDoc ty = D.text . E.printFlat E.JavaScript <$> webTypeReference ty


-- | A built-in collection container's short name.
collectionContainer :: String -> Maybe String
collectionContainer name = case stripPrefix (collectionsUnit ++ "::type::") name of
  Just short | short `elem` ["Set", "KeyVal", "Queue", "Stack", "Deque"] -> Just short
  _ -> Nothing

-- | Scalars whose JavaScript natives compare by value.
webByValue :: String -> Bool
webByValue n = isInteger n || n `elem` ["Bool", "Char", "Text", "CodePoint", "CodeUnit16", "Unit"]
