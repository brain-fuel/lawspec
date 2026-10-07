{-# LANGUAGE BangPatterns, ScopedTypeVariables #-}
-- SHA3-256 (FIPS 202) in plain Haskell, so content hashes that leave the
-- compiler (a remote definition's hash, which nodes compare) name a
-- post-quantum-era hash on every platform, the WebAssembly build included.
module LawSpec.Sha3 (sha3_256, sha3_256Hex, sha3_256String) where

import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray)
import Data.Array.Unboxed (UArray, elems, listArray)
import Data.Bits (complement, rotateL, shiftL, shiftR, xor, (.&.))
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word64, Word8)
import Text.Printf (printf)

-- The 32-byte digest.
sha3_256 :: B.ByteString -> B.ByteString
sha3_256 message = B.pack (take 32 (concatMap bytes (take 4 (elems (absorb padded)))))
  where
    rate = 136
    -- SHA-3's domain bits (01) and pad10*1.
    padLength = rate - B.length message `mod` rate
    padded
      | padLength == 1 = message <> B.singleton 0x86
      | otherwise = B.concat [message, B.singleton 0x06, B.replicate (padLength - 2) 0, B.singleton 0x80]
    bytes w = [fromIntegral (w `shiftR` (8 * i)) :: Word8 | i <- [0 .. 7]]

sha3_256Hex :: B.ByteString -> String
sha3_256Hex = concatMap (printf "%02x") . B.unpack . sha3_256

-- The digest of text, encoded as UTF-8, in hexadecimal.
sha3_256String :: String -> String
sha3_256String = sha3_256Hex . T.encodeUtf8 . T.pack

absorb :: B.ByteString -> UArray Int Word64
absorb input = runSTUArray $ do
  state <- newArray (0, 24) 0
  let blocks = B.length input `div` 136
  forM_ [0 .. blocks - 1] $ \b -> do
    forM_ [0 .. 16] $ \i -> do
      let lane = laneAt input (b * 136 + i * 8)
      v <- unsafeRead state i
      unsafeWrite state i (v `xor` lane)
    keccak state
  pure state

laneAt :: B.ByteString -> Int -> Word64
laneAt bs offset = go 7 0
  where
    go :: Int -> Word64 -> Word64
    go i !acc
      | i < 0 = acc
      | otherwise = go (i - 1) ((acc `shiftL` 8) + fromIntegral (B.index bs (offset + i)))

keccak :: forall s. STUArray s Int Word64 -> ST s ()
keccak a = forM_ [0 .. 23] $ \r -> do
  -- theta
  c <- mapM (\x -> do
    vs <- mapM (\y -> unsafeRead a (x + 5 * y)) [0 .. 4]
    pure (foldr1 xor vs)) [0 .. 4]
  let cArr = listArray (0, 4) c :: UArray Int Word64
      d x = (cArr `unsafeAt` ((x + 4) `mod` 5)) `xor` rotateL (cArr `unsafeAt` ((x + 1) `mod` 5)) 1
  forM_ [0 .. 4] $ \x -> let dx = d x in forM_ [0 .. 4] $ \y -> do
    v <- unsafeRead a (x + 5 * y)
    unsafeWrite a (x + 5 * y) (v `xor` dx)
  -- rho and pi
  b <- newArray (0, 24) 0 :: ST s (STUArray s Int Word64)
  forM_ [0 .. 4] $ \x -> forM_ [0 .. 4] $ \y -> do
    v <- unsafeRead a (x + 5 * y)
    let x' = y
        y' = (2 * x + 3 * y) `mod` 5
    unsafeWrite b (x' + 5 * y') (rotateL v (rotations `unsafeAt` (x + 5 * y)))
  -- chi
  forM_ [0 .. 4] $ \y -> forM_ [0 .. 4] $ \x -> do
    v0 <- unsafeRead b (x + 5 * y)
    v1 <- unsafeRead b ((x + 1) `mod` 5 + 5 * y)
    v2 <- unsafeRead b ((x + 2) `mod` 5 + 5 * y)
    unsafeWrite a (x + 5 * y) (v0 `xor` (complement v1 .&. v2))
  -- iota
  v <- unsafeRead a 0
  unsafeWrite a 0 (v `xor` (roundConstants `unsafeAt` r))

rotations :: UArray Int Int
rotations = listArray (0, 24)
  [ 0, 1, 62, 28, 27
  , 36, 44, 6, 55, 20
  , 3, 10, 43, 25, 39
  , 41, 45, 15, 21, 8
  , 18, 2, 61, 56, 14 ]

roundConstants :: UArray Int Word64
roundConstants = listArray (0, 23)
  [ 0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000
  , 0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009
  , 0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A
  , 0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003
  , 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A
  , 0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008 ]
