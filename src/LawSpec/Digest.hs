{-# LANGUAGE BangPatterns #-}
-- | SHA-256 (FIPS 180-4) in plain Haskell, so the compiler can name content by
-- digest on every platform, including the WebAssembly build, without a C
-- dependency. Digests key the incremental compiler's memo tables.
module LawSpec.Digest (Digest, digest, digestString, digestHex, digestBytes) where

import Control.Monad (forM_)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (newArray, runSTUArray)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word32, Word64)
import Text.Printf (printf)

-- | A SHA-256 digest as eight big-endian words.
data Digest = Digest !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32
  deriving (Eq, Ord)

instance Show Digest where
  show = digestHex

-- | Cache keys are file names and JSON strings, so a digest is shown as text.
-- ref:DEC-incremental-compilation
digestHex :: Digest -> String
digestHex (Digest a b c d e f g h) = concatMap (printf "%08x") [a, b, c, d, e, f, g, h]

-- | Composite keys hash the bytes of other digests, which is cheaper and
-- unambiguous compared with hashing their hex text.
digestBytes :: Digest -> B.ByteString
digestBytes (Digest a b c d e f g h) = B.pack (concatMap word [a, b, c, d, e, f, g, h])
  where word w = [fromIntegral (w `shiftR` s) | s <- [24, 16, 8, 0]]

-- | The digest of text, encoded as UTF-8.
digestString :: String -> Digest
digestString = digest . T.encodeUtf8 . T.pack

-- | SHA-256 written in Haskell, because the WASM build cannot link a C hash
-- library and the native and WASM compilers must agree on every cache key.
-- ref:DEC-wasm-distribution
digest :: B.ByteString -> Digest
digest message = go initial 0
  where
    len = B.length message
    bitLength = fromIntegral len * 8 :: Word64
    zeros = (55 - len) `mod` 64
    padded = B.concat [message, B.singleton 0x80, B.replicate zeros 0, B.pack [fromIntegral (bitLength `shiftR` s) | s <- [56, 48 .. 0]]]
    blocks = B.length padded `div` 64
    go !state i
      | i >= blocks = finish state
      | otherwise = go (block state padded (64 * i)) (i + 1)
    finish (State a b c d e f g h) = Digest a b c d e f g h

data State = State !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32

initial :: State
initial = State 0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a 0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19

-- | One 64-byte block at an offset: expand the message schedule into an
-- unboxed array, then run the 64 rounds over strict registers.
block :: State -> B.ByteString -> Int -> State
block (State h0 h1 h2 h3 h4 h5 h6 h7) bytes offset = rounds 0 h0 h1 h2 h3 h4 h5 h6 h7
  where
    byte i = fromIntegral (BU.unsafeIndex bytes (offset + i)) :: Word32
    word i = byte (4 * i) `shiftL` 24 .|. byte (4 * i + 1) `shiftL` 16 .|. byte (4 * i + 2) `shiftL` 8 .|. byte (4 * i + 3)
    schedule :: UArray Int Word32
    schedule = runSTUArray $ do
      w <- newArray (0, 63) 0
      forM_ [0 .. 15] $ \i -> unsafeWrite w i (word i)
      forM_ [16 .. 63] $ \i -> do
        w2 <- unsafeRead w (i - 2)
        w7 <- unsafeRead w (i - 7)
        w15 <- unsafeRead w (i - 15)
        w16 <- unsafeRead w (i - 16)
        unsafeWrite w i (sigma1 w2 + w7 + sigma0 w15 + w16)
      pure w
    sigma0 x = rotateR x 7 `xor` rotateR x 18 `xor` shiftR x 3
    sigma1 x = rotateR x 17 `xor` rotateR x 19 `xor` shiftR x 10
    rounds :: Int -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> State
    rounds !i !a !b !c !d !e !f !g !h
      | i == 64 = State (h0 + a) (h1 + b) (h2 + c) (h3 + d) (h4 + e) (h5 + f) (h6 + g) (h7 + h)
      | otherwise =
          let s1 = rotateR e 6 `xor` rotateR e 11 `xor` rotateR e 25
              choice = (e .&. f) `xor` (complement e .&. g)
              t1 = h + s1 + choice + unsafeAt constants i + unsafeAt schedule i
              s0 = rotateR a 2 `xor` rotateR a 13 `xor` rotateR a 22
              majority = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
          in rounds (i + 1) (t1 + s0 + majority) a b c (d + t1) e f g

constants :: UArray Int Word32
constants = listArray (0, 63) roundConstants

roundConstants :: [Word32]
roundConstants =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 ]
