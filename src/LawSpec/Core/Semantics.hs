-- | Framework- and syntax-independent scalar semantics used by the core oracle.
module LawSpec.Core.Semantics where
import LawSpec.Core (Type(..), Argument(..), scalarType)
import LawSpec.Scalar
import Data.Ratio
import Control.Monad (unless)
import Data.List (isPrefixOf, isSuffixOf, isInfixOf)
import LawSpec.Regex (regexMatchesText)
import LawSpec.Formats (rfc822Uncommented)
import LawSpec.Blake3 (blake3, blake3DeriveKey, blake3Keyed)
import qualified Data.ByteString as B

-- | Conversions follow LawSpec's rules, so a non-finite float never becomes an
-- exact number on any target. ref:DEC-portable-exact-arithmetic
convertValue :: Int -> Type -> Scalar -> Either String Scalar
convertValue bits (Constructor n []) s = case s of
  SFloat _ _ | isExact n -> let v = floatValue s in
    if isNaN v || isInfinite v then Left "non-finite exact conversion"
    else convertScalar bits n (reduced (toRational v))
  _ -> convertScalar bits n s
convertValue _ (Constructor n [_]) (SAbsent a)
  | (n,a) `elem` [("Nullable","Null"),("Optional","Undefined")] = Right (SPresent n Nothing)
convertValue _ (Constructor n [_]) (SPresent m Nothing) | n == m = Right (SPresent n Nothing)
convertValue bits (Constructor n [TypeArgument t]) (SPresent m (Just s))
  | n == m = SPresent n . Just <$> convertValue bits t s
convertValue _ _ _ = Left "invalid scalar conversion"

-- | Operators compute LawSpec's results, exact where the types are exact, so the
-- compiler's evaluation agrees with every runtime.
-- ref:DEC-portable-exact-arithmetic
binaryValue :: Int -> String -> Scalar -> Scalar -> Either String Scalar
binaryValue bits op a b
  | op `elem` ["==","!="], not (isNumeric (scalarName a)) = do
      let eq = scalarEqual a b
      pure (SBool (if op == "==" then eq else not eq))
  | otherwise = do
      result <- promote op (scalarName a) (scalarName b)
      if isExact (scalarName a) then do
        x <- exactValue a; y <- exactValue b
        if op `elem` ["<","<=",">",">=","==","!="] then pure (SBool (cmp op x y)) else do
          unless (op `notElem` ["/","quot","rem"] || y /= 0) (Left "exact division by zero")
          case op of
            "quot" -> pure (SInteger "Integer" (numerator x `quot` numerator y))
            "rem" -> pure (SInteger "Integer" (numerator x `rem` numerator y))
            "pow" | numerator y < 0 -> Left "negative exponent"
            "pow" -> pure (SInteger "Integer" (numerator x ^ numerator y))
            _ -> convertScalar bits result (reduced (case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> 0))
      else if any (`elem` ["Complex64","Complex128"]) [scalarName a,scalarName b] then do
        let pair (SComplex _ r i) = (r,i)
            pair v = (v,floatScalar (scalarName v) 0)
            (ar,ai) = pair a; (br,bi) = pair b
            component = if result == "Complex64" then "Float32" else "Float64"
        if op `elem` ["==","!="] then pure (SBool (if op == "==" then scalarEqual ar br && scalarEqual ai bi else not (scalarEqual ar br && scalarEqual ai bi))) else do
          (r,i) <- case op of
            "+" -> (,) <$> binaryValue bits "+" ar br <*> binaryValue bits "+" ai bi
            "-" -> (,) <$> binaryValue bits "-" ar br <*> binaryValue bits "-" ai bi
            "*" -> do p <- binaryValue bits "*" ar br; q <- binaryValue bits "*" ai bi; r <- binaryValue bits "*" ar bi; s <- binaryValue bits "*" ai br; (,) <$> binaryValue bits "-" p q <*> binaryValue bits "+" r s
            "/" -> do p <- binaryValue bits "*" br br; q <- binaryValue bits "*" bi bi; d <- binaryValue bits "+" p q; ac <- binaryValue bits "*" ar br; bd <- binaryValue bits "*" ai bi; bc <- binaryValue bits "*" ai br; ad <- binaryValue bits "*" ar bi; nr <- binaryValue bits "+" ac bd; ni <- binaryValue bits "-" bc ad; (,) <$> binaryValue bits "/" nr d <*> binaryValue bits "/" ni d
            _ -> Left "complex values are not ordered"
          SComplex result <$> convertScalar bits component r <*> convertScalar bits component i
      else do
        let x = floatValue a; y = floatValue b
        pure $ if op `elem` ["<","<=",">",">=","==","!="] then SBool (cmp op x y) else floatScalar result (case op of "+" -> x+y; "-" -> x-y; "*" -> x*y; "/" -> x/y; _ -> 0)
