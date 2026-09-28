module Main where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (unless, forM_)
import Data.Int (Int8)
import Data.Ratio ((%))
import Data.Word (Word64)
import qualified Data.Text as T
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

reject :: String -> LS.Scalar -> IO ()
reject label value = do
  result <- try (evaluate (LS.forceScalar value)) :: IO (Either SomeException ())
  case result of
    Left _ -> pure ()
    Right _ -> error ("expected rejection: " ++ label)

main :: IO ()
main = do
  assert "constructor boundary selector collisions" (Data.SelectorsX True /= Data.SelectorsXY True)
  let tree = Data.TreeBranch [Data.TreeLeaf (127 :: Int8), Data.TreeBranch []]
  assert "recursive native tree" (tree == Data.TreeBranch [Data.TreeLeaf 127, Data.TreeBranch []])
  assert "constructor tags" (Data.TreeLeaf (0 :: Int8) /= Data.TreeBranch [])
  let pair = Data.PairPair (T.pack "🙂") (maxBound :: Word64)
  assert "native UInt64 and Text" (Data.pairPairFirst pair == T.pack "🙂" &&
    Data.pairPairSecond pair == 18446744073709551615)
  let phantom = Data.PhantomTag :: Data.Phantom (Int -> Int)
  assert "phantom parameters need no artificial Eq constraint" (phantom == phantom)
  assert "recursive Maybe" (Data.ChainNext (Just Data.ChainStop) /= Data.ChainStop)
  let mutual = Data.LeftSideAcross (Data.RightSideBack Nothing)
  assert "mutual recursion" (mutual == mutual)
  let present = Data.PresenceStates (LS.NullableValue LS.UndefinedValue) () LS.Undefined
      absent = Data.PresenceStates LS.NullValue () LS.Undefined
  assert "nested presence" (present /= absent)
  let texts = Data.StringsTexts (T.pack "🙂") ['🙂']
        (LS.CodePointText ['\xD800', '🙂']) (LS.Utf16Text [0xD800, 0, 0xDC00])
  assert "Text and linked character lists stay distinct"
    (Data.stringsTextsText texts == T.pack (Data.stringsTextsCharacters texts))
  assert "IEEE NaN inside native data" (Data.TreeLeaf (0/0 :: Double) /= Data.TreeLeaf (0/0 :: Double))
  assert "IEEE signed zero inside native data" (Data.TreeLeaf (0 :: Double) == Data.TreeLeaf (-0 :: Double))
  assert "Symbol identity" (LS.Symbol "one" "same" /= LS.Symbol "two" "same")
  assert "Symbol descriptions do not change identity" (LS.Symbol "one" "a" == LS.Symbol "one" "b")
  forM_ [32,64] $ \bits -> do
    let roundtrip :: LS.Native a => String -> a -> a
        roundtrip name value = LS.toNative name (LS.fromNative name value bits) bits
    assert "exact decimal" (roundtrip "Decimal" (LS.Decimal (3 % 10)) == LS.Decimal (3 % 10))
    assert "raw code points" (roundtrip "CodePointText" (LS.CodePointText ['\xD800','🙂']) == LS.CodePointText ['\xD800','🙂'])
    assert "raw UTF16 units" (roundtrip "Utf16Text" (LS.Utf16Text [0xD800,0,0xDC00]) == LS.Utf16Text [0xD800,0,0xDC00])
    assert "Null roundtrip" (roundtrip "Null" LS.Null == LS.Null)
    assert "Undefined roundtrip" (roundtrip "Undefined" LS.Undefined == LS.Undefined)
    let nested = LS.NullableValue LS.UndefinedValue :: LS.Nullable (LS.Optional Int8)
    assert "nested absence roundtrip" (roundtrip "Nullable Optional Int8" nested == nested)
    assert "nested payload roundtrip" (roundtrip "Nullable Optional Int8" (LS.NullableValue (LS.OptionalValue (127 :: Int8))) == LS.NullableValue (LS.OptionalValue 127))
    reject "nonfinite base-ten fraction" (LS.fromNative "Decimal" (LS.Decimal (1 % 3)) bits)
  putStrLn "Haskell native data and support type checks passed"
