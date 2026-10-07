-- | Shared resolved Haskell runtime type references.
module LawSpec.HaskellTypeRefs (requiresSchema, reference, haskellTypeReference, haskellTypeReferenceDoc) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D

apply :: String -> [D.Doc] -> D.Doc
apply name arguments = D.group (D.text name <> D.nest 2
  (mconcat [D.softline <> argument | argument <- arguments]))

list :: [D.Doc] -> D.Doc
list = D.delimit 2 "[" "]"

-- | Values of these types need the runtime's schema to cross the adapter
-- boundary; plain scalars do not.
requiresSchema :: [C.DataDeclaration] -> C.Type -> Bool
requiresSchema declarations ty = case ty of
  C.Constructor name arguments -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
    any ((== C.Id name) . C.dataId) declarations ||
    any (\a -> case a of C.TypeArgument value -> requiresSchema declarations value; _ -> False) arguments
  C.Arrow a b -> requiresSchema declarations a || requiresSchema declarations b
  _ -> False

reference :: S.TypeRef -> D.Doc
reference (S.Parameter index) = apply "Schema.Parameter" [D.text (show index)]
reference (S.Named name arguments) = apply "Schema.Named"
  [D.text (show name), list (map reference arguments)]

-- | The runtime validates values against a schema reference built from the type.
haskellTypeReference :: C.Type -> Either String String
haskellTypeReference ty = D.render D.Compact <$> haskellTypeReferenceDoc ty

haskellTypeReferenceDoc :: C.Type -> Either String D.Doc
haskellTypeReferenceDoc ty = reference <$> S.typeReference [] ty

