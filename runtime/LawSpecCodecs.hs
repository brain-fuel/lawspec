-- | Typed native bridges with checked, contextual conversions.
--
-- Adapters work with their own Haskell types; each codec converts between them
-- and LawSpec's values and checks the result, so a law never sees a native
-- value outside its domain. ref:DEC-native-bindings-typed-identity
module LawSpecCodecs
  ( Codec,
    reference,
    decode,
    encode,
    decoded,
    encoded,
    call1,
    perform1,
    call2,
    perform2,
    call3,
    perform3,
    call4,
    perform4,
    call5,
    perform5,
    call6,
    perform6,
    call7,
    perform7,
    call8,
    perform8,
    codec,
    codecWith,
    context,
    integerCodec,
    boolCodec,
    decimalCodec,
    rationalCodec,
    float32Codec,
    float64Codec,
    complex64Codec,
    complex128Codec,
    characterCodec,
    codeUnitCodec,
    textCodec,
    bytesCodec,
    codePointTextCodec,
    utf16TextCodec,
    symbolCodec,
    unitCodec,
    nullCodec,
    undefinedCodec,
    listCodec,
    maybeCodec,
    eitherCodec,
    nullableCodec,
    optionalCodec,
    listCodecWith,
    maybeCodecWith,
    eitherCodecWith,
    nullableCodecWith,
    optionalCodecWith,
  )
where

import Control.Monad (unless, zipWithM)
import Data.Bits (finiteBitSize)
import qualified Data.ByteString as B
import Data.Char (ord)
import Data.Complex (Complex ((:+)))
import Data.Ratio (denominator, numerator)
import qualified Data.Text as T
import Data.Word (Word16)
import GHC.Float (float2Double)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

data Codec a = Codec
  { reference :: S.TypeRef,
    decode :: LS.Scalar -> Either String a,
    encode :: a -> Either String LS.Scalar
  }

context :: String -> Either String a -> Either String a
context label = either (Left . ((label ++ ": ") ++)) Right

checkNativeProfile :: S.Schema -> S.TypeRef -> Int -> Either String ()
checkNativeProfile schema typeRef bits = do
  unless (bits == 32 || bits == 64) (Left "machineBits must be 32 or 64")
  names <- S.nativeProfileTypes schema typeRef
  unless
    ( all (`notElem` ["IntSize", "UIntSize", "UIntPtr"]) names
        || bits == finiteBitSize (0 :: Int)
    )
    (Left "machineBits does not match native architecture")

codec ::
  S.Schema ->
  Int ->
  S.TypeRef ->
  (LS.Scalar -> Either String a) ->
  (a -> Either String LS.Scalar) ->
  Codec a
codec = codecWith Nothing

codecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  S.TypeRef ->
  (LS.Scalar -> Either String a) ->
  (a -> Either String LS.Scalar) ->
  Codec a
codecWith scope schema bits typeRef decoder encoder =
  Codec typeRef fromValue toValue
  where
    checked = checkNativeProfile schema typeRef bits
    fromValue value = context (show typeRef) $ do
      checked
      validated <- S.validateWith scope schema typeRef bits value
      decoder validated
    toValue value = context (show typeRef) $ do
      checked
      encoded <- encoder value
      S.validateWith scope schema typeRef bits encoded

scalar ::
  (LS.Native a) =>
  S.Schema ->
  Int ->
  String ->
  (a -> Either String LS.Scalar) ->
  Codec a
scalar schema bits name encoder =
  codec
    schema
    bits
    (S.Named name [])
    (\value -> Right (LS.toNative name value bits))
    encoder

integerCodec ::
  (Integral a, LS.Native a) =>
  S.Schema -> Int -> String -> Codec a
integerCodec schema bits name =
  scalar
    schema
    bits
    name
    (Right . LS.SInteger name . toInteger)

boolCodec :: S.Schema -> Int -> Codec Bool
boolCodec schema bits = scalar schema bits "Bool" (Right . LS.SBool)

decimalCodec :: S.Schema -> Int -> Codec LS.Decimal
decimalCodec schema bits =
  scalar
    schema
    bits
    "Decimal"
    (\(LS.Decimal value) -> LS.decimal value)

rationalCodec :: S.Schema -> Int -> Codec Rational
rationalCodec schema bits =
  scalar
    schema
    bits
    "Rational"
    (\value -> Right (LS.SRational (numerator value) (denominator value)))

