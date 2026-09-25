module LawSpec.Eval (evaluate, evaluateBool, evaluateTyped, boundsValue, finiteValues) where
import LawSpec.Model
import LawSpec.Scalar
import Data.Ratio
import qualified Data.Map.Strict as M
import Control.Monad (unless)

boundsValue :: Int -> String -> Type -> Either String Scalar
boundsValue bits b t = case baseType t of
  Named n -> case integerBounds bits n of
    Just (lo,hi) -> Right (SInteger "Integer" (if b == "min" then lo else hi))
    _ -> Left ("Bounded requires a fixed or machine integer: " ++ n)
  _ -> Left "unresolved representation bound"

evaluateBool :: Int -> [(String,Scalar)] -> Expr -> Either String Bool
evaluateBool bits env e = evaluate bits env e >>= boolean
boolean :: Scalar -> Either String Bool
boolean (SBool b) = Right b
boolean _ = Left "predicate must return Bool"

evaluate :: Int -> [(String,Scalar)] -> Expr -> Either String Scalar
evaluate bits bindings = go where
  env = M.fromList bindings
  go (Var n) = maybe (Left ("unknown pure value: " ++ n)) Right (M.lookup n env)
  go (Number n) = Right (SInteger "Integer" n)
  go (DecimalNumber c e) = Right (SDecimal c e)
  go (BoolLit b) = Right (SBool b)
  go (StringLit s) = Right (textScalar s)
  go (ScalarLit s) = validateScalar bits s
  go (TypeBound b t) = boundsValue bits b t
  go (Annotate e t) = go e >>= convert t
  go (Unary "!" e) = SBool . not <$> (go e >>= boolean)
  go (Unary "-" e) = do
    a <- go e
    if isExact (scalarName a) then exactValue a >>= convertScalar bits (if isInteger (scalarName a) then "Integer" else scalarName a) . reduced . negate
    else case a of
      SComplex t r i -> Right (SComplex t (floatScalar (scalarName r) (negate (floatValue r))) (floatScalar (scalarName i) (negate (floatValue i))))
      _ -> Right (floatScalar (scalarName a) (negate (floatValue a)))
  go (Binary "&&" a b) = do x <- go a >>= boolean; if x then SBool <$> (go b >>= boolean) else Right (SBool False)
  go (Binary "||" a b) = do x <- go a >>= boolean; if x then Right (SBool True) else SBool <$> (go b >>= boolean)
  go (Binary op a b) = do x <- go a; y <- go b; binary op x y
  go e@(Apply _ _) = case application e of
    (Var n,args) | take 8 n == "prelude." -> mapM go args >>= helper (drop 8 n)
    _ -> Left "adapter calls are forbidden in refinement predicates"
  go _ = Left "unsupported pure expression"
  convert (Refined _ t _) s = convert t s
  convert (Qualified _ t) s = convert t s
  convert (Named n) s = case s of
    SFloat _ _ | isExact n -> let v = floatValue s in if isNaN v || isInfinite v then Left "non-finite exact conversion" else convertScalar bits n (reduced (toRational v))
    _ -> convertScalar bits n s
  convert (Applied n _) (SAbsent a) | (n,a) `elem` [("Nullable","Null"),("Optional","Undefined")] = Right (SPresent n Nothing)
  convert (Applied n _) (SPresent m Nothing) | n == m = Right (SPresent n Nothing)
  convert (Applied n t) (SPresent m (Just s)) | n == m = SPresent n . Just <$> convert t s
  convert _ _ = Left "invalid contextual scalar"
  binary op a b
    | op `elem` ["==","!="], not (isNumeric (scalarName a)) = do
        let eq = scalarEqual a b
        pure (SBool (if op == "==" then eq else not eq))
    | otherwise = do
        result <- promote op (scalarName a) (scalarName b)
        if isExact (scalarName a) then do
          x <- exactValue a; y <- exactValue b
          if op `elem` ["<","<=",">",">=","==","!="] then pure (SBool (cmp op x y)) else do
            unless (op `notElem` ["/","quot","rem"] || y /= 0) (Left "exact division by zero")
            case op of
              "quot" -> pure (SInteger "Integer" (numerator x `quot` numerator y))
              "rem" -> pure (SInteger "Integer" (numerator x `rem` numerator y))
              _ -> convertScalar bits result (reduced (case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> 0))
        else if any (`elem` ["Complex64","Complex128"]) [scalarName a,scalarName b] then do
          let pair (SComplex _ r i) = (r,i)
              pair v = (v,floatScalar (scalarName v) 0)
              (ar,ai) = pair a; (br,bi) = pair b
              component = if result == "Complex64" then "Float32" else "Float64"
          if op `elem` ["==","!="] then pure (SBool (if op == "==" then scalarEqual ar br && scalarEqual ai bi else not (scalarEqual ar br && scalarEqual ai bi))) else do
            (r,i) <- case op of
              "+" -> (,) <$> binary "+" ar br <*> binary "+" ai bi
              "-" -> (,) <$> binary "-" ar br <*> binary "-" ai bi
              "*" -> do p <- binary "*" ar br; q <- binary "*" ai bi; r <- binary "*" ar bi; s <- binary "*" ai br; (,) <$> binary "-" p q <*> binary "+" r s
              "/" -> do p <- binary "*" br br; q <- binary "*" bi bi; d <- binary "+" p q; ac <- binary "*" ar br; bd <- binary "*" ai bi; bc <- binary "*" ai br; ad <- binary "*" ar bi; nr <- binary "+" ac bd; ni <- binary "-" bc ad; (,) <$> binary "/" nr d <*> binary "/" ni d
              _ -> Left "complex values are not ordered"
            SComplex result <$> convertScalar bits component r <*> convertScalar bits component i
        else do
          let x = floatValue a; y = floatValue b
          pure $ if op `elem` ["<","<=",">",">=","==","!="] then SBool (cmp op x y) else floatScalar result (case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> 0)
  helper "checked" [_] = Right (SBool True)
  helper "length" [SSequence _ xs] = Right (SInteger "Integer" (fromIntegral (length xs)))
  helper "isPresent" [SPresent _ v] = Right (SBool (case v of Just _ -> True; _ -> False))
  helper "presentValue" [SPresent _ (Just v)] = Right v
  helper "real" [SComplex _ r _] = Right r
  helper "imag" [SComplex _ _ i] = Right i
  helper "quot" [a,b] = binary "quot" a b
  helper "rem" [a,b] = binary "rem" a b
  helper "isNaN" [a] = Right (SBool (isNaN (floatValue a)))
  helper "isInfinite" [a] = Right (SBool (isInfinite (floatValue a)))
  helper "isFinite" [a] = Right (SBool (not (isNaN (floatValue a) || isInfinite (floatValue a))))
  helper "isNegativeZero" [a] = Right (SBool (isNegativeZero (floatValue a)))
  helper "round" [a,b] = do
    x <- exactValue a; scale <- exactValue b
    unless (denominator scale == 1) (Left "fractional decimal scale")
    let k = numerator scale; factor = if k >= 0 then 10^k % 1 else 1 % 10^(-k)
    decimal (fromInteger (round (x*factor)) / factor)
  helper n [a] | isNumeric n = convert (Named n) a
  helper _ _ = Left "invalid pure helper or arguments"
  application (Apply a b) = let (f,as) = application a in (f,as++[b])
  application e = (e,[])

