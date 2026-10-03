{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
-- The portable scalar domain. No test framework or target runtime dependencies.
module LawSpecRuntime where

import Control.Exception (SomeException, catch, displayException, evaluate)
import Control.Concurrent (threadDelay)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad (foldM)
import Data.Unique (Unique, newUnique)
import Data.Char (ord, chr)
import Data.Int
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Complex (Complex((:+)))
import Data.Word
import Data.Bits (finiteBitSize, shiftR, xor)
import Data.Text (Text)
import qualified Data.Text as T
import Data.List (find, sortBy, stripPrefix)
import Data.Ratio
import GHC.Float
  ( castFloatToWord32, castDoubleToWord64, castWord32ToFloat
  , castWord64ToDouble, float2Double, double2Float
  )
import Numeric (showHex, readHex)

data Family
  = Boolean | IntegerFamily | Exact | Floating | Complex | Character
  | Sequence | Identity | Absence
  deriving (Eq, Show)

data Primitive = Primitive
  { primitiveName :: String
  , family :: Family
  , width :: Maybe Int
  , signed :: Bool
  } deriving (Eq, Show)

primitives :: [Primitive]
primitives = [Primitive "Bool" Boolean Nothing False]
  ++ [Primitive (p ++ show w) IntegerFamily (Just w) s
     | (p,s) <- [("Int",True),("UInt",False)], w <- [8,16,32,64]]
  ++ [Primitive n IntegerFamily Nothing s
     | (n,s) <- [("IntSize",True),("UIntSize",False),("UIntPtr",False),
                 ("Integer",True),("BigInt",True),("BigUInt",False)]]
  ++ [Primitive n f w False
     | (n,f,w) <- [("Decimal",Exact,Nothing),("Rational",Exact,Nothing),
                   ("Float32",Floating,Just 32),("Float64",Floating,Just 64),
                   ("Complex64",Complex,Just 32),
                   ("Complex128",Complex,Just 64)]]
  ++ [Primitive n f Nothing False
     | (f,ns) <- [(Character,["Char","CodePoint","CodeUnit16"]),
                  (Sequence,["Text","CodePointText","Utf16Text","Bytes"]),
                  (Identity,["Symbol"]),(Absence,["Unit","Null","Undefined"])],
       n <- ns]
primitive :: String -> Maybe Primitive
primitive n = find ((== n) . primitiveName) primitives
isInteger, isExact, isInexact, isNumeric :: String -> Bool
isInteger n = maybe False ((== IntegerFamily) . family) (primitive n)
isExact n = isInteger n || n `elem` ["Decimal","Rational"]
isInexact n = n `elem` ["Float32","Float64","Complex64","Complex128"]
isNumeric n = isExact n || isInexact n
integerBounds :: Int -> String -> Maybe (Integer, Integer)
integerBounds machine n = do
  p <- primitive n
  w <- if n `elem` ["IntSize","UIntSize","UIntPtr"]
    then Just machine else width p
  if family p /= IntegerFamily then Nothing else pure $
    if signed p then (negate (2^(w-1)),2^(w-1)-1) else (0,2^w-1)

-- Raw strings travel as numeric code points/units,
-- never JSON surrogate strings.
data Scalar = SInteger String Integer | SBool Bool | SDecimal Integer Integer
  | SRational Integer Integer | SFloat String String
  | SComplex String Scalar Scalar
  | SSequence String [Int] | SCharacter String Int | SSymbol String String
  | SScopedSymbol SymbolContext String String
  | SAbsent String | SPresent String (Maybe Scalar)
  | SList [Scalar] | SData String [Scalar] deriving (Eq, Show)
scalarName :: Scalar -> String
scalarName (SInteger t _) = t
scalarName (SBool _) = "Bool"
scalarName (SDecimal _ _) = "Decimal"
scalarName (SRational _ _) = "Rational"
scalarName (SFloat t _) = t
scalarName (SComplex t _ _) = t
scalarName (SSequence t _) = t
scalarName (SCharacter t _) = t
scalarName (SSymbol _ _) = "Symbol"
scalarName (SScopedSymbol _ _ _) = "Symbol"
scalarName (SAbsent t) = t
scalarName (SPresent t _) = t
scalarName (SList _) = "List"
scalarName (SData tag _) = takeWhile (/= ':') tag
floatScalar :: String -> Double -> Scalar
floatScalar t x = SFloat t $ pad (if t == "Float32" then 8 else 16) $
  if t == "Float32"
    then showHex (castFloatToWord32 (double2Float x)) ""
    else showHex (castDoubleToWord64 x) ""
  where pad n s = replicate (n-length s) '0' ++ s
floatValue :: Scalar -> Double
floatValue (SFloat t bits) = case readHex bits of
  [(n,"")] -> if t == "Float32"
    then float2Double (castWord32ToFloat (fromInteger n))
    else castWord64ToDouble (fromInteger n)
  _ -> error "invalid internal float bits"
floatValue _ = error "not a float"
exactValue :: Scalar -> Either String Rational
exactValue (SInteger _ n) = Right (n % 1)
exactValue (SRational n d) | d /= 0 = Right (n % d)
exactValue (SDecimal c e) = Right (if e >= 0 then c * 10^e % 1 else c % 10^(-e))
exactValue _ = Left "requires an exact numeric value"
reduced :: Rational -> Scalar
reduced r = SRational (numerator r) (denominator r)
decimal :: Rational -> Either String Scalar
decimal r = go (denominator r) 0 0 where
  go d a b | d `mod` 2 == 0 = go (d `div` 2) (a+1) b
           | d `mod` 5 == 0 = go (d `div` 5) a (b+1)
           | d /= 1 =
               Left "conversion to Decimal is not finite; use prelude.round"
           | otherwise = let scale = max a b
                         in Right (SDecimal
                           (numerator r * 2^(scale-a) * 5^(scale-b)) (-scale))
validateScalar :: Int -> Scalar -> Either String Scalar
validateScalar machine s = case s of
  SInteger t n | not (isInteger t) -> Left "unknown integer type"
               | t == "BigUInt" && n < 0 -> Left "BigUInt cannot be negative"
               | Just (lo,hi) <- integerBounds machine t,
                 n < lo || n > hi -> Left ("integer outside " ++ t ++ " range")
               | otherwise -> Right s
  SRational n d | d == 0 -> Left "Rational denominator cannot be zero"
                | otherwise -> Right (reduced (n % d))
  SCharacter t c | validUnit t c -> Right s
                 | otherwise -> Left ("invalid " ++ t ++ " representation")
  SSequence t xs | t `elem` ["Text","CodePointText","Utf16Text","Bytes"],
                  all (validUnit t) xs -> Right s
                | otherwise -> Left ("invalid " ++ t ++ " representation")
  SFloat t bits | t `elem` ["Float32","Float64"],
                 length bits == (if t == "Float32" then 8 else 16),
                 [(_,"")] <- (readHex bits :: [(Integer,String)]) -> Right s
               | otherwise -> Left "invalid IEEE bit representation"
  SComplex t r i | t `elem` ["Complex64","Complex128"],
                  all ((== if t == "Complex64" then "Float32" else "Float64") .
                    scalarName) [r,i] ->
                    SComplex t <$> validateScalar machine r
                      <*> validateScalar machine i
                 | otherwise -> Left "complex component precision mismatch"
  SScopedSymbol _ i d
    | all (validUnit "Text" . ord) (i ++ d) -> Right s
    | otherwise -> Left
        "Symbol IDs and descriptions must contain Unicode scalars"
  SSymbol i d | all (validUnit "Text" . ord) (i ++ d) -> Right s
              | otherwise -> Left
                  "Symbol IDs and descriptions must contain Unicode scalars"
  SAbsent t | t `elem` ["Unit","Null","Undefined"] -> Right s
            | otherwise -> Left "unknown absence value"
  SPresent t v | t `elem` ["Nullable","Optional"] ->
                 SPresent t <$> traverse (validateScalar machine) v
               | otherwise -> Left "unknown presence type"
  _ -> Right s
validUnit :: String -> Int -> Bool
validUnit t c
  | t == "Bytes" = c >= 0 && c <= 255
  | t `elem` ["CodeUnit16","Utf16Text"] = c >= 0 && c <= 65535
  | t `elem` ["CodePoint","CodePointText"] = c >= 0 && c <= 1114111
  | t `elem` ["Char","Text"] =
      c >= 0 && c <= 1114111 && (c < 55296 || c > 57343)
  | otherwise = False
promote :: String -> String -> String -> Either String String
promote op a b
  | not (isNumeric a && isNumeric b) =
      Left "arithmetic requires numeric operands (Bool is not an integer)"
  | isExact a /= isExact b =
      Left "exact/inexact mixing requires an explicit conversion"
  | op `elem` ["quot","rem","pow"] =
      if isInteger a && isInteger b then Right "Integer"
      else Left "quot/rem/pow require integer operands"
  | isExact a = Right $
      if op == "/" || "Rational" `elem` [a,b] then "Rational"
      else if "Decimal" `elem` [a,b] then "Decimal" else "Integer"
  | otherwise = Right $ if any (`elem` ["Complex64","Complex128"]) [a,b]
      then if any (`elem` ["Float64","Complex128"]) [a,b]
        then "Complex128" else "Complex64"
      else if "Float64" `elem` [a,b] then "Float64" else "Float32"
convertScalar :: Int -> String -> Scalar -> Either String Scalar
convertScalar machine t s
  | t == scalarName s = validateScalar machine s
  | isInteger t = do
      r <- exactValue s
      if denominator r /= 1 then Left ("fractional conversion to " ++ t)
      else validateScalar machine (SInteger t (numerator r))
  | t == "Rational" = reduced <$> exactValue s
  | t == "Decimal" = exactValue s >>= decimal
  | t `elem` ["Float32","Float64"] = if isExact (scalarName s)
      then (\r -> if t == "Float32"
        then SFloat t (pad8 (showHex (castFloatToWord32 (fromRational r)) ""))
        else floatScalar t (fromRational r)) <$> exactValue s
      else case s of
      SFloat _ _ -> Right (floatScalar t (floatValue s))
      _ -> Left "conversion requires a real number"
  | t `elem` ["Complex64","Complex128"] =
      let component = if t == "Complex64" then "Float32" else "Float64"
      in case s of
        SComplex _ r i -> SComplex t <$> convertScalar machine component r
          <*> convertScalar machine component i
        _ -> SComplex t <$> convertScalar machine component s
          <*> pure (floatScalar component 0)
  | otherwise = Left ("cannot convert " ++ scalarName s ++ " to " ++ t)
scalarBoundaries :: Int -> String -> [Scalar]
scalarBoundaries machine t
  | isInteger t = map (SInteger t) $ case integerBounds machine t of
      Just (lo,hi) -> [lo, max lo (-1),0,hi]
      Nothing -> if t == "BigUInt" then [0,1,2^(128::Int)]
        else [-2^(128::Int),-1,0,2^(128::Int)]
  | otherwise = case t of
      "Bool" -> map SBool [False,True]
      "Decimal" -> [SDecimal 0 0,SDecimal 1 (-1),SDecimal (-123) 100]
      "Rational" -> [SRational 0 1,SRational 1 2,SRational (-2) 3]
      "Float32" -> floats t
      "Float64" -> floats t
      "Complex64" -> [SComplex t x y
        | (x,y) <- zip (floats "Float32") (reverse (floats "Float32"))]
      "Complex128" -> [SComplex t x y
        | (x,y) <- zip (floats "Float64") (reverse (floats "Float64"))]
      "Symbol" -> [SSymbol "a" "same", SSymbol "b" "same"]
      _ | Just p <- primitive t, family p == Character ->
          map (SCharacter t) (units t)
        | Just p <- primitive t, family p == Sequence ->
          map (SSequence t) [[],units t]
        | otherwise -> [SAbsent t]
  where floats n = map (SFloat n) $ if n == "Float32"
          then ["00000000","80000000","3f800000","bf800000",
                "7f800000","ff800000","7fc00000","00000001",
                "007fffff","00800000","7f7fffff","ff7fffff"]
          else ["0000000000000000","8000000000000000","3ff0000000000000",
                "bff0000000000000","7ff0000000000000","fff0000000000000",
                "7ff8000000000000","0000000000000001","000fffffffffffff",
                "0010000000000000","7fefffffffffffff","ffefffffffffffff"]
        units n | n == "Bytes" = [0,127,128,255]
                | n `elem` ["Utf16Text","CodeUnit16"] = [0,55296,56320,65535]
                | n `elem` ["CodePointText","CodePoint"] =
                    [0,55296,128512,1114111]
                | otherwise = [0,97,955,128512,1114111]
textScalar :: String -> Scalar
textScalar = SSequence "Text" . map ord

type Value = Scalar
allElements :: Scalar -> (Scalar -> Scalar) -> Scalar
allElements (SList values) predicate = SBool (all (truth . predicate) values)
allElements _ _ = error "expected List in element predicate"

construct :: String -> [Scalar] -> Scalar
construct "List::Nil" [] = SList []
construct "List::Cons" [headValue, SList tailValues] =
  SList (headValue : tailValues)
construct "Maybe::Nothing" [] = SData "Maybe::Nothing" []
construct tag [value]
  | tag `elem` ["Maybe::Just", "Either::Left", "Either::Right"] =
      SData tag [value]
construct tag _ = error ("invalid constructor or arity: " ++ tag)

-- Decode the compiler's parenthesized two-argument runtime type key.
eitherArguments :: String -> (String, String)
eitherArguments t = case stripPrefix "Either " t of
  Just body -> case arguments body of
    [a,b] | not (null a), not (null b) -> (a,b)
    _ -> error "invalid Either type key"
  Nothing -> error "Either type required"
  where
    arguments [] = []
    arguments (' ':rest) = arguments rest
    arguments ('(':rest) = let (value,remaining) = consume (1 :: Int) [] rest
                          in value : arguments remaining
    arguments _ = error "invalid Either type key"
    consume 1 value (')':rest) = (reverse value,rest)
    consume depth value ('(':rest) = consume (depth+1) ('(':value) rest
    consume depth value (')':rest) = consume (depth-1) (')':value) rest
    consume depth value (c:rest) = consume depth (c:value) rest
    consume _ _ [] = error "invalid Either type key"

mapSumFields :: (String -> Scalar -> Scalar) -> String -> Scalar -> Scalar
mapSumFields field t value = forceScalar result `seq` result
  where
    result | Just inner <- stripPrefix "Maybe " t = case value of
             SData "Maybe::Nothing" [] -> value
             SData "Maybe::Just" [payload] ->
               SData "Maybe::Just" [field inner payload]
             _ -> error "invalid Maybe constructor or arity"
           | otherwise = let (left,right) = eitherArguments t in case value of
             SData "Either::Left" [payload] ->
               SData "Either::Left" [field left payload]
             SData "Either::Right" [payload] ->
               SData "Either::Right" [field right payload]
             _ -> error "invalid Either constructor or arity"

convert :: String -> Scalar -> Int -> Scalar
convert t s bits
  | take 6 t == "Maybe " || take 7 t == "Either " =
      mapSumFields (\inner value -> convert inner value bits) t s
  | Just inner <- stripPrefix "List " t = case s of
      SList xs -> let result = SList (map (\x -> convert inner x bits) xs)
                  in forceScalar result `seq` result
      _ -> error "List required"
  | Just inner <- strip "Nullable " t = presence "Nullable" "Null" inner
  | Just inner <- strip "Optional " t = presence "Optional" "Undefined" inner
  | isExact t, SFloat _ _ <- s = let x = floatValue s
    in if isNaN x || isInfinite x then error "non-finite exact conversion"
       else either error id (convertScalar bits t (reduced (toRational x)))
  | otherwise = either error id (convertScalar bits t s)
  where presence n absent inner = case s of
          SAbsent a | a == absent -> SPresent n Nothing
          SPresent k v | k == n ->
            SPresent n (fmap (\x -> convert inner x bits) v)
          _ -> error "tagged presence required"
        strip [] xs = Just xs
        strip (a:as) (b:bs) | a == b = strip as bs
        strip _ _ = Nothing
validate :: String -> Scalar -> Int -> Scalar
validate t s bits
  | take 6 t == "Maybe " || take 7 t == "Either " =
      mapSumFields (\inner value -> validate inner value bits) t s
  | Just inner <- stripPrefix "List " t = case s of
      SList xs -> let result = SList (map (\x -> validate inner x bits) xs)
                  in forceScalar result `seq` result
      _ -> error "List required"
  | take 9 t == "Nullable " || take 9 t == "Optional " = convert t s bits
  | scalarName s /= t = error ("invalid " ++ t ++ " representation")
  | otherwise = either error id (validateScalar bits s)
truth :: Scalar -> Bool
truth (SBool b) = b
truth _ = error "Bool required"
equal :: Scalar -> Scalar -> Bool
equal a b
  | SData tag xs <- a, SData other ys <- b =
      tag == other && length xs == length ys && and (zipWith equal xs ys)
  | SList xs <- a, SList ys <- b =
      length xs == length ys && and (zipWith equal xs ys)
  | isInexact (scalarName a) && isInexact (scalarName b) =
      truth (binary "==" a b)
  | isExact (scalarName a) && isExact (scalarName b) =
      exactValue a == exactValue b
  | SFloat _ _ <- a, SFloat _ _ <- b = floatValue a == floatValue b
  | SComplex _ r i <- a, SComplex _ s j <- b = equal r s && equal i j
  | SPresent n x <- a, SPresent m y <- b = n == m && case (x,y) of
      (Nothing,Nothing) -> True
      (Just p,Just q) -> equal p q
      _ -> False
  | SSymbol i _ <- a, SSymbol j _ <- b = i == j
  | SScopedSymbol scope i _ <- a, SScopedSymbol other j _ <- b =
      scope == other && i == j
  | otherwise = a == b
binary :: String -> Scalar -> Scalar -> Scalar
binary op a b | op `elem` ["==","!="], not (isNumeric (scalarName a)) =
  SBool (if op == "==" then equal a b else not (equal a b))
binary op a b = either error run (promote op (scalarName a) (scalarName b))
  where
  run t
    | isExact (scalarName a) =
        let x = either error id (exactValue a)
            y = either error id (exactValue b)
            result = case op of
              "+" -> x+y
              "-" -> x-y
              "*" -> x*y
              "/" -> x/y
              _ -> error "unknown arithmetic operator"
        in if op `elem` ["<","<=",">",">=","==","!="]
          then SBool (compareWith op x y)
        else if op == "quot"
          then SInteger "Integer" (numerator x `quot` numerator y)
        else if op == "rem"
          then SInteger "Integer" (numerator x `rem` numerator y)
        else if op == "pow"
          then if numerator y < 0 then error "negative exponent"
            else SInteger "Integer" (numerator x ^ numerator y)
        else convert t (reduced result) 64
    | t `elem` ["Complex64","Complex128"] =
        let component = if t == "Complex64" then "Float32" else "Float64"
            pair (SComplex _ r i) = (floatValue r,floatValue i)
            pair s = (floatValue s,0)
            (ar,ai) = pair a; (br,bi) = pair b
            rnd = floatValue . floatScalar component
            d = rnd (rnd (br*br)+rnd (bi*bi))
            (re,im) = case op of
              "+" -> (ar+br,ai+bi)
              "-" -> (ar-br,ai-bi)
              "*" -> (rnd (ar*br)-rnd (ai*bi),rnd (ar*bi)+rnd (ai*br))
              "/" ->
                (rnd (rnd (ar*br)+rnd (ai*bi))/d,
                 rnd (rnd (ai*br)-rnd (ar*bi))/d)
              _ -> error "complex values are not ordered"
        in if op == "==" then SBool (ar==br && ai==bi)
           else if op == "!=" then SBool (ar/=br || ai/=bi)
           else SComplex t (floatScalar component re) (floatScalar component im)
    | otherwise = let x = floatValue a; y = floatValue b
                      result = case op of
                        "+" -> x+y
                        "-" -> x-y
                        "*" -> x*y
                        "/" -> x/y
                        _ -> error "unknown operator"
                  in if op `elem` ["<","<=",">",">=","==","!="]
                     then SBool (compareWith op x y) else floatScalar t result
  compareWith "<" x y = x < y
  compareWith "<=" x y = x <= y
  compareWith ">" x y = x > y
  compareWith ">=" x y = x >= y
  compareWith "==" x y = x == y
  compareWith "!=" x y = x /= y
  compareWith _ _ _ = error "unknown comparison"
-- An async adapter's IO result, awaited where it is called. Adapters are
-- functions of their arguments, so running the action in place is safe.
awaitTask :: IO a -> a
awaitTask action = unsafePerformIO action
{-# NOINLINE awaitTask #-}

-- The portable total order. Exact numbers by value, sequences by unit, False
-- before True, absence before presence, lists element by element, Nothing
-- before Just, and other data by constructor identity, then fields left to
-- right.
compareValues :: Scalar -> Scalar -> Either String Ordering
compareValues a b = case (a, b) of
  (SBool x, SBool y) -> Right (compare x y)
  (SSequence _ x, SSequence _ y) -> Right (compare x y)
  (SCharacter _ x, SCharacter _ y) -> Right (compare x y)
  (SAbsent _, SAbsent _) -> Right EQ
  (SPresent _ x, SPresent _ y) -> optional x y
  (SList xs, SList ys) -> items xs ys
  (SData s xs, SData t ys)
    | s == t -> items xs ys
    | s == "Maybe::Nothing" && t == "Maybe::Just" -> Right LT
    | s == "Maybe::Just" && t == "Maybe::Nothing" -> Right GT
    | otherwise -> Right (compare s t)
  _ | isExact (scalarName a) && isExact (scalarName b) -> compare <$> exactRatio a <*> exactRatio b
  _ -> Left "values have no portable order"
  where
    optional Nothing Nothing = Right EQ
    optional Nothing (Just _) = Right LT
    optional (Just _) Nothing = Right GT
    optional (Just x) (Just y) = compareValues x y
    items [] [] = Right EQ
    items [] _ = Right LT
    items _ [] = Right GT
    items (x : xs) (y : ys) = compareValues x y >>= \order -> if order == EQ then items xs ys else Right order
    exactRatio value = case value of
      SInteger _ n -> Right (fromInteger n :: Rational)
      SDecimal c e -> Right (fromInteger c * (10 ^^ e))
      SRational n d -> Right (n % d)
      _ -> Left "exact value required"

-- A Set's items or a KeyVal's entries sorted by key, keeping the last of
-- equal keys.
canonicalItems :: Bool -> [Scalar] -> [Scalar]
canonicalItems keyed values = foldr keepLast [] (sortBy order values)
  where
    key value = case (keyed, value) of
      (True, SData _ (k : _)) -> k
      _ -> value
    order x y = either (const EQ) id (compareValues (key x) (key y))
    keepLast item rest = case rest of
      next : others | order item next == EQ -> next : others
      _ -> item : rest

helper :: String -> [Scalar] -> Int -> Scalar
helper n args bits = case (n,args) of
  ("checked",[v]) -> forceScalar v `seq` SBool True
  ("select",[c,a,b]) -> if truth c then a else b
  ("compare",[x,y]) -> case compareValues x y of
    Right order -> SData ("lawspec.collections::type::Ordering::" ++
      case order of LT -> "Less"; EQ -> "Equal"; GT -> "Greater") []
    Left message -> error message
  ("length",[SSequence _ xs]) -> SInteger "Integer" (fromIntegral (length xs))
  ("length",[SList xs]) -> SInteger "Integer" (fromIntegral (length xs))
  ("isPresent",[SPresent _ v]) -> SBool (case v of Just _ -> True; _ -> False)
  ("presentValue",[SPresent _ (Just v)]) -> v
  ("real",[SComplex _ r _]) -> r
  ("imag",[SComplex _ _ i]) -> i
  ("quot",[a,b]) -> binary "quot" a b
  ("pow",[a,b]) -> binary "pow" a b
  ("rem",[a,b]) -> binary "rem" a b
  ("negate",[a]) | isExact (scalarName a) -> binary "-" (SInteger "BigInt" 0) a
  ("negate",[SComplex t r i]) ->
    SComplex t (helper "negate" [r] bits) (helper "negate" [i] bits)
  ("negate",[a]) -> floatScalar (scalarName a) (negate (floatValue a))
  ("isNaN",[a]) -> SBool (isNaN (floatValue a))
  ("isInfinite",[a]) -> SBool (isInfinite (floatValue a))
  ("isFinite",[a]) ->
    SBool (not (isNaN (floatValue a) || isInfinite (floatValue a)))
  ("isNegativeZero",[a]) -> SBool (isNegativeZero (floatValue a))
  ("round",[a,b]) ->
    let { x = either error id (exactValue a)
        ; scale = either error numerator (exactValue (convert "Int32" b bits))
        ; factor = if scale >= 0 then 10^scale % 1 else 1 % 10^(-scale)
        }
    in either error id (decimal (fromInteger (round (x*factor)) / factor))
  (_,[a]) -> convert n a bits
  _ -> error "unknown helper or wrong arity"

sample :: String -> Int -> Int -> Scalar
sample t seed bits
  | take 9 t == "Nullable " || take 9 t == "Optional " =
      SPresent (take 8 t) (if even seed then Nothing
        else Just (sample (drop 9 t) (seed `div` 2) bits))
  | isInteger t =
      let { bounds = integerBounds bits t
          ; n = case bounds of
              Just (lo,hi) -> lo + randomN `mod` (hi-lo+1)
              Nothing -> if t == "BigUInt" then randomN
                else randomN - 2^(255::Int)
          }
      in SInteger t n
  | t == "Bool" = SBool (even seed)
  | t == "Decimal" =
      SDecimal (randomN - 2^(255::Int)) (fromIntegral (seed `mod` 41 - 20))
  | t == "Rational" =
      reduced ((randomN - 2^(255::Int)) % (randomN `mod` 2^(128::Int) + 1))
  | t == "Float32" = SFloat t (pad 8 (showHex (randomN `mod` 2^(32::Int)) ""))
  | t == "Float64" = SFloat t (pad 16 (showHex (randomN `mod` 2^(64::Int)) ""))
  | t == "Complex64" || t == "Complex128" =
      let c = if t == "Complex64" then "Float32" else "Float64"
      in SComplex t (sample c seed bits) (sample c (seed `div` 7) bits)
  | t == "Symbol" = SSymbol (show seed) "same"
  | t `elem` ["Unit","Null","Undefined"] = SAbsent t
  | t `elem` ["Char","CodePoint","CodeUnit16"] = SCharacter t (unit randomN)
  | otherwise = SSequence t (map unit (take (seed `mod` 40) stream))
  where stream = tail (iterate
          (\n -> (n*6364136223846793005+1442695040888963407) `mod` 2^(256::Int))
          (fromIntegral seed))
        randomN = stream !! 7
        maximumUnit = if t == "Bytes" then 256
          else if t `elem` ["CodeUnit16","Utf16Text"] then 65536 else 1114112
        unit n = let c = fromInteger (n `mod` maximumUnit)
                 in if validUnit t c then c else 0
        pad n s = replicate (n-length s) '0' ++ s

-- Native support types preserve domains that lack a faithful Prelude type.
newtype Decimal = Decimal Rational deriving (Eq, Ord, Show)
newtype CodePointText = CodePointText [Char] deriving (Eq, Ord, Show)
newtype Utf16Text = Utf16Text [Word16] deriving (Eq, Ord, Show)
-- Context creation is the only effect needed for fixture Symbol identity.
-- Equality uses Unique directly, never a potentially colliding hash or label.
newtype SymbolContext = SymbolContext Unique deriving (Eq)
instance Show SymbolContext where
  show _ = "<SymbolContext>"

newSymbolContext :: IO SymbolContext
newSymbolContext = SymbolContext <$> newUnique

scopeSymbols :: SymbolContext -> Scalar -> Scalar
scopeSymbols scope value = case value of
  SSymbol identity description -> SScopedSymbol scope identity description
  SPresent name payload -> SPresent name (fmap (scopeSymbols scope) payload)
  SList values -> SList (map (scopeSymbols scope) values)
  SData tag fields -> SData tag (map (scopeSymbols scope) fields)
  _ -> value

data Symbol = Symbol String String | ScopedSymbol SymbolContext String String
  deriving (Show)
instance Eq Symbol where
  Symbol identity _ == Symbol other _ = identity == other
  ScopedSymbol scope identity _ == ScopedSymbol otherScope other _ =
    scope == otherScope && identity == other
  _ == _ = False
data Null = Null deriving (Eq, Ord, Show)
data Undefined = Undefined deriving (Eq, Ord, Show)
data Nullable a = NullValue | NullableValue a deriving (Eq, Ord, Show)
data Optional a = UndefinedValue | OptionalValue a deriving (Eq, Ord, Show)

class Native a where
  toNative :: String -> Scalar -> Int -> a
  fromNative :: String -> a -> Int -> Scalar

checkMachineBits :: Int -> ()
checkMachineBits bits
  | bits == finiteBitSize (0 :: Int) = ()
  | otherwise = error "machineBits does not match native architecture"

instance Native a => Native [a] where
  toNative t s bits = case (stripPrefix "List " t, validate t s bits) of
    (Just inner, SList xs) -> map (\x -> toNative inner x bits) xs
    _ -> error "List required"
  fromNative t xs bits = case stripPrefix "List " t of
    Just inner -> let result = SList (map (\x -> fromNative inner x bits) xs)
                  in forceScalar result `seq` result
    Nothing -> error "List required"
instance Native a => Native (Maybe a) where
  toNative t s bits = case (stripPrefix "Maybe " t, validate t s bits) of
    (Just _, SData "Maybe::Nothing" []) -> Nothing
    (Just inner, SData "Maybe::Just" [value]) ->
      Just (toNative inner value bits)
    _ -> error "Maybe required"
  fromNative t value bits = case stripPrefix "Maybe " t of
    Just inner -> let result = case value of
                       Nothing -> SData "Maybe::Nothing" []
                       Just payload ->
                         SData "Maybe::Just" [fromNative inner payload bits]
                  in forceScalar result `seq` result
    Nothing -> error "Maybe required"
instance (Native a, Native b) => Native (Either a b) where
  toNative t s bits = let (left,right) = eitherArguments t
    in case validate t s bits of
    SData "Either::Left" [value] -> Left (toNative left value bits)
    SData "Either::Right" [value] -> Right (toNative right value bits)
    _ -> error "Either required"
  fromNative t value bits =
    let (left,right) = eitherArguments t
        result = case value of
          Left payload -> SData "Either::Left" [fromNative left payload bits]
          Right payload -> SData "Either::Right" [fromNative right payload bits]
    in forceScalar result `seq` result
instance Native Scalar where
  toNative = convert
  fromNative = validate
instance Native Bool where
  toNative t s bits = truth (validate t s bits)
  fromNative t x bits = validate t (SBool x) bits
instance Native Text where
  toNative t s bits = case validate t s bits of
    SSequence _ xs -> T.pack (map chr xs)
    _ -> error "Text required"
  fromNative t x bits = validate t (textScalar (T.unpack x)) bits
instance Native Rational where
  toNative t s bits = either error id (exactValue (convert t s bits))
  fromNative t x bits = validate t (reduced x) bits
instance Native Float where
  toNative t s bits = double2Float (floatValue (convert t s bits))
  fromNative t x bits = validate t (floatScalar t (float2Double x)) bits
instance Native Double where
  toNative t s bits = floatValue (convert t s bits)
  fromNative t x bits = validate t (floatScalar t x) bits
instance Native Int8 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int16 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int32 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int64 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word8 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word16 where
  toNative "CodeUnit16" s bits = case validate "CodeUnit16" s bits of
    SCharacter _ c -> fromIntegral c
    _ -> error "CodeUnit16 required"
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    SCharacter "CodeUnit16" c -> fromIntegral c
    _ -> error "Word16 required"
  fromNative "CodeUnit16" x bits =
    validate "CodeUnit16" (SCharacter "CodeUnit16" (fromIntegral x)) bits
  fromNative t x bits = validate t
    (if t == "CodeUnit16" then SCharacter t (fromIntegral x)
     else SInteger t (toInteger x)) bits
instance Native Word32 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word64 where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Integer where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> fromInteger n
    _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int where
  toNative t s bits = if bits /= finiteBitSize (0 :: Int)
    then error "machineBits does not match native architecture"
    else case convert t s bits of
      SInteger _ n -> fromInteger n
      _ -> error "integer required"
  fromNative t x bits = if bits /= finiteBitSize (0 :: Int)
    then error "machineBits does not match native architecture"
    else validate t (SInteger t (toInteger x)) bits
instance Native Word where
  toNative t s bits = if bits /= finiteBitSize (0 :: Word)
    then error "machineBits does not match native architecture"
    else case convert t s bits of
      SInteger _ n -> fromInteger n
      _ -> error "integer required"
  fromNative t x bits = if bits /= finiteBitSize (0 :: Word)
    then error "machineBits does not match native architecture"
    else validate t (SInteger t (toInteger x)) bits

instance Native () where
  toNative t s bits = validate t s bits `seq` ()
  fromNative t x bits = x `seq` validate t (SAbsent "Unit") bits

pad8 :: String -> String
pad8 s = replicate (8-length s) '0' ++ s

instance Native Char where
  toNative t s bits = case validate t s bits of
    SCharacter _ c -> chr c
    _ -> error "character required"
  fromNative t c bits = validate t (SCharacter t (ord c)) bits

instance Native (Complex Float) where
  toNative t s bits = case convert t s bits of
    SComplex _ r i -> double2Float (floatValue r) :+ double2Float (floatValue i)
    _ -> error "complex required"
  fromNative t (r :+ i) bits = validate t
    (SComplex t (floatScalar "Float32" (float2Double r))
      (floatScalar "Float32" (float2Double i))) bits
instance Native (Complex Double) where
  toNative t s bits = case convert t s bits of
    SComplex _ r i -> floatValue r :+ floatValue i
    _ -> error "complex required"
  fromNative t (r :+ i) bits = validate t
    (SComplex t (floatScalar "Float64" r) (floatScalar "Float64" i)) bits

instance Native ByteString where
  toNative t s bits = case validate t s bits of
    SSequence "Bytes" xs -> B.pack (map fromIntegral xs)
    _ -> error "Bytes required"
  fromNative t x bits =
    validate t (SSequence "Bytes" (map fromIntegral (B.unpack x))) bits

instance Native Decimal where
  toNative t value bits =
    Decimal (either error id (exactValue (validate t value bits)))
  fromNative t (Decimal value) bits =
    validate t (either error id (decimal value)) bits

instance Native CodePointText where
  toNative t value bits = case validate t value bits of
    SSequence "CodePointText" units -> CodePointText (map chr units)
    _ -> error "CodePointText required"
  fromNative t (CodePointText value) bits =
    validate t (SSequence "CodePointText" (map ord value)) bits

instance Native Utf16Text where
  toNative t value bits = case validate t value bits of
    SSequence "Utf16Text" units -> Utf16Text (map fromIntegral units)
    _ -> error "Utf16Text required"
  fromNative t (Utf16Text value) bits =
    validate t (SSequence "Utf16Text" (map fromIntegral value)) bits

instance Native Symbol where
  toNative t value bits = case validate t value bits of
    SSymbol identity description -> Symbol identity description
    SScopedSymbol scope identity description ->
      ScopedSymbol scope identity description
    _ -> error "Symbol required"
  fromNative t (Symbol identity description) bits =
    validate t (SSymbol identity description) bits
  fromNative t (ScopedSymbol scope identity description) bits =
    validate t (SScopedSymbol scope identity description) bits

instance Native Null where
  toNative t value bits = validate t value bits `seq` Null
  fromNative t value bits = value `seq` validate t (SAbsent "Null") bits

instance Native Undefined where
  toNative t value bits = validate t value bits `seq` Undefined
  fromNative t value bits = value `seq` validate t (SAbsent "Undefined") bits

instance Native a => Native (Nullable a) where
  toNative t value bits = case
      (stripPrefix "Nullable " t, validate t value bits) of
    (Just _, SPresent "Nullable" Nothing) -> NullValue
    (Just inner, SPresent "Nullable" (Just payload)) ->
      NullableValue (toNative inner payload bits)
    _ -> error "Nullable required"
  fromNative t value bits = case stripPrefix "Nullable " t of
    Just inner -> let result = case value of
                       NullValue -> SPresent "Nullable" Nothing
                       NullableValue payload ->
                         SPresent "Nullable"
                           (Just (fromNative inner payload bits))
                  in forceScalar result `seq` result
    _ -> error "Nullable required"

instance Native a => Native (Optional a) where
  toNative t value bits = case
      (stripPrefix "Optional " t, validate t value bits) of
    (Just _, SPresent "Optional" Nothing) -> UndefinedValue
    (Just inner, SPresent "Optional" (Just payload)) ->
      OptionalValue (toNative inner payload bits)
    _ -> error "Optional required"
  fromNative t value bits = case stripPrefix "Optional " t of
    Just inner -> let result = case value of
                       UndefinedValue -> SPresent "Optional" Nothing
                       OptionalValue payload ->
                         SPresent "Optional"
                           (Just (fromNative inner payload bits))
                  in forceScalar result `seq` result
    _ -> error "Optional required"

-- An abstract integer result erases the native width without losing its value.
newtype IntegerValue = IntegerValue Integer deriving (Eq, Show)
integerValue :: Integral a => a -> IntegerValue
integerValue = IntegerValue . toInteger
instance Native IntegerValue where
  toNative t s bits = case convert t s bits of
    SInteger _ n -> IntegerValue n
    _ -> error "integer required"
  fromNative t (IntegerValue n) bits = validate t (SInteger t n) bits

data Domain = Domain ([Scalar] -> Int -> [Scalar]) ([Scalar] -> Bool)
domainCandidates :: String -> Int -> Int -> [(String,Scalar)]
                 -> [Scalar] -> [Scalar]
domainCandidates t seed bits restrictions hints = rotate values where
  rotate [] = []
  rotate xs = let offset = seed `mod` length xs
              in drop offset xs ++ take offset xs
  values | isInteger t = case limits of
             (Just lo,Just hi) | lo > hi -> []
             (lo,hi) ->
               let { lower = maybe (min 0 (maybe 0 id hi) - 2^(256::Int)) id lo
                   ; upper = maybe (max 0 (maybe 0 id lo) + 2^(256::Int)) id hi
                   ; ns = [lower,upper,0,1,-1,lower+1,upper-1] ++
                       [lower + random j `mod` (upper-lower+1) | j <- [0..7]]
                   }
               in [SInteger t n | SInteger _ n <- hints ++ map (SInteger t) ns,
                                   n >= lower, n <= upper]
         | otherwise =
             [v | hint <- hints, Right v <- [convertScalar bits t hint]] ++
             [sample t (seed+j*7919) bits | j <- [0..7]]
  initial = case integerBounds bits t of
    Just (lo,hi) -> (Just lo,Just hi)
    Nothing -> (if t == "BigUInt" then Just 0 else Nothing,Nothing)
  limits = foldl restrict initial restrictions
  restrict (lo,hi) (op,v) =
    let { r = either error id (exactValue v)
        ; lower = if op == ">" then floor r + 1 else ceiling r
        ; upper = if op == "<" then ceiling r - 1 else floor r
        }
    in (if op `elem` [">",">=","=="]
          then Just (maybe lower (max lower) lo) else lo,
        if op `elem` ["<","<=","=="]
          then Just (maybe upper (min upper) hi) else hi)
  random j = (fromIntegral seed * 6364136223846793005 +
              fromIntegral j * 1442695040888963407) ^ (8::Int)

generateTuple :: [Domain] -> Int -> Int -> [Scalar] -> Either String [Scalar]
generateTuple domains seed attempts prefix = retry 0 where
  retry used
    | used >= attempts = Left ("refinement-generation-exhausted after " ++
        show used ++ " attempts; prefix=" ++ show prefix ++
        "; seed=" ++ show seed)
    | otherwise = case search used prefix of
        (Just result,_) -> Right result
        (Nothing,next) -> retry next
  search used values | length values == length domains = (Just values,used)
                     | used >= attempts = (Nothing,used)
                     | otherwise =
                         let Domain candidates accept = domains !! length values
                         in walk accept (used+1) values
                           (candidates values (seed+(used+1)*7919))
  walk _ used _ [] = (Nothing,used)
  walk accept used values (v:vs)
    | used >= attempts = (Nothing,used)
    | not (accept (values++[v])) = walk accept (used+1) values vs
    | otherwise = case search (used+1) (values++[v]) of
        (Just result,next) -> (Just result,next)
        (Nothing,next) -> walk accept next values vs

contract :: String -> Bool -> Scalar -> Scalar
contract context condition result = if condition then result else error context

refinedCase :: [Domain] -> Int -> Int -> Int
            -> ([Scalar] -> IO ()) -> String -> IO ()
refinedCase domains seed attempts shrinks check context = do
  let values = either (error . ((context ++ ": ") ++)) id
        (generateTuple domains seed attempts [])
  outcome <- capture check values
  case outcome of
    Nothing -> pure ()
    Just original -> do
      (best,_) <- foldM shrinkAt (values,shrinks) [0..length values-1]
      ioError (userError (context ++ ": " ++ original ++
        "; refined counterexample=" ++ show best ++ "; seed=" ++ show seed))
  where
    capture f xs = (f xs >> pure Nothing) `catch`
      (\e -> pure (Just (displayException (e :: SomeException))))
    shrinkAt state@(best,_) i =
      let { Domain candidates _ = domains !! i
          ; additional = case best !! i of
              SInteger t n -> map (SInteger t)
                (0:signum n:takeWhile ((>1) . abs)
                  (tail (iterate (`quot` 2) n)))
              _ -> []
          }
      in foldM (tryCandidate i) state
        (additional ++ candidates (take i best) 0)
    tryCandidate i state@(best,budget) candidate
      | budget <= 0 = pure state
      | complexity candidate >= complexity (best !! i) = pure (best,budget-1)
      | otherwise = do
          let prefix = take i best ++ [candidate]
              Domain _ accept = domains !! i
          if not (accept prefix) then pure (best,budget-1)
          else case generateTuple domains seed (min attempts 100) prefix of
            Left _ -> pure (best,budget-1)
            Right trial -> do
              failed <- capture check trial
              pure ((case failed of Just _ -> trial; Nothing -> best),budget-1)

complexity :: Scalar -> Integer
complexity (SInteger _ n) = abs n
complexity (SBool b) = if b then 1 else 0
complexity (SPresent _ Nothing) = 0
complexity (SPresent _ (Just v)) = 1 + complexity v
complexity (SSequence _ xs) = fromIntegral (length xs)
complexity (SCharacter _ c) = fromIntegral c
complexity v@(SFloat _ _) = toInteger (castDoubleToWord64 (abs (floatValue v)))
complexity (SComplex _ r i) = complexity r + complexity i
complexity (SAbsent _) = 0
complexity (SSymbol _ _) = 1
complexity (SScopedSymbol _ _ _) = 1
complexity v = let r = either error id (exactValue v)
               in abs (numerator r) + denominator r - 1

bool :: Bool -> Scalar
bool = SBool

-- Standalone contracts must observe their result even when
-- the predicate is true.
forceScalar :: Scalar -> ()
forceScalar (SInteger _ n) = n `seq` ()
forceScalar (SBool b) = b `seq` ()
forceScalar (SDecimal c e) = c `seq` e `seq` ()
forceScalar (SRational n d) = n `seq` d `seq` ()
forceScalar (SFloat _ bs) = foldr seq () bs
forceScalar (SComplex _ r i) = forceScalar r `seq` forceScalar i
forceScalar (SSequence _ xs) = foldr seq () xs
forceScalar (SList xs) =
  foldr (\value rest -> forceScalar value `seq` rest) () xs
forceScalar (SData tag xs) = foldr seq () tag `seq`
  foldr (\value rest -> forceScalar value `seq` rest) () xs
forceScalar (SCharacter _ c) = c `seq` ()
forceScalar (SSymbol ident description) =
  foldr seq () ident `seq` foldr seq () description
forceScalar (SScopedSymbol scope ident description) =
  scope `seq` foldr seq () ident `seq` foldr seq () description
forceScalar (SPresent _ (Just v)) = forceScalar v
forceScalar _ = ()

-- Workflow runtime. A workflow runs under a runtime: a clock, a seeded
-- random source, a trace of what happened, and the state of stateful
-- stages. A runtime is attached to a symbol context (workflowContext);
-- without one, the default runtime applies (real time, unless the tests
-- installed a virtual clock). Durations are Integer microseconds. Workflow
-- bodies are pure, so a stage's waits run through unsafePerformIO.

-- | Tells the time and waits, in microseconds.
data Clock = Clock { clockNow :: IO Integer, clockSleep :: Integer -> IO () }

realClock :: Clock
realClock = Clock
  { clockNow = (`div` 1000) . toInteger <$> getMonotonicTimeNSec
  , clockSleep = \micros -> threadDelay (fromInteger micros) }

-- | Advances when slept on and returns at once.
virtualClock :: IO (Clock, IORef Integer)
virtualClock = do
  time <- newIORef 0
  pure (Clock (readIORef time) (\micros -> modifyIORef' time (+ micros)), time)

-- | The same sequence on every target for the same seed: (output, next state).
splitMix64 :: Word64 -> (Word64, Word64)
splitMix64 state =
  let next = state + 0x9E3779B97F4A7C15
      z1 = (next `xor` (next `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), next)

-- | A stage starting or finishing an attempt, or a wait.
data TraceEvent = TraceEvent { traceKind :: String, traceStage :: String, traceNumber :: Integer, traceSucceeded :: Bool }
  deriving (Eq, Show)

data WorkflowRuntime = WorkflowRuntime
  { runtimeClock :: Clock, runtimeRandom :: IORef Word64
  , runtimeTrace :: IORef [TraceEvent], runtimeState :: IORef [(String, Scalar)] }

newWorkflowRuntime :: Clock -> Word64 -> IO WorkflowRuntime
newWorkflowRuntime clock seed = WorkflowRuntime clock <$> newIORef seed <*> newIORef [] <*> newIORef []

-- | Uniform in [0, bound); 0 when bound is 0.
randomBelow :: WorkflowRuntime -> Integer -> IO Integer
randomBelow runtime bound
  | bound <= 0 = pure 0
  | otherwise = do
      (value, next) <- splitMix64 <$> readIORef (runtimeRandom runtime)
      writeIORef (runtimeRandom runtime) next
      pure (toInteger value `mod` bound)

{-# NOINLINE workflowTable #-}
workflowTable :: IORef [(Unique, WorkflowRuntime)]
workflowTable = unsafePerformIO (newIORef [])

{-# NOINLINE defaultWorkflow #-}
defaultWorkflow :: IORef (Maybe WorkflowRuntime)
defaultWorkflow = unsafePerformIO (newIORef Nothing)

-- | A symbol context whose workflows run under the runtime.
workflowContext :: WorkflowRuntime -> IO SymbolContext
workflowContext runtime = do
  unique <- newUnique
  modifyIORef' workflowTable ((unique, runtime) :)
  pure (SymbolContext unique)

-- | Makes the default runtime virtual, as generated tests do.
useVirtualClock :: Word64 -> IO ()
useVirtualClock seed = do
  (clock, _) <- virtualClock
  runtime <- newWorkflowRuntime clock seed
  writeIORef defaultWorkflow (Just runtime)

workflowRuntime :: SymbolContext -> IO WorkflowRuntime
workflowRuntime (SymbolContext unique) = do
  table <- readIORef workflowTable
  case lookup unique table of
    Just runtime -> pure runtime
    Nothing -> readIORef defaultWorkflow >>= \current -> case current of
      Just runtime -> pure runtime
      Nothing -> do
        runtime <- newWorkflowRuntime realClock 0
        writeIORef defaultWorkflow (Just runtime)
        pure runtime

-- | retryStrategy is immediate, fixed, linear, exponential, fibonacci or
-- custom; delay, step, factor and cap (negative for none) are its parameters.
data Retry = Retry
  { retryStrategy :: String, retryDelayOf :: Integer, retryStep :: Integer, retryFactor :: Integer, retryCap :: Integer
  , retryAttempts :: Integer, retryJitter :: String
  , retryWhen :: Maybe (Scalar -> Bool)
  , retryDecide :: Maybe (Integer -> Scalar -> Integer -> Maybe Integer) }

data StagePolicy = StagePolicy { policyStage :: String, policyRetry :: Maybe Retry, policyTimeout :: Integer }

-- | The delay before attempt (2 or more), before jitter.
retryDelay :: Retry -> Integer -> Integer
retryDelay retry attempt = case retryStrategy retry of
  "immediate" -> 0
  "fixed" -> retryDelayOf retry
  "linear" -> retryDelayOf retry + retryStep retry * (n - 1)
  "exponential" ->
    let delay = retryDelayOf retry * retryFactor retry ^ (n - 1)
    in if retryCap retry >= 0 && delay > retryCap retry then retryCap retry else delay
  "fibonacci" -> retryDelayOf retry * fibonacci n
  other -> error ("unknown retry strategy: " ++ other)
  where
    n = attempt - 1
    fibonacci k = fst (foldl (\(a, b) _ -> (b, a + b)) (1, 1) [2 .. k])

-- | Full: [0, delay]; equal: delay/2 + [0, delay/2]; decorrelated:
-- [base, previous * 3], capped at delay.
jittered :: WorkflowRuntime -> String -> Integer -> Integer -> Integer -> IO Integer
jittered runtime jitter delay previous base = case jitter of
  "full" -> randomBelow runtime (delay + 1)
  "equal" -> let half = delay `div` 2 in (half +) <$> randomBelow runtime (delay - half + 1)
  "decorrelated" -> do
    let high = max base (previous * 3)
    value <- (base +) <$> randomBelow runtime (high - base + 1)
    pure (min delay value)
  _ -> pure delay

-- | Runs a stage's attempts under its policy; a Left is a failure.
{-# NOINLINE runStage #-}
runStage :: SymbolContext -> StagePolicy -> (() -> Scalar) -> Scalar
runStage symbols policy attempt = unsafePerformIO (workflowRuntime symbols >>= \runtime -> loop runtime 1 0)
  where
    event runtime kind number succeeded =
      modifyIORef' (runtimeTrace runtime) (++ [TraceEvent kind (policyStage policy) number succeeded])
    loop runtime number previous = do
      event runtime "start" number False
      result <- evaluate (attempt ())
      let failure = case result of
            SData "Either::Left" [value] -> Just value
            _ -> Nothing
      event runtime "finish" number (failure == Nothing)
      case (failure, policyRetry policy) of
        (Just value, Just retry)
          | retryAttempts retry > 0 && number >= retryAttempts retry -> pure result
          | maybe False (\when -> not (when value)) (retryWhen retry) -> pure result
          | otherwise -> do
              let next = number + 1
              wait <- case retryStrategy retry of
                "custom" -> pure (maybe Nothing (\decide -> decide next value previous) (retryDecide retry))
                _ -> do
                  let base = if retryStrategy retry == "immediate" then 0 else retryDelay retry 2
                  Just <$> jittered runtime (retryJitter retry) (retryDelay retry next) previous base
              case wait of
                Nothing -> pure result
                Just delay -> do
                  event runtime "sleep" delay True
                  clockSleep (runtimeClock runtime) delay
                  loop runtime next delay
        _ -> pure result

-- | A logical Duration of whole microseconds.
durationScalar :: Integer -> Scalar
durationScalar micros = SData "lawspec.time::type::Duration::Duration" [SInteger "Integer" micros]

-- | A RetryDecision's delay, or Nothing to stop.
retryDecision :: Scalar -> Maybe Integer
retryDecision decision = case decision of
  SData "lawspec.time::type::RetryDecision::RetryAfter" [SData _ [SInteger _ micros]] -> Just micros
  _ -> Nothing

