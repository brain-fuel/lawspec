-- User-owned LawSpec adapter: a tab's handlers, run inside an actor.
-- keepsTotal uses the generated bar supervisor; the adapters are pure, so it
-- runs it with unsafePerformIO.
module Example.Restarts (openTab, add, total, keepsTotal) where

import qualified Data.Int as I
import qualified Data.Word as W
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecData as Data
import LawSpecActors.Example.Restarts

openTab :: () -> Data.Tab
openTab _ = Data.Tab 0

add :: Data.Tab -> W.Word8 -> Data.Pair I.Int64 Data.Tab
add (Data.Tab current) amount =
  let after = current + fromIntegral amount
  in Data.Pair after (Data.Tab after)

total :: Data.Tab -> Data.Pair I.Int64 Data.Tab
total tab@(Data.Tab current) = Data.Pair current tab

-- The handlers are this module's own adapters.
handlers :: TabHandlers
handlers = TabHandlers { onOpenTab = openTab, onAdd = add, onTotal = total }

{-# NOINLINE keepsTotal #-}
keepsTotal :: W.Word8 -> I.Int64
keepsTotal amount = unsafePerformIO $ do
  bar <- startBarSupervisor handlers
  _ <- tabAdd (barTab bar) amount
  crashTabActor (barTab bar)
  kept <- tabTotal (barTab bar)
  stopBarSupervisor bar
  pure kept
