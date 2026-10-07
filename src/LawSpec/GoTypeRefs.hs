-- | Go runtime type references shared by schema and expression emission.
module LawSpec.GoTypeRefs (reference, goTypeReference, requiresSchema, goDataKey) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import Data.List (intercalate)
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

q :: String -> String
q = T.unpack . T.decodeUtf8 . encode

reference :: S.TypeRef -> String
reference (S.Parameter index) = "lsParameter(" ++ show index ++ ")"
reference (S.Named name arguments) = "lsNamed(" ++ intercalate ", " (q name : map reference arguments) ++ ")"

-- | The runtime validates values against a schema reference built from the type.
goTypeReference :: C.Type -> Either String String
goTypeReference ty = reference <$> S.typeReference [] ty


-- | Values of these types need the runtime's schema to cross the adapter
-- boundary; plain scalars do not.
requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

-- | Go runtime data is keyed by a type's text, nested arguments included, so
-- List Int8 and List Int16 stay apart.
goDataKey :: C.Type -> String
goDataKey (C.Constructor name arguments) = case [t | C.TypeArgument t <- arguments] of
  [] -> name
  [ty] -> name ++ " " ++ goDataKey ty
  types -> name ++ concatMap (\ty -> " (" ++ goDataKey ty ++ ")") types
goDataKey ty = show ty

