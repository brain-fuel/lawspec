-- | A capability law, restated for the functions a law writes. The law is
-- proved once over types and functions of which nothing is known
-- (LawSpec.Instances); as Why3 uses a cloned theory's lemmas at any
-- instance of its abstract symbols, a law that cites it takes it at each
-- of its own functions that fits. ref:DEC-capability-laws
module LawSpec.Core.SmtRestate (Restatement(..), restatements, restatedAt, inlineDefinitions, mapProposition) where

import Control.Monad (foldM, unless, when)
import Data.List (isPrefixOf, nub, nubBy)
import qualified Data.Map.Strict as M
import LawSpec.Common (Quantification(..))
import LawSpec.Core
import LawSpec.Core.SmtInstances (mapExpressionTypes, writtenKey)

-- | The functions written in place of the law's unknown ones, each with its
-- binders in the order of the unknown function's arguments; and the law
-- with them in place, at their types.
data Restatement = Restatement
  { restatedFunctions :: [([Binder], Expr)]
  , restatedInputs :: [Quantifier]
  , restatedBody :: Proposition }

capabilityLawsUnit :: Id
capabilityLawsUnit = Id "lawspec.instances.laws"

-- | A written function: its binders, in the order an unknown function of
-- its kind takes its arguments, and its body.
type Function = ([Binder], Expr)

