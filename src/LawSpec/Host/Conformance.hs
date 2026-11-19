{-# LANGUAGE GADTs #-}

-- | The host conformance suite: a fixed script of effect requests and the
-- results the ABI requires, run against a host from inside the core. Every
-- host (Node, Go, the native interpreter, the in-memory fake) runs the same
-- script, so a host is conformant exactly when this passes over it. Effects a
-- host does not provide are reported as unsupported, not as passes.
-- The suite runs with the host confined to 'conformancePolicy'; its
-- confinement checks then go to the host directly, without the core's own
-- policy check, to show that the host refuses out-of-policy requests itself.
-- docs/reference/host-effects.md describes the contract checked here.
-- ref:DEC-host-effect-abi
module LawSpec.Host.Conformance
  ( Verdict (..),
    Check (..),
    conformance,
    renderVerdicts,
    conformant,
    shellScripts,
    conformancePolicy,
    roundTripRequest,
    escapeRequest,
  )
where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isSuffixOf, sort)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join)
import LawSpec.Host.Policy (Policy)
import qualified LawSpec.Host.Policy as Policy

data Verdict = Pass | Fail String | NotProvided String deriving (Eq, Show)

data Check = Check {checkName :: String, checkVerdict :: Verdict} deriving (Eq, Show)

conformant :: [Check] -> Bool
conformant = all (\check -> case checkVerdict check of Fail _ -> False; _ -> True)

renderVerdicts :: [Check] -> String
renderVerdicts checks =
  unlines (map line checks)
    ++ show (length [() | Check _ Pass <- checks])
    ++ " passed, "
    ++ show (length [() | Check _ (Fail _) <- checks])
    ++ " failed, "
    ++ show (length [() | Check _ (NotProvided _) <- checks])
    ++ " unsupported\n"
  where
    line (Check name Pass) = "ok " ++ name
    line (Check name (Fail problem)) = "FAIL " ++ name ++ ": " ++ problem
    line (Check name (NotProvided problem)) = "unsupported " ++ name ++ ": " ++ problem

-- | The shell programs the process checks run, by name. The fake host
-- scripts these exactly; real hosts run them with /bin/sh.
shellScripts :: [(String, String)]
shellScripts =
  [ ("streams", "printf out; printf err >&2; exit 3"),
    ("input", "cat; printf \"$CONFORMANCE_VALUE\""),
    ("directory", "pwd"),
    ("sleep", "exec sleep 30"),
    ("links", "ln -s ../secret.txt read/escape && ln -s ../read write/link"),
    ("path links", "ln -s dir paths/link && ln -s link paths/chain && ln -s missing paths/dangling"),
    ("guard links", "ln -s ../work plain/up")
  ]

script :: String -> String
script name = maybe (error ("unknown conformance script " ++ name)) id (lookup name shellScripts)

-- | Run every check in a fresh, empty, absolute scratch directory.
conformance :: (Monad m) => Host m -> FilePath -> m [Check]
conformance host scratch = do
  granted <- concat <$> mapM (\check -> check (confined host (conformancePolicy scratch)) scratch) checks
  refused <- confinement host scratch
  guarded <- guardrails host scratch
  pure (granted ++ refused ++ guarded)
  where
    checks = [files, errors, renames, permissions, paths, terminals, environment, clock, processes, network]

-- | The policy the suite runs under: the scratch directory, the programs it
-- runs, the network and listening.
conformancePolicy :: FilePath -> Policy
conformancePolicy scratch =
  Policy.closed
    { Policy.readRoots = [],
      Policy.writeRoots = [scratch],
      Policy.programs = ["/bin/sh", curl, missingProgram],
      Policy.network = True,
      Policy.listening = True
    }

curl :: FilePath
curl = "/usr/bin/curl"

missingProgram :: FilePath
missingProgram = "/nonexistent/lawspec-conformance"

type Suite m = Host m -> FilePath -> m [Check]

expect :: (Monad m) => Host m -> String -> Effect a -> (Either HostError a -> Maybe String) -> m Check
expect host name request judge = do
  result <- perform host request
  pure (Check name (maybe Pass Fail (judge result)))

ok :: (Show a) => (a -> Bool) -> Either HostError a -> Maybe String
ok accept = \case
  Right value | accept value -> Nothing
  Right value -> Just ("unexpected result " ++ show value)
  Left problem -> Just ("unexpected error " ++ show problem)

