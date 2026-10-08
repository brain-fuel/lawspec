-- | Exercise the shared BEAM scalar domain against Core's independent oracle,
-- including IEEE bit patterns, checked conversions and both machine profiles.
-- ref:DEC-portable-exact-arithmetic ref:DEC-explicit-machine-profile
module BeamVectors (writeVectors) where

import Data.Aeson (Value, object, (.=), encode)
import qualified Data.ByteString.Lazy as B
import Data.Bits ((.&.))
import Numeric (showHex)
import LawSpec.Core (scalarType)
import LawSpec.Core.Semantics (binaryValue, convertValue, helperValue)
import LawSpec.Scalar

writeVectors :: FilePath -> IO ()
writeVectors path = B.writeFile path (encode vectors)

vectors :: [Value]
vectors = concat [forProfile bits | bits <- [32, 64]]
  where
    forProfile bits =
      [one bits "literal" "" [a] (Right a)
        | p <- primitives, a <- scalarBoundaries bits (primitiveName p)] ++
      [one bits "binary" op [a, b] (binaryValue bits op a b)
        | (a, b) <- exactPairs ++ floatingPairs,
          op <- ["+", "-", "*", "/", "==", "!=", "<", "<=", ">", ">="]] ++
      [one bits "binary" op [a, b] (binaryValue bits op a b)
        | a <- integers, b <- map (SInteger "Integer") [-7, -1, 0, 1, 2, 7],
          op <- ["quot", "rem"] ++ ["pow" | notNegative b]] ++
      [one bits "convert" target [a] (convertValue bits (scalarType target) a)
        | a <- exacts ++ concatMap floatEdges ["Float32", "Float64"],
          target <- ["Int8", "UInt8", "IntSize", "UIntSize", "UInt64", "Integer",
                     "BigUInt", "Rational", "Decimal", "Float32", "Float64",
                     "Complex64", "Complex128"]] ++
      [one bits "helper" "round" [a, places] (helperValue bits "round" [a, places])
        | a <- exacts, places <- map (SInteger "Int32") [-2, -1, 0, 1, 2, 20]] ++
      [one bits "helper" op [a] (helperValue bits op [a])
        | a <- concatMap floatEdges ["Float32", "Float64"],
          op <- ["isNaN", "isInfinite", "isFinite", "isNegativeZero"]] ++
      [one bits "binary" op [a, b] (binaryValue bits op a b)
        | t <- ["Complex64", "Complex128"],
          a <- scalarBoundaries bits t, b <- scalarBoundaries bits t,
          op <- ["+", "-", "*", "/", "==", "!="]]
      ++ [one bits "helper" "regexMatches" [p,t] (helperValue bits "regexMatches" [p,t])
        | p <- map textScalar ["", "a", "a|ab", "(?:a|ab)*", "(a?)*", ".*", "a{2,4}",
            "a{2,}", "a{2}", "[^a-z]*", "[a-c]+", "\\d+", "\\D+", "[\\s\\w]+", "\\W*",
            "[a-]", "λ+", "😀.{0,3}", "\\.", "\\n", "^a$", "(?=a)", "[z-a]", "[]",
            "a{2,1}", "a{1001}", "a++", "\\q", "(", "a)", "[", "[a\\D]+", "[a-z-]+"],
          t <- map textScalar ["", "a", "ab", "aaaa", "b", "abc", "d", "aab", "0123",
            "0a", "λ", "λλ", "😀", "😀λa", "😀\n", "\n", "\r", "-", ".", " ", "a b", "１２"]]
    notNegative (SInteger _ n) = n >= 0
    notNegative _ = False
    integers = map (SInteger "Integer") [-(2^(256 :: Int)), -101, -1, 0, 1, 3,
      2^(24 :: Int) + 1, 2^(53 :: Int) + 1, 2^(256 :: Int) + 7]
    exacts = integers ++ [SDecimal 1 (-1), SDecimal 125 (-2), SDecimal 135 (-2),
      SDecimal (-125) (-2), SDecimal (-135) (-2), SDecimal 999999999999999999999 (-9),
      SRational 1 3, SRational (-7) 11, SRational 1 (2^(160 :: Int)),
      SRational (2^(150 :: Int) + 1) (2^(153 :: Int)), SDecimal 1 400]
    exactPairs = [(a,b) | a <- exacts, b <- exacts]
    floatEdges t = scalarBoundaries 64 t ++
      [SFloat t (if t == "Float32" then "7f800001" else "7ff0000000000001")]
    floatingPairs = concat
      [ [(a,b) | a <- floatEdges t, b <- floatEdges t] ++ zip randoms (drop 1 randoms)
        | t <- ["Float32", "Float64"],
          let width = if t == "Float32" then 32 else 64
              randoms = take 1025 (map (bitsScalar t width) words64)]
    words64 = iterate (\n -> (6364136223846793005*n + 1442695040888963407) .&.
      (2^(64 :: Int)-1)) (701 :: Integer)
    bitsScalar t width n = let s = showHex (n .&. (2^width - 1)) ""
                           in SFloat t (replicate (width `div` 4 - length s) '0' ++ s)

one :: Int -> String -> String -> [Scalar] -> Either String Scalar -> Value
one bits kind operation arguments expected = object
  (["machineBits" .= bits, "kind" .= kind, "op" .= operation,
    "args" .= arguments, "types" .= map scalarName arguments] ++
    either (\message -> ["error" .= message]) (\value -> ["expected" .= value]) expected)
