-- | The Kafka reference model's workload, driven through the generated
-- cluster spec handler of the Broker ability: produce across 100
-- partitions, a consumer group of ten members fetching and committing with
-- a rebalance, then transactions. See bench/README.md.
module Main (main) where

import Control.Monad (forM, forM_, foldM, when)
import qualified Data.ByteString as B
import Data.Bits (shiftR)
import Data.Int (Int32, Int64)
import Data.IORef
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import GHC.Stats (getRTSStats, getRTSStatsEnabled, gcdetails_live_bytes, gc)
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import Text.Printf (printf)
import qualified LawSpecData as Data
import LawSpecAbilities.Lawtwin.Kafka
import qualified LawSpecHandlers.Lawtwin.Kafka as Handlers
import qualified LawSpecRuntime as LS

partitions :: Int
partitions = 100

members :: Int
members = 10

tp :: Int -> Data.TopicPartition
tp p = Data.TopicPartition (T.pack "bench") (fromIntegral p)

record :: Int -> Data.Record
record i = Data.Record (Just key) (Just (B.replicate 64 120)) []
  where key = B.pack [fromIntegral (i `shiftR` (8 * k)) | k <- [7, 6 .. 0]]

phase :: String -> Int -> Double -> IO ()
phase name ops start = do
  now <- getMonotonicTime
  printf "phase %s %d %.6f\n" name ops (now - start)

memory :: String -> IO ()
memory label = do
  performMajorGC
  enabled <- getRTSStatsEnabled
  when enabled $ do
    stats <- getRTSStats
    printf "memory %s %d\n" label (gcdetails_live_bytes (gc stats))

main :: IO ()
main = do
  args <- getArgs
  let scale = case args of
        n : _ -> read n
        [] -> 1000000 :: Int
  symbols <- LS.newSymbolContext
  state <- Handlers.clusterState symbols
  broker <- Handlers.clusterBroker symbols state
  everything <- getMonotonicTime
  createTopicsRequest broker (T.pack "bench") (fromIntegral partitions)

  start <- getMonotonicTime
  forM_ [0 .. scale - 1] $ \i -> produceRequest broker (tp (i `mod` partitions)) Nothing [record i]
  phase "produce" scale start
  memory "after-produce"

  start2 <- getMonotonicTime
  ops <- newIORef (0 :: Int)
  readCount <- newIORef (0 :: Int)
  let tick n = modifyIORef' ops (+ n)
      names = [T.pack ("member-" ++ show m) | m <- [0 .. members - 1]]
      g = T.pack "g"
      topics = [T.pack "bench"]
  generation0 <- foldM (\_ m -> tick 1 >> joinGroupRequest broker g m topics) 0 names
  generationRef <- newIORef generation0
  forM_ [0 :: Int, 1] $ \round' -> do
    when (round' == 1) $ do
      leaveGroupRequest broker g (last names)
      joinGroupRequest broker g (last names) topics >>= writeIORef generationRef
      tick 2
    generation <- readIORef generationRef
    forM_ names $ \m -> do
      heartbeatRequest broker g m generation
      assigned <- syncGroupRequest broker g m generation
      tick 2
      forM_ assigned $ \p -> do
        fetched <- offsetFetchRequest broker g p
        tick 1
        let loop position = do
              r <- fetchRequest broker p position 500 Data.IsolationLevelReadUncommitted
              tick 1
              let hw = Data.fetchResultHighWatermark r
                  end = if round' == 0 then hw `div` 2 else hw
              if null (Data.fetchResultRecords r) || position >= end then pure () else do
                modifyIORef' readCount (+ length (Data.fetchResultRecords r))
                let next = Data.fetchResultNextOffset r
                offsetCommitRequest broker g m generation [Data.OffsetEntry p next]
                tick 1
                loop next
        loop (maybe 0 id fetched)
  consumed <- readIORef ops
  phase "consume" consumed start2
  readIORef readCount >>= printf "check records-read %d\n"

  start3 <- getMonotonicTime
  let txns = max 1 (scale `div` 100)
      tx = T.pack "tx"
  pid <- initProducerIdRequest broker (Just tx)
  let producerId = Data.producerIdAndEpochProducerId pid
      epoch = Data.producerIdAndEpochProducerEpoch pid
  sequences <- newIORef (replicate partitions (0 :: Int32))
  forM_ [0 .. txns - 1] $ \t -> do
    let parts = [(2 * t) `mod` partitions, (2 * t + 1) `mod` partitions]
    addPartitionsToTxnRequest broker tx producerId epoch (map tp parts)
    forM_ parts $ \p -> do
      sq <- readIORef sequences
      let s = sq !! p
      writeIORef sequences (take p sq ++ [s + 1] ++ drop (p + 1) sq)
      _ <- produceRequest broker (tp p) (Just (Data.ProducerTag producerId epoch s)) [record t]
      pure ()
    txnOffsetCommitRequest broker tx producerId epoch (T.pack "g") [Data.OffsetEntry (tp (head parts)) (fromIntegral t :: Int64)]
    endTxnRequest broker tx producerId epoch True
  let txOps = 1 + 5 * txns
  phase "transactions" txOps start3
  phase "total" (scale + consumed + txOps) everything
  memory "end"
  r <- fetchRequest broker (tp 0) 0 10 Data.IsolationLevelReadCommitted
  printf "check committed-hw %d\n" (Data.fetchResultHighWatermark r)
  _ <- forM [()] pure
  pure ()
