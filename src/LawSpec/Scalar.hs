-- The portable scalar domain. No test framework or target runtime dependencies.
module LawSpec.Scalar where

import Data.Aeson (ToJSON(..), object, (.=))
import Data.Char (ord)
import Data.List (find)
import Data.Ratio
import GHC.Float (castFloatToWord32, castDoubleToWord64, castWord32ToFloat, castWord64ToDouble)
import Numeric (showHex, readHex)

data Family = Boolean | IntegerFamily | Exact | Floating | Complex | Character | Sequence | Identity | Absence deriving (Eq, Show)
data Primitive = Primitive { primitiveName :: String, family :: Family, width :: Maybe Int, signed :: Bool } deriving (Eq, Show)
primitives :: [Primitive]
primitives = [Primitive "Bool" Boolean Nothing False]
  ++ [Primitive (p ++ show w) IntegerFamily (Just w) s | (p,s) <- [("Int",True),("UInt",False)], w <- [8,16,32,64]]
  ++ [Primitive n IntegerFamily Nothing s | (n,s) <- [("IntSize",True),("UIntSize",False),("UIntPtr",False),("Integer",True),("BigInt",True),("BigUInt",False)]]
  ++ [Primitive n f w False | (n,f,w) <- [("Decimal",Exact,Nothing),("Rational",Exact,Nothing),("Float32",Floating,Just 32),("Float64",Floating,Just 64),("Complex64",Complex,Just 32),("Complex128",Complex,Just 64)]]
  ++ [Primitive n f Nothing False | (f,ns) <- [(Character,["Char","CodePoint","CodeUnit16"]),(Sequence,["Text","CodePointText","Utf16Text","Bytes"]),(Identity,["Symbol"]),(Absence,["Unit","Null","Undefined"])], n <- ns]
primitive :: String -> Maybe Primitive
primitive n = find ((== n) . primitiveName) primitives
isInteger, isExact, isInexact, isNumeric :: String -> Bool
isInteger n = maybe False ((== IntegerFamily) . family) (primitive n)
isExact n = isInteger n || n `elem` ["Decimal","Rational"]
isInexact n = n `elem` ["Float32","Float64","Complex64","Complex128"]
isNumeric n = isExact n || isInexact n
integerBounds :: Int -> String -> Maybe (Integer, Integer)
integerBounds machine n = do
  p <- primitive n
  w <- if n `elem` ["IntSize","UIntSize","UIntPtr"] then Just machine else width p
  if family p /= IntegerFamily then Nothing else pure $ if signed p then (negate (2^(w-1)),2^(w-1)-1) else (0,2^w-1)

-- Raw strings travel as numeric code points/units, never JSON surrogate strings.
data Scalar = SInteger String Integer | SBool Bool | SDecimal Integer Integer
  | SRational Integer Integer | SFloat String String | SComplex String Scalar Scalar
  | SSequence String [Int] | SCharacter String Int | SSymbol String String
  | SAbsent String | SPresent String (Maybe Scalar) deriving (Eq, Show)
scalarName :: Scalar -> String
scalarName (SInteger t _) = t
scalarName (SBool _) = "Bool"
scalarName (SDecimal _ _) = "Decimal"
scalarName (SRational _ _) = "Rational"
scalarName (SFloat t _) = t
scalarName (SComplex t _ _) = t
scalarName (SSequence t _) = t
scalarName (SCharacter t _) = t
scalarName (SSymbol _ _) = "Symbol"
scalarName (SAbsent t) = t
scalarName (SPresent t _) = t
instance ToJSON Scalar where
  toJSON s = object $ ["type" .= scalarName s] ++ case s of
    SInteger _ n -> ["value" .= show n]
    SBool b -> ["value" .= b]
    SDecimal c e -> ["coefficient" .= show c,"exponent" .= show e]
    SRational n d -> ["numerator" .= show n,"denominator" .= show d]
    SFloat _ bits -> ["bits" .= bits]
    SComplex _ r i -> ["real" .= r,"imaginary" .= i]
    SSequence _ xs -> ["units" .= xs]
    SCharacter _ c -> ["value" .= c]
    SSymbol i d -> ["id" .= i,"description" .= d]
    SAbsent _ -> []
    SPresent _ v -> ["value" .= v]

