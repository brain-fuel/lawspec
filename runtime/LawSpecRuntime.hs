{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
-- The portable scalar domain. No test framework or target runtime dependencies.
module LawSpecRuntime where

import Control.Exception (SomeException, catch, displayException)
import Control.Monad (foldM)
import Data.Char (ord, chr)
import Data.Int
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Complex (Complex((:+)))
import Data.Word
import Data.Bits (finiteBitSize)
import Data.Text (Text)
import qualified Data.Text as T
import Data.List (find)
import Data.Ratio
import GHC.Float (castFloatToWord32, castDoubleToWord64, castWord32ToFloat, castWord64ToDouble)
import Numeric (showHex, readHex)

data Family = Boolean | IntegerFamily | Exact | Floating | Complex | Character | Sequence | Identity | Absence deriving (Eq, Show)
data Primitive = Primitive { primitiveName :: String, family :: Family, width :: Maybe Int, signed :: Bool } deriving (Eq, Show)
primitives :: [Primitive]
primitives = [Primitive "Bool" Boolean Nothing False]
  ++ [Primitive (p ++ show w) IntegerFamily (Just w) s | (p,s) <- [("Int",True),("UInt",False)], w <- [8,16,32,64]]
  ++ [Primitive n IntegerFamily Nothing s | (n,s) <- [("IntSize",True),("UIntSize",False),("UIntPtr",False),("Integer",True),("BigInt",True),("BigUInt",False)]]
  ++ [Primitive n f w False | (n,f,w) <- [("Decimal",Exact,Nothing),("Rational",Exact,Nothing),("Float32",Floating,Just 32),("Float64",Floating,Just 64),("Complex64",Complex,Just 32),("Complex128",Complex,Just 64)]]
  ++ [Primitive n f Nothing False | (f,ns) <- [(Character,["Char","CodePoint","CodeUnit16"]),(Sequence,["Text","CodePointText","Utf16Text","Bytes"]),(Identity,["Symbol"]),(Absence,["Unit","Null","Undefined"])], n <- ns]
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
  w <- if n `elem` ["IntSize","UIntSize","UIntPtr"] then Just machine else width p
  if family p /= IntegerFamily then Nothing else pure $ if signed p then (negate (2^(w-1)),2^(w-1)-1) else (0,2^w-1)

-- Raw strings travel as numeric code points/units, never JSON surrogate strings.
data Scalar = SInteger String Integer | SBool Bool | SDecimal Integer Integer
  | SRational Integer Integer | SFloat String String | SComplex String Scalar Scalar
  | SSequence String [Int] | SCharacter String Int | SSymbol String String
  | SAbsent String | SPresent String (Maybe Scalar) deriving (Eq, Show)
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
scalarName (SAbsent t) = t
scalarName (SPresent t _) = t
floatScalar :: String -> Double -> Scalar
floatScalar t x = SFloat t $ pad (if t == "Float32" then 8 else 16) $ if t == "Float32" then showHex (castFloatToWord32 (realToFrac x)) "" else showHex (castDoubleToWord64 x) ""
  where pad n s = replicate (n-length s) '0' ++ s
floatValue :: Scalar -> Double
floatValue (SFloat t bits) = case readHex bits of
  [(n,"")] -> if t == "Float32" then realToFrac (castWord32ToFloat (fromInteger n)) else castWord64ToDouble (fromInteger n)
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
           | d /= 1 = Left "conversion to Decimal is not finite; use prelude.round"
           | otherwise = let scale = max a b in Right (SDecimal (numerator r * 2^(scale-a) * 5^(scale-b)) (-scale))
validateScalar :: Int -> Scalar -> Either String Scalar
validateScalar machine s = case s of
  SInteger t n | not (isInteger t) -> Left "unknown integer type"
               | t == "BigUInt" && n < 0 -> Left "BigUInt cannot be negative"
               | Just (lo,hi) <- integerBounds machine t, n < lo || n > hi -> Left ("integer outside " ++ t ++ " range")
               | otherwise -> Right s
  SRational n d | d == 0 -> Left "Rational denominator cannot be zero"
                | otherwise -> Right (reduced (n % d))
  SCharacter t c | validUnit t c -> Right s
                 | otherwise -> Left ("invalid " ++ t ++ " representation")
  SSequence t xs | t `elem` ["Text","CodePointText","Utf16Text","Bytes"], all (validUnit t) xs -> Right s
                | otherwise -> Left ("invalid " ++ t ++ " representation")
  SFloat t bits | t `elem` ["Float32","Float64"], length bits == (if t == "Float32" then 8 else 16), [(_,"")] <- (readHex bits :: [(Integer,String)]) -> Right s
               | otherwise -> Left "invalid IEEE bit representation"
  SComplex t r i | t `elem` ["Complex64","Complex128"], all ((== if t == "Complex64" then "Float32" else "Float64") . scalarName) [r,i] -> SComplex t <$> validateScalar machine r <*> validateScalar machine i
                 | otherwise -> Left "complex component precision mismatch"
  SSymbol i d | all (validUnit "Text" . ord) (i ++ d) -> Right s
              | otherwise -> Left "Symbol IDs and descriptions must contain Unicode scalars"
  SAbsent t | t `elem` ["Unit","Null","Undefined"] -> Right s
            | otherwise -> Left "unknown absence value"
  SPresent t v | t `elem` ["Nullable","Optional"] -> SPresent t <$> traverse (validateScalar machine) v
               | otherwise -> Left "unknown presence type"
  _ -> Right s
validUnit :: String -> Int -> Bool
validUnit t c
  | t == "Bytes" = c >= 0 && c <= 255
  | t `elem` ["CodeUnit16","Utf16Text"] = c >= 0 && c <= 65535
  | t `elem` ["CodePoint","CodePointText"] = c >= 0 && c <= 1114111
  | t `elem` ["Char","Text"] = c >= 0 && c <= 1114111 && (c < 55296 || c > 57343)
  | otherwise = False
promote :: String -> String -> String -> Either String String
promote op a b
  | not (isNumeric a && isNumeric b) = Left "arithmetic requires numeric operands (Bool is not an integer)"
  | isExact a /= isExact b = Left "exact/inexact mixing requires an explicit conversion"
  | op `elem` ["quot","rem"] = if isInteger a && isInteger b then Right "Integer" else Left "quot/rem require integer operands"
  | isExact a = Right $ if op == "/" || "Rational" `elem` [a,b] then "Rational" else if "Decimal" `elem` [a,b] then "Decimal" else "Integer"
  | otherwise = Right $ if any (`elem` ["Complex64","Complex128"]) [a,b]
      then if any (`elem` ["Float64","Complex128"]) [a,b] then "Complex128" else "Complex64"
      else if "Float64" `elem` [a,b] then "Float64" else "Float32"
convertScalar :: Int -> String -> Scalar -> Either String Scalar
convertScalar machine t s
  | t == scalarName s = validateScalar machine s
  | isInteger t = do r <- exactValue s; if denominator r /= 1 then Left ("fractional conversion to " ++ t) else validateScalar machine (SInteger t (numerator r))
  | t == "Rational" = reduced <$> exactValue s
  | t == "Decimal" = exactValue s >>= decimal
  | t `elem` ["Float32","Float64"] = if isExact (scalarName s) then (\r -> if t == "Float32" then SFloat t (pad8 (showHex (castFloatToWord32 (fromRational r)) "")) else floatScalar t (fromRational r)) <$> exactValue s else case s of
      SFloat _ _ -> Right (floatScalar t (floatValue s))
      _ -> Left "conversion requires a real number"
  | t `elem` ["Complex64","Complex128"] =
      let component = if t == "Complex64" then "Float32" else "Float64" in case s of
        SComplex _ r i -> SComplex t <$> convertScalar machine component r <*> convertScalar machine component i
        _ -> SComplex t <$> convertScalar machine component s <*> pure (floatScalar component 0)
  | otherwise = Left ("cannot convert " ++ scalarName s ++ " to " ++ t)
scalarBoundaries :: Int -> String -> [Scalar]
scalarBoundaries machine t
  | isInteger t = map (SInteger t) $ case integerBounds machine t of Just (lo,hi) -> [lo, max lo (-1),0,hi]; Nothing -> if t == "BigUInt" then [0,1,2^(128::Int)] else [-2^(128::Int),-1,0,2^(128::Int)]
  | otherwise = case t of
      "Bool" -> map SBool [False,True]
      "Decimal" -> [SDecimal 0 0,SDecimal 1 (-1),SDecimal (-123) 100]
      "Rational" -> [SRational 0 1,SRational 1 2,SRational (-2) 3]
      "Float32" -> floats t
      "Float64" -> floats t
      "Complex64" -> [SComplex t x y | (x,y) <- zip (floats "Float32") (reverse (floats "Float32"))]
      "Complex128" -> [SComplex t x y | (x,y) <- zip (floats "Float64") (reverse (floats "Float64"))]
      "Symbol" -> [SSymbol "a" "same", SSymbol "b" "same"]
      _ | Just p <- primitive t, family p == Character -> map (SCharacter t) (units t)
        | Just p <- primitive t, family p == Sequence -> map (SSequence t) [[],units t]
        | otherwise -> [SAbsent t]
  where floats n = map (SFloat n) $ if n == "Float32"
          then ["00000000","80000000","3f800000","bf800000","7f800000","ff800000","7fc00000","00000001","007fffff","00800000","7f7fffff","ff7fffff"]
          else ["0000000000000000","8000000000000000","3ff0000000000000","bff0000000000000","7ff0000000000000","fff0000000000000","7ff8000000000000","0000000000000001","000fffffffffffff","0010000000000000","7fefffffffffffff","ffefffffffffffff"]
        units n | n == "Bytes" = [0,127,128,255]
                | n `elem` ["Utf16Text","CodeUnit16"] = [0,55296,56320,65535]
                | n `elem` ["CodePointText","CodePoint"] = [0,55296,128512,1114111]
                | otherwise = [0,97,955,128512,1114111]
textScalar :: String -> Scalar
textScalar = SSequence "Text" . map ord

type Value = Scalar
convert :: String -> Scalar -> Int -> Scalar
convert t s bits
  | Just inner <- strip "Nullable " t = presence "Nullable" "Null" inner
  | Just inner <- strip "Optional " t = presence "Optional" "Undefined" inner
  | isExact t, SFloat _ _ <- s = let x = floatValue s in if isNaN x || isInfinite x then error "non-finite exact conversion" else either error id (convertScalar bits t (reduced (toRational x)))
  | otherwise = either error id (convertScalar bits t s)
  where presence n absent inner = case s of
          SAbsent a | a == absent -> SPresent n Nothing
          SPresent k v | k == n -> SPresent n (fmap (\x -> convert inner x bits) v)
          _ -> error "tagged presence required"
        strip [] xs = Just xs
        strip (a:as) (b:bs) | a == b = strip as bs
        strip _ _ = Nothing
validate :: String -> Scalar -> Int -> Scalar
validate t s bits
  | take 9 t == "Nullable " || take 9 t == "Optional " = convert t s bits
  | scalarName s /= t = error ("invalid " ++ t ++ " representation")
  | otherwise = either error id (validateScalar bits s)
truth :: Scalar -> Bool
truth (SBool b) = b
truth _ = error "Bool required"
equal :: Scalar -> Scalar -> Bool
equal a b
  | isInexact (scalarName a) && isInexact (scalarName b) = truth (binary "==" a b)
  | isExact (scalarName a) && isExact (scalarName b) = exactValue a == exactValue b
  | SFloat _ _ <- a, SFloat _ _ <- b = floatValue a == floatValue b
  | SComplex _ r i <- a, SComplex _ s j <- b = equal r s && equal i j
  | SPresent n x <- a, SPresent m y <- b = n == m && case (x,y) of (Nothing,Nothing) -> True; (Just p,Just q) -> equal p q; _ -> False
  | SSymbol i _ <- a, SSymbol j _ <- b = i == j
  | otherwise = a == b
binary :: String -> Scalar -> Scalar -> Scalar
binary op a b | op `elem` ["==","!="], not (isNumeric (scalarName a)) = SBool (if op == "==" then equal a b else not (equal a b))
binary op a b = either error run (promote op (scalarName a) (scalarName b)) where
  run t
    | isExact (scalarName a) =
        let x = either error id (exactValue a); y = either error id (exactValue b)
            result = case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> error "unknown arithmetic operator"
        in if op `elem` ["<","<=",">",">=","==","!="] then SBool (compareWith op x y)
        else if op == "quot" then SInteger "Integer" (numerator x `quot` numerator y)
        else if op == "rem" then SInteger "Integer" (numerator x `rem` numerator y)
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
              "/" -> (rnd (rnd (ar*br)+rnd (ai*bi))/d,rnd (rnd (ai*br)-rnd (ar*bi))/d)
              _ -> error "complex values are not ordered"
        in if op == "==" then SBool (ar==br && ai==bi) else if op == "!=" then SBool (ar/=br || ai/=bi) else SComplex t (floatScalar component re) (floatScalar component im)
    | otherwise = let x = floatValue a; y = floatValue b
                      result = case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> error "unknown operator"
                  in if op `elem` ["<","<=",">",">=","==","!="] then SBool (compareWith op x y) else floatScalar t result
  compareWith "<" x y = x < y
  compareWith "<=" x y = x <= y
  compareWith ">" x y = x > y
  compareWith ">=" x y = x >= y
  compareWith "==" x y = x == y
  compareWith "!=" x y = x /= y
  compareWith _ _ _ = error "unknown comparison"
helper :: String -> [Scalar] -> Int -> Scalar
helper n args bits = case (n,args) of
  ("checked",[v]) -> forceScalar v `seq` SBool True
  ("length",[SSequence _ xs]) -> SInteger "Integer" (fromIntegral (length xs))
  ("isPresent",[SPresent _ v]) -> SBool (case v of Just _ -> True; _ -> False)
  ("presentValue",[SPresent _ (Just v)]) -> v
  ("real",[SComplex _ r _]) -> r
  ("imag",[SComplex _ _ i]) -> i
  ("quot",[a,b]) -> binary "quot" a b
  ("rem",[a,b]) -> binary "rem" a b
  ("negate",[a]) | isExact (scalarName a) -> binary "-" (SInteger "BigInt" 0) a
  ("negate",[SComplex t r i]) -> SComplex t (helper "negate" [r] bits) (helper "negate" [i] bits)
  ("negate",[a]) -> floatScalar (scalarName a) (negate (floatValue a))
  ("isNaN",[a]) -> SBool (isNaN (floatValue a))
  ("isInfinite",[a]) -> SBool (isInfinite (floatValue a))
  ("isFinite",[a]) -> SBool (not (isNaN (floatValue a) || isInfinite (floatValue a)))
  ("isNegativeZero",[a]) -> SBool (isNegativeZero (floatValue a))
  ("round",[a,b]) -> let { x = either error id (exactValue a); scale = either error numerator (exactValue (convert "Int32" b bits)); factor = if scale >= 0 then 10^scale % 1 else 1 % 10^(-scale) } in either error id (decimal (fromInteger (round (x*factor)) / factor))
  (_,[a]) -> convert n a bits
  _ -> error "unknown helper or wrong arity"

sample :: String -> Int -> Int -> Scalar
sample t seed bits
  | take 9 t == "Nullable " || take 9 t == "Optional " = SPresent (take 8 t) (if even seed then Nothing else Just (sample (drop 9 t) (seed `div` 2) bits))
  | isInteger t = let { bounds = integerBounds bits t; n = case bounds of Just (lo,hi) -> lo + randomN `mod` (hi-lo+1); Nothing -> if t == "BigUInt" then randomN else randomN - 2^(255::Int) } in SInteger t n
  | t == "Bool" = SBool (even seed)
  | t == "Decimal" = SDecimal (randomN - 2^(255::Int)) (fromIntegral (seed `mod` 41 - 20))
  | t == "Rational" = reduced ((randomN - 2^(255::Int)) % (randomN `mod` 2^(128::Int) + 1))
  | t == "Float32" = SFloat t (pad 8 (showHex (randomN `mod` 2^(32::Int)) ""))
  | t == "Float64" = SFloat t (pad 16 (showHex (randomN `mod` 2^(64::Int)) ""))
  | t == "Complex64" || t == "Complex128" = let c = if t == "Complex64" then "Float32" else "Float64" in SComplex t (sample c seed bits) (sample c (seed `div` 7) bits)
  | t == "Symbol" = SSymbol (show seed) "same"
  | t `elem` ["Unit","Null","Undefined"] = SAbsent t
  | t `elem` ["Char","CodePoint","CodeUnit16"] = SCharacter t (unit randomN)
  | otherwise = SSequence t (map unit (take (seed `mod` 40) stream))
  where stream = tail (iterate (\n -> (n*6364136223846793005+1442695040888963407) `mod` 2^(256::Int)) (fromIntegral seed))
        randomN = stream !! 7
        maximumUnit = if t == "Bytes" then 256 else if t `elem` ["CodeUnit16","Utf16Text"] then 65536 else 1114112
        unit n = let c = fromInteger (n `mod` maximumUnit) in if validUnit t c then c else 0
        pad n s = replicate (n-length s) '0' ++ s

class Native a where
  toNative :: String -> Scalar -> Int -> a
  fromNative :: String -> a -> Int -> Scalar
instance Native Scalar where
  toNative = convert
  fromNative = validate
instance Native Bool where
  toNative t s bits = truth (validate t s bits)
  fromNative t x bits = validate t (SBool x) bits
instance Native Text where
  toNative t s bits = case validate t s bits of SSequence _ xs -> T.pack (map chr xs); _ -> error "Text required"
  fromNative t x bits = validate t (textScalar (T.unpack x)) bits
instance Native Rational where
  toNative t s bits = either error id (exactValue (convert t s bits))
  fromNative t x bits = validate t (reduced x) bits
instance Native Float where
  toNative t s bits = realToFrac (floatValue (convert t s bits))
  fromNative t x bits = validate t (floatScalar t (realToFrac x)) bits
instance Native Double where
  toNative t s bits = floatValue (convert t s bits)
  fromNative t x bits = validate t (floatScalar t x) bits
instance Native Int8 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int16 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int32 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int64 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word8 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word16 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; SCharacter "CodeUnit16" c -> fromIntegral c; _ -> error "Word16 required"
  fromNative t x bits = validate t (if t == "CodeUnit16" then SCharacter t (fromIntegral x) else SInteger t (toInteger x)) bits
instance Native Word32 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Word64 where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Integer where
  toNative t s bits = case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = validate t (SInteger t (toInteger x)) bits
instance Native Int where
  toNative t s bits = if bits /= finiteBitSize (0 :: Int) then error "machineBits does not match native architecture" else case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = if bits /= finiteBitSize (0 :: Int) then error "machineBits does not match native architecture" else validate t (SInteger t (toInteger x)) bits
instance Native Word where
  toNative t s bits = if bits /= finiteBitSize (0 :: Word) then error "machineBits does not match native architecture" else case convert t s bits of SInteger _ n -> fromInteger n; _ -> error "integer required"
  fromNative t x bits = if bits /= finiteBitSize (0 :: Word) then error "machineBits does not match native architecture" else validate t (SInteger t (toInteger x)) bits

instance Native () where
  toNative t s bits = validate t s bits `seq` ()
  fromNative t x bits = x `seq` validate t (SAbsent "Unit") bits

pad8 :: String -> String
pad8 s = replicate (8-length s) '0' ++ s

instance Native Char where
  toNative t s bits = case validate t s bits of SCharacter _ c -> chr c; _ -> error "character required"
  fromNative t c bits = validate t (SCharacter t (ord c)) bits

instance Native (Complex Float) where
  toNative t s bits = case convert t s bits of SComplex _ r i -> realToFrac (floatValue r) :+ realToFrac (floatValue i); _ -> error "complex required"
  fromNative t (r :+ i) bits = validate t (SComplex t (floatScalar "Float32" (realToFrac r)) (floatScalar "Float32" (realToFrac i))) bits
instance Native (Complex Double) where
  toNative t s bits = case convert t s bits of SComplex _ r i -> floatValue r :+ floatValue i; _ -> error "complex required"
  fromNative t (r :+ i) bits = validate t (SComplex t (floatScalar "Float64" r) (floatScalar "Float64" i)) bits

instance Native ByteString where
  toNative t s bits = case validate t s bits of SSequence "Bytes" xs -> B.pack (map fromIntegral xs); _ -> error "Bytes required"
  fromNative t x bits = validate t (SSequence "Bytes" (map fromIntegral (B.unpack x))) bits

-- An abstract integer result erases the native width without losing its value.
newtype IntegerValue = IntegerValue Integer deriving (Eq, Show)
integerValue :: Integral a => a -> IntegerValue
integerValue = IntegerValue . toInteger
instance Native IntegerValue where
  toNative t s bits = case convert t s bits of SInteger _ n -> IntegerValue n; _ -> error "integer required"
  fromNative t (IntegerValue n) bits = validate t (SInteger t n) bits

data Domain = Domain ([Scalar] -> Int -> [Scalar]) ([Scalar] -> Bool)
domainCandidates :: String -> Int -> Int -> [(String,Scalar)] -> [Scalar] -> [Scalar]
domainCandidates t seed bits restrictions hints = rotate values where
  rotate [] = []
  rotate xs = let offset = seed `mod` length xs in drop offset xs ++ take offset xs
  values | isInteger t = case limits of
             (Just lo,Just hi) | lo > hi -> []
             (lo,hi) -> let { lower = maybe (min 0 (maybe 0 id hi) - 2^(256::Int)) id lo
                           ; upper = maybe (max 0 (maybe 0 id lo) + 2^(256::Int)) id hi
                           ; ns = [lower,upper,0,1,-1,lower+1,upper-1] ++ [lower + random j `mod` (upper-lower+1) | j <- [0..7]]
                       } in [SInteger t n | SInteger _ n <- hints ++ map (SInteger t) ns, n >= lower, n <= upper]
         | otherwise = [v | hint <- hints, Right v <- [convertScalar bits t hint]] ++ [sample t (seed+j*7919) bits | j <- [0..7]]
  initial = case integerBounds bits t of Just (lo,hi) -> (Just lo,Just hi); Nothing -> (if t == "BigUInt" then Just 0 else Nothing,Nothing)
  limits = foldl restrict initial restrictions
  restrict (lo,hi) (op,v) = let { r = either error id (exactValue v)
                              ; lower = if op == ">" then floor r + 1 else ceiling r
                              ; upper = if op == "<" then ceiling r - 1 else floor r
                          } in (if op `elem` [">",">=","=="] then Just (maybe lower (max lower) lo) else lo,
                              if op `elem` ["<","<=","=="] then Just (maybe upper (min upper) hi) else hi)
  random j = (fromIntegral seed * 6364136223846793005 + fromIntegral j * 1442695040888963407) ^ (8::Int)

generateTuple :: [Domain] -> Int -> Int -> [Scalar] -> Either String [Scalar]
generateTuple domains seed attempts prefix = retry 0 where
  retry used | used >= attempts = Left ("refinement-generation-exhausted after " ++ show used ++ " attempts; prefix=" ++ show prefix ++ "; seed=" ++ show seed)
             | otherwise = case search used prefix of (Just result,_) -> Right result; (Nothing,next) -> retry next
  search used values | length values == length domains = (Just values,used)
                     | used >= attempts = (Nothing,used)
                     | otherwise = let Domain candidates accept = domains !! length values
                                   in walk accept (used+1) values (candidates values (seed+(used+1)*7919))
  walk _ used _ [] = (Nothing,used)
  walk accept used values (v:vs) | used >= attempts = (Nothing,used)
                                | not (accept (values++[v])) = walk accept (used+1) values vs
                                | otherwise = case search (used+1) (values++[v]) of
                                    (Just result,next) -> (Just result,next)
                                    (Nothing,next) -> walk accept next values vs

contract :: String -> Bool -> Scalar -> Scalar
contract context condition result = if condition then result else error context

refinedCase :: [Domain] -> Int -> Int -> Int -> ([Scalar] -> IO ()) -> String -> IO ()
refinedCase domains seed attempts shrinks check context = do
  let values = either (error . ((context ++ ": ") ++)) id (generateTuple domains seed attempts [])
  outcome <- capture check values
  case outcome of
    Nothing -> pure ()
    Just original -> do
      (best,_) <- foldM shrinkAt (values,shrinks) [0..length values-1]
      ioError (userError (context ++ ": " ++ original ++ "; refined counterexample=" ++ show best ++ "; seed=" ++ show seed))
  where
    capture f xs = (f xs >> pure Nothing) `catch` (\e -> pure (Just (displayException (e :: SomeException))))
    shrinkAt state@(best,_) i = let { Domain candidates _ = domains !! i
                                  ; additional = case best !! i of SInteger t n -> map (SInteger t) (0:signum n:takeWhile ((>1) . abs) (tail (iterate (`quot` 2) n))); _ -> []
                                  } in foldM (tryCandidate i) state (additional ++ candidates (take i best) 0)
    tryCandidate i state@(best,budget) candidate
      | budget <= 0 = pure state
      | complexity candidate >= complexity (best !! i) = pure (best,budget-1)
      | otherwise = do
          let prefix = take i best ++ [candidate]
              Domain _ accept = domains !! i
          if not (accept prefix) then pure (best,budget-1) else case generateTuple domains seed (min attempts 100) prefix of
            Left _ -> pure (best,budget-1)
            Right trial -> do failed <- capture check trial; pure ((case failed of Just _ -> trial; Nothing -> best),budget-1)

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
complexity v = let r = either error id (exactValue v) in abs (numerator r) + denominator r - 1

bool :: Bool -> Scalar
bool = SBool

-- Standalone contracts must observe their result even when the predicate is true.
forceScalar :: Scalar -> ()
forceScalar (SInteger _ n) = n `seq` ()
forceScalar (SBool b) = b `seq` ()
forceScalar (SDecimal c e) = c `seq` e `seq` ()
forceScalar (SRational n d) = n `seq` d `seq` ()
forceScalar (SFloat _ bs) = foldr seq () bs
forceScalar (SComplex _ r i) = forceScalar r `seq` forceScalar i
forceScalar (SSequence _ xs) = foldr seq () xs
forceScalar (SCharacter _ c) = c `seq` ()
forceScalar (SSymbol ident description) = foldr seq () ident `seq` foldr seq () description
forceScalar (SPresent _ (Just v)) = forceScalar v
forceScalar _ = ()