float32Codec :: S.Schema -> Int -> Codec Float
float32Codec schema bits =
  scalar
    schema
    bits
    "Float32"
    (Right . LS.floatScalar "Float32" . float2Double)

float64Codec :: S.Schema -> Int -> Codec Double
float64Codec schema bits =
  scalar
    schema
    bits
    "Float64"
    (Right . LS.floatScalar "Float64")

complex64Codec :: S.Schema -> Int -> Codec (Complex Float)
complex64Codec schema bits =
  scalar
    schema
    bits
    "Complex64"
    ( \(r :+ i) ->
        Right
          ( LS.SComplex
              "Complex64"
              (LS.floatScalar "Float32" (float2Double r))
              (LS.floatScalar "Float32" (float2Double i))
          )
    )

complex128Codec :: S.Schema -> Int -> Codec (Complex Double)
complex128Codec schema bits =
  scalar
    schema
    bits
    "Complex128"
    ( \(r :+ i) ->
        Right
          ( LS.SComplex
              "Complex128"
              (LS.floatScalar "Float64" r)
              (LS.floatScalar "Float64" i)
          )
    )

characterCodec :: S.Schema -> Int -> String -> Codec Char
characterCodec schema bits name =
  scalar
    schema
    bits
    name
    (Right . LS.SCharacter name . ord)

codeUnitCodec :: S.Schema -> Int -> Codec Word16
codeUnitCodec schema bits =
  scalar
    schema
    bits
    "CodeUnit16"
    (Right . LS.SCharacter "CodeUnit16" . fromIntegral)

textCodec :: S.Schema -> Int -> Codec T.Text
textCodec schema bits =
  scalar
    schema
    bits
    "Text"
    (Right . LS.SSequence "Text" . map ord . T.unpack)

bytesCodec :: S.Schema -> Int -> Codec B.ByteString
bytesCodec schema bits =
  scalar
    schema
    bits
    "Bytes"
    (Right . LS.SSequence "Bytes" . map fromIntegral . B.unpack)

codePointTextCodec :: S.Schema -> Int -> Codec LS.CodePointText
codePointTextCodec schema bits =
  scalar
    schema
    bits
    "CodePointText"
    ( \(LS.CodePointText value) ->
        Right (LS.SSequence "CodePointText" (map ord value))
    )

utf16TextCodec :: S.Schema -> Int -> Codec LS.Utf16Text
utf16TextCodec schema bits =
  scalar
    schema
    bits
    "Utf16Text"
    ( \(LS.Utf16Text value) ->
        Right (LS.SSequence "Utf16Text" (map fromIntegral value))
    )

symbolCodec :: S.Schema -> Int -> Codec LS.Symbol
symbolCodec schema bits =
  scalar
    schema
    bits
    "Symbol"
    encodeSymbol
  where
    encodeSymbol (LS.Symbol identity description) =
      Right (LS.SSymbol identity description)
    encodeSymbol (LS.ScopedSymbol scope identity description) =
      Right (LS.SScopedSymbol scope identity description)

unitCodec :: S.Schema -> Int -> Codec ()
unitCodec schema bits =
  scalar
    schema
    bits
    "Unit"
    (\() -> Right (LS.SAbsent "Unit"))

nullCodec :: S.Schema -> Int -> Codec LS.Null
nullCodec schema bits =
  scalar
    schema
    bits
    "Null"
    (\LS.Null -> Right (LS.SAbsent "Null"))

undefinedCodec :: S.Schema -> Int -> Codec LS.Undefined
undefinedCodec schema bits =
  scalar
    schema
    bits
    "Undefined"
    (\LS.Undefined -> Right (LS.SAbsent "Undefined"))

listCodec :: S.Schema -> Int -> Codec a -> Codec [a]
listCodec = listCodecWith Nothing

listCodecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  Codec a ->
  Codec [a]
listCodecWith scope schema bits element =
  codecWith
    scope
    schema
    bits
    (S.Named "List" [reference element])
    fromValue
    toValue
  where
    fromValue (LS.SList values) =
      zipWithM
        ( \index value ->
            context
              ("List[" ++ show index ++ "]")
              (decode element value)
        )
        [0 :: Int ..]
        values
    fromValue _ = Left "invalid checked List"
    toValue values =
      LS.SList
        <$> zipWithM
          ( \index value ->
              context
                ("List[" ++ show index ++ "]")
                (encode element value)
          )
          [0 :: Int ..]
          values

maybeCodec :: S.Schema -> Int -> Codec a -> Codec (Maybe a)
maybeCodec = maybeCodecWith Nothing

maybeCodecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  Codec a ->
  Codec (Maybe a)
maybeCodecWith scope schema bits element =
  codecWith
    scope
    schema
    bits
    (S.Named "Maybe" [reference element])
    fromValue
    toValue
  where
    fromValue (LS.SData "Maybe::Absent" []) = Right Nothing
    fromValue (LS.SData "Maybe::Present" [value]) =
      Just <$> context "Maybe::Present.value" (decode element value)
    fromValue _ = Left "invalid checked Maybe"
    toValue Nothing = Right (LS.SData "Maybe::Absent" [])
    toValue (Just value) = do
      field <- context "Maybe::Present.value" (encode element value)
      pure (LS.SData "Maybe::Present" [field])

eitherCodec :: S.Schema -> Int -> Codec a -> Codec b -> Codec (Either a b)
eitherCodec = eitherCodecWith Nothing

eitherCodecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  Codec a ->
  Codec b ->
  Codec (Either a b)
eitherCodecWith scope schema bits left right =
  codecWith
    scope
    schema
    bits
    (S.Named "Either" [reference left, reference right])
    fromValue
    toValue
  where
    fromValue (LS.SData "Either::Left" [value]) =
      Left <$> context "Either::Left.value" (decode left value)
    fromValue (LS.SData "Either::Right" [value]) =
      Right <$> context "Either::Right.value" (decode right value)
    fromValue _ = Left "invalid checked Either"
    toValue (Left value) = do
      field <- context "Either::Left.value" (encode left value)
      pure (LS.SData "Either::Left" [field])
    toValue (Right value) = do
      field <- context "Either::Right.value" (encode right value)
      pure (LS.SData "Either::Right" [field])

nullableCodec :: S.Schema -> Int -> Codec a -> Codec (LS.Nullable a)
nullableCodec = nullableCodecWith Nothing

nullableCodecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  Codec a ->
  Codec (LS.Nullable a)
nullableCodecWith scope schema bits element =
  codecWith
    scope
    schema
    bits
    (S.Named "Nullable" [reference element])
    fromValue
    toValue
  where
    fromValue (LS.SPresent "Nullable" Nothing) = Right LS.NullValue
    fromValue (LS.SPresent "Nullable" (Just value)) =
      LS.NullableValue <$> context "Nullable.value" (decode element value)
    fromValue _ = Left "invalid checked Nullable"
    toValue LS.NullValue = Right (LS.SPresent "Nullable" Nothing)
    toValue (LS.NullableValue value) = do
      field <- context "Nullable.value" (encode element value)
      pure (LS.SPresent "Nullable" (Just field))

optionalCodec :: S.Schema -> Int -> Codec a -> Codec (LS.Optional a)
optionalCodec = optionalCodecWith Nothing

optionalCodecWith ::
  Maybe LS.SymbolContext ->
  S.Schema ->
  Int ->
  Codec a ->
  Codec (LS.Optional a)
optionalCodecWith scope schema bits element =
  codecWith
    scope
    schema
    bits
    (S.Named "Optional" [reference element])
    fromValue
    toValue
  where
    fromValue (LS.SPresent "Optional" Nothing) = Right LS.UndefinedValue
    fromValue (LS.SPresent "Optional" (Just value)) =
      LS.OptionalValue <$> context "Optional.value" (decode element value)
    fromValue _ = Left "invalid checked Optional"
    toValue LS.UndefinedValue = Right (LS.SPresent "Optional" Nothing)
    toValue (LS.OptionalValue value) = do
      field <- context "Optional.value" (encode element value)
      pure (LS.SPresent "Optional" (Just field))

-- | A law's value as the native value an adapter takes; an error says why
-- it is not one.
decoded :: Codec a -> LS.Scalar -> a
decoded c = either error id . decode c

-- | An adapter's native result as a law's value, checked.
encoded :: Codec a -> a -> LS.Scalar
encoded c = either error id . encode c

-- | An adapter called with a law's values: each argument is evaluated in
-- full and decoded with its codec, and the result is encoded and checked
-- with the result's codec. callN takes N arguments; performN runs an
-- adapter that performs operations, in IO.
call1 :: Codec a -> Codec r -> (a -> r) -> LS.Scalar -> LS.Scalar
call1 ca result adapter x1 =
  LS.forcing [x1] (encoded result (adapter (decoded ca x1)))