done :: Either HostError () -> Maybe String
done = ok (const True)

failsWith :: (Show a) => ErrorKind -> Either HostError a -> Maybe String
failsWith kind = \case
  Left (HostError actual _) | actual == kind -> Nothing
  Left problem -> Just ("expected " ++ errorKindName kind ++ ", got " ++ show problem)
  Right value -> Just ("expected " ++ errorKindName kind ++ ", got " ++ show value)

-- | Arbitrary bytes, including invalid UTF-8, survive a round trip.
payload :: B.ByteString
payload = B.pack ([0, 255, 254, 10, 13] ++ [0 .. 255]) <> BC.pack "\nend"

files :: (Monad m) => Suite m
files host scratch =
  sequence
    [ expect host "mkdirs creates missing parents" (MakeDirectories Nothing (scratch `join` "a/b")) done,
      expect host "mkdirs accepts an existing directory" (MakeDirectories Nothing (scratch `join` "a")) done,
      expect host "stat reports a directory" (Stat Follow (scratch `join` "a/b")) (ok ((== DirectoryKind) . statusKind)),
      expect host "write replaces a file" (WriteFile Replace Nothing file payload) done,
      expect host "read returns the written bytes" (ReadFile file) (ok (== payload)),
      expect host "stat reports a file's size" (Stat NoFollow file) (ok (\status -> statusKind status == FileKind && statusSize status == fromIntegral (B.length payload))),
      expect host "create refuses an existing file" (WriteFile Create Nothing file (BC.pack "other")) (failsWith AlreadyExists),
      expect host "a refused create leaves the file" (ReadFile file) (ok (== payload)),
      expect host "replace overwrites" (WriteFile Replace Nothing file (BC.pack "second")) done,
      expect host "read sees the replacement" (ReadFile file) (ok (== BC.pack "second")),
      expect host "create writes a new file" (WriteFile Create Nothing (scratch `join` "a/b/new.txt") B.empty) done,
      expect host "an empty file reads empty" (ReadFile (scratch `join` "a/b/new.txt")) (ok B.null),
      expect host "write creates missing parents" (WriteFile Replace Nothing (scratch `join` "c/d/e.txt") (BC.pack "e")) done,
      expect host "list leaves no temporary files" (ListDirectory (scratch `join` "a/b")) (ok (\entries -> sort [(entryName e, entryKind e) | e <- entries] == [("f.bin", FileKind), ("new.txt", FileKind)])),
      expect host "list reports directories" (ListDirectory scratch) (ok (\entries -> sort [(entryName e, entryKind e) | e <- entries, entryName e `elem` ["a", "c"]] == [("a", DirectoryKind), ("c", DirectoryKind)])),
      expect host "mkdirs refuses a file" (MakeDirectories Nothing file) (failsWith AlreadyExists),
      expect host "remove refuses a non-empty directory" (Remove NotRecursive (scratch `join` "c")) (failsWith DirectoryNotEmpty),
      expect host "remove deletes a file" (Remove NotRecursive (scratch `join` "c/d/e.txt")) done,
      expect host "remove deletes an empty directory" (Remove NotRecursive (scratch `join` "c/d")) done,
      expect host "remove deletes a tree" (Remove Recursive (scratch `join` "a")) done,
      expect host "a removed tree is gone" (Stat NoFollow (scratch `join` "a/b/f.bin")) (failsWith NotFound)
    ]
  where
    file = scratch `join` "a/b/f.bin"

errors :: (Monad m) => Suite m
errors host scratch =
  sequence
    [ expect host "write a file to inspect" (WriteFile Replace Nothing file (BC.pack "x")) done,
      expect host "read of a missing file" (ReadFile missing) (failsWith NotFound),
      expect host "stat of a missing file" (Stat Follow missing) (failsWith NotFound),
      expect host "list of a missing directory" (ListDirectory missing) (failsWith NotFound),
      expect host "remove of a missing file" (Remove NotRecursive missing) (failsWith NotFound),
      expect host "list of a file" (ListDirectory file) (failsWith NotADirectory),
      expect host "read of a directory" (ReadFile scratch) (failsWith IsADirectory),
      expect host "a relative path is invalid" (ReadFile "relative.txt") (failsWith Invalid),
      expect host "an unknown process handle is invalid" (Poll [ProcessHandle 999999] 0) (failsWith Invalid),
      expect host "an unknown listener is invalid" (Accept (Listener 999999) 0) invalidOrUnsupported
    ]
  where
    missing = scratch `join` "missing"
    file = scratch `join` "file.txt"
    invalidOrUnsupported result = case result of
      Left (HostError Unsupported _) -> Nothing
      _ -> failsWith Invalid result