cmp :: Ord a => String -> a -> a -> Bool
cmp "<" = (<)
cmp "<=" = (<=)
cmp ">" = (>)
cmp ">=" = (>=)
cmp "==" = (==)
cmp "!=" = (/=)
cmp _ = \_ _ -> False
scalarEqual :: Scalar -> Scalar -> Bool
scalarEqual a b | isExact (scalarName a) && isExact (scalarName b) = exactValue a == exactValue b
scalarEqual (SFloat _ a) (SFloat _ b) | length a == length b = let t = if length a == 8 then "Float32" else "Float64" in floatValue (SFloat t a) == floatValue (SFloat t b)
scalarEqual a@(SFloat _ _) b@(SFloat _ _) = floatValue a == floatValue b
scalarEqual (SSymbol a _) (SSymbol b _) = a == b
scalarEqual (SComplex _ a b) (SComplex _ c d) = scalarEqual a c && scalarEqual b d
scalarEqual (SPresent a (Just x)) (SPresent b (Just y)) = a == b && scalarEqual x y
scalarEqual a b = a == b

-- Respect contextual literal types from the compiler's typed IR.
evaluateTyped :: Int -> [(String,Scalar)] -> TypedExpr -> Either String Scalar
evaluateTyped bits env = evaluate bits env . materialize where
  materialize (TypedExpr t e cs _) = case (e,cs) of
    (Number _,_) -> Annotate e t
    (DecimalNumber _ _,_) -> Annotate e t
    (Binary op _ _,[a,b]) -> Binary op (materialize a) (materialize b)
    (Unary op _,[a]) -> Unary op (materialize a)
    (Annotate _ t',[a]) -> Annotate (materialize a) t'
    (Apply _ _,_) | (Var n,_) <- app e, take 8 n == "prelude." -> foldl Apply (Var n) (map materialize cs)
    _ -> e
  app (Apply f x) = let (n,args) = app f in (n,args++[x])
  app e = (e,[])

finiteValues :: Int -> Int -> Type -> Maybe [Scalar]
finiteValues bits limit t = case baseType t of
  Named n | Just (lo,hi) <- integerBounds bits n, hi-lo+1 <= fromIntegral limit -> Just [SInteger n x | x <- [lo..hi]]
          | n `elem` ["Bool","Unit","Null","Undefined"] -> Just (scalarBoundaries bits n)
  Applied n a -> do xs <- finiteValues bits (limit-1) a; pure (SPresent n Nothing : map (SPresent n . Just) xs)
  _ -> Nothing