{-# NOINLINE perform1 #-}
perform1 :: Codec a -> Codec r -> (a -> IO r) -> LS.Scalar -> LS.Scalar
perform1 ca result adapter =
  call1 ca result (\a -> LS.performIO (adapter a))

call2 :: Codec a -> Codec b -> Codec r -> (a -> b -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar
call2 ca cb result adapter x1 x2 =
  LS.forcing [x1, x2] (encoded result (adapter (decoded ca x1) (decoded cb x2)))

{-# NOINLINE perform2 #-}
perform2 :: Codec a -> Codec b -> Codec r -> (a -> b -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform2 ca cb result adapter =
  call2 ca cb result (\a b -> LS.performIO (adapter a b))

call3 :: Codec a -> Codec b -> Codec c -> Codec r -> (a -> b -> c -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call3 ca cb cc result adapter x1 x2 x3 =
  LS.forcing [x1, x2, x3] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3)))

{-# NOINLINE perform3 #-}
perform3 :: Codec a -> Codec b -> Codec c -> Codec r -> (a -> b -> c -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform3 ca cb cc result adapter =
  call3 ca cb cc result (\a b c -> LS.performIO (adapter a b c))

call4 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec r -> (a -> b -> c -> d -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call4 ca cb cc cd result adapter x1 x2 x3 x4 =
  LS.forcing [x1, x2, x3, x4] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3) (decoded cd x4)))

{-# NOINLINE perform4 #-}
perform4 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec r -> (a -> b -> c -> d -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform4 ca cb cc cd result adapter =
  call4 ca cb cc cd result (\a b c d -> LS.performIO (adapter a b c d))

call5 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec r -> (a -> b -> c -> d -> e -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call5 ca cb cc cd ce result adapter x1 x2 x3 x4 x5 =
  LS.forcing [x1, x2, x3, x4, x5] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3) (decoded cd x4) (decoded ce x5)))

{-# NOINLINE perform5 #-}
perform5 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec r -> (a -> b -> c -> d -> e -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform5 ca cb cc cd ce result adapter =
  call5 ca cb cc cd ce result (\a b c d e -> LS.performIO (adapter a b c d e))

call6 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec r -> (a -> b -> c -> d -> e -> f -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call6 ca cb cc cd ce cf result adapter x1 x2 x3 x4 x5 x6 =
  LS.forcing [x1, x2, x3, x4, x5, x6] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3) (decoded cd x4) (decoded ce x5) (decoded cf x6)))

{-# NOINLINE perform6 #-}
perform6 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec r -> (a -> b -> c -> d -> e -> f -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform6 ca cb cc cd ce cf result adapter =
  call6 ca cb cc cd ce cf result (\a b c d e f -> LS.performIO (adapter a b c d e f))

call7 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec g -> Codec r -> (a -> b -> c -> d -> e -> f -> g -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call7 ca cb cc cd ce cf cg result adapter x1 x2 x3 x4 x5 x6 x7 =
  LS.forcing [x1, x2, x3, x4, x5, x6, x7] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3) (decoded cd x4) (decoded ce x5) (decoded cf x6) (decoded cg x7)))

{-# NOINLINE perform7 #-}
perform7 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec g -> Codec r -> (a -> b -> c -> d -> e -> f -> g -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform7 ca cb cc cd ce cf cg result adapter =
  call7 ca cb cc cd ce cf cg result (\a b c d e f g -> LS.performIO (adapter a b c d e f g))

call8 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec g -> Codec h -> Codec r -> (a -> b -> c -> d -> e -> f -> g -> h -> r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
call8 ca cb cc cd ce cf cg ch result adapter x1 x2 x3 x4 x5 x6 x7 x8 =
  LS.forcing [x1, x2, x3, x4, x5, x6, x7, x8] (encoded result (adapter (decoded ca x1) (decoded cb x2) (decoded cc x3) (decoded cd x4) (decoded ce x5) (decoded cf x6) (decoded cg x7) (decoded ch x8)))

{-# NOINLINE perform8 #-}
perform8 :: Codec a -> Codec b -> Codec c -> Codec d -> Codec e -> Codec f -> Codec g -> Codec h -> Codec r -> (a -> b -> c -> d -> e -> f -> g -> h -> IO r) -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar -> LS.Scalar
perform8 ca cb cc cd ce cf cg ch result adapter =
  call8 ca cb cc cd ce cf cg ch result (\a b c d e f g h -> LS.performIO (adapter a b c d e f g h))