-- | rename(2) inside the scratch directory: a file over an existing file,
-- a directory with its contents, and a missing source.
renames :: (Monad m) => Suite m
renames host scratch = do
  prepared <-
    sequence
      [ perform host (WriteFile Replace Nothing (directory `join` "a.txt") (BC.pack "a")),
        perform host (WriteFile Replace Nothing (directory `join` "b.txt") (BC.pack "b")),
        perform host (WriteFile Replace Nothing (directory `join` "d/inner.txt") (BC.pack "inner"))
      ]
  case sequence prepared of
    Left problem -> pure [Check "rename setup" (Fail (show problem))]
    Right _ ->
      sequence
        [ expect host "rename replaces an existing file" (Rename (directory `join` "a.txt") (directory `join` "b.txt")) done,
          expect host "a renamed file has its bytes at the new name" (ReadFile (directory `join` "b.txt")) (ok (== BC.pack "a")),
          expect host "a renamed file is gone from the old name" (Stat NoFollow (directory `join` "a.txt")) (failsWith NotFound),
          expect host "rename moves a directory" (Rename (directory `join` "d") (directory `join` "e")) done,
          expect host "a renamed directory keeps its contents" (ReadFile (directory `join` "e/inner.txt")) (ok (== BC.pack "inner")),
          expect host "a renamed directory is gone from the old name" (Stat NoFollow (directory `join` "d")) (failsWith NotFound),
          expect host "rename of a missing path" (Rename (directory `join` "missing") (directory `join` "c.txt")) (failsWith NotFound)
        ]
  where
    directory = scratch `join` "rename"

-- | Permission bits through write, mkdirs and stat. A file-creation mask
-- leaves the owner's bits alone, so 0700 and 0600 come back as written;
-- a host that cannot set or report them is unsupported, not passed.
permissions :: (Monad m) => Suite m
permissions host scratch = do
  executable <- perform host (WriteFile Replace (Just 0o700) (directory `join` "run.sh") (BC.pack "#!/bin/sh\n"))
  private <- perform host (WriteFile Replace (Just 0o600) (directory `join` "private.txt") B.empty)
  made <- perform host (MakeDirectories (Just 0o700) (directory `join` "private"))
  case sequence [executable, private, made] of
    Left (HostError Unsupported message) -> pure [Check "permissions round trip through write, mkdirs and stat" (NotProvided message)]
    Left problem -> pure [Check "permissions setup" (Fail (show problem))]
    Right _ ->
      sequence
        [ bits "write gives a file the requested permission bits" "run.sh" 0o700,
          bits "write replaces a file's permission bits" "private.txt" 0o600,
          bits "mkdirs gives a directory the requested permission bits" "private" 0o700
        ]
  where
    directory = scratch `join` "permissions"
    bits name file expected = do
      result <- perform host (Stat NoFollow (directory `join` file))
      pure . Check name $ case result of
        Right status -> case statusPermissions status of
          Just actual | actual == expected -> Pass
          Just actual -> Fail ("expected " ++ octal expected ++ ", got " ++ octal actual)
          Nothing -> NotProvided "stat reports no permission bits"
        Left problem -> Fail ("unexpected error " ++ show problem)
    octal :: Permissions -> String
    octal value = "0o" ++ reverse (go value)
      where
        go 0 = "0"
        go n = if n < 8 then [digit n] else digit (n `mod` 8) : go (n `div` 8)
        digit n = toEnum (fromEnum '0' + n)