-- | Built-in operations have one reference meaning each runtime must match.
bytesScalar :: B.ByteString -> Scalar
bytesScalar = SSequence "Bytes" . map fromIntegral . B.unpack

helperValue :: Int -> String -> [Scalar] -> Either String Scalar
helperValue bits "checked" [_] = Right (SBool True)
helperValue bits "length" [SSequence _ xs] = Right (SInteger "Integer" (fromIntegral (length xs)))
helperValue bits "isPresent" [SPresent _ v] = Right (SBool (case v of Just _ -> True; _ -> False))
helperValue bits "presentValue" [SPresent _ (Just v)] = Right v
helperValue bits "real" [SComplex _ r _] = Right r
helperValue bits "imag" [SComplex _ _ i] = Right i
helperValue bits "quot" [a,b] = binaryValue bits "quot" a b
helperValue bits "rem" [a,b] = binaryValue bits "rem" a b
helperValue bits "isNaN" [a] = Right (SBool (isNaN (floatValue a)))
helperValue bits "isInfinite" [a] = Right (SBool (isInfinite (floatValue a)))
helperValue bits "isFinite" [a] = Right (SBool (not (isNaN (floatValue a) || isInfinite (floatValue a))))
helperValue bits "isNegativeZero" [a] = Right (SBool (isNegativeZero (floatValue a)))
helperValue bits "round" [a,b] = do
  x <- exactValue a; scale <- exactValue b
  unless (denominator scale == 1) (Left "fractional decimal scale")
  let k = numerator scale; factor = if k >= 0 then 10^k % 1 else 1 % 10^(-k)
  decimal (fromInteger (round (x*factor)) / factor)
helperValue _ "startsWith" [SSequence "Text" t, SSequence "Text" p] = Right (SBool (isPrefixOf p t))
helperValue _ "endsWith" [SSequence "Text" t, SSequence "Text" p] = Right (SBool (isSuffixOf p t))
helperValue _ "textContains" [SSequence "Text" t, SSequence "Text" p] = Right (SBool (isInfixOf p t))
helperValue _ "regexMatches" [SSequence "Text" p, SSequence "Text" t] = SBool <$> regexMatchesText (map toEnum p) t
helperValue _ "rfc822Uncommented" [SSequence "Text" t] = Right (SSequence "Text" (map fromEnum (rfc822Uncommented (map toEnum t))))
helperValue _ "trim" [SSequence "Text" t] = Right (SSequence "Text" (trimText t))
helperValue _ "trimAsciiControl" [SSequence "Text" t] = Right (SSequence "Text" (trimAsciiControlText t))
-- BLAKE3-256 of bytes, in its three modes. A derivation context is its
-- text's UTF-8 bytes.
helperValue _ "blake3" [SSequence "Bytes" bytes] = Right (bytesScalar (blake3 (B.pack (map fromIntegral bytes))))
helperValue _ "blake3Keyed" [SSequence "Bytes" key, SSequence "Bytes" bytes] =
  maybe (Left "blake3Keyed: the key is 32 bytes") (Right . bytesScalar)
    (blake3Keyed (B.pack (map fromIntegral key)) (B.pack (map fromIntegral bytes)))
helperValue _ "blake3DeriveKey" [SSequence "Text" context, SSequence "Bytes" material] =
  Right (bytesScalar (blake3DeriveKey (B.pack (map fromIntegral (concatMap utf8Units context))) (B.pack (map fromIntegral material))))
-- Text and Bytes: joined, sliced by index (clamped), encoded and printed.
helperValue _ "append" [SSequence t a, SSequence u b] | t == u = Right (SSequence t (a ++ b))
helperValue _ "slice" [SSequence t xs, from, to] = do
  i <- exactValue from
  j <- exactValue to
  let count = length xs
      -- Clamp before narrowing: drop passes 2^63 - 1 as the end, which a
      -- 32-bit Int (the WASM core) would wrap to a negative index.
      clamp r = fromInteger (max 0 (min (toInteger count) (floor r))) :: Int
      start = clamp i
  pure (SSequence t (take (max start (clamp j) - start) (drop start xs)))
