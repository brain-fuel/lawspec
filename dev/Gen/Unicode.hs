-- | Embed the pinned upstream C + F table; S and Turkic T mappings are excluded.
module Gen.Unicode (caseFoldData) where

import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.Char (chr)
import Data.List (intercalate,nub)
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
