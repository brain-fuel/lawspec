-- Python names, type representations and schema references shared by emitters.
module LawSpec.PythonTypes where

import LawSpec.DataNames (flatDataCandidates)
import Control.Monad (unless)
import Data.Char (isAscii, isAlphaNum, isLetter, toLower, ord)
import Data.List (nub)
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

type Names = [(C.Id,String)]

namesFor :: [C.DataDeclaration] -> Either String Names
namesFor declarations = do
  let duplicate name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
      qualified = flatDataCandidates id (const False) declarations
      names = [(identity, if duplicate name qualified then name ++ "_" ++ concatMap (\c -> showHex (ord c) "_") (C.idText identity) else name) | (identity,name) <- qualified]
  mapM_ (identifier . snd) names
  unless (length names == length (nub (map (map toLower . snd) names))) (Left "conflicting Python data identities")
  pure names

identifier :: String -> Either String ()
identifier name = unless (valid && name `notElem` reserved)
  (Left ("invalid Python data identifier: " ++ name))
  where
    valid = case name of
      c:cs -> isAscii c && (isLetter c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
      [] -> False
    reserved = words "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield _builtins _dataclasses _schema ls make_schema"

lookupName :: Names -> C.Id -> Either String String
lookupName names identity = maybe (Left "unplanned Python data name") Right (lookup identity names)

application :: String -> [D.Doc] -> D.Doc
application name [] = D.text name
application name args = D.text name <> D.delimit 4 "[" "]" args

typeDoc :: String -> Names -> [(C.Id,String)] -> C.Type -> Either String D.Doc
typeDoc scope names parameters ty = case ty of
  C.TypeVariable variable -> maybe (Left "unbound Python data parameter") (Right . D.text) (lookup variable parameters)
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
    argument (C.TypeArgument value) = typeDoc scope names parameters value
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

requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

pythonDataType :: [C.DataDeclaration] -> C.Type -> Either String String
pythonDataType declarations ty = D.render (D.Pretty 79) <$> pythonDataTypeDoc declarations ty

pythonDataTypeDoc :: [C.DataDeclaration] -> C.Type -> Either String D.Doc
pythonDataTypeDoc declarations ty = do
  registry <- makeRegistry declarations
  checkType registry ty
  names <- namesFor declarations
  typeDoc "data." names [] ty

reference :: S.TypeRef -> D.Doc
reference (S.Parameter n) = D.text ("_schema.Parameter(" ++ show n ++ ")")
reference (S.Named name arguments) = invoke "_schema.Named"
  ([quotedName name] ++ [array (map reference arguments) | not (null arguments)])

-- Adjacent string tokens preserve identity while allowing narrow nested types.
quotedName :: String -> D.Doc
quotedName name = D.prefixChoice (q name) (D.text (q name))
  (D.group (D.text "(" <> D.nest 4
    (D.softbreak <> D.joinWith D.softline (map (D.text . q) (chunks name))) <>
    D.softbreak <> D.text ")"))
  where
    chunks [] = []
    chunks rest = take 4 rest : chunks (drop 4 rest)

pythonTypeReference :: C.Type -> Either String String
pythonTypeReference ty = D.render (D.Pretty 79) <$> pythonTypeReferenceDoc ty

pythonTypeReferenceDoc :: C.Type -> Either String D.Doc
pythonTypeReferenceDoc ty = reference <$> S.typeReference [] ty

invoke :: String -> [D.Doc] -> D.Doc
invoke name values = D.text name <> D.delimitTrailing 4 "(" ")" values

array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 4 "[" "]"

suite :: D.Doc -> D.Doc -> D.Doc
suite header body = header <> D.text ":" <> D.nest 4 (D.hardline <> body)

