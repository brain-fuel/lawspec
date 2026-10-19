-- User-owned LawSpec adapters for the matchers example.
module Example.Matchers where

import Prelude
import qualified Prelude as P
import qualified Data.Char as Char
import qualified Data.Int as I
import qualified Data.List as List
import qualified Data.Text as T
import qualified LawSpecData as Data

-- (List (Int32) -> List (Int32))
sortItems :: [I.Int32] -> [I.Int32]
sortItems xs = List.sort xs

-- (List (Text) -> List (Text))
uniqueTags :: [T.Text] -> [T.Text]
uniqueTags tags = List.nub tags

-- (Int32 -> (Int32 -> Float64))
average :: I.Int32 -> I.Int32 -> P.Double
average a b = (fromIntegral a + fromIntegral b) / 2

-- (Text -> Text)
slug :: T.Text -> T.Text
slug title = T.intercalate (T.pack "-") (filter (not . T.null) (T.split (not . word) (T.toLower title)))
  where word c = Char.isAsciiLower c || Char.isDigit c

-- (Int32 -> example.matchers::type::Order)
ship :: I.Int32 -> Data.Order
ship n = Data.OrderShipped (Data.Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911 (T.pack "post") n)
