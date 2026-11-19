{-# LANGUAGE GADTs #-}

-- | What every ported command shares: the invocation it runs for, how it
-- fails, how it performs effects, and how it prints. A command reports
-- through the host's standard streams and returns its exit code; the texts it
-- prints are the Node CLI's, byte for byte, until that CLI is retired.
--
-- A command runs in a session: the policy its effects are confined to, which
-- grows only by explicit grants as the command learns which project it works
-- on, and the state the Node CLI kept in module variables (the warnings
-- already printed, the .lawspec folder a failed run removes).
-- ref:DEC-host-effect-abi ref:DEC-haskell-application-port
module LawSpec.App.Command
  ( Invocation (..),
    HostIdentity (..),
    CanonTool (..),
    CanonSource (..),
    Failure (..),
    Abort (..),
    Session (..),
    Compiler (..),
    Nested (..),
    Subcommand,
    Command,
    newSession,
    runCommand,
    failWith,
    failWithDiagnostics,
    unported,
    abort,
    recover,
    effect,
    effectOr,
    effectUnobserved,
    nodeFailure,
    grantRead,
    grantWrite,
    grantProject,
    grantPrograms,
    grantListening,
    protectSession,
    removeCreated,
    sessionHost,
    modifySession,
    getSession,
    liftBase,
    printLine,
    printError,
    printJson,
    writeOutput,
    utf8,
    fromUtf8,
  )
where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, catchE, runExceptT, throwE)
import Control.Monad.Trans.State.Strict (StateT, get, gets, modify', runStateT)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import LawSpec.App.Json (Json, stringify)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, normalise, takeDirectory)
import LawSpec.Host.Sandbox (Policy (..), closed, sandboxed)

-- | One run of the CLI: its arguments (without the program name), the
-- absolute working directory it was started in, the host's identity of
-- the core it runs (the SHA-256 of its module), the host itself, the
-- directory of the package resources the host ships (lawspec learn's
-- assets), when it gave them, and the Canon it ships, when it has one.
data Invocation = Invocation
  { invocationArguments :: [String],
    invocationDirectory :: FilePath,
    invocationBuild :: Maybe String,
    invocationHost :: Maybe HostIdentity,
    invocationResources :: Maybe FilePath,
    invocationCanon :: Maybe CanonSource
  }
  deriving (Eq, Show)

-- | The Canon a host ships ("tools" in the invocation): the command that
-- runs it, an absolute program and any arguments before Canon's own (the
-- native canon executable, or Node running the ricestax package's CLI with
-- @canon@), and the absolute directory of Rice's Tax's grammar presets that
-- lawspec project init and adopt copy into .ricestax/.
-- ref:DEC-native-canon
data CanonTool = CanonTool
  { canonCommand :: [String],
    canonPresets :: FilePath
  }
  deriving (Eq, Show)

-- | Where the Canon a host offers comes from: a bundle it ships
-- ('CanonTool'), or, for a host that ships none (the Go host), the npm
-- package @goforgedev/canon-<platform> the core downloads into the host's
-- cache directory and verifies against the digest this build records
-- ("LawSpec.App.CanonDownload").
-- ref:DEC-native-canon
data CanonSource
  = CanonShipped CanonTool
  | CanonDownload
      { downloadPlatform :: String,
        downloadCache :: FilePath
      }
  deriving (Eq, Show)

