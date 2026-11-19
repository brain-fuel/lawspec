{-# LANGUAGE GADTs #-}

-- | Contract packages over the in-memory host: fetch and update resolving
-- archive and Git sources into the package cache, the archive checksum,
-- version selection, lawspec package and its archive, and the tar and
-- gzip codecs with the entries an unpack refuses. tools/host-parity.mjs
-- compares the same commands with the legacy CLI byte for byte.
-- ref:DEC-haskell-application-port
module PackagesSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.Main
import LawSpec.Archive.Deflate (gunzip, gzip)
import LawSpec.Archive.Tar
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect hiding (Entry (..))
import LawSpec.Host.Fake
import Test.Hspec

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/p" Nothing Nothing Nothing Nothing))

out, err :: World -> String
out = BC.unpack . worldStdout
err = BC.unpack . worldStderr

file :: FilePath -> World -> Maybe B.ByteString
file path' world = case M.lookup path' (worldFiles world) of
  Just (FileNode bytes) -> Just bytes
  _ -> Nothing

-- | A published shop.tax at a version: its manifest and one unit.
taxPackage :: String -> [(String, Int, B.ByteString)]
taxPackage version' =
  [ ("lawspec.edn", 0o644, BC.pack ("{:manifest-version 1 :package {:name \"shop.tax\" :version \"" ++ version' ++ "\"} :language-profile \"1.0-rc.2\" :sources [\"src\"]}\n")),
    ("src/rates.lawspec", 0o644, BC.pack "unit shop.tax.rates\ntype Rate is a record{percent :: Integer} end type\nend unit\n")
  ]

archiveBytes :: B.ByteString
archiveBytes = gzip (writeTar (taxPackage "2.0.0"))

archiveUrl :: String
archiveUrl = "https://example.org/shop-tax-2.0.0.tgz"

-- | A component depending on shop.tax as the given EDN dependency.
orders :: String -> World
orders dependency =
  withFile "/p/lawspec.edn" (BC.pack ("{:manifest-version 1 :component {:name \"orders\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :dependencies {\"shop.tax\" " ++ dependency ++ "}}\n"))
    $ withFile "/p/laws/orders.lawspec" (BC.pack "unit orders\ntype Order is a record{id :: Integer} end type\nend unit\n")
    $ withDirectory "/cache" emptyWorld {worldEnvironment = [("LAWSPEC_CACHE_DIR", "/cache"), ("PATH", "/bin")]}

archiveProject :: String -> World
archiveProject sha =
  (orders ("{:version \"^2.0.0\" :archive \"" ++ archiveUrl ++ "\" :sha256 \"" ++ sha ++ "\"}"))
    { worldResponses = [(archiveUrl, FetchResponse 200 [] archiveBytes)]
    }

-- | The cache entry an archive source unpacks into.
archiveEntry :: String -> FilePath
archiveEntry sha =
  "/cache/" ++ hex ("{\"kind\":\"archive\",\"sha256\":\"" ++ sha ++ "\",\"url\":\"" ++ archiveUrl ++ "\"}")

hex :: String -> String
hex = digestHex . digest . BC.pack

-- | A Git remote with three release tags, as git answers for it.
gitRemote :: String
gitRemote = "https://example.org/tax.git"

commitFor :: String -> String
commitFor version' = take 40 (hex version')

git :: String -> SpawnRequest -> Maybe (Int, B.ByteString, B.ByteString)
git expected request = case drop 1 (spawnArguments request) of
  ["ls-remote", "--tags", "--refs", "--", _] ->
    ok (concat [commitFor v ++ "\trefs/tags/v" ++ v ++ "\n" | v <- ["2.0.0", "2.1.0", "3.0.0"]] ++ commitFor "x" ++ "\trefs/tags/latest\n")
  ["--git-dir", _, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", _, _] -> ok ""
  ["--git-dir", _, "rev-parse", _] -> ok (commitFor expected ++ "\n")
  ["--git-dir", _, "update-ref", "-d", _] -> ok ""
  ["--git-dir", _, "cat-file", "-e", _] -> ok ""
  ["init", "--bare", "--quiet", _] -> ok ""
  ["--git-dir", _, "archive", "--format=tar", commit]
    | commit == commitFor expected -> Just (0, writeTar (taxPackage expected), B.empty)
  _ -> Just (1, B.empty, BC.pack "unexpected git invocation\n")
  where
    ok text = Just (0, BC.pack text, B.empty)

gitProject :: String -> World
gitProject expected =
  withFile "/bin/git" (BC.pack "git")
    $
    -- git init --bare leaves HEAD behind; the scripted git writes nothing.
    withFile ("/cache/git/" ++ hex gitRemote ++ "/HEAD") (BC.pack "ref: refs/heads/main\n")
    $ (orders ("{:version \"^2.0.0\" :git \"" ++ gitRemote ++ "\"}")) {worldPrograms = [("/bin/git", git expected)]}

downloads :: [SomeEffect] -> [String]
downloads trace = [fetchUrl request | SomeEffect (Fetch request) <- trace]

-- | The same remote when it offered only 2.0.0.
pinnedProject :: World
pinnedProject = (gitProject "2.0.0") {worldPrograms = [("/bin/git", pinned)]}
  where
    pinned request = case drop 1 (spawnArguments request) of
      ["ls-remote", _, _, _, _] -> Just (0, BC.pack (commitFor "2.0.0" ++ "\trefs/tags/v2.0.0\n"), B.empty)
      _ -> git "2.0.0" request

fetched :: World -> [[String]]
fetched world = [drop 1 (spawnArguments request) | SomeEffect (Spawn request) <- worldTrace world, "fetch" `elem` spawnArguments request]

spec :: Spec
spec = describe "contract packages" $ do
  describe "lawspec fetch" $ do
    let sha' = digestHex (digest archiveBytes)
    it "downloads an archive whose SHA-256 matches, unpacks it into the cache and locks it" $ do
      let (outcome, world) = run ["fetch"] (archiveProject sha')
      (outcome, out world, err world) `shouldBe` (Completed 0, "Resolved 1 contract package(s).\n", "")
      file (archiveEntry sha' ++ "/src/rates.lawspec") world `shouldBe` lookup "src/rates.lawspec" [(p, b) | (p, _, b) <- taxPackage "2.0.0"]
      fmap (BC.unpack . BC.take 64) (file (archiveEntry sha' ++ ".sha256") world) `shouldSatisfy` maybe False ((== 64) . length)
      fmap (BC.isInfixOf (BC.pack (":sha256 \"" ++ sha' ++ "\""))) (file "/p/lawspec.lock.edn" world) `shouldBe` Just True
      [path' | path' <- M.keys (worldFiles world), ".unpack-" `isInfixOf` path'] `shouldBe` []
      -- The lock and the cache are enough offline.
      let (again, world') = run ["fetch", "--offline"] world {worldStdout = B.empty}
      (again, out world') `shouldBe` (Completed 0, "Resolved 1 contract package(s).\n")
      downloads (drop (length (worldTrace world)) (worldTrace world')) `shouldBe` []
    it "unpacks with the archive's modes into a 0700 entry renamed into place" $ do
      let executable = gzip (writeTar (taxPackage "2.0.0" ++ [("tools/run.sh", 0o775, BC.pack "#!/bin/sh\n")]))
          sha = digestHex (digest executable)
          (outcome, world) = run ["fetch"] (archiveProject sha) {worldResponses = [(archiveUrl, FetchResponse 200 [] executable)]}
      (outcome, err world) `shouldBe` (Completed 0, "")
      permissionsOf world (archiveEntry sha) `shouldBe` Just 0o700
      permissionsOf world (archiveEntry sha ++ "/tools/run.sh") `shouldBe` Just 0o755
      permissionsOf world (archiveEntry sha ++ "/lawspec.edn") `shouldBe` Just 0o644
      [() | SomeEffect (Rename from to) <- worldTrace world, ".unpack-" `isInfixOf` from, to == archiveEntry sha] `shouldBe` [()]
    it "keeps an entry another run placed first" $ do
      let (_, placed) = run ["fetch"] (archiveProject sha')
          (outcome, world) = run ["fetch"] placed {worldStdout = B.empty, worldFiles = M.delete "/p/lawspec.lock.edn" (M.delete (archiveEntry sha' ++ ".sha256") (worldFiles placed))}
      (outcome, err world) `shouldBe` (Completed 0, "")
      [path' | path' <- M.keys (worldFiles world), ".unpack-" `isInfixOf` path'] `shouldBe` []
    it "refuses an archive whose SHA-256 differs and keeps nothing of it" $ do
      let wrong = replicate 64 '0'
          (outcome, world) = run ["fetch"] (archiveProject wrong)
      (outcome, out world, err world) `shouldBe` (Completed 1, "", "lawspec: Contract archive SHA-256 mismatch: " ++ archiveUrl ++ "\n")
      [path' | path' <- M.keys (worldFiles world), "/cache/" `isPrefixOf` path'] `shouldBe` []
      file "/p/lawspec.lock.edn" world `shouldBe` Nothing
    it "reports a failed download with its status" $ do
      let world0 = (archiveProject sha') {worldResponses = [(archiveUrl, FetchResponse 404 [] B.empty)]}
          (outcome, world) = run ["fetch"] world0
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Contract download failed: HTTP 404 for " ++ archiveUrl ++ "\n")
    it "follows a redirect as fetch() did" $ do
      let moved = "https://mirror.example.org/tax.tgz"
          world0 = (archiveProject sha') {worldResponses = [(archiveUrl, FetchResponse 302 [("location", moved)] B.empty), (moved, FetchResponse 200 [] archiveBytes)]}
          (outcome, world) = run ["fetch"] world0
      (outcome, err world) `shouldBe` (Completed 0, "")
    it "refuses an archive URL that is not HTTPS" $ do
      let world0 = orders ("{:version \"^2.0.0\" :archive \"ftp://example.org/tax.tgz\" :sha256 \"" ++ replicate 64 'a' ++ "\"}")
          (outcome, world) = run ["fetch"] world0
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Contract archives must use HTTPS\n")
    it "needs a lockfile offline" $ do
      let (outcome, world) = run ["fetch", "--offline"] (gitProject "2.1.0")
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Offline: resolving shop.tax requires a lockfile\n")
  describe "the Git cache" $ do
    it "initialises a bare repository under a temporary name and renames it into place" $ do
      let world0 = (gitProject "2.1.0") {worldFiles = M.delete ("/cache/git/" ++ hex gitRemote ++ "/HEAD") (worldFiles (gitProject "2.1.0"))}
          (outcome, world) = run ["fetch"] world0
          initialised :: [String]
          initialised = [last (spawnArguments request) | SomeEffect (Spawn request) <- worldTrace world, "init" `elem` spawnArguments request]
      -- The scripted git writes no HEAD, so the renamed repository has none.
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Cached Git repository initialization did not complete: /cache/git/" ++ hex gitRemote ++ "\n")
      map (".initializing-" `isInfixOf`) initialised `shouldBe` [True]
      [() | SomeEffect (Rename from to) <- worldTrace world, [from] == initialised, to == "/cache/git/" ++ hex gitRemote] `shouldBe` [()]
      [path' | path' <- M.keys (worldFiles world), ".initializing-" `isInfixOf` path'] `shouldBe` []
    it "reports a cached repository left without HEAD and keeps it" $ do
      let repository = "/cache/git/" ++ hex gitRemote
          base = gitProject "2.1.0"
          world0 = withFile (repository ++ "/objects/info/packs") B.empty base {worldFiles = M.delete (repository ++ "/HEAD") (worldFiles base)}
          (outcome, world) = run ["fetch"] world0
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Cached Git repository initialization did not complete: " ++ repository ++ "\n")
      file (repository ++ "/objects/info/packs") world `shouldBe` Just B.empty
      [path' | path' <- M.keys (worldFiles world), ".initializing-" `isInfixOf` path'] `shouldBe` []
  describe "lawspec update" $ do
    it "selects the newest tagged version the range admits" $ do
      let (outcome, world) = run ["fetch", "--json"] (gitProject "2.1.0")
      (outcome, err world) `shouldBe` (Completed 0, "")
      fetched world `shouldBe` [["--git-dir", "/cache/git/" ++ hex gitRemote, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--", gitRemote, commitFor "2.1.0" ++ ":refs/lawspec/" ++ refName world]]
      out world `shouldSatisfy` ("\"tagVersion\": \"2.1.0\"" `isInfixOf`)
      out world `shouldSatisfy` (("\"commit\": \"" ++ commitFor "2.1.0" ++ "\"") `isInfixOf`)
    it "keeps the locked version on fetch and moves it on update" $ do
      let (first, locked) = run ["fetch"] pinnedProject
          -- The remote now offers 2.1.0, which only update takes.
          republished = locked {worldPrograms = [("/bin/git", git "2.1.0")], worldStdout = B.empty}
          (kept, keptWorld) = run ["fetch", "--json"] republished
          (moved, movedWorld) = run ["update", "shop.tax", "--json"] republished
      (first, err locked) `shouldBe` (Completed 0, "")
      (kept, err keptWorld) `shouldBe` (Completed 0, "")
      out keptWorld `shouldSatisfy` ("\"tagVersion\": \"2.0.0\"" `isInfixOf`)
      (moved, err movedWorld) `shouldBe` (Completed 0, "")
      out movedWorld `shouldSatisfy` ("\"tagVersion\": \"2.1.0\"" `isInfixOf`)
    it "refuses a lock that must change under --locked" $ do
      let (_, locked) = run ["fetch"] pinnedProject
          changed = withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"orders\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :dependencies {}}\n") locked
          (outcome, world) = run ["fetch", "--locked"] changed
      outcome `shouldBe` Completed 1
      err world `shouldBe` "lawspec: Lockfile is out of date; run lawspec fetch\n"
  describe "lawspec package" $ do
    let package' =
          withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1 :package {:name \"shop.tax\" :version \"2.0.0\"} :language-profile \"1.0-rc.2\" :sources [\"src\"]}\n")
            $ withFile "/p/src/rates.lawspec" (BC.pack "unit shop.tax.rates\ntype Rate is a record{percent :: Integer} end type\nend unit\n")
            $ withFile "/p/src/notes.txt" (BC.pack "not published\n") emptyWorld
    it "summarises the package's own units, laws and data types" $ do
      let (outcome, world) = run ["package"] package'
      (outcome, out world, err world)
        `shouldBe` (Completed 0, "shop.tax 2.0.0: 1 unit(s), 0 law(s), 1 data type(s).\nUnits: shop.tax.rates\nDependencies: none\n", "")
    it "writes a portable archive of the published files" $ do
      let (outcome, world) = run ["package", "--output", "dist/tax.tgz", "--json"] package'
      (outcome, err world) `shouldBe` (Completed 0, "")
      let written = file "/p/dist/tax.tgz" world
      fmap (\bytes -> map entryPath <$> (gunzip bytes >>= readTar)) written `shouldBe` Just (Right ["lawspec.edn", "src/rates.lawspec"])
      out world `shouldSatisfy` (maybe (const False) (\bytes -> isInfixOf ("\"sha256\": \"" ++ digestHex (digest bytes) ++ "\"")) written)
    it "records each file's mode as node-tar's portable mode does" $ do
      let (outcome, world) = run ["package", "--output", "dist/tax.tgz"] (withPermissions "/p/src/rates.lawspec" 0o775 package')
      (outcome, err world) `shouldBe` (Completed 0, "")
      fmap (\bytes -> map entryMode <$> (gunzip bytes >>= readTar)) (file "/p/dist/tax.tgz" world) `shouldBe` Just (Right [Just 0o644, Just 0o755])
    it "needs a package identity" $ do
      let (outcome, world) = run ["package"] (withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"c\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"src\"]}\n") package')
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: /p/lawspec.edn: expected a package identity\n")
  describe "the tar and gzip codecs" $ do
    let files = taxPackage "2.0.0" ++ [(replicate 120 'd' ++ "/" ++ replicate 60 'f' ++ ".lawspec", 0o644, BC.pack "long"), ("ünïcode.lawspec", 0o644, B.empty)]
    it "reads back what it writes" $ do
      (gunzip (gzip (writeTar files)) >>= readTar) `shouldBe` Right [Entry name RegularFile (Just (toInteger mode)) body | (name, mode, body) <- files]
    it "records and reads back each file's mode" $
      fmap (map entryMode) (readTar (writeTar [("run.sh", 0o755, B.empty), ("private", 0o600, B.empty), ("setuid", 0o4755, B.empty)])) `shouldBe` Right [Just 0o755, Just 0o600, Just 0o4755]
    it "keeps node-tar's portable mode" $
      map portableMode [0o755, 0o777, 0o775, 0o664, 0o644, 0o600, 0o700, 0o444, 0o4755, 0o100755] `shouldBe` [0o755, 0o755, 0o755, 0o644, 0o644, 0o600, 0o700, 0o644, 0o4755, 0o755]
    it "writes 512-byte blocks and ends with two zero blocks" $ do
      let archive = writeTar files
      B.length archive `mod` 512 `shouldBe` 0
      B.drop (B.length archive - 1024) archive `shouldBe` B.replicate 1024 0
    it "rejects a corrupt header and a truncated body" $ do
      let archive = writeTar (taxPackage "2.0.0")
      readTar (B.append (BC.pack "x") (B.drop 1 archive)) `shouldBe` Left "TAR_ENTRY_INVALID: checksum failure"
      readTar (B.take 600 archive) `shouldSatisfy` either ("TAR_BAD_ARCHIVE: Truncated input" `isPrefixOf`) (const False)
      readTar (B.replicate 1024 0) `shouldBe` Left "TAR_BAD_ARCHIVE: Unrecognized archive format"
    it "rejects a corrupt gzip stream" $ do
      gunzip (B.take 20 (gzip (BC.pack "contract"))) `shouldSatisfy` either (const True) (const False)
    describe "refuses unsafe entries when it unpacks" $ do
      let unsafe entry = unpackEntries "/cache/x" [Entry "lawspec.edn" RegularFile Nothing B.empty, entry]
      it "an absolute path" $ unsafe (Entry "/etc/passwd" RegularFile Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: /etc/passwd"
      it "a parent component" $ unsafe (Entry "src/../../escape" RegularFile Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: src/../../escape"
      it "a symbolic link" $ unsafe (Entry "link" SymbolicLink Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: link"
      it "a hard link" $ unsafe (Entry "hard" HardLink Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: hard"
      it "a device or a FIFO" $ do
        unsafe (Entry "dev" CharacterDevice Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: dev"
        unsafe (Entry "blk" BlockDevice Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: blk"
        unsafe (Entry "fifo" Fifo Nothing B.empty) `shouldBe` Left "Unsafe package archive entry: fifo"
      it "and names the last one" $
        unpackEntries "/cache/x" [Entry "/a" RegularFile Nothing B.empty, Entry "../b" RegularFile Nothing B.empty] `shouldBe` Left "Unsafe package archive entry: ../b"
      it "places safe entries below the directory" $
        unpackEntries "/cache/x" [Entry "src/" Directory Nothing B.empty, Entry "src/a.lawspec" RegularFile Nothing (BC.pack "a")]
          `shouldBe` Right [MakeDirectory "/cache/x/src" 0o777, MakeFile "/cache/x/src/a.lawspec" 0o666 (BC.pack "a")]
      it "with the modes node-tar's extract creates them with" $
        unpackEntries
          "/cache/x"
          [ Entry "bin/" Directory (Just 0o775) B.empty,
            Entry "locked/" Directory (Just 0o500) B.empty,
            Entry "bin/run" RegularFile (Just 0o775) B.empty,
            Entry "bin/setuid" RegularFile (Just 0o4755) B.empty,
            Entry "none" RegularFile (Just 0) B.empty,
            Entry "bin/run" RegularFile (Just 0o600) (BC.pack "again")
          ]
          `shouldBe` Right
            [ MakeDirectory "/cache/x/bin" 0o775,
              MakeDirectory "/cache/x/locked" 0o700,
              MakeFile "/cache/x/bin/run" 0o775 B.empty,
              MakeFile "/cache/x/bin/setuid" 0o4755 B.empty,
              MakeFile "/cache/x/none" 0 B.empty,
              MakeFile "/cache/x/bin/run" 0o775 (BC.pack "again")
            ]
    it "refuses an unsafe entry in a downloaded archive and removes the unpacked files" $ do
      let hostile = gzip (writeTar (taxPackage "2.0.0" ++ [("../escape.lawspec", 0o644, BC.pack "x")]))
          sha = digestHex (digest hostile)
          world0 = (archiveProject sha) {worldResponses = [(archiveUrl, FetchResponse 200 [] hostile)]}
          (outcome, world) = run ["fetch"] world0
      (outcome, err world) `shouldBe` (Completed 1, "lawspec: Unsafe package archive entry: ../escape.lawspec\n")
      [path' | path' <- M.keys (worldFiles world), "/cache/" `isPrefixOf` path' || "escape" `isInfixOf` path'] `shouldBe` []
  where
    -- The temporary ref the fetch named, which is the digest of its source.
    refName world = case fetched world of
      arguments : _ | not (null arguments) -> drop (length ("refs/lawspec/" :: String)) (drop 1 (dropWhile (/= ':') (last arguments)))
      _ -> ""
