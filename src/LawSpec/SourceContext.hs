-- | Source constructor types retained until elaboration. Core remains the
-- authoritative executable representation; this catalogue preserves structural
-- products and their authored restrictions while inference instantiates a
-- nominal constructor's parameters and GADT equations.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module LawSpec.SourceContext
  ( SourceContext(..), SourceConstructor(..), emptyContext, instantiateSource ) where

import qualified Data.Map.Strict as M
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S

newtype SourceContext = SourceContext
  { constructorSources :: M.Map C.Id SourceConstructor }
  deriving (Eq,Show)

data SourceConstructor = SourceConstructor
  { sourceFields :: [S.Type]
  , sourceEquations :: [(C.Id,S.Type)]
  } deriving (Eq,Show)

emptyContext :: SourceContext
emptyContext = SourceContext M.empty

-- Constructor parameters are instantiated together in fields, restrictions
-- and expression annotations. Public record labels and lexical value binders
-- are not type variables and retain their spelling.
instantiateSource :: [(C.Id,S.Type)] -> SourceConstructor -> Either String ([S.Type],[(C.Id,S.Type)])
instantiateSource variables source = do
  fields <- mapM substitute (sourceFields source)
  equations <- mapM (\(name,ty) -> (,) name <$> substitute ty) (sourceEquations source)
  pure (fields,equations)
  where
    substitute ty = do
      let names = collect ty
      mapM_ (\name -> case lookup (C.Id name) variables of
        Nothing -> Left ("unbound source constructor parameter: " ++ name)
        Just _ -> Right ()) names
      pure (S.mapType change (S.mapExprTypes replace) ty)
    replace = S.mapType change (S.mapExprTypes replace)
    change (S.Variable name) = maybe (S.Variable name) id (lookup (C.Id name) variables)
    change other = other
    collect = S.typeVariableNames
