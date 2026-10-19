-- User-owned LawSpec adapter.
module Example.Gadt (evalNumber, evalTruth, evalPair, fold, describe) where

import qualified Data.Text as T
import qualified LawSpecData as Data

-- Only the number cases build an Expr Integer, so GHC accepts these matches
-- as complete; Both's halves arrive at the types Expr (Pair b c) fixes.
evalNumber :: Data.Expr Integer -> Integer
evalNumber (Data.ExprNumber value) = value
evalNumber (Data.ExprPlus (Data.Record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e left right)) = evalNumber left + evalNumber right

evalTruth :: Data.Expr Bool -> Bool
evalTruth (Data.ExprTruth value) = value
evalTruth (Data.ExprSame (Data.Record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e left right)) = evalNumber left == evalNumber right
evalTruth (Data.ExprNegate operand) = not (evalTruth operand)

evalPair :: Data.Expr (Data.Pair Integer Bool) -> Data.Pair Integer Bool
evalPair (Data.ExprBoth (Data.Recorddf69a8df6c38a0adbe741f620a312261d0d3b0973eba2bc27135c83989a8365e first second)) = Data.Pair (evalNumber first) (evalTruth second)

fold :: Data.Expr Integer -> Data.Expr Integer
fold = Data.ExprNumber . evalNumber

-- The witness names the type the shown value holds.
describe :: Data.Shown -> T.Text
describe (Data.Shown _ witness) = witness
