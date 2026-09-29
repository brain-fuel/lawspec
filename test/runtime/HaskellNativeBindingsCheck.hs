module Main where

import Control.Monad (unless)
import Data.Bits (finiteBitSize)
import qualified Data.ByteString as B
import Data.Int (Int8)
import Data.List (isInfixOf)
import System.Environment (getArgs)
import qualified LawSpecCodecs as C
import qualified LawSpecDataSchema as DataSchema
import qualified LawSpecNativeCodecs as Native
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as Schema
import qualified P as Application
import ShapesDomain (Wrapped(..))

right :: Either String a -> a
right = either error id

check :: String -> Bool -> IO ()
check label condition = unless condition (error label)

roundtrip :: (Eq a, Show a) => C.Codec a -> a -> IO ()
roundtrip codec value = check ("native roundtrip: " ++ show value)
  (right (C.encode codec value >>= C.decode codec) == value)

reject :: String -> Either String a -> IO ()
reject fragment value = case value of
  Left message -> check message (fragment `isInfixOf` message)
  Right _ -> error ("invalid native value accepted: " ++ fragment)

main :: IO ()
main = do
  [argument] <- getArgs
  let bits = read argument
      schema = right DataSchema.schema
      boxed = Native.boxCodec schema bits
  roundtrip (boxed (C.codePointTextCodec schema bits))
    (Wrapped (LS.CodePointText ['\0','\xd800','\x10ffff']))
  roundtrip (boxed (C.utf16TextCodec schema bits))
    (Wrapped (LS.Utf16Text [0xd800,0,0xdfff,0xffff]))
  roundtrip (boxed (C.bytesCodec schema bits)) (Wrapped (B.pack [0,128,255]))
  roundtrip (boxed (C.characterCodec schema bits "Char")) (Wrapped '\x1f642')
  roundtrip (boxed (C.characterCodec schema bits "CodePoint")) (Wrapped '\xd800')
  reject "Char" (C.encode (boxed (C.characterCodec schema bits "Char")) (Wrapped '\xd800'))
  let int8 = C.integerCodec schema bits "Int8" :: C.Codec Int8
      presence = boxed (C.optionalCodec schema bits (C.nullableCodec schema bits int8))
      absent = Wrapped LS.UndefinedValue
      presentNull = Wrapped (LS.OptionalValue LS.NullValue)
      present = Wrapped (LS.OptionalValue (LS.NullableValue 127))
  mapM_ (roundtrip presence) [absent,presentNull,present]
  check "collapsed absence states" (not (right (Schema.equal schema (C.reference presence) bits
    (right (C.encode presence absent)) (right (C.encode presence presentNull)))))
  first <- LS.newSymbolContext
  second <- LS.newSymbolContext
  let symbolCodec = boxed (C.symbolCodec schema bits)
      symbol = LS.ScopedSymbol first "fixture" "same"
  roundtrip symbolCodec (Wrapped symbol)
  check "Symbol descriptions became identity" (not (LS.equal
    (right (C.encode symbolCodec (Wrapped symbol)))
    (right (C.encode symbolCodec (Wrapped (LS.ScopedSymbol first "other" "same"))))))
  check "Symbol scopes collapsed" (not (LS.equal
    (right (C.encode symbolCodec (Wrapped symbol)))
    (right (C.encode symbolCodec (Wrapped (LS.ScopedSymbol second "fixture" "same"))))))
  let identity = Native.identityCodecWith (Just first) schema bits
  roundtrip identity (Application.Claim symbol)
  roundtrip identity (Application.Claim (LS.ScopedSymbol first "fixture" "different description"))
  reject "contract rejected" (C.encode identity (Application.Claim (LS.ScopedSymbol second "fixture" "same")))
  let machine = boxed (C.integerCodec schema bits "IntSize" :: C.Codec Int)
  if bits == finiteBitSize (0 :: Int)
    then roundtrip machine (Wrapped 42)
    else reject "architecture" (C.encode machine (Wrapped 42))
  putStrLn ("Haskell native raw values, presence, Symbol contracts and machine profile passed: " ++ show bits)
