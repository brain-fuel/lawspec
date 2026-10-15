{-# LANGUAGE BangPatterns #-}
-- | Portable unkeyed BLAKE3-256 for structural identities. This implementation
-- is shared by native and WASM; unrelated incremental caches retain SHA-256.
module LawSpec.Blake3 (blake3, blake3Hex, blake3Text) where

import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Data.Array.ST (STUArray, newListArray, readArray, writeArray, getElems, runSTUArray)
import Data.Array.Unboxed (UArray, elems)
import Data.Bits (rotateR, shiftR, shiftL, xor, (.|.))
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word32, Word64)
import Text.Printf (printf)

iv :: [Word32]
iv = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
data Output = Output [Word32] [Word32] Word64 Word32 Word32

-- | The root output uses counter zero and the ROOT flag. Chaining values are
-- intermediate nodes, never the digest itself.
blake3 :: B.ByteString -> B.ByteString
blake3 bytes = B.pack (concatMap little (take 8 (compress root)))
  where
    count = max 1 ((B.length bytes + 1023) `div` 1024)
    tree offset chunks
      | chunks == 1 = chunk (fromIntegral offset) (B.take 1024 (B.drop (offset * 1024) bytes))
      | otherwise = let leftCount = last (takeWhile (< chunks) (iterate (* 2) 1))
                        left = chaining (tree offset leftCount)
                        right = chaining (tree (offset + leftCount) (chunks - leftCount))
                    in Output iv (left ++ right) 0 64 4
    Output cv block _ len flags = tree 0 count
    root = Output cv block 0 len (flags .|. 8)
    little word = [fromIntegral (word `shiftR` n) | n <- [0,8,16,24]]

blake3Hex :: B.ByteString -> String
blake3Hex = concatMap (printf "%02x") . B.unpack . blake3
blake3Text :: String -> String
blake3Text = blake3Hex . T.encodeUtf8 . T.pack

chaining :: Output -> [Word32]
chaining = take 8 . compress
chunk :: Word64 -> B.ByteString -> Output
chunk counter bytes = go iv 0
  where
    blocks = max 1 ((B.length bytes + 63) `div` 64)
    go !cv index =
      let payload = B.take 64 (B.drop (index * 64) bytes)
          start = if index == 0 then 1 else 0
          end = if index == blocks - 1 then 2 else 0
          output = Output cv (wordsLE payload) counter (fromIntegral (B.length payload)) (start .|. end)
      in if index == blocks - 1 then output else go (chaining output) (index + 1)
wordsLE :: B.ByteString -> [Word32]
wordsLE bytes = [foldl (.|.) 0 [byte (i * 4 + j) `shiftL` (j * 8) | j <- [0..3]] | i <- [0..15]]
  where byte index = if index < B.length bytes then fromIntegral (B.index bytes index) else 0

compress :: Output -> [Word32]
compress (Output cv message counter len flags) = elems result
  where
    result :: UArray Int Word32
    result = runSTUArray $ do
      state <- newListArray (0,15) (cv ++ take 4 iv ++ [fromIntegral counter, fromIntegral (counter `shiftR` 32), len, flags])
      let round' m = do
            forM_ [(0,4,8,12,0,1),(1,5,9,13,2,3),(2,6,10,14,4,5),(3,7,11,15,6,7),
                   (0,5,10,15,8,9),(1,6,11,12,10,11),(2,7,8,13,12,13),(3,4,9,14,14,15)] $
              \(a,b,c,d,x,y) -> mix state a b c d (m !! x) (m !! y)
      forM_ (take 7 (iterate permute message)) round'
      values <- getElems state
      forM_ [0..7] $ \i -> do
        writeArray state i (values !! i `xor` values !! (i+8))
        writeArray state (i+8) (values !! (i+8) `xor` cv !! i)
      pure state
    permute m = map (m !!) [2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8]
mix :: STUArray s Int Word32 -> Int -> Int -> Int -> Int -> Word32 -> Word32 -> ST s ()
mix state a b c d x y = do
  av <- readArray state a; bv <- readArray state b
  cv <- readArray state c; dv <- readArray state d
  let a1 = av + bv + x
      d1 = rotateR (dv `xor` a1) 16
      c1 = cv + d1
      b1 = rotateR (bv `xor` c1) 12
      a2 = a1 + b1 + y
      d2 = rotateR (d1 `xor` a2) 8
      c2 = c1 + d2
      b2 = rotateR (b1 `xor` c2) 7
  writeArray state a a2; writeArray state b b2
  writeArray state c c2; writeArray state d d2
