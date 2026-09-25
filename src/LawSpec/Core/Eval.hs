-- Reference execution of typed core. External calls are explicit effects;
-- evaluating a pure predicate cannot accidentally invoke an adapter.
module LawSpec.Core.Eval (evaluate, evaluatePure, evaluateProposition) where
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Core.Semantics
import qualified Data.Map.Strict as M

type Adapter = Id -> [Scalar] -> Either String Scalar

evaluatePure :: Int -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluatePure bits = evaluate bits (\n _ -> Left ("external call in pure expression: " ++ idText n))

evaluate :: Int -> Adapter -> [(Id,Scalar)] -> Expr -> Either String Scalar
evaluate bits adapter bindings = go where
  env = M.fromList bindings
  go Expr{..} = context expressionOrigin $ case expressionNode of
    Constant s -> Right s
    Local n -> maybe (Left ("unbound core value: " ++ idText n)) Right (M.lookup n env)
    ExternalCall n args -> mapM go args >>= adapter n
    Binary op _ a b -> do x <- go a; y <- go b; binaryValue bits (binaryName op) x y
    Unary Not a -> SBool . not <$> (go a >>= boolean)
    Unary Negate a -> do
      x <- go a
      case x of
        SComplex t r i -> pure (SComplex t (floatScalar (scalarName r) (negate (floatValue r))) (floatScalar (scalarName i) (negate (floatValue i))))
        SFloat t _ -> pure (floatScalar t (negate (floatValue x)))
        _ -> do r <- exactValue x; convertValue bits expressionType (reduced (negate r))
    ShortCircuit And a b -> do x <- go a >>= boolean; if x then go b else pure (SBool False)
    ShortCircuit Or a b -> do x <- go a >>= boolean; if x then pure (SBool True) else go b
    Convert _ target a -> go a >>= convertValue bits target
    Helper builtin args -> mapM go args >>= helperValue bits (builtinName builtin)
  context origin result = case result of
    Left msg -> Left (show origin ++ ": " ++ msg)
    Right v -> Right v

boolean :: Scalar -> Either String Bool
boolean (SBool b) = Right b
boolean _ = Left "expected Bool"


evaluateProposition :: Int -> Adapter -> [(Id,Scalar)] -> Proposition -> Either String Bool
evaluateProposition bits adapter env = go where
  term = evaluate bits adapter env
  go (Equation _ a b) = do x <- term a; y <- term b; binaryValue bits "==" x y >>= boolean
  go (Implication g p) = do enabled <- term g >>= boolean; if enabled then go p else pure True
  go (Conjunction ps) = allM ps
  allM [] = Right True
  allM (p:ps) = do ok <- go p; if ok then allM ps else pure False
