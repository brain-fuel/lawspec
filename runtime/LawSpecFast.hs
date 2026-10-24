{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Typed values for generated checked definitions and stateful spec
-- handlers.
--
-- A definition whose types all have a typed form runs over these instead of
-- the dynamic Scalar: the scalars are Haskell's own (Int8 to Word64,
-- Integer, Text, ByteString), and lists, Maybe and Either are the strict
-- types below; KeyVal and Set are Data.Map.Strict and Data.Set, persistent
-- trees whose updates copy only the path to a key. Generated data types are
-- strict too, with their constructors declared in the portable order, so
-- the derived Eq and Ord are LawSpec's equality and order, and a value is
-- fully evaluated once it is built. Typed definitions run in IO, so an
-- operation of another ability happens exactly where it is written. A
-- handler's state is shared, never copied, from one operation to the next.
-- The generated LawSpecTyped converts each typed value to and from Scalar
-- where typed and dynamic code meet. ref:DEC-typed-native-definitions
module LawSpecFast where

import Control.Exception (ErrorCall (..), catch, evaluate, throw, throwIO, try)
import qualified Data.ByteString as B
import Data.Char (chr, ord)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Typeable (Typeable, cast)
import Data.Word (Word8)
import LawSpecRuntime (Fail (..), Failure (..), Scalar (..))
import qualified LawSpecRuntime as LS

