-- | Checked type and native-name contexts for independent emission chunks.
-- Helpers are named before lowering; a function records only its own requests.
-- ref:DEC-content-identity ref:DEC-incremental-compilation
module LawSpec.Typed.EmissionContext
  ( expressionTypes, definitionTypes, typeClosure, helperAllocation, helperAllocationWith, declarationContext, selectedDeclarationNames, calledFunctions ) where

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
helperAllocation = helperAllocationWith (\name suffix -> name ++ "_" ++ suffix)

-- A friendly spelling may itself equal another entry's digest fallback.
-- Reserve every unambiguous candidate before allocating the colliding set;
-- the final target-name claim checks the complete namespace, not just hashes.
helperAllocationWith :: (String -> String -> String) -> Identity.Graph -> [String]
  -> (String -> Type -> String) -> [String] -> [Type] -> M.Map (String, String) String
helperAllocationWith suffix graph reserved base kinds types = M.fromList
  [((kind, show ty), allocated M.! (kind,ty)) | (kind,ty) <- pairs]
  where
    pairs = sort [(kind,ty) | ty <- nub types, kind <- kinds]
    groups values = M.fromListWith (++) [(name,[pair]) | (pair,name) <- values]
    bases = groups [(pair,uncurry base pair) | pair <- pairs]
    semantic (kind,ty) = suffix (base kind ty) (Identity.semanticKey graph "typed-helper" ty)
    semantics = groups [(pair,semantic pair) | pair <- pairs]
    initial pair@(kind,ty)
      | Just [_] <- M.lookup (base kind ty) bases, base kind ty `notElem` reserved = base kind ty
      | Just [_] <- M.lookup (semantic pair) semantics, semantic pair `notElem` reserved = semantic pair
      | otherwise = suffix (semantic pair) (Identity.fullKey graph "typed-helper-interface" ty)
    candidates = [(pair,initial pair) | pair <- pairs]
    collisions = groups candidates
    clear = [(pair,name) | (pair,name) <- candidates,
      Just [_] <- [M.lookup name collisions], name `notElem` reserved]
    pending = [(pair,name) | (pair,name) <- candidates, pair `notElem` map fst clear]
    allocated = snd (foldl claim (S.fromList (reserved ++ map snd clear),M.fromList clear) pending)
    claim (taken,names) (pair@(_,ty),name) =
      let rooted = suffix name (Identity.fullKey graph "typed-helper-interface" ty)
          chosen = head [candidate | candidate <- rooted : [suffix rooted (show n) | n <- [2 :: Int ..]],
            candidate `S.notMember` taken]
      in (S.insert chosen taken,M.insert pair chosen names)

-- A public declaration may name only its own and its checked dependencies'
-- allocated interfaces. Namespace planning and registry validation still run
-- on every request before any document lookup.
declarationContext :: Identity.Graph -> [DataDeclaration] -> [(Id,String)] -> DataDeclaration -> String
declarationContext graph declarations names declaration = show
  (selectedDeclarationNames graph declarations names declaration,
   sort [(dataId value,dataHandle value,dataNative value) | value <- declarations, dataId value `S.member` selected])
  where selected = S.fromList (map dataId (declarationClosure graph declaration))

selectedDeclarationNames :: Identity.Graph -> [DataDeclaration] -> [(Id,String)] -> DataDeclaration -> [(Id,String)]
selectedDeclarationNames graph _ names declaration =
  [(identity,name) | identity <- S.toAscList selected, Just name <- [lookup identity names]]
  where
    selected = S.fromList [identity | value <- declarationClosure graph declaration,
      identity <- dataId value : map constructorId (dataConstructors value)]

declarationClosure :: Identity.Graph -> DataDeclaration -> [DataDeclaration]
declarationClosure graph declaration = declaration :
  Identity.reachableData graph (Identity.closure graph (Identity.referencesOf graph declaration))

calledFunctions :: TypedPlan -> M.Map Int String -> Int -> Definition -> [(String,Bool,Maybe Intrinsic,Bool)]
calledFunctions plan names classification definition = sort (nub
  [(name,selected == classification,M.lookup identity (typedIntrinsics plan),isContextual plan identity) |
    identity <- declarationId (definitionDeclaration definition) : callees (definitionBody definition),
    Just selected <- [definitionClass plan identity], Just name <- [M.lookup selected names]])
  where
    callees expression = case expressionNode expression of
      ExternalCall callee arguments -> callee : concatMap callees arguments
      _ -> concatMap callees (children expression)
