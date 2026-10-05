{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}
-- User-owned LawSpec adapters for the resources example. A Store is a
-- handle around an IORef; each command runs its effect with
-- unsafePerformIO, every call its own effect.
module Example.Resources where

import Prelude
import qualified Prelude as P
import Control.Exception (SomeException, try)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Int as I
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Network.Socket as Socket
import qualified System.Directory as Directory
import qualified System.Environment as Environment
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data

-- An in-memory store. At most three may be open at once, so a store that is
-- never closed is noticed.
data Store = Store { storeItems :: IORef (Map.Map I.Int32 I.Int32), storeOpen :: IORef Bool }

{-# NOINLINE openCount #-}
openCount :: IORef Int
openCount = unsafePerformIO (newIORef 0)

store :: Data.Store -> Store
store = LS.fromHandle

-- (Unit -> example.resources::type::Store)
{-# NOINLINE openStore #-}
openStore :: () -> Data.Store
openStore () = unsafePerformIO $ do
  count <- atomicModifyIORef' openCount (\n -> (n + 1, n))
  if count >= 3 then ioError (userError "too many open stores: one was never closed") else pure ()
  items <- newIORef Map.empty
  open <- newIORef True
  LS.handle (Store items open)

-- (example.resources::type::Store -> Unit)
{-# NOINLINE closeStore #-}
closeStore :: Data.Store -> ()
closeStore s = unsafePerformIO $ do
  open <- readIORef (storeOpen (store s))
  if open
    then do
      writeIORef (storeOpen (store s)) False
      modifyIORef' openCount (subtract 1)
    else pure ()

-- (example.resources::type::Store -> Unit)
{-# NOINLINE clearStore #-}
clearStore :: Data.Store -> ()
clearStore s = unsafePerformIO (writeIORef (storeItems (store s)) Map.empty)

-- (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
{-# NOINLINE put #-}
put :: Data.Store -> I.Int32 -> I.Int32 -> ()
put s k v = unsafePerformIO $ do
  open <- readIORef (storeOpen (store s))
  if open then modifyIORef' (storeItems (store s)) (Map.insert k v) else ioError (userError "the store is closed")

-- (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
{-# NOINLINE get #-}
get :: Data.Store -> I.Int32 -> (P.Maybe I.Int32)
get s k = unsafePerformIO (Map.lookup k <$> readIORef (storeItems (store s)))

-- (example.resources::type::Store -> Bool)
{-# NOINLINE isOpen #-}
isOpen :: Data.Store -> P.Bool
isOpen s = unsafePerformIO (readIORef (storeOpen (store s)))

-- (example.resources::type::Store -> Int32)
{-# NOINLINE size #-}
size :: Data.Store -> I.Int32
size s = unsafePerformIO (fromIntegral . Map.size <$> readIORef (storeItems (store s)))

-- (Text -> (Int32 -> Unit))
{-# NOINLINE writeNote #-}
writeNote :: T.Text -> I.Int32 -> ()
writeNote dir n = unsafePerformIO (writeFile (T.unpack dir ++ "/note.txt") (show n))

-- (Text -> Maybe (Int32))
{-# NOINLINE readNote #-}
readNote :: T.Text -> (P.Maybe I.Int32)
readNote dir = unsafePerformIO $ do
  let path = T.unpack dir ++ "/note.txt"
  exists <- Directory.doesFileExist path
  if exists then Just . read <$> readFile path else pure Nothing

-- (Int32 -> Bool)
{-# NOINLINE canListen #-}
canListen :: I.Int32 -> P.Bool
canListen port = unsafePerformIO $ do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream }
  address : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just (show port))
  outcome <- try $ do
    socket <- Socket.openSocket address
    Socket.bind socket (Socket.addrAddress address)
    Socket.close socket
  pure (case outcome of Left (_ :: SomeException) -> False; Right () -> True)

-- (Int32 -> Unit)
{-# NOINLINE setGreeting #-}
setGreeting :: I.Int32 -> ()
setGreeting n = unsafePerformIO (Environment.setEnv "LAWSPEC_EXAMPLE_GREETING" (show n))

-- (Unit -> Maybe (Int32))
{-# NOINLINE greeting #-}
greeting :: () -> (P.Maybe I.Int32)
greeting () = unsafePerformIO (fmap read <$> Environment.lookupEnv "LAWSPEC_EXAMPLE_GREETING")