floatScalar :: String -> Double -> Scalar
floatScalar t x = SFloat t $ pad (if t == "Float32" then 8 else 16) $ if t == "Float32" then showHex (castFloatToWord32 (realToFrac x)) "" else showHex (castDoubleToWord64 x) ""
  where pad n s = replicate (n-length s) '0' ++ s
floatValue :: Scalar -> Double
floatValue (SFloat t bits) = case readHex bits of
  [(n,"")] -> if t == "Float32" then realToFrac (castWord32ToFloat (fromInteger n)) else castWord64ToDouble (fromInteger n)
  _ -> error "invalid internal float bits"
floatValue _ = error "not a float"
exactValue :: Scalar -> Either String Rational
exactValue (SInteger _ n) = Right (n % 1)
exactValue (SRational n d) | d /= 0 = Right (n % d)
exactValue (SDecimal c e) = Right (if e >= 0 then c * 10^e % 1 else c % 10^(-e))
exactValue _ = Left "requires an exact numeric value"
reduced :: Rational -> Scalar
reduced r = SRational (numerator r) (denominator r)
decimal :: Rational -> Either String Scalar
decimal r = go (denominator r) 0 0 where
  go d a b | d `mod` 2 == 0 = go (d `div` 2) (a+1) b
           | d `mod` 5 == 0 = go (d `div` 5) a (b+1)
           | d /= 1 = Left "conversion to Decimal is not finite; use prelude.round"
           | otherwise = let scale = max a b in Right (SDecimal (numerator r * 2^(scale-a) * 5^(scale-b)) (-scale))
validateScalar :: Int -> Scalar -> Either String Scalar
validateScalar machine s = case s of
  SInteger t n | not (isInteger t) -> Left "unknown integer type"
               | t == "BigUInt" && n < 0 -> Left "BigUInt cannot be negative"
               | Just (lo,hi) <- integerBounds machine t, n < lo || n > hi -> Left ("integer outside " ++ t ++ " range")
               | otherwise -> Right s
  SRational n d | d == 0 -> Left "Rational denominator cannot be zero"
                | otherwise -> Right (reduced (n % d))
  SCharacter t c | validUnit t c -> Right s
                 | otherwise -> Left ("invalid " ++ t ++ " representation")
  SSequence t xs | t `elem` ["Text","CodePointText","Utf16Text","Bytes"], all (validUnit t) xs -> Right s
                | otherwise -> Left ("invalid " ++ t ++ " representation")
  SFloat t bits | t `elem` ["Float32","Float64"], length bits == (if t == "Float32" then 8 else 16), [(_,"")] <- (readHex bits :: [(Integer,String)]) -> Right s
               | otherwise -> Left "invalid IEEE bit representation"
  SComplex t r i | t `elem` ["Complex64","Complex128"], all ((== if t == "Complex64" then "Float32" else "Float64") . scalarName) [r,i] -> SComplex t <$> validateScalar machine r <*> validateScalar machine i
                 | otherwise -> Left "complex component precision mismatch"
  SSymbol i d | all (validUnit "Text" . ord) (i ++ d) -> Right s
              | otherwise -> Left "Symbol IDs and descriptions must contain Unicode scalars"
  SAbsent t | t `elem` ["Unit","Null","Undefined"] -> Right s
            | otherwise -> Left "unknown absence value"
  SPresent t v | t `elem` ["Nullable","Optional"] -> SPresent t <$> traverse (validateScalar machine) v
               | otherwise -> Left "unknown presence type"
  _ -> Right s
validUnit :: String -> Int -> Bool
validUnit t c
  | t == "Bytes" = c >= 0 && c <= 255
  | t `elem` ["CodeUnit16","Utf16Text"] = c >= 0 && c <= 65535
  | t `elem` ["CodePoint","CodePointText"] = c >= 0 && c <= 1114111
  | t `elem` ["Char","Text"] = c >= 0 && c <= 1114111 && (c < 55296 || c > 57343)
  | otherwise = False
