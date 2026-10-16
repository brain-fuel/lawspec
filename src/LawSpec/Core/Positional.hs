-- | Structural position labels shared by source elaboration and native names.
-- Labels cannot be authored as ordinary record fields. They keep tuple arity
-- and grouping in the existing canonical structural-product descriptor.
module LawSpec.Core.Positional (positionalFields,positionalItems,positionalLabel) where

import Data.Char (isDigit)
import Data.List (stripPrefix)

positionalFields :: [a] -> [(String,a)]
positionalFields values = zipWith field [1::Int ..] values
  where
    width=length (show (length values))
    field index value=let digits=show index in ("_tuple" ++ replicate (width-length digits) '0' ++ digits ++ "_",value)

positionalItems :: [(String,a)] -> Maybe [a]
positionalItems fields
  | length fields < 2 = Nothing
  | otherwise = mapM (`lookup` fields) (map fst (positionalFields fields))

positionalLabel :: String -> Maybe String
positionalLabel name = do
  suffix <- stripPrefix "_tuple" name
  case span isDigit suffix of
    (digits,"_") | first:_ <- dropWhile (=='0') digits -> Just ("tuple"++dropWhile (=='0') digits)
    _ -> Nothing
