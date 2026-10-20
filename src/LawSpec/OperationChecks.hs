-- | A definition may rely on an ability operation's refined result, such as
-- `load` at `Store Count`, only after a runtime check where it calls the
-- operation. Each such call becomes
--
-- > let r = load in if r >= 0 then r else prelude.unreachable m end if
--
-- with m from Core.operationResultCheck. Every target runs the check as it
-- runs any other conditional, so a handler that breaks the type stops the
-- definition at the call. Admission reads the checked branch as a fact
-- about r (DefinitionTotality, Core.Total), and evidence reports the check
-- as runtime-checked. Handlers stay native code: their "gives what its type
-- says" laws are still tested, never assumed. ref:DEC-operation-result-checks
module LawSpec.OperationChecks (checkOperationResults) where

import qualified Data.Map.Strict as M
import LawSpec.Model
import LawSpec.Abilities (abilityArguments, instantiatedOperations)
import LawSpec.Refinement (expandUnitType)
import qualified LawSpec.Core as C

-- | Before refinement lowering, which leaves ability rows at their base
-- types: the row still says `Store Count`. Types are expanded here; one
-- that does not expand is left unchecked, and lowering reports it.
checkOperationResults :: M.Map String DataTypeDeclaration -> Unit -> Unit
checkOperationResults imported u = u{functionDefinitions = map check (functionDefinitions u)}
  where
    expand ty = either (const Nothing) Just (expandUnitType imported u ty)
    expandedInstance ty = case ty of
      Applied name argument -> Applied name <$> expand argument
      Application name arguments -> Application name <$> mapM expand arguments
      other -> Just other
    rows = M.fromList (abilityRows u)
    check d = case M.findWithDefault [] (functionName d) rows of
      [] -> d
      row -> let table = operationsOf row
             in if M.null table then d else d{functionBody = rewrite table [] (functionBody d)}
    -- Each operation of a row whose result type is refined, by name. An
    -- operation the row gives at two different types is left unchecked.
    operationsOf row = M.mapMaybe agreed (M.fromListWith (++)
      [ (op, [(length arguments, result)])
      | written <- row, Just instance' <- [expandedInstance written]
      , declared <- abilities u, abilityName declared == abilityTypeName instance'
      , length (abilityArguments instance') == length (abilityParameters declared)
      , Just operations <- [mapM (\(op, ty) -> (,) op <$> expand ty) (abilityOperations declared)]
      , (op, ty) <- instantiatedOperations declared{abilityOperations = operations} instance'
      , let (arguments, result) = functionType ty
      , not (null (typePredicates (Var probe) result))
      , not (any (`elem` concatMap binders arguments) (concatMap exprVars (typePredicates (Var probe) result))) ])
    agreed entries = case entries of
      first : rest | all (== first) rest -> Just first
      _ -> Nothing
    -- A dependent result names an argument; it is not checked here.
    binders ty = case ty of
      Refined name inner _ -> name : binders inner
      _ -> []
    probe = "lawspecOperationResult"

rewrite :: M.Map String (Int, Type) -> [String] -> Expr -> Expr
rewrite table bound expression = case expression of
  _ | Just (op, arguments) <- spine expression, op `notElem` bound
    , Just (arity, result) <- M.lookup op table, length arguments == arity ->
      checked op result (foldl Apply (Var op) (map recur arguments))
  Located range inner -> Located range (recur inner)
  Apply f x -> Apply (recur f) (recur x)
  Compose f g -> Compose (recur f) (recur g)
  ListLit items -> ListLit (map recur items)
  RecordLit fields -> RecordLit [(label, recur value) | (label, value) <- fields]
  ConstructLit name fields -> ConstructLit name (map recur fields)
  MatchExpr value branches -> MatchExpr (recur value)
    [MatchBranch tag names (rewrite table (names ++ bound) body) | MatchBranch tag names body <- branches]
  AllElementsExpr value binder body -> AllElementsExpr (recur value) binder (rewrite table (binder : bound) body)
  AllPayloadsExpr value predicates -> AllPayloadsExpr (recur value)
    [(binder, rewrite table (binder : bound) body) | (binder, body) <- predicates]
  Binary op a b -> Binary op (recur a) (recur b)
  Unary op a -> Unary op (recur a)
  Annotate a ty -> Annotate (recur a) ty
  other -> other
  where
    recur = rewrite table bound

-- | op a b, as its name and arguments.
spine :: Expr -> Maybe (String, [Expr])
spine expression = case expression of
  Located _ inner -> spine inner
  Var name -> Just (name, [])
  Apply f x -> fmap (\(name, arguments) -> (name, arguments ++ [x])) (spine f)
  _ -> Nothing

checked :: String -> Type -> Expr -> Expr
checked op result call =
  let name = "lawspecChecked" ++ concatMap (\c -> if c == '.' then "_" else [c]) op
      claim = foldr1 (Binary "&&") (typePredicates (Var name) result)
      failure = Apply (Var "prelude.unreachable") (StringLit (C.operationResultCheck op))
  in MatchExpr (Annotate call (baseType result)) [MatchBranch letTag [name] (foldl Apply (Var "prelude.select") [claim, Var name, failure])]
