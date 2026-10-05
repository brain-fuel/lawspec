{-# LANGUAGE ScopedTypeVariables #-}
-- Network transports for LawSpecRuntime's nodes: frames over TCP (each a
-- 4-byte big-endian length, then the frame) and HTTP (POST /lawspec with
-- the frame as the body). Both speak the same bytes as every other target.
module LawSpecTransports (tcpTransport, httpTransport) where

import Control.Concurrent (forkIO, MVar, newMVar, modifyMVar)
import Control.Exception (SomeException, bracket, catch, throwIO, try)
import Control.Monad (forever, unless)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.ByteString (ByteString)
import Data.Char (isDigit, toLower)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Network.Socket
import qualified Network.Socket.ByteString as NB
import LawSpecRuntime (Transport(..), Unreachable(..))

-- | Frames over TCP on host (port 0 picks a free port); the address is
-- tcp://host:port.
tcpTransport :: String -> Int -> IO Transport
tcpTransport host port = do
  server <- listening host port
  bound <- socketPort server
  connections <- newMVar []
  closed <- newIORef False
  let address = "tcp://" ++ host ++ ":" ++ show bound
      send node frame = modifyMVar connections $ \cached -> do
        let header = B.pack [fromIntegral (B.length frame `shiftR` s) | s <- [24, 16, 8, 0]]
            attempt existing = do
              sock <- maybe (connectTo node "tcp://") pure existing
              NB.sendAll sock (header <> frame)
              pure sock
        first <- try (attempt (lookup node cached))
        case first of
          Right sock -> pure ((node, sock) : filter ((/= node) . fst) cached, ())
          Left (_ :: SomeException) -> do
            maybe (pure ()) (\s -> close s `catch` \(_ :: SomeException) -> pure ()) (lookup node cached)
            second <- try (attempt Nothing)
            case second of
              Right sock -> pure ((node, sock) : filter ((/= node) . fst) cached, ())
              Left (e :: SomeException) -> throwIO (Unreachable ("cannot reach " ++ node ++ ": " ++ show e))
      start deliver = () <$ forkIO (acceptLoop server closed (\sock -> readFrames sock deliver))
      stop = do
        stopListening server address "tcp://" closed
        modifyMVar connections (\cached -> do
          mapM_ (\(_, s) -> close s `catch` \(_ :: SomeException) -> pure ()) cached
          pure ([], ()))
  pure (Transport address start send stop)

-- | Frames as HTTP POST bodies to /lawspec; the address is http://host:port.
httpTransport :: String -> Int -> IO Transport
httpTransport host port = do
  server <- listening host port
  bound <- socketPort server
  closed <- newIORef False
  let address = "http://" ++ host ++ ":" ++ show bound
      start deliver = () <$ forkIO (acceptLoop server closed (\sock -> serveRequest sock deliver))
      send node frame = do
        outcome <- try (bracket (connectTo node "http://") close (\sock -> do
          let (h, p) = hostPort (drop (length "http://") node)
              headers = "POST /lawspec HTTP/1.1\r\nHost: " ++ h ++ ":" ++ p
                ++ "\r\nContent-Type: application/octet-stream\r\nContent-Length: " ++ show (B.length frame)
                ++ "\r\nConnection: close\r\n\r\n"
          NB.sendAll sock (BC.pack headers <> frame)
          response <- readHead sock B.empty
          let status = words (BC.unpack (BC.takeWhile (/= '\r') response))
          unless (take 1 (drop 1 status) `elem` [["204"], ["200"]])
            (throwIO (userError ("the node answered " ++ unwords (take 3 status))))))
        case outcome of
          Right () -> pure ()
          Left (e :: SomeException) -> throwIO (Unreachable ("cannot reach " ++ node ++ ": " ++ show e))
      stop = stopListening server address "http://" closed
  pure (Transport address start send stop)

listening :: String -> Int -> IO Socket
listening host port = do
  info : _ <- getAddrInfo (Just defaultHints { addrSocketType = Stream, addrFlags = [AI_NUMERICSERV] }) (Just host) (Just (show port))
  sock <- socket (addrFamily info) Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (addrAddress info)
  listen sock 64
  pure sock