promote :: String -> String -> String -> Either String String
promote op a b
  | not (isNumeric a && isNumeric b) = Left "arithmetic requires numeric operands (Bool is not an integer)"
  | isExact a /= isExact b = Left "exact/inexact mixing requires an explicit conversion"
  | op `elem` ["quot","rem"] = if isInteger a && isInteger b then Right "Integer" else Left "quot/rem require integer operands"
  | isExact a = Right $ if op == "/" || "Rational" `elem` [a,b] then "Rational" else if "Decimal" `elem` [a,b] then "Decimal" else "Integer"
  | otherwise = Right $ if any (`elem` ["Complex64","Complex128"]) [a,b]
      then if any (`elem` ["Float64","Complex128"]) [a,b] then "Complex128" else "Complex64"
      else if "Float64" `elem` [a,b] then "Float64" else "Float32"
convertScalar :: Int -> String -> Scalar -> Either String Scalar
convertScalar machine t s
  | t == scalarName s = validateScalar machine s
  | isInteger t = do r <- exactValue s; if denominator r /= 1 then Left ("fractional conversion to " ++ t) else validateScalar machine (SInteger t (numerator r))
  | t == "Rational" = reduced <$> exactValue s
  | t == "Decimal" = exactValue s >>= decimal
  | t `elem` ["Float32","Float64"] = if isExact (scalarName s) then (\r -> if t == "Float32" then SFloat t (pad8 (showHex (castFloatToWord32 (fromRational r)) "")) else floatScalar t (fromRational r)) <$> exactValue s else case s of
      SFloat _ _ -> Right (floatScalar t (floatValue s))
      _ -> Left "conversion requires a real number"
  | t `elem` ["Complex64","Complex128"] =
      let component = if t == "Complex64" then "Float32" else "Float64" in case s of
        SComplex _ r i -> SComplex t <$> convertScalar machine component r <*> convertScalar machine component i
        _ -> SComplex t <$> convertScalar machine component s <*> pure (floatScalar component 0)
  | otherwise = Left ("cannot convert " ++ scalarName s ++ " to " ++ t)
scalarBoundaries :: Int -> String -> [Scalar]
scalarBoundaries machine t
  | isInteger t = map (SInteger t) $ case integerBounds machine t of Just (lo,hi) -> [lo, max lo (-1),0,hi]; Nothing -> if t == "BigUInt" then [0,1,2^(128::Int)] else [-2^(128::Int),-1,0,2^(128::Int)]
  | otherwise = case t of
      "Bool" -> map SBool [False,True]
      "Decimal" -> [SDecimal 0 0,SDecimal 1 (-1),SDecimal (-123) 100]
      "Rational" -> [SRational 0 1,SRational 1 2,SRational (-2) 3]
      "Float32" -> floats t
      "Float64" -> floats t
      "Complex64" -> [SComplex t x y | (x,y) <- zip (floats "Float32") (reverse (floats "Float32"))]
      "Complex128" -> [SComplex t x y | (x,y) <- zip (floats "Float64") (reverse (floats "Float64"))]
      "Symbol" -> [SSymbol "a" "same", SSymbol "b" "same"]
      _ | Just p <- primitive t, family p == Character -> map (SCharacter t) (units t)
        | Just p <- primitive t, family p == Sequence -> map (SSequence t) [[],units t]
        | otherwise -> [SAbsent t]
  where floats n = map (SFloat n) $ if n == "Float32"
          then ["00000000","80000000","3f800000","bf800000","7f800000","ff800000","7fc00000","00000001","007fffff","00800000","7f7fffff","ff7fffff"]
          else ["0000000000000000","8000000000000000","3ff0000000000000","bff0000000000000","7ff0000000000000","fff0000000000000","7ff8000000000000","0000000000000001","000fffffffffffff","0010000000000000","7fefffffffffffff","ffefffffffffffff"]
        units n | n == "Bytes" = [0,127,128,255]
                | n `elem` ["Utf16Text","CodeUnit16"] = [0,55296,56320,65535]
                | n `elem` ["CodePointText","CodePoint"] = [0,55296,128512,1114111]
                | otherwise = [0,97,955,128512,1114111]
textScalar :: String -> Scalar
textScalar = SSequence "Text" . map ord

