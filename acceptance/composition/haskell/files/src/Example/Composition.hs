{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
-- share the case's Store, a handle around an IORef.
module Example.Composition where

import Prelude
import qualified Prelude as P
import qualified Control.Exception as E
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified LawSpecAbilities.Example.Composition as Abilities

-- An in-memory log store: each log's records, newest first.
data LogStore = LogStore { storeLogs :: IORef (Map.Map T.Text [T.Text]), storeOpen :: IORef Bool }

logStore :: Data.Store -> LogStore
logStore = LS.fromHandle

-- (Unit -> example.composition::type::Store)
{-# NOINLINE openStore #-}
openStore :: () -> Data.Store
openStore () = unsafePerformIO $ do
  logs <- newIORef Map.empty
  open <- newIORef True
  LS.handle (LogStore logs open)

-- (example.composition::type::Store -> Unit)
{-# NOINLINE closeStore #-}
closeStore :: Data.Store -> ()
closeStore s = unsafePerformIO (writeIORef (storeOpen (logStore s)) False)

-- | The native handler of Logs: create, append.
logsHandler :: Data.Store -> P.IO Abilities.Logs
logsHandler resource = P.pure Abilities.Logs
  { Abilities.create = \name -> modifyIORef' (storeLogs store) (Map.insert name [])
  , Abilities.append = \name record -> do
      logs <- readIORef (storeLogs store)
      case Map.lookup name logs of
        Nothing -> E.throwIO (LS.Fail Data.ProblemUnknownLog)
        Just records
          | T.null record -> E.throwIO (LS.Fail Data.ProblemEmptyRecord)
          | otherwise -> do
              writeIORef (storeLogs store) (Map.insert name (record : records) logs)
              P.pure (P.fromIntegral (P.length records))
  }
  where store = logStore resource

-- | The native handler of Reader: size.
readerHandler :: Data.Store -> P.IO Abilities.Reader
readerHandler resource = P.pure Abilities.Reader
  { Abilities.size = \name -> do
      logs <- readIORef (storeLogs (logStore resource))
      P.pure (P.fmap (P.fromIntegral . P.length) (Map.lookup name logs))
  }

-- | The native handler of Writer: write, lastOffset.
writerHandler :: Data.Store -> P.IO Abilities.Writer
writerHandler resource = do
  lastWritten <- newIORef P.Nothing
  P.pure Abilities.Writer
    { Abilities.write = \name record -> do
        logs <- readIORef (storeLogs store)
        case Map.lookup name logs of
          Just records | not (T.null record) -> do
            writeIORef (storeLogs store) (Map.insert name (record : records) logs)
            writeIORef lastWritten (P.Just (P.fromIntegral (P.length records)))
            P.pure True
          _ -> P.pure False
    , Abilities.lastOffset = readIORef lastWritten
    }
  where store = logStore resource