helperValue _ "utf8" [SSequence "Text" points] = Right (SSequence "Bytes" (concatMap utf8Units points))
helperValue _ "textOf" [n] = do
  r <- exactValue n
  pure (textScalar (show (numerator r)))
helperValue bits n [a] | isNumeric n = convertValue bits (scalarType n) a
helperValue bits _ _ = Left "invalid pure helper or arguments"
-- | Comparison operators are spelled once.
cmp :: Ord a => String -> a -> a -> Bool
cmp "<" = (<)
cmp "<=" = (<=)
cmp ">" = (>)
cmp ">=" = (>=)
cmp "==" = (==)
cmp "!=" = (/=)
cmp _ = \_ _ -> False
-- | Equality is LawSpec's: exact values compare by value across types, NaN
-- differs from itself, and signed zeros are equal. ref:ieee-754
scalarEqual :: Scalar -> Scalar -> Bool
scalarEqual a b | isExact (scalarName a) && isExact (scalarName b) = exactValue a == exactValue b
scalarEqual (SFloat _ a) (SFloat _ b) | length a == length b = let t = if length a == 8 then "Float32" else "Float64" in floatValue (SFloat t a) == floatValue (SFloat t b)
scalarEqual a@(SFloat _ _) b@(SFloat _ _) = floatValue a == floatValue b
scalarEqual (SSymbol a _) (SSymbol b _) = a == b
scalarEqual (SComplex _ a b) (SComplex _ c d) = scalarEqual a c && scalarEqual b d
scalarEqual (SPresent a (Just x)) (SPresent b (Just y)) = a == b && scalarEqual x y
scalarEqual a b = a == b

-- | A code point's UTF-8 octets.
utf8Units :: Int -> [Int]
utf8Units c
  | c < 0x80 = [c]
  | c < 0x800 = [0xC0 + c `div` 64, 0x80 + c `mod` 64]
  | c < 0x10000 = [0xE0 + c `div` 4096, 0x80 + (c `div` 64) `mod` 64, 0x80 + c `mod` 64]
  | otherwise = [0xF0 + c `div` 262144, 0x80 + (c `div` 4096) `mod` 64, 0x80 + (c `div` 64) `mod` 64, 0x80 + c `mod` 64]

-- | White space for trim and words: Unicode's White_Space property, written
-- out so that every target's runtime uses the same set whatever its own
-- library calls a space. ref:DEC-text-pieces
textWhiteSpace :: Int -> Bool
textWhiteSpace point =
  (point >= 0x09 && point <= 0x0D) || point == 0x20 || point == 0x85 || point == 0xA0 || point == 0x1680
    || (point >= 0x2000 && point <= 0x200A) || point == 0x2028 || point == 0x2029 || point == 0x202F
    || point == 0x205F || point == 0x3000

-- | The pieces of a text between each occurrence of a separator, found from
-- the left without overlap. Empty pieces are kept, so joining the pieces
-- with the separator gives the text back. An empty separator divides nothing.
splitText :: [Int] -> [Int] -> [[Int]]
splitText [] text = [text]
splitText separator text = go [] text
  where
    size = length separator
    go piece rest
      | take size rest == separator && length rest >= size = reverse piece : go [] (drop size rest)
      | otherwise = case rest of
          [] -> [reverse piece]
          point : more -> go (point : piece) more

-- | The text without the white space at its two ends.
trimText :: [Int] -> [Int]
trimText = dropEnd . dropWhile textWhiteSpace
  where dropEnd = reverse . dropWhile textWhiteSpace . reverse

-- | The text without the code points up to U+0020 at its two ends: the C0
-- controls and the space, which is what Java's String.trim() removes. It is
-- not trimText: U+0085, U+00A0 and the other Unicode spaces stay, and U+0000
-- to U+0008, U+000E to U+001F go.
trimAsciiControlText :: [Int] -> [Int]
trimAsciiControlText = dropEnd . dropWhile (<= 0x20)
  where dropEnd = reverse . dropWhile (<= 0x20) . reverse

-- | The runs of a text that hold no white space.
wordsOfText :: [Int] -> [[Int]]
wordsOfText text = case dropWhile textWhiteSpace text of
  [] -> []
  rest -> let (word, more) = break textWhiteSpace rest in word : wordsOfText more

-- | The lines of a text: the pieces between line feeds, without a last empty
-- piece when the text ends with a line feed. The empty text has no lines.
linesOfText :: [Int] -> [[Int]]
linesOfText [] = []
linesOfText text = case break (== 0x0A) text of
  (line, []) -> [line]
  (line, _ : rest) -> line : linesOfText rest