-- | The host that runs the core: its kind ("node", "go", "native") and its
-- version (the runtime's, as the host words it). Native test results are
-- keyed by it, with the core's digest, where the legacy CLI keyed them by
-- the Node binary and SDK files that ran it ("LawSpec.App.Test").
data HostIdentity = HostIdentity {hostKind :: String, hostVersion :: String}
  deriving (Eq, Show)

-- | A command's failure: the message, and the compiler diagnostics behind it
-- when there are any (printed instead of the message under @--json@).
data Failure = Failure
  { failureMessage :: String,
    failureDiagnostics :: Maybe Json
  }
  deriving (Eq, Show)

-- | Why a command stopped early: it failed, or it reached behaviour that is
-- not ported yet. The second is raised only before the command has written,
-- removed or printed anything ('sessionMutated'), so that the legacy CLI can
-- run the invocation instead.
data Abort = Aborted Failure | Unported String
  deriving (Eq, Show)

-- | How the application calls the compiler: request bytes to response bytes.
-- An IO host lets the compiler keep its cache through the host's effects;
-- the in-memory fake runs it without one.
newtype Compiler m = Compiler {compile :: Host m -> BL.ByteString -> m BL.ByteString}

data Session m = Session
  { sessionBase :: Host m,
    sessionPolicy :: Policy,
    sessionCompiler :: Compiler m,
    -- | Whether an effect that changes anything outside the core (a write,
    -- a removal, a process, standard output or error) has been performed.
    sessionMutated :: Bool,
    -- | The compiler warnings printed so far (diagnostics() in the Node CLI).
    sessionWarnings :: S.Set String,
    sessionCacheWarned :: Bool,
    -- | The .lawspec folder this run created, removed if the command fails.
    sessionCreatedState :: Maybe FilePath,
    -- | The host's whole environment, once a process needed it
    -- ("LawSpec.App.Process").
    sessionEnvironment :: Maybe [(String, String)],
    -- | SHA-256 digests of files read this run, by path, with the size and
    -- modification time they were taken at ("LawSpec.App.Prove").
    sessionDigests :: M.Map FilePath ((Integer, Integer), String),
    -- | While a nested invocation runs in place of a child process (see
    -- "LawSpec.App.Cli"), what it prints, latest first, instead of the
    -- host's streams.
    sessionCapture :: Maybe [(Stream, B.ByteString)],
    -- | The monotonic time, in microseconds, after which no process may run:
    -- one still running then is killed, and none starts ("LawSpec.App.Process").
    sessionDeadline :: Maybe Integer,
    -- | Whether a process was killed, or not started, for that deadline.
    sessionTimedOut :: Bool
  }

type Command m = ExceptT Abort (StateT (Session m) m)

-- | What a nested invocation of the CLI did, as a child process's result:
-- its exit code ('Nothing' when its deadline stopped it), and what it
-- printed on each stream.
data Nested = Nested
  { nestedExit :: Maybe Int,
    nestedStdout :: B.ByteString,
    nestedStderr :: B.ByteString
  }
  deriving (Eq, Show)

-- | Run the CLI again within this invocation, where the legacy CLI ran
-- itself as a child process: the arguments, the working directory and the
-- deadline (monotonic microseconds) of the run. "LawSpec.App.Cli" gives
-- commands this, so that they need not import it.
type Subcommand m = [String] -> FilePath -> Maybe Integer -> Command m Nested

newSession :: Host m -> Compiler m -> Session m
newSession host compiler = Session host closed compiler False S.empty False Nothing Nothing M.empty Nothing Nothing False

runCommand :: (Monad m) => Session m -> Command m a -> m (Either Abort a, Session m)
runCommand session command = runStateT (runExceptT command) session

failWith :: (Monad m) => String -> Command m a
failWith message = throwE (Aborted (Failure message Nothing))

failWithDiagnostics :: (Monad m) => String -> Json -> Command m a
failWithDiagnostics message diagnostics = throwE (Aborted (Failure message (Just diagnostics)))

abort :: (Monad m) => Failure -> Command m a
abort = throwE . Aborted

-- | Stop because this behaviour has not been ported. Nothing may have been
-- written or printed yet; 'LawSpec.App.Main' checks that it was not.
unported :: (Monad m) => String -> Command m a
unported = throwE . Unported

-- | Run a command step and handle its failure (not an unported stop).
recover :: (Monad m) => Command m a -> (Failure -> Command m a) -> Command m a
recover step handler =
  step `catchE` \case
    Aborted failure -> handler failure
    other -> throwE other

-- | Run an action of the host's monad.
liftBase :: (Monad m) => m a -> Command m a
liftBase = lift . lift

getSession :: (Monad m) => Command m (Session m)
getSession = lift get

modifySession :: (Monad m) => (Session m -> Session m) -> Command m ()
modifySession = lift . modify'

-- | The host as the session's policy confines it.
sessionHost :: (Monad m) => Command m (Host m)
sessionHost = do
  session <- getSession
  pure (sandboxed (sessionPolicy session) (sessionBase session))

grantRead :: (Monad m) => [FilePath] -> Command m ()
grantRead paths = modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {readRoots = readRoots (sessionPolicy s) ++ paths}})

grantWrite :: (Monad m) => [FilePath] -> Command m ()
grantWrite paths = modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {writeRoots = writeRoots (sessionPolicy s) ++ paths}})

-- | Mark project roots: the guard protects each one, and lets each be a
-- write root exactly (it grants nothing itself).
grantProject :: (Monad m) => [FilePath] -> Command m ()
grantProject paths = modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {projectRoots = projectRoots (sessionPolicy s) ++ paths}})

-- | Give the guard its anchors before a command runs: the working directory,
-- and the user's home and temporary directories as the host's environment
-- names them (os.homedir() and os.tmpdir() read the same variables). The
-- fixed system paths need no telling ("LawSpec.Host.Sandbox").
protectSession :: (Monad m) => FilePath -> Command m ()
protectSession cwd = do
  home <- variable "HOME"
  temporary <- variable "TMPDIR"
  modifySession $ \s ->
    s
      { sessionPolicy =
          (sessionPolicy s)
            { workingDirectory = Just cwd,
              protectedPaths = protectedPaths (sessionPolicy s) ++ [path | Just path <- [home, temporary], isAbsolute path]
            }
      }
  where
    variable name = either (const Nothing) id <$> effectUnobserved (GetEnvironment name)

