-- Typed native bridges with checked, contextual conversions.
module LawSpecCodecs
  ( Codec, reference, decode, encode, codec, codecWith, context
  , integerCodec, boolCodec, decimalCodec, rationalCodec
  , float32Codec, float64Codec, complex64Codec, complex128Codec
  , characterCodec, codeUnitCodec, textCodec, bytesCodec
  , codePointTextCodec, utf16TextCodec, symbolCodec
  , unitCodec, nullCodec, undefinedCodec
  , listCodec, maybeCodec, eitherCodec, nullableCodec, optionalCodec
  , listCodecWith, maybeCodecWith, eitherCodecWith
  , nullableCodecWith, optionalCodecWith
  ) where

import Control.Monad (unless, foldM, zipWithM)
import Data.Bits (finiteBitSize)
import Data.Char (ord)
import Data.Complex (Complex((:+)))
import Data.Ratio (numerator, denominator)
import Data.Word (Word16)
import qualified Data.ByteString as B
import qualified Data.Text as T
import GHC.Float (float2Double)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

data Codec a = Codec
  { reference :: S.TypeRef
  , decode :: LS.Scalar -> Either String a
  , encode :: a -> Either String LS.Scalar
  }

context :: String -> Either String a -> Either String a
context label = either (Left . ((label ++ ": ") ++)) Right

checkNativeProfile :: S.Schema -> S.TypeRef -> Int -> Either String ()
checkNativeProfile schema typeRef bits = do
  unless (bits == 32 || bits == 64) (Left "machineBits must be 32 or 64")
  S.checkType schema 0 typeRef
  _ <- visit [] typeRef
  pure ()
  where
    visit _ (S.Parameter _) = Left "unbound native type parameter"
    visit seen current@(S.Named name arguments) = do
      previous <- foldM visit seen arguments
      unless (name `notElem` ["IntSize", "UIntSize", "UIntPtr"] ||
              bits == finiteBitSize (0 :: Int))
        (Left "machineBits does not match native architecture")
      if name `elem` previous then pure previous else do
        variants <- S.constructors schema current
        let fields = [ty | S.Constructor _ items <- maybe [] id variants,
                           S.Field _ ty <- items]
        foldM visit (name : previous) fields

codec :: S.Schema -> Int -> S.TypeRef
      -> (LS.Scalar -> Either String a)
      -> (a -> Either String LS.Scalar) -> Codec a
codec = codecWith Nothing

codecWith :: Maybe LS.SymbolContext -> S.Schema -> Int -> S.TypeRef
          -> (LS.Scalar -> Either String a)
          -> (a -> Either String LS.Scalar) -> Codec a
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

scalar :: LS.Native a => S.Schema -> Int -> String
       -> (a -> Either String LS.Scalar) -> Codec a
scalar schema bits name encoder = codec schema bits (S.Named name [])
  (\value -> Right (LS.toNative name value bits)) encoder

integerCodec :: (Integral a, LS.Native a)
             => S.Schema -> Int -> String -> Codec a
integerCodec schema bits name = scalar schema bits name
  (Right . LS.SInteger name . toInteger)

boolCodec :: S.Schema -> Int -> Codec Bool
boolCodec schema bits = scalar schema bits "Bool" (Right . LS.SBool)

decimalCodec :: S.Schema -> Int -> Codec LS.Decimal
decimalCodec schema bits = scalar schema bits "Decimal"
  (\(LS.Decimal value) -> LS.decimal value)

rationalCodec :: S.Schema -> Int -> Codec Rational
rationalCodec schema bits = scalar schema bits "Rational"
  (\value -> Right (LS.SRational (numerator value) (denominator value)))

float32Codec :: S.Schema -> Int -> Codec Float
float32Codec schema bits = scalar schema bits "Float32"
  (Right . LS.floatScalar "Float32" . float2Double)

float64Codec :: S.Schema -> Int -> Codec Double
float64Codec schema bits = scalar schema bits "Float64"
  (Right . LS.floatScalar "Float64")

complex64Codec :: S.Schema -> Int -> Codec (Complex Float)
complex64Codec schema bits = scalar schema bits "Complex64"
  (\(r :+ i) -> Right (LS.SComplex "Complex64"
    (LS.floatScalar "Float32" (float2Double r))
    (LS.floatScalar "Float32" (float2Double i))))

complex128Codec :: S.Schema -> Int -> Codec (Complex Double)
complex128Codec schema bits = scalar schema bits "Complex128"
  (\(r :+ i) -> Right (LS.SComplex "Complex128"
    (LS.floatScalar "Float64" r) (LS.floatScalar "Float64" i)))

characterCodec :: S.Schema -> Int -> String -> Codec Char
characterCodec schema bits name = scalar schema bits name
  (Right . LS.SCharacter name . ord)

codeUnitCodec :: S.Schema -> Int -> Codec Word16
codeUnitCodec schema bits = scalar schema bits "CodeUnit16"
  (Right . LS.SCharacter "CodeUnit16" . fromIntegral)