-- | Every restatement of a capability law that a law's functions allow: one
-- for each way of putting a function the law writes at an operation (a map,
-- a filter, an all, a fold) in place of each unknown function, and a type
-- of the law's lists in place of an unknown type no function settles.
restatements :: Unit -> Property -> Property -> Either String [Restatement]
restatements unit law lemma = do
  let definitions = [(declarationId (definitionDeclaration d), d) | d <- unitDefinitions unit]
      unknown = [(declarationId d, d) | d <- unitDeclarations unit, declarationId d `notElem` map fst definitions]
      inline = inlineDefinitions unit
      quantifiers = map (mapQuantifier inline) (propertyParameters lemma ++ propertyInputs lemma)
      body = mapProposition id inline (propertyBody lemma)
      expressions = concatMap quantifierExpressions quantifiers ++ propositionExpressions body
      used = nub [name | e <- expressions, name <- calls e, name `elem` map fst unknown]
      inputs = map (binderId . quantifiedBinder) (propertyParameters law ++ propertyInputs law) ++ outer (propertyBody law)
      lawExpressions = concatMap quantifierExpressions (propertyParameters law ++ propertyInputs law) ++ propositionExpressions (propertyBody law)
      candidates = nubBy (\(bs, b) (cs, c) -> writtenKey bs b == writtenKey cs c) (concatMap written lawExpressions)
      elementTypes = nub [t | e <- lawExpressions, Constructor "List" [TypeArgument t] <- typesOf e]
      handles = nub (concatMap handlesOf (map (binderType . quantifiedBinder) quantifiers ++ concatMap typesOf expressions))
      assign (table, chosen) name = case lookup name unknown of
        Nothing -> []
        Just declaration ->
          let (parameters, result) = functionType (declarationType declaration)
          in [ (table', chosen ++ [(name, candidate)])
             | candidate@(binders, value) <- candidates, length binders == length parameters
             , Just table' <- [foldM unify table (zip (parameters ++ [result]) (map binderType binders ++ [expressionType value]))] ]
      settle table handle = case M.lookup handle table of
        Just _ -> [table]
        Nothing -> [M.insert handle t table | t <- elementTypes]
      choices = [ (table', chosen) | (table, chosen) <- foldM assign (M.empty, []) used, table' <- foldM settle table handles ]
  when (null choices) (Left ("cited law " ++ propertyName lemma ++
    ": the law writes no function or list that it could be about"))
  unless (length choices <= 32) (Left ("cited law " ++ propertyName lemma ++ ": it would be restated " ++
    show (length choices) ++ " times for the functions this law writes; at most 32"))
  mapM (\(table, chosen) -> do
    let functions = nubBy (\(bs, b) (cs, c) -> writtenKey bs b == writtenKey cs c) (map snd chosen)
    mapM_ (\(binders, value) -> unless (all (`elem` (inputs ++ map binderId binders)) (freeBinders value))
      (Left ("cited law " ++ propertyName lemma ++ ": a function it would be about uses a value bound inside the law"))) functions
    pure (restatedAt table chosen functions quantifiers body)) choices
  where
    outer claim = case claim of
      Quantified ForEvery q rest -> binderId (quantifiedBinder q) : outer rest
      _ -> []

-- | The unit's own definitions (the identity, negation) written out where
-- they are called.
inlineDefinitions :: Unit -> Expr -> Expr
inlineDefinitions unit = inline
  where
    definitions = [(declarationId (definitionDeclaration d), d) | d <- unitDefinitions unit]
    inline e = case expressionNode e' of
      ExternalCall name arguments | Just d <- lookup name definitions, length arguments == length (definitionArguments d) ->
        inline (substitute (M.fromList (zip (map binderId (definitionArguments d)) arguments)) (definitionBody d))
      _ -> e'
      where e' = mapChildren inline e

-- | A law's inputs and body (its own definitions already written out) at
-- the given types in place of the unknown types, and the given functions in
-- place of the unknown functions.
restatedAt :: M.Map String Type -> [(Id, Function)] -> [Function] -> [Quantifier] -> Proposition -> Restatement
restatedAt table chosen functions quantifiers body =
  Restatement functions
    [ (mapQuantifier restated q) { quantifiedBinder = (quantifiedBinder q) { binderType = at (binderType (quantifiedBinder q)) } } | q <- quantifiers ]
    (mapProposition at restated body)
  where
    at = retype table
    place e = case expressionNode e' of
      ExternalCall name arguments | Just (binders, value) <- lookup name chosen ->
        substitute (M.fromList (zip (map binderId binders) arguments)) value
      _ -> e'
      where e' = mapChildren place e
    restated = place . mapExpressionTypes at

isHandle :: String -> Bool
isHandle name = (idText capabilityLawsUnit ++ "::type::") `isPrefixOf` name

handlesOf :: Type -> [String]
handlesOf ty = case ty of
  Constructor name [] | isHandle name -> [name]
  Constructor _ arguments -> concat [handlesOf t | TypeArgument t <- arguments]
  Arrow a b -> handlesOf a ++ handlesOf b
  TypeVariable _ -> []

retype :: M.Map String Type -> Type -> Type
retype table ty = case ty of
  Constructor name [] | Just t <- M.lookup name table -> t
  Constructor name arguments -> Constructor name
    [case a of TypeArgument t -> TypeArgument (retype table t); other -> other | a <- arguments]
  Arrow a b -> Arrow (retype table a) (retype table b)
  TypeVariable _ -> ty

-- | The unknown types of a pattern, as they must be for it to be the type.
unify :: M.Map String Type -> (Type, Type) -> Maybe (M.Map String Type)
unify table (pattern', actual) = case (pattern', actual) of
  (Constructor name [], _) | isHandle name -> case M.lookup name table of
    Nothing -> Just (M.insert name actual table)
    Just t | t == actual -> Just table
    _ -> Nothing
  (Constructor name arguments, Constructor name' arguments') | name == name', length arguments == length arguments' ->
    foldM argument table (zip arguments arguments')
  _ | pattern' == actual -> Just table
  _ -> Nothing
  where
    argument found pair = case pair of
      (TypeArgument a, TypeArgument b) -> unify found (a, b)
      (a, b) | a == b -> Just found
      _ -> Nothing

-- | The functions an expression writes at its operations.
written :: Expr -> [Function]
written e = here ++ concatMap written (children e)
  where
    here = case expressionNode e of
      MapElements _ binder value -> [([binder], value)]
      FilterElements _ binder value -> [([binder], value)]
      AllElements _ binder value -> [([binder], value)]
      FoldElements True _ _ accumulator binder value -> [([accumulator, binder], value)]
      FoldElements False _ _ accumulator binder value -> [([binder, accumulator], value)]
      _ -> []

calls :: Expr -> [Id]
calls e = [name | ExternalCall name _ <- [expressionNode e]] ++ concatMap calls (children e)

typesOf :: Expr -> [Type]
typesOf e = expressionType e : concatMap typesOf (children e)

-- | An expression with locals replaced by expressions (no binder in Core
-- rebinds an id, so no capture is possible).
substitute :: M.Map Id Expr -> Expr -> Expr
substitute table e = case expressionNode e of
  Local i | Just replacement <- M.lookup i table -> replacement
  _ -> mapChildren (substitute table) e

quantifierExpressions :: Quantifier -> [Expr]
quantifierExpressions q = quantifiedPredicates q ++ map snd (quantifiedBounds q)

mapQuantifier :: (Expr -> Expr) -> Quantifier -> Quantifier
mapQuantifier f q = q { quantifiedPredicates = map f (quantifiedPredicates q), quantifiedBounds = [(op, f value) | (op, value) <- quantifiedBounds q] }

-- | A proposition with its types and its expressions changed.
mapProposition :: (Type -> Type) -> (Expr -> Expr) -> Proposition -> Proposition
mapProposition at f claim = case claim of
  Equation evidence a b -> Equation (case evidence of Numeric t -> Numeric (at t); Structural t -> Structural (at t)) (f a) (f b)
  Implication guard rest -> Implication (f guard) (go rest)
  Conjunction claims -> Conjunction (map go claims)
  Negation rest -> Negation (go rest)
  Quantified kind q rest -> Quantified kind
    ((mapQuantifier f q) { quantifiedBinder = (quantifiedBinder q) { binderType = at (binderType (quantifiedBinder q)) } }) (go rest)
  where go = mapProposition at f