-- Native adapter bridges are selected here, not by a fallback to Text.
nativeRepresentation :: String -> String -> Maybe String
nativeRepresentation target t = lookup t $ case target of
  "java" -> [("Integer","Number"),("Char","String"),("CodePoint","int"),("CodeUnit16","char"),("Bytes","byte[]"),("Utf16Text","String"),("Unit","void"),("Bool","boolean"),("Text","String"),("Int8","byte"),("Int16","short"),("Int32","int"),("Int64","long"),("UInt8","short"),("UInt16","int"),("UInt32","long"),("BigInt","java.math.BigInteger"),("BigUInt","java.math.BigInteger"),("UInt64","java.math.BigInteger"),("Decimal","java.math.BigDecimal"),("Float32","float"),("Float64","double")]
  "kotlin" -> [("Integer","Number"),("Char","String"),("CodePoint","Int"),("CodeUnit16","Char"),("Bytes","ByteArray"),("Utf16Text","String"),("Unit","Unit"),("Bool","Boolean"),("Text","String"),("Int8","Byte"),("Int16","Short"),("Int32","Int"),("Int64","Long"),("UInt8","Short"),("UInt16","Int"),("UInt32","Long"),("BigInt","java.math.BigInteger"),("BigUInt","java.math.BigInteger"),("UInt64","java.math.BigInteger"),("Decimal","java.math.BigDecimal"),("Float32","Float"),("Float64","Double")]
  "go" -> [("Integer","any"),("Char","rune"),("CodePoint","rune"),("CodeUnit16","uint16"),("Bytes","[]byte"),("Utf16Text","[]uint16"),("CodePointText","[]rune"),("Bool","bool"),("Text","string"),("Int8","int8"),("Int16","int16"),("Int32","int32"),("Int64","int64"),("UInt8","uint8"),("UInt16","uint16"),("UInt32","uint32"),("UInt64","uint64"),("IntSize","int"),("UIntSize","uint"),("UIntPtr","uintptr"),("BigInt","*LawSpecBigInt"),("BigUInt","*LawSpecBigInt"),("Rational","*LawSpecRational"),("Float32","float32"),("Float64","float64"),("Complex64","complex64"),("Complex128","complex128")]
  "haskell" -> [("Integer","IntegerValue"),("Bytes","ByteString"),("Complex64","(Complex Float)"),("Complex128","(Complex Double)"),("Char","Char"),("CodePoint","Char"),("CodeUnit16","Word16"),("Unit","()"),("Bool","Bool"),("Text","Text"),("Int8","Int8"),("Int16","Int16"),("Int32","Int32"),("Int64","Int64"),("UInt8","Word8"),("UInt16","Word16"),("UInt32","Word32"),("UInt64","Word64"),("IntSize","Int"),("UIntSize","Word"),("BigInt","Integer"),("BigUInt","Integer"),("Rational","Rational"),("Float32","Float"),("Float64","Double")]
  _ -> []

prettyScalar :: Scalar -> String
prettyScalar s = case s of
  SInteger _ n -> show n
  SBool b -> if b then "true" else "false"
  SDecimal c e -> show c ++ "e" ++ show e
  SRational n d -> "rational(" ++ show n ++ ", " ++ show d ++ ")"
  SFloat t bits -> (if t == "Float32" then "float32Bits" else "float64Bits") ++ "(" ++ show bits ++ ")"
  SComplex t r i -> t ++ "(" ++ prettyScalar r ++ ", " ++ prettyScalar i ++ ")"
  SSequence "Text" xs -> show (map toEnum xs :: String)
  SSequence t xs -> (case t of "Bytes" -> "bytes"; "Utf16Text" -> "utf16"; _ -> "codePoints") ++ "(" ++ show xs ++ ")"
  SCharacter t c -> (case t of "Char" -> "char"; "CodePoint" -> "codePoint"; _ -> "codeUnit16") ++ "(" ++ show c ++ ")"
  SSymbol i d -> "symbol(" ++ show i ++ ", " ++ show d ++ ")"
  SAbsent t -> case t of "Unit" -> "unitValue"; "Null" -> "null"; _ -> "undefined"
  SPresent t Nothing -> if t == "Nullable" then "null" else "undefined"
  SPresent t (Just v) -> (if t == "Nullable" then "nullable" else "optional") ++ "(" ++ prettyScalar v ++ ")"

pad8 :: String -> String
pad8 s = replicate (8-length s) '0' ++ s
