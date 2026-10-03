-- User-owned LawSpec adapter.
module Example.Limits (admitTicket, reserveSeat, chargeCard, releaseSeat, fetchQuote, hedgeQuote, resetQuotes) where

import Control.Concurrent (threadDelay)
import Data.IORef (IORef, atomicModifyIORef', newIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as T
import qualified LawSpecData as Data

admitTicket :: Data.Ticket -> Either T.Text Data.Ticket
admitTicket = Right

reserveSeat :: Data.Ticket -> Either T.Text Data.Ticket
reserveSeat = Right

chargeCard :: Data.Ticket -> Either T.Text Data.Ticket
chargeCard ticket@(Data.Ticket number)
  | number < 0 = Left (T.pack "declined")
  | otherwise = Right ticket

releaseSeat :: Data.Ticket -> Bool
releaseSeat _ = True

-- | Ticket -1's quote takes 600ms.
fetchQuote :: Data.Ticket -> IO (Either T.Text Data.Ticket)
fetchQuote ticket@(Data.Ticket number) = do
  if number == -1 then threadDelay 600000 else pure ()
  pure (Right ticket)

{-# NOINLINE quotes #-}
quotes :: IORef Int
quotes = unsafePerformIO (newIORef 0)

resetQuotes :: IO ()
resetQuotes = writeIORef quotes 0

-- | Ticket -2's first quote (and every other one after) stalls.
hedgeQuote :: Data.Ticket -> IO (Either T.Text Data.Ticket)
hedgeQuote ticket@(Data.Ticket number) = do
  if number == -2
    then do
      count <- atomicModifyIORef' quotes (\n -> (n + 1, n + 1))
      if odd count then threadDelay 600000 else pure ()
    else pure ()
  pure (Right ticket)