-- | A list that shares its tail and knows its length.
data List a = Nil | Cons !a !(List a) {-# UNPACK #-} !Int
  deriving (Eq, Ord)

data Opt a = None | Some !a
  deriving (Eq, Ord)

data Alt a b = L !a | R !b
  deriving (Eq, Ord)

cons :: a -> List a -> List a
cons h t = Cons h t (len t + 1)
{-# INLINE cons #-}

len :: List a -> Int
len Nil = 0
len (Cons _ _ n) = n
{-# INLINE len #-}

listOf :: [a] -> List a
listOf = foldr cons Nil

items :: List a -> [a]
items Nil = []
items (Cons h t _) = h : items t

unreachable :: IO a
unreachable = throwIO (ErrorCall "unreachable branch reached")

outside :: String -> a
outside t = throw (ErrorCall ("integer outside " ++ t ++ " range"))

-- | An Integer into a bounded type, checked.
narrow :: (Num b) => Integer -> Integer -> String -> Integer -> b
narrow lo hi t v
  | v < lo || v > hi = outside t
  | otherwise = fromInteger v
{-# INLINE narrow #-}

quot' :: Integer -> Integer -> Integer
quot' _ 0 = throw (ErrorCall "exact division by zero")
quot' a b = quot a b

rem' :: Integer -> Integer -> Integer
rem' _ 0 = throw (ErrorCall "exact division by zero")
rem' a b = rem a b

power :: Integer -> Integer -> Integer
power a b
  | b < 0 = throw (ErrorCall "negative exponent")
  | b > 2147483648 = throw (ErrorCall "exponent too large")
  | otherwise = a ^ b

-- Sequences.

bounds :: Integer -> Integer -> Int -> (Int, Int)
bounds from to count =
  let clamp x = if x < 0 then 0 else if x > toInteger count then count else fromInteger x
      i = clamp from
      j = clamp to
   in (i, if j < i then i else j)

append :: List a -> List a -> List a
append a b = foldr cons b (items a)

sliceList :: List a -> Integer -> Integer -> List a
sliceList xs from to =
  let count = len xs
      (i, j) = bounds from to count
      rest = dropList i xs
   in if j == count then rest else listOf (take (j - i) (items rest))
  where
    dropList 0 ys = ys
    dropList _ Nil = Nil
    dropList k (Cons _ t _) = dropList (k - 1 :: Int) t

sliceText :: T.Text -> Integer -> Integer -> T.Text
sliceText s from to = let (i, j) = bounds from to (T.length s) in T.take (j - i) (T.drop i s)

sliceBytes :: B.ByteString -> Integer -> Integer -> B.ByteString
sliceBytes s from to = let (i, j) = bounds from to (B.length s) in B.take (j - i) (B.drop i s)

atList :: List a -> Integer -> Opt a
atList xs i
  | i < 0 || i >= toInteger (len xs) = None
  | otherwise = go (fromInteger i) xs
  where
    go :: Int -> List a -> Opt a
    go 0 (Cons h _ _) = Some h
    go k (Cons _ t _) = go (k - 1) t
    go _ Nil = None

atBytes :: B.ByteString -> Integer -> Opt Word8
atBytes s i
  | i < 0 || i >= toInteger (B.length s) = None
  | otherwise = Some (B.index s (fromInteger i))

range :: (Integral a) => a -> a -> List a
range lo hi = if hi <= lo then Nil else listOf [lo .. hi - 1]

octets :: B.ByteString -> List Word8
octets = listOf . B.unpack

bytesOf :: List Word8 -> B.ByteString
bytesOf = B.pack . items

utf8 :: T.Text -> B.ByteString
utf8 t = B.pack (concatMap encode (T.unpack t))
  where
    encode c
      | n < 0x80 = [fromIntegral n]
      | n < 0x800 = [fromIntegral (0xc0 + n `div` 64), fromIntegral (0x80 + n `mod` 64)]
      | n < 0x10000 = [fromIntegral (0xe0 + n `div` 4096), fromIntegral (0x80 + (n `div` 64) `mod` 64), fromIntegral (0x80 + n `mod` 64)]
      | otherwise = [fromIntegral (0xf0 + n `div` 262144), fromIntegral (0x80 + (n `div` 4096) `mod` 64), fromIntegral (0x80 + (n `div` 64) `mod` 64), fromIntegral (0x80 + n `mod` 64)]
      where
        n = ord c

join :: T.Text -> List T.Text -> T.Text
join separator parts = T.intercalate separator (items parts)

regexMatches :: T.Text -> T.Text -> Bool
regexMatches pattern text = either error id (LS.regexMatches (T.unpack pattern) (map ord (T.unpack text)))

textOf :: (Show a) => a -> T.Text
textOf = T.pack . show

-- Maps and sets.

lookupMap :: (Ord k) => k -> Map.Map k v -> Opt v
lookupMap k m = maybe None Some (Map.lookup k m)

keyValOf :: (Ord k) => (e -> k) -> (e -> v) -> List e -> Map.Map k v
keyValOf key value = foldl (\m e -> Map.insert (key e) (value e) m) Map.empty . items

keysList :: Map.Map k v -> List k
keysList = listOf . Map.keys

valuesList :: Map.Map k v -> List v
valuesList = listOf . Map.elems

entriesList :: (k -> v -> e) -> Map.Map k v -> List e
entriesList entry = listOf . map (uncurry entry) . Map.toAscList

setOf :: (Ord a) => List a -> Set.Set a
setOf = Set.fromList . items

-- Failures, as the dynamic code raises and catches them.

raise :: String -> Scalar -> IO a
raise ability value = throwIO (Failure ability value)

-- | attempt e: Right of e's value, or Left of the failure it raised with
-- this ability.
attempt :: String -> IO a -> IO (Either Scalar a)
attempt ability body = do
  outcome <- try (body >>= evaluate)
  case outcome of
    Right value -> pure (Right value)
    Left failure@(Failure raised value)
      | raised == ability -> pure (Left value)
      | otherwise -> throwIO failure

-- | A native handler's operation that fails with E: the native failure it
-- throws becomes the failure.
performing :: forall e a. (Typeable e) => String -> (e -> Scalar) -> IO a -> IO a
performing ability convert action =
  action `catch` \problem@(Fail native) -> case cast native of
    Just (value :: e) -> throwIO (Failure ability (convert value))
    Nothing -> throwIO problem

-- Conversions with Scalar.

textScalar :: T.Text -> Scalar
textScalar t = SSequence "Text" (map ord (T.unpack t))

scalarText :: Scalar -> T.Text
scalarText (SSequence _ units) = T.pack (map chr units)
scalarText _ = error "expected Text"

bytesScalar :: B.ByteString -> Scalar
bytesScalar b = SSequence "Bytes" (map fromIntegral (B.unpack b))

scalarBytes :: Scalar -> B.ByteString
scalarBytes (SSequence _ units) = B.pack (map fromIntegral units)
scalarBytes _ = error "expected Bytes"

scalarInteger :: Scalar -> Integer
scalarInteger (SInteger _ n) = n
scalarInteger _ = error "expected an integer"

scalarBool :: Scalar -> Bool
scalarBool (SBool b) = b
scalarBool _ = error "expected Bool"

scalarItems :: Scalar -> [Scalar]
scalarItems (SList xs) = xs
scalarItems _ = error "expected List"

-- | A data value's single field: a KeyVal's or a Set's items.
onlyField :: Scalar -> Scalar
onlyField (SData _ [field]) = field
onlyField _ = error "expected a value of one field"

scalarData :: Scalar -> (String, [Scalar])
scalarData (SData tag fields) = (tag, fields)
scalarData _ = error "expected data"
