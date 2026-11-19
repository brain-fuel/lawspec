{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE GADTs #-}

-- | The native IO interpreter: the effects performed directly by the
-- operating system, for the native @lawspec-native@ executable (the JVM
-- packages' platform binaries, and parity runs). It answers with the same
-- typed results as a WebAssembly host, and like every host it enforces the
-- policy it is confined to, symbolic links included. HTTPS fetches use
-- http-client with http-client-tls; HTTP serving uses Warp on a loopback
-- socket. @rename@ is rename(2), and a file's or directory's permission
-- bits are given to open(2) and mkdir(2) as it is created and read back
-- from stat(2). @realpath@ calls the C library's realpath(3), and @terminal@ asks
-- isatty and the TIOCGWINSZ ioctl. This module is built only for native
-- targets (package.yaml), so the WebAssembly core never links its network
-- dependencies or these C calls.
-- ref:DEC-host-effect-abi ref:http-client ref:warp ref:realpath ref:ghc-capi
module LawSpec.Host.Native (nativeHost) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (Handler (..), IOException, catches, finally, try)
import Control.Monad (forM_, unless, void, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word16)
import Foreign.C.Error (Errno (..), eACCES, eADDRINUSE, eEXIST, eISDIR, eNOENT, eNOTDIR, eNOTEMPTY, ePERM, throwErrnoPathIfNull)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes, free)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peekByteOff)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOException (..))
import qualified GHC.IO.Exception as IOType
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, normalise, takeDirectory)
import LawSpec.Host.Policy (Policy (..), closed)
import LawSpec.Host.Sandbox (Resolution (..), enforced)
import qualified Network.HTTP.Client as Http
import qualified Network.HTTP.Client.TLS as Tls
import qualified Network.HTTP.Types as HttpTypes
import qualified Network.Socket as Socket
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    getDirectoryContents,
    getHomeDirectory,
    getTemporaryDirectory,
    removeDirectory,
    removeFile,
    removePathForcibly,
    renameFile,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush, hIsTerminalDevice, hSetBinaryMode, stderr, stdin, stdout)
import qualified System.Posix.Directory as Directory
import qualified System.Posix.Files as Files
import qualified System.Posix.IO as PosixIO
import System.Posix.Internals (peekFilePath, withFilePath)
import System.Posix.Types (FileMode)
import qualified System.Process as Process
import System.Timeout (timeout)

-- | realpath(3) with a null buffer, which POSIX.1-2008 has it allocate.
foreign import ccall unsafe "stdlib.h realpath"
  c_realpath :: CString -> CString -> IO CString

-- | ioctl is variadic, so it is called through a C stub with its prototype
-- (the capi convention), never as a plain ccall.
foreign import capi unsafe "sys/ioctl.h ioctl"
  c_ioctl :: CInt -> CULong -> Ptr () -> IO CInt

foreign import capi "sys/ioctl.h value TIOCGWINSZ"
  tiocgwinsz :: CULong

data Running = Running
  { runningProcess :: Process.ProcessHandle,
    runningDone :: TVar Bool
  }

-- | The interpreter's state: running processes, listeners and the HTTP
-- requests waiting for a response.
data Native = Native
  { nativeProcesses :: IORef (M.Map Int Running),
    nativeCounter :: IORef Int,
    nativeEvents :: TVar (M.Map Int [Event]),
    nativeListeners :: IORef (M.Map Int (TQueue IncomingRequest)),
    nativePending :: TVar (M.Map Int (TMVar Response)),
    -- | Created on the first fetch, so a run that never fetches never loads
    -- the system's trust store.
    nativeManager :: IORef (Maybe Http.Manager),
    -- | The interpreter's own home and temporary directories, which the
    -- guard protects whatever the policy names ('ownProtected').
    nativeProtected :: [FilePath]
  }

-- | A fresh interpreter with its own process table, confined to 'closed'
-- until 'confined' gives it a command's policy.
nativeHost :: IO (Host IO)
nativeHost = do
  native <- Native <$> newIORef M.empty <*> newIORef 1 <*> newTVarIO M.empty <*> newIORef M.empty <*> newTVarIO M.empty <*> newIORef Nothing <*> ownProtected
  mapM_ (`hSetBinaryMode` True) [stdout, stderr, stdin]
  pure (confinedTo native closed)

confinedTo :: Native -> Policy -> Host IO
confinedTo native policy = Host (\effect -> guarded (enforce native policy effect)) (confinedTo native)

