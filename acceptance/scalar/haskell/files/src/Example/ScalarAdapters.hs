-- User-owned LawSpec adapter.
module Example.ScalarAdapters where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data

-- (Char -> Char)
echoChar :: P.Char -> P.Char
echoChar value0 = value0

-- (CodePoint -> CodePoint)
echoCodePoint :: P.Char -> P.Char
echoCodePoint value0 = value0

-- (CodeUnit16 -> CodeUnit16)
echoCodeUnit :: W.Word16 -> W.Word16
echoCodeUnit value0 = value0

-- (Bytes -> Bytes)
echoBytes :: B.ByteString -> B.ByteString
echoBytes value0 = value0

-- (Complex64 -> Complex64)
echoComplex :: (C.Complex P.Float) -> (C.Complex P.Float)
echoComplex value0 = value0

-- (Int8 -> BigInt)
successor :: I.Int8 -> P.Integer
successor value0 = toInteger value0 + 1

-- (Int8 -> Int8)
narrow :: I.Int8 -> I.Int8
narrow value0 = value0

-- (Decimal -> (Decimal -> Decimal))
addDecimal :: LS.Decimal -> LS.Decimal -> LS.Decimal
addDecimal value0 value1 = case (value0,value1) of (LS.Decimal a,LS.Decimal b) -> LS.Decimal (a+b)

-- (Symbol -> (Symbol -> Bool))
sameSymbol :: LS.Symbol -> LS.Symbol -> P.Bool
sameSymbol value0 value1 = value0 == value1

-- (Utf16Text -> Utf16Text)
echoRaw :: LS.Utf16Text -> LS.Utf16Text
echoRaw value0 = value0

-- (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
echoPresence ::
  (LS.Optional (LS.Nullable I.Int8))
  -> (LS.Optional (LS.Nullable I.Int8))
echoPresence value0 = value0

-- (Unit -> Unit)
finish :: () -> ()
finish value0 = ()

-- (UInt64 -> UInt64)
preserveBig :: W.Word64 -> W.Word64
preserveBig value0 = value0

-- (IntSize -> IntSize)
machineEcho :: P.Int -> P.Int
machineEcho value0 = value0
