{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | The primitive effects a LawSpec host provides, and the interface every
-- application command is written against. A host performs one request at a
-- time and answers with a typed result: a failure is a 'HostError' value,
-- never an exception crossing the boundary. Every decision about which
-- effect to perform, and what its result means, stays in Haskell.
-- ref:DEC-host-effect-abi ref:DEC-haskell-application-port
module LawSpec.Host.Effect
  ( Effect (..),
    SomeEffect (..),
    Host (..),
    HostError (..),
    ErrorKind (..),
    errorKindName,
    errorKindFromName,
    WriteMode (..),
    Permissions,
    permissionMask,
    Follow (..),
    Recursive (..),
    EntryKind (..),
    entryKindName,
    entryKindFromName,
    Entry (..),
    Status (..),
    ProcessHandle (..),
    SpawnRequest (..),
    Stream (..),
    StandardStream (..),
    Terminal (..),
    Event (..),
    ExitStatus (..),
    Clock (..),
    Input (..),
    FetchRequest (..),
    FetchResponse (..),
    Listener (..),
    Listening (..),
    RequestId (..),
    IncomingRequest (..),
    Response (..),
    hostError,
    effectName,
    sameEffect,
  )
where

import qualified Data.ByteString as B
import LawSpec.Host.Policy (Policy)

-- | One primitive effect and the type of its successful result. Paths are
-- absolute; a host refuses a relative path as 'Invalid'.
data Effect a where
  -- | The whole file's bytes, following symbolic links.
  ReadFile :: FilePath -> Effect B.ByteString
  -- | Write a whole file atomically: a temporary sibling, then a rename
  -- ('Replace') or a hard link that fails when the file exists ('Create').
  -- Missing parent directories are created. The temporary file is created
  -- with the given permission bits, or 0666 when there are none, less the
  -- host's file-creation mask, as open(2) creates a file; the file the path
  -- names afterwards is always that new file.
  WriteFile :: WriteMode -> Maybe Permissions -> FilePath -> B.ByteString -> Effect ()
  -- | A directory's entries, without @.@ and @..@, in no particular order.
  ListDirectory :: FilePath -> Effect [Entry]
  Stat :: Follow -> FilePath -> Effect Status
  -- | The path's canonical absolute form, as POSIX realpath(3) gives it:
  -- every symbolic link resolved, every component present ('NotFound'
  -- otherwise), and on macOS each name in the case stored on disk. The path
  -- is normalised lexically first, as every request path is.
  RealPath :: FilePath -> Effect FilePath
  Remove :: Recursive -> FilePath -> Effect ()
  -- | rename(2): move the first path to the second atomically, within one
  -- file system, replacing an existing file (or an empty directory, when
  -- the first is a directory). Neither path's final link is followed.
  -- Across file systems it fails ('Failed') and never copies.
  -- ref:posix-rename
  Rename :: FilePath -> FilePath -> Effect ()
  -- | Create a directory and its missing parents; an existing one is
  -- success and keeps its permission bits. Each directory created gets the
  -- given bits, or 0777 when there are none, less the host's file-creation
  -- mask, as mkdir(2) does.
  MakeDirectories :: Maybe Permissions -> FilePath -> Effect ()
  Spawn :: SpawnRequest -> Effect ProcessHandle
  -- | Wait up to the timeout (milliseconds) for output or exits of the given
  -- processes. Returns every event available when it wakes, possibly none.
  Poll :: [ProcessHandle] -> Int -> Effect [Event]
  Kill :: ProcessHandle -> Effect ()
  -- | An HTTPS request. Other schemes are refused as 'Denied'.
  Fetch :: FetchRequest -> Effect FetchResponse
  GetEnvironment :: String -> Effect (Maybe String)
  GetClock :: Effect Clock
  WriteOutput :: Stream -> B.ByteString -> Effect ()
  -- | Read up to the given number of bytes of standard input.
  ReadInput :: Int -> Effect Input
  -- | Whether one of the host's standard streams is a terminal, and its
  -- width when the host can tell.
  QueryTerminal :: StandardStream -> Effect Terminal
  -- | Listen for HTTP on the loopback interface; port 0 picks a free one.
  Serve :: Int -> Effect Listening
  -- | Wait up to the timeout (milliseconds) for the next HTTP request.
  Accept :: Listener -> Int -> Effect (Maybe IncomingRequest)
  Respond :: RequestId -> Response -> Effect ()

deriving instance Show (Effect a)

instance Eq (Effect a) where
  (==) = sameEffect

-- | An effect whose result type has been forgotten, as a host decodes it.
data SomeEffect where
  SomeEffect :: Effect a -> SomeEffect

instance Show SomeEffect where
  show (SomeEffect effect) = show effect

instance Eq SomeEffect where
  SomeEffect left == SomeEffect right = sameEffect left right

-- | Structural equality across result types.
sameEffect :: Effect a -> Effect b -> Bool
sameEffect left right = case (left, right) of
  (ReadFile a, ReadFile b) -> a == b
  (WriteFile m p a d, WriteFile n q b e) -> (m, p, a, d) == (n, q, b, e)
  (ListDirectory a, ListDirectory b) -> a == b
  (Stat f a, Stat g b) -> (f, a) == (g, b)
  (RealPath a, RealPath b) -> a == b
  (Remove r a, Remove s b) -> (r, a) == (s, b)
  (Rename a c, Rename b d) -> (a, c) == (b, d)
  (MakeDirectories p a, MakeDirectories q b) -> (p, a) == (q, b)
  (Spawn a, Spawn b) -> a == b
  (Poll a t, Poll b u) -> (a, t) == (b, u)
  (Kill a, Kill b) -> a == b
  (Fetch a, Fetch b) -> a == b
  (GetEnvironment a, GetEnvironment b) -> a == b
  (GetClock, GetClock) -> True
  (WriteOutput s a, WriteOutput t b) -> (s, a) == (t, b)
  (ReadInput a, ReadInput b) -> a == b
  (QueryTerminal a, QueryTerminal b) -> a == b
  (Serve a, Serve b) -> a == b
  (Accept a t, Accept b u) -> (a, t) == (b, u)
  (Respond a r, Respond b s) -> (a, r) == (b, s)
  _ -> False

-- | The wire name of an effect's operation.
effectName :: Effect a -> String
effectName = \case
  ReadFile {} -> "read"
  WriteFile {} -> "write"
  ListDirectory {} -> "list"
  Stat {} -> "stat"
  RealPath {} -> "realpath"
  Remove {} -> "remove"
  Rename {} -> "rename"
  MakeDirectories {} -> "mkdirs"
  Spawn {} -> "spawn"
  Poll {} -> "poll"
  Kill {} -> "kill"
  Fetch {} -> "fetch"
  GetEnvironment {} -> "env"
  GetClock -> "clock"
  WriteOutput {} -> "output"
  ReadInput {} -> "input"
  QueryTerminal {} -> "terminal"
  Serve {} -> "serve"
  Accept {} -> "accept"
  Respond {} -> "respond"

-- | Commands are written against this record, so one command runs over the
-- WebAssembly import, native IO or the in-memory fake unchanged.
data Host m = Host
  { perform :: forall a. Effect a -> m (Either HostError a),
    -- | The same host told the policy the core enforces, so that the host
    -- refuses out-of-policy requests itself ('Denied'). Every effect the
    -- result performs carries the policy; a host without a policy of its own
    -- enforces 'LawSpec.Host.Policy.closed'.
    confined :: Policy -> Host m
  }

-- | A typed failure. The kind is what callers branch on; the message is for
-- people and carries no meaning.
data HostError = HostError {errorKind :: ErrorKind, errorMessage :: String}
  deriving (Eq, Show)

hostError :: ErrorKind -> String -> HostError
hostError = HostError

data ErrorKind
  = NotFound
  | AlreadyExists
  | PermissionDenied
  | NotADirectory
  | IsADirectory
  | DirectoryNotEmpty
  | -- | The sandbox policy, in the core or the host, refused the request.
    Denied
  | -- | This host does not provide the effect.
    Unsupported
  | -- | The request was malformed, such as a relative path or unknown handle.
    Invalid
  | -- | Any other operating-system or network failure.
    Failed
  deriving (Eq, Show, Enum, Bounded)

errorKindName :: ErrorKind -> String
errorKindName = \case
  NotFound -> "not-found"
  AlreadyExists -> "already-exists"
  PermissionDenied -> "permission-denied"
  NotADirectory -> "not-a-directory"
  IsADirectory -> "is-a-directory"
  DirectoryNotEmpty -> "directory-not-empty"
  Denied -> "denied"
  Unsupported -> "unsupported"
  Invalid -> "invalid"
  Failed -> "failed"

errorKindFromName :: String -> Maybe ErrorKind
errorKindFromName name = lookup name [(errorKindName kind, kind) | kind <- [minBound .. maxBound]]

data WriteMode = Replace | Create deriving (Eq, Show)

-- | POSIX permission bits: the owner, group and other bits with set-user-ID,
-- set-group-ID and sticky, within 'permissionMask'. Never the file type.
type Permissions = Int

-- | 0o7777, the bits 'Permissions' may hold.
permissionMask :: Permissions
permissionMask = 0o7777

-- | Whether 'Stat' follows a final symbolic link (stat) or reports it (lstat).
data Follow = Follow | NoFollow deriving (Eq, Show)

data Recursive = Recursive | NotRecursive deriving (Eq, Show)

data EntryKind = FileKind | DirectoryKind | SymbolicLinkKind | OtherKind
  deriving (Eq, Ord, Show, Enum, Bounded)

entryKindName :: EntryKind -> String
entryKindName = \case
  FileKind -> "file"
  DirectoryKind -> "directory"
  SymbolicLinkKind -> "symlink"
  OtherKind -> "other"

entryKindFromName :: String -> Maybe EntryKind
entryKindFromName name = lookup name [(entryKindName kind, kind) | kind <- [minBound .. maxBound]]

data Entry = Entry {entryName :: String, entryKind :: EntryKind}
  deriving (Eq, Show)

data Status = Status
  { statusKind :: EntryKind,
    statusSize :: Integer,
    -- | Milliseconds since the Unix epoch.
    statusModified :: Integer,
    -- | The permission bits ('permissionMask'), or 'Nothing' where the host
    -- cannot tell.
    statusPermissions :: Maybe Permissions
  }
  deriving (Eq, Show)

newtype ProcessHandle = ProcessHandle Int deriving (Eq, Ord, Show)

data SpawnRequest = SpawnRequest
  { spawnArguments :: [String],
    spawnDirectory :: FilePath,
    -- | 'Nothing' inherits the host's environment; 'Just' replaces it.
    spawnEnvironment :: Maybe [(String, String)],
    -- | Bytes written to standard input, which is then closed. 'Nothing'
    -- gives the process an empty, closed standard input.
    spawnInput :: Maybe B.ByteString
  }
  deriving (Eq, Show)

data Stream = Stdout | Stderr deriving (Eq, Show)

-- | The host's own standard streams, as 'QueryTerminal' names them.
data StandardStream = StandardInput | StandardOutput | StandardError
  deriving (Eq, Show, Enum, Bounded)

data Terminal = Terminal
  { -- | Whether the stream is a terminal (isatty).
    isTerminal :: Bool,
    -- | The terminal's width in columns: 'Nothing' when the stream is not a
    -- terminal, is standard input, or the host cannot tell.
    terminalColumns :: Maybe Int
  }
  deriving (Eq, Show)

data Event
  = Chunk ProcessHandle Stream B.ByteString
  | -- | Sent once, after the process's last output chunk.
    Exited ProcessHandle ExitStatus
  deriving (Eq, Show)

data ExitStatus = ExitCode Int | Signalled String deriving (Eq, Show)

data Clock = Clock
  { -- | Milliseconds since the Unix epoch.
    wallMilliseconds :: Integer,
    -- | Microseconds from an arbitrary, fixed origin; never decreases.
    monotonicMicroseconds :: Integer
  }
  deriving (Eq, Show)

data Input = Input {inputBytes :: B.ByteString, inputEnded :: Bool}
  deriving (Eq, Show)

data FetchRequest = FetchRequest
  { fetchUrl :: String,
    fetchMethod :: String,
    fetchHeaders :: [(String, String)],
    fetchBody :: Maybe B.ByteString
  }
  deriving (Eq, Show)

data FetchResponse = FetchResponse
  { fetchStatus :: Int,
    fetchResponseHeaders :: [(String, String)],
    fetchResponseBody :: B.ByteString
  }
  deriving (Eq, Show)

newtype Listener = Listener Int deriving (Eq, Ord, Show)

data Listening = Listening {listeningOn :: Listener, listeningPort :: Int}
  deriving (Eq, Show)

newtype RequestId = RequestId Int deriving (Eq, Ord, Show)

data IncomingRequest = IncomingRequest
  { requestId :: RequestId,
    requestMethod :: String,
    -- | The request target: path and query, as received.
    requestPath :: String,
    requestHeaders :: [(String, String)],
    requestBody :: B.ByteString
  }
  deriving (Eq, Show)

data Response = Response
  { responseStatus :: Int,
    responseHeaders :: [(String, String)],
    responseBody :: B.ByteString
  }
  deriving (Eq, Show)