-- | The home and temporary directories as this process sees them: HOME and
-- TMPDIR, and the directory package's answers, which may differ.
ownProtected :: IO [FilePath]
ownProtected = do
  variables <- mapM lookupEnv ["HOME", "TMPDIR"]
  home <- try getHomeDirectory :: IO (Either IOException FilePath)
  temporary <- try getTemporaryDirectory :: IO (Either IOException FilePath)
  pure [normalise path | path <- [v | Just v <- variables] ++ [v | Right v <- [home, temporary]], isAbsolute path]

-- | The host's own check of the policy: the core's lexical rules, then the
-- same paths with their symbolic links resolved by the operating system.
-- The guard protects the interpreter's own home and temporary directories
-- besides those the policy names.
enforce :: Native -> Policy -> Effect a -> IO (Either HostError a)
enforce native policy effect = do
  refused <- enforced realPath policy {protectedPaths = protectedPaths policy ++ nativeProtected native} effect
  case refused of
    Just problem -> pure (Left (HostError Denied problem))
    Nothing -> run native effect

-- | realpath, keeping missing trailing components (canonicalizePath).
realPath :: Resolution -> FilePath -> IO FilePath
realPath Whole path = normalise <$> canonicalizePath path
realPath Parent path
  | path == "/" = pure path
  | otherwise = (`join` reverse (takeWhile (/= '/') (reverse path))) . normalise <$> canonicalizePath (takeDirectory path)

guarded :: IO (Either HostError a) -> IO (Either HostError a)
guarded action =
  action
    `catches` [ Handler (pure . Left . classify),
                Handler (pure . Left . httpFailure)
              ]

httpFailure :: Http.HttpException -> HostError
httpFailure = \case
  Http.InvalidUrlException url reason -> HostError Invalid ("invalid URL " ++ url ++ ": " ++ reason)
  Http.HttpExceptionRequest request content ->
    HostError Failed (BC.unpack (Http.host request) ++ ": " ++ show content)

-- | Errno first, as the operating system reported it; GHC's coarser error
-- type when there is none.
classify :: IOException -> HostError
classify problem = HostError kind (show problem)
  where
    kind = case ioe_errno problem of
      Just errno
        | Errno errno == eNOENT -> NotFound
        | Errno errno == eEXIST -> AlreadyExists
        -- serve: the port is taken.
        | Errno errno == eADDRINUSE -> AlreadyExists
        | Errno errno `elem` [eACCES, ePERM] -> PermissionDenied
        | Errno errno == eNOTDIR -> NotADirectory
        | Errno errno == eISDIR -> IsADirectory
        | Errno errno == eNOTEMPTY -> DirectoryNotEmpty
      _ -> case ioe_type problem of
        IOType.NoSuchThing -> NotFound
        IOType.AlreadyExists -> AlreadyExists
        IOType.PermissionDenied -> PermissionDenied
        IOType.UnsatisfiedConstraints -> DirectoryNotEmpty
        -- GHC's openFile refuses a directory itself, without an errno.
        IOType.InappropriateType | ioe_description problem == "is a directory" -> IsADirectory
        _ -> Failed

