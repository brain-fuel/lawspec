-- | Embed the pinned upstream C + F table; S and Turkic T mappings are excluded.
module Gen.Unicode (caseFoldData, displayWidthData) where

import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.Char (chr)
import Data.List (intercalate,nub)
import qualified Data.Map.Strict as M
import Numeric (readHex)
import LawSpec.Digest (digest,digestHex)

caseFoldData :: IO String
caseFoldData = do
  bytes <- B.readFile "vendor/unicode/17.0.0/CaseFolding.txt"
  unless (digestHex (digest bytes) == "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183")
    (fail "The pinned Unicode 17.0.0 CaseFolding.txt digest changed")
  let rows = [ (hex key, map hex (words mapping))
             | line <- lines (map (toEnum . fromEnum) (B.unpack bytes))
             , not (null line),head line /= '#'
             , [key,status,mapping,_] <- [split line]
             , words status `elem` [["C"],["F"]] ]
      quoted values = '"' : concatMap (\value -> "\\" ++ show value ++ "\\&") values ++ "\""
  unless (length rows == 1585 && length (nub (map fst rows)) == length rows)
    (fail "Unexpected Unicode full default case-fold mapping inventory")
  pure $ unlines
    [ "-- Generated from vendor/unicode/17.0.0/CaseFolding.txt by lawspec-dev generate. Do not edit."
    , "module LawSpec.CaseFoldData (caseFoldMappings) where"
    , ""
    , "caseFoldMappings :: [(String,String)]"
    , "caseFoldMappings ="
    , "  [ " ++ intercalate "\n  , " ["(" ++ quoted [key] ++ "," ++ quoted value ++ ")" | (key,value) <- rows]
    , "  ]" ]
  where
    hex text = case readHex (unwords (words text)) of
      [(n,"")] | n >= 0 && n <= fromEnum (maxBound :: Char) -> fromEnum (chr n)
      _ -> error "Invalid pinned Unicode code point"
    split text = case break (== ';') text of
      (first,';':rest) -> first : split rest
      (last',_) -> [last']

-- | Display columns per code point, as the unicode-width crate measures them
-- for ruff and rustfmt: East Asian Wide and Fullwidth are two columns;
-- combining marks, format controls and Hangul medial and final jamo are none.
displayWidthData :: IO String
displayWidthData = do
  widths <- B.readFile "vendor/unicode/17.0.0/EastAsianWidth.txt"
  categories <- B.readFile "vendor/unicode/17.0.0/DerivedGeneralCategory.txt"
  unless (digestHex (digest widths) == eastAsianDigest && digestHex (digest categories) == categoryDigest)
    (fail "The pinned Unicode 17.0.0 width tables' digests changed")
  let rows bytes = [ (range field, unwords (words value))
                   | line <- lines (map (toEnum . fromEnum) (B.unpack bytes))
                   , let content = takeWhile (/= '#') line, not (all (== ' ') content)
                   , [field,value] <- [split content] ]
      wide = [r | (r,v) <- rows widths, v `elem` ["W","F"]]
      -- Prepended concatenation marks are visible format characters.
      visible = [0x00AD,0x0600,0x0601,0x0602,0x0603,0x0604,0x0605,0x06DD,0x070F,0x0890,0x0891,0x08E2,0x110BD,0x110CD]
      zero = [r | (r,v) <- rows categories, v `elem` ["Mn","Me","Cf"]] ++ [(0x1160,0x11FF),(0xD7B0,0xD7FF),(0x200B,0x200B)]
      table = merge (sortOn' fst ([(c,0) | (lo,hi) <- zero, c <- [lo..hi], c `notElem` visible] ++
        [(c,2) | (lo,hi) <- wide, c <- [lo..hi]]))
      unprintable = merge (sortOn' fst [(c,1 :: Int) | (r,v) <- rows categories, v `elem` ["Cc","Cf","Cs","Co","Cn","Zl","Zp","Zs"]
        , let (lo,hi) = r, c <- [lo..hi], c /= 0x20])
  pure $ unlines
    [ "-- Generated from vendor/unicode/17.0.0/EastAsianWidth.txt and DerivedGeneralCategory.txt"
    , "-- by lawspec-dev generate. Do not edit."
    , "module LawSpec.DisplayWidthData (displayWidthRanges, unprintableRanges) where"
    , ""
    , "-- | Code point ranges whose display width is not one column: (first, last, width)."
    , "displayWidthRanges :: [(Int,Int,Int)]"
    , "displayWidthRanges ="
    , "  [ " ++ intercalate "\n  , " ["(" ++ show lo ++ "," ++ show hi ++ "," ++ show w ++ ")" | (lo,hi,w) <- table]
    , "  ]"
    , ""
    , "-- | Code point ranges a string literal escapes to stay readable: controls,"
    , "-- format characters, surrogates, private use, unassigned code points and"
    , "-- separators other than the space."
    , "unprintableRanges :: [(Int,Int)]"
    , "unprintableRanges ="
    , "  [ " ++ intercalate "\n  , " ["(" ++ show lo ++ "," ++ show hi ++ ")" | (lo,hi,_) <- unprintable]
    , "  ]" ]
  where
    eastAsianDigest = "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33"
    categoryDigest = "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e"
    range field = case break (== '.') (unwords (words field)) of
      (lo,'.':'.':hi) -> (hex' lo,hex' hi)
      (lo,_) -> (hex' lo,hex' lo)
    hex' text = case readHex text of
      [(n,"")] -> n
      _ -> error "Invalid pinned Unicode code point"
    split text = case break (== ';') text of
      (first,';':rest) -> [first,rest]
      _ -> []
    -- Later entries win: a wide combining mark is wide.
    sortOn' f = map snd . M.toList . M.fromList . map (\x -> (f x,x))
    merge ((c,w):rest) = go c c w rest
      where
        go lo hi width ((c',w'):more) | c' == hi + 1 && w' == width = go lo c' width more
                                      | otherwise = (lo,hi,width) : go c' c' w' more
        go lo hi width [] = [(lo,hi,width)]
    merge [] = []
