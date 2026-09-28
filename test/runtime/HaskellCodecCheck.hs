module HaskellCodecCheck (checkCodecs) where

import Control.Monad (forM_, unless)
import Data.Bits (finiteBitSize)
import Data.Complex (Complex((:+)))
import Data.Int (Int8)
import Data.List (isInfixOf)
import Data.Ratio ((%))
import Data.Word (Word64)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified LawSpecCodecs as C
import qualified LawSpecData as D
import qualified LawSpecDataCodecs as DC
import qualified LawSpecDataSchema as DS
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

reject :: String -> Either String a -> IO ()
reject fragment result = case result of
  Left message -> assert ("missing context: " ++ message) (fragment `isInfixOf` message)
  Right _ -> error ("expected rejection: " ++ fragment)

roundtrip :: (Eq a, Show a) => C.Codec a -> a -> IO ()
roundtrip codec value = case C.encode codec value >>= C.decode codec of
  Left message -> error message
  Right restored -> assert ("native round trip: " ++ show value) (restored == value)

checkCodecs :: IO ()
checkCodecs = do
  let schema = either error id DS.schema
  forM_ [32,64] $ \bits -> do
    let int8 = C.integerCodec schema bits "Int8" :: C.Codec Int8
        tree = DC.treeCodec schema bits int8
        pair = DC.pairCodec schema bits (C.textCodec schema bits)
        value = D.TreeBranch [D.TreeLeaf 127, D.TreeBranch [], D.TreeLeaf (-128)]
    roundtrip tree value
    roundtrip pair (D.PairPair (T.pack "🙂") (maxBound :: Word64))
    roundtrip (DC.chainCodec schema bits) (D.ChainNext (Just D.ChainStop))
    roundtrip (DC.leftSideCodec schema bits) (D.LeftSideAcross (D.RightSideBack Nothing))
    roundtrip (DC.presenceCodec schema bits)
      (D.PresenceStates (LS.NullableValue LS.UndefinedValue) () LS.Undefined)
    roundtrip (C.maybeCodec schema bits (C.maybeCodec schema bits tree)) Nothing
    roundtrip (C.maybeCodec schema bits (C.maybeCodec schema bits tree)) (Just Nothing)
    roundtrip (C.maybeCodec schema bits (C.maybeCodec schema bits tree)) (Just (Just value))
    roundtrip (C.eitherCodec schema bits tree pair) (Left value)
    roundtrip (C.eitherCodec schema bits tree pair) (Right (D.PairPair (T.pack "text") 9))
    roundtrip (DC.treeCodec schema bits (C.codeUnitCodec schema bits)) (D.TreeLeaf 0xD800)
    roundtrip (DC.stringsCodec schema bits) (D.StringsTexts (T.pack "🙂") ['🙂']
      (LS.CodePointText ['\xD800','🙂']) (LS.Utf16Text [0xD800,0,0xDC00]))
    roundtrip (DC.treeCodec schema bits (C.bytesCodec schema bits)) (D.TreeLeaf (B.pack [0,128,255]))
    roundtrip (DC.treeCodec schema bits (C.integerCodec schema bits "BigUInt"))
      (D.TreeLeaf (18446744073709551616 :: Integer))
    roundtrip (DC.treeCodec schema bits (C.decimalCodec schema bits)) (D.TreeLeaf (LS.Decimal (3 % 10)))
    roundtrip (DC.treeCodec schema bits (C.rationalCodec schema bits)) (D.TreeLeaf (1 % 2))
    roundtrip (DC.treeCodec schema bits (C.float32Codec schema bits)) (D.TreeLeaf 0.1)
    roundtrip (DC.treeCodec schema bits (C.complex64Codec schema bits)) (D.TreeLeaf (1 :+ 2))
    roundtrip (DC.treeCodec schema bits (C.complex128Codec schema bits)) (D.TreeLeaf (1 :+ (-2)))
    roundtrip (C.nullCodec schema bits) LS.Null
    roundtrip (C.undefinedCodec schema bits) LS.Undefined
    let floats = DC.treeCodec schema bits (C.float64Codec schema bits)
        nan = either error id (C.encode floats (D.TreeLeaf (0/0)))
        restored = either error id (C.decode floats nan)
    assert "native NaN preserved" (isNaN (D.treeLeafValue restored))
    assert "logical NaN equality" (S.equal schema (C.reference floats) bits nan nan == Right False)
    let negativeZero = either error id (C.encode floats (D.TreeLeaf (-0)) >>= C.decode floats)
    assert "negative zero preserved" (isNegativeZero (D.treeLeafValue negativeZero))
    let symbols = DC.treeCodec schema bits (C.symbolCodec schema bits)
        symbol identity = either error id (C.encode symbols (D.TreeLeaf (LS.Symbol identity "same")))
    assert "Symbol identity preserved" (S.equal schema (C.reference symbols) bits (symbol "a") (symbol "b") == Right False)
    reject "ctor::Leaf.value" (C.encode (DC.treeCodec schema bits (C.characterCodec schema bits "Char")) (D.TreeLeaf '\xD800'))
    reject "ctor::Leaf.value" (C.encode (DC.treeCodec schema bits (C.integerCodec schema bits "BigUInt")) (D.TreeLeaf (-1 :: Integer)))
    reject "ctor::Leaf.value" (C.encode (DC.treeCodec schema bits (C.decimalCodec schema bits)) (D.TreeLeaf (LS.Decimal (1 % 3))))
    reject "ctor::Leaf.value" (C.decode tree (LS.SData "ctor::Leaf" [LS.SInteger "Int8" 128]))
    reject "field count" (C.decode tree (LS.SData "ctor::Leaf" []))
    reject "unknown constructor" (C.decode tree (LS.SData "ctor::Pair" []))
    let machine = C.integerCodec schema bits "IntSize" :: C.Codec Int
    if bits == finiteBitSize (0 :: Int)
      then do
        roundtrip machine 1
        roundtrip (DC.machineCodec schema bits) D.MachineMachineEmpty
        roundtrip (DC.machineCodec schema bits) (D.MachineMachineValue 1)
      else do
        reject "machineBits" (C.encode machine 1)
        reject "machineBits" (C.encode (DC.machineCodec schema bits) D.MachineMachineEmpty)
    reject "unknown constructor" (C.decode (DC.emptyCodec schema bits int8) (LS.SData "fake" []))
  putStrLn "Haskell native codec checks passed"