run :: Native -> Effect a -> IO (Either HostError a)
run native effect = case effect of
  ReadFile path -> absolute path (fmap Right . B.readFile)
  WriteFile mode bits path bytes -> absolute path $ \target -> Right <$> atomicWrite mode bits target bytes
  ListDirectory path -> absolute path $ \target -> do
    names <- filter (`notElem` [".", ".."]) <$> getDirectoryContents target
    entries <- mapM (\name -> Entry name . kindOf <$> Files.getSymbolicLinkStatus (target ++ "/" ++ name)) names
    pure (Right entries)
  Stat follow path -> absolute path $ \target -> do
    status <- (if follow == Follow then Files.getFileStatus else Files.getSymbolicLinkStatus) target
    pure
      ( Right
          ( Status
              (kindOf status)
              (fromIntegral (Files.fileSize status))
              (floor (1000 * toRational (Files.modificationTimeHiRes status)))
              (Just (fromIntegral (Files.fileMode status) .&. permissionMask))
          )
      )
  RealPath path -> absolute path $ \target -> Right <$> canonical target
  Remove recursive path -> absolute path $ \target -> do
    status <- Files.getSymbolicLinkStatus target
    if Files.isDirectory status
      then if recursive == Recursive then removePathForcibly target else removeDirectory target
      else removeFile target
    pure (Right ())
  Rename from to
    | not (isAbsolute from) -> pure (Left (HostError Invalid ("path is not absolute: " ++ from)))
    | otherwise -> absolute to $ \target -> Right <$> Files.rename (normalise from) target
  MakeDirectories bits path -> absolute path $ \target -> do
    existing <- try (Files.getFileStatus target) :: IO (Either IOException Files.FileStatus)
    case (existing, bits) of
      (Right status, _) | not (Files.isDirectory status) -> pure (Left (HostError AlreadyExists target))
      (_, Nothing) -> Right <$> createDirectoryIfMissing True target
      (_, Just given) -> Right <$> makeDirectories (fromIntegral given) target
  Spawn request -> spawn request
  Poll handles limit -> do
    let wanted = [handle | ProcessHandle handle <- handles]
    known <- readIORef processes
    case filter (`M.notMember` known) wanted of
      unknown : _ -> pure (Left (HostError Invalid ("unknown process handle " ++ show unknown)))
      [] -> do
        let collect = do
              table <- readTVar events
              let found = concat [M.findWithDefault [] handle table | handle <- wanted]
              when (null found) retry
              writeTVar events (foldr M.delete table wanted)
              pure found
        found <- within limit collect
        pure (Right (maybe [] id found))
  Kill (ProcessHandle handle) -> do
    known <- readIORef processes
    case M.lookup handle known of
      Nothing -> pure (Left (HostError Invalid ("unknown process handle " ++ show handle)))
      Just running -> do
        done <- readTVarIO (runningDone running)
        unless done (Process.terminateProcess (runningProcess running))
        pure (Right ())
  Fetch request
    | take 8 (fetchUrl request) /= "https://" -> pure (Left (HostError Denied ("only https URLs may be fetched: " ++ fetchUrl request)))
    | otherwise -> fetch request
  GetEnvironment name -> Right <$> lookupEnv name
  GetClock -> do
    wall <- getPOSIXTime
    monotonic <- getMonotonicTimeNSec
    pure (Right (Clock (floor (1000 * toRational wall)) (fromIntegral (monotonic `div` 1000))))
  WriteOutput stream bytes -> do
    let handle = if stream == Stdout then stdout else stderr
    B.hPut handle bytes
    hFlush handle
    pure (Right ())
  ReadInput limit -> do
    bytes <- B.hGetSome stdin (max 1 limit)
    pure (Right (Input bytes (B.null bytes)))
  QueryTerminal stream -> Right <$> terminal stream
  Serve port -> serve port
  Accept (Listener listener) limit -> do
    known <- readIORef (nativeListeners native)
    case M.lookup listener known of
      Nothing -> pure (Left (HostError Invalid ("unknown listener " ++ show listener)))
      Just queue -> Right <$> within limit (readTQueue queue)
  Respond (RequestId request) response -> do
    slot <- atomically $ do
      table <- readTVar (nativePending native)
      writeTVar (nativePending native) (M.delete request table)
      pure (M.lookup request table)
    case slot of
      Nothing -> pure (Left (HostError Invalid ("unknown request " ++ show request)))
      Just answer -> Right <$> atomically (void (tryPutTMVar answer response))
  where
    processes = nativeProcesses native
    counter = nativeCounter native
    events = nativeEvents native
    fresh = atomicModifyIORef' counter (\next -> (next + 1, next))
    -- What is available now, or the first thing to arrive within the
    -- timeout (milliseconds).
    within :: Int -> STM b -> IO (Maybe b)
    within limit wait = do
      ready <- atomically ((Just <$> wait) `orElse` pure Nothing)
      case ready of
        Just value -> pure (Just value)
        Nothing | limit <= 0 -> pure Nothing
        Nothing -> timeout (limit * 1000) (atomically wait)
    fetch :: FetchRequest -> IO (Either HostError FetchResponse)
    fetch request = do
      manager <- do
        existing <- readIORef (nativeManager native)
        case existing of
          Just manager -> pure manager
          Nothing -> do
            manager <- Tls.newTlsManager
            writeIORef (nativeManager native) (Just manager)
            pure manager
      base <- Http.parseRequest (fetchUrl request)
      let headers = [(CI.mk (BC.pack name), BC.pack value) | (name, value) <- fetchHeaders request]
          identity = [("Accept-Encoding", "identity") | not (any ((== "accept-encoding") . CI.foldedCase . fst) headers)]
          prepared =
            base
              { Http.method = BC.pack (fetchMethod request),
                Http.requestHeaders = headers ++ identity,
                Http.requestBody = Http.RequestBodyBS (maybe B.empty id (fetchBody request)),
                Http.redirectCount = 0,
                Http.decompress = const False,
                Http.responseTimeout = Http.responseTimeoutMicro 60000000
              }
      response <- Http.httpLbs prepared manager
      pure
        ( Right
            ( FetchResponse
                (HttpTypes.statusCode (Http.responseStatus response))
                [(BC.unpack (CI.foldedCase name), BC.unpack value) | (name, value) <- Http.responseHeaders response]
                (BL.toStrict (Http.responseBody response))
            )
        )
    serve :: Int -> IO (Either HostError Listening)
    serve port = do
      socket <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
      bound <- try $ do
        Socket.setSocketOption socket Socket.ReuseAddr 1
        Socket.bind socket (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
        Socket.listen socket 128
        Socket.socketPort socket
      case bound of
        Left problem -> do
          Socket.close socket
          pure (Left (classify problem))
        Right actual -> do
          listener <- fresh
          queue <- newTQueueIO
          modifyIORef' (nativeListeners native) (M.insert listener queue)
          let settings = Warp.setOnException (\_ _ -> pure ()) Warp.defaultSettings
          _ <- forkIO (Warp.runSettingsSocket settings socket (application queue))
          pure (Right (Listening (Listener listener) (fromIntegral actual)))
    -- Each request waits in its Warp thread until the core responds. A
    -- target that is not visible ASCII is refused here, as Node's parser
    -- refuses it, and never accepted.
    application :: TQueue IncomingRequest -> Wai.Application
    application _ request reply
      | B.any (\byte -> byte < 0x21 || byte > 0x7E) (Wai.rawPathInfo request <> Wai.rawQueryString request) =
          reply (Wai.responseLBS (toEnum 400) [("Connection", "close")] BL.empty)
    application queue request reply = do
      body <- Wai.strictRequestBody request
      number <- fresh
      answer <- newEmptyTMVarIO
      atomically $ do
        modifyTVar' (nativePending native) (M.insert number answer)
        writeTQueue
          queue
          ( IncomingRequest
              (RequestId number)
              (BC.unpack (Wai.requestMethod request))
              (BC.unpack (Wai.rawPathInfo request <> Wai.rawQueryString request))
              [(BC.unpack (CI.foldedCase name), BC.unpack value) | (name, value) <- Wai.requestHeaders request]
              (BL.toStrict body)
          )
      Response status headers bytes <- atomically (takeTMVar answer)
      reply
        ( Wai.responseLBS
            (toEnum status)
            [(CI.mk (BC.pack name), BC.pack value) | (name, value) <- headers]
            (BL.fromStrict bytes)
        )
    absolute :: FilePath -> (FilePath -> IO (Either HostError b)) -> IO (Either HostError b)
    absolute path continue
      | isAbsolute path = continue (normalise path)
      | otherwise = pure (Left (HostError Invalid ("path is not absolute: " ++ path)))
    spawn request = case spawnArguments request of
      [] -> pure (Left (HostError Invalid "spawn needs a program"))
      program : arguments -> do
        let process =
              (Process.proc program arguments)
                { Process.cwd = Just (spawnDirectory request),
                  Process.env = spawnEnvironment request,
                  Process.std_in = Process.CreatePipe,
                  Process.std_out = Process.CreatePipe,
                  Process.std_err = Process.CreatePipe
                }
        (Just input, Just output, Just failure, handle) <- Process.createProcess process
        number <- fresh
        done <- newTVarIO False
        modifyIORef' processes (M.insert number (Running handle done))
        let push event = atomically (modifyTVar' events (M.insertWith (flip (++)) number [event]))
        _ <- forkIO $ do
          _ <- try (B.hPut input (maybe B.empty id (spawnInput request))) :: IO (Either IOException ())
          void (try (hClose input) :: IO (Either IOException ()))
        outputDone <- newEmptyTMVarIO
        failureDone <- newEmptyTMVarIO
        let pump stream source finished =
              void . forkIO $
                let loop = do
                      chunk <- B.hGetSome source 65536
                      if B.null chunk
                        then hClose source
                        else push (Chunk (ProcessHandle number) stream chunk) >> loop
                 in void (try loop :: IO (Either IOException ())) `finally` atomically (putTMVar finished ())
        pump Stdout output outputDone
        pump Stderr failure failureDone
        _ <- forkIO $ do
          atomically (takeTMVar outputDone >> takeTMVar failureDone)
          code <- waitWithoutBlocking handle
          push (Exited (ProcessHandle number) (exitStatus code))
          atomically (writeTVar done True)
        pure (Right (ProcessHandle number))

-- | realpath(3): every component must exist, and the C library gives the
-- stored case of each name on macOS.
canonical :: FilePath -> IO FilePath
canonical path = withFilePath path $ \name -> do
  real <- throwErrnoPathIfNull "realpath" path (c_realpath name nullPtr)
  peekFilePath real `finally` free real

-- | isatty, and for an output stream that is one, the width TIOCGWINSZ
-- reports (struct winsize: ws_row, then ws_col, each an unsigned short).
terminal :: StandardStream -> IO Terminal
terminal stream = do
  attached <- hIsTerminalDevice handle
  columns <-
    if not attached || stream == StandardInput
      then pure Nothing
      else allocaBytes 8 $ \size -> do
        answer <- c_ioctl descriptor tiocgwinsz size
        width <- peekByteOff size 2 :: IO Word16
        pure (if answer == 0 && width > 0 then Just (fromIntegral width) else Nothing)
  pure (Terminal attached columns)
  where
    (handle, descriptor) = case stream of
      StandardInput -> (stdin, 0)
      StandardOutput -> (stdout, 1)
      StandardError -> (stderr, 2)

-- | Poll for the exit status, so the single-threaded runtime is never
-- blocked in a foreign wait.
waitWithoutBlocking :: Process.ProcessHandle -> IO ExitCode
waitWithoutBlocking handle = do
  status <- Process.getProcessExitCode handle
  case status of
    Just code -> pure code
    Nothing -> threadDelay 1000 >> waitWithoutBlocking handle

-- | System.Process reports a signal as a negative exit code.
exitStatus :: ExitCode -> ExitStatus
exitStatus ExitSuccess = ExitCode 0
exitStatus (ExitFailure code)
  | code < 0 = Signalled (signalName (negate code))
  | otherwise = ExitCode code

signalName :: Int -> String
signalName number = maybe ("SIG" ++ show number) id (lookup number names)
  where
    names = [(1, "SIGHUP"), (2, "SIGINT"), (3, "SIGQUIT"), (6, "SIGABRT"), (9, "SIGKILL"), (13, "SIGPIPE"), (14, "SIGALRM"), (15, "SIGTERM")]

kindOf :: Files.FileStatus -> EntryKind
kindOf status
  | Files.isSymbolicLink status = SymbolicLinkKind
  | Files.isDirectory status = DirectoryKind
  | Files.isRegularFile status = FileKind
  | otherwise = OtherKind

-- | mkdir(2) with the given bits for the directory and each missing parent,
-- outermost first, as mkdir -p and Node's recursive mkdir create them; one
-- that appears meanwhile is kept.
makeDirectories :: FileMode -> FilePath -> IO ()
makeDirectories bits target = do
  missing <- missingFrom target []
  forM_ missing $ \directory -> do
    made <- try (Directory.createDirectory directory bits) :: IO (Either IOException ())
    case made of
      Left problem | ioe_errno problem /= (let Errno code = eEXIST in Just code) -> ioError problem
      _ -> pure ()
  where
    missingFrom directory acc
      | directory == "/" = pure acc
      | otherwise = do
          present <- Files.fileExist directory
          if present then pure acc else missingFrom (takeDirectory directory) (directory : acc)

-- | A temporary sibling written exclusively, then renamed over the target or
-- hard-linked to it, so readers never see a partial file. It is created
-- with the given permission bits (0666 without), less the umask.
atomicWrite :: WriteMode -> Maybe Permissions -> FilePath -> B.ByteString -> IO ()
atomicWrite mode bits target bytes = do
  createDirectoryIfMissing True (takeDirectory target)
  stamp <- getMonotonicTimeNSec
  let temporary = target ++ ".lawspec-" ++ show stamp ++ ".tmp"
  ( do
      descriptor <- PosixIO.openFd temporary PosixIO.WriteOnly PosixIO.defaultFileFlags {PosixIO.exclusive = True, PosixIO.creat = Just permissions}
      handle <- PosixIO.fdToHandle descriptor
      writeAll handle
      case mode of
        Replace -> renameFile temporary target
        Create -> Files.createLink temporary target
    )
    `finally` void (try (removeFile temporary) :: IO (Either IOException ()))
  where
    permissions = maybe 0o666 fromIntegral bits :: FileMode
    writeAll :: Handle -> IO ()
    writeAll handle = (B.hPut handle bytes >> hFlush handle) `finally` hClose handle
