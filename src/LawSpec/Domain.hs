module LawSpec.Domain where
import LawSpec.Refinement (safeDomainExpr)
import LawSpec.Model
import LawSpec.Scalar
import LawSpec.Eval
import LawSpec.Compile (typedExpression)
import Control.Monad (filterM)

-- Small domains are enumerated exactly, with dependent predicates checked in order.
finiteTuples :: Int -> Generation -> [Input] -> Either String (Maybe [[Scalar]])
finiteTuples bits settings ins = case mapM (finiteValues bits (exhaustiveLimit settings) . inputType) ins of
  Just sets | product (map (toInteger . length) sets) <= toInteger (exhaustiveLimit settings) -> Just <$> filterM (validTuple bits ins) (sequence sets)
  _ -> pure Nothing

validTuple :: Int -> [Input] -> [Scalar] -> Either String Bool
validTuple bits ins values = walk [] (zip ins values) where
  walk _ [] = Right True
  walk prefix ((i,v):rest) = do
    let env = prefix ++ [(inputId i,v)]
    ok <- allM (\p -> do ir <- typedExpression bits [(inputId x,inputType x) | x <- ins] p; v <- evaluateTyped bits env ir; pure (v == SBool True)) (inputRefinements i)
    if ok then walk env rest else Right False
  allM _ [] = Right True
  allM f (x:xs) = do b <- f x; if b then allM f xs else Right False

boundaryTuples :: Int -> Expanded -> Either String [[Scalar]]
boundaryTuples bits e = filterM (validTuple bits (inputs e)) raw where
  sets = map (boundaries bits . inputType) (inputs e)
  raw = if null sets then [] else [[xs !! (j `mod` length xs) | xs <- sets] | j <- [0..maximum (map length sets)-1]]

boundaries :: Int -> Type -> [Scalar]
boundaries bits (Named n) = scalarBoundaries bits n
boundaries bits (Applied n t) = SPresent n Nothing : map (SPresent n . Just) (boundaries bits t)
boundaries bits t = boundaries bits (baseType t)

-- Direct comparisons seed the candidate pool, including sparse equalities.
domainHints :: Input -> [Expr]
domainHints i = concatMap walk (inputRefinements i) where
  name = inputId i
  walk (Binary op a b) | op `elem` ["&&","||"] = walk a ++ walk b
  walk (Binary _ (Var n) b) | n == name, name `notElem` exprVars b, safeDomainExpr [] b = [b]
  walk (Binary _ a (Var n)) | n == name, name `notElem` exprVars a, safeDomainExpr [] a = [a]
  walk _ = []
