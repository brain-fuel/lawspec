{-# LANGUAGE GADTs #-}

-- | A pure, in-memory host for Hspec: a file tree with each entry's
-- permission bits, an environment, a clock,
-- standard streams (and which of them are terminals), scripted programs,
-- HTTPS responses and HTTP requests.
-- It follows the same contract as the IO hosts, so a command tested here
-- behaves the same over them; the host conformance suite runs against it
-- too. Every performed effect is recorded in 'worldTrace'.
-- ref:DEC-host-effect-abi
module LawSpec.Host.Fake
  ( World (..),
    Node (..),
    Program,
    emptyWorld,
    withFile,
    withDirectory,
    withPermissions,
    permissionsOf,
    fakeHost,
    runFake,
  )
where

import Control.Monad.State.Strict (State, modify', runState, state)
import Data.Bits (complement, (.&.))
import qualified Data.ByteString as B
import Data.Functor.Identity (Identity (..))
import qualified Data.Map.Strict as M
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, normalise, resolve, takeDirectory, within)
import LawSpec.Host.Policy (Policy (..), closed)
import LawSpec.Host.Sandbox (Resolution (..), enforced)

data Node = FileNode B.ByteString | DirectoryNode | LinkNode FilePath
  deriving (Eq, Show)

-- | A scripted program, chosen by argv[0]: the whole request to its exit
-- code, stdout and stderr, delivered as one chunk per stream; or 'Nothing'
-- for a process that runs until it is killed.
type Program = SpawnRequest -> Maybe (Int, B.ByteString, B.ByteString)

data World = World
  { worldFiles :: M.Map FilePath Node,
    worldEnvironment :: [(String, String)],
    worldClock :: Clock,
    worldStdout :: B.ByteString,
    worldStderr :: B.ByteString,
    worldStdin :: B.ByteString,
    worldPrograms :: [(String, Program)],
    worldProcesses :: M.Map Int [Event],
    -- | Processes still running, which 'Kill' ends with SIGTERM.
    worldRunning :: [Int],
    worldNextHandle :: Int,
    worldResponses :: [(String, FetchResponse)],
    worldRequests :: [IncomingRequest],
    worldAnswers :: [(RequestId, Response)],
    worldListeners :: Int,
    -- | The ports listened on; serving one of them again fails as a host
    -- reports a port in use ('AlreadyExists').
    worldPorts :: [Int],
    -- | Whether the listeners close once 'worldRequests' runs out: accept
    -- then fails, as it does on a listener the host has closed, instead of
    -- timing out. A server loop under test ends there.
    worldHangUp :: Bool,
    worldTrace :: [SomeEffect],
    -- | The standard streams that are terminals, with their widths; the
    -- others are not terminals.
    worldTerminals :: [(StandardStream, Maybe Int)],
    -- | Permission bits by path. A file or directory without an entry has
    -- the default a host creates it with: 0666 or 0777 less 'worldMask'.
    worldPermissions :: M.Map FilePath Permissions,
    -- | The file-creation mask (umask) applied to every file and directory
    -- the host creates.
    worldMask :: Permissions
  }

-- | An empty file system with only the root directory; the clock starts at
-- 2026-01-01 and advances one millisecond per reading. No stream is a
-- terminal, and the file-creation mask is 022.
emptyWorld :: World
emptyWorld = World (M.singleton "/" DirectoryNode) [] (Clock 1767225600000 0) B.empty B.empty B.empty [] M.empty [] 1 [] [] [] 0 [] False [] [] M.empty 0o022

-- | Add a file, creating its parent directories.
withFile :: FilePath -> B.ByteString -> World -> World
withFile path bytes world =
  world {worldFiles = M.insert (normalise path) (FileNode bytes) (parents (normalise path) (worldFiles world))}

withDirectory :: FilePath -> World -> World
withDirectory path world =
  world {worldFiles = M.insert (normalise path) DirectoryNode (parents (normalise path) (worldFiles world))}

-- | Set a file's or directory's permission bits, as chmod does.
withPermissions :: FilePath -> Permissions -> World -> World
withPermissions path bits world =
  world {worldPermissions = M.insert (normalise path) (bits .&. permissionMask) (worldPermissions world)}

-- | A file's or directory's permission bits, or 'Nothing' when nothing is
-- there.
permissionsOf :: World -> FilePath -> Maybe Permissions
permissionsOf world path = case M.lookup (normalise path) (worldFiles world) of
  Nothing -> Nothing
  Just node -> Just (M.findWithDefault (defaultPermissions world node) (normalise path) (worldPermissions world))

-- | What a host creates a file (0666), a directory (0777) or a symbolic link
-- (0777) with, less the file-creation mask.
defaultPermissions :: World -> Node -> Permissions
defaultPermissions world node = base .&. complement (worldMask world)
  where
    base = case node of
      FileNode _ -> 0o666
      _ -> 0o777

parents :: FilePath -> M.Map FilePath Node -> M.Map FilePath Node
parents path files
  | path == "/" = files
  | otherwise = let parent = takeDirectory path in parents parent (M.insertWith (\_ old -> old) parent DirectoryNode files)

runFake :: State World a -> World -> (a, World)
runFake = runState

-- | The in-memory host. Like every host it enforces the policy it is
-- confined to ('closed' until then), symbolic links included, before it
-- performs a request; every request that reaches it is traced. Its own
-- home and temporary directories, which the guard protects as well as the
-- policy's, are the world's HOME and TMPDIR.
fakeHost :: Host (State World)
fakeHost = confinedFake closed

confinedFake :: Policy -> Host (State World)
confinedFake policy = Host enforce confinedFake
  where
    enforce :: Effect a -> State World (Either HostError a)
    enforce effect = do
      modify' (\world -> world {worldTrace = worldTrace world ++ [SomeEffect effect]})
      state $ \world -> case runIdentity (enforced (\how path -> Identity (resolved world how path)) (own world) effect) of
        Just problem -> (Left (HostError Denied problem), world)
        Nothing -> fakePerform effect world
    own world =
      policy {protectedPaths = protectedPaths policy ++ [path | name <- ["HOME", "TMPDIR"], Just path@('/' : _) <- [lookup name (worldEnvironment world)]]}

-- | A path with its symbolic links followed ('Whole') or only its directory's
-- ('Parent'), as a real host's realpath does.
resolved :: World -> Resolution -> FilePath -> FilePath
resolved world how path = case how of
  Parent | path /= "/" -> join (go (16 :: Int) (takeDirectory path)) (lastComponent path)
  _ -> go 16 path
  where
    lastComponent = reverse . takeWhile (/= '/') . reverse
    go 0 current = current
    go budget current
      | current == "/" = current
      | otherwise =
          let parent = go budget (takeDirectory current)
              here = join parent (lastComponent current)
           in case M.lookup here (worldFiles world) of
                Just (LinkNode destination) -> go (budget - 1) (resolve (takeDirectory here) destination)
                _ -> here

failWith :: ErrorKind -> String -> World -> (Either HostError a, World)
failWith kind message world = (Left (HostError kind message), world)

fakePerform :: Effect a -> World -> (Either HostError a, World)
fakePerform effect world = case effect of
  ReadFile path -> absolute path $ \target -> case followed target of
    Just (FileNode bytes) -> (Right bytes, world)
    Just DirectoryNode -> failWith IsADirectory target world
    _ -> failWith NotFound target world
  WriteFile mode bits path bytes -> absolute path $ \target -> case (mode, M.lookup target files) of
    (_, Just DirectoryNode) -> failWith IsADirectory target world
    (Create, Just _) -> failWith AlreadyExists target world
    _ | Just problem <- blockedParent target -> failWith NotADirectory problem world
    _ -> (Right (), created bits [target] (withFile target bytes world))
  ListDirectory path -> absolute path $ \target -> case followed target of
    Just DirectoryNode ->
      ( Right
          [ Entry (drop (length prefix) child) (kindOf node)
          | (child, node) <- M.toList files,
            child /= target,
            takeDirectory child == target,
            let prefix = if target == "/" then "/" else target ++ "/"
          ],
        world
      )
    Just _ -> failWith NotADirectory target world
    Nothing -> failWith NotFound target world
  Stat follow path -> absolute path $ \target ->
    case (if follow == Follow then followed target else M.lookup target files) of
      Just node ->
        let shown = if follow == Follow then resolved world Whole target else target
         in (Right (Status (kindOf node) (size node) (wallMilliseconds (worldClock world)) (permissionsOf world shown)), world)
      Nothing -> failWith NotFound target world
  RealPath path -> absolute path $ \target ->
    let real = resolved world Whole target
     in case M.lookup real files of
          Just (LinkNode _) -> failWith Failed ("too many levels of symbolic links: " ++ target) world
          Just _ -> (Right real, world)
          Nothing
            | Just problem <- blockedParent real -> failWith NotADirectory problem world
            | otherwise -> failWith NotFound target world
  Remove recursive path -> absolute path $ \target -> case M.lookup target files of
    Nothing -> failWith NotFound target world
    Just DirectoryNode
      | recursive == NotRecursive && any (\child -> child /= target && within target child) (M.keys files) ->
          failWith DirectoryNotEmpty target world
    Just _ ->
      ( Right (),
        world
          { worldFiles = M.filterWithKey (\child _ -> not (within target child)) files,
            worldPermissions = M.filterWithKey (\child _ -> not (within target child)) (worldPermissions world)
          }
      )
  Rename from to
    | not (isAbsolute from) -> failWith Invalid ("path is not absolute: " ++ from) world
    | not (isAbsolute to) -> failWith Invalid ("path is not absolute: " ++ to) world
    | otherwise -> renamed (normalise from) (normalise to)
  MakeDirectories bits path -> absolute path $ \target -> case M.lookup target files of
    Just DirectoryNode -> (Right (), world)
    Just _ -> failWith AlreadyExists target world
    Nothing
      | Just problem <- blockedParent target -> failWith NotADirectory problem world
      | otherwise ->
          let made = [directory | directory <- target : ancestors target, M.notMember directory files]
           in (Right (), created bits made (withDirectory target world))
  Spawn request -> case spawnArguments request of
    program : _
      | Just run <- lookup program (worldPrograms world) ->
          let handle = worldNextHandle world
              (events, running) = case run request of
                Just (code, out, err) ->
                  ( [Chunk (ProcessHandle handle) Stdout out | not (B.null out)]
                      ++ [Chunk (ProcessHandle handle) Stderr err | not (B.null err)]
                      ++ [Exited (ProcessHandle handle) (ExitCode code)],
                    []
                  )
                Nothing -> ([], [handle])
           in ( Right (ProcessHandle handle),
                world
                  { worldProcesses = M.insert handle events (worldProcesses world),
                    worldRunning = running ++ worldRunning world,
                    worldNextHandle = handle + 1
                  }
              )
    program : _ -> failWith NotFound program world
    [] -> failWith Invalid "spawn needs a program" world
  Poll handles _
    | Just (ProcessHandle unknown) <- firstUnknown handles -> failWith Invalid ("unknown process handle " ++ show unknown) world
    | otherwise ->
        let wanted = [handle | ProcessHandle handle <- handles]
            events = concat [M.findWithDefault [] handle (worldProcesses world) | handle <- wanted]
         in (Right events, world {worldProcesses = foldr (M.adjust (const [])) (worldProcesses world) wanted})
  Kill (ProcessHandle handle)
    | handle `elem` worldRunning world ->
        ( Right (),
          world
            { worldRunning = filter (/= handle) (worldRunning world),
              worldProcesses = M.adjust (++ [Exited (ProcessHandle handle) (Signalled "SIGTERM")]) handle (worldProcesses world)
            }
        )
    | M.member handle (worldProcesses world) -> (Right (), world)
    | otherwise -> failWith Invalid ("unknown process handle " ++ show handle) world
  Fetch request
    | take 8 (fetchUrl request) /= "https://" -> failWith Denied ("only https URLs may be fetched: " ++ fetchUrl request) world
  Fetch request -> case lookup (fetchUrl request) (worldResponses world) of
    Just response -> (Right response, world)
    Nothing -> failWith Failed ("no scripted response for " ++ fetchUrl request) world
  GetEnvironment name -> (Right (lookup name (worldEnvironment world)), world)
  GetClock ->
    let Clock wall monotonic = worldClock world
     in (Right (worldClock world), world {worldClock = Clock (wall + 1) (monotonic + 1000)})
  WriteOutput Stdout bytes -> (Right (), world {worldStdout = worldStdout world <> bytes})
  WriteOutput Stderr bytes -> (Right (), world {worldStderr = worldStderr world <> bytes})
  -- At least one byte while any is left, as a host that waits for input
  -- answers; the end of input is an empty read.
  ReadInput limit ->
    let (taken, rest) = B.splitAt (max 1 limit) (worldStdin world)
     in (Right (Input taken (B.null taken)), world {worldStdin = rest})
  QueryTerminal stream -> case lookup stream (worldTerminals world) of
    Just columns -> (Right (Terminal True (if stream == StandardInput then Nothing else columns)), world)
    Nothing -> (Right (Terminal False Nothing), world)
  Serve port
    | port `elem` worldPorts world -> failWith AlreadyExists ("listen EADDRINUSE: address already in use 127.0.0.1:" ++ show port) world
    | otherwise ->
        let listener = worldListeners world + 1
            actual = if port == 0 then 40000 + listener else port
         in (Right (Listening (Listener listener) actual), world {worldListeners = listener, worldPorts = actual : worldPorts world})
  Accept (Listener listener) _
    | listener < 1 || listener > worldListeners world -> failWith Invalid ("unknown listener " ++ show listener) world
    | otherwise -> case worldRequests world of
        next : rest -> (Right (Just next), world {worldRequests = rest})
        [] | worldHangUp world -> failWith Failed "the listener closed" world
        [] -> (Right Nothing, world)
  Respond request response -> (Right (), world {worldAnswers = worldAnswers world ++ [(request, response)]})
  where
    files = worldFiles world
    -- The paths a write or mkdirs created get the requested bits less the
    -- mask, or lose any recorded bits for the default.
    created :: Maybe Permissions -> [FilePath] -> World -> World
    created bits paths after =
      after
        { worldPermissions = case bits of
            Just given -> foldr (\path -> M.insert path (given .&. permissionMask .&. complement (worldMask world))) (worldPermissions after) paths
            Nothing -> foldr M.delete (worldPermissions after) paths
        }
    -- rename(2): the entry and everything below it move to the new name,
    -- replacing a file or an empty directory there.
    renamed :: FilePath -> FilePath -> (Either HostError (), World)
    renamed from to = case (M.lookup from files, M.lookup to files) of
      (Nothing, _) -> failWith NotFound from world
      _ | from == to -> (Right (), world)
      _ | Just problem <- blockedParent to -> failWith NotADirectory problem world
      _ | M.notMember (takeDirectory to) files -> failWith NotFound to world
      _ | from == "/" || within from to -> failWith Failed ("cannot move a directory into itself: " ++ to) world
      (Just DirectoryNode, Just DirectoryNode)
        | any (\child -> child /= to && within to child) (M.keys files) -> failWith DirectoryNotEmpty to world
      (Just DirectoryNode, Just node) | node /= DirectoryNode -> failWith NotADirectory to world
      (Just node, Just DirectoryNode) | node /= DirectoryNode -> failWith IsADirectory to world
      _ ->
        let moved path = if within from path then to ++ drop (length from) path else path
            move :: M.Map FilePath v -> M.Map FilePath v
            move = M.fromList . map (\(path, value) -> (moved path, value)) . M.toList
            keep :: M.Map FilePath v -> M.Map FilePath v
            keep = M.filterWithKey (\path _ -> path /= to)
         in (Right (), world {worldFiles = move (keep files), worldPermissions = move (keep (worldPermissions world))})
    absolute :: FilePath -> (FilePath -> (Either HostError b, World)) -> (Either HostError b, World)
    absolute path continue
      | isAbsolute path = continue (normalise path)
      | otherwise = failWith Invalid ("path is not absolute: " ++ path) world
    followed target = go (16 :: Int) target
      where
        go 0 _ = Nothing
        go budget path = case M.lookup path files of
          Just (LinkNode destination) -> go (budget - 1) (resolve (takeDirectory path) destination)
          other -> other
    kindOf (FileNode _) = FileKind
    kindOf DirectoryNode = DirectoryKind
    kindOf (LinkNode _) = SymbolicLinkKind
    size (FileNode bytes) = fromIntegral (B.length bytes)
    size _ = 0
    blockedParent target =
      case [parent | parent <- ancestors target, Just node <- [M.lookup parent files], node /= DirectoryNode] of
        parent : _ -> Just parent
        [] -> Nothing
    ancestors path
      | path == "/" = []
      | otherwise = let parent = takeDirectory path in parent : ancestors parent
    firstUnknown handles = case [handle | handle@(ProcessHandle number) <- handles, not (M.member number (worldProcesses world))] of
      unknown : _ -> Just unknown
      [] -> Nothing
