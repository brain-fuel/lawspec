-- User-owned LawSpec adapter for example.scalar_adapters: implement each function.
module Example.ScalarAdapters where

import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import Prelude
import qualified Prelude as P

-- echoChar :: Char -> Char — scalar_adapters.lawspec:2
echoChar :: P.Char -> P.Char
echoChar _ = P.error "echoChar"

-- echoCodePoint :: CodePoint -> CodePoint — scalar_adapters.lawspec:3
echoCodePoint :: P.Char -> P.Char
echoCodePoint _ = P.error "echoCodePoint"

-- echoCodeUnit :: CodeUnit16 -> CodeUnit16 — scalar_adapters.lawspec:4
echoCodeUnit :: W.Word16 -> W.Word16
echoCodeUnit _ = P.error "echoCodeUnit"

-- echoBytes :: Bytes -> Bytes — scalar_adapters.lawspec:5
echoBytes :: B.ByteString -> B.ByteString
echoBytes _ = P.error "echoBytes"

-- echoComplex :: Complex64 -> Complex64 — scalar_adapters.lawspec:6
echoComplex :: (C.Complex P.Float) -> (C.Complex P.Float)
echoComplex _ = P.error "echoComplex"

-- successor :: Int8 -> Integer — scalar_adapters.lawspec:7
successor :: I.Int8 -> LS.IntegerValue
successor _ = P.error "successor"

-- narrow :: Int8 -> Int8 — scalar_adapters.lawspec:8
narrow :: I.Int8 -> I.Int8
narrow _ = P.error "narrow"

-- addDecimal :: Decimal -> Decimal -> Decimal — scalar_adapters.lawspec:9
addDecimal :: LS.Decimal -> LS.Decimal -> LS.Decimal
addDecimal _ _ = P.error "addDecimal"

-- sameSymbol :: Symbol -> Symbol -> Bool — scalar_adapters.lawspec:10
sameSymbol :: LS.Symbol -> LS.Symbol -> P.Bool
sameSymbol _ _ = P.error "sameSymbol"

-- echoRaw :: Utf16Text -> Utf16Text — scalar_adapters.lawspec:11
echoRaw :: LS.Utf16Text -> LS.Utf16Text
echoRaw _ = P.error "echoRaw"

-- echoPresence :: Optional (Nullable (Int8)) -> Optional (Nullable (Int8)) —
-- scalar_adapters.lawspec:12
echoPresence ::
  (LS.Optional (LS.Nullable I.Int8)) ->
  (LS.Optional (LS.Nullable I.Int8))
echoPresence _ = P.error "echoPresence"

-- finish :: Unit -> Unit — scalar_adapters.lawspec:13
finish :: () -> ()
finish _ = P.error "finish"

-- preserveBig :: UInt64 -> UInt64 — scalar_adapters.lawspec:14
preserveBig :: W.Word64 -> W.Word64
preserveBig _ = P.error "preserveBig"

-- machineEcho :: IntSize -> IntSize — scalar_adapters.lawspec:15
machineEcho :: P.Int -> P.Int
machineEcho _ = P.error "machineEcho"
