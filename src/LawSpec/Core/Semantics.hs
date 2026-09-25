-- Framework- and syntax-independent scalar semantics used by the core oracle.
module LawSpec.Core.Semantics where
import LawSpec.Core (Type(..), Argument(..), scalarType)
import LawSpec.Scalar
import Data.Ratio
import Control.Monad (unless)

convertValue :: Int -> Type -> Scalar -> Either String Scalar
convertValue bits (Constructor n []) s = case s of
  SFloat _ _ | isExact n -> let v = floatValue s in
    if isNaN v || isInfinite v then Left "non-finite exact conversion"
    else convertScalar bits n (reduced (toRational v))
  _ -> convertScalar bits n s
convertValue _ (Constructor n [_]) (SAbsent a)
  | (n,a) `elem` [("Nullable","Null"),("Optional","Undefined")] = Right (SPresent n Nothing)
convertValue _ (Constructor n [_]) (SPresent m Nothing) | n == m = Right (SPresent n Nothing)
convertValue bits (Constructor n [TypeArgument t]) (SPresent m (Just s))
  | n == m = SPresent n . Just <$> convertValue bits t s
convertValue _ _ _ = Left "invalid scalar conversion"

binaryValue :: Int -> String -> Scalar -> Scalar -> Either String Scalar
binaryValue bits op a b
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
            "+" -> (,) <$> binaryValue bits "+" ar br <*> binaryValue bits "+" ai bi
            "-" -> (,) <$> binaryValue bits "-" ar br <*> binaryValue bits "-" ai bi
            "*" -> do p <- binaryValue bits "*" ar br; q <- binaryValue bits "*" ai bi; r <- binaryValue bits "*" ar bi; s <- binaryValue bits "*" ai br; (,) <$> binaryValue bits "-" p q <*> binaryValue bits "+" r s
            "/" -> do p <- binaryValue bits "*" br br; q <- binaryValue bits "*" bi bi; d <- binaryValue bits "+" p q; ac <- binaryValue bits "*" ar br; bd <- binaryValue bits "*" ai bi; bc <- binaryValue bits "*" ai br; ad <- binaryValue bits "*" ar bi; nr <- binaryValue bits "+" ac bd; ni <- binaryValue bits "-" bc ad; (,) <$> binaryValue bits "/" nr d <*> binaryValue bits "/" ni d
            _ -> Left "complex values are not ordered"
          SComplex result <$> convertScalar bits component r <*> convertScalar bits component i
      else do
        let x = floatValue a; y = floatValue b
        pure $ if op `elem` ["<","<=",">",">=","==","!="] then SBool (cmp op x y) else floatScalar result (case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> 0)
helperValue :: Int -> String -> [Scalar] -> Either String Scalar
helperValue bits "checked" [_] = Right (SBool True)
helperValue bits "length" [SSequence _ xs] = Right (SInteger "Integer" (fromIntegral (length xs)))
helperValue bits "isPresent" [SPresent _ v] = Right (SBool (case v of Just _ -> True; _ -> False))
helperValue bits "presentValue" [SPresent _ (Just v)] = Right v
helperValue bits "real" [SComplex _ r _] = Right r
helperValue bits "imag" [SComplex _ _ i] = Right i
helperValue bits "quot" [a,b] = binaryValue bits "quot" a b
helperValue bits "rem" [a,b] = binaryValue bits "rem" a b
helperValue bits "isNaN" [a] = Right (SBool (isNaN (floatValue a)))
helperValue bits "isInfinite" [a] = Right (SBool (isInfinite (floatValue a)))
helperValue bits "isFinite" [a] = Right (SBool (not (isNaN (floatValue a) || isInfinite (floatValue a))))
helperValue bits "isNegativeZero" [a] = Right (SBool (isNegativeZero (floatValue a)))
helperValue bits "round" [a,b] = do
  x <- exactValue a; scale <- exactValue b
  unless (denominator scale == 1) (Left "fractional decimal scale")
  let k = numerator scale; factor = if k >= 0 then 10^k % 1 else 1 % 10^(-k)
  decimal (fromInteger (round (x*factor)) / factor)
helperValue bits n [a] | isNumeric n = convertValue bits (scalarType n) a
helperValue bits _ _ = Left "invalid pure helper or arguments"
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
