-- User-owned LawSpec adapter.
module Example.Orders (price, stock, quote) where

import qualified Data.Int as I
import qualified Data.Text as T

priceOf :: T.Text -> I.Int32
priceOf sku
  | sku == T.pack "free" = 0
  | otherwise = fromIntegral (T.length sku `mod` 100)

price :: T.Text -> IO I.Int32
price = pure . priceOf

stock :: T.Text -> IO I.Int32
stock = pure . fromIntegral . T.length

quote :: T.Text -> I.Int32
quote = priceOf
