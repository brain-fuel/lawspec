{-# LANGUAGE GADTs #-}

-- | The host-effect ABI: the envelope codec round-trips every effect and
-- result, the sandbox refuses what its policy does not grant, the in-memory
-- host passes the conformance suite every host must pass, and the ported
-- fmt command prints and writes what the Node CLI does.
-- ref:DEC-host-effect-abi ref:DEC-haskell-application-port
module HostSpec (spec) where

import qualified Data.Aeson as JSON
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import LawSpec.App.Arguments (javascriptNumber)
import LawSpec.App.Command (utf8)
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.Host.Base64
import LawSpec.Host.Codec
import LawSpec.Host.Conformance
import LawSpec.Host.Effect
import LawSpec.Host.Fake
import LawSpec.Host.Path
import LawSpec.Host.Sandbox
import Test.Hspec

effects :: [SomeEffect]
effects =
  [ SomeEffect (ReadFile "/a/b"),
    SomeEffect (WriteFile Replace Nothing "/a" (B.pack [0, 255, 10])),
    SomeEffect (WriteFile Create Nothing "/a" B.empty),
    SomeEffect (WriteFile Replace (Just 0o755) "/a" B.empty),
    SomeEffect (WriteFile Create (Just 0o4700) "/a" B.empty),
    SomeEffect (ListDirectory "/"),
    SomeEffect (Stat Follow "/a"),
    SomeEffect (Stat NoFollow "/a"),
    SomeEffect (RealPath "/a/b"),
    SomeEffect (Remove Recursive "/a"),
    SomeEffect (Remove NotRecursive "/a"),
    SomeEffect (Rename "/a/b" "/a/c"),
    SomeEffect (MakeDirectories Nothing "/a/b"),
    SomeEffect (MakeDirectories (Just 0o700) "/a/b"),
    SomeEffect (Spawn (SpawnRequest ["/bin/sh", "-c", "true"] "/w" Nothing Nothing)),
    SomeEffect (Spawn (SpawnRequest ["x"] "/w" (Just [("A", "1"), ("B", "")]) (Just (BC.pack "in")))),
    SomeEffect (Poll [ProcessHandle 1, ProcessHandle 2] 250),
    SomeEffect (Kill (ProcessHandle 3)),
    SomeEffect (Fetch (FetchRequest "https://example.org/x" "GET" [("accept", "a"), ("accept", "b")] Nothing)),
    SomeEffect (Fetch (FetchRequest "https://example.org/x" "POST" [] (Just (BC.pack "body")))),
    SomeEffect (GetEnvironment "PATH"),
    SomeEffect GetClock,
    SomeEffect (WriteOutput Stdout (BC.pack "out")),
    SomeEffect (WriteOutput Stderr B.empty),
    SomeEffect (ReadInput 4096),
    SomeEffect (QueryTerminal StandardInput),
    SomeEffect (QueryTerminal StandardOutput),
    SomeEffect (QueryTerminal StandardError),
    SomeEffect (Serve 0),
    SomeEffect (Accept (Listener 1) 10),
    SomeEffect (Respond (RequestId 4) (Response 200 [("content-type", "text/plain")] (BC.pack "ok")))
  ]

-- | Each effect with results of its own type, failures included.
results :: [(String, Either String Bool)]
results =
  [ check (ReadFile "/a") [Right (B.pack [0 .. 255]), failure NotFound],
    check (WriteFile Replace Nothing "/a" B.empty) [Right (), failure AlreadyExists],
    check (ListDirectory "/") [Right [Entry "a" FileKind, Entry "b" DirectoryKind, Entry "c" SymbolicLinkKind, Entry "d" OtherKind], Right []],
    check (Stat Follow "/") [Right (Status DirectoryKind 0 1700000000000 (Just 0o755)), Right (Status FileKind 3 0 Nothing), failure Denied],
    check (Rename "/a" "/b") [Right (), failure DirectoryNotEmpty, failure Failed],
    check (MakeDirectories (Just 0o700) "/a") [Right (), failure AlreadyExists],
    check (RealPath "/a/../b") [Right "/private/b", failure NotFound],
    check (Spawn (SpawnRequest [] "/" Nothing Nothing)) [Right (ProcessHandle 7), failure Invalid],
    check (Poll [] 0) [Right [Chunk (ProcessHandle 1) Stdout (BC.pack "x"), Chunk (ProcessHandle 1) Stderr B.empty, Exited (ProcessHandle 1) (ExitCode 3), Exited (ProcessHandle 2) (Signalled "SIGTERM")]],
    check (Fetch (FetchRequest "" "" [] Nothing)) [Right (FetchResponse 404 [("a", "b")] (BC.pack "nope")), failure Unsupported],
    check (GetEnvironment "X") [Right Nothing, Right (Just "value")],
    check GetClock [Right (Clock 1700000000123 99999999999)],
    check (ReadInput 1) [Right (Input B.empty True), Right (Input (BC.pack "x") False)],
    check (QueryTerminal StandardInput) [Right (Terminal False Nothing)],
    check (QueryTerminal StandardOutput) [Right (Terminal True (Just 120)), Right (Terminal True Nothing)],
    check (QueryTerminal StandardError) [Right (Terminal False Nothing), failure Failed],
    check (Serve 0) [Right (Listening (Listener 2) 8080)],
    check (Accept (Listener 1) 0) [Right Nothing, Right (Just (IncomingRequest (RequestId 3) "GET" "/x?y" [("host", "h")] B.empty))],
    check (Respond (RequestId 1) (Response 200 [] B.empty)) [Right (), failure Failed]
  ]
  where
    failure kind = Left (HostError kind ("a " ++ errorKindName kind ++ " problem"))
    check :: (Eq a, Show a) => Effect a -> [Either HostError a] -> (String, Either String Bool)
    check request values =
      (effectName request, fmap and (mapM (\value -> (== value) <$> decodeResult request (encodeResult request (value))) values))

-- | /bin/sh for the conformance scripts, by their exact text.
shell :: Program
shell request = case spawnArguments request of
  ["/bin/sh", "-c", text]
    | Just name <- lookup text [(body, label) | (label, body) <- shellScripts] -> case name of
        "streams" -> Just (3, BC.pack "out", BC.pack "err")
        "input" ->
          Just (0, maybe B.empty id (spawnInput request) <> BC.pack (maybe "" id (spawnEnvironment request >>= lookup "CONFORMANCE_VALUE")), B.empty)
        "directory" -> Just (0, BC.pack (spawnDirectory request ++ "\n"), B.empty)
        "links" -> Just (0, B.empty, B.empty)
        "path links" -> Just (0, B.empty, B.empty)
        "guard links" -> Just (0, B.empty, B.empty)
        _ -> Nothing
  _ -> Just (127, B.empty, BC.pack "unknown script")

-- | curl in the serve round trip: the fake delivers its request from
-- 'worldRequests' and its output is the response body.
curl :: Program
curl _ = Just (0, BC.pack "pong", B.empty)

-- | The scratch directory, with the symbolic links the conformance
-- suite's "links", "path links" and "guard links" scripts make, since
-- scripted programs cannot write.
scratchWorld :: World
scratchWorld =
  (withDirectory "/scratch" emptyWorld)
    { worldEnvironment = [("PATH", "/usr/bin:/bin")],
      worldPrograms = [("/bin/sh", shell), ("/usr/bin/curl", curl)],
      worldRequests = [roundTripRequest 1, escapeRequest 2],
      worldFiles =
        foldr
          (uncurry M.insert)
          (worldFiles (withDirectory "/scratch/policy/read" (withDirectory "/scratch/policy/write" emptyWorld)))
          [ ("/scratch/policy/read/escape", LinkNode "../secret.txt"),
            ("/scratch/policy/write/link", LinkNode "../read"),
            ("/scratch/paths/link", LinkNode "dir"),
            ("/scratch/paths/chain", LinkNode "link"),
            ("/scratch/paths/dangling", LinkNode "missing"),
            ("/scratch/guard/plain/up", LinkNode "../work")
          ]
    }

samplePolicy :: Policy
samplePolicy = Policy ["/r", "/s"] ["/w"] ["/bin/sh"] True False ["/home/u", "/tmp/u"] (Just "/w/p") ["/w"]

source :: String
source = "unit example.boolean_flags\n\nflipFlag :: Bool -> Bool\nend unit\n"

-- | The same unit with doubled spaces, which the formatter removes.
unformatted :: String
unformatted = "unit example.boolean_flags\n\nflipFlag :: Bool  ->  Bool\nend unit\n"

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/work" Nothing Nothing Nothing Nothing))

stdout', stderr' :: World -> String
stdout' = BC.unpack . worldStdout
stderr' = BC.unpack . worldStderr

writes :: World -> [FilePath]
writes world = [path' | SomeEffect (WriteFile _ _ path' _) <- worldTrace world]