-- | realpath over links the suite makes, relative to the scratch
-- directory's own real path (which may lie outside the policy's lexical
-- root, as /var does on macOS): a link, a chain of links, a
-- dangling link, a path through a file, and a name in another case, which a
-- case-insensitive file system resolves to the stored name and a
-- case-sensitive one does not find.
paths :: (Monad m) => Suite m
paths host scratch = do
  prepared <-
    sequence
      [ perform host (MakeDirectories Nothing (directory `join` "dir")),
        perform host (WriteFile Replace Nothing (directory `join` "dir/f.txt") (BC.pack "f"))
      ]
  linked <- do
    started <- perform host (Spawn (SpawnRequest ["/bin/sh", "-c", script "path links"] scratch Nothing Nothing))
    either (pure . Left . show) (finish host) started
  canonicalScratch <- perform host (RealPath scratch)
  case (sequence prepared, linked, canonicalScratch) of
    (Left problem, _, _) -> pure [Check "realpath setup" (Fail (show problem))]
    (_, Left problem, _) -> pure [Check "realpath setup" (Fail problem)]
    (_, Right (_, _, status), _) | status /= ExitCode 0 -> pure [Check "realpath setup" (Fail ("ln exited with " ++ show status))]
    (_, _, Left problem) -> pure [Check "realpath resolves the scratch directory" (Fail ("unexpected error " ++ show problem))]
    (_, _, Right base) -> do
      let real = join (base `join` "paths")
      sequence
        [ expect host "realpath resolves a directory below the scratch directory" (RealPath (directory `join` "dir")) (ok (== real "dir")),
          expect host "realpath resolves a symbolic link" (RealPath (directory `join` "link/f.txt")) (ok (== real "dir/f.txt")),
          expect host "realpath resolves a chain of links" (RealPath (directory `join` "chain")) (ok (== real "dir")),
          expect host "realpath of a missing path" (RealPath (directory `join` "missing")) (failsWith NotFound),
          expect host "realpath through a dangling link" (RealPath (directory `join` "dangling")) (failsWith NotFound),
          expect host "realpath through a file" (RealPath (directory `join` "dir/f.txt/x")) (failsWith NotADirectory),
          expect host "realpath reports a name in its stored case" (RealPath (directory `join` "DIR/F.TXT")) $ \case
            Left (HostError NotFound _) -> Nothing
            other -> ok (== real "dir/f.txt") other
        ]
  where
    directory = scratch `join` "paths"

-- | The suite runs with standard input redirected (tools/hosts.sh gives it
-- /dev/null), so that stream is not a terminal; standard output and error
-- may be either, but a stream that is not a terminal has no width.
terminals :: (Monad m) => Suite m
terminals host _ =
  sequence
    [ expect host "terminal reports standard input is not a terminal" (QueryTerminal StandardInput) $ \case
        Right (Terminal True _) -> Just "standard input is a terminal; run the suite with it redirected, as tools/hosts.sh does"
        result -> ok (== Terminal False Nothing) result,
      expect host "terminal answers for standard output" (QueryTerminal StandardOutput) (ok consistent),
      expect host "terminal answers for standard error" (QueryTerminal StandardError) (ok consistent)
    ]
  where
    consistent (Terminal attached columns) = maybe True (\width -> attached && width > 0) columns

environment :: (Monad m) => Suite m
environment host _ =
  sequence
    [ expect host "env reads PATH" (GetEnvironment "PATH") (ok (maybe False (not . null))),
      expect host "env reports an unset variable" (GetEnvironment "LAWSPEC_CONFORMANCE_UNSET_VARIABLE") (ok (== Nothing)),
      expect host "output writes to standard error" (WriteOutput Stderr (BC.pack "host conformance: standard error\n")) done
    ]

clock :: (Monad m) => Suite m
clock host _ = do
  first <- perform host GetClock
  second <- perform host GetClock
  pure
    [ Check "clock reads the wall time" $ case first of
        Right (Clock wall _) | wall > 1577836800000 -> Pass
        other -> Fail ("unexpected " ++ show other),
      Check "the monotonic clock never decreases" $ case (first, second) of
        (Right (Clock _ a), Right (Clock _ b)) | b >= a -> Pass
        other -> Fail ("unexpected " ++ show other)
    ]