-- | Remove a path this run created, with write granted on its parent, and
-- the path itself no write root, for this removal only: the guard allows a
-- removal only strictly inside a write root, never of one. A parent the
-- guard protects (a temporary root, the home directory) makes the removal
-- fail as denied instead.
removeCreated :: (Monad m) => Recursive -> FilePath -> Command m (Either HostError ())
removeCreated recursive path = do
  saved <- sessionPolicy <$> getSession
  modifySession (\s -> s {sessionPolicy = saved {writeRoots = takeDirectory path : filter ((/= normalise path) . normalise) (writeRoots saved)}})
  result <- effectOr (Remove recursive path)
  modifySession (\s -> s {sessionPolicy = saved})
  pure result

-- | Let the command listen for HTTP on the loopback interface (serve).
grantListening :: (Monad m) => Command m ()
grantListening = modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {listening = True}})

grantPrograms :: (Monad m) => [FilePath] -> Command m ()
grantPrograms paths = modifySession (\s -> s {sessionPolicy = (sessionPolicy s) {programs = programs (sessionPolicy s) ++ paths}})

-- | Perform an effect under the session's policy, turning a host error into
-- a failure.
effect :: (Monad m) => (HostError -> Failure) -> Effect a -> Command m a
effect describe request = effectOr request >>= either (abort . describe) pure

-- | Perform an effect and keep a host error as a value.
effectOr :: (Monad m) => Effect a -> Command m (Either HostError a)
effectOr request = do
  host <- sessionHost
  mutated <- lift (gets sessionMutated)
  if not mutated && mutating request then modifySession (\s -> s {sessionMutated = True}) else pure ()
  lift (lift (perform host request))
  where
    mutating = \case
      WriteFile {} -> True
      Remove {} -> True
      Rename {} -> True
      MakeDirectories {} -> True
      WriteOutput {} -> True
      Spawn {} -> True
      _ -> False

-- | Perform an effect that changes nothing outside the core although its
-- kind could, such as running @env@ to read the environment: it leaves the
-- session unmutated, so the command may still stop as not ported.
effectUnobserved :: (Monad m) => Effect a -> Command m (Either HostError a)
effectUnobserved request = do
  host <- sessionHost
  lift (lift (perform host request))

-- | Node's fs error text, "<CODE>: <description>, <syscall> '<path>'", for the
-- kinds a Node host reports with an errno.
nodeFailure :: String -> FilePath -> HostError -> Failure
nodeFailure syscall path (HostError kind message) = Failure text Nothing
  where
    text = case kind of
      NotFound -> errno "ENOENT: no such file or directory"
      PermissionDenied -> errno "EACCES: permission denied"
      NotADirectory -> errno "ENOTDIR: not a directory"
      IsADirectory -> errno "EISDIR: illegal operation on a directory"
      AlreadyExists -> errno "EEXIST: file already exists"
      DirectoryNotEmpty -> errno "ENOTEMPTY: directory not empty"
      _ -> message
    errno description = description ++ ", " ++ syscall ++ " '" ++ path ++ "'"

-- | console.log: the text and a newline, on standard output.
printLine :: (Monad m) => String -> Command m ()
printLine text = write Stdout (text ++ "\n")

-- | console.error.
printError :: (Monad m) => String -> Command m ()
printError text = write Stderr (text ++ "\n")

-- | console.log(JSON.stringify(value, null, 2)).
printJson :: (Monad m) => Json -> Command m ()
printJson = printLine . stringify

-- | A closed or broken standard stream does not change a command's result,
-- as console.log does not throw in Node.
write :: (Monad m) => Stream -> String -> Command m ()
write stream text = writeOutput stream (utf8 text)

-- | Bytes on one of the host's standard streams, or into the capture of the
-- nested invocation that is running.
writeOutput :: (Monad m) => Stream -> B.ByteString -> Command m ()
writeOutput stream bytes = do
  capture <- sessionCapture <$> getSession
  case capture of
    Just written -> modifySession (\s -> s {sessionCapture = Just ((stream, bytes) : written)})
    Nothing -> () <$ effectOr (WriteOutput stream bytes)

-- | UTF-8, with unpaired surrogates replaced as JavaScript's encoder does.
utf8 :: String -> B.ByteString
utf8 = TE.encodeUtf8 . T.pack

-- | Node's readFile(file, 'utf8'): invalid sequences become U+FFFD.
fromUtf8 :: B.ByteString -> String
fromUtf8 = T.unpack . TE.decodeUtf8With TE.lenientDecode
