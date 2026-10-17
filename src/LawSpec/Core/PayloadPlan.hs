-- | Finite parameter-provenance metadata shared by execution and proof lowering.
module LawSpec.Core.PayloadPlan
  ( Plan(..), Schema, fromRegistry, entry, arity, fields, storedParameters,recordTag,recordInstances ) where

import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Core.Types (TypeRegistry, registryDeclarations)
import qualified LawSpec.Core.RecordInstances as R

-- | Which parts of a value hold a type parameter's payload, so a predicate over
-- payloads visits only those.
data Plan = Ignore | Parameter Int | Applied String [Plan]
  deriving (Eq, Show)

-- | Only checked registries can create schemas; recursive declarations stay as
-- references rather than an eagerly expanded tree.
data Schema = Schema [(String, [Id], [(Id, [Type])])] [(String,Id)] R.RecordInstances
  deriving (Eq, Ord, Show)

-- | Plans come only from a checked registry, so they never describe an
-- ill-formed type.
fromRegistry :: TypeRegistry -> Schema
fromRegistry registry = Schema
  [(idText (dataId d), dataParameters d,
    [(constructorId c, map binderType (constructorFields c)) | c <- dataConstructors d])
    | d <- registryDeclarations registry]
  [(idText (dataId d),constructorId c) | d<-registryDeclarations registry,dataStructural d/=Nothing,[c]<-[dataConstructors d]]
  (R.fromRegistry registry)

recordTag :: Schema -> Type -> Maybe Id
recordTag (Schema _ tags _) (Constructor name _) = lookup name tags
recordTag _ _ = Nothing

recordInstances :: Schema -> R.RecordInstances
recordInstances (Schema _ _ instances) = instances

entry :: Schema -> String -> Either String ([Id], [(Id, [Type])])
entry (Schema declarations _ _) name = maybe (Left ("unknown payload data type: " ++ name)) Right
  (lookup name [(n,(parameters,constructors)) | (n,parameters,constructors) <- declarations])

-- | Optional types take one parameter whatever the registry says.
arity :: Schema -> String -> Either String Int
arity _ name | name `elem` ["Nullable", "Optional"] = Right 1
arity schema name = length . fst <$> entry schema name

-- | A constructor's fields are planned with the type's arguments substituted.
fields :: Schema -> String -> Id -> [Plan] -> Either String [Plan]
fields schema name tag arguments = do
  (parameters,constructors) <- entry schema name
  unless (length parameters == length arguments) (Left "payload plan arity mismatch")
  types <- maybe (Left "unknown payload constructor") Right (lookup tag constructors)
  mapM (recipe (M.fromList (zip parameters arguments))) types

recipe :: M.Map Id Plan -> Type -> Either String Plan
recipe environment ty = case ty of
  TypeVariable name -> maybe (Left "unbound payload parameter") Right (M.lookup name environment)
  Constructor name arguments -> do
    children <- mapM argument arguments
    pure (if all (== Ignore) children then Ignore else Applied name children)
  Arrow _ _ -> Left "payload predicates cannot traverse function fields"
  where
    argument (TypeArgument child) = recipe environment child
    argument _ = Left "payload traversal requires type arguments"

-- | A least fixed point over parameter positions handles mutual and growing
-- recursion while recognizing genuinely phantom parameters.
storedParameters :: Schema -> String -> Either String [Int]
storedParameters schema@(Schema declarations _ _) name = do
  _ <- arity schema name
  pure (S.toAscList (M.findWithDefault S.empty name (settle initial)))
  where
    initial = M.fromList [(n,S.singleton 0) | n <- ["Nullable","Optional"]]
    settle known =
      let next = M.unionWith S.union known (M.fromList
            [(n,S.unions [uses known parameters ty | (_,types) <- constructors,ty <- types])
              | (n,parameters,constructors) <- declarations])
      in if next == known then known else settle next
    uses known parameters ty = case ty of
      TypeVariable identity -> S.fromList [i | (i,p) <- zip [0..] parameters,p == identity]
      Constructor n args -> S.unions
        [uses known parameters child | (i,TypeArgument child) <- zip [0..] args,
          i `S.member` M.findWithDefault S.empty n known]
      Arrow left right -> uses known parameters left `S.union` uses known parameters right
