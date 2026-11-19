-- | The Canon for a host that ships none (the Go host, whose module would
-- otherwise carry four executables of some 45 MB each): the core downloads
-- this release's @goforgedev/canon-<platform> npm tarball, the package
-- tools/package-canon.sh packs from the Canon bundle and the Node host
-- installs, checks it against the SHA-256 this build records
-- ("LawSpec.App.CanonPackages"), and unpacks it into the host's cache
-- directory, where later runs find it. The host only names its platform and
-- cache directory; the URL, the digest, the check and the unpacking are
-- here.
--
-- Nothing is downloaded until a command needs Canon: lawspec project init or
-- adopt in a project without canon.yaml, and status or validate without
-- CANON. A tarball whose digest differs from the recorded one, or a
-- platform this build records no digest for, is refused before anything is
-- unpacked. LAWSPEC_CANON_REGISTRY names another HTTPS registry (a mirror);
-- the recorded digest still applies, so it
-- changes where the bytes come from, never which bytes run.
--
-- Trust boundary: the cache entry is checked on reuse by its marker (the
-- tarball digest it was unpacked from, which must be this build's) and the
-- executable's size, not by hashing the executable again; an entry that
-- fails either is downloaded again. The cache directory is the user's, as
-- Go's module cache is.
-- ref:DEC-native-canon
module LawSpec.App.CanonDownload
  ( resolveCanon,
    downloadCanon,
    canonPackageUrl,
    defaultRegistry,
  )
where

import Control.Monad (unless, when)
import Data.Version (showVersion)
import LawSpec.App.CanonPackages (canonPackageDigests, canonPackagesVersion)
import LawSpec.App.Command
import LawSpec.App.Files (atomicWrite, readOptional)
import LawSpec.App.Packages (archiveEntries, download, freshDirectory, renameInto)
import LawSpec.App.Project (environment)
import LawSpec.Archive.Tar (Unpacked (..))
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join)
import Paths_lawspec (version)

-- | The Canon a project command runs: the one the host ships, or this
-- release's package, downloaded into the host's cache when it is not there
-- already.
resolveCanon :: (Monad m) => CanonSource -> Command m CanonTool
resolveCanon (CanonShipped tool) = pure tool
resolveCanon (CanonDownload platform cache) =
  downloadCanon (canonPackagesVersion, canonPackageDigests) (showVersion version) platform cache

-- | The npm registry the packages are published to.
defaultRegistry :: String
defaultRegistry = "https://registry.npmjs.org"

-- | The tarball URL npm gives a scoped package's version.
canonPackageUrl :: String -> String -> String -> String
canonPackageUrl registry platform release =
  stripSlashes registry ++ "/@goforgedev/canon-" ++ platform ++ "/-/canon-" ++ platform ++ "-" ++ release ++ ".tgz"
  where
    stripSlashes = reverse . dropWhile (== '/') . reverse

-- | 'resolveCanon' with the recorded digests (the version they were packed
-- for and each platform's) and the running release given, so tests can
-- name their own.
downloadCanon :: (Monad m) => (String, [(String, String)]) -> String -> String -> FilePath -> Command m CanonTool
downloadCanon (recordedVersion, digests) release platform cache = do
  unless (platform `elem` map fst digests) $
    failWith ("No Canon is published for " ++ platform ++ "; set CANON to a canon executable, or give the host a Canon bundle.")
  expected <- case lookup platform digests of
    Just value | recordedVersion == release, hex64 value -> pure value
    _ ->
      failWith
        ( "This build of LawSpec "
            ++ release
            ++ " records no digest for @goforgedev/canon-"
            ++ platform
            ++ ", so it does not download Canon; set CANON to a canon executable, or give the host a Canon bundle."
        )
  registry <- maybe defaultRegistry (\value -> if null value then defaultRegistry else value) <$> environment "LAWSPEC_CANON_REGISTRY"
  let root = join cache "canon"
      parent = join root release
      directory = join parent platform
      marker = directory ++ ".sha256"
      executable = join directory "canon"
      tool = CanonTool [executable] (join directory "presets")
      url = canonPackageUrl registry platform release
  grantWrite [root]
  reusable <- verified marker executable expected
  unless reusable $ do
    -- A stale or damaged entry goes first; the marker with it, so a failure
    -- below never leaves an entry that looks verified.
    _ <- effectOr (Remove NotRecursive marker)
    _ <- effectOr (Remove Recursive directory)
    bytes <- download url
    let actual = digestHex (digest bytes)
    when (actual /= expected) $
      failWith ("Canon package SHA-256 mismatch: " ++ url ++ " is " ++ actual ++ ", but this build of LawSpec records " ++ expected)
    effect (nodeFailure "mkdir" parent) (MakeDirectories Nothing parent)
    staging <- freshDirectory parent (".canon-" ++ platform ++ "-")
    outcome <-
      recover
        ( Right <$> do
            archiveEntries bytes staging >>= mapM_ place
            -- npm packs a package's files under package/.
            renameInto [AlreadyExists, DirectoryNotEmpty] (join staging "package") directory
        )
        (pure . Left)
    _ <- removeCreated Recursive staging
    either abort pure outcome
    size <- executableSize executable
    case size of
      Just bytes' -> atomicWrite marker (expected ++ " " ++ show bytes' ++ "\n") False
      Nothing -> failWith ("The Canon package from " ++ url ++ " holds no canon executable")
    placed <- verified marker executable expected
    unless placed (failWith ("The Canon unpacked from " ++ url ++ " does not match its marker"))
  grantRead [directory]
  pure tool
  where
    hex64 text = length text == 64 && all (`elem` ("0123456789abcdef" :: String)) text
    place = \case
      MakeDirectory path' bits -> effect (nodeFailure "mkdir" path') (MakeDirectories (Just bits) path')
      MakeFile path' bits bytes -> effect (nodeFailure "open" path') (WriteFile Replace (Just bits) path' bytes)

-- | A cache entry this build may run: its marker names the expected tarball
-- digest and the size the executable had when it was unpacked.
verified :: (Monad m) => FilePath -> FilePath -> String -> Command m Bool
verified marker executable expected = do
  recorded <- readOptional marker
  case words <$> recorded of
    Just [digest', size] | digest' == expected -> do
      actual <- executableSize executable
      pure (fmap show actual == Just size)
    _ -> pure False

-- | The size of a regular file, if there is one.
executableSize :: (Monad m) => FilePath -> Command m (Maybe Integer)
executableSize path' =
  effectOr (Stat NoFollow path') >>= \case
    Right status | statusKind status == FileKind -> pure (Just (statusSize status))
    _ -> pure Nothing
