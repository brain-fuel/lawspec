{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: pause notes when it is called.
module Example.Sequencing where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Control.Concurrent as Concurrent
import qualified GHC.Clock as Clock
import qualified System.Environment as Environment
import System.IO.Unsafe (unsafePerformIO)

-- One writer at a time: the Overlap module's naps note here too.
{-# NOINLINE noting #-}
noting :: Concurrent.MVar ()
noting = unsafePerformIO (Concurrent.newMVar ())

note :: String -> I.Int32 -> P.IO ()
note event n = do
  path <- Environment.lookupEnv "LAWSPEC_SCHEDULE_LOG"
  case path of
    Just file | not (null file) -> Concurrent.withMVar noting $ \_ -> do
      now <- Clock.getMonotonicTimeNSec
      appendFile file (event ++ " " ++ show n ++ " " ++ show (fromIntegral now / 1000000 :: Double) ++ "\n")
    _ -> P.pure ()

-- (Int32 -> Bool)
{-# NOINLINE pause #-}
pause :: I.Int32 -> P.Bool
pause n = unsafePerformIO $ do
  note "start" n
  Concurrent.threadDelay 5000
  note "end" n
  P.pure P.True
