-- | The Canon a host without one of its own has the core download: this
-- release's @goforgedev/canon-<platform> tarball, checked against the digest
-- the build records, unpacked into the host's cache and reused from there;
-- refused when the digest differs or none is recorded.
-- ref:DEC-native-canon
module CanonDownloadSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.CanonDownload (canonPackageUrl, defaultRegistry, downloadCanon)
import LawSpec.App.Command
import LawSpec.App.Main
import LawSpec.Archive.Deflate (gzip)
import LawSpec.Archive.Tar (writeTar)
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Fake
import Test.Hspec

-- | An npm tarball of the package: its files under package/.
package :: B.ByteString -> B.ByteString
package executable =
  gzip
    ( writeTar
        [ ("package/canon", 0o755, executable),
          ("package/canon.json", 0o644, BC.pack "{\"canon\": \"0.2.3\"}\n"),
          ("package/presets/languages.json", 0o644, BC.pack "{}\n"),
          ("package/package.json", 0o644, BC.pack "{\"name\": \"@goforgedev/canon-linux-x64\"}\n")
        ]
    )

tarball :: B.ByteString
tarball = package (BC.pack "#!/bin/sh\necho canon 0.2.3\n")

sha :: B.ByteString -> String
sha = digestHex . digest

url :: String
url = canonPackageUrl defaultRegistry "linux-x64" "0.34.0"

pins :: String -> (String, [(String, String)])
pins value = ("0.34.0", [("linux-x64", value), ("darwin-arm64", "")])

world :: World
world = withDirectory "/home/u/.cache/lawspec" emptyWorld {worldResponses = [(url, FetchResponse 200 [] tarball)]}

-- | downloadCanon over the fake host, as a project command runs it.
resolve' :: (String, [(String, String)]) -> String -> World -> (Either String CanonTool, World)
resolve' recorded platform world0 =
  let ((result, _), world1) =
        runFake
          (runCommand (newSession fakeHost pureCompiler) (downloadCanon recorded "0.34.0" platform "/home/u/.cache/lawspec"))
          world0
   in (either (Left . show) Right result, world1)

entry :: FilePath
entry = "/home/u/.cache/lawspec/canon/0.34.0/linux-x64"

file :: FilePath -> World -> Maybe B.ByteString
file path' world' = case M.lookup path' (worldFiles world') of
  Just (FileNode bytes) -> Just bytes
  _ -> Nothing

fetches :: World -> [String]
fetches world' = [fetchUrl request | SomeEffect (Fetch request) <- worldTrace world']

spec :: Spec
spec = describe "the Canon a host without one downloads" $ do
  it "names the package's npm tarball" $
    url `shouldBe` "https://registry.npmjs.org/@goforgedev/canon-linux-x64/-/canon-linux-x64-0.34.0.tgz"
  it "downloads, verifies and unpacks this release's package into the cache" $ do
    let (result, world') = resolve' (pins (sha tarball)) "linux-x64" world
    result `shouldBe` Right (CanonTool [entry ++ "/canon"] (entry ++ "/presets"))
    file (entry ++ "/canon") world' `shouldBe` Just (BC.pack "#!/bin/sh\necho canon 0.2.3\n")
    file (entry ++ "/presets/languages.json") world' `shouldBe` Just (BC.pack "{}\n")
    file (entry ++ ".sha256") world' `shouldBe` Just (BC.pack (sha tarball ++ " 27\n"))
    fetches world' `shouldBe` [url]
    -- No staging directory is left behind.
    [path' | path' <- M.keys (worldFiles world'), ".canon-" `isInfixOf` path'] `shouldBe` []
  it "reuses a verified cache entry without downloading again" $ do
    let (_, placed) = resolve' (pins (sha tarball)) "linux-x64" world
        (result, world') = resolve' (pins (sha tarball)) "linux-x64" placed {worldTrace = []}
    result `shouldBe` Right (CanonTool [entry ++ "/canon"] (entry ++ "/presets"))
    fetches world' `shouldBe` []
  it "downloads a damaged cache entry again" $ do
    let (_, placed) = resolve' (pins (sha tarball)) "linux-x64" world
        damaged = withFile (entry ++ "/canon") (BC.pack "#!/bin/sh\necho evil\n") placed {worldTrace = []}
        (result, world') = resolve' (pins (sha tarball)) "linux-x64" damaged
    result `shouldBe` Right (CanonTool [entry ++ "/canon"] (entry ++ "/presets"))
    fetches world' `shouldBe` [url]
    file (entry ++ "/canon") world' `shouldBe` Just (BC.pack "#!/bin/sh\necho canon 0.2.3\n")
  it "refuses a tarball whose digest is not the recorded one, unpacking nothing" $ do
    let (result, world') = resolve' (pins (sha (package (BC.pack "other")))) "linux-x64" world
    either id (const "") result `shouldSatisfy` ("Canon package SHA-256 mismatch" `isInfixOf`)
    M.member entry (worldFiles world') `shouldBe` False
    file (entry ++ ".sha256") world' `shouldBe` Nothing
  it "downloads nothing for a platform this build records no digest for" $ do
    let (result, world') = resolve' (pins (sha tarball)) "darwin-arm64" world
    either id (const "") result `shouldSatisfy` ("records no digest for @goforgedev/canon-darwin-arm64" `isInfixOf`)
    fetches world' `shouldBe` []
  it "downloads nothing when the digests were recorded for another release" $ do
    let (result, world') = resolve' ("0.33.0", snd (pins (sha tarball))) "linux-x64" world
    either id (const "") result `shouldSatisfy` ("records no digest" `isInfixOf`)
    fetches world' `shouldBe` []
  it "takes the tarball from LAWSPEC_CANON_REGISTRY, still checked against the recorded digest" $ do
    let mirror = canonPackageUrl "https://mirror.example/npm/" "linux-x64" "0.34.0"
        mirrored = world {worldEnvironment = [("LAWSPEC_CANON_REGISTRY", "https://mirror.example/npm/")], worldResponses = [(mirror, FetchResponse 200 [] tarball)]}
        (result, world') = resolve' (pins (sha tarball)) "linux-x64" mirrored
    result `shouldBe` Right (CanonTool [entry ++ "/canon"] (entry ++ "/presets"))
    fetches world' `shouldBe` ["https://mirror.example/npm/@goforgedev/canon-linux-x64/-/canon-linux-x64-0.34.0.tgz"]
  it "reports Canon incomplete in project status when it cannot download one" $ do
    let project = withFile "/w/p/canon.yaml" (BC.pack "canon: 0.2.3\n") (withFile "/w/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets []}\n") world)
        (_, world') = runFake (lawspecMain fakeHost pureCompiler (Invocation ["project", "status", "--json"] "/w/p" Nothing Nothing Nothing (Just (CanonDownload "linux-x64" "/home/u/.cache/lawspec")))) project
    -- With this build's digests recorded the download is attempted and the
    -- in-memory host answers no fetch; without them nothing is fetched.
    -- Either way Canon is incomplete, never skipped.
    BC.unpack (worldStdout world') `shouldSatisfy` (\out -> "\"canon\": {\n    \"status\": \"incomplete\"" `isInfixOf` out && any (`isInfixOf` out) ["records no digest for @goforgedev/canon-linux-x64", "fetch failed"])
