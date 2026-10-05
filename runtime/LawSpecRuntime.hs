{-# LANGUAGE FlexibleInstances, TypeSynonymInstances, ScopedTypeVariables, MultiParamTypeClasses, FunctionalDependencies #-}
-- The portable scalar domain. No test framework or target runtime dependencies.
module LawSpecRuntime where

import Control.Exception (ErrorCall(..), Exception, SomeException(..), catch, displayException, evaluate, finally, fromException, throwIO, toException, try)
import Control.Concurrent (Chan, threadDelay, yield, forkIO, killThread, newChan, readChan, writeChan, newEmptyMVar, putMVar, takeMVar, tryPutMVar, MVar, readMVar, newMVar, modifyMVar)
import System.Timeout (timeout)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef', atomicModifyIORef')
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Unsafe (unsafePerformIO)
import System.Environment (lookupEnv)
import Control.Monad (foldM, forM, forM_, replicateM)
import Data.Unique (Unique, newUnique, hashUnique)
import Data.Dynamic (Dynamic, toDyn, fromDynamic, dynTypeRep)
import Data.Typeable (Typeable, typeRep, Proxy(..))
import Data.Char (ord, chr, isDigit)
import Data.Int
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Complex (Complex((:+)))
import Data.Word
import Data.Bits (bit, finiteBitSize, setBit, shiftR, testBit, xor)
import Data.Text (Text)
import qualified Data.Text as T
import Data.List (find, intercalate, nub, sort, sortBy, stripPrefix)
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
  | SList [Scalar] | SData String [Scalar]
  -- A handle: a value only adapters create, passed along unopened. Its
  -- label is the handle type's identity; equality is the handle's identity.
  | SHandle String Handle deriving (Eq, Show)

-- A handle's value is the adapter's own, kept with a Unique that is its
-- identity. LawSpec never builds, inspects or orders one.
data Handle = Handle Unique Dynamic
instance Eq Handle where
  Handle a _ == Handle b _ = a == b
instance Show Handle where
  show h = "<handle #" ++ show (handleNumber h) ++ ">"

-- | Wraps an adapter's value as a new handle, distinct from every other.
handle :: Typeable a => a -> IO Handle
handle value = do
  identity <- newUnique
  pure (Handle identity (toDyn value))

-- | The value a handle wraps, at the type it was made with.
fromHandle :: forall a. Typeable a => Handle -> a
fromHandle (Handle _ value) = case fromDynamic value of
  Just native -> native
  Nothing -> error ("handle holds a " ++ show (dynTypeRep value) ++
    ", not a " ++ show (typeRep (Proxy :: Proxy a)))

