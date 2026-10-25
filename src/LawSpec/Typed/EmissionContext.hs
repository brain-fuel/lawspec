-- | Checked type and native-name contexts for independent emission chunks.
-- Helpers are named before lowering; a function records only its own requests.
-- ref:DEC-content-identity ref:DEC-incremental-compilation
module LawSpec.Typed.EmissionContext
  ( expressionTypes, definitionTypes, typeClosure, helperAllocation, calledFunctions ) where

import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core
import qualified LawSpec.Dependencies as Identity
import LawSpec.Typed.Plan

expressionTypes :: Expr -> [Type]
expressionTypes expression = expressionType expression : concatMap expressionTypes (children expression)

definitionTypes :: Definition -> [Type]
definitionTypes definition = declarationType (definitionDeclaration definition) :
  map binderType (definitionArguments definition) ++ expressionTypes (definitionBody definition)

-- Expand instantiated fields, stopping expansion of a recursive constructor
-- on its current path. Unknown further instantiations retain content names.
typeClosure :: M.Map String DataDeclaration -> [Type] -> [Type]
typeClosure declarations = S.toAscList . S.unions . map (walk S.empty)
  where
    walk seen ty = S.insert ty $ case ty of
      Constructor name arguments ->
        let args = [t | TypeArgument t <- arguments]
            fields = case M.lookup name declarations of
              Just declaration | name `S.notMember` seen ->
                [substitute (zip (dataParameters declaration) args) (binderType field) |
                  constructor <- dataConstructors declaration, field <- constructorFields constructor]
              _ -> []
        in S.unions (map (walk (S.insert name seen)) (args ++ fields))
      Arrow a b -> S.union (walk seen a) (walk seen b)
      _ -> S.empty
    substitute bindings ty = case ty of
      TypeVariable identity -> M.findWithDefault ty identity (M.fromList bindings)
      Constructor name arguments -> Constructor name [case argument of
        TypeArgument value -> TypeArgument (substitute bindings value)
        other -> other | argument <- arguments]
      Arrow a b -> Arrow (substitute bindings a) (substitute bindings b)

-- Friendly names stay readable when unambiguous. A real collision gets a
-- checked type suffix; equal-shaped distinct native types also need their
-- exact nominal interface as presentation disambiguation.
helperAllocation :: Identity.Graph -> [String] -> (String -> Type -> String)
  -> [String] -> [Type] -> M.Map (String, String) String
helperAllocation graph reserved base kinds types = M.fromList
  [((kind, show ty), selected kind ty) | (kind,ty) <- pairs]
  where
    pairs = [(kind,ty) | ty <- nub types, kind <- kinds]
    groups = M.fromListWith (++) [(base kind ty, [(kind,ty)]) | (kind,ty) <- pairs]
    semantic kind ty = base kind ty ++ "_" ++ Identity.semanticKey graph "typed-helper" ty
    semanticGroups = M.fromListWith (++) [(semantic kind ty, [(kind,ty)]) | (kind,ty) <- pairs]
    selected kind ty
      | Just [_] <- M.lookup (base kind ty) groups, base kind ty `notElem` reserved = base kind ty
      | Just [_] <- M.lookup (semantic kind ty) semanticGroups, semantic kind ty `notElem` reserved = semantic kind ty
      | otherwise = semantic kind ty ++ "_" ++ Identity.fullKey graph "typed-helper-interface" ty

calledFunctions :: TypedPlan -> M.Map Int String -> Int -> Definition -> [(String,Bool,Maybe Intrinsic,Bool)]
calledFunctions plan names classification definition = sort (nub
  [(name,selected == classification,M.lookup identity (typedIntrinsics plan),isContextual plan identity) |
    identity <- declarationId (definitionDeclaration definition) : callees (definitionBody definition),
    Just selected <- [definitionClass plan identity], Just name <- [M.lookup selected names]])
  where
    callees expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callees arguments
      _ -> concatMap callees (children expression)
