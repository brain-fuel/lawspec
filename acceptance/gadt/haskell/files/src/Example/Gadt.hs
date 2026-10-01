-- User-owned LawSpec adapter.
module Example.Gadt (evalNumber, evalTruth, evalPair, fold) where

import qualified LawSpecData as Data

-- Only the number cases build an Expr Integer, so GHC accepts these matches
-- as complete; Both's halves arrive at the types Expr (Pair b c) fixes.
evalNumber :: Data.Expr Integer -> Integer
evalNumber (Data.ExprNumber value) = value
evalNumber (Data.ExprPlus left right) = evalNumber left + evalNumber right

evalTruth :: Data.Expr Bool -> Bool
evalTruth (Data.ExprTruth value) = value
evalTruth (Data.ExprSame left right) = evalNumber left == evalNumber right
evalTruth (Data.ExprNegate operand) = not (evalTruth operand)

evalPair :: Data.Expr (Data.Pair Integer Bool) -> Data.Pair Integer Bool
evalPair (Data.ExprBoth first second) = Data.Pair (evalNumber first) (evalTruth second)

fold :: Data.Expr Integer -> Data.Expr Integer
fold = Data.ExprNumber . evalNumber
