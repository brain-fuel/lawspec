{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE UnboxedTuples #-}
-- | Portable unkeyed BLAKE3-256. The native and WASM builds share this pure
-- implementation, so their hashes agree. It follows goforge's blake3sum:
-- unboxed 32-bit state through an unrolled compression function, message
-- words read straight from the input, one compression for an input of one
-- block, and hashMany for the many small nodes of content identity.
-- ref:DEC-blake3-port
module LawSpec.Blake3 (blake3, blake3Hex, blake3Text, hashMany, hexOf) where

import Data.Bits (rotateR, shiftL, shiftR, xor, (.&.), (.|.), countTrailingZeros)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word8, Word32, Word64)

-- | A chaining value: eight words.
data CV = CV {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32
             {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32

-- | Sixteen words: a message block or the compression state.
data W16 = W16 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32
               {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32
               {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32
               {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32

-- | A node not yet compressed, kept so the root can be compressed with ROOT.
data Node = Node !CV !W16 {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32

iv :: CV
iv = CV 0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a 0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19

chunkStart, chunkEnd, parent, root :: Word32
chunkStart = 1
chunkEnd = 2
parent = 4
root = 8

-- | The BLAKE3 quarter-round, on four state words and two message words.
g :: Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> (# Word32, Word32, Word32, Word32 #)
g a0 b0 c0 d0 x y =
  let !a1 = a0 + b0 + x
      !d1 = rotateR (d0 `xor` a1) 16
      !c1 = c0 + d1
      !b1 = rotateR (b0 `xor` c1) 12
      !a2 = a1 + b1 + y
      !d2 = rotateR (d1 `xor` a2) 8
      !c2 = c1 + d2
      !b2 = rotateR (b1 `xor` c2) 7
  in (# a2, b2, c2, d2 #)
{-# INLINE g #-}

-- | One round: columns, then diagonals.
roundW :: W16 -> W16 -> W16
roundW (W16 s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15)
       (W16 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15) =
  case g s0 s4 s8 s12 m0 m1 of
   (# a0, a4, a8, a12 #) -> case g s1 s5 s9 s13 m2 m3 of
    (# a1, a5, a9, a13 #) -> case g s2 s6 s10 s14 m4 m5 of
     (# a2, a6, a10, a14 #) -> case g s3 s7 s11 s15 m6 m7 of
      (# a3, a7, a11, a15 #) -> case g a0 a5 a10 a15 m8 m9 of
       (# b0, b5, b10, b15 #) -> case g a1 a6 a11 a12 m10 m11 of
        (# b1, b6, b11, b12 #) -> case g a2 a7 a8 a13 m12 m13 of
         (# b2, b7, b8, b13 #) -> case g a3 a4 a9 a14 m14 m15 of
          (# b3, b4, b9, b14 #) -> W16 b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12 b13 b14 b15
{-# INLINE roundW #-}

-- | The message schedule's permutation between rounds.
permute :: W16 -> W16
permute (W16 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15) =
  W16 m2 m6 m3 m10 m7 m0 m4 m13 m1 m11 m12 m5 m9 m14 m15 m8
{-# INLINE permute #-}

-- | The compression function's full sixteen-word output.
compress :: Node -> W16
compress (Node cv@(CV c0 c1 c2 c3 c4 c5 c6 c7) m0 counter len flags) =
  let CV i0 i1 i2 i3 _ _ _ _ = iv
      !s0 = W16 c0 c1 c2 c3 c4 c5 c6 c7 i0 i1 i2 i3
                (fromIntegral counter) (fromIntegral (counter `shiftR` 32)) len flags
      !m1 = permute m0; !m2 = permute m1; !m3 = permute m2
      !m4 = permute m3; !m5 = permute m4; !m6 = permute m5
      !(W16 t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 t13 t14 t15) =
        roundW (roundW (roundW (roundW (roundW (roundW (roundW s0 m0) m1) m2) m3) m4) m5) m6
  in cv `seq` W16 (t0 `xor` t8) (t1 `xor` t9) (t2 `xor` t10) (t3 `xor` t11)
         (t4 `xor` t12) (t5 `xor` t13) (t6 `xor` t14) (t7 `xor` t15)
         (t8 `xor` c0) (t9 `xor` c1) (t10 `xor` c2) (t11 `xor` c3)
         (t12 `xor` c4) (t13 `xor` c5) (t14 `xor` c6) (t15 `xor` c7)

chaining :: Node -> CV
chaining node = case compress node of
  W16 a b c d e f g' h _ _ _ _ _ _ _ _ -> CV a b c d e f g' h
{-# INLINE chaining #-}

-- | The block of 64 bytes at an offset, zero padded past the end.
block :: B.ByteString -> Int -> W16
block bytes offset
  | offset + 64 <= B.length bytes = full
  | otherwise = padded
  where
    full = W16 (w 0) (w 1) (w 2) (w 3) (w 4) (w 5) (w 6) (w 7) (w 8) (w 9) (w 10) (w 11) (w 12) (w 13) (w 14) (w 15)
    w i = let o = offset + i * 4
          in fromIntegral (BU.unsafeIndex bytes o) .|. (fromIntegral (BU.unsafeIndex bytes (o + 1)) `shiftL` 8)
             .|. (fromIntegral (BU.unsafeIndex bytes (o + 2)) `shiftL` 16) .|. (fromIntegral (BU.unsafeIndex bytes (o + 3)) `shiftL` 24)
    padded = W16 (p 0) (p 1) (p 2) (p 3) (p 4) (p 5) (p 6) (p 7) (p 8) (p 9) (p 10) (p 11) (p 12) (p 13) (p 14) (p 15)
    p i = byte (i * 4) .|. (byte (i * 4 + 1) `shiftL` 8) .|. (byte (i * 4 + 2) `shiftL` 16) .|. (byte (i * 4 + 3) `shiftL` 24)
    byte i = let o = offset + i in if o < B.length bytes then fromIntegral (BU.unsafeIndex bytes o) else 0 :: Word32

-- | A chunk's last node, still to be compressed. A chunk is at most 1024
-- bytes; an empty input is one empty block.
chunkNode :: B.ByteString -> Int -> Int -> Word64 -> Node
chunkNode bytes start size counter = go iv start chunkStart
  where
    end = start + size
    go !cv !offset !flags
      | offset + 64 >= end =
          Node cv (block (B.take end bytes) offset) counter (fromIntegral (end - offset)) (flags .|. chunkEnd)
      | otherwise = go (chaining (Node cv (block bytes offset) counter 64 flags)) (offset + 64) 0

parentNode :: CV -> CV -> Node
parentNode (CV a0 a1 a2 a3 a4 a5 a6 a7) (CV b0 b1 b2 b3 b4 b5 b6 b7) =
  Node iv (W16 a0 a1 a2 a3 a4 a5 a6 a7 b0 b1 b2 b3 b4 b5 b6 b7) 0 64 parent

-- | The root node: every chunk but the last is merged into a stack of
-- subtree chaining values as BLAKE3's reference implementation does; the
-- last chunk's node is then folded with the stack, top first.
rootNode :: B.ByteString -> Node
rootNode bytes = finish (go [] 0)
  where
    count = max 1 ((B.length bytes + 1023) `div` 1024)
    go stack index
      | index == count - 1 = (stack, chunkNode bytes (index * 1024) (B.length bytes - index * 1024) (fromIntegral index))
      | otherwise =
          let cv = chaining (chunkNode bytes (index * 1024) 1024 (fromIntegral index))
          in go (merge stack cv (countTrailingZeros (fromIntegral (index + 1) :: Word64))) (index + 1)
    -- A completed chunk closes one subtree per trailing zero of the count.
    merge stack cv 0 = cv : stack
    merge (left : rest) cv n = merge rest (chaining (parentNode left cv)) (n - 1 :: Int)
    merge [] cv _ = [cv]
    finish (stack, node) = foldl (\right left -> parentNode left (chaining right)) node stack

-- | The 32-byte digest of some bytes.
blake3 :: B.ByteString -> B.ByteString
blake3 bytes = case rootNode bytes of
  Node cv m counter len flags -> case compress (Node cv m counter len (flags .|. root)) of
    W16 a b c d e f g' h _ _ _ _ _ _ _ _ -> littleEndian [a, b, c, d, e, f, g', h]
  where
    littleEndian ws = B.pack [fromIntegral (w `shiftR` n) :: Word8 | w <- ws, n <- [0, 8, 16, 24]]

-- | Many inputs at once, in order: the batch form for content identity.
-- blake3sum spreads the same call across cores; the WASM build has no
-- threads, so this one forces each digest in turn.
hashMany :: [B.ByteString] -> [B.ByteString]
hashMany = foldr (\input rest -> let !d = blake3 input in d : rest) []

-- | Lower-case hexadecimal.
hexOf :: B.ByteString -> String
hexOf = B.foldr (\w rest -> digit (w `shiftR` 4) : digit (w .&. 15) : rest) ""
  where digit n = "0123456789abcdef" !! fromIntegral n

blake3Hex :: B.ByteString -> String
blake3Hex = hexOf . blake3

blake3Text :: String -> String
blake3Text = blake3Hex . T.encodeUtf8 . T.pack