textCodec :: S.Schema -> Int -> Codec T.Text
textCodec schema bits = scalar schema bits "Text"
  (Right . LS.SSequence "Text" . map ord . T.unpack)

bytesCodec :: S.Schema -> Int -> Codec B.ByteString
bytesCodec schema bits = scalar schema bits "Bytes"
  (Right . LS.SSequence "Bytes" . map fromIntegral . B.unpack)

codePointTextCodec :: S.Schema -> Int -> Codec LS.CodePointText
codePointTextCodec schema bits = scalar schema bits "CodePointText"
  (\(LS.CodePointText value) ->
    Right (LS.SSequence "CodePointText" (map ord value)))

utf16TextCodec :: S.Schema -> Int -> Codec LS.Utf16Text
utf16TextCodec schema bits = scalar schema bits "Utf16Text"
  (\(LS.Utf16Text value) ->
    Right (LS.SSequence "Utf16Text" (map fromIntegral value)))

symbolCodec :: S.Schema -> Int -> Codec LS.Symbol
symbolCodec schema bits = scalar schema bits "Symbol"
  encodeSymbol
  where
    encodeSymbol (LS.Symbol identity description) =
      Right (LS.SSymbol identity description)
    encodeSymbol (LS.ScopedSymbol scope identity description) =
      Right (LS.SScopedSymbol scope identity description)

unitCodec :: S.Schema -> Int -> Codec ()
unitCodec schema bits = scalar schema bits "Unit"
  (\() -> Right (LS.SAbsent "Unit"))

nullCodec :: S.Schema -> Int -> Codec LS.Null
nullCodec schema bits = scalar schema bits "Null"
  (\LS.Null -> Right (LS.SAbsent "Null"))

undefinedCodec :: S.Schema -> Int -> Codec LS.Undefined
undefinedCodec schema bits = scalar schema bits "Undefined"
  (\LS.Undefined -> Right (LS.SAbsent "Undefined"))

listCodec :: S.Schema -> Int -> Codec a -> Codec [a]
listCodec = listCodecWith Nothing

listCodecWith :: Maybe LS.SymbolContext -> S.Schema -> Int
              -> Codec a -> Codec [a]
listCodecWith scope schema bits element = codecWith scope schema bits
  (S.Named "List" [reference element]) fromValue toValue
  where
    fromValue (LS.SList values) = zipWithM
      (\index value -> context ("List[" ++ show index ++ "]")
        (decode element value)) [0 :: Int ..] values
    fromValue _ = Left "invalid checked List"
    toValue values = LS.SList <$> zipWithM
      (\index value -> context ("List[" ++ show index ++ "]")
        (encode element value)) [0 :: Int ..] values

maybeCodec :: S.Schema -> Int -> Codec a -> Codec (Maybe a)
maybeCodec = maybeCodecWith Nothing

maybeCodecWith :: Maybe LS.SymbolContext -> S.Schema -> Int
               -> Codec a -> Codec (Maybe a)
maybeCodecWith scope schema bits element = codecWith scope schema bits
  (S.Named "Maybe" [reference element]) fromValue toValue
  where
    fromValue (LS.SData "Maybe::Nothing" []) = Right Nothing
    fromValue (LS.SData "Maybe::Just" [value]) =
      Just <$> context "Maybe::Just.value" (decode element value)
    fromValue _ = Left "invalid checked Maybe"
    toValue Nothing = Right (LS.SData "Maybe::Nothing" [])
    toValue (Just value) = do
      field <- context "Maybe::Just.value" (encode element value)
      pure (LS.SData "Maybe::Just" [field])

eitherCodec :: S.Schema -> Int -> Codec a -> Codec b -> Codec (Either a b)
eitherCodec = eitherCodecWith Nothing

eitherCodecWith :: Maybe LS.SymbolContext -> S.Schema -> Int
                -> Codec a -> Codec b -> Codec (Either a b)
eitherCodecWith scope schema bits left right = codecWith scope schema bits
  (S.Named "Either" [reference left, reference right]) fromValue toValue
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

nullableCodecWith :: Maybe LS.SymbolContext -> S.Schema -> Int
                  -> Codec a -> Codec (LS.Nullable a)
nullableCodecWith scope schema bits element = codecWith scope schema bits
  (S.Named "Nullable" [reference element]) fromValue toValue
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

optionalCodecWith :: Maybe LS.SymbolContext -> S.Schema -> Int
                  -> Codec a -> Codec (LS.Optional a)
optionalCodecWith scope schema bits element = codecWith scope schema bits
  (S.Named "Optional" [reference element]) fromValue toValue
  where
    fromValue (LS.SPresent "Optional" Nothing) = Right LS.UndefinedValue
    fromValue (LS.SPresent "Optional" (Just value)) =
      LS.OptionalValue <$> context "Optional.value" (decode element value)
    fromValue _ = Left "invalid checked Optional"
    toValue LS.UndefinedValue = Right (LS.SPresent "Optional" Nothing)
    toValue (LS.OptionalValue value) = do
      field <- context "Optional.value" (encode element value)
      pure (LS.SPresent "Optional" (Just field))
