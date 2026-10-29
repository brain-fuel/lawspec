-- | Reuse elaborated adapter contracts for state-dependent model arguments.
-- Indices come from the abstract run's typestate, never from the adapter.
-- This is generator planning, not proof discharge. ref:DEC-dependent-model-arguments
module LawSpec.ModelDomains (dependentRanges, resolveBound, boundText) where

import Data.List (isSuffixOf)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import LawSpec.IndexTerm (familyIndexNames)
import LawSpec.Scalar (Scalar(..))

-- | Only integer comparisons with expressions over known state indices are
-- narrowed. Other dependencies are explicitly unsupported by the planner.
dependentRanges :: [C.DataDeclaration] -> [C.Contract] -> Command C.Id
  -> Either String [(Int, [(C.BinaryOp, C.Expr)])]
dependentRanges datas contracts command = case [c | c <- contracts, C.contractDeclaration c == commandSystem command] of
  [] -> Right []
  c : _ -> do
    let binders = C.contractArguments c
        state = binders !! commandStatePosition command
        families = [d | d <- datas, C.binderType state == C.Constructor (C.idText (C.dataId d)) []]
        measures = [(name ++ "Of" ++ C.dataName d, k) | d <- families, Just family <- [C.dataIndex d], (k, name) <- zip [0 :: Int ..] (familyIndexNames family)]
        lower e = case C.expressionNode e of
          C.ExternalCall name [arg] | local (C.binderId state) arg
            , (_, k) : _ <- [(n, i) | (n, i) <- measures, ("::" ++ n) `isSuffixOf` C.idText name] ->
                e {C.expressionNode = C.Local (C.Id ("model-index:" ++ show k))}
          _ -> C.mapChildren lower e
        predicates = concatMap conjuncts (map lower (C.contractPreconditions c))
        range position = do
          let binder = C.binderId (binders !! position)
              relevant = [p | p <- predicates, mentions binder p]
          pairs <- mapM (comparison (any indexed relevant) binder) relevant
          pure (position, [pair | Just pair <- pairs])
    filter (not . null . snd) <$> mapM range (commandArguments command)
  where
    conjuncts e = case C.expressionNode e of C.ShortCircuit C.And a b -> conjuncts a ++ conjuncts b; _ -> [e]
    local binder e = case C.expressionNode e of C.Local name -> binder == name; C.Convert _ _ a -> local binder a; _ -> False
    mentions binder e = local binder e || any (mentions binder) (C.children e)
    indexed e = case C.expressionNode e of C.Local (C.Id n) -> take 12 n == "model-index:"; _ -> any indexed (C.children e)
    comparison dynamic binder e = case C.expressionNode e of
      C.Binary op _ a b | local binder a, supported b, op `elem` [C.Less,C.LessEqual,C.Greater,C.GreaterEqual,C.Equal] -> Right (Just (op, b))
                       | local binder b, supported a, op `elem` [C.Less,C.LessEqual,C.Greater,C.GreaterEqual,C.Equal] -> Right (Just (flipped op, a))
      _ | dynamic || indexed e -> Left "unsupported state-dependent model argument refinement"
        | otherwise -> Right Nothing
    supported e = case C.expressionNode e of
      C.Constant (SInteger _ _) -> True
      C.Local (C.Id n) -> take 12 n == "model-index:"
      C.Convert _ _ a -> supported a
      C.Binary op _ a b -> op `elem` [C.Add,C.Subtract,C.Multiply] && supported a && supported b
      _ -> False
    flipped op = case op of C.Less -> C.Greater; C.LessEqual -> C.GreaterEqual; C.Greater -> C.Less; C.GreaterEqual -> C.LessEqual; x -> x

-- | Evaluate a bound using the current reference indices. Signed subtraction
-- here is ordinary integer arithmetic, as in the elaborated refinement.
resolveBound :: [Integer] -> C.Expr -> Either String Integer
resolveBound indices e = case C.expressionNode e of
  C.Constant (SInteger _ n) -> Right n
  C.Local (C.Id name) | [(k, "")] <- reads (drop 12 name), k >= 0, k < length indices -> Right (indices !! k)
  C.Convert _ _ a -> resolveBound indices a
  C.Binary op _ a b -> do
    x <- resolveBound indices a; y <- resolveBound indices b
    case op of C.Add -> Right (x+y); C.Subtract -> Right (x-y); C.Multiply -> Right (x*y); _ -> Left "unsupported bound operator"
  _ -> Left "unsupported model argument bound"

-- | Private runtime descriptor terms, sharing the existing descriptor reader.
boundText :: C.Expr -> String
boundText e = case C.expressionNode e of
  C.Constant (SInteger _ n) -> show n
  C.Local (C.Id n) -> "(index " ++ drop 12 n ++ ")"
  C.Convert _ _ a -> boundText a
  C.Binary op _ a b -> "(" ++ C.binaryName op ++ " " ++ boundText a ++ " " ++ boundText b ++ ")"
  _ -> "unsupported"