-- | Collect a process's output and exit, polling for at most 30 seconds.
finish :: (Monad m) => Host m -> ProcessHandle -> m (Either String (B.ByteString, B.ByteString, ExitStatus))
finish host handle = go (60 :: Int) B.empty B.empty
  where
    go 0 _ _ = pure (Left "no exit within 30 seconds")
    go budget out err = do
      result <- perform host (Poll [handle] 500)
      case result of
        Left problem -> pure (Left ("poll failed: " ++ show problem))
        Right events -> do
          let out' = out <> B.concat [bytes | Chunk h Stdout bytes <- events, h == handle]
              err' = err <> B.concat [bytes | Chunk h Stderr bytes <- events, h == handle]
          case [status | Exited h status <- events, h == handle] of
            status : _ -> pure (Right (out', err', status))
            [] -> go (budget - 1) out' err'

processes :: (Monad m) => Suite m
processes host scratch = do
  streams <- run "spawn collects both streams and the exit code" (shell "streams" Nothing Nothing) $ \(out, err, status) ->
    (out, err, status) == (BC.pack "out", BC.pack "err", ExitCode 3)
  input <-
    run
      "spawn passes standard input and a replaced environment"
      (shell "input" (Just [("CONFORMANCE_VALUE", "v1"), ("PATH", "/usr/bin:/bin")]) (Just (BC.pack "piped")))
      (\(out, _, status) -> (out, status) == (BC.pack "pipedv1", ExitCode 0))
  directory <-
    run "spawn runs in the given directory" ((shell "directory" Nothing Nothing) {spawnDirectory = scratch `join` "cwd"}) $ \(out, _, status) ->
      "/cwd\n" `isSuffixOf` BC.unpack out && status == ExitCode 0
  killed <- do
    started <- perform host (Spawn (shell "sleep" Nothing Nothing))
    case started of
      Left problem -> pure (Check "kill stops a process" (Fail ("spawn failed: " ++ show problem)))
      Right handle -> do
        stopped <- perform host (Kill handle)
        result <- finish host handle
        pure . Check "kill stops a process" $ case (stopped, result) of
          (Right (), Right (_, _, Signalled "SIGTERM")) -> Pass
          other -> Fail ("unexpected " ++ show other)
  missing <- expect host "spawn of a missing program" (Spawn (SpawnRequest [missingProgram] scratch Nothing Nothing)) (failsWith NotFound)
  pure [streams, input, directory, killed, missing]
  where
    shell name environment' input = SpawnRequest ["/bin/sh", "-c", script name] scratch environment' input
    run name request accept = do
      prepared <- perform host (MakeDirectories Nothing (scratch `join` "cwd"))
      started <- either (pure . Left) (const (perform host (Spawn request))) prepared
      case started of
        Left problem -> pure (Check name (Fail ("spawn failed: " ++ show problem)))
        Right handle -> do
          result <- finish host handle
          pure . Check name $ case result of
            Right outcome | accept outcome -> Pass
            Right outcome -> Fail ("unexpected " ++ show outcome)
            Left problem -> Fail problem

-- | Network effects need no network: a plain-HTTP fetch is refused, a
-- listener with no client times out, listening again on its port fails as
-- already-exists (EADDRINUSE, which lawspec learn reports as Node did), and
-- loopback requests from curl are accepted, with their targets as sent, and
-- answered. A host without them is unsupported.
network :: (Monad m) => Suite m
network host scratch = do
  fetched <- perform host (Fetch (FetchRequest "http://127.0.0.1:9/" "GET" [] Nothing))
  answered <- roundTrip host scratch
  escaped <- escapedTarget host scratch
  served <- perform host (Serve 0)
  accepted <- case served of
    Right (Listening listener _) -> Just <$> perform host (Accept listener 10)
    Left _ -> pure Nothing
  again <- case served of
    Right (Listening _ port) -> Just <$> perform host (Serve port)
    Left _ -> pure Nothing
  pure
    [ Check "fetch refuses plain HTTP" $ case fetched of
        Left (HostError Denied _) -> Pass
        Left (HostError Unsupported message) -> NotProvided message
        other -> Fail ("expected denied, got " ++ show other),
      Check "serve listens and accept times out" $ case (served, accepted) of
        (Right (Listening _ port), Just (Right Nothing)) | port > 0 -> Pass
        (Left (HostError Unsupported message), _) -> NotProvided message
        other -> Fail ("unexpected " ++ show other),
      Check "serve reports a port in use as already-exists" $ case (served, again) of
        (Right _, Just (Left (HostError AlreadyExists _))) -> Pass
        (Left (HostError Unsupported message), _) -> NotProvided message
        other -> Fail ("unexpected " ++ show other),
      answered,
      escaped
    ]

