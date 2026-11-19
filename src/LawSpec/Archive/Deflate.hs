{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

-- | DEFLATE (RFC 1951) and gzip (RFC 1952) in pure Haskell, for the package
-- archives lawspec package writes and lawspec fetch unpacks.
--
-- 'gzip' is a transcription of zlib 1.2.12's deflate at the default level
-- (6: lazy matching, good 8, lazy 16, nice 128, chain 128; a 32 KiB window
-- and memLevel 8), so that an archive is byte-identical to the one Node's
-- zlib, built against that zlib, writes for the same input. Every decision
-- that shapes the output (the hash chains and their limits, lazy
-- evaluation, the 16383-symbol blocks, Huffman tree construction with its
-- depth tie-break and length-limiting, and the stored/fixed/dynamic block
-- choice) follows deflate.c and trees.c; the bits are written least
-- significant first exactly as zlib's 16-bit buffer emits them. The gzip
-- header is minizlib's portable one: no name, mtime 0, and OS byte 255.
--
-- 'gunzip' and 'inflate' decode any valid stream (stored, fixed and
-- dynamic blocks, concatenated gzip members) and refuse a malformed one
-- with a message; they never read past the input or write past what the
-- stream describes.
-- ref:DEC-haskell-application-port
module LawSpec.Archive.Deflate
  ( gzip,
    deflate,
    gunzip,
    inflate,
    crc32,
  )
where

import Control.Monad (forM_, unless, when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, getBounds, newArray, newListArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.STRef (STRef, modifySTRef', newSTRef, readSTRef, writeSTRef)
import Data.Word (Word32, Word8)

-- * CRC-32

crcTable :: UArray Int Word32
crcTable = listArray (0, 255) [entry (fromIntegral n) (8 :: Int) | n <- [0 .. 255 :: Int]]
  where
    entry c 0 = c
    entry c k = entry (if c .&. 1 /= 0 then 0xedb88320 `xor` (c `shiftR` 1) else c `shiftR` 1) (k - 1)

-- | The CRC-32 of gzip and zlib.
crc32 :: B.ByteString -> Word32
crc32 = complement . B.foldl' step 0xffffffff
  where
    step c byte = (crcTable ! fromIntegral ((c `xor` fromIntegral byte) .&. 0xff)) `xor` (c `shiftR` 8)

-- * Growable byte output

data Output s = Output (STRef s (STUArray s Int Word8)) (STRef s Int)

newOutput :: Int -> ST s (Output s)
newOutput size = do
  array <- newArray (0, max 16 size - 1) 0
  Output <$> newSTRef array <*> newSTRef 0

putByte :: Output s -> Int -> ST s ()
putByte (Output ref count) value = do
  array <- readSTRef ref
  n <- readSTRef count
  (_, top) <- getBounds array
  array' <-
    if n > top
      then do
        bigger <- newArray (0, 2 * (top + 1) - 1) 0
        forM_ [0 .. top] $ \i -> unsafeRead array i >>= unsafeWrite bigger i
        writeSTRef ref bigger
        pure bigger
      else pure array
  unsafeWrite array' n (fromIntegral value)
  writeSTRef count (n + 1)

outputByte :: Output s -> Int -> ST s Word8
outputByte (Output ref _) i = readSTRef ref >>= \array -> unsafeRead array i

outputLength :: Output s -> ST s Int
outputLength (Output _ count) = readSTRef count

freeze :: Output s -> ST s B.ByteString
freeze output = do
  n <- outputLength output
  bytes <- mapM (outputByte output) [0 .. n - 1]
  pure (B.pack bytes)

-- * Static tables (trees.c tr_static_init)

lCodes, dCodes, blCodes, heapSize, literals, endBlock, maxBits, maxBlBits :: Int
lCodes = 286
dCodes = 30
blCodes = 19
heapSize = 2 * lCodes + 1
literals = 256
endBlock = 256
maxBits = 15
maxBlBits = 7

rep3to6, repz3to10, repz11to138 :: Int
rep3to6 = 16
repz3to10 = 17
repz11to138 = 18

extraLbits, extraDbits, extraBlbits, blOrder :: UArray Int Int
extraLbits = listArray (0, 28) [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
extraDbits = listArray (0, 29) [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
extraBlbits = listArray (0, 18) (replicate 16 0 ++ [2, 3, 7])
blOrder = listArray (0, 18) [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

baseLength, lengthCode, baseDist, distCode :: UArray Int Int
baseLength = listArray (0, 28) (init (scanl (+) 0 [1 `shiftL` (extraLbits ! code) | code <- [0 .. 27]]) ++ [0])
lengthCode = listArray (0, 255) (take 255 (concat [replicate (1 `shiftL` (extraLbits ! code)) code | code <- [0 .. 27]]) ++ [28])
baseDist =
  listArray (0, 29) $
    take 16 (scanl (+) 0 [1 `shiftL` (extraDbits ! code) | code <- [0 .. 15]])
      ++ take 14 [(d `shiftL` 7) | d <- scanl (+) 2 [1 `shiftL` ((extraDbits ! code) - 7) | code <- [16 .. 29]]]
distCode =
  listArray (0, 511) $
    concat [replicate (1 `shiftL` (extraDbits ! code)) code | code <- [0 .. 15]]
      ++ [0, 0]
      ++ concat [replicate (1 `shiftL` ((extraDbits ! code) - 7)) code | code <- [16 .. 29]]

dCode :: Int -> Int
dCode dist = if dist < 256 then distCode ! dist else distCode ! (256 + (dist `shiftR` 7))

reverseBits :: Int -> Int -> Int
reverseBits code len = go code len 0
  where
    go _ 0 acc = acc
    go c n acc = go (c `shiftR` 1) (n - 1) ((acc `shiftL` 1) .|. (c .&. 1))

-- | gen_codes: canonical codes, bit-reversed, for the given lengths.
canonicalCodes :: [Int] -> [Int]
canonicalCodes lens = reverse (snd (foldl assign (initial, []) lens))
  where
    counts = 0 : [length (filter (== bits) lens) | bits <- [1 .. maxBits]]
    initial = scanl (\code bits -> (code + counts !! (bits - 1)) `shiftL` 1) 0 [1 .. maxBits]
    assign (next, acc) len
      | len == 0 = (next, 0 : acc)
      | otherwise =
          let code = next !! len
           in (take len next ++ [code + 1] ++ drop (len + 1) next, reverseBits code len : acc)

staticLtreeLen, staticLtreeCode, staticDtreeLen, staticDtreeCode :: UArray Int Int
staticLtreeLen = listArray (0, 287) (replicate 144 8 ++ replicate 112 9 ++ replicate 24 7 ++ replicate 8 8)
staticLtreeCode = listArray (0, 287) (canonicalCodes (replicate 144 8 ++ replicate 112 9 ++ replicate 24 7 ++ replicate 8 8))
staticDtreeLen = listArray (0, 29) (replicate 30 5)
staticDtreeCode = listArray (0, 29) [reverseBits n 5 | n <- [0 .. 29]]

-- * Deflate state (deflate.c)

wSize, wMask, windowSize, hashMask, hashShift, minMatch, maxMatch, minLookahead, maxDist, tooFar, winInit, litBufsize :: Int
wSize = 32768
wMask = wSize - 1
windowSize = 2 * wSize
hashMask = 32767
hashShift = 5
minMatch = 3
maxMatch = 258
minLookahead = maxMatch + minMatch + 1
maxDist = wSize - minLookahead
tooFar = 4096
winInit = maxMatch
litBufsize = 16384

goodMatch, maxLazyMatch, niceMatchDefault, maxChainLength :: Int
goodMatch = 8
maxLazyMatch = 16
niceMatchDefault = 128
maxChainLength = 128

-- | One Huffman tree of trees.c: frequencies (later codes) and dads (later
-- lengths) as zlib's unions, kept as separate arrays.
data Tree s = Tree
  { treeFreq :: STUArray s Int Int,
    treeLen :: STUArray s Int Int,
    treeCode :: STUArray s Int Int,
    treeDad :: STUArray s Int Int,
    treeMaxCode :: STRef s Int
  }

data Desc = Desc
  { descStaticLen :: Maybe (UArray Int Int),
    descExtra :: UArray Int Int,
    descExtraBase :: Int,
    descElems :: Int,
    descMaxLength :: Int
  }

lDesc, dDesc, blDesc :: Desc
lDesc = Desc (Just staticLtreeLen) extraLbits (literals + 1) lCodes maxBits
dDesc = Desc (Just staticDtreeLen) extraDbits 0 dCodes maxBits
blDesc = Desc Nothing extraBlbits 0 blCodes maxBlBits

data S s = S
  { sInput :: B.ByteString,
    sNext :: STRef s Int,
    sWindow :: STUArray s Int Int,
    sPrev :: STUArray s Int Int,
    sHead :: STUArray s Int Int,
    sInsH :: STRef s Int,
    sStrstart :: STRef s Int,
    sBlockStart :: STRef s Int,
    sLookahead :: STRef s Int,
    sInsert :: STRef s Int,
    sMatchStart :: STRef s Int,
    sMatchLength :: STRef s Int,
    sPrevLength :: STRef s Int,
    sPrevMatch :: STRef s Int,
    sMatchAvailable :: STRef s Bool,
    sHighWater :: STRef s Int,
    sSymDist :: STUArray s Int Int,
    sSymLc :: STUArray s Int Int,
    sSymNext :: STRef s Int,
    sLtree :: Tree s,
    sDtree :: Tree s,
    sBltree :: Tree s,
    sHeap :: STUArray s Int Int,
    sHeapLen :: STRef s Int,
    sHeapMax :: STRef s Int,
    sDepth :: STUArray s Int Int,
    sBlCount :: STUArray s Int Int,
    sOptLen :: STRef s Int,
    sStaticLen :: STRef s Int,
    sOut :: Output s,
    sBiBuf :: STRef s Int,
    sBiValid :: STRef s Int
  }

newTree :: Int -> ST s (Tree s)
newTree size = Tree <$> newArray (0, size - 1) 0 <*> newArray (0, size - 1) 0 <*> newArray (0, size - 1) 0 <*> newArray (0, size - 1) 0 <*> newSTRef 0

-- | Raw DEFLATE of the whole input, as zlib's deflate at level 6 writes it.
deflate :: B.ByteString -> B.ByteString
deflate input = runST $ do
  s <- newState input
  deflateSlow s
  freeze (sOut s)

-- | gzip as minizlib's portable Gzip writes it: zlib's header (no flags,
-- mtime 0, xfl 0) with the OS byte set to 255, the level-6 stream, then
-- the CRC-32 and the length modulo 2^32, both little-endian.
gzip :: B.ByteString -> B.ByteString
gzip input = B.concat [B.pack [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255], deflate input, word32 (crc32 input), word32 (fromIntegral (B.length input))]
  where
    word32 :: Word32 -> B.ByteString
    word32 w = B.pack [fromIntegral (w `shiftR` shift) | shift <- [0, 8, 16, 24]]

newState :: B.ByteString -> ST s (S s)
newState input = do
  window <- newArray (0, windowSize - 1) 0
  prev <- newArray (0, wSize - 1) 0
  hashHead <- newArray (0, hashMask) 0
  let zero = newSTRef 0
  next <- zero
  insH <- zero
  strstart <- zero
  blockStart <- zero
  lookahead <- zero
  insert <- zero
  matchStart <- zero
  highWater <- zero
  symNext <- zero
  heapLen <- zero
  heapMax <- zero
  optLen <- zero
  staticLen <- zero
  biBuf <- zero
  biValid <- zero
  matchLength <- newSTRef (minMatch - 1)
  prevLength <- newSTRef (minMatch - 1)
  prevMatch <- newSTRef 0
  available <- newSTRef False
  symDist <- newArray (0, litBufsize - 1) 0
  symLc <- newArray (0, litBufsize - 1) 0
  ltree <- newTree heapSize
  dtree <- newTree (2 * dCodes + 1)
  bltree <- newTree (2 * blCodes + 1)
  heap <- newArray (0, 2 * lCodes + 1) 0
  depth <- newArray (0, 2 * lCodes + 1) 0
  blCount <- newArray (0, maxBits) 0
  output <- newOutput (B.length input `div` 2 + 64)
  let s =
        S input next window prev hashHead insH strstart blockStart lookahead insert matchStart matchLength prevLength prevMatch available highWater symDist symLc symNext ltree dtree bltree heap heapLen heapMax depth blCount optLen staticLen output biBuf biValid
  initBlock s
  pure s

rd :: STRef s Int -> ST s Int
rd = readSTRef

wr :: STRef s Int -> Int -> ST s ()
wr = writeSTRef

updateHash :: Int -> Int -> Int
updateHash h c = ((h `shiftL` hashShift) `xor` c) .&. hashMask

-- | INSERT_STRING: the previous head of the string's hash chain.
insertString :: S s -> Int -> ST s Int
insertString s str = do
  c <- unsafeRead (sWindow s) (str + minMatch - 1)
  h <- updateHash <$> rd (sInsH s) <*> pure c
  wr (sInsH s) h
  matchHead <- unsafeRead (sHead s) h
  unsafeWrite (sPrev s) (str .&. wMask) matchHead
  unsafeWrite (sHead s) h str
  pure matchHead

slideHash :: S s -> ST s ()
slideHash s = do
  forM_ [0 .. hashMask] $ \i -> unsafeRead (sHead s) i >>= \m -> unsafeWrite (sHead s) i (if m >= wSize then m - wSize else 0)
  forM_ [0 .. wSize - 1] $ \i -> unsafeRead (sPrev s) i >>= \m -> unsafeWrite (sPrev s) i (if m >= wSize then m - wSize else 0)

fillWindow :: S s -> ST s ()
fillWindow s = loop >> highWater
  where
    window = sWindow s
    loop = do
      lookahead <- rd (sLookahead s)
      strstart <- rd (sStrstart s)
      let more0 = windowSize - lookahead - strstart
      more <-
        if strstart >= wSize + maxDist
          then do
            forM_ [0 .. wSize - more0 - 1] $ \i -> unsafeRead window (wSize + i) >>= unsafeWrite window i
            modifySTRef' (sMatchStart s) (subtract wSize)
            wr (sStrstart s) (strstart - wSize)
            modifySTRef' (sBlockStart s) (subtract wSize)
            insert <- rd (sInsert s)
            when (insert > strstart - wSize) (wr (sInsert s) (strstart - wSize))
            slideHash s
            pure (more0 + wSize)
          else pure more0
      next <- rd (sNext s)
      let available = B.length (sInput s) - next
      unless (available == 0) $ do
        strstart' <- rd (sStrstart s)
        let n = min available more
        forM_ [0 .. n - 1] $ \i -> unsafeWrite window (strstart' + lookahead + i) (fromIntegral (BU.unsafeIndex (sInput s) (next + i)))
        wr (sNext s) (next + n)
        let lookahead' = lookahead + n
        wr (sLookahead s) lookahead'
        insert <- rd (sInsert s)
        when (lookahead' + insert >= minMatch) $ do
          let str = strstart' - insert
          c0 <- unsafeRead window str
          c1 <- unsafeRead window (str + 1)
          wr (sInsH s) (updateHash c0 c1)
          let inserting position remaining
                | remaining == 0 = wr (sInsert s) 0
                | otherwise = do
                    c <- unsafeRead window (position + minMatch - 1)
                    h <- updateHash <$> rd (sInsH s) <*> pure c
                    wr (sInsH s) h
                    unsafeRead (sHead s) h >>= unsafeWrite (sPrev s) (position .&. wMask)
                    unsafeWrite (sHead s) h position
                    let remaining' = remaining - 1
                    if lookahead' + remaining' < minMatch
                      then wr (sInsert s) remaining'
                      else inserting (position + 1) remaining'
          inserting str insert
        when (lookahead' < minLookahead && next + n < B.length (sInput s)) loop
    highWater = do
      water <- rd (sHighWater s)
      when (water < windowSize) $ do
        current <- (+) <$> rd (sStrstart s) <*> rd (sLookahead s)
        if water < current
          then do
            let count = min winInit (windowSize - current)
            forM_ [current .. current + count - 1] $ \i -> unsafeWrite window i 0
            wr (sHighWater s) (current + count)
          else when (water < current + winInit) $ do
            let count = min (current + winInit - water) (windowSize - water)
            forM_ [water .. water + count - 1] $ \i -> unsafeWrite window i 0
            wr (sHighWater s) (water + count)

longestMatch :: S s -> Int -> ST s Int
longestMatch s curMatch0 = do
  strstart <- rd (sStrstart s)
  prevLength <- rd (sPrevLength s)
  lookahead <- rd (sLookahead s)
  let window = sWindow s
      limit = if strstart > maxDist then strstart - maxDist else 0
      chain0 = if prevLength >= goodMatch then maxChainLength `shiftR` 2 else maxChainLength
      nice = min niceMatchDefault lookahead
      byte = unsafeRead window
      -- The first mismatch from offset 3 on, as zlib's unrolled loop finds
      -- it (offset 2 is equal whenever the hashes are), at most 258.
      extent match offset
        | offset >= maxMatch = pure maxMatch
        | otherwise = do
            a <- byte (strstart + offset)
            b <- byte (match + offset)
            if a == b then extent match (offset + 1) else pure offset
      search curMatch chain bestLen = do
        scanEnd1 <- byte (strstart + bestLen - 1)
        scanEnd <- byte (strstart + bestLen)
        m0 <- byte (curMatch + bestLen)
        m1 <- byte (curMatch + bestLen - 1)
        a0 <- byte curMatch
        s0 <- byte strstart
        a1 <- byte (curMatch + 1)
        s1 <- byte (strstart + 1)
        (bestLen', stop) <-
          if m0 /= scanEnd || m1 /= scanEnd1 || a0 /= s0 || a1 /= s1
            then pure (bestLen, False)
            else do
              len <- extent curMatch 3
              if len > bestLen
                then do
                  wr (sMatchStart s) curMatch
                  pure (len, len >= nice)
                else pure (bestLen, False)
        if stop
          then pure bestLen'
          else do
            next <- unsafeRead (sPrev s) (curMatch .&. wMask)
            if next > limit && chain - 1 /= 0
              then search next (chain - 1) bestLen'
              else pure bestLen'
  best <- search curMatch0 chain0 prevLength
  pure (if best <= lookahead then best else lookahead)

-- | _tr_tally: record a literal (dist 0) or a match; whether the block is full.
tally :: S s -> Int -> Int -> ST s Bool
tally s dist lc = do
  n <- rd (sSymNext s)
  unsafeWrite (sSymDist s) n dist
  unsafeWrite (sSymLc s) n lc
  wr (sSymNext s) (n + 1)
  if dist == 0
    then bump (treeFreq (sLtree s)) lc
    else do
      bump (treeFreq (sLtree s)) ((lengthCode ! lc) + literals + 1)
      bump (treeFreq (sDtree s)) (dCode (dist - 1))
  pure (n + 1 == litBufsize - 1)
  where
    bump array i = unsafeRead array i >>= unsafeWrite array i . (+ 1)

deflateSlow :: S s -> ST s ()
deflateSlow s = loop
  where
    loop = do
      lookahead0 <- rd (sLookahead s)
      when (lookahead0 < minLookahead) (fillWindow s)
      lookahead <- rd (sLookahead s)
      if lookahead == 0
        then finish
        else do
          strstart <- rd (sStrstart s)
          hashHead <- if lookahead >= minMatch then insertString s strstart else pure 0
          rd (sMatchLength s) >>= wr (sPrevLength s)
          rd (sMatchStart s) >>= wr (sPrevMatch s)
          wr (sMatchLength s) (minMatch - 1)
          prevLength <- rd (sPrevLength s)
          when (hashHead /= 0 && prevLength < maxLazyMatch && strstart - hashHead <= maxDist) $ do
            len <- longestMatch s hashHead
            wr (sMatchLength s) len
            matchStart <- rd (sMatchStart s)
            when (len <= 5 && len == minMatch && strstart - matchStart > tooFar) (wr (sMatchLength s) (minMatch - 1))
          matchLength <- rd (sMatchLength s)
          available <- readSTRef (sMatchAvailable s)
          if prevLength >= minMatch && matchLength <= prevLength
            then do
              let maxInsert = strstart + lookahead - minMatch
              prevMatch <- rd (sPrevMatch s)
              full <- tally s (strstart - 1 - prevMatch) (prevLength - minMatch)
              wr (sLookahead s) (lookahead - (prevLength - 1))
              let inserting position remaining
                    | remaining == 0 = pure position
                    | otherwise = do
                        let position' = position + 1
                        when (position' <= maxInsert) (() <$ insertString s position')
                        inserting position' (remaining - 1)
              final <- inserting strstart (prevLength - 2)
              writeSTRef (sMatchAvailable s) False
              wr (sMatchLength s) (minMatch - 1)
              wr (sStrstart s) (final + 1)
              when full (flushBlock s False)
              loop
            else
              if available
                then do
                  c <- unsafeRead (sWindow s) (strstart - 1)
                  full <- tally s 0 c
                  when full (flushBlock s False)
                  wr (sStrstart s) (strstart + 1)
                  wr (sLookahead s) (lookahead - 1)
                  loop
                else do
                  writeSTRef (sMatchAvailable s) True
                  wr (sStrstart s) (strstart + 1)
                  wr (sLookahead s) (lookahead - 1)
                  loop
    finish = do
      available <- readSTRef (sMatchAvailable s)
      when available $ do
        strstart <- rd (sStrstart s)
        c <- unsafeRead (sWindow s) (strstart - 1)
        _ <- tally s 0 c
        writeSTRef (sMatchAvailable s) False
      strstart <- rd (sStrstart s)
      wr (sInsert s) (if strstart < minMatch - 1 then strstart else minMatch - 1)
      flushBlock s True

-- | FLUSH_BLOCK_ONLY: the block from block_start to strstart.
flushBlock :: S s -> Bool -> ST s ()
flushBlock s final = do
  blockStart <- rd (sBlockStart s)
  strstart <- rd (sStrstart s)
  trFlushBlock s (if blockStart >= 0 then Just blockStart else Nothing) (strstart - blockStart) final
  wr (sBlockStart s) strstart

-- * Trees (trees.c)

initBlock :: S s -> ST s ()
initBlock s = do
  forM_ [0 .. lCodes - 1] $ \n -> unsafeWrite (treeFreq (sLtree s)) n 0
  forM_ [0 .. dCodes - 1] $ \n -> unsafeWrite (treeFreq (sDtree s)) n 0
  forM_ [0 .. blCodes - 1] $ \n -> unsafeWrite (treeFreq (sBltree s)) n 0
  unsafeWrite (treeFreq (sLtree s)) endBlock 1
  wr (sOptLen s) 0
  wr (sStaticLen s) 0
  wr (sSymNext s) 0

sendBits :: S s -> Int -> Int -> ST s ()
sendBits s value len = do
  buffer <- rd (sBiBuf s)
  valid <- rd (sBiValid s)
  let combined = buffer .|. ((value .&. ((1 `shiftL` len) - 1)) `shiftL` valid)
      drain b v
        | v >= 8 = putByte (sOut s) (b .&. 0xff) >> drain (b `shiftR` 8) (v - 8)
        | otherwise = wr (sBiBuf s) b >> wr (sBiValid s) v
  drain combined (valid + len)

windup :: S s -> ST s ()
windup s = do
  valid <- rd (sBiValid s)
  when (valid > 0) (rd (sBiBuf s) >>= putByte (sOut s) . (.&. 0xff))
  wr (sBiBuf s) 0
  wr (sBiValid s) 0

sendCode :: S s -> Int -> STUArray s Int Int -> STUArray s Int Int -> ST s ()
sendCode s c codes lens = do
  code <- unsafeRead codes c
  len <- unsafeRead lens c
  sendBits s code len

smaller :: S s -> Tree s -> Int -> Int -> ST s Bool
smaller s tree n m = do
  fn <- unsafeRead (treeFreq tree) n
  fm <- unsafeRead (treeFreq tree) m
  if fn < fm
    then pure True
    else
      if fn == fm
        then (<=) <$> unsafeRead (sDepth s) n <*> unsafeRead (sDepth s) m
        else pure False

pqdownheap :: S s -> Tree s -> Int -> ST s ()
pqdownheap s tree k0 = do
  v <- unsafeRead (sHeap s) k0
  heapLen <- rd (sHeapLen s)
  let go k j
        | j > heapLen = unsafeWrite (sHeap s) k v
        | otherwise = do
            j' <-
              if j < heapLen
                then do
                  right <- unsafeRead (sHeap s) (j + 1)
                  left <- unsafeRead (sHeap s) j
                  less <- smaller s tree right left
                  pure (if less then j + 1 else j)
                else pure j
            child <- unsafeRead (sHeap s) j'
            stop <- smaller s tree v child
            if stop
              then unsafeWrite (sHeap s) k v
              else do
                unsafeWrite (sHeap s) k child
                go j' (j' `shiftL` 1)
  go k0 (k0 `shiftL` 1)

buildTree :: S s -> Tree s -> Desc -> ST s ()
buildTree s tree desc = do
  let elems = descElems desc
      heap = sHeap s
  wr (sHeapLen s) 0
  wr (sHeapMax s) heapSize
  maxCodeRef <- newSTRef (-1)
  forM_ [0 .. elems - 1] $ \n -> do
    freq <- unsafeRead (treeFreq tree) n
    if freq /= 0
      then do
        len <- (+ 1) <$> rd (sHeapLen s)
        wr (sHeapLen s) len
        unsafeWrite heap len n
        wr maxCodeRef n
        unsafeWrite (sDepth s) n 0
      else unsafeWrite (treeLen tree) n 0
  let force = do
        heapLen <- rd (sHeapLen s)
        when (heapLen < 2) $ do
          maxCode <- rd maxCodeRef
          node <-
            if maxCode < 2
              then wr maxCodeRef (maxCode + 1) >> pure (maxCode + 1)
              else pure 0
          wr (sHeapLen s) (heapLen + 1)
          unsafeWrite heap (heapLen + 1) node
          unsafeWrite (treeFreq tree) node 1
          unsafeWrite (sDepth s) node 0
          modifySTRef' (sOptLen s) (subtract 1)
          forM_ (descStaticLen desc) $ \stree -> modifySTRef' (sStaticLen s) (subtract (stree ! node))
          force
  force
  maxCode <- rd maxCodeRef
  wr (treeMaxCode tree) maxCode
  heapLen0 <- rd (sHeapLen s)
  forM_ [heapLen0 `div` 2, heapLen0 `div` 2 - 1 .. 1] $ \n -> pqdownheap s tree n
  let combine node = do
        n <- unsafeRead heap 1
        heapLen <- rd (sHeapLen s)
        unsafeRead heap heapLen >>= unsafeWrite heap 1
        wr (sHeapLen s) (heapLen - 1)
        pqdownheap s tree 1
        m <- unsafeRead heap 1
        heapMax <- rd (sHeapMax s)
        unsafeWrite heap (heapMax - 1) n
        unsafeWrite heap (heapMax - 2) m
        wr (sHeapMax s) (heapMax - 2)
        fn <- unsafeRead (treeFreq tree) n
        fm <- unsafeRead (treeFreq tree) m
        unsafeWrite (treeFreq tree) node (fn + fm)
        dn <- unsafeRead (sDepth s) n
        dm <- unsafeRead (sDepth s) m
        unsafeWrite (sDepth s) node ((if dn >= dm then dn else dm) + 1)
        unsafeWrite (treeDad tree) n node
        unsafeWrite (treeDad tree) m node
        unsafeWrite heap 1 node
        pqdownheap s tree 1
        remaining <- rd (sHeapLen s)
        when (remaining >= 2) (combine (node + 1))
  combine elems
  heapMax <- (subtract 1) <$> rd (sHeapMax s)
  wr (sHeapMax s) heapMax
  unsafeRead heap 1 >>= unsafeWrite heap heapMax
  genBitlen s tree desc
  genCodes s tree maxCode

genBitlen :: S s -> Tree s -> Desc -> ST s ()
genBitlen s tree desc = do
  maxCode <- rd (treeMaxCode tree)
  let heap = sHeap s
      maxLength = descMaxLength desc
      base = descExtraBase desc
  forM_ [0 .. maxBits] $ \bits -> unsafeWrite (sBlCount s) bits 0
  heapMax <- rd (sHeapMax s)
  root <- unsafeRead heap heapMax
  unsafeWrite (treeLen tree) root 0
  overflowRef <- newSTRef (0 :: Int)
  forM_ [heapMax + 1 .. heapSize - 1] $ \h -> do
    n <- unsafeRead heap h
    dad <- unsafeRead (treeDad tree) n
    bits0 <- (+ 1) <$> unsafeRead (treeLen tree) dad
    bits <-
      if bits0 > maxLength
        then modifySTRef' overflowRef (+ 1) >> pure maxLength
        else pure bits0
    unsafeWrite (treeLen tree) n bits
    when (n <= maxCode) $ do
      unsafeRead (sBlCount s) bits >>= unsafeWrite (sBlCount s) bits . (+ 1)
      let xbits = if n >= base then descExtra desc ! (n - base) else 0
      f <- unsafeRead (treeFreq tree) n
      modifySTRef' (sOptLen s) (+ f * (bits + xbits))
      forM_ (descStaticLen desc) $ \stree -> modifySTRef' (sStaticLen s) (+ f * (stree ! n + xbits))
  overflow0 <- readSTRef overflowRef
  when (overflow0 /= 0) $ do
    let adjust overflow = do
          let findBits bits = do
                count <- unsafeRead (sBlCount s) bits
                if count == 0 then findBits (bits - 1) else pure bits
          bits <- findBits (maxLength - 1)
          unsafeRead (sBlCount s) bits >>= unsafeWrite (sBlCount s) bits . subtract 1
          unsafeRead (sBlCount s) (bits + 1) >>= unsafeWrite (sBlCount s) (bits + 1) . (+ 2)
          unsafeRead (sBlCount s) maxLength >>= unsafeWrite (sBlCount s) maxLength . subtract 1
          let overflow' = overflow - 2
          when (overflow' > 0) (adjust overflow')
    adjust overflow0
    hRef <- newSTRef heapSize
    forM_ [maxLength, maxLength - 1 .. 1] $ \bits -> do
      count0 <- unsafeRead (sBlCount s) bits
      let assign count = when (count /= 0) $ do
            h <- subtract 1 <$> readSTRef hRef
            writeSTRef hRef h
            m <- unsafeRead heap h
            if m > maxCode
              then assign count
              else do
                len <- unsafeRead (treeLen tree) m
                when (len /= bits) $ do
                  f <- unsafeRead (treeFreq tree) m
                  modifySTRef' (sOptLen s) (+ (bits - len) * f)
                  unsafeWrite (treeLen tree) m bits
                assign (count - 1)
      assign count0

genCodes :: S s -> Tree s -> Int -> ST s ()
genCodes s tree maxCode = do
  counts <- mapM (unsafeRead (sBlCount s)) [0 .. maxBits]
  let nextCodes = scanl (\code bits -> (code + counts !! (bits - 1)) `shiftL` 1) 0 [1 .. maxBits]
  next <- newListArray (0, maxBits) nextCodes :: ST s (STUArray s Int Int)
  forM_ [0 .. maxCode] $ \n -> do
    len <- unsafeRead (treeLen tree) n
    when (len /= 0) $ do
      code <- unsafeRead next len
      unsafeWrite next len (code + 1)
      unsafeWrite (treeCode tree) n (reverseBits code len)

scanTree :: S s -> Tree s -> Int -> ST s ()
scanTree s tree maxCode = do
  next0 <- unsafeRead (treeLen tree) 0
  writeArray (treeLen tree) (maxCode + 1) 0xffff
  let bl = treeFreq (sBltree s)
      bump i by = unsafeRead bl i >>= unsafeWrite bl i . (+ by)
      limits nextlen curlen
        | nextlen == 0 = (138, 3)
        | curlen == nextlen = (6, 3)
        | otherwise = (7, 4)
      go n prevlen nextlen count (maxCount, minCount)
        | n > maxCode = pure ()
        | otherwise = do
            let curlen = nextlen
            nextlen' <- unsafeRead (treeLen tree) (n + 1)
            let count' = count + 1
            if count' < maxCount && curlen == nextlen'
              then go (n + 1) prevlen nextlen' count' (maxCount, minCount)
              else do
                if count' < minCount
                  then bump curlen count'
                  else
                    if curlen /= 0
                      then do
                        when (curlen /= prevlen) (bump curlen 1)
                        bump rep3to6 1
                      else if count' <= 10 then bump repz3to10 1 else bump repz11to138 1
                go (n + 1) curlen nextlen' 0 (limits nextlen' curlen)
  go 0 (-1) next0 0 (if next0 == 0 then (138, 3) else (7, 4))

sendTree :: S s -> Tree s -> Int -> ST s ()
sendTree s tree maxCode = do
  next0 <- unsafeRead (treeLen tree) 0
  let bl = sBltree s
      code c = sendCode s c (treeCode bl) (treeLen bl)
      limits nextlen curlen
        | nextlen == 0 = (138, 3)
        | curlen == nextlen = (6, 3)
        | otherwise = (7, 4)
      go n prevlen nextlen count (maxCount, minCount)
        | n > maxCode = pure ()
        | otherwise = do
            let curlen = nextlen
            nextlen' <- unsafeRead (treeLen tree) (n + 1)
            let count' = count + 1
            if count' < maxCount && curlen == nextlen'
              then go (n + 1) prevlen nextlen' count' (maxCount, minCount)
              else do
                if count' < minCount
                  then forM_ [1 .. count'] (const (code curlen))
                  else
                    if curlen /= 0
                      then do
                        count'' <-
                          if curlen /= prevlen
                            then code curlen >> pure (count' - 1)
                            else pure count'
                        code rep3to6
                        sendBits s (count'' - 3) 2
                      else
                        if count' <= 10
                          then code repz3to10 >> sendBits s (count' - 3) 3
                          else code repz11to138 >> sendBits s (count' - 11) 7
                go (n + 1) curlen nextlen' 0 (limits nextlen' curlen)
  go 0 (-1) next0 0 (if next0 == 0 then (138, 3) else (7, 4))

buildBlTree :: S s -> ST s Int
buildBlTree s = do
  rd (treeMaxCode (sLtree s)) >>= scanTree s (sLtree s)
  rd (treeMaxCode (sDtree s)) >>= scanTree s (sDtree s)
  buildTree s (sBltree s) blDesc
  let find index
        | index < 3 = pure index
        | otherwise = do
            len <- unsafeRead (treeLen (sBltree s)) (blOrder ! index)
            if len /= 0 then pure index else find (index - 1)
  maxBlindex <- find (blCodes - 1)
  modifySTRef' (sOptLen s) (+ (3 * (maxBlindex + 1) + 5 + 5 + 4))
  pure maxBlindex

compressBlock :: S s -> (Int -> ST s (Int, Int)) -> (Int -> ST s (Int, Int)) -> ST s ()
compressBlock s literal distance = do
  count <- rd (sSymNext s)
  forM_ [0 .. count - 1] $ \i -> do
    dist <- unsafeRead (sSymDist s) i
    lc <- unsafeRead (sSymLc s) i
    if dist == 0
      then literal lc >>= uncurry (sendBits s)
      else do
        let code = lengthCode ! lc
        literal (code + literals + 1) >>= uncurry (sendBits s)
        let extra = extraLbits ! code
        when (extra /= 0) (sendBits s (lc - baseLength ! code) extra)
        let dist' = dist - 1
            dcode = dCode dist'
        distance dcode >>= uncurry (sendBits s)
        let dextra = extraDbits ! dcode
        when (dextra /= 0) (sendBits s (dist' - baseDist ! dcode) dextra)
  literal endBlock >>= uncurry (sendBits s)

trFlushBlock :: S s -> Maybe Int -> Int -> Bool -> ST s ()
trFlushBlock s buffer storedLen final = do
  buildTree s (sLtree s) lDesc
  buildTree s (sDtree s) dDesc
  maxBlindex <- buildBlTree s
  optLen <- rd (sOptLen s)
  staticLen <- rd (sStaticLen s)
  let optLenb0 = (optLen + 3 + 7) `shiftR` 3
      staticLenb = (staticLen + 3 + 7) `shiftR` 3
      optLenb = if staticLenb <= optLenb0 then staticLenb else optLenb0
      lastBit = if final then 1 else 0
  case buffer of
    Just start
      | storedLen + 4 <= optLenb -> do
          sendBits s lastBit 3
          windup s
          let len = storedLen .&. 0xffff
          forM_ [len .&. 0xff, len `shiftR` 8, complement len .&. 0xff, (complement len `shiftR` 8) .&. 0xff] (putByte (sOut s))
          forM_ [start .. start + storedLen - 1] $ \i -> unsafeRead (sWindow s) i >>= putByte (sOut s)
    _
      | staticLenb == optLenb -> do
          sendBits s (2 + lastBit) 3
          compressBlock s (\c -> pure (staticLtreeCode ! c, staticLtreeLen ! c)) (\c -> pure (staticDtreeCode ! c, staticDtreeLen ! c))
      | otherwise -> do
          sendBits s (4 + lastBit) 3
          lcodes <- (+ 1) <$> rd (treeMaxCode (sLtree s))
          dcodes <- (+ 1) <$> rd (treeMaxCode (sDtree s))
          let blcodes = maxBlindex + 1
          sendBits s (lcodes - 257) 5
          sendBits s (dcodes - 1) 5
          sendBits s (blcodes - 4) 4
          forM_ [0 .. blcodes - 1] $ \rank -> unsafeRead (treeLen (sBltree s)) (blOrder ! rank) >>= \len -> sendBits s len 3
          sendTree s (sLtree s) (lcodes - 1)
          sendTree s (sDtree s) (dcodes - 1)
          let pair tree c = (,) <$> unsafeRead (treeCode tree) c <*> unsafeRead (treeLen tree) c
          compressBlock s (pair (sLtree s)) (pair (sDtree s))
  initBlock s
  when final (windup s)

-- * Inflate

-- | Decode a gzip file: one or more members, each checked against its
-- CRC-32 and length. Bytes after the last member that do not start another
-- member are ignored, as Node's zlib does.
gunzip :: B.ByteString -> Either String B.ByteString
gunzip input = B.concat <$> members input True
  where
    members bytes first
      | B.length bytes >= 2 && B.index bytes 0 == 0x1f && B.index bytes 1 == 0x8b = do
          (content, rest) <- member bytes
          (content :) <$> members rest False
      | first = Left "incorrect header check"
      | otherwise = Right []
    member bytes = do
      when (B.length bytes < 10) (Left "unexpected end of file")
      unless (B.index bytes 2 == 8) (Left "unknown compression method")
      let flags = B.index bytes 3
      when (flags .&. 0xe0 /= 0) (Left "unknown header flags set")
      afterExtra <-
        if flags .&. 4 /= 0
          then do
            when (B.length bytes < 12) (Left "unexpected end of file")
            let len = fromIntegral (B.index bytes 10) + 256 * fromIntegral (B.index bytes 11)
            pure (12 + len)
          else pure 10
      afterName <- if flags .&. 8 /= 0 then zeroTerminated bytes afterExtra else pure afterExtra
      afterComment <- if flags .&. 16 /= 0 then zeroTerminated bytes afterName else pure afterName
      let start = if flags .&. 2 /= 0 then afterComment + 2 else afterComment
      when (start > B.length bytes) (Left "unexpected end of file")
      (content, used) <- inflateFrom (B.drop start bytes)
      let trailer = B.drop (start + used) bytes
      when (B.length trailer < 8) (Left "unexpected end of file")
      let word offset = sum [fromIntegral (B.index trailer (offset + i)) `shiftL` (8 * i) | i <- [0 .. 3]] :: Word32
      unless (word 0 == crc32 content) (Left "incorrect data check")
      unless (word 4 == fromIntegral (B.length content)) (Left "incorrect length check")
      pure (content, B.drop 8 trailer)
    zeroTerminated bytes from = case B.elemIndex 0 (B.drop from bytes) of
      Just at -> Right (from + at + 1)
      Nothing -> Left "unexpected end of file"

-- | Decode a raw DEFLATE stream.
inflate :: B.ByteString -> Either String B.ByteString
inflate bytes = fst <$> inflateFrom bytes

-- | Decode a raw DEFLATE stream at the start of the input: the content and
-- how many input bytes the stream took.
inflateFrom :: B.ByteString -> Either String (B.ByteString, Int)
inflateFrom input = runST $ do
  output <- newOutput (4 * B.length input + 64)
  position <- newSTRef 0
  buffer <- newSTRef 0
  count <- newSTRef 0
  let total = B.length input
      need n = do
        have <- rd count
        if have >= n
          then pure True
          else do
            p <- rd position
            if p >= total
              then pure False
              else do
                b <- rd buffer
                wr buffer (b .|. (fromIntegral (BU.unsafeIndex input p) `shiftL` have))
                wr count (have + 8)
                wr position (p + 1)
                need n
      bits n = do
        ok <- need n
        if not ok
          then pure Nothing
          else do
            b <- rd buffer
            wr buffer (b `shiftR` n)
            modifySTRef' count (subtract n)
            pure (Just (b .&. ((1 `shiftL` n) - 1)))
      -- A decoding table: every maxLen-bit pattern to symbol * 16 + length.
      table lens = do
        let maxLen = maximum (0 : lens)
            codes = canonicalCodes lens
        array <- newArray (0, (1 `shiftL` maxLen) - 1) (-1) :: ST s (STUArray s Int Int)
        forM_ (zip3 [0 ..] lens codes) $ \(symbol, len, code) ->
          when (len > 0) $
            forM_ [0 .. (1 `shiftL` (maxLen - len)) - 1] $ \e ->
              writeArray array (code .|. (e `shiftL` len)) (symbol * 16 + len)
        pure (array, maxLen)
      decode (array, maxLen) = do
        _ <- need maxLen
        have <- rd count
        b <- rd buffer
        let peek = b .&. ((1 `shiftL` maxLen) - 1)
        if maxLen == 0
          then pure Nothing
          else do
            entry <- readArray array peek
            let len = entry .&. 15
            if entry < 0 || len > have
              then pure Nothing
              else do
                wr buffer (b `shiftR` len)
                wr count (have - len)
                pure (Just (entry `shiftR` 4))
      validLengths lens = overSubscribed (map (\size -> length (filter (== size) lens)) [1 .. maxBits])
      overSubscribed counts = go 1 counts
        where
          go _ [] = True
          go left (c : rest) = let left' = left * 2 - c in left' >= 0 && go left' rest
      copy distance len = do
        n <- outputLength output
        if distance > n || distance == 0
          then pure False
          else do
            forM_ [0 .. len - 1] $ \i -> outputByte output (n - distance + i) >>= putByte output . fromIntegral
            pure True
      codesLoop literal distance = do
        symbol <- decode literal
        case symbol of
          Nothing -> pure (Left "invalid code")
          Just sym
            | sym < 256 -> putByte output sym >> codesLoop literal distance
            | sym == 256 -> pure (Right ())
            | sym > 285 -> pure (Left "invalid literal/length code")
            | otherwise -> do
                let code = sym - 257
                extra <- bits (extraLbits ! code)
                d <- decode distance
                case (extra, d) of
                  (Just e, Just dsym)
                    | dsym < 30 -> do
                        dextra <- bits (extraDbits ! dsym)
                        case dextra of
                          Just de -> do
                            let len = if code == 28 then 258 else 3 + baseLength ! code + e
                            ok <- copy (baseDist ! dsym + de + 1) len
                            if ok then codesLoop literal distance else pure (Left "invalid distance too far back")
                          Nothing -> pure (Left "unexpected end of file")
                  (Just _, Just _) -> pure (Left "invalid distance code")
                  _ -> pure (Left "unexpected end of file")
      stored = do
        -- The rest of the current byte is padding; whole bytes already
        -- buffered are the block's length fields.
        unread <- rd count
        modifySTRef' position (subtract (unread `div` 8))
        wr buffer 0
        wr count 0
        p <- rd position
        if p + 4 > total
          then pure (Left "unexpected end of file")
          else do
            let byte i = fromIntegral (BU.unsafeIndex input (p + i)) :: Int
                len = byte 0 .|. (byte 1 `shiftL` 8)
                nlen = byte 2 .|. (byte 3 `shiftL` 8)
            if len /= complement nlen .&. 0xffff
              then pure (Left "invalid stored block lengths")
              else
                if p + 4 + len > total
                  then pure (Left "unexpected end of file")
                  else do
                    forM_ [0 .. len - 1] $ \i -> putByte output (byte (4 + i))
                    wr position (p + 4 + len)
                    pure (Right ())
      fixed = do
        literal <- table (replicate 144 8 ++ replicate 112 9 ++ replicate 24 7 ++ replicate 8 8)
        distance <- table (replicate 30 5)
        codesLoop literal distance
      dynamic = do
        header <- mapM bits [5, 5, 4]
        case sequence header of
          Nothing -> pure (Left "unexpected end of file")
          Just [hlit0, hdist0, hclen0] -> do
            let hlit = hlit0 + 257
                hdist = hdist0 + 1
                hclen = hclen0 + 4
            if hlit > 286 || hdist > 30
              then pure (Left "too many length or distance symbols")
              else do
                clens <- mapM (const (bits 3)) [1 .. hclen]
                case sequence clens of
                  Nothing -> pure (Left "unexpected end of file")
                  Just given -> do
                    let ordered = [maybe 0 id (lookup i (zip [blOrder ! r | r <- [0 .. 18]] (given ++ replicate (19 - hclen) 0))) | i <- [0 .. 18 :: Int]]
                    if not (validLengths ordered)
                      then pure (Left "invalid code lengths set")
                      else do
                        lengthTable <- table ordered
                        let readLengths acc
                              | length acc >= hlit + hdist = pure (Right (take (hlit + hdist) acc))
                              | otherwise = do
                                  symbol <- decode lengthTable
                                  case symbol of
                                    Nothing -> pure (Left "invalid code lengths set")
                                    Just sym
                                      | sym < 16 -> readLengths (acc ++ [sym])
                                      | sym == 16 ->
                                          if null acc
                                            then pure (Left "invalid bit length repeat")
                                            else repeatWith 2 3 (last acc) acc
                                      | sym == 17 -> repeatWith 3 3 0 acc
                                      | otherwise -> repeatWith 7 11 0 acc
                            repeatWith extraBits base value acc = do
                              r <- bits extraBits
                              case r of
                                Nothing -> pure (Left "unexpected end of file")
                                Just n
                                  | length acc + base + n > hlit + hdist -> pure (Left "invalid bit length repeat")
                                  | otherwise -> readLengths (acc ++ replicate (base + n) value)
                        lens <- readLengths []
                        case lens of
                          Left problem -> pure (Left problem)
                          Right all'
                            | (all' !! 256) == 0 -> pure (Left "invalid code -- missing end-of-block")
                            | not (validLengths (take hlit all')) -> pure (Left "invalid literal/lengths set")
                            | not (validLengths (drop hlit all')) -> pure (Left "invalid distances set")
                            | otherwise -> do
                                literal <- table (take hlit all')
                                distance <- table (drop hlit all')
                                codesLoop literal distance
          Just _ -> pure (Left "unexpected end of file")
      blocks = do
        header <- bits 3
        case header of
          Nothing -> pure (Left "unexpected end of file")
          Just h -> do
            result <- case h `shiftR` 1 of
              0 -> stored
              1 -> fixed
              2 -> dynamic
              _ -> pure (Left "invalid block type")
            case result of
              Left problem -> pure (Left problem)
              Right ()
                | h .&. 1 == 1 -> pure (Right ())
                | otherwise -> blocks
  result <- blocks
  case result of
    Left problem -> pure (Left problem)
    Right () -> do
      content <- freeze output
      p <- rd position
      unread <- rd count
      pure (Right (content, p - unread `div` 8))
