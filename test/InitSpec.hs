-- | lawspec init over the in-memory host: the manifest, the starter
-- specification and the scaffold for a new project, the settings added to
-- an existing JSON build file, and the dependency step's failure.
-- tools/host-parity.mjs compares the same commands with the legacy CLI.
-- ref:DEC-haskell-application-port ref:DEC-init-prepares-project
module InitSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.Init (starterSpecification)
import LawSpec.App.Main
import LawSpec.Host.Fake
import Test.Hspec

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/w/p" Nothing Nothing Nothing Nothing))

out, err :: World -> String
out = BC.unpack . worldStdout
err = BC.unpack . worldStderr

file :: FilePath -> World -> Maybe String
file path' world = case M.lookup path' (worldFiles world) of
  Just (FileNode bytes) -> Just (BC.unpack bytes)
  _ -> Nothing

empty :: World
empty = withDirectory "/w/p" emptyWorld {worldEnvironment = [("PATH", "/nowhere")]}

spec :: Spec
spec = describe "lawspec init" $ do
  it "embeds the starter specification the npm package ships" $ do
    shipped <- readFile "templates/npm/starter-rc1.lawspec"
    starterSpecification `shouldBe` shipped
  it "creates the manifest, the starter and an artifact target's scaffold" $ do
    let (outcome, world) = run ["init", "--target", "yaml", "--no-install"] empty
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldSatisfy` ("Configured yaml. Created missing project build files.\nGenerate YAML 1.2 configuration" `isPrefixOf`)
    out world `shouldSatisfy` ("\nNext: lawspec doctor, then lawspec generate.\n" `isInfixOf`)
    file "/w/p/lawspec.edn" world
      `shouldBe` Just "{\n  :manifest-version 1\n  :component {\n    :name \"p\"\n    :version \"0.1.0\"\n  }\n  :language-profile \"1.0-rc.2\"\n  :verification {\n    :layers []\n  }\n  :sources [\"laws\"]\n  :targets [\n    {\n      :language :yaml\n      :root \".\"\n    }\n  ]\n}\n"
    fmap ("unit configuration\n" `isPrefixOf`) (file "/w/p/laws/atoi_codec.lawspec" world) `shouldBe` Just True
    -- The starter is already in canonical format.
    let (formatted, world') = run ["fmt", "--check"] world {worldStdout = B.empty}
    (formatted, out world') `shouldBe` (Completed 0, "All sources are formatted.\n")
  it "scaffolds a program target in its own root with the starter specification" $ do
    let (outcome, world) = run ["init", "--target", "javascript", "--project", "web", "--no-install", "--machine-bits", "32"] empty
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldSatisfy` ("Configured javascript. Created missing project build files.\nProject name: p (from the directory name).\n" `isPrefixOf`)
    file "/w/p/laws/atoi_codec.lawspec" world `shouldBe` Just starterSpecification
    fmap ("\"type\": \"module\"" `isInfixOf`) (file "/w/p/web/package.json" world) `shouldBe` Just True
    fmap (":machine-bits 32\n" `isInfixOf`) (file "/w/p/lawspec.edn" world) `shouldBe` Just True
    fmap (":root \"web\"" `isInfixOf`) (file "/w/p/lawspec.edn" world) `shouldBe` Just True
    -- Running it again changes nothing.
    let (again, world') = run ["init", "--target", "javascript", "--project", "web", "--no-install"] world {worldStdout = B.empty}
    (again, err world') `shouldBe` (Completed 0, "")
    out world' `shouldSatisfy` ("Configured javascript. Existing build files preserved.\n" `isPrefixOf`)
    worldFiles world' `shouldBe` worldFiles world
  it "adds the settings an existing package.json lacks, in its own indentation" $ do
    let existing = withFile "/w/p/package.json" (BC.pack "{\n    \"name\": \"web\",\n    \"type\": \"commonjs\"\n}\n") empty
        (outcome, world) = run ["init", "--target", "javascript", "--no-install"] existing
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldSatisfy` ("Configured javascript. Existing build files preserved; updated package.json (type, devDependencies.fast-check).\n" `isPrefixOf`)
    fmap (take 4 . lines) (file "/w/p/package.json" world) `shouldBe` Just ["{", "    \"name\": \"web\",", "    \"type\": \"module\",", "    \"devDependencies\": {"]
    fmap (("        \"fast-check\": \"" `isPrefixOf`) . (!! 4) . lines) (file "/w/p/package.json" world) `shouldBe` Just True
  it "keeps type=commonjs when a source depends on it" $ do
    let existing =
          withFile "/w/p/lib/index.js" (BC.pack "module.exports = 1;\n") $
            withFile "/w/p/package.json" (BC.pack "{\"name\":\"web\",\"type\":\"commonjs\"}") empty
        (outcome, world) = run ["init", "--target", "javascript", "--no-install"] existing
    outcome `shouldBe` Completed 1
    err world `shouldSatisfy` ("lawspec: package.json sets type=commonjs and lib/index.js depends on it." `isPrefixOf`)
    file "/w/p/lawspec.edn" world `shouldBe` Nothing
  it "checks the target and the manifest" $ do
    let failed arguments world = let (outcome, after) = run arguments world in (outcome, err after)
    failed ["init"] empty `shouldSatisfy` (\(outcome, message) -> outcome == Completed 1 && "lawspec: Choose --target java|python|" `isPrefixOf` message)
    failed ["init", "--target", "yaml"] (withFile "/w/p/lawspec.json" (BC.pack "{}") empty)
      `shouldBe` (Completed 1, "lawspec: lawspec.json is no longer supported; use lawspec.edn\n")
    let several = withFile "/w/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"s\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :yaml :root \"a\"} {:language :yaml :root \"b\"}]}\n") empty
    failed ["init", "--target", "yaml"] several `shouldBe` (Completed 1, "lawspec: Several yaml targets are configured; choose the root with --project\n")
  it "reports a target whose build tool is missing as not ready" $ do
    let (outcome, world) = run ["init", "--target", "go"] empty
    outcome `shouldBe` Completed 1
    out world `shouldSatisfy` ("\ngo is not ready: go was not found on PATH; searched /nowhere; install Go or add its directory to PATH\n" `isInfixOf`)
    out world `shouldSatisfy` ("Correct this and run lawspec init --target go again, or lawspec doctor to check.\n" `isInfixOf`)
    fmap ("module " `isPrefixOf`) (file "/w/p/go.mod" world) `shouldBe` Just True