-- | A new handle around a native value, for codecs of bound handle types.
wrapHandle :: Typeable a => a -> Handle
wrapHandle value = unsafePerformIO (value `seq` handle value)
{-# NOINLINE wrapHandle #-}

handleNumber :: Handle -> Int
handleNumber (Handle identity _) = hashUnique identity
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
scalarName (SHandle t _) = t
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
  (SHandle _ x, SHandle _ y)
    | x == y -> Right EQ
    | otherwise -> Left "handles have no portable order"
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
complexity (SHandle _ _) = 0
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
forceScalar (SHandle t h) = foldr seq () t `seq` h `seq` ()
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

-- | runtimeGates: whether rate limits, breakers, bulkheads and caches apply.
-- The runtime generated tests install has them off: a workflow law calls the
-- workflow and its composition, which would see each other's state.
data WorkflowRuntime = WorkflowRuntime
  { runtimeClock :: Clock, runtimeRandom :: IORef Word64
  , runtimeTrace :: IORef [TraceEvent], runtimeState :: IORef [(String, Scalar)]
  , runtimeGates :: Bool, runtimeCache :: IORef [(String, [(Scalar, Scalar, Integer)])]
  -- A frame per running workflow: the undos of its completed stages.
  , runtimeFrames :: IORef [[(String, IO ())]]
  -- The running attempt's stage and hedge (delay, most).
  , runtimeHedge :: IORef (Maybe (String, Integer, Integer)) }

newWorkflowRuntime :: Clock -> Word64 -> IO WorkflowRuntime
newWorkflowRuntime clock seed = do
  random <- newIORef seed
  trace <- newIORef []
  state <- newIORef []
  cache <- newIORef []
  frames <- newIORef []
  hedge <- newIORef Nothing
  pure (WorkflowRuntime clock random trace state True cache frames hedge)

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
  writeIORef defaultWorkflow (Just runtime { runtimeGates = False })

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

-- | A stateful policy: gateStart gives its state, gateAdmit a Step of the
-- next state and a Gate (Admit, WaitFor or Reject), and gateFinish (when
-- set) the state after the call. gateWait is -2 to fail at once when not
-- admitted, -1 to wait without bound, or the most it waits.
data Gate = Gate
  { gateKind :: String, gateStart :: Integer -> Scalar, gateAdmit :: Scalar -> Integer -> Scalar
  , gateFinish :: Maybe (Scalar -> Integer -> Bool -> Scalar), gateWait :: Integer }

-- | policyKey names the stage's state; policyCache is how long a success is
-- reused (0 or less for none); policyWraps says failures are StageFailures.
data StagePolicy = StagePolicy
  { policyStage :: String, policyRetry :: Maybe Retry, policyTimeout :: Integer
  , policyKey :: String, policyGates :: [Gate], policyCache :: Integer, policyWraps :: Bool
  , policyCompensate :: Maybe (Scalar -> Scalar)
  -- (delay, most): when an attempt has not succeeded after delay, another
  -- starts beside it, up to most in all; the first success wins.
  , policyHedge :: Maybe (Integer, Integer) }

-- | A policy with only a stage name and retries, as built by hand.
retryPolicy :: String -> Maybe Retry -> StagePolicy
retryPolicy stage retry = StagePolicy stage retry (-1) stage [] (-1) False Nothing Nothing

-- | Runs a workflow whose stages compensate: when it fails, the undos of its
-- completed stages run, last first.
{-# NOINLINE runWorkflow #-}
runWorkflow :: SymbolContext -> (() -> Scalar) -> Scalar
runWorkflow symbols attempt = unsafePerformIO $ do
  runtime <- workflowRuntime symbols
  modifyIORef' (runtimeFrames runtime) ([] :)
  result <- evaluate (attempt ())
  frames <- readIORef (runtimeFrames runtime)
  let (frame, rest) = case frames of
        top : others -> (top, others)
        [] -> ([], [])
  writeIORef (runtimeFrames runtime) rest
  case result of
    SData "Either::Left" _ -> mapM_ (\(stage, undo) -> do
      modifyIORef' (runtimeTrace runtime) (++ [TraceEvent "compensate" stage 0 True])
      undo) frame
    _ -> pure ()
  pure result

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

stageFailurePrefix :: String
stageFailurePrefix = "lawspec.resilience::type::StageFailure::"

gatePrefix :: String
gatePrefix = "lawspec.resilience::type::Gate::"

-- | Admits the call (Nothing) or gives the failure to return instead.
passGate :: WorkflowRuntime -> StagePolicy -> Gate -> IO (Maybe String)
passGate runtime policy gate = go 0
  where
    key = policyKey policy ++ "/" ++ gateKind gate
    failure = case gateKind gate of
      "breaker" -> "CircuitOpen"
      "limit" -> "RateLimited"
      _ -> "Saturated"
    go waited = do
      now <- clockNow (runtimeClock runtime)
      states <- readIORef (runtimeState runtime)
      let state = maybe (gateStart gate now) id (lookup key states)
      step <- evaluate (gateAdmit gate state now)
      case step of
        SData _ [next, SData decision fields] -> do
          modifyIORef' (runtimeState runtime) (((key, next) :) . filter ((/= key) . fst))
          case (decision, fields) of
            _ | decision == gatePrefix ++ "Admit" -> pure Nothing
              | decision == gatePrefix ++ "Reject" || gateWait gate == -2 -> pure (Just failure)
            (_, [SInteger _ delay])
              | gateWait gate >= 0 && waited + delay > gateWait gate -> pure (Just failure)
              | otherwise -> do
                  modifyIORef' (runtimeTrace runtime) (++ [TraceEvent "wait" (policyStage policy) delay True])
                  clockSleep (runtimeClock runtime) delay
                  go (waited + delay)
            _ -> error "expected a Gate"
        _ -> error "expected a Step"

finishGate :: WorkflowRuntime -> StagePolicy -> Bool -> Gate -> IO ()
finishGate runtime policy succeeded gate = case gateFinish gate of
  Nothing -> pure ()
  Just finish -> do
    let key = policyKey policy ++ "/" ++ gateKind gate
    now <- clockNow (runtimeClock runtime)
    states <- readIORef (runtimeState runtime)
    case lookup key states of
      Just state -> do
        next <- evaluate (finish state now succeeded)
        modifyIORef' (runtimeState runtime) (((key, next) :) . filter ((/= key) . fst))
      Nothing -> pure ()

-- | Runs a stage's attempts under its policy; a Left is a failure. key is the
-- stage's input, for the cache.
{-# NOINLINE runStage #-}
runStage :: SymbolContext -> StagePolicy -> (() -> Scalar) -> Scalar -> Scalar
runStage symbols policy attempt key = unsafePerformIO $ do
  runtime <- workflowRuntime symbols
  let gates = if runtimeGates runtime then policyGates policy else []
      cacheKey = policyKey policy ++ "/cache"
      caching = policyCache policy > 0 && runtimeGates runtime
  now <- clockNow (runtimeClock runtime)
  entries <- maybe [] id . lookup cacheKey <$> readIORef (runtimeCache runtime)
  case [value | caching, (entry, value, expires) <- entries, now < expires, entry == key] of
    value : _ -> do
      modifyIORef' (runtimeTrace runtime) (++ [TraceEvent "cached" (policyStage policy) 0 True])
      pure value
    [] -> gated runtime gates [] caching cacheKey
  where
    gated runtime (gate : rest) passed caching cacheKey = do
      outcome <- passGate runtime policy gate
      case outcome of
        Just failure -> do
          mapM_ (finishGate runtime policy False) passed
          pure (SData "Either::Left" [SData (stageFailurePrefix ++ failure) []])
        Nothing -> gated runtime rest (passed ++ [gate]) caching cacheKey
    gated runtime [] passed caching cacheKey = do
      result <- attempts runtime 1 0
      let succeeded = case result of
            SData "Either::Left" _ -> False
            _ -> True
      mapM_ (finishGate runtime policy succeeded) passed
      case (result, policyCompensate policy) of
        (SData "Either::Right" [value], Just undo) ->
          -- The newest undo first, so a frame runs last-completed first.
          modifyIORef' (runtimeFrames runtime) $ \frames -> case frames of
            top : others -> ((policyStage policy, () <$ evaluate (undo value)) : top) : others
            [] -> []
        _ -> pure ()
      when' (caching && succeeded) $ do
        now <- clockNow (runtimeClock runtime)
        modifyIORef' (runtimeCache runtime) $ \caches ->
          let kept = [entry | entry@(entryKey, _, _) <- maybe [] id (lookup cacheKey caches), entryKey /= key]
          in (cacheKey, kept ++ [(key, result, now + policyCache policy)]) : filter ((/= cacheKey) . fst) caches
      pure result
    when' condition action = if condition then action else pure ()
    -- An attempt, evaluated in full under its stage's timeout (failing
    -- with TimedOut when it outlives it) and hedge. Under the runtime
    -- generated tests install (gates off), both are off.
    timed runtime
      | not (runtimeGates runtime) || (policyTimeout policy <= 0 && policyHedge policy == Nothing) = evaluate (attempt ())
      | otherwise = do
          outer <- readIORef (runtimeHedge runtime)
          writeIORef (runtimeHedge runtime) ((\(delay, most) -> (policyStage policy, delay, most)) <$> policyHedge policy)
          let full = do
                result <- evaluate (attempt ())
                result <$ evaluate (deepScalar result)
              limited = if policyTimeout policy > 0 then timeout (fromInteger (policyTimeout policy)) full else Just <$> full
          outcome <- limited `finally` writeIORef (runtimeHedge runtime) outer
          pure (maybe (SData "Either::Left" [SData (stageFailurePrefix ++ "TimedOut") []]) id outcome)
    event runtime kind number succeeded =
      modifyIORef' (runtimeTrace runtime) (++ [TraceEvent kind (policyStage policy) number succeeded])
    attempts runtime number previous = do
      event runtime "start" number False
      result <- timed runtime
      let failure = case result of
            SData "Either::Left" [value] -> Just value
            _ -> Nothing
      event runtime "finish" number (failure == Nothing)
      -- Only the step's own failures and timeouts are retried.
      let retried = case failure of
            Just value | policyWraps policy -> case value of
              SData tag [inner] | tag == stageFailurePrefix ++ "StepFailed" -> Just inner
              SData tag [] | tag == stageFailurePrefix ++ "TimedOut" -> Just value
              _ -> Nothing
            other -> other
      case (retried, policyRetry policy) of
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
                  attempts runtime next delay
        _ -> pure result

-- | An asynchronous step's logical result: start runs the step and convert
-- turns its native result into a logical value. Under a hedge, attempts run
-- on threads of their own; the first success wins.
{-# NOINLINE awaitStep #-}
awaitStep :: SymbolContext -> IO a -> (a -> Scalar) -> Scalar
awaitStep symbols start convert = unsafePerformIO $ do
  runtime <- workflowRuntime symbols
  hedge <- readIORef (runtimeHedge runtime)
  case hedge of
    Nothing -> convert <$> start
    Just (stage, delay, most) -> do
      results <- newChan
      threads <- newIORef []
      let launch number = do
            if number > 1 then modifyIORef' (runtimeTrace runtime) (++ [TraceEvent "hedge" stage number True]) else pure ()
            thread <- forkIO $ do
              outcome <- try (start >>= \native -> let value = convert native in value <$ evaluate (deepScalar value))
              writeChan results (outcome :: Either SomeException Scalar)
            modifyIORef' threads (thread :)
          loop started pending = do
            outcome <- if started < most then timeout (fromInteger delay) (readChan results) else Just <$> readChan results
            case outcome of
              Nothing -> launch (started + 1) >> loop (started + 1) (pending + 1)
              Just (Left failure) -> throwIO failure
              Just (Right value@(SData "Either::Left" _))
                | pending > (1 :: Integer) -> loop started (pending - 1)
                | started >= most -> pure value
                | otherwise -> launch (started + 1) >> loop (started + 1) 1
              Just (Right value) -> pure value
      (launch 1 >> loop 1 1) `finally` (readIORef threads >>= mapM_ killThread)

-- | Evaluates a value in full.
deepScalar :: Scalar -> ()
deepScalar value = case value of
  SComplex _ a b -> deepScalar a `seq` deepScalar b
  SPresent _ (Just inner) -> deepScalar inner
  SList items -> foldr (seq . deepScalar) () items
  SData tag fields -> length tag `seq` foldr (seq . deepScalar) () fields
  SHandle t h -> length t `seq` h `seq` ()
  other -> other `seq` ()

-- | A logical Duration of whole microseconds.
durationScalar :: Integer -> Scalar
durationScalar micros = SData "lawspec.time::type::Duration::Duration" [SInteger "Integer" micros]

-- | A RetryDecision's delay, or Nothing to stop.
retryDecision :: Scalar -> Maybe Integer
retryDecision decision = case decision of
  SData "lawspec.time::type::RetryDecision::RetryAfter" [SData _ [SInteger _ micros]] -> Just micros
  _ -> Nothing


-- Portable generation for stateful models. A type descriptor is an
-- s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
-- (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
-- (ref NAME) for a data type declared in the model's table. Every target
-- generates, shrinks and renders the same values for the same seed.

-- | A descriptor form: a list, an integer, a symbol or string, or _.
data Descriptor = DescList [Descriptor] | DescInteger Integer | DescAtom String | DescNone
  deriving (Eq, Show)

-- | Parses s-expressions: lists, integers, strings, symbols and _.
readDescriptor :: String -> [Descriptor]
readDescriptor = forms . skipBlank where
  skipBlank = dropWhile (`elem` " \t\r\n")
  forms "" = []
  forms text = let (form, rest) = item text in form : forms (skipBlank rest)
  item ('(' : rest) = list [] (skipBlank rest)
  item ('"' : rest) = quoted [] rest
  item text =
    let (atom, rest) = break (`elem` " \t\r\n()") text
        digits = dropWhile (== '-') atom
    in (if atom == "_" then DescNone
        else if not (null digits) && all isDigit digits
          then DescInteger (read (if take 1 atom == "-" then '-' : digits else digits))
          else DescAtom atom, rest)
  list acc (')' : rest) = (DescList (reverse acc), rest)
  list acc text = let (form, rest) = item text in list (form : acc) (skipBlank rest)
  quoted acc ('"' : rest) = (DescAtom (reverse acc), rest)
  quoted acc ('\\' : c : rest) = quoted (c : acc) rest
  quoted acc (c : rest) = quoted (c : acc) rest
  quoted _ [] = error "unterminated descriptor string"

-- | A descriptor atom's text.
descriptorName :: Descriptor -> String
descriptorName (DescAtom s) = s
descriptorName (DescInteger n) = show n
descriptorName DescNone = "None"
descriptorName (DescList _) = error "descriptor name expected"

-- | The data types of a descriptor text, by name.
type DataTable = [(String, Descriptor)]

-- | SplitMix64 draws threaded through a generation.
newtype Draw a = Draw { runDraw :: Word64 -> (a, Word64) }
instance Functor Draw where
  fmap f (Draw g) = Draw (\s -> let (a, s') = g s in (f a, s'))
instance Applicative Draw where
  pure a = Draw (\s -> (a, s))
  Draw f <*> Draw g = Draw (\s -> let (h, s1) = f s; (a, s2) = g s1 in (h a, s2))
instance Monad Draw where
  Draw g >>= k = Draw (\s -> let (a, s1) = g s in runDraw (k a) s1)

-- | Uniform in [0, bound); 0, with no draw, when bound is 0.
drawBelow :: Integer -> Draw Integer
drawBelow bound
  | bound <= 0 = pure 0
  | otherwise = Draw (\s -> let (value, next) = splitMix64 s in (toInteger value `mod` bound, next))

resolveDescriptor :: DataTable -> Descriptor -> Descriptor
resolveDescriptor table (DescList [DescAtom "ref", name]) =
  case lookup (descriptorName name) (reverse table) of
    Just d -> d
    Nothing -> error ("unknown data type " ++ descriptorName name)
resolveDescriptor _ d = d

unboundedRange :: Integer
unboundedRange = 1000000

-- | An integer's range: a missing bound is 1,000,000 from zero, or
-- 2,000,000 from the other bound when that is beyond it.
descriptorBounds :: Descriptor -> (Integer, Integer)
descriptorBounds (DescList (_ : _ : lo : hi : _)) = case (lo, hi) of
  (DescNone, DescNone) -> (negate unboundedRange, unboundedRange)
  (DescNone, DescInteger h) -> (min (negate unboundedRange) (h - 2 * unboundedRange), h)
  (DescInteger l, DescNone) -> (l, max unboundedRange (l + 2 * unboundedRange))
  (DescInteger l, DescInteger h) -> (l, h)
  _ -> error "invalid integer bounds"
descriptorBounds d = error ("invalid integer descriptor " ++ show d)

-- | The constructors of a data descriptor.
constructorsOf :: Descriptor -> [Descriptor]
constructorsOf (DescList (_ : _ : ctors)) = ctors
constructorsOf d = error ("invalid data descriptor " ++ show d)

-- | A constructor's tag and field descriptors.
constructorParts :: Descriptor -> (String, [Descriptor])
constructorParts (DescList (_ : tag : fields)) = (descriptorName tag, fields)
constructorParts d = error ("invalid constructor descriptor " ++ show d)

-- | The constructors whose fields mention no data type.
baseConstructors :: Descriptor -> [Descriptor]
baseConstructors d =
  let ctors = constructorsOf d
      found = [c | c <- ctors, not (any mentionsData (snd (constructorParts c)))]
  in if null found then ctors else found

mentionsData :: Descriptor -> Bool
mentionsData (DescList (kind : rest)) = kind `elem` [DescAtom "ref", DescAtom "data"] || any mentionsData rest
mentionsData _ = False

descriptorKind :: Descriptor -> String
descriptorKind (DescList (DescAtom kind : _)) = kind
descriptorKind d = error ("unknown descriptor " ++ show d)

descriptorArgument :: Int -> Descriptor -> Descriptor
descriptorArgument i (DescList xs) | i < length xs = xs !! i
descriptorArgument _ d = error ("invalid descriptor " ++ show d)

generateValue :: DataTable -> Descriptor -> Integer -> Draw Scalar
generateValue table d0 size = case descriptorKind d of
  "int" -> do
    let (lo, hi) = descriptorBounds d
    special <- drawBelow 10
    if special < 2
      then do
        i <- drawBelow 4
        pure (SInteger t ([lo, hi, min (max 0 lo) hi, min (max 1 lo) hi] !! fromInteger i))
      else SInteger t . (lo +) <$> drawBelow (hi - lo + 1)
  "bool" -> SBool . (== 1) <$> drawBelow 2
  "text" -> do
    n <- drawBelow (size + 1)
    SSequence "Text" <$> replicateM (fromInteger n) ((fromInteger . (32 +)) <$> drawBelow 95)
  "unit" -> pure (SAbsent "Unit")
  "list" -> do
    n <- drawBelow (size + 1)
    SList <$> replicateM (fromInteger n) (generateValue table (arg 1) size)
  "maybe" -> do
    r <- drawBelow 4
    if r == 0 then pure (SData "Maybe::Nothing" [])
      else (\v -> SData "Maybe::Just" [v]) <$> generateValue table (arg 1) size
  "either" -> do
    r <- drawBelow 2
    if r == 0 then (\v -> SData "Either::Left" [v]) <$> generateValue table (arg 1) size
      else (\v -> SData "Either::Right" [v]) <$> generateValue table (arg 2) size
  "data" -> do
    let choices = if size <= 0 then baseConstructors d else constructorsOf d
    i <- drawBelow (toInteger (length choices))
    let (tag, fields) = constructorParts (choices !! fromInteger i)
    SData tag <$> mapM (\f -> generateValue table f (max (size - 1) 0)) fields
  _ -> error ("unknown descriptor " ++ show d)
  where d = resolveDescriptor table d0
        t = descriptorName (arg 1)
        arg i = descriptorArgument i d

minimalValue :: DataTable -> Descriptor -> Scalar
minimalValue table d0 = case descriptorKind d of
  "int" -> let (lo, hi) = descriptorBounds d in SInteger (descriptorName (arg 1)) (min (max 0 lo) hi)
  "bool" -> SBool False
  "text" -> SSequence "Text" []
  "unit" -> SAbsent "Unit"
  "list" -> SList []
  "maybe" -> SData "Maybe::Nothing" []
  "either" -> SData "Either::Left" [minimalValue table (arg 1)]
  _ -> case baseConstructors d of
    ctor : _ -> let (tag, fields) = constructorParts ctor in SData tag (map (minimalValue table) fields)
    [] -> error ("data type without constructors " ++ show d)
  where d = resolveDescriptor table d0
        arg i = descriptorArgument i d

-- | Toward zero integer division.
towardZero :: Integer -> Integer -> Integer
towardZero n divisor = let q = abs n `div` divisor in if n >= 0 then q else negate q

-- | The empty sequence, the first half, then each with one item removed.
halfAndRemovals :: [a] -> [[a]]
halfAndRemovals xs = [] : take (length xs `div` 2) xs : [take i xs ++ drop (i + 1) xs | i <- [0 .. length xs - 1]]

-- | Smaller candidates for a value, most aggressive first.
shrinkValue :: DataTable -> Descriptor -> Scalar -> [Scalar]
shrinkValue table d0 v = uniqueRendered $ case (descriptorKind d, v) of
  ("int", SInteger t n) -> case minimalValue table d of
    SInteger _ target | n /= target ->
      map (SInteger t) [target, n - towardZero (n - target) 2, n - (if n > target then 1 else -1)]
    _ -> []
  ("bool", SBool True) -> [SBool False]
  ("text", SSequence t xs) | not (null xs) -> map (SSequence t) (halfAndRemovals xs)
  ("list", SList xs) | not (null xs) ->
    map SList (halfAndRemovals xs)
      ++ concat [[SList (take i xs ++ [c] ++ drop (i + 1) xs) | c <- shrinkValue table (arg 1) x]
                | (i, x) <- zip [0 ..] xs]
  ("maybe", SData "Maybe::Just" [x]) ->
    SData "Maybe::Nothing" [] : [SData "Maybe::Just" [c] | c <- shrinkValue table (arg 1) x]
  ("either", SData tag [x]) ->
    [SData tag [c] | c <- shrinkValue table (arg (if tag == "Either::Left" then 1 else 2)) x]
  ("data", SData tag fields) ->
    let ctorFields = case find ((== tag) . fst) (map constructorParts (constructorsOf d)) of
          Just (_, fs) -> fs
          Nothing -> error ("unknown constructor " ++ tag)
        pairs = zip fields ctorFields
    in minimalValue table d
         -- A field of the same type is a smaller value of it.
         : [f | (f, fd) <- pairs, fd == DescList [DescAtom "ref", arg 1]]
         ++ concat [[SData tag (take i fields ++ [c] ++ drop (i + 1) fields) | c <- shrinkValue table fd field]
                   | (i, (field, fd)) <- zip [0 ..] pairs]
  _ -> []
  where d = resolveDescriptor table d0
        arg i = descriptorArgument i d
        uniqueRendered candidates = go [renderValue v] candidates
        go _ [] = []
        go seen (c : cs) = let r = renderValue c in
          if r `elem` seen then go seen cs else c : go (r : seen) cs

-- | A value's canonical text, the same on every target.
renderValue :: Scalar -> String
renderValue value = case value of
  SBool b -> if b then "true" else "false"
  SInteger _ n -> show n
  SSequence _ xs -> '"' : concatMap escape (map chr xs) ++ "\""
  SAbsent _ -> "()"
  SList xs -> "[" ++ commas xs ++ "]"
  SData tag fields ->
    let name = T.unpack (last (T.splitOn (T.pack "::") (T.pack tag)))
    in if null fields then name else name ++ "(" ++ commas fields ++ ")"
  SHandle t h -> T.unpack (last (T.splitOn (T.pack "::") (T.pack t))) ++ "#" ++ show (handleNumber h)
  other -> show other
  where escape c = if c == '\\' || c == '"' then ['\\', c] else [c]
        commas xs = foldr1' (map renderValue xs)
        foldr1' [] = ""
        foldr1' parts = foldr1 (\a b -> a ++ ", " ++ b) parts

-- | A descriptor text's data types and its last form, the one generated.
valuesFrom :: String -> (DataTable, Descriptor)
valuesFrom text =
  let forms = readDescriptor text
      table = [(descriptorName name, f) | f@(DescList (DescAtom "data" : name : _)) <- forms]
  in (table, last forms)

-- | count values generated from one SplitMix64 seed, rendered.
generatedValues :: String -> Word64 -> Integer -> Integer -> [String]
generatedValues text seed size count =
  let (table, d) = valuesFrom text
  in map renderValue (fst (runDraw (replicateM (fromInteger count) (generateValue table d size)) seed))

-- | The shrink candidates of the first value generated, rendered.
shrunkValues :: String -> Word64 -> Integer -> [String]
shrunkValues text seed size =
  let (table, d) = valuesFrom text
      first = fst (runDraw (generateValue table d size) seed)
  in map renderValue (shrinkValue table d first)

-- Stateful models. A model's spec (see LawSpec.MachineSpec) lists its data
-- types, start and commands; the callbacks beside it are the generated
-- definitions that call the adapters, the references over the model state,
-- preconditions, the abstraction and invariants, each taking symbols first.
-- A run is generated by simulating the pure model, so every command in it is
-- allowed by typestate, its precondition and its reference; it is then
-- executed against the adapters and every result, abstracted state and
-- invariant is checked. A failing run is shrunk by dropping commands and
-- shrinking arguments, replaying the model to keep each candidate valid.
-- Draws, shrink candidates and messages match every other target.

-- | A generated definition: symbols, then its arguments in order.
type ModelCallback = SymbolContext -> [Scalar] -> Either String Scalar

-- | A model: its spec, (start system, start model), each command's (system,
-- reference, precondition), the abstraction and the invariants, in the
-- spec's order.
data Model = Model
  { modelSpec :: String
  , modelStart :: (ModelCallback, ModelCallback)
  , modelCommands :: [(ModelCallback, ModelCallback, Maybe ModelCallback)]
  , modelAbstract :: Maybe ModelCallback
  , modelInvariants :: [ModelCallback]
  }

data ModelCommand = ModelCommand
  { mcName :: String
  , mcArguments :: [Descriptor]
  , mcState :: Int
  , mcUnit :: Bool
  , mcNeeds :: [(String, Integer)]
  , mcShifts :: [(String, Integer)]
  -- | The argument naming the key the command touches, for per-key checks.
  , mcKey :: Maybe Int
  , mcRun :: ModelCallback
  , mcReference :: ModelCallback
  , mcWhen :: Maybe ModelCallback
  -- | An actor's restart: never a generated step; injected crashes run it.
  , mcRestart :: Bool
  }

-- | An injected crash of an actor model, given the run's start arguments:
-- restarting the system's actor, and the model state after the restart.
data CrashStep = CrashStep
  { crashSystem :: [Scalar] -> SymbolContext -> Scalar -> IO ()
  , crashModel :: [Scalar] -> SymbolContext -> Scalar -> IO Scalar
  }

data ModelPlan = ModelPlan
  { planName :: String
  , planShared :: Bool
  , planTable :: DataTable
  , planStartIndices :: [Integer]
  , planStartArguments :: [Descriptor]
  , planStartRun :: ModelCallback
  , planStartModel :: ModelCallback
  , planCommands :: [ModelCommand]
  , planAbstract :: Maybe ModelCallback
  , planInvariants :: [(String, ModelCallback)]
  , planPerKey :: Bool
  -- | An actor model's crash step, numbered after the commands.
  , planCrash :: Maybe CrashStep
  }

-- | Start arguments, then each step's command index and arguments.
type ModelRun = ([Scalar], [(Int, [Scalar])])

-- | A command the model does not allow here, or a callback's failure.
data ModelStop = ModelInvalid | ModelRaised String deriving Show
instance Exception ModelStop

modelPlan :: Model -> ModelPlan
modelPlan model = asActor $ ModelPlan
  { planName = name
  , planShared = kind == "shared"
  , planTable = [(descriptorName n, f) | f@(DescList (DescAtom "data" : n : _)) <- forms]
  , planStartIndices = integers (field "indices" startFields)
  , planStartArguments = field "arguments" startFields
  , planStartRun = fst (modelStart model)
  , planStartModel = snd (modelStart model)
  , planCommands = filter (not . mcRestart) allCommands
  , planAbstract = modelAbstract model
  , planInvariants = zip kinds (modelInvariants model)
  , planPerKey = not (null [() | DescList [DescAtom "perkey", DescAtom "true"] <- forms])
  , planCrash = Nothing
  }
  where
    allCommands = zipWith command [rest | DescList (DescAtom "command" : rest) <- forms] (modelCommands model)
    restart = find mcRestart allCommands
    -- An actor model's start and handlers run inside an actor; the
    -- abstraction and state invariants read its state between messages.
    actor = not (null [() | DescList [DescAtom "actor", DescAtom "true"] <- forms])
    asActor plan
      | not actor = plan
      | otherwise = plan
          { planStartRun = actorStartCallback (planStartRun plan)
          , planCrash = Just (actorCrashStep (planStartRun plan) (planStartModel plan) restart)
          , planCommands = [c { mcRun = actorCommandCallback (mcUnit c) (mcRun c) } | c <- planCommands plan]
          , planAbstract = fmap actorStateCallback (planAbstract plan)
          , planInvariants = [(k, if k == "model" then p else actorStateCallback p) | (k, p) <- planInvariants plan] }
    forms = readDescriptor (modelSpec model)
    (name, kind) = case forms of
      DescList (_ : n : k : _) : _ -> (descriptorName n, descriptorName k)
      _ -> error "invalid model spec"
    startFields = case [rest | DescList (DescAtom "start" : rest) <- forms] of
      rest : _ -> rest
      [] -> error "model spec without a start"
    kinds = case [map descriptorName rest | DescList (DescAtom "invariants" : rest) <- forms] of
      ks : _ -> ks
      [] -> []
    field key fs = case [rest | DescList (k : rest) <- reverse fs, k == DescAtom key] of
      rest : _ -> rest
      [] -> []
    integers = map (\d -> case d of DescInteger k -> k; _ -> error "integer expected in model spec")
    pair d = case d of
      DescList [DescAtom k, DescInteger v] -> (k, v)
      _ -> error ("invalid model typestate " ++ show d)
    command (nameForm : fs) (run, reference, precondition) = ModelCommand
      { mcName = descriptorName nameForm
      , mcArguments = field "arguments" fs
      , mcState = case field "state" fs of
          [DescInteger p] -> fromInteger p
          _ -> error "invalid command state position"
      , mcUnit = field "unit" fs == [DescAtom "true"]
      , mcNeeds = map pair (field "needs" fs)
      , mcShifts = map pair (field "shifts" fs)
      , mcKey = case field "key" fs of
          [DescInteger k] -> Just (fromInteger k)
          _ -> Nothing
      , mcRun = run
      , mcReference = reference
      , mcWhen = precondition
      , mcRestart = field "restart" fs == [DescAtom "true"]
      }
    command [] _ = error "invalid command form"

-- | Whether a step index is an actor's injected crash.
isCrashStep :: ModelPlan -> Int -> Bool
isCrashStep plan index = index >= length (planCommands plan)

stepName :: ModelPlan -> Int -> String
stepName plan index = if isCrashStep plan index then "crash" else mcName (planCommands plan !! index)

stepArguments :: ModelPlan -> Int -> [Descriptor]
stepArguments plan index = if isCrashStep plan index then [] else mcArguments (planCommands plan !! index)

-- | The model state after an injected crash, or ModelInvalid.
crashModelState :: ModelPlan -> [Scalar] -> SymbolContext -> Scalar -> IO Scalar
crashModelState plan startArgs symbols state = case planCrash plan of
  Just crash -> crashModel crash startArgs symbols state
  Nothing -> throwIO ModelInvalid

admits :: ModelCommand -> [Integer] -> Bool
admits command indices = and (zipWith needs (mcNeeds command) indices)
  where needs (kind, k) i = if kind == "atleast" then i >= k else i == k

shifted :: ModelCommand -> [Integer] -> [Integer]
shifted command = zipWith shift (mcShifts command)
  where shift (kind, d) i = if kind == "by" then i + d else d

-- | An exception's message, without the location or context GHC adds.
exceptionText :: SomeException -> String
exceptionText e = case fromException e of
  Just (ErrorCall message) -> message
  Nothing -> case e of SomeException inner -> displayException inner

-- | Calls a callback, evaluating its result in full; a thrown exception is
-- a Left like any other failure.
callModel :: ModelCallback -> SymbolContext -> [Scalar] -> IO (Either String Scalar)
callModel f symbols args = do
  outcome <- try (evaluate (case f symbols args of
    Left message -> length message `seq` Left message
    Right value -> deepScalar value `seq` Right value))
  pure (either (Left . exceptionText) id outcome)

-- | A callback's result, or ModelRaised.
callOrRaise :: ModelCallback -> SymbolContext -> [Scalar] -> IO Scalar
callOrRaise f symbols args = callModel f symbols args >>= either (throwIO . ModelRaised) pure

productField :: Bool -> Scalar -> Scalar
productField lastField value = case value of
  SData _ fields@(first : _) -> if lastField then last fields else first
  _ -> error ("expected a product, got " ++ renderValue value)

-- | The model state and result after a command, or ModelInvalid.
stepModel :: ModelCommand -> SymbolContext -> [Scalar] -> Scalar -> IO (Scalar, Scalar)
stepModel command symbols args state = do
  case mcWhen command of
    Nothing -> pure ()
    Just precondition -> do
      allowed <- callModel precondition symbols [state]
      case allowed of
        Right (SBool True) -> pure ()
        _ -> throwIO ModelInvalid
  out <- callModel (mcReference command) symbols (args ++ [state])
  case out of
    Left _ -> throwIO ModelInvalid
    Right value
      | mcUnit command -> pure (value, SAbsent "Unit")
      | otherwise -> case value of
          SData _ (result : next : _) -> pure (next, result)
          _ -> throwIO (ErrorCall ("expected a product, got " ++ renderValue value))

-- | Whether the model allows every step of a run.
simulateRun :: ModelPlan -> ModelRun -> IO Bool
simulateRun plan run = do
  symbols <- newSymbolContext
  maybe False (const True) <$> simulateFinal plan symbols run

-- | The model state after a run, or Nothing when the model does not allow
-- every step of it.
simulateFinal :: ModelPlan -> SymbolContext -> ModelRun -> IO (Maybe Scalar)
simulateFinal plan symbols (startArgs, steps) = do
  started <- callModel (planStartModel plan) symbols startArgs
  case started of
    Left _ -> pure Nothing
    Right state0 -> do
      let go state _ [] = pure (Just state)
          go state indices ((index, _) : rest) | isCrashStep plan index = do
            stepped <- try (crashModelState plan startArgs symbols state)
            case stepped of
              Left (_ :: ModelStop) -> pure Nothing
              Right next -> go next indices rest
          go state indices ((index, args) : rest) = do
            let command = planCommands plan !! index
            if not (admits command indices) then pure Nothing else do
              stepped <- try (stepModel command symbols args state)
              case stepped of
                Left ModelInvalid -> pure Nothing
                Left (ModelRaised _) -> pure Nothing
                Right (next, _) -> go next (shifted command indices) rest
      go state0 (planStartIndices plan) steps

drawIO :: IORef Word64 -> Draw a -> IO a
drawIO source draw = do
  seed <- readIORef source
  let (value, next) = runDraw draw seed
  writeIORef source next
  pure value

generateRun :: ModelPlan -> IORef Word64 -> Integer -> Integer -> IO ModelRun
generateRun plan = generateRunWith False plan

-- | A generated run; with crashes, one step in eight of an actor's run is
-- an injected crash (drawn right after the command, as on every target).
generateRunWith :: Bool -> ModelPlan -> IORef Word64 -> Integer -> Integer -> IO ModelRun
generateRunWith crashes plan source len size = do
  symbols <- newSymbolContext
  startArgs <- mapM (\d -> drawIO source (generateValue (planTable plan) d size)) (planStartArguments plan)
  started <- callModel (planStartModel plan) symbols startArgs
  case started of
    Left _ -> pure (startArgs, [])
    Right state0 -> do
      let go 0 _ _ acc = pure (reverse acc)
          go n state indices acc = do
            let allowed = [i | (i, c) <- zip [0 ..] (planCommands plan), admits c indices]
            if null allowed then pure (reverse acc) else do
              pick <- drawIO source (drawBelow (toInteger (length allowed)))
              crash <- case planCrash plan of
                Just _ | crashes -> (== 0) <$> drawIO source (drawBelow 8)
                _ -> pure False
              let index = allowed !! fromInteger pick
                  command = planCommands plan !! index
              if crash then do
                stepped <- try (crashModelState plan startArgs symbols state)
                case stepped of
                  Left (_ :: ModelStop) -> go (n - 1) state indices acc
                  Right next -> go (n - 1) next indices ((length (planCommands plan), []) : acc)
              else do
               args <- mapM (\d -> drawIO source (generateValue (planTable plan) d size)) (mcArguments command)
               stepped <- try (stepModel command symbols args state)
               case stepped of
                 Left ModelInvalid -> go (n - 1) state indices acc
                 Left (ModelRaised _) -> go (n - 1) state indices acc
                 Right (next, _) -> go (n - 1) next (shifted command indices) ((index, args) : acc)
      steps <- go len state0 (planStartIndices plan) []
      pure (startArgs, steps)

-- | Nothing when the system agrees with the model along the run; otherwise
-- the failing step's number and what went wrong.
executeRun :: ModelPlan -> ModelRun -> IO (Maybe (Int, String))
executeRun plan (startArgs, steps) = do
  symbols <- newSymbolContext
  stepRef <- newIORef 0
  outcome <- try (do
    state0 <- callOrRaise (planStartRun plan) symbols startArgs
    expected0 <- callOrRaise (planStartModel plan) symbols startArgs
    failure0 <- checkModelState plan symbols state0 expected0
    case failure0 of
      Just failure -> pure (Just failure)
      Nothing -> do
        let go _ _ [] = pure Nothing
            go state expected ((index, _) : rest) | isCrashStep plan index = do
              modifyIORef' stepRef (+ 1)
              forM_ (planCrash plan) (\crash -> crashSystem crash startArgs symbols state)
              expected' <- crashModelState plan startArgs symbols expected
              failure <- checkModelState plan symbols state expected'
              case failure of
                Just _ -> pure failure
                Nothing -> go state expected' rest
            go state expected ((index, args) : rest) = do
              modifyIORef' stepRef (+ 1)
              let command = planCommands plan !! index
                  position = mcState command
              out <- callOrRaise (mcRun command) symbols (take position args ++ [state] ++ drop position args)
              let (result, state') = if planShared plan then (out, state)
                    else (if mcUnit command then SAbsent "Unit" else productField False out, productField True out)
              _ <- evaluate (deepScalar result `seq` deepScalar state')
              (expected', wanted) <- stepModel command symbols args expected
              order <- if mcUnit command then pure EQ
                else either (throwIO . ModelRaised) pure (compareValues result wanted)
              if order /= EQ
                then pure (Just ("returned " ++ renderValue result ++ "; the model returns " ++ renderValue wanted))
                else do
                  failure <- checkModelState plan symbols state' expected'
                  case failure of
                    Just _ -> pure failure
                    Nothing -> go state' expected' rest
        go state0 expected0 steps)
  step <- readIORef stepRef
  pure $ case outcome of
    Right Nothing -> Nothing
    Right (Just message) -> Just (step, message)
    Left e -> Just (step, case fromException e of
      Just ModelInvalid -> "the model does not allow this step"
      Just (ModelRaised message) -> "raised error: " ++ message
      Nothing -> "raised error: " ++ exceptionText e)

checkModelState :: ModelPlan -> SymbolContext -> Scalar -> Scalar -> IO (Maybe String)
checkModelState plan symbols state expected = do
  abstracted <- case planAbstract plan of
    Nothing -> pure Nothing
    Just abstract -> do
      actual <- callOrRaise abstract symbols [state]
      order <- either (throwIO . ModelRaised) pure (compareValues actual expected)
      pure (if order /= EQ
        then Just ("the state is " ++ renderValue actual ++ "; the model is " ++ renderValue expected)
        else Nothing)
  case abstracted of
    Just _ -> pure abstracted
    Nothing -> invariants (planInvariants plan)
  where
    invariants [] = pure Nothing
    invariants ((kind, invariant) : rest) = do
      holds <- callOrRaise invariant symbols [if kind == "model" then expected else state]
      case holds of
        SBool True -> invariants rest
        SBool False -> pure (Just ("an invariant on the " ++ kind ++ " fails"))
        _ -> throwIO (ModelRaised "Bool required")

-- | Smaller runs: dropping halves, quarters and so on of the steps, then
-- shrinking each step's arguments, then the start's.
runCandidates :: ModelPlan -> ModelRun -> [ModelRun]
runCandidates plan (startArgs, steps) =
  [ (startArgs, take begin steps ++ drop (begin + size) steps)
  | size <- takeWhile (>= 1) (iterate (`div` 2) (n `div` 2)), begin <- [0, size .. n - 1] ]
  ++ [ (startArgs, take k steps ++ [(index, replace j c args)] ++ drop (k + 1) steps)
     | (k, (index, args)) <- zip [0 ..] steps
     , (j, (d, arg)) <- zip [0 ..] (zip (stepArguments plan index) args)
     , c <- shrinkValue (planTable plan) d arg ]
  ++ [ (replace j c startArgs, steps)
     | (j, (d, arg)) <- zip [0 ..] (zip (planStartArguments plan) startArgs)
     , c <- shrinkValue (planTable plan) d arg ]
  where n = length steps
        replace j c xs = take j xs ++ [c] ++ drop (j + 1) xs

shrinkRun :: ModelPlan -> ModelRun -> (Int, String) -> Int -> IO (ModelRun, (Int, String))
shrinkRun plan run failure budget
  | budget <= 0 = pure (run, failure)
  | otherwise = go (runCandidates plan run) budget
  where
    go [] _ = pure (run, failure)
    go (candidate : rest) b = do
      let b' = b - 1
      if b' <= 0 then pure (run, failure) else do
        valid <- simulateRun plan candidate
        if not valid then go rest b' else do
          found <- executeRun plan candidate
          case found of
            Just failure' -> shrinkRun plan candidate failure' b'
            Nothing -> go rest b'

describeRun :: ModelPlan -> ModelRun -> String
describeRun plan (startArgs, steps) =
  let call name args = name ++ "(" ++ joinComma (map renderValue args) ++ ")"
      joinComma [] = ""
      joinComma texts = foldr1 (\a b -> a ++ ", " ++ b) texts
      parts = call "start" startArgs : [call (stepName plan i) args | (i, args) <- steps]
  in foldr1 (\a b -> a ++ "; " ++ b) parts

-- | Checks the system against its model on generated runs: Nothing, or the
-- failure naming the shortest failing run found. 100 cases of up to 20
-- steps, 2000 shrinks, seeded from LAWSPEC_SEED or 0.
checkModel :: Model -> IO (Maybe String)
checkModel = checkModelWith 100 20 2000 Nothing

-- | checkModel with the number of cases, the longest run, the shrink
-- budget and the seed (Nothing: LAWSPEC_SEED, else 0).
checkModelWith :: Int -> Int -> Int -> Maybe Word64 -> Model -> IO (Maybe String)
checkModelWith cases maxLength maxShrinks seedOverride model = do
  seed <- case seedOverride of
    Just s -> pure s
    Nothing -> maybe 0 (fromInteger . read) <$> lookupEnv "LAWSPEC_SEED"
  source <- newIORef seed
  let plan = modelPlan model
      loop c
        | c >= cases = pure Nothing
        | otherwise = do
            len <- drawIO source (drawBelow (toInteger maxLength + 1))
            run <- generateRunWith True plan source len (1 + toInteger (c `mod` 8))
            failure <- executeRun plan run
            case failure of
              Nothing -> loop (c + 1)
              Just found -> do
                (run', (step, message)) <- shrinkRun plan run found maxShrinks
                pure (Just ("model " ++ planName plan ++ " fails at step " ++ show step ++ " of "
                  ++ describeRun plan run' ++ ": " ++ message))
  loop 0

-- Parallel runs of a shared model. A case is a sequential prefix and one
-- branch per thread, generated so that the model allows every interleaving
-- of the branches (a search over each thread's position and the model state,
-- memoized). The system runs the branches at the same time, each call's start
-- and return recorded on one counter, with random yields and short sleeps
-- around calls to shake out rare schedules. The history must be
-- linearizable: some interleaving that keeps every call after those that
-- returned before it started must give every result the model gives and
-- leave the state it leaves (a Wing-Gong search, memoized on the same
-- positions and model state). Each case runs several times.

-- | A sequential prefix, then each thread's branch of steps.
type ParallelCase = (ModelRun, [[(Int, [Scalar])]])

-- | The default number of threads and the longest branch.
parallelThreads, parallelBranch :: Int
parallelThreads = 3
parallelBranch = 5

allM :: (a -> IO Bool) -> [a] -> IO Bool
allM _ [] = pure True
allM p (x : xs) = p x >>= \ok -> if ok then allM p xs else pure False

anyM :: (a -> IO Bool) -> [a] -> IO Bool
anyM _ [] = pure False
anyM p (x : xs) = p x >>= \ok -> if ok then pure True else anyM p xs

-- | Whether a search key was seen before; records it if not.
seenBefore :: IORef [([Int], String)] -> ([Int], String) -> IO Bool
seenBefore seen key = do
  keys <- readIORef seen
  if key `elem` keys then pure True else writeIORef seen (key : keys) >> pure False

-- | The positions with thread i one step further.
advanceAt :: Int -> [Int] -> [Int]
advanceAt i positions = [if j == i then k + 1 else k | (j, k) <- zip [0 ..] positions]

-- | Whether the model allows the prefix then every interleaving.
parallelAllowed :: ModelPlan -> ParallelCase -> IO Bool
parallelAllowed plan (prefix, branches) = do
  symbols <- newSymbolContext
  final <- simulateFinal plan symbols prefix
  case final of
    Nothing -> pure False
    Just state0 -> do
      seen <- newIORef []
      let visit positions state = do
            old <- seenBefore seen (positions, renderValue state)
            if old then pure True else allM (stepFrom positions state) (zip [0 ..] branches)
          stepFrom positions state (i, branch) = do
            let k = positions !! i
            if k >= length branch then pure True else do
              let (index, args) = branch !! k
              stepped <- try (stepModel (planCommands plan !! index) symbols args state)
              case stepped of
                Left ModelInvalid -> pure False
                Left (ModelRaised _) -> pure False
                Right (next, _) -> visit (advanceAt i positions) next
      visit (map (const 0) branches) state0

generateBranch :: ModelPlan -> IORef Word64 -> Scalar -> Integer -> Integer -> IO [(Int, [Scalar])]
generateBranch plan source state0 len size = do
  symbols <- newSymbolContext
  let go 0 _ acc = pure (reverse acc)
      go n state acc = do
        pick <- drawIO source (drawBelow (toInteger (length (planCommands plan))))
        let index = fromInteger pick
            command = planCommands plan !! index
        args <- mapM (\d -> drawIO source (generateValue (planTable plan) d size)) (mcArguments command)
        stepped <- try (stepModel command symbols args state)
        case stepped of
          Left ModelInvalid -> go (n - 1) state acc
          Left (ModelRaised _) -> go (n - 1) state acc
          Right (next, _) -> go (n - 1) next ((index, args) : acc)
  go len state0 []

generateParallel :: ModelPlan -> IORef Word64 -> Integer -> Int -> Int -> IO ParallelCase
generateParallel plan source size threads branchLength = do
  prefixLength <- drawIO source (drawBelow 4)
  prefix <- generateRun plan source prefixLength size
  symbols <- newSymbolContext
  final <- simulateFinal plan symbols prefix
  case final of
    Nothing -> pure (prefix, replicate threads [])
    Just state -> do
      branches <- forM [1 .. threads] $ \_ -> do
        n <- drawIO source (drawBelow (toInteger branchLength))
        generateBranch plan source state (1 + n) size
      -- Drop the last step of the longest branch (the first, among equals)
      -- until every interleaving is allowed.
      let trim bs = do
            allowed <- parallelAllowed plan (prefix, bs)
            if allowed then pure (prefix, bs) else do
              let longest = maximum (map length bs)
                  i = length (takeWhile ((/= longest) . length) bs)
              trim [if j == i then init b else b | (j, b) <- zip [0 :: Int ..] bs]
      trim branches

-- | Nothing, a yield, or a sleep of 10 or 100 microseconds.
perturb :: IORef Word64 -> IO ()
perturb source = do
  choice <- drawIO source (drawBelow 4)
  case choice of
    0 -> pure ()
    1 -> yield
    2 -> threadDelay 10
    _ -> threadDelay 100

branchName :: Int -> String
branchName i = [chr (ord 'A' + i)]

-- | Nothing when the history is linearizable; otherwise what went wrong.
executeParallel :: ModelPlan -> ParallelCase -> Word64 -> IO (Maybe String)
executeParallel plan (prefix@(startArgs, steps), branches) shake = do
  symbols <- newSymbolContext
  let withState command state args = take (mcState command) args ++ [state] ++ drop (mcState command) args
  prepared <- try (do
    state <- callOrRaise (planStartRun plan) symbols startArgs
    mapM_ (\(index, args) -> let command = planCommands plan !! index
      in callOrRaise (mcRun command) symbols (withState command state args)) steps
    pure state)
  case prepared of
    Left e -> pure (Just ("the prefix raised error: " ++ case fromException e of
      Just (ModelRaised message) -> message
      _ -> exceptionText e))
    Right state -> do
      clock <- newIORef (0 :: Int)
      errors <- newIORef []
      let tick = atomicModifyIORef' clock (\c -> (c + 1, c + 1))
          branch i steps' = do
            own <- newSymbolContext
            source <- newIORef (shake `xor` (fromIntegral (i + 1) * 0x9E3779B97F4A7C15))
            forM steps' $ \(index, args) -> do
              let command = planCommands plan !! index
              perturb source
              called <- tick
              -- callModel forces the result in full, so the effect happens here.
              out <- callModel (mcRun command) own (withState command state args)
              result <- case out of
                Left message -> do
                  atomicModifyIORef' errors (\es -> (es ++ [mcName command ++ " raised error: " ++ message], ()))
                  pure (SAbsent "Unit")
                Right value -> pure value
              returned <- tick
              perturb source
              pure (called, returned, result)
      dones <- forM (zip [0 :: Int ..] branches) $ \(i, steps') -> do
        done <- newEmptyMVar
        _ <- forkIO (try (branch i steps') >>= putMVar done)
        pure done
      outcomes <- mapM takeMVar dones
      raised <- readIORef errors
      case (raised, [e | Left e <- outcomes]) of
        (message : _, _) -> pure (Just message)
        ([], e : _) -> pure (Just ("raised error: " ++ exceptionText e))
        ([], []) -> do
          let history = [h | Right h <- outcomes]
          expectedFinal <- simulateFinal plan symbols prefix
          final <- case planAbstract plan of
            Nothing -> pure (Right Nothing)
            Just abstract -> fmap Just <$> callModel abstract symbols [state]
          case (expectedFinal, final) of
            (Nothing, _) -> pure (Just "the model does not allow this step")
            (_, Left message) -> pure (Just ("raised error: " ++ message))
            (Just expected, Right actual) -> do
              found <- linearizable plan symbols branches history expected actual state
              let observed = intercalate "; "
                    [ branchName i ++ ": " ++ mcName (planCommands plan !! fst (branches !! i !! k))
                      ++ "() returned " ++ renderValue result
                    | (i, h) <- zip [0 ..] history, (k, (_, _, result)) <- zip [0 ..] h ]
              pure (if found then Nothing
                else Just ("no order of the parallel calls agrees with the model (" ++ observed ++ ")"))

-- | Whether the history linearizes, with the final state and invariants the
-- model gives. For a set or map whose every call touches one key, each key's
-- calls are linearized separately (the keys are independent), one group
-- after another; otherwise all calls at once.
linearizable :: ModelPlan -> SymbolContext -> [[(Int, [Scalar])]] -> [[(Int, Int, Scalar)]]
             -> Scalar -> Maybe Scalar -> Scalar -> IO Bool
linearizable plan symbols branches history expected0 final state
  | not (planPerKey plan) = linearize plan symbols branches history expected0 finish
  | otherwise = groups keys expected0
  where
    finish modelState =
      if maybe False (\actual -> compareValues actual modelState /= Right EQ) final then pure False
      else allM (\(kind, invariant) -> do
        holds <- callModel invariant symbols [if kind == "model" then modelState else state]
        pure (case holds of Right (SBool True) -> True; _ -> False)) (planInvariants plan)
    keyOf (index, args) = case mcKey (planCommands plan !! index) of
      Just a -> renderValue (args !! a)
      Nothing -> error "per-key model command without a key"
    calls = [zip branch h | (branch, h) <- zip branches history]
    keys = sort (nub [keyOf step | branch <- branches, step <- branch])
    groups [] modelState = finish modelState
    groups (key : rest) modelState = do
      let parts = [[c | c@(step, _) <- branch, keyOf step == key] | branch <- calls]
      ends <- newIORef Nothing
      found <- linearize plan symbols (map (map fst) parts) (map (map snd) parts) modelState
        (\end -> writeIORef ends (Just end) >> pure True)
      if not found then pure False else do
        end <- readIORef ends
        maybe (pure False) (groups rest) end

-- | A Wing-Gong search: linearize, next, a call no pending call on another
-- thread returned before; memoized on positions and the model state. The
-- last argument judges each complete order's final model state.
linearize :: ModelPlan -> SymbolContext -> [[(Int, [Scalar])]] -> [[(Int, Int, Scalar)]]
              -> Scalar -> (Scalar -> IO Bool) -> IO Bool
linearize plan symbols branches history expected0 finish = do
  seen <- newIORef []
  let threads = length branches
      lengths = map length branches
      returnedAt j k = let (_, r, _) = history !! j !! k in r
      visit positions modelState = do
        old <- seenBefore seen (positions, renderValue modelState)
        if old then pure False
        else if and (zipWith (==) positions lengths) then finish modelState
        else anyM (next positions modelState) [0 .. threads - 1]
      next positions modelState i = do
        let k = positions !! i
        if k == lengths !! i then pure False else do
          let (called, _, result) = history !! i !! k
              blocked = or [ positions !! j < lengths !! j && returnedAt j (positions !! j) < called
                           | j <- [0 .. threads - 1], j /= i ]
          if blocked then pure False else do
            let (index, args) = branches !! i !! k
                command = planCommands plan !! index
            stepped <- try (stepModel command symbols args modelState)
            case stepped of
              Left ModelInvalid -> pure False
              Left (ModelRaised _) -> pure False
              Right (after, wanted)
                | not (mcUnit command) && compareValues result wanted /= Right EQ -> pure False
                | otherwise -> visit (advanceAt i positions) after
  visit (map (const 0) branches) expected0

-- | The first failure of repeated runs, run k shaken with shake + k.
parallelFails :: ModelPlan -> ParallelCase -> Int -> Word64 -> IO (Maybe String)
parallelFails plan parallelCase repeats shake = go 0
  where
    go attempt
      | attempt >= repeats = pure Nothing
      | otherwise = do
          failure <- executeParallel plan parallelCase (shake + fromIntegral attempt)
          case failure of
            Just _ -> pure failure
            Nothing -> go (attempt + 1)

-- | Smaller cases: dropping each prefix step, then each branch step, then
-- smaller arguments, branch by branch, step by step.
parallelCandidates :: ModelPlan -> ParallelCase -> [ParallelCase]
parallelCandidates plan (prefix@(startArgs, steps), branches) =
  [ ((startArgs, dropAt k steps), branches) | k <- [0 .. length steps - 1] ]
  ++ [ (prefix, [if j == i then dropAt k b else b | (j, b) <- zip [0 :: Int ..] branches])
     | (i, branch) <- zip [0 ..] branches, k <- [0 .. length branch - 1] ]
  ++ [ (prefix, [if j == i then replace k (index, replace a c args) b else b | (j, b) <- zip [0 :: Int ..] branches])
     | (i, branch) <- zip [0 ..] branches
     , (k, (index, args)) <- zip [0 ..] branch
     , (a, (d, arg)) <- zip [0 ..] (zip (mcArguments (planCommands plan !! index)) args)
     , c <- shrinkValue (planTable plan) d arg ]
  where dropAt k xs = take k xs ++ drop (k + 1) xs
        replace k x xs = take k xs ++ [x] ++ drop (k + 1) xs

shrinkParallel :: ModelPlan -> ParallelCase -> String -> Int -> Int -> Word64 -> IO (ParallelCase, String)
shrinkParallel plan parallelCase failure repeats budget shake
  | budget <= 0 = pure (parallelCase, failure)
  | otherwise = go (parallelCandidates plan parallelCase) budget
  where
    go [] _ = pure (parallelCase, failure)
    go (candidate : rest) b = do
      let b' = b - 1
      if b' <= 0 then pure (parallelCase, failure) else do
        allowed <- parallelAllowed plan candidate
        if not allowed then go rest b' else do
          found <- parallelFails plan candidate repeats shake
          case found of
            Just failure' -> shrinkParallel plan candidate failure' repeats b' shake
            Nothing -> go rest b'

describeParallel :: ModelPlan -> ParallelCase -> String
describeParallel plan (prefix, branches) =
  let call (i, args) = mcName (planCommands plan !! i) ++ "(" ++ intercalate ", " (map renderValue args) ++ ")"
      describe steps = if null steps then "nothing" else intercalate "; " (map call steps)
      parts = [branchName i ++ ": " ++ describe b | (i, b) <- zip [0 ..] branches]
  in describeRun plan prefix ++ ", then " ++ intercalate ", " (init parts) ++ " and " ++ last parts
       ++ " at the same time"

-- | Checks a shared model's histories under concurrency: Nothing, or the
-- failure naming the smallest failing case found. 50 cases, each run 10
-- times, 300 shrinks, 3 threads of up to 5 steps, seeded from LAWSPEC_SEED
-- or 0.
checkModelParallel :: Model -> IO (Maybe String)
checkModelParallel = checkModelParallelWith 50 10 300 parallelThreads parallelBranch Nothing

-- | checkModelParallel with the number of cases, the runs of each case, the
-- shrink budget, the threads, the longest branch and the seed (Nothing:
-- LAWSPEC_SEED, else 0).
checkModelParallelWith :: Int -> Int -> Int -> Int -> Int -> Maybe Word64 -> Model -> IO (Maybe String)
checkModelParallelWith cases repeats maxShrinks threads branchLength seedOverride model = do
  seed <- case seedOverride of
    Just s -> pure s
    Nothing -> maybe 0 (fromInteger . read) <$> lookupEnv "LAWSPEC_SEED"
  source <- newIORef (seed `xor` 0x5BD1E995)
  let plan = modelPlan model
      loop c
        | c >= cases = pure Nothing
        | otherwise = do
            parallelCase <- generateParallel plan source (1 + toInteger (c `mod` 8)) threads branchLength
            shake <- drawIO source (Draw splitMix64)
            failure <- parallelFails plan parallelCase repeats shake
            case failure of
              Nothing -> loop (c + 1)
              Just found -> do
                (parallelCase', message) <- shrinkParallel plan parallelCase found (max 2 (repeats `div` 2)) maxShrinks shake
                pure (Just ("model " ++ planName plan ++ " is not linearizable: "
                  ++ describeParallel plan parallelCase' ++ ": " ++ message))
  loop 0

-- Scenarios: processes that drive a shared model's commands at the same time
-- and talk over channels (see LawSpec.Core.Program for the spec). Each
-- channel has a queue per direction; a process holds an end of a channel as
-- (channel, side), the first branch of a par to use a channel taking side 0.
-- A channel end sent over a channel moves to the receiver. Every command's
-- call and return are stamped on one counter; the history must linearize
-- against the model, and every expect must hold, on each of many schedules.
-- A process that ends, or fails, gives up the ends it still holds (and ends
-- on their way to it): the other side's receives then fail instead of
-- waiting, unless written with or else. Every third run crashes one
-- process of a par at a random point.

-- | A blocking queue with one reader at a time.
data ScenarioQueue = ScenarioQueue (MVar ([ScenarioItem], [ScenarioItem])) (MVar ())

newScenarioQueue :: IO ScenarioQueue
newScenarioQueue = ScenarioQueue <$> newMVar ([], []) <*> newEmptyMVar

pushQueue :: ScenarioQueue -> ScenarioItem -> IO ()
pushQueue (ScenarioQueue items signal) item = do
  modifyMVar items (\(front, back) -> pure ((front, item : back), ()))
  _ <- tryPutMVar signal ()
  pure ()

tryPopQueue :: ScenarioQueue -> IO (Maybe ScenarioItem)
tryPopQueue (ScenarioQueue items _) = modifyMVar items (\(front, back) -> pure (case front of
  x : rest -> ((rest, back), Just x)
  [] -> case reverse back of
    x : rest -> ((rest, []), Just x)
    [] -> (([], []), Nothing)))

-- | The next item, waiting up to the given microseconds.
popQueue :: ScenarioQueue -> Int -> IO (Maybe ScenarioItem)
popQueue queue@(ScenarioQueue _ signal) micros = do
  item <- tryPopQueue queue
  case item of
    Just x -> pure (Just x)
    Nothing -> do
      woke <- timeout micros (takeMVar signal)
      case woke of
        Nothing -> tryPopQueue queue
        Just () -> popQueue queue micros

-- | A channel: side s sends on queue s and receives from queue 1 - s; and
-- whether each side's process has ended.
data ScenarioChannel = ScenarioChannel ScenarioQueue ScenarioQueue (MVar (Bool, Bool))

-- | A value, a channel end in transit, or the mark that the sender ended.
data ScenarioItem = ScenarioValue Scalar | ScenarioEnd (ScenarioChannel, Int) | ScenarioGone

newScenarioChannel :: IO ScenarioChannel
newScenarioChannel = ScenarioChannel <$> newScenarioQueue <*> newScenarioQueue <*> newMVar (False, False)

scenarioQueue :: ScenarioChannel -> Int -> ScenarioQueue
scenarioQueue (ScenarioChannel first second _) side = if side == 0 then first else second

sideEnded :: (Bool, Bool) -> Int -> Bool
sideEnded (a, b) side = if side == 0 then a else b

-- | Sends from side; a channel end sent to a process that has ended is
-- given up.
scenarioSend :: ScenarioChannel -> Int -> ScenarioItem -> IO ()
scenarioSend channel@(ScenarioChannel _ _ ended) side item = do
  stranded <- modifyMVar ended (\flags -> case item of
    ScenarioEnd end | sideEnded flags (1 - side) -> pure (flags, Just end)
    _ -> pushQueue (scenarioQueue channel side) item >> pure (flags, Nothing))
  forM_ stranded (\(c, s) -> scenarioGone c s)

-- | side's process has ended: the other side's receives that find nothing
-- more fail instead of waiting, and channel ends on their way to side are
-- given up too.
scenarioGone :: ScenarioChannel -> Int -> IO ()
scenarioGone channel@(ScenarioChannel _ _ ended) side = do
  stranded <- modifyMVar ended (\flags -> if sideEnded flags side then pure (flags, []) else do
    pushQueue (scenarioQueue channel side) ScenarioGone
    let drain acc = do
          item <- tryPopQueue (scenarioQueue channel (1 - side))
          case item of
            Nothing -> pure acc
            Just (ScenarioEnd end) -> drain (end : acc)
            Just ScenarioGone -> pushQueue (scenarioQueue channel (1 - side)) ScenarioGone >> pure acc
            Just _ -> drain acc
    found <- drain []
    pure (if side == 0 then (True, snd flags) else (fst flags, True), reverse found))
  mapM_ (\(c, s) -> scenarioGone c s) stranded

-- | The names an act list sends, receives or sends away, with nested pars.
actsChannels :: [Descriptor] -> [String]
actsChannels = concatMap names
  where
    names act = case act of
      DescList [DescAtom "send", c, operand] -> descriptorName c : case operand of
        DescList [DescAtom "var", x] -> [descriptorName x]
        _ -> []
      DescList (DescAtom "receive" : c : _) -> [descriptorName c]
      DescList [DescAtom "receiveor", c, _, DescList (_ : handler)] -> descriptorName c : actsChannels handler
      DescList (DescAtom "par" : branches) -> concat [actsChannels (branchActs b) | b <- branches]
      _ -> []

-- | A par branch's acts (numbered branches carry their number first).
branchActs :: Descriptor -> [Descriptor]
branchActs form = case form of
  DescList (_ : DescInteger _ : acts) -> acts
  DescList (_ : acts) -> acts
  _ -> []

-- | Numbers every par branch, outermost and first first (not inside or
-- else), as (process n acts...); and how many acts each has.
numberBranches :: [Descriptor] -> ([Descriptor], [Int])
numberBranches body = let (acts, (_, lengths)) = goActs body (0, []) in (acts, reverse lengths)
  where
    goActs [] st = ([], st)
    goActs (act : rest) st =
      let (act', st') = goAct act st
          (rest', st'') = goActs rest st'
      in (act' : rest', st'')
    goAct (DescList (DescAtom "par" : branches)) st =
      let step (acc, s) (DescList (h : acts)) =
            let (n, ls) = s
                (acts', s') = goActs acts (n + 1, length acts : ls)
            in (acc ++ [DescList (h : DescInteger (toInteger n) : acts')], s')
          step (acc, s) other = (acc ++ [other], s)
          (branches', st') = foldl step ([], st) branches
      in (DescList (DescAtom "par" : branches'), st')
    goAct other st = (other, st)

scenarioConstant :: Descriptor -> Scalar
scenarioConstant form = case form of
  DescList [DescAtom "int", DescInteger n] -> SInteger "Integer" n
  DescList [DescAtom "text", t] -> textScalar (descriptorName t)
  DescList [DescAtom "bool", b] -> SBool (descriptorName b == "true")
  DescList [_, t] -> SData (descriptorName t) []
  _ -> error ("invalid scenario constant " ++ show form)

-- | A call in a scenario's history: command, arguments, result, called, returned.
type ScenarioCall = (ModelCommand, [Scalar], Scalar, Int, Int)

-- | The scenario's title and its failure on one schedule, if any.
runScenario :: Model -> String -> Word64 -> IO (String, Maybe String)
runScenario model spec shake = runScenarioWith False model spec shake

-- | runScenario, with crash: one process of a par crashes before a random act.
runScenarioWith :: Bool -> Model -> String -> Word64 -> IO (String, Maybe String)
runScenarioWith crash model spec shake = do
  let forms = readDescriptor spec
      title = case forms of
        DescList (_ : t : _) : _ -> descriptorName t
        _ -> error "invalid scenario spec"
      names = concat (take 1 [map descriptorName rest | DescList (DescAtom "channels" : rest) <- forms])
      (body, lengths) = numberBranches (concat (take 1 [rest | DescList (DescAtom "process" : rest) <- forms]))
      plan = modelPlan model
      commandNamed n = case find ((== n) . mcName) (planCommands plan) of
        Just command -> command
        Nothing -> error ("unknown command " ++ n)
  victim <- if crash && not (null lengths) then do
      chooser <- newIORef (shake `xor` 0xC3A5C85C97CB3127)
      branch <- drawIO chooser (drawBelow (toInteger (length lengths)))
      at <- drawIO chooser (drawBelow (toInteger (lengths !! fromInteger branch) + 1))
      pure (Just (fromInteger branch :: Int, fromInteger at :: Int))
    else pure Nothing
  channels <- forM names $ \n -> (,) n <$> newScenarioChannel
  symbols <- newSymbolContext
  let startArgs = map (minimalValue (planTable plan)) (planStartArguments plan)
  outcome <- try $ do
    state <- callOrRaise (planStartRun plan) symbols startArgs
    expected <- callOrRaise (planStartModel plan) symbols startArgs
    clock <- newIORef (0 :: Int)
    history <- newIORef ([] :: [ScenarioCall])
    failures <- newIORef ([] :: [String])
    let tick = atomicModifyIORef' clock (\c -> (c + 1, c + 1))
        failWith message = atomicModifyIORef' failures (\fs -> (fs ++ [message], ())) >> pure False
        bind name value pairs = (name, value) : filter ((/= name) . fst) pairs
        valueOf env operand = case operand of
          DescList [DescAtom "var", x] -> case lookup (descriptorName x) env of
            Just value -> value
            Nothing -> error ("unbound scenario variable " ++ descriptorName x)
          _ -> scenarioConstant operand
        endOf ends c = case lookup (descriptorName c) ends of
          Just end -> end
          Nothing -> error ("no end of channel " ++ descriptorName c)
        -- True when the process finished, False when it failed; either way
        -- the ends it still holds are given up.
        process acts env0 ends0 source identity = do
          held <- newIORef ends0
          done <- (steps acts env0 ends0 source identity held
            `catch` \(e :: SomeException) -> failWith ("raised error: " ++ exceptionText e))
            `finally` (readIORef held >>= mapM_ (\(_, (c, s)) -> scenarioGone c s))
          pure done
        steps acts env0 ends0 source identity held = do
          own <- newSymbolContext
          let crashesAt index = case (victim, identity) of
                (Just v, Just i) -> v == (i, index)
                _ -> False
              go index [] _ ends = writeIORef held ends >> pure (not (crashesAt index))
              go index (act : rest) env ends = do
                writeIORef held ends
                failed <- not . null <$> readIORef failures
                if failed || crashesAt index then pure False else case act of
                  DescList (DescAtom "call" : nameForm : bound : operands) -> do
                    let command = commandNamed (descriptorName nameForm)
                        -- An integer constant takes the argument's own type.
                        typed d value = case (d, value) of
                          (DescList (DescAtom "int" : t : _), SInteger _ n) -> SInteger (descriptorName t) n
                          _ -> value
                        args = zipWith typed (mcArguments command ++ repeat DescNone) (map (valueOf env) operands)
                        position = mcState command
                        full = take position args ++ [state] ++ drop position args
                    perturb source
                    called <- tick
                    -- The result is forced in full here, so the effect (or its
                    -- error) happens between the call and return stamps.
                    let run symbols' args' = case mcRun command symbols' args' of
                          Right value -> forceScalar value `seq` Right value
                          failure -> failure
                    out <- callModel run own full
                    case out of
                      Left message -> failWith (mcName command ++ " raised error: " ++ message)
                      Right result -> do
                        returned <- tick
                        atomicModifyIORef' history (\h -> (h ++ [(command, args, result, called, returned)], ()))
                        let env' = case bound of
                              DescNone -> env
                              DescAtom "_" -> env
                              _ -> bind (descriptorName bound) result env
                        go (index + 1) rest env' ends
                  DescList [DescAtom "send", c, operand] -> do
                    let (channel, side) = endOf ends c
                        (item, ends') = case operand of
                          DescList [DescAtom "var", x] | Just end <- lookup (descriptorName x) ends ->
                            (ScenarioEnd end, filter ((/= descriptorName x) . fst) ends)
                          _ -> (ScenarioValue (valueOf env operand), ends)
                    perturb source
                    writeIORef held ends'
                    scenarioSend channel side item
                    go (index + 1) rest env ends'
                  DescList (DescAtom kind : c : x : handler) | kind == "receive" || kind == "receiveor" -> do
                    let (channel, side) = endOf ends c
                        queue = scenarioQueue channel (1 - side)
                    got <- popQueue queue 5000000
                    case got of
                      Nothing -> failWith ("a receive on " ++ descriptorName c
                        ++ " waited too long: the processes are blocked")
                      -- The other process ended: or else runs instead of the
                      -- rest; without it, this process fails too.
                      Just ScenarioGone -> do
                        pushQueue queue ScenarioGone
                        case handler of
                          [DescList (_ : handlerActs)] | kind == "receiveor" -> do
                            let ends' = filter ((/= descriptorName c) . fst) ends
                            writeIORef held ends'
                            steps handlerActs env ends' source Nothing held
                          _ -> pure False
                      Just (ScenarioEnd end) -> go (index + 1) rest env (bind (descriptorName x) end ends)
                      Just (ScenarioValue value) -> go (index + 1) rest (bind (descriptorName x) value env) ends
                  DescList (DescAtom "par" : branchForms) -> do
                    let branches = [ case form of
                                       DescList (_ : DescInteger n : acts) -> (Just (fromInteger n), acts)
                                       _ -> (Nothing, branchActs form)
                                   | form <- branchForms ]
                        addUser owned (name, i) = case lookup name owned of
                          Nothing -> owned ++ [(name, [i])]
                          Just users
                            | i `elem` users -> owned
                            | otherwise -> [(n, if n == name then us ++ [i] else us) | (n, us) <- owned]
                        owned = foldl addUser [] [(name, i) | (i, (_, b)) <- zip [0 :: Int ..] branches, name <- actsChannels b]
                        mine i = [ (name, end) | (name, users) <- owned, i `elem` users
                                 , end <- case lookup name ends of
                                     Just held' -> [held']
                                     Nothing -> case lookup name channels of
                                       Just channel -> [(channel, length (takeWhile (/= i) users))]
                                       Nothing -> [] ]
                        -- Ends handed to the branches are theirs now.
                        ends' = filter ((`notElem` map fst owned) . fst) ends
                    writeIORef held ends'
                    dones <- forM (zip [0 :: Int ..] branches) $ \(i, (n, b)) -> do
                      finished <- newEmptyMVar
                      branchSource <- newIORef (shake `xor` (fromIntegral (i + 1) * 0x9E3779B97F4A7C15))
                      _ <- forkIO (do
                        ok <- process b env (mine i) branchSource n `catch` \(_ :: SomeException) -> pure False
                        putMVar finished ok)
                      pure finished
                    results <- mapM takeMVar dones
                    -- A failed branch fails the process that ran the par.
                    if and results then go (index + 1) rest env ends' else pure False
                  DescList [DescAtom "expect", x, c] -> do
                    let name = descriptorName x
                        wanted = scenarioConstant c
                        actual = lookup name env
                    if maybe True (\a -> compareValues a wanted /= Right EQ) actual
                      then failWith ("expect " ++ name ++ " = " ++ renderValue wanted ++ " failed: "
                        ++ name ++ " is " ++ maybe "None" renderValue actual)
                      else go (index + 1) rest env ends
                  _ -> error ("unknown scenario act " ++ show act)
          go (0 :: Int) acts env0 ends0
    root <- newIORef shake
    finished <- process body [] [] root Nothing
    found <- readIORef failures
    case found of
      failure : _ -> pure (Just (failure ++ (if victim /= Nothing then " (with a process crashed)" else "")))
      [] | not finished && victim == Nothing -> pure (Just "a process failed")
      [] -> do
        final <- case planAbstract plan of
          Nothing -> pure Nothing
          Just abstract -> Just <$> callOrRaise abstract symbols [state]
        calls <- readIORef history
        linearizes <- linearizesHistory plan symbols calls expected final state
        let calledAt (_, _, _, c, _) = c
            observed = intercalate "; "
              [ mcName command ++ "(" ++ intercalate ", " (map renderValue args) ++ ") returned " ++ renderValue result
              | (command, args, result, _, _) <- sortBy (\a b -> compare (calledAt a) (calledAt b)) calls ]
        pure (if linearizes then Nothing
          else Just ("no order of the calls agrees with the model (" ++ observed ++ ")"))
  pure (title, case outcome of
    Right failure -> failure
    Left e -> Just ("raised error: " ++ case fromException e of
      Just (ModelRaised message) -> message
      _ -> exceptionText e))

-- | A Wing-Gong search over any real-time order: next, a call that no
-- pending call returned before; memoized on the calls done and the state.
linearizesHistory :: ModelPlan -> SymbolContext -> [ScenarioCall] -> Scalar -> Maybe Scalar -> Scalar -> IO Bool
linearizesHistory plan symbols calls expected final state = do
  seen <- newIORef ([] :: [(Integer, String)])
  let indexed = zip [0 ..] calls
      complete = bit (length calls) - 1 :: Integer
      visit done modelState = do
        let key = (done, renderValue modelState)
        keys <- readIORef seen
        if key `elem` keys then pure False else do
          writeIORef seen (key : keys)
          if done == complete then finish modelState else anyM (next done modelState) indexed
      next done modelState (i, (command, args, result, called, _))
        | testBit done i = pure False
        | or [ not (testBit done j) && returned < called
             | (j, (_, _, _, _, returned)) <- indexed, j /= i ] = pure False
        | otherwise = do
            stepped <- try (stepModel command symbols args modelState)
            case stepped of
              Left (_ :: ModelStop) -> pure False
              Right (after, wanted)
                | not (mcUnit command) && compareValues result wanted /= Right EQ -> pure False
                | otherwise -> visit (setBit done i) after
      finish modelState
        | maybe False (\actual -> compareValues actual modelState /= Right EQ) final = pure False
        | otherwise = allM (\(kind, invariant) -> do
            holds <- callModel invariant symbols [if kind == "model" then modelState else state]
            pure (case holds of Right (SBool True) -> True; _ -> False)) (planInvariants plan)
  visit 0 expected

-- | Runs a scenario on 30 schedules, seeded from LAWSPEC_SEED or 0: Nothing,
-- or the first failure.
checkScenario :: Model -> String -> IO (Maybe String)
checkScenario model spec = do
  seed <- maybe 0 (fromInteger . read) <$> lookupEnv "LAWSPEC_SEED"
  source <- newIORef (seed `xor` 0x2545F4914F6CDD1D)
  let loop :: Int -> IO (Maybe String)
      loop run
        | run >= 30 = pure Nothing
        | otherwise = do
            shake <- drawIO source (Draw splitMix64)
            -- Every third run crashes one process of a par at a random point.
            (title, failure) <- runScenarioWith (run `mod` 3 == 2) model spec shake
            case failure of
              Just message -> pure (Just ("scenario " ++ title ++ " fails: " ++ message))
              Nothing -> loop (run + 1)
  loop 0

-- Actors. An actor owns a state and handles one message at a time, in the
-- order they arrive. It is not a thread: a message sent to an idle actor
-- forks a short-lived worker that drains its mailbox and then stops, so an
-- idle actor costs only its state and queue. A handler that throws crashes
-- the actor: the caller gets ActorCrashed, and a supervised actor restarts
-- in place (keeping its address and the messages waiting for it) while any
-- other stops.

-- | A message sent to an actor (or mailbox) that has stopped.
data ActorStopped = ActorStopped deriving Show
instance Exception ActorStopped

-- | A handler failed, so the actor crashed; the cause is what it threw.
newtype ActorCrashed = ActorCrashed SomeException deriving Show
instance Exception ActorCrashed

-- | Why an actor or supervisor exited, as its monitors hear it.
data Exit = Crashed String | Stopped deriving (Eq, Show)

-- | What a message does to the actor: the next state, or a crash with its
-- cause and the crash it started from (so a crash crosses each link once).
data Outcome s = Next s | Crash String Integer

-- | A queued message, and how to refuse it once the actor has stopped.
data Message s = Message (s -> IO (Outcome s)) (IO ())

data Actor s = Actor
  { actorRef :: IORef s
  , actorBox :: MVar (ActorBox s)
  , actorRestartWith :: Maybe (s -> IO s)
  , actorSupervisor :: IORef (Maybe Supervisor)
  , actorMonitors :: IORef [Exit -> IO ()]
  , actorLinks :: IORef [String -> Integer -> IO ()]
  , actorSeen :: IORef [Integer]
  , actorKey :: Unique
  }

-- | Queued messages (front, then back reversed), whether a worker is
-- draining them, and whether the actor has stopped.
data ActorBox s = ActorBox [Message s] [Message s] Bool Bool

crashCounter :: IORef Integer
crashCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE crashCounter #-}

nextCrash :: IO Integer
nextCrash = atomicModifyIORef' crashCounter (\n -> (n + 1, n + 1))

-- | An actor owning the given state; a crash stops it.
newActor :: s -> IO (Actor s)
newActor = newActorWith Nothing

-- | An actor whose state after a crash is restart (last state), so a
-- supervisor can restart it.
newRestartableActor :: (s -> IO s) -> s -> IO (Actor s)
newRestartableActor restart = newActorWith (Just restart)

newActorWith :: Maybe (s -> IO s) -> s -> IO (Actor s)
newActorWith restart state = Actor <$> newIORef state <*> newMVar (ActorBox [] [] False False) <*> pure restart
  <*> newIORef Nothing <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newUnique

postActor :: Actor s -> Message s -> IO ()
postActor actor message = do
  start <- modifyMVar (actorBox actor) (\(ActorBox front back draining stopped) ->
    if stopped then throwIO ActorStopped
    else pure (ActorBox front (message : back) True stopped, not draining))
  if start then () <$ forkIO (drainActor actor) else pure ()

-- | Posts a message, ignoring an actor that has stopped.
postQuietly :: Actor s -> Message s -> IO ()
postQuietly actor message = postActor actor message `catch` \ActorStopped -> pure ()

drainActor :: Actor s -> IO ()
drainActor actor = loop
  where
    loop = do
      next <- modifyMVar (actorBox actor) (\(ActorBox front back _ stopped) -> pure (case front of
        m : rest -> (ActorBox rest back True stopped, Just m)
        [] -> case reverse back of
          m : rest -> (ActorBox rest [] True stopped, Just m)
          [] -> (ActorBox [] [] False stopped, Nothing)))
      case next of
        Nothing -> pure ()
        Just (Message run _) -> do
          outcome <- readIORef (actorRef actor) >>= run
          case outcome of
            Next state -> writeIORef (actorRef actor) state
            Crash cause origin -> actorCrashed actor cause origin
          loop

-- | On the actor's turn: restart or stop, then tell monitors and links.
actorCrashed :: Actor s -> String -> Integer -> IO ()
actorCrashed actor cause origin = do
  modifyIORef' (actorSeen actor) (origin :)
  supervisor <- readIORef (actorSupervisor actor)
  restarted <- case (supervisor, actorRestartWith actor) of
    (Just s, Just _) -> supervisorChildCrashed s (actorChild actor) cause
    _ -> pure False
  if restarted then pure () else haltActor actor
  readIORef (actorMonitors actor) >>= mapM_ ($ Crashed cause)
  readIORef (actorLinks actor) >>= mapM_ (\crash -> crash cause origin)

-- | On the actor's turn: the restarted state from the last one; a restart
-- that throws stops the actor.
restartNow :: Actor s -> IO ()
restartNow actor = case actorRestartWith actor of
  Nothing -> haltActor actor
  Just restart -> do
    outcome <- try (readIORef (actorRef actor) >>= restart >>= evaluate)
    case outcome of
      Right state -> writeIORef (actorRef actor) state
      Left (_ :: SomeException) -> haltActor actor

-- | A restart a supervisor asks of a sibling, in mailbox order.
restartLater :: Actor s -> IO ()
restartLater actor = case actorRestartWith actor of
  Nothing -> pure ()
  Just restart -> postQuietly actor (Message (\state -> do
    outcome <- try (restart state >>= evaluate)
    pure (either (\e -> Crash (exceptionText e) 0) Next outcome)) (pure ()))

-- | Stops the actor; messages still waiting fail with ActorStopped.
haltActor :: Actor s -> IO ()
haltActor actor = do
  waiting <- modifyMVar (actorBox actor) (\(ActorBox front back draining _) ->
    pure (ActorBox [] [] draining True, front ++ reverse back))
  mapM_ (\(Message _ refuse) -> refuse) waiting

-- | Runs handler state -> (reply, next state) in turn and returns the
-- reply. A handler that throws crashes the actor, and callActor throws
-- ActorCrashed.
callActor :: Actor s -> (s -> IO (r, s)) -> IO r
callActor actor handler = do
  reply <- newEmptyMVar
  postActor actor (Message (\state -> do
    outcome <- try (handler state >>= \(r, next) -> next `seq` pure (r, next))
    case outcome of
      Left e -> do
        origin <- nextCrash
        putMVar reply (Left (toException (ActorCrashed e)))
        pure (Crash (exceptionText e) origin)
      Right (r, next) -> putMVar reply (Right r) >> pure (Next next))
    (putMVar reply (Left (toException ActorStopped))))
  takeMVar reply >>= either throwIO pure

-- | Queues handler state -> (reply, next state) without waiting; a handler
-- that throws crashes the actor.
castActor :: Actor s -> (s -> IO (r, s)) -> IO ()
castActor actor handler = postActor actor (Message (\state -> do
  outcome <- try (handler state >>= \(r, next) -> next `seq` pure (r, next))
  case outcome of
    Left e -> Crash (exceptionText (e :: SomeException)) <$> nextCrash
    Right (_, next) -> pure (Next next)) (pure ()))

-- | Crashes the actor once the messages before this one are handled, as a
-- failing handler would: for testing supervision.
crashActor :: Actor s -> String -> IO ()
crashActor actor cause = do
  origin <- nextCrash
  reply <- newEmptyMVar
  postActor actor (Message (\_ -> putMVar reply (Right ()) >> pure (Crash cause origin))
    (putMVar reply (Left (toException ActorStopped))))
  takeMVar reply >>= either throwIO pure

-- | Replaces the state by restart (last state) between messages, as a
-- supervised restart does (crash injection in model runs).
restartActor :: Actor s -> (s -> IO s) -> IO ()
restartActor actor restart = callActor actor (\state -> (,) () <$> restart state)

-- | The state after every message sent before this call.
actorState :: Actor s -> IO s
actorState actor = callActor actor (\s -> pure (s, s))

-- | Calls notify with Crashed cause after each crash, and Stopped once the
-- actor stops.
monitorActor :: Actor s -> (Exit -> IO ()) -> IO ()
monitorActor actor notify = modifyIORef' (actorMonitors actor) (++ [notify])

-- | Links two actors: when either crashes, the other crashes too.
linkActors :: Actor a -> Actor b -> IO ()
linkActors = link

linkCrash :: Actor s -> String -> Integer -> IO ()
linkCrash actor cause origin = do
  seen <- readIORef (actorSeen actor)
  if origin `elem` seen then pure ()
    -- Checked again on the actor's turn: another link may have brought the
    -- same crash first.
    else postQuietly actor (Message (\state -> do
      again <- readIORef (actorSeen actor)
      pure (if origin `elem` again then Next state else Crash cause origin)) (pure ()))

-- | Refuses further messages; those already queued still run. A permanent
-- child of a supervisor restarts instead.
stopActor :: Actor s -> IO ()
stopActor actor = do
  supervisor <- readIORef (actorSupervisor actor)
  restarted <- maybe (pure False) (\s -> supervisorChildStopped s (actorChild actor)) supervisor
  if restarted then pure () else do
    already <- modifyMVar (actorBox actor) (\(ActorBox front back draining stopped) ->
      pure (ActorBox front back draining True, stopped))
    if already then pure () else readIORef (actorMonitors actor) >>= mapM_ ($ Stopped)

-- Supervision.

data SupervisionStrategy = OneForOne | OneForAll | RestForOne deriving (Eq, Show)
data Lifetime = Permanent | Transient | Temporary deriving (Eq, Show)

-- | What a supervisor needs of a child, actor or supervisor.
data SupervisedChild = SupervisedChild
  { childKey :: Unique
  , childRestartNow :: IO ()
  , childRestartLater :: IO ()
  , childHalt :: IO ()
  , childStop :: IO ()
  , childAdopt :: Maybe Supervisor -> IO ()
  }

actorChild :: Actor s -> SupervisedChild
actorChild actor = SupervisedChild (actorKey actor) (restartNow actor) (restartLater actor)
  (haltActor actor) (stopActor actor) (writeIORef (actorSupervisor actor))

supervisorChild :: Supervisor -> SupervisedChild
supervisorChild s = SupervisedChild (supervisorKey s) (pure ()) (supervisorRestartLater s)
  (stopSupervisor s) (stopSupervisor s) (writeIORef (supervisorParent s))

-- | Starts children (actors or supervisors) and restarts them after a
-- crash. OneForOne restarts the child that crashed, OneForAll every child,
-- RestForOne it and those added after it. A Permanent child restarts after
-- a crash or a stop, a Transient one only after a crash, a Temporary one
-- never. More restarts than allowed within the period is the supervisor's
-- own crash: its supervisor restarts all of its children, or, at the top,
-- every child stops.
data Supervisor = Supervisor
  { supervisorStrategy :: SupervisionStrategy
  , supervisorMaxRestarts :: Int
  , supervisorPeriodMicros :: Integer
  , supervisorLock :: MVar ()
  , supervisorChildren :: IORef [(SupervisedChild, Lifetime)]
  , supervisorRestarts :: IORef [Word64]
  , supervisorParent :: IORef (Maybe Supervisor)
  , supervisorStopped :: IORef Bool
  , supervisorMonitors :: IORef [Exit -> IO ()]
  , supervisorKey :: Unique
  }

-- | A supervisor with a strategy, allowing at most so many restarts within
-- a period in microseconds.
newSupervisor :: SupervisionStrategy -> Int -> Integer -> IO Supervisor
newSupervisor strategy maxRestarts period = Supervisor strategy maxRestarts period <$> newMVar ()
  <*> newIORef [] <*> newIORef [] <*> newIORef Nothing <*> newIORef False <*> newIORef [] <*> newUnique

-- | Adds a started child.
supervise :: Supervisor -> SupervisedChild -> Lifetime -> IO ()
supervise s child lifetime = withMVar' (supervisorLock s) $ do
  childAdopt child (Just s)
  modifyIORef' (supervisorChildren s) (++ [(child, lifetime)])

-- | Adds a started actor.
superviseActor :: Supervisor -> Actor a -> Lifetime -> IO ()
superviseActor s actor = supervise s (actorChild actor)

-- | Adds a started supervisor.
superviseSupervisor :: Supervisor -> Supervisor -> Lifetime -> IO ()
superviseSupervisor s child = supervise s (supervisorChild child)

withMVar' :: MVar () -> IO a -> IO a
withMVar' lock action = modifyMVar lock (\() -> (,) () <$> action)

allowRestart :: Supervisor -> IO Bool
allowRestart s = do
  now <- getMonotonicTimeNSec
  let window = fromInteger (supervisorPeriodMicros s * 1000)
  recent <- filter (\t -> now - t <= window) <$> readIORef (supervisorRestarts s)
  if length recent >= supervisorMaxRestarts s
    then writeIORef (supervisorRestarts s) recent >> pure False
    else writeIORef (supervisorRestarts s) (recent ++ [now]) >> pure True

-- | Under the lock: the children to restart for a child's crash, or
-- Nothing when the supervisor gives up.
restarting :: Supervisor -> Unique -> String -> IO (Maybe [SupervisedChild])
restarting s key cause = do
  allowed <- allowRestart s
  children <- readIORef (supervisorChildren s)
  if allowed then pure (Just (case supervisorStrategy s of
      OneForOne -> [c | (c, _) <- children, childKey c == key]
      OneForAll -> map fst children
      RestForOne -> map fst (dropWhile ((/= key) . childKey . fst) children)))
  else do
    parent <- readIORef (supervisorParent s)
    escalated <- maybe (pure False) (\p -> supervisorChildFailed p (supervisorChild s) cause) parent
    if escalated
      then writeIORef (supervisorRestarts s) [] >> pure (Just (map fst children))
      else failSupervisor s key cause >> pure Nothing

-- | The child's entry, unless the supervisor stopped; a Temporary child is
-- dropped and gets nothing.
entryOf :: Supervisor -> Unique -> IO (Maybe Lifetime)
entryOf s key = do
  stopped <- readIORef (supervisorStopped s)
  children <- readIORef (supervisorChildren s)
  case lookup key [(childKey c, l) | (c, l) <- children] of
    Just lifetime | not stopped -> pure (Just lifetime)
    _ -> pure Nothing

dropChild :: Supervisor -> Unique -> IO ()
dropChild s key = modifyIORef' (supervisorChildren s) (filter ((/= key) . childKey . fst))

-- | On the child's turn: True when it restarts now.
supervisorChildCrashed :: Supervisor -> SupervisedChild -> String -> IO Bool
supervisorChildCrashed s child cause = do
  group <- withMVar' (supervisorLock s) $ do
    entry <- entryOf s (childKey child)
    case entry of
      Nothing -> pure Nothing
      Just Temporary -> dropChild s (childKey child) >> pure Nothing
      Just _ -> restarting s (childKey child) cause
  case group of
    Nothing -> pure False
    Just children -> do
      mapM_ childRestartLater [c | c <- children, childKey c /= childKey child]
      childRestartNow child
      pure True

-- | A child supervisor gave up: True when it may restart its children.
supervisorChildFailed :: Supervisor -> SupervisedChild -> String -> IO Bool
supervisorChildFailed s child cause = do
  group <- withMVar' (supervisorLock s) $ do
    entry <- entryOf s (childKey child)
    case entry of
      Nothing -> pure Nothing
      Just Temporary -> dropChild s (childKey child) >> pure Nothing
      Just _ -> restarting s (childKey child) cause
  case group of
    Nothing -> pure False
    Just children -> do
      mapM_ childRestartLater [c | c <- children, childKey c /= childKey child]
      pure True

-- | True when a stopped child is Permanent and restarts instead.
supervisorChildStopped :: Supervisor -> SupervisedChild -> IO Bool
supervisorChildStopped s child = do
  group <- withMVar' (supervisorLock s) $ do
    entry <- entryOf s (childKey child)
    case entry of
      Just Permanent -> restarting s (childKey child) "stopped"
      Just _ -> dropChild s (childKey child) >> pure Nothing
      Nothing -> pure Nothing
  case group of
    Nothing -> pure False
    Just children -> mapM_ childRestartLater children >> pure True

-- | Under the lock: every child but the one crashing (which stops itself)
-- stops, and so does the supervisor.
failSupervisor :: Supervisor -> Unique -> String -> IO ()
failSupervisor s crashed cause = do
  children <- readIORef (supervisorChildren s)
  writeIORef (supervisorChildren s) []
  writeIORef (supervisorStopped s) True
  forM_ (reverse children) $ \(c, _) -> do
    childAdopt c Nothing
    if childKey c == crashed then pure () else childHalt c
  readIORef (supervisorMonitors s) >>= mapM_ ($ Crashed cause)

-- | Restarted by its own supervisor: every child restarts.
supervisorRestartLater :: Supervisor -> IO ()
supervisorRestartLater s = do
  children <- withMVar' (supervisorLock s) $ do
    writeIORef (supervisorRestarts s) []
    readIORef (supervisorChildren s)
  mapM_ (childRestartLater . fst) children

-- | Calls notify with Crashed cause when it passes its restart limit, and
-- Stopped once stopped.
monitorSupervisor :: Supervisor -> (Exit -> IO ()) -> IO ()
monitorSupervisor s notify = modifyIORef' (supervisorMonitors s) (++ [notify])

-- | Stops every child, last added first, without restarting them.
stopSupervisor :: Supervisor -> IO ()
stopSupervisor s = do
  children <- withMVar' (supervisorLock s) $ do
    stopped <- readIORef (supervisorStopped s)
    if stopped then pure Nothing else do
      writeIORef (supervisorStopped s) True
      children <- readIORef (supervisorChildren s)
      writeIORef (supervisorChildren s) []
      pure (Just children)
  case children of
    Nothing -> pure ()
    Just cs -> do
      forM_ (reverse cs) $ \(c, _) -> childAdopt c Nothing >> childStop c
      readIORef (supervisorMonitors s) >>= mapM_ ($ Stopped)

-- | Anything a supervisor can supervise: actors, supervisors, and the
-- generated typed actors and supervisors.
class Supervisable t where
  asChild :: t -> SupervisedChild

instance Supervisable (Actor s) where
  asChild = actorChild

instance Supervisable Supervisor where
  asChild = supervisorChild

-- | Adds a started child (an actor or a supervisor) to a supervisor.
superviseChild :: Supervisable t => Supervisor -> t -> Lifetime -> IO ()
superviseChild s child = supervise s (asChild child)

-- | Where a crash arrives for an actor that is linked to: its links, and
-- how to crash it.
data LinkPoint = LinkPoint (IORef [String -> Integer -> IO ()]) (String -> Integer -> IO ())

-- | Anything that can be linked: actors and the generated typed actors.
class Linkable t where
  linkPoint :: t -> LinkPoint

instance Linkable (Actor s) where
  linkPoint actor = LinkPoint (actorLinks actor) (linkCrash actor)

-- | Links two actors: when either crashes, the other crashes too.
link :: (Linkable a, Linkable b) => a -> b -> IO ()
link a b = do
  let LinkPoint linksA crashA = linkPoint a
      LinkPoint linksB crashB = linkPoint b
  modifyIORef' linksA (++ [crashB])
  modifyIORef' linksB (++ [crashA])

-- | Anything whose exits can be watched.
class Monitorable t where
  -- | Calls notify with Crashed cause after each crash (for a supervisor,
  -- when it passes its restart limit), and Stopped once it stops.
  monitor :: t -> (Exit -> IO ()) -> IO ()

instance Monitorable (Actor s) where
  monitor = monitorActor

instance Monitorable Supervisor where
  monitor = monitorSupervisor

-- | The runtime's own check of crashes, links, monitors and supervision:
-- every strategy, lifetime, the restart limit and escalation. Nothing, or
-- the first behaviour that differs.
checkSupervision :: IO (Maybe String)
checkSupervision = do
  outcome <- try checks
  pure (case outcome of
    Right () -> Nothing
    Left (ErrorCall message) -> Just message)
  where
    counter = newRestartableActor (\_ -> pure (0 :: Int)) 0
    bump a = callActor a (\s -> pure (s + 1, s + 1))
    failing a = do
      outcome <- try (callActor a (\s -> if s >= 0 then throwIO (ErrorCall "a failing handler") else pure ((), s)))
      case outcome of
        Left (ActorCrashed _) -> pure ()
        Right () -> throwIO (ErrorCall "a failing handler did not throw ActorCrashed")
    stopped a what = do
      outcome <- try (actorState a)
      case outcome of
        Left ActorStopped -> pure ()
        Right _ -> throwIO (ErrorCall (what ++ " should have stopped"))
    expect :: (Eq a, Show a) => a -> a -> String -> IO ()
    expect actual wanted what = if actual == wanted then pure ()
      else throwIO (ErrorCall (what ++ ": got " ++ show actual ++ ", expected " ++ show wanted))
    under s lifetime = do
      a <- counter
      superviseActor s a lifetime
      pure a
    waitFor condition = loop (100 :: Int)
      where loop n = do
              ok <- condition
              if ok || n <= 0 then pure () else threadDelay 10000 >> loop (n - 1)
    checks = do
      a <- counter
      _ <- bump a
      failing a
      stopped a "an unsupervised actor that crashed"
      s1 <- newSupervisor OneForOne 3 5000000
      x1 <- under s1 Permanent
      y1 <- under s1 Permanent
      _ <- bump x1 >> bump y1 >> bump y1
      failing x1
      states1 <- (,) <$> actorState x1 <*> actorState y1
      expect states1 (0, 2) "one for one restarts only the crashed child"
      s2 <- newSupervisor OneForAll 3 5000000
      x2 <- under s2 Permanent
      y2 <- under s2 Permanent
      _ <- bump x2 >> bump y2
      failing x2
      states2 <- (,) <$> actorState x2 <*> actorState y2
      expect states2 (0, 0) "one for all restarts every child"
      s3 <- newSupervisor RestForOne 3 5000000
      x3 <- under s3 Permanent
      y3 <- under s3 Permanent
      z3 <- under s3 Permanent
      _ <- bump x3 >> bump y3 >> bump z3
      failing y3
      states3 <- (,,) <$> actorState x3 <*> actorState y3 <*> actorState z3
      expect states3 (1, 0, 0) "rest for one restarts the child and later ones"
      s4 <- newSupervisor OneForOne 3 5000000
      t4 <- under s4 Temporary
      failing t4
      stopped t4 "a temporary child that crashed"
      s5 <- newSupervisor OneForOne 3 5000000
      p5 <- under s5 Permanent
      q5 <- under s5 Transient
      _ <- bump p5
      stopActor p5
      state5 <- actorState p5
      expect state5 0 "a permanent child restarts after a stop"
      stopActor q5
      stopped q5 "a transient child that was stopped"
      events <- newIORef []
      s6 <- newSupervisor OneForOne 2 10000000
      monitorSupervisor s6 (\e -> modifyIORef' events (++ [e]))
      x6 <- under s6 Permanent
      y6 <- under s6 Permanent
      failing x6 >> failing x6 >> failing x6
      stopped y6 "a child of a supervisor past its restart limit"
      heard <- map (\e -> case e of Crashed _ -> "crashed"; Stopped -> "stopped") <$> readIORef events
      expect heard ["crashed"] "a supervisor past its limit tells its monitors"
      outer <- newSupervisor OneForOne 5 10000000
      inner <- newSupervisor OneForOne 1 10000000
      superviseSupervisor outer inner Permanent
      x7 <- under inner Permanent
      y7 <- under inner Permanent
      _ <- bump y7
      failing x7 >> failing x7
      states7 <- (,) <$> actorState x7 <*> actorState y7
      expect states7 (0, 0) "a supervisor past its limit is restarted by its own"
      seen <- newIORef []
      a8 <- counter
      b8 <- counter
      linkActors a8 b8
      monitorActor b8 (\e -> modifyIORef' seen (++ [e]))
      failing a8
      waitFor (not . null <$> readIORef seen)
      stopped b8 "an unsupervised actor linked to one that crashed"
      heard8 <- map (\e -> case e of Crashed _ -> "crashed"; Stopped -> "stopped") <$> readIORef seen
      expect heard8 ["crashed"] "a monitor hears of a crash"
      s9 <- newSupervisor OneForOne 10 5000000
      a9 <- under s9 Permanent
      b9 <- under s9 Permanent
      c9 <- under s9 Permanent
      linkActors a9 b9 >> linkActors b9 c9 >> linkActors c9 a9
      _ <- bump a9 >> bump b9 >> bump c9
      failing a9
      waitFor ((>= 3) . length <$> readIORef (supervisorRestarts s9))
      threadDelay 50000
      states9 <- (,,) <$> actorState a9 <*> actorState b9 <*> actorState c9
      restarts9 <- length <$> readIORef (supervisorRestarts s9)
      expect (states9, restarts9) ((0, 0, 0), 3) "a crash crosses each link once"

-- | A queue with many senders and one receiver: the channel form of an
-- actor. A process that loops over receiveMailbox and answers each message
-- is an actor written by hand; sendMailbox never waits.
data Mailbox a = Mailbox (Chan (Maybe a)) (IORef Bool)

newMailbox :: IO (Mailbox a)
newMailbox = Mailbox <$> newChan <*> newIORef False

sendMailbox :: Mailbox a -> a -> IO ()
sendMailbox (Mailbox chan closed) value = do
  done <- readIORef closed
  if done then throwIO ActorStopped else writeChan chan (Just value)

-- | The next message, waiting for it; throws ActorStopped once the mailbox
-- is closed and empty.
receiveMailbox :: Mailbox a -> IO a
receiveMailbox mailbox@(Mailbox chan _) = readChan chan >>= closedOr mailbox

-- | The next message, waiting up to the given microseconds (Nothing when
-- none arrives in time).
receiveMailboxWithin :: Int -> Mailbox a -> IO (Maybe a)
receiveMailboxWithin micros mailbox@(Mailbox chan _) =
  timeout micros (readChan chan) >>= traverse (closedOr mailbox)

closedOr :: Mailbox a -> Maybe a -> IO a
closedOr (Mailbox chan _) item = case item of
  Just value -> pure value
  -- Leave the mark for any later receive.
  Nothing -> writeChan chan Nothing >> throwIO ActorStopped

-- | Refuses further messages; those already sent can still be received.
closeMailbox :: Mailbox a -> IO ()
closeMailbox (Mailbox chan closed) = do
  done <- atomicModifyIORef' closed (\d -> (True, d))
  if done then pure () else writeChan chan Nothing

-- Actor models: the generated callbacks are pure, so these run the actor's
-- IO inside them, each call its own effect.
actorStartCallback :: ModelCallback -> ModelCallback
actorStartCallback run symbols args = case run symbols args of
  Left message -> Left message
  Right state -> Right (unsafePerformIO (do
    _ <- evaluate (deepScalar state)
    actor <- newActor state
    SHandle "lawspec::actor" <$> handle actor))
{-# NOINLINE actorStartCallback #-}

actorCommandCallback :: Bool -> ModelCallback -> ModelCallback
actorCommandCallback unit run symbols args = case args of
  SHandle _ h : rest -> unsafePerformIO (do
    outcome <- try (callActor (fromHandle h :: Actor Scalar) (\state -> case run symbols (state : rest) of
      Left message -> throwIO (ModelRaised message)
      Right out -> do
        _ <- evaluate (deepScalar out)
        pure (if unit then (SAbsent "Unit", out) else (productField False out, productField True out))))
    pure (case outcome of
      Right reply -> Right reply
      Left e -> Left (case fromException e of
        Just (ActorCrashed cause) -> case fromException cause of
          Just (ModelRaised message) -> message
          _ -> exceptionText cause
        _ -> exceptionText e)))
  _ -> Left "an actor command needs its actor first"
{-# NOINLINE actorCommandCallback #-}

-- | An actor model's crash step: the actor restarts from the restart
-- command (its run on the system, its reference on the model) or, without
-- one, from the start with the run's start arguments.
actorCrashStep :: ModelCallback -> ModelCallback -> Maybe ModelCommand -> CrashStep
actorCrashStep startRun startModel restart = CrashStep system model
  where
    system startArgs symbols handleValue = case handleValue of
      SHandle _ h -> restartActor (fromHandle h :: Actor Scalar) (\state ->
        either (throwIO . ModelRaised) (\v -> evaluate (deepScalar v) >> pure v)
          (case restart of
            Just r -> mcRun r symbols [state]
            Nothing -> startRun symbols startArgs))
      _ -> throwIO (ModelRaised "an actor crash needs its actor")
    model startArgs symbols state = do
      out <- callModel (maybe (\s _ -> startModel s startArgs) mcReference restart) symbols [state]
      either (const (throwIO ModelInvalid)) pure out

actorStateCallback :: ModelCallback -> ModelCallback
actorStateCallback f symbols args = case args of
  [SHandle _ h] -> f symbols [unsafePerformIO (actorState (fromHandle h :: Actor Scalar))]
  _ -> f symbols args
{-# NOINLINE actorStateCallback #-}

-- Sessions: typed channel ends for implementation code. Each generated
-- protocol module (LawSpecSessions.*) wraps a SessionEnd in a type per step
-- and makes it an instance of Send or Receive, so steps out of order do not
-- compile; a SessionEnd is single use, so a stale end fails when used.

-- | One side of a channel, as a transport implements it: sending a value to
-- the other side and receiving the next value from it. localChannel joins two
-- sides in process; a network transport could implement the same record.
data ChannelSide = ChannelSide
  { sideSend :: Dynamic -> IO ()
  -- | The next value; throws PeerFailed once the other side has given up
  -- and nothing it sent is left.
  , sideReceive :: IO Dynamic
  -- | Gives up: the other side's receives fail after the values already sent.
  , sideAbandon :: IO ()
  }

-- | A receive whose other end gave up: its process failed, or it called
-- abandon. Catch it (or use tryReceive) to handle the failure; otherwise
-- this process fails too.
data PeerFailed = PeerFailed deriving Show
instance Exception PeerFailed

-- The mark a side that gave up leaves for the other.
data Abandoned = Abandoned

-- | Two connected sides, with one queue per direction.
localChannel :: IO (ChannelSide, ChannelSide)
localChannel = do
  forward <- newChan
  backward <- newChan
  let receiving chan = do
        message <- readChan chan
        case fromDynamic message of
          Just Abandoned -> writeChan chan message >> throwIO PeerFailed
          Nothing -> pure message
  pure ( ChannelSide (writeChan forward) (receiving backward) (writeChan forward (toDyn Abandoned))
       , ChannelSide (writeChan backward) (receiving forward) (writeChan backward (toDyn Abandoned)) )

-- | A channel side at one step of a protocol, usable once: each step returns
-- a fresh end for the next.
data SessionEnd = SessionEnd ChannelSide (IORef Bool)

-- | A channel's two ends, at their first step.
openSession :: IO (SessionEnd, SessionEnd)
openSession = do
  (first, second) <- localChannel
  (,) <$> sessionEnd first <*> sessionEnd second

sessionEnd :: ChannelSide -> IO SessionEnd
sessionEnd side = SessionEnd side <$> newIORef False

-- Marks an end used, failing if it already was, and returns its side.
useEnd :: SessionEnd -> IO ChannelSide
useEnd (SessionEnd side used) = do
  already <- atomicModifyIORef' used (\was -> (True, was))
  if already
    then throwIO (ErrorCall "this end was already used; use the end its last step returned")
    else pure side

-- | Sends a value on an end, wrapping the side's fresh end as the next step.
sendOn :: Typeable a => (SessionEnd -> next) -> SessionEnd -> a -> IO next
sendOn next end value = do
  side <- useEnd end
  sideSend side (toDyn value)
  next <$> sessionEnd side

-- | Receives a value on an end, with the side's fresh end as the next step.
receiveOn :: forall a next. Typeable a => (SessionEnd -> next) -> SessionEnd -> IO (a, next)
receiveOn next end = do
  side <- useEnd end
  message <- sideReceive side
  value <- maybe (throwIO (ErrorCall ("a session received " ++ show (dynTypeRep message)
    ++ " where it expected " ++ show (typeRep (Proxy :: Proxy a))))) pure (fromDynamic message)
  (,) value . next <$> sessionEnd side

-- | An end whose next step sends a message; the end type determines what it
-- sends and the end that follows.
class Send end message next | end -> message next where
  send :: end -> message -> IO next

-- | An end whose next step receives a message, returned with the end that
-- follows. receive throws PeerFailed when the other end gave up and nothing
-- it sent is left.
class Receive end message next | end -> message next where
  receive :: end -> IO (message, next)

-- | receive, with the other end's failure as a Left.
tryReceive :: Receive end message next => end -> IO (Either PeerFailed (message, next))
tryReceive end = try (receive end)

-- | An end that can give up its conversation: the other end's receives then
-- fail with PeerFailed, after the values already sent. A process that fails
-- while holding an end should abandon it (with finally or bracket), so the
-- other process does not wait for ever.
class Abandon end where
  abandon :: end -> IO ()

-- | Gives up the channel an end belongs to.
abandonEnd :: SessionEnd -> IO ()
abandonEnd end = useEnd end >>= sideAbandon

-- | A running thread whose result join waits for.
newtype Process a = Process (MVar (Either SomeException a))

-- | Runs an action in its own thread.
spawn :: IO a -> IO (Process a)
spawn action = do
  result <- newEmptyMVar
  _ <- forkIO (try action >>= putMVar result)
  pure (Process result)

-- | Waits for a process, rethrowing what it threw.
join :: Process a -> IO a
join (Process result) = readMVar result >>= either throwIO pure

-- | Runs actions in parallel and waits for all of them, rethrowing the first
-- failure in list order.
par :: [IO ()] -> IO ()
par actions = mapM spawn actions >>= mapM_ join