spec :: Spec
spec = describe "the host-effect ABI" $ do
  describe "base64" $ do
    it "matches the RFC 4648 test vectors" $
      map (encodeBase64 . BC.pack) ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
        `shouldBe` map BC.pack ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
    it "round-trips every byte value at every padding" $
      mapM_ (\n -> let bytes = B.pack (take n (cycle [0 .. 255])) in decodeBase64 (encodeBase64 bytes) `shouldBe` Right bytes) [0 .. 300]
    it "rejects malformed text" $ do
      decodeBase64 (BC.pack "Zg=") `shouldSatisfy` either (const True) (const False)
      decodeBase64 (BC.pack "Z===") `shouldSatisfy` either (const True) (const False)
      decodeBase64 (BC.pack "Zm9v!A==") `shouldSatisfy` either (const True) (const False)
  describe "the envelope codec" $ do
    it "round-trips every effect request with its policy" $
      mapM_ (\(SomeEffect request) -> decodeEffect (encodeEffect samplePolicy request) `shouldBe` Right (samplePolicy, SomeEffect request)) effects
    it "names the ABI version, operation and policy in every request" $
      mapM_ (\(SomeEffect request) -> encodeEffect closed request `shouldSatisfy` versioned request) effects
    it "rejects an effect request without a policy" $
      decodeEffect (JSON.object ["abi" JSON..= abiVersion, "op" JSON..= ("clock" :: String)]) `shouldSatisfy` either (const True) (const False)
    it "round-trips results and typed errors" $
      mapM_ (\(name, outcome) -> (name, outcome) `shouldBe` (name, Right True)) results
    it "rejects another ABI version and malformed replies" $ do
      decodeResult GetClock (JSON.object ["abi" JSON..= (1 :: Int), "ok" JSON..= JSON.object []]) `shouldSatisfy` either (const True) (const False)
      decodeResult (ReadFile "/a") (JSON.object ["abi" JSON..= abiVersion, "ok" JSON..= JSON.object ["data" JSON..= ("!!" :: String)]]) `shouldSatisfy` either (const True) (const False)
      decodeEffect (JSON.object ["abi" JSON..= abiVersion, "op" JSON..= ("teleport" :: String), "policy" JSON..= encodePolicy closed]) `shouldSatisfy` either (const True) (const False)
  describe "paths" $ do
    it "resolves, joins and relates as Node's path.posix does" $ do
      resolve "/a/b" "../c/./d/" `shouldBe` "/a/c/d"
      resolve "/a" "/x/../../y" `shouldBe` "/y"
      join "/a/b" "c" `shouldBe` "/a/b/c"
      relative "/a/b" "/a/b/c/d.lawspec" `shouldBe` "c/d.lawspec"
      relative "/a/b" "/a/x/y" `shouldBe` "../x/y"
      relative "/a" "/a" `shouldBe` ""
      normalise "a/../../b" `shouldBe` "../b"
    it "keeps a sibling with a common prefix outside a root" $ do
      within "/work" "/work/a" `shouldBe` True
      within "/work" "/workshop" `shouldBe` False
  describe "the sandbox" $ do
    let policy = closed {readRoots = ["/read"], writeRoots = ["/work"], programs = ["/bin/sh"]}
    it "allows what the policy grants" $ do
      allows policy (ReadFile "/read/a") `shouldBe` Nothing
      allows policy (ReadFile "/work/a") `shouldBe` Nothing
      allows policy (WriteFile Replace Nothing "/work/a/b" B.empty) `shouldBe` Nothing
      allows policy (Spawn (SpawnRequest ["/bin/sh"] "/work" Nothing Nothing)) `shouldBe` Nothing
      allows policy (RealPath "/read/a") `shouldBe` Nothing
      allows policy (QueryTerminal StandardOutput) `shouldBe` Nothing
    it "refuses everything else before the host sees it" $ do
      allows policy (WriteFile Replace Nothing "/read/a" B.empty) `shouldSatisfy` (/= Nothing)
      allows policy (ReadFile "/work/../etc/passwd") `shouldSatisfy` (/= Nothing)
      allows policy (ReadFile "relative") `shouldSatisfy` (/= Nothing)
      allows policy (Spawn (SpawnRequest ["/usr/bin/curl"] "/work" Nothing Nothing)) `shouldSatisfy` (/= Nothing)
      allows policy (Fetch (FetchRequest "https://example.org" "GET" [] Nothing)) `shouldSatisfy` (/= Nothing)
      allows policy {network = True} (Fetch (FetchRequest "http://example.org" "GET" [] Nothing)) `shouldSatisfy` (/= Nothing)
      allows policy (Serve 0) `shouldSatisfy` (/= Nothing)
      allows policy (RealPath "/etc") `shouldSatisfy` (/= Nothing)
      let (result, world) = runFake (perform (sandboxed policy fakeHost) (ReadFile "/etc/passwd")) emptyWorld
      fmap (const ()) result `shouldBe` Left (HostError Denied "path is outside the sandbox: /etc/passwd")
      length (worldTrace world) `shouldBe` 0
    it "confines the host to the same policy, and the host resolves links" $ do
      let base = withFile "/etc/passwd" (BC.pack "root") (withDirectory "/read" emptyWorld)
          linked = base {worldFiles = M.insert "/read/link" (LinkNode "/etc/passwd") (worldFiles base)}
          (result, world) = runFake (perform (sandboxed policy fakeHost) (ReadFile "/read/link")) linked
      allows policy (ReadFile "/read/link") `shouldBe` Nothing
      fmap (const ()) result `shouldBe` Left (HostError Denied "path leaves the sandbox through a symbolic link: /read/link")
      length (worldTrace world) `shouldBe` 1
    it "leaves a malformed request to the host's interpreter" $ do
      let (result, _) = runFake (perform (confined fakeHost policy) (ReadFile "relative")) emptyWorld
      fmap (const ()) result `shouldSatisfy` either ((== Invalid) . errorKind) (const False)
  describe "the guard" $ do
    -- /home/u is home, /t the temporary directory; /p the project root
    -- with the working directory /p/sub/cwd; /p/out a plain write root.
    let anchored = closed {protectedPaths = ["/home/u", "/t"], workingDirectory = Just "/p/sub/cwd", projectRoots = ["/p"]}
        guardedPolicy = anchored {writeRoots = ["/p", "/p/out"]}
        refused policy' effect' = case allows policy' effect' of
          Just _ -> True
          Nothing -> False
    it "refuses a write, remove or mkdirs of a protected path or an ancestor of one" $ do
      mapM_
        (\effect' -> (show effect', refused guardedPolicy effect') `shouldBe` (show effect', True))
        [ Remove Recursive "/",
          Remove Recursive "/home/u",
          Remove Recursive "/home",
          Remove Recursive "/t",
          Remove Recursive "/tmp",
          Remove Recursive "/private/tmp",
          Remove NotRecursive "/private",
          Remove Recursive "/var/tmp",
          Remove Recursive "/private/var/folders",
          Remove Recursive "/var/folders/ab/cdef/T",
          Remove Recursive "/private/var/folders/ab/cdef",
          Remove Recursive "/var",
          MakeDirectories Nothing "/",
          MakeDirectories Nothing "/p/sub/cwd",
          MakeDirectories Nothing "/p",
          WriteFile Replace Nothing "/p/sub" B.empty,
          WriteFile Replace Nothing "/p/sub/cwd/../" B.empty,
          Remove Recursive "/p",
          Remove Recursive "/p/sub"
        ]
    it "allows what lies inside the project and the temporary directories" $ do
      allows guardedPolicy (WriteFile Replace Nothing "/p/a.lawspec" B.empty) `shouldBe` Nothing
      allows guardedPolicy (WriteFile Replace Nothing "/p/sub/cwd/a.lawspec" B.empty) `shouldBe` Nothing
      allows guardedPolicy (MakeDirectories Nothing "/p/.lawspec/cache") `shouldBe` Nothing
      allows guardedPolicy (Remove Recursive "/p/.lawspec") `shouldBe` Nothing
      allows guardedPolicy (Remove Recursive "/p/out/x") `shouldBe` Nothing
      allows guardedPolicy {writeRoots = ["/t/lawspec-scratch"]} (Remove Recursive "/t/lawspec-scratch/probe") `shouldBe` Nothing
      allows guardedPolicy {writeRoots = ["/var/folders/ab/cdef/T/x"]} (Remove Recursive "/var/folders/ab/cdef/T/x/y") `shouldBe` Nothing
      allows guardedPolicy {writeRoots = ["/var/folders/ab/cdef/C"]} (Remove Recursive "/var/folders/ab/cdef/C/y") `shouldBe` Nothing
    it "allows a removal only strictly inside a write root" $ do
      allows guardedPolicy (Remove Recursive "/p/out") `shouldSatisfy` (/= Nothing)
      allows guardedPolicy (Remove NotRecursive "/p/out/") `shouldSatisfy` (/= Nothing)
      allows guardedPolicy (Remove NotRecursive "/p/out/file") `shouldBe` Nothing
    it "allows a rename only with both paths strictly inside write roots and unprotected" $ do
      allows guardedPolicy (Rename "/p/out/a" "/p/out/b") `shouldBe` Nothing
      allows guardedPolicy (Rename "/p/out/a" "/p/.lawspec/b") `shouldBe` Nothing
      allows guardedPolicy (Rename "/p/out" "/p/moved") `shouldBe` Just "rename is allowed only strictly inside a write root, never of one: /p/out"
      allows guardedPolicy (Rename "/p/out/a" "/p/out/") `shouldBe` Just "rename is allowed only strictly inside a write root, never of one: /p/out/"
      allows guardedPolicy (Rename "/p/out/a" "/p/sub/cwd") `shouldBe` Just "rename of a protected path, or of an ancestor of one, is refused: /p/sub/cwd"
      allows guardedPolicy (Rename "/p/sub" "/p/out/sub") `shouldBe` Just "rename of a protected path, or of an ancestor of one, is refused: /p/sub"
      allows guardedPolicy (Rename "/p/out/a" "/p") `shouldSatisfy` (/= Nothing)
      allows guardedPolicy (Rename "/p/out/a" "/elsewhere/b") `shouldSatisfy` (/= Nothing)
      allows guardedPolicy (Rename "/read/a" "/p/out/b") `shouldSatisfy` (/= Nothing)
      touched (Rename "/a" "/b") `shouldBe` [(WriteAccess, Parent, "/a"), (WriteAccess, Parent, "/b")]
    it "refuses every path effect while a write root is protected" $ do
      let granting root = guardedPolicy {writeRoots = writeRoots guardedPolicy ++ [root]}
      mapM_
        (\root -> (root, refused (granting root) (ReadFile "/p/a.lawspec")) `shouldBe` (root, True))
        ["/", "/home/u", "/home", "/t", "/tmp", "/private", "/var", "/var/folders/ab", "/p/sub", "/p/sub/cwd"]
      allows (granting "/") (WriteFile Replace Nothing "/p/a" B.empty) `shouldBe` Just "a write root is a protected path or contains one: /"
      allows (granting "/") GetClock `shouldBe` Nothing
      allows (granting "/") (WriteOutput Stdout B.empty) `shouldBe` Nothing
    it "lets a project root, and only a project root, contain the working directory" $ do
      allows guardedPolicy {projectRoots = []} (WriteFile Replace Nothing "/p/a" B.empty) `shouldSatisfy` (/= Nothing)
      allows guardedPolicy {projectRoots = ["/p/sub/cwd"], writeRoots = ["/p/sub/cwd"]} (WriteFile Replace Nothing "/p/sub/cwd/a" B.empty) `shouldBe` Nothing
      allows anchored {projectRoots = ["/home/u"], writeRoots = ["/home/u"]} (WriteFile Replace Nothing "/home/u/a" B.empty) `shouldSatisfy` (/= Nothing)
    it "protects the fixed system paths under every policy" $ do
      allows closed {writeRoots = ["/"]} (WriteFile Replace Nothing "/x" B.empty) `shouldSatisfy` (/= Nothing)
      allows closed {writeRoots = ["/w"]} (Remove Recursive "/w") `shouldSatisfy` (/= Nothing)
      protects [] "/private/var/folders/xy/z/T" `shouldBe` True
      protects [] "/var/folders/xy/z/T/item" `shouldBe` False
      protects ["/Users/u"] "/Users" `shouldBe` True
      protects ["/Users/u"] "/Users/u2" `shouldBe` False
    it "refuses before the host performs anything, and the host refuses on its own" $ do
      let world = withFile "/p/out/keep" (BC.pack "keep") (withDirectory "/p/sub/cwd" emptyWorld)
          attempts =
            [ SomeEffect (Remove Recursive "/p/out"),
              SomeEffect (Remove Recursive "/"),
              SomeEffect (Remove Recursive "/p"),
              SomeEffect (MakeDirectories Nothing "/"),
              SomeEffect (WriteFile Replace Nothing "/p/sub" B.empty),
              SomeEffect (Rename "/p/out" "/p/moved"),
              SomeEffect (Rename "/p/out/keep" "/p/out"),
              SomeEffect (Rename "/p/sub" "/p/out/sub")
            ]
      mapM_
        ( \(SomeEffect effect') -> do
            let (sandboxedResult, sandboxedWorld) = runFake (perform (sandboxed guardedPolicy fakeHost) effect') world
                (hostResult, hostWorld) = runFake (perform (confined fakeHost guardedPolicy) effect') world
            fmap (const ()) sandboxedResult `shouldSatisfy` either ((== Denied) . errorKind) (const False)
            length (worldTrace sandboxedWorld) `shouldBe` 0
            fmap (const ()) hostResult `shouldSatisfy` either ((== Denied) . errorKind) (const False)
            worldFiles hostWorld `shouldBe` worldFiles world
        )
        attempts
    it "resolves symbolic links in the host before it applies the guard again" $ do
      let base = withFile "/p/out/keep" (BC.pack "keep") (withDirectory "/home/u/docs" (withDirectory "/p/sub/cwd" emptyWorld))
          world =
            base
              { worldEnvironment = [("HOME", "/home/u")],
                worldFiles =
                  foldr
                    (uncurry M.insert)
                    (worldFiles base)
                    [ ("/p/out/home", LinkNode "/home/u"),
                      ("/p/out/root", LinkNode "/"),
                      ("/p/out/up", LinkNode "../sub")
                    ]
              }
          -- The host's own HOME, not the policy, protects /home/u here.
          hostPolicy = guardedPolicy {protectedPaths = []}
          host = confined fakeHost hostPolicy
          denied effect' = do
            let (result, afterwards) = runFake (perform host effect') world
            fmap (const ()) result `shouldSatisfy` either ((== Denied) . errorKind) (const False)
            worldFiles afterwards `shouldBe` worldFiles world
      allows hostPolicy (MakeDirectories Nothing "/p/out/home") `shouldBe` Nothing
      denied (MakeDirectories Nothing "/p/out/home")
      allows hostPolicy (WriteFile Replace Nothing "/p/out/up" B.empty) `shouldBe` Nothing
      denied (MakeDirectories Nothing "/p/out/up")
      denied (Remove Recursive "/home/u")
      denied (Rename "/p/out/keep" "/p/out/up/cwd")
      denied (Rename "/p/out/root/etc" "/p/out/x")
      let linkedRoot = confined fakeHost hostPolicy {writeRoots = ["/p/out/root"]}
          (rootResult, rootWorld) = runFake (perform linkedRoot (WriteFile Replace Nothing "/p/out/root/x" B.empty)) world
      fmap (const ()) rootResult `shouldSatisfy` either ((== Denied) . errorKind) (const False)
      worldFiles rootWorld `shouldBe` worldFiles world
      -- Removing a link to home removes the link alone, which is allowed.
      let (unlinked, unlinkedWorld) = runFake (perform host (Remove NotRecursive "/p/out/home")) world
      unlinked `shouldBe` Right ()
      M.member "/p/out/home" (worldFiles unlinkedWorld) `shouldBe` False
      M.member "/home/u/docs" (worldFiles unlinkedWorld) `shouldBe` True
    it "tells the guard the working directory, home and temporary directories at startup" $ do
      let project = withFile "/work/a.lawspec" (utf8 source) emptyWorld
          (outcome, world) = runFake (lawspecMain fakeHost pureCompiler (Invocation ["fmt", "."] "/work" Nothing Nothing Nothing Nothing)) project {worldEnvironment = [("HOME", "/home/u"), ("TMPDIR", "/t/")]}
      outcome `shouldBe` Completed 0
      map variableName (take 2 (worldTrace world)) `shouldBe` [Just "HOME", Just "TMPDIR"]
    it "formats a named ancestor of the working directory as the project" $ do
      let project = withFile "/work/sub/a.lawspec" (utf8 source) emptyWorld
          (outcome, world) = runFake (lawspecMain fakeHost pureCompiler (Invocation ["fmt", ".."] "/work/sub" Nothing Nothing Nothing Nothing)) project
      (outcome, stderr' world) `shouldBe` (Completed 0, "")
    it "refuses fmt of a path that makes the home directory a write root" $ do
      let project = withFile "/home/u/sub/a.lawspec" (utf8 source) emptyWorld
          (outcome, world) = runFake (lawspecMain fakeHost pureCompiler (Invocation ["fmt", ".."] "/home/u/sub" Nothing Nothing Nothing Nothing)) project {worldEnvironment = [("HOME", "/home/u")]}
      outcome `shouldBe` Completed 1
      stderr' world `shouldSatisfy` ("lawspec: a write root is a protected path or contains one: /home/u" `isPrefixOf`)
      writes world `shouldBe` []
  describe "the in-memory host's files" $ do
    let host = confined fakeHost closed {writeRoots = ["/w"]}
        world = withFile "/w/d/x" (BC.pack "x") (withFile "/w/a" (BC.pack "a") (withFile "/w/b" (BC.pack "b") emptyWorld))
        run' effect' = runFake (perform host effect') world
    it "renames a file over another and a directory with its contents" $ do
      let (result, after) = run' (Rename "/w/a" "/w/b")
      result `shouldBe` Right ()
      (M.lookup "/w/a" (worldFiles after), M.lookup "/w/b" (worldFiles after)) `shouldBe` (Nothing, Just (FileNode (BC.pack "a")))
      let (moved, afterMove) = run' (Rename "/w/d" "/w/e")
      moved `shouldBe` Right ()
      (M.member "/w/d" (worldFiles afterMove), M.lookup "/w/e/x" (worldFiles afterMove)) `shouldBe` (False, Just (FileNode (BC.pack "x")))
      let (replaced, afterReplace) = runFake (perform host (Rename "/w/d" "/w/empty")) (withDirectory "/w/empty" world)
      replaced `shouldBe` Right ()
      M.lookup "/w/empty/x" (worldFiles afterReplace) `shouldBe` Just (FileNode (BC.pack "x"))
    it "refuses a rename as rename(2) does" $ do
      fmap (const ()) (fst (run' (Rename "/w/missing" "/w/c"))) `shouldBe` Left (HostError NotFound "/w/missing")
      either (Just . errorKind) (const Nothing) (fst (run' (Rename "/w/a" "/w/d"))) `shouldBe` Just IsADirectory
      either (Just . errorKind) (const Nothing) (fst (run' (Rename "/w/d" "/w/a"))) `shouldBe` Just NotADirectory
      either (Just . errorKind) (const Nothing) (fst (run' (Rename "/w/d" "/w/d/inner"))) `shouldBe` Just Failed
      either (Just . errorKind) (const Nothing) (fst (run' (Rename "/w/a" "/w/none/c"))) `shouldBe` Just NotFound
    it "creates files and directories with permission bits less the mask, and stats them" $ do
      let (_, written) = run' (WriteFile Replace (Just 0o777) "/w/run.sh" B.empty)
          (_, made) = runFake (perform host (MakeDirectories (Just 0o700) "/w/p/q")) written
          (_, replaced) = runFake (perform host (WriteFile Replace Nothing "/w/run.sh" B.empty)) made
          bits world' path' = fst (runFake (perform host (Stat NoFollow path')) world') >>= maybe (Left (HostError Failed "none")) Right . statusPermissions
      bits written "/w/run.sh" `shouldBe` Right 0o755
      bits made "/w/p" `shouldBe` Right 0o700
      bits made "/w/p/q" `shouldBe` Right 0o700
      bits made "/w/a" `shouldBe` Right 0o644
      bits made "/w/d" `shouldBe` Right 0o755
      bits replaced "/w/run.sh" `shouldBe` Right 0o644
      let (_, again) = runFake (perform host (MakeDirectories (Just 0o777) "/w/p")) made
      bits again "/w/p" `shouldBe` Right 0o700
  describe "host conformance" $
    it "passes over the in-memory host" $ do
      let (checks, _) = runFake (conformance fakeHost "/scratch") scratchWorld
      [check | check@(Check _ verdict) <- checks, verdict /= Pass] `shouldBe` []
  describe "the native CLI" $
    it "names an unported command in one line with its own exit code" $ do
      notPortedMessage (Invocation ["check", "--json"] "/w" Nothing Nothing Nothing Nothing) "command not ported yet: check"
        `shouldBe` "lawspec: 'check' is not available in the native CLI yet (command not ported yet: check)"
      notPortedMessage (Invocation [] "/w" Nothing Nothing Nothing Nothing) "usage is printed by the legacy CLI"
        `shouldBe` "lawspec: this invocation is not available in the native CLI yet (usage is printed by the legacy CLI)"
      notPortedExitCode `shouldSatisfy` (`notElem` ([0 .. 14] ++ [128 .. 160]))
  describe "JSON.stringify" $ do
    it "indents, escapes and orders as JavaScript" $
      stringify (fromValue (JSON.object ["b" JSON..= [1 :: Int, 2], "a" JSON..= ("q\"\n\1" :: String), "10" JSON..= JSON.Null, "2" JSON..= JSON.object [], "e" JSON..= ([] :: [Int])]))
        `shouldBe` "{\n  \"2\": {},\n  \"10\": null,\n  \"a\": \"q\\\"\\n\\u0001\",\n  \"b\": [\n    1,\n    2\n  ],\n  \"e\": []\n}"
    it "prints numbers as Number::toString" $
      map (numberText . number) ["5", "1.5", "1e21", "1e-7", "123e-9", "-2"]
        `shouldBe` ["5", "1.5", "1e+21", "1e-7", "1.23e-7", "-2"]
    it "reads numbers as Number(string)" $
      map javascriptNumber [" 32 ", "0x20", "64.0", "6.4e1", "3.2e+1", "", "32px", "-0x20", "1e999999999"]
        `shouldBe` [Just 32, Just 32, Just 64, Just 64, Just 32, Just 0, Nothing, Nothing, Just (10 ^ (400 :: Int))]
  describe "lawspec fmt" $ do
    let project = withFile "/work/a.lawspec" (utf8 source) (withFile "/work/sub/b.lawspec" (utf8 unformatted) (withFile "/work/notes.txt" (BC.pack "x") emptyWorld))
    it "formats the given paths in place" $ do
      let (outcome, world) = run ["fmt", "."] project
      outcome `shouldBe` Completed 0
      stdout' world `shouldBe` "1 source file(s) formatted.\n"
      stderr' world `shouldBe` ""
      writes world `shouldBe` ["/work/sub/b.lawspec"]
      M.lookup "/work/sub/b.lawspec" (worldFiles world) `shouldBe` Just (FileNode (utf8 source))
    it "checks without writing" $ do
      let (outcome, world) = run ["fmt", "sub", "--check"] project
      outcome `shouldBe` Completed 1
      stdout' world `shouldBe` "1 source file(s) need formatting.\n"
      writes world `shouldBe` []
    it "reports formatted sources as JSON" $ do
      let (outcome, world) = run ["fmt", "--json", "--check", "a.lawspec", "sub/b.lawspec"] project
      outcome `shouldBe` Completed 1
      stdout' world `shouldBe` "{\n  \"changed\": [\n    \"sub/b.lawspec\"\n  ],\n  \"check\": true\n}\n"
    it "says when every source is formatted" $ do
      let (outcome, world) = run ["fmt", "a.lawspec", "--machine-bits", "0x20"] project
      (outcome, stdout' world) `shouldBe` (Completed 0, "All sources are formatted.\n")
    it "fails as the Node CLI does" $ do
      let failure arguments = let (outcome, world) = run arguments project in (outcome, stdout' world, stderr' world)
      failure ["fmt", "missing.lawspec"]
        `shouldBe` (Completed 1, "", "lawspec: ENOENT: no such file or directory, lstat '/work/missing.lawspec'\n")
      failure ["fmt", "notes.txt"] `shouldBe` (Completed 1, "", "lawspec: No .lawspec source files found\n")
      failure ["fmt", "a.lawspec", "--strict"] `shouldBe` (Completed 1, "", "lawspec: --strict applies to advise\n")
      failure ["fmt", "a.lawspec", "--machine-bits", "33"] `shouldBe` (Completed 1, "", "lawspec: machineBits must be 32 or 64\n")
      failure ["fmt", "a.lawspec", "--tag", ",", "--json"]
        `shouldBe` (Completed 1, "{\n  \"diagnostics\": [\n    {\n      \"code\": \"cli\",\n      \"message\": \"--fresh, --seed, --update-recorded, --tag, --exclude-tag, --report, --coverage and --benchmarks apply to test\",\n      \"at\": null\n    }\n  ]\n}\n", "")
    it "refuses symbolic links in sources" $ do
      let linked = project {worldFiles = M.insert "/work/link.lawspec" (LinkNode "a.lawspec") (worldFiles project)}
          (outcome, world) = run ["fmt", "."] linked
      (outcome, stderr' world) `shouldBe` (Completed 1, "lawspec: Symbolic links are not supported in LawSpec sources: /work/link.lawspec\n")
    it "reports compiler diagnostics with their locations" $ do
      let broken = withFile "/work/bad.lawspec" (utf8 "unit broken\nf :: \nend unit\n") emptyWorld
          (outcome, world) = run ["fmt", "bad.lawspec"] broken
      outcome `shouldBe` Completed 1
      stderr' world `shouldSatisfy` ("lawspec: bad.lawspec:" `isPrefixOf`)
      writes world `shouldBe` []
    it "leaves nothing to the legacy CLI: Canon's setup without a shipped Canon fails before writing anything" $
      mapM_
        ( \arguments -> do
            let (outcome, world) = run arguments project
            outcome `shouldNotSatisfy` notPorted
            outcome `shouldBe` Completed 1
            worldFiles world `shouldBe` worldFiles project
        )
        [["project", "init", "--project", "fresh"]]
    it "reports unknown options and missing values as usage errors without writing anything" $
      mapM_
        ( \(arguments, problem) -> do
            let (outcome, world) = run arguments project
            outcome `shouldBe` Completed 1
            stderr' world `shouldSatisfy` (("lawspec: " ++ problem ++ "\nUsage: lawspec fmt") `isPrefixOf`)
            writes world `shouldBe` []
        )
        [(["fmt", "a.lawspec", "--bogus"], "Unknown option: --bogus"), (["fmt", "--config"], "Missing value for --config")]
    it "decodes invocations and encodes outcomes" $ do
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[\"fmt\",\".\"],\"cwd\":\"/w/./x/\"}") `shouldBe` Right (Invocation ["fmt", "."] "/w/x" Nothing Nothing Nothing Nothing)
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"relative\"}") `shouldSatisfy` either (const True) (const False)
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[\"learn\"],\"cwd\":\"/w\",\"resources\":\"/pkg/./npm/\"}") `shouldBe` Right (Invocation ["learn"] "/w" Nothing Nothing (Just "/pkg/npm") Nothing)
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"resources\":\"npm\"}") `shouldBe` Left "resources must be an absolute path"
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"tools\":{\"canon\":{\"command\":[\"/n/./node\",\"/r/ricestax.mjs\",\"canon\"],\"presets\":\"/r/presets/\"},\"other\":1}}")
        `shouldBe` Right (Invocation [] "/w" Nothing Nothing Nothing (Just (CanonShipped (CanonTool ["/n/node", "/r/ricestax.mjs", "canon"] "/r/presets"))))
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"tools\":{\"canon\":{\"download\":{\"platform\":\"linux-x64\",\"cache\":\"/h/./cache/\"}}}}")
        `shouldBe` Right (Invocation [] "/w" Nothing Nothing Nothing (Just (CanonDownload "linux-x64" "/h/cache")))
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"tools\":{}}") `shouldBe` Right (Invocation [] "/w" Nothing Nothing Nothing Nothing)
      mapM_
        ( \tools ->
            decodeInvocation (BC.pack ("{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"tools\":" ++ tools ++ "}"))
              `shouldBe` Left "tools.canon must be an object with a command (an absolute program and its arguments) and an absolute presets directory, or with a download naming a platform and an absolute cache directory"
        )
        ["{\"canon\":\"/c\"}", "{\"canon\":{\"download\":{\"platform\":\"linux-x64\",\"cache\":\"cache\"}}}", "{\"canon\":{\"download\":{\"cache\":\"/c\"}}}", "{\"canon\":{\"command\":[],\"presets\":\"/p\"}}", "{\"canon\":{\"command\":[\"canon\"],\"presets\":\"/p\"}}", "{\"canon\":{\"command\":[\"/c\"]}}", "{\"canon\":{\"command\":[\"/c\"],\"presets\":\"p\"}}"]
      decodeInvocation (BC.pack "{\"abi\":2,\"argv\":[],\"cwd\":\"/w\",\"tools\":[]}") `shouldBe` Left "tools must be an object"
      encodeOutcome (Right (Completed 1)) `shouldBe` BC.pack "{\"abi\":2,\"exit\":1}"
  where
    number text = case JSON.decode (BL.fromStrict (BC.pack text)) of
      Just (JSON.Number value) -> value
      _ -> error ("not a number: " ++ text)
    variableName :: SomeEffect -> Maybe String
    variableName (SomeEffect effect') = case effect' of
      GetEnvironment name -> Just name
      _ -> Nothing
    notPorted (NotPorted _) = True
    notPorted _ = False
    mutating :: Effect a -> Bool
    mutating = \case
      WriteFile {} -> True
      Remove {} -> True
      MakeDirectories {} -> True
      WriteOutput {} -> True
      Spawn {} -> True
      _ -> False
    versioned request value = case value of
      JSON.Object fields ->
        KM.lookup "abi" fields == Just (JSON.Number 2) && KM.lookup "op" fields == Just (JSON.String (T.pack (effectName request))) && KM.member "policy" fields
      _ -> False