-- | The request curl sends in the round trip, as a host must report it:
-- the target as sent, header names in lower case, the body's bytes.
roundTripRequest :: Int -> IncomingRequest
roundTripRequest identifier =
  IncomingRequest (RequestId identifier) "POST" "/conformance?q=1" [("x-conformance", "yes")] (BC.pack "ping")

-- | The request of the second exchange: a target with a malformed percent
-- escape, which a host passes on as received (Node's parser does, and
-- lawspec learn answers it), with no body.
escapeRequest :: Int -> IncomingRequest
escapeRequest identifier =
  IncomingRequest (RequestId identifier) "GET" "/conformance%zz?q=%" [("x-conformance", "yes")] B.empty

roundTrip :: (Monad m) => Host m -> FilePath -> m Check
roundTrip host scratch =
  exchange host scratch "serve accepts a request and responds" (roundTripRequest 0) ["--data-binary", "ping"]

escapedTarget :: (Monad m) => Host m -> FilePath -> m Check
escapedTarget host scratch =
  exchange host scratch "serve passes a target with a malformed escape as received" (escapeRequest 0) []

-- | One request from curl to a fresh listener, which must arrive as
-- expected and be answered.
exchange :: (Monad m) => Host m -> FilePath -> String -> IncomingRequest -> [String] -> m Check
exchange host scratch name expected arguments = do
  served <- perform host (Serve 0)
  case served of
    Left (HostError Unsupported message) -> pure (Check name (NotProvided message))
    Left problem -> pure (Check name (Fail ("serve failed: " ++ show problem)))
    Right (Listening listener port) -> do
      started <- perform host (Spawn (client port))
      case started of
        Left (HostError NotFound _) -> pure (Check name (NotProvided ("the round trip needs " ++ curl)))
        Left problem -> pure (Check name (Fail ("spawn failed: " ++ show problem)))
        Right handle -> do
          accepted <- perform host (Accept listener 20000)
          case accepted of
            Right (Just request) | matches request -> do
              responded <- perform host (Respond (requestId request) (Response 200 [("content-type", "text/plain")] (BC.pack "pong")))
              result <- finish host handle
              pure . Check name $ case (responded, result) of
                (Right (), Right (out, _, ExitCode 0)) | out == BC.pack "pong" -> Pass
                other -> Fail ("unexpected " ++ show other)
            other -> do
              _ <- perform host (Kill handle)
              pure (Check name (Fail ("unexpected request " ++ show other)))
  where
    matches request =
      (requestMethod request, requestPath request, requestBody request) == (requestMethod expected, requestPath expected, requestBody expected)
        && all (`elem` requestHeaders request) (requestHeaders expected)
    client port =
      SpawnRequest
        ( [ curl,
            "--silent",
            "--show-error",
            "--noproxy",
            "*",
            "--header",
            "X-Conformance: yes"
          ]
            ++ arguments
            ++ ["http://127.0.0.1:" ++ show port ++ requestPath expected]
        )
        scratch
        Nothing
        Nothing