-- | Stops accepting. Closing a socket that accept is waiting on can stall
-- GHC's non-threaded runtime, so the accept loop is woken by a connection
-- of our own and closes the socket itself.
stopListening :: Socket -> String -> String -> IORefBool -> IO ()
stopListening _ address scheme closed = do
  already <- readIORef closed
  unless already $ do
    writeIORef closed True
    woken <- try (connectTo address scheme)
    case woken of
      Right sock -> close sock
      Left (_ :: SomeException) -> pure ()

acceptLoop :: Socket -> IORefBool -> (Socket -> IO ()) -> IO ()
acceptLoop server closed handler = loop
  where
    finish = close server `catch` \(_ :: SomeException) -> pure ()
    loop = do
      accepted <- try (accept server)
      done <- readIORef closed
      case accepted of
        _ | done -> do
          either (\(_ :: SomeException) -> pure ()) (\(sock, _) -> close sock) accepted
          finish
        Left (_ :: SomeException) -> loop
        Right (sock, _) -> do
          _ <- forkIO ((handler sock `catch` \(_ :: SomeException) -> pure ()) >> (close sock `catch` \(_ :: SomeException) -> pure ()))
          loop

type IORefBool = IORef Bool

hostPort :: String -> (String, String)
hostPort rest = let (h, p) = break (== ':') (reverse (takeWhile (/= '/') rest))
                in (reverse (drop 1 p), reverse h)

connectTo :: String -> String -> IO Socket
connectTo node scheme = do
  let (h, p) = hostPort (drop (length scheme) node)
  info : _ <- getAddrInfo (Just defaultHints { addrSocketType = Stream }) (Just h) (Just p)
  sock <- socket (addrFamily info) Stream defaultProtocol
  connect sock (addrAddress info) `catch` \(e :: SomeException) -> close sock >> throwIO e
  pure sock

-- | Exactly n bytes, or Nothing at the end of the stream.
readExactly :: Socket -> Int -> IO (Maybe ByteString)
readExactly sock n = go B.empty
  where
    go acc
      | B.length acc >= n = pure (Just acc)
      | otherwise = do
          chunk <- NB.recv sock (n - B.length acc)
          if B.null chunk then pure Nothing else go (acc <> chunk)

readFrames :: Socket -> (ByteString -> IO ()) -> IO ()
readFrames sock deliver = do
  header <- readExactly sock 4
  case header of
    Nothing -> pure ()
    Just h -> do
      let n = foldl (\acc b -> (acc `shiftL` 8) .|. fromIntegral b) 0 (B.unpack h) :: Int
      frame <- readExactly sock (n .&. 0x7FFFFFFF)
      case frame of
        Nothing -> pure ()
        Just f -> deliver f >> readFrames sock deliver

-- | The bytes up to and including the blank line after the headers.
readHead :: Socket -> ByteString -> IO ByteString
readHead sock acc
  | BC.pack "\r\n\r\n" `B.isInfixOf` acc = pure acc
  | otherwise = do
      chunk <- NB.recv sock 4096
      if B.null chunk then pure acc else readHead sock (acc <> chunk)

serveRequest :: Socket -> (ByteString -> IO ()) -> IO ()
serveRequest sock deliver = do
  raw <- readHead sock B.empty
  let (headPart, rest) = B.breakSubstring (BC.pack "\r\n\r\n") raw
      body0 = B.drop 4 rest
      ls = lines (filter (/= '\r') (BC.unpack headPart))
      requestLine = words (concat (take 1 ls))
      lengthOf = [read (takeWhile isDigit (dropWhile (== ' ') (drop 1 (dropWhile (/= ':') l)))) :: Int
                 | l <- drop 1 ls, "content-length" `isPrefixOf` map toLower l]
      wanted = case lengthOf of n : _ -> n; [] -> 0
  more <- readExactly sock (max 0 (wanted - B.length body0))
  let body = B.take wanted (body0 <> maybe B.empty id more)
      ok = take 2 requestLine == ["POST", "/lawspec"]
  NB.sendAll sock (BC.pack (if ok then "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    else "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
  if ok then deliver body else pure ()
