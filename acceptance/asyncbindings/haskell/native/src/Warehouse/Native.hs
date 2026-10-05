-- | Application code the warehouse adapters are bound to: some of it
-- asynchronous, as a real service client would be.
module Warehouse.Native (priceOf, quoteOf, Shelf, newShelf, restock, count) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import qualified Data.Int as I
import qualified Data.Text as T

price :: T.Text -> I.Int32
price sku
  | sku == T.pack "free" = 0
  | otherwise = fromIntegral (T.length sku `mod` 100)

priceOf :: T.Text -> IO I.Int32
priceOf sku = pure (price sku)

quoteOf :: T.Text -> I.Int32
quoteOf = price

-- | A stock count that several callers may change.
newtype Shelf = Shelf (MVar I.Int64)

newShelf :: IO Shelf
newShelf = Shelf <$> newMVar 0

restock :: Shelf -> I.Int32 -> IO ()
restock (Shelf total) amount = modifyMVar_ total (pure . (+ fromIntegral amount))

count :: Shelf -> IO I.Int64
count (Shelf total) = readMVar total