-- | The guard, enforced by the host itself, as 'confinement' is: each
-- refusal must come before the host touches the disk. Every request that
-- names a real protected path (the root, the home directory, the temporary
-- root) also lies outside the policy's roots, so a host without the guard
-- still refuses it; the requests that only the guard refuses touch the
-- scratch directory alone (a write over a directory, or mkdirs of an
-- existing one, when a host lacks the guard). Sentinel files must survive
-- them all, and a removal strictly inside a write root stays allowed.
guardrails :: (Monad m) => Suite m
guardrails host scratch = do
  home <- either (const Nothing) id <$> perform host (GetEnvironment "HOME")
  temporary <- either (const Nothing) id <$> perform host (GetEnvironment "TMPDIR")
  let broad = confined host (conformancePolicy scratch)
      guarded = confined host policy
      granting root = confined host policy {Policy.writeRoots = Policy.writeRoots policy ++ [root]}
      absolute = filter (\path -> take 1 path == "/")
      temporaryRoot = case absolute (maybe [] pure temporary) of
        root : _ -> root
        [] -> "/tmp"
  prepared <-
    sequence
      [ perform broad (MakeDirectories Nothing cwd),
        perform broad (MakeDirectories Nothing (plain `join` "inner")),
        perform broad (WriteFile Replace Nothing sentinel (BC.pack "keep")),
        perform broad (WriteFile Replace Nothing (plain `join` "sentinel.txt") (BC.pack "keep"))
      ]
  linked <- do
    started <- perform broad (Spawn (SpawnRequest ["/bin/sh", "-c", script "guard links"] project Nothing Nothing))
    either (pure . Left . show) (finish broad) started
  case (sequence prepared, linked) of
    (Left problem, _) -> pure [Check "guard setup" (Fail (show problem))]
    (_, Left problem) -> pure [Check "guard setup" (Fail problem)]
    (_, Right (_, _, status)) | status /= ExitCode 0 -> pure [Check "guard setup" (Fail ("ln exited with " ++ show status))]
    _ -> do
      refusals <-
        sequence
          ( [ expect guarded "the guard refuses removing a write root itself" (Remove Recursive plain) (failsWith Denied),
              expect guarded "the guard refuses removing /" (Remove Recursive "/") (failsWith Denied),
              expect guarded "the guard refuses removing the temporary root" (Remove Recursive temporaryRoot) (failsWith Denied),
              expect guarded "the guard refuses mkdirs at /" (MakeDirectories Nothing "/") (failsWith Denied),
              expect guarded "the guard refuses a write to an ancestor of the working directory" (WriteFile Replace Nothing (project `join` "work") (BC.pack "x")) (failsWith Denied),
              expect guarded "the guard refuses removing the project root" (Remove Recursive project) (failsWith Denied),
              expect guarded "the guard refuses mkdirs through a link to an ancestor of the working directory" (MakeDirectories Nothing (plain `join` "up")) (failsWith Denied),
              expect (granting "/") "the guard refuses a policy granting write on /" (WriteFile Replace Nothing refused (BC.pack "x")) (failsWith Denied),
              expect guarded "the guard refuses renaming a write root itself" (Rename plain (project `join` "moved")) (failsWith Denied),
              expect guarded "the guard refuses renaming over a write root" (Rename (plain `join` "sentinel.txt") plain) (failsWith Denied),
              expect guarded "the guard refuses renaming over the project root" (Rename (plain `join` "sentinel.txt") project) (failsWith Denied),
              expect guarded "the guard refuses renaming an ancestor of the working directory" (Rename (project `join` "work") (plain `join` "work")) (failsWith Denied),
              expect guarded "the guard refuses renaming over the working directory" (Rename sentinel cwd) (failsWith Denied),
              expect guarded "the guard refuses renaming to /" (Rename (plain `join` "sentinel.txt") "/") (failsWith Denied)
            ]
              ++ concat
                [ [ expect guarded "the guard refuses removing the home directory" (Remove Recursive root) (failsWith Denied),
                    expect (granting root) "the guard refuses a policy granting write on the home directory" (WriteFile Replace Nothing refused (BC.pack "x")) (failsWith Denied)
                  ]
                | root <- take 1 (absolute (maybe [] pure home))
                ]
          )
      allowed <-
        sequence
          [ expect guarded "the guard allows a rename strictly inside write roots" (Rename (plain `join` "inner") (plain `join` "renamed")) done,
            expect guarded "the guard allows a removal strictly inside a write root" (Remove Recursive (plain `join` "renamed")) done
          ]
      kept <-
        sequence
          [ expect broad "the guard's refusals leave the sentinels" (ReadFile sentinel) (ok (== BC.pack "keep")),
            expect broad "the guard's refusals leave a write root's files" (ReadFile (plain `join` "sentinel.txt")) (ok (== BC.pack "keep")),
            expect broad "the guard's refusals leave the working directory" (Stat NoFollow cwd) (ok ((== DirectoryKind) . statusKind)),
            expect broad "the guard's refusals write nothing" (Stat NoFollow refused) (failsWith NotFound)
          ]
      pure (refusals ++ allowed ++ kept)
  where
    -- The project root, holding the working directory, with a plain write
    -- root inside it.
    project = scratch `join` "guard"
    cwd = project `join` "work/cwd"
    plain = project `join` "plain"
    sentinel = project `join` "sentinel.txt"
    refused = project `join` "refused.txt"
    policy =
      Policy.closed
        { Policy.writeRoots = [project, plain],
          Policy.workingDirectory = Just cwd,
          Policy.projectRoots = [project]
        }

