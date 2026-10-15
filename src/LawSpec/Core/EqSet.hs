-- | The representation contract for canonical Eq-only sets. Storage order is
-- observable through iteration; equality compares membership independently of
-- that order. The existing ordered collection remains a distinct type.
module LawSpec.Core.EqSet
  ( eqSetTypeId, eqSetConstructorId, eqSetDeclaration, isEqSetType
  , validateEqSetDeclaration, sameMembers, distinctMembers
  ) where

import Control.Monad (unless)
import LawSpec.Core

eqSetTypeId, eqSetConstructorId :: Id
eqSetTypeId = Id "lawspec.collections::type::EqSet"
eqSetConstructorId = Id (idText eqSetTypeId ++ "::EqSetItems")

-- | An ordinary, opaque nominal product; operations are checked definitions.
-- This internal identity is not an additional authoring type or capability.
eqSetDeclaration :: DataDeclaration
eqSetDeclaration = DataDeclaration eqSetTypeId "Set" [parameter]
  [DataConstructor eqSetConstructorId "EqSetItems"
    [Binder (Id (idText eqSetConstructorId ++ "::items")) "items"
      (Constructor "List" [TypeArgument (TypeVariable parameter)])]
    [] origin [] []] origin Nothing
  where
    parameter = Id (idText eqSetTypeId ++ "::a")
    origin = GeneratedFrom eqSetTypeId

isEqSetType :: Type -> Bool
isEqSetType (Constructor name [TypeArgument _]) = name == idText eqSetTypeId
isEqSetType _ = False

-- | Runtime equality recognizes the reserved constructor identity. Refuse a
-- declaration which would give that identity another shape or owner.
validateEqSetDeclaration :: DataDeclaration -> Either String ()
validateEqSetDeclaration declaration
  | dataId declaration /= eqSetTypeId =
      unless (all ((/= eqSetConstructorId) . constructorId) (dataConstructors declaration))
        (Left "the Eq-only set constructor belongs to its reserved type")
  | otherwise = unless shape (Left "the Eq-only set representation requires one List field and one type parameter")
  where
    shape = not (dataHandle declaration) && dataIndex declaration == Nothing &&
      case (dataParameters declaration, dataConstructors declaration) of
        ([parameter], [constructor]) -> constructorId constructor == eqSetConstructorId &&
          null (constructorPredicates constructor) && null (constructorExistentials constructor) &&
          null (constructorEquations constructor) &&
          case constructorFields constructor of
            [field] -> binderType field == Constructor "List" [TypeArgument (TypeVariable parameter)]
            _ -> False
        _ -> False

-- | Mutual membership, using language equality rather than host Eq, hashing,
-- sorting, identity shortcuts or multiset pairing. A NaN has no equal member,
-- including itself; a set containing one is consequently non-reflexive.
sameMembers :: Monad m => (a -> a -> m Bool) -> [a] -> [a] -> m Bool
sameMembers equal left right = do
  forward <- included left right
  if forward then included right left else pure False
  where
    included [] _ = pure True
    included (value:rest) candidates = do
      found <- member value candidates
      if found then included rest candidates else pure False
    member _ [] = pure False
    member value (candidate:rest) = do
      same <- equal value candidate
      if same then pure True else member value rest

-- | Non-reflexive values are permitted and never silently identified with one
-- another. Iteration order is retained; this checks, rather than repairs, a
-- representation supplied at a checked boundary.
distinctMembers :: Monad m => (a -> a -> m Bool) -> [a] -> m Bool
distinctMembers equal = go []
  where
    go _ [] = pure True
    go previous (value:rest) = do
      duplicate <- member value previous
      if duplicate then pure False else go (value:previous) rest
    member _ [] = pure False
    member value (candidate:rest) = do
      same <- equal value candidate
      if same then pure True else member value rest
