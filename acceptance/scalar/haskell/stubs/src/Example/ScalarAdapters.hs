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
echoChar _ = error "echoChar"

-- (CodePoint -> CodePoint)
echoCodePoint :: P.Char -> P.Char
echoCodePoint _ = error "echoCodePoint"

-- (CodeUnit16 -> CodeUnit16)
echoCodeUnit :: W.Word16 -> W.Word16
echoCodeUnit _ = error "echoCodeUnit"

-- (Bytes -> Bytes)
echoBytes :: B.ByteString -> B.ByteString
echoBytes _ = error "echoBytes"

-- (Complex64 -> Complex64)
echoComplex :: (C.Complex P.Float) -> (C.Complex P.Float)
echoComplex _ = error "echoComplex"

-- (Int8 -> BigInt)
successor :: I.Int8 -> P.Integer
successor _ = error "successor"

-- (Int8 -> Int8)
narrow :: I.Int8 -> I.Int8
narrow _ = error "narrow"

-- (Decimal -> (Decimal -> Decimal))
addDecimal :: LS.Decimal -> LS.Decimal -> LS.Decimal
addDecimal _ _ = error "addDecimal"

-- (Symbol -> (Symbol -> Bool))
sameSymbol :: LS.Symbol -> LS.Symbol -> P.Bool
sameSymbol _ _ = error "sameSymbol"

-- (Utf16Text -> Utf16Text)
echoRaw :: LS.Utf16Text -> LS.Utf16Text
echoRaw _ = error "echoRaw"

-- (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
echoPresence ::
  (LS.Optional (LS.Nullable I.Int8))
  -> (LS.Optional (LS.Nullable I.Int8))
echoPresence _ = error "echoPresence"

-- (Unit -> Unit)
finish :: () -> ()
finish _ = error "finish"

-- (UInt64 -> UInt64)
preserveBig :: W.Word64 -> W.Word64
preserveBig _ = error "preserveBig"

-- (IntSize -> IntSize)
machineEcho :: P.Int -> P.Int
machineEcho _ = error "machineEcho"