-- | The host's own enforcement. Requests go to the host confined to a
-- narrow policy without passing the core's check, as if the core had a
-- defect; the host must refuse each one with 'Denied', including paths
-- that leave a root only through a symbolic link.
confinement :: (Monad m) => Suite m
confinement host scratch = do
  let broad = confined host (conformancePolicy scratch)
      narrow = confined host policy
  prepared <-
    sequence
      [ perform broad (WriteFile Replace Nothing (base `join` "secret.txt") (BC.pack "secret")),
        perform broad (WriteFile Replace Nothing (readRoot `join` "granted.txt") (BC.pack "granted")),
        perform broad (MakeDirectories Nothing writeRoot)
      ]
  linked <- do
    started <- perform broad (Spawn (SpawnRequest ["/bin/sh", "-c", script "links"] base Nothing Nothing))
    either (pure . Left . show) (finish broad) started
  case (sequence prepared, linked) of
    (Left problem, _) -> pure [Check "confinement setup" (Fail (show problem))]
    (_, Left problem) -> pure [Check "confinement setup" (Fail problem)]
    (_, Right (_, _, status)) | status /= ExitCode 0 -> pure [Check "confinement setup" (Fail ("ln exited with " ++ show status))]
    _ ->
      sequence
        [ expect narrow "a host allows what its policy grants" (ReadFile (readRoot `join` "granted.txt")) (ok (== BC.pack "granted")),
          expect narrow "a host refuses a read outside its roots" (ReadFile (base `join` "secret.txt")) (failsWith Denied),
          expect narrow "a host refuses a write to a read-only root" (WriteFile Replace Nothing (readRoot `join` "new.txt") (BC.pack "x")) (failsWith Denied),
          expect narrow "a host refuses a program it was not granted" (Spawn (SpawnRequest ["/bin/echo", "x"] readRoot Nothing Nothing)) (failsWith Denied),
          expect narrow "a host refuses a fetch without network access" (Fetch (FetchRequest "https://127.0.0.1:9/" "GET" [] Nothing)) (failsWith Denied),
          expect narrow "a host refuses to listen without permission" (Serve 0) (failsWith Denied),
          expect narrow "a host refuses a read through a link that leaves its root" (ReadFile (readRoot `join` "escape")) (failsWith Denied),
          expect narrow "a host refuses a write through a linked directory" (WriteFile Replace Nothing (writeRoot `join` "link/x.txt") (BC.pack "x")) (failsWith Denied),
          expect narrow "a host refuses a rename out of a read-only root" (Rename (readRoot `join` "granted.txt") (writeRoot `join` "granted.txt")) (failsWith Denied),
          expect narrow "a host refuses a rename into a read-only root" (Rename (writeRoot `join` "x.txt") (readRoot `join` "x.txt")) (failsWith Denied),
          expect narrow "a host refuses a rename through a linked directory" (Rename (writeRoot `join` "link/granted.txt") (writeRoot `join` "granted.txt")) (failsWith Denied),
          expect narrow "a host's rename refusals leave the file" (ReadFile (readRoot `join` "granted.txt")) (ok (== BC.pack "granted")),
          expect narrow "a host stats a link in its root without following it" (Stat NoFollow (readRoot `join` "escape")) (ok ((== SymbolicLinkKind) . statusKind)),
          expect narrow "a host refuses realpath through a link that leaves its root" (RealPath (readRoot `join` "escape")) (failsWith Denied),
          expect host "a host refuses files before it is confined" (ReadFile (readRoot `join` "granted.txt")) (failsWith Denied),
          expect host "a host refuses realpath before it is confined" (RealPath readRoot) (failsWith Denied),
          expect host "a host allows standard streams before it is confined" GetClock (ok (const True)),
          expect host "a host allows terminal queries before it is confined" (QueryTerminal StandardError) (ok (const True))
        ]
  where
    base = scratch `join` "policy"
    readRoot = base `join` "read"
    writeRoot = base `join` "write"
    policy = Policy.closed {Policy.readRoots = [readRoot], Policy.writeRoots = [writeRoot], Policy.programs = ["/bin/sh"]}
