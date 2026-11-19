-- | lawspec project and lawspec examples over the in-memory host: adopting
-- a project Canon is set up in, setting Canon up with the presets the host
-- ships, the checks made before anything is written, status and validate
-- with Canon absent, with the Canon the host ships and with a canon
-- executable named by CANON, and the bundled examples embedded in the
-- core. tools/host-parity.mjs compares the same commands with the legacy
-- CLI.
-- ref:DEC-haskell-application-port ref:DEC-native-canon
module ProjectSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.ExampleSources (exampleSpecifications, paymentsProjects, paymentsSpecification)
import LawSpec.App.Main
import LawSpec.App.Json (parseJson)
import LawSpec.App.ProjectCommand (canonExpectedVersion, canonReportedVersion, projectExitCode)
import LawSpec.Host.Effect
import LawSpec.Host.Fake
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/w/p" Nothing Nothing Nothing Nothing))

-- | A run on a host that ships a Canon.
runShipped :: CanonTool -> [String] -> World -> (Outcome, World)
runShipped tool arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/w/p" Nothing Nothing Nothing (Just (CanonShipped tool))))

-- | The Canon a host ships: the native executable, or Node running the
-- ricestax package's CLI with canon, both with these presets.
nativeCanon, ricestaxCanon :: CanonTool
nativeCanon = CanonTool ["/opt/canon/canon"] "/opt/canon/presets"
ricestaxCanon = CanonTool ["/opt/node", "/opt/ricestax/bin/ricestax.mjs", "canon"] "/opt/canon/presets"

-- | A small presets folder in ricestax@0.4.3's layout.
presetsCatalog :: String
presetsCatalog =
  "{\n  \"go\": {\"extensions\": [\".go\"], \"lexer\": \".ricestax/grammars/golang/GoLexer.g4\"},\n  \"folio\": {\"extensions\": [\".md\"], \"embeds\": {\"go\": {\"language\": \"go\"}, \"calm\": {\"language\": \"calm\"}}, \"start\": \"document\"},\n  \"calm\": {\"extensions\": [\".calm.json\"]}\n}\n"

shipped :: World -> World
shipped world =
  foldr
    (\(path', content) -> text path' content)
    world {worldPrograms = [("/opt/canon/canon", canon "0.1.0" . dropLeading 0), ("/opt/node", canon "0.1.0" . dropLeading 2)]}
    [ ("/opt/canon/presets/languages.json", presetsCatalog),
      ("/opt/canon/presets/provenance.json", "{\"canonCommit\": \"f639753\"}\n"),
      ("/opt/canon/presets/CANON-LICENSE", "MIT License\n"),
      ("/opt/canon/presets/grammars/golang/GoLexer.g4", "lexer grammar GoLexer;\n"),
      ("/opt/canon/presets/grammars/folio/FolioParser.g4", "parser grammar FolioParser;\n"),
      ("/opt/canon/canon", ""),
      ("/opt/node", ""),
      ("/opt/ricestax/bin/ricestax.mjs", "")
    ]
  where
    -- The fake canon answers by its first argument after the program, so
    -- Node's script and canon verb are taken off first.
    dropLeading n request = request {spawnArguments = take 1 (spawnArguments request) ++ drop (n + 1) (spawnArguments request)}

-- | The files of a world under a folder, by path.
filesUnder :: FilePath -> World -> [(FilePath, String)]
filesUnder folder world = [(path', BC.unpack bytes) | (path', FileNode bytes) <- M.toList (worldFiles world), (folder ++ "/") `isPrefixOf` path']

out, err :: World -> String
out = BC.unpack . worldStdout
err = BC.unpack . worldStderr

file :: FilePath -> World -> Maybe String
file path' world = case M.lookup path' (worldFiles world) of
  Just (FileNode bytes) -> Just (BC.unpack bytes)
  _ -> Nothing

empty :: World
empty = withDirectory "/w/p" emptyWorld {worldEnvironment = [("PATH", "/nowhere")]}

text :: FilePath -> String -> World -> World
text path' content = withFile path' (BC.pack content)

specsManifest :: String
specsManifest = "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :verification {:layers [:exhaustive]}}\n"

-- | A canon executable at /w/p/canon: its version, and check or decisions.
canon :: String -> Program
canon version request = case drop 1 (spawnArguments request) of
  ["version"] -> Just (0, BC.pack ("canon " ++ version ++ "\n"), BC.empty)
  ["check"] -> Just (0, BC.pack "{\"findings\": []}\n", BC.empty)
  ["decisions"] -> Just (2, BC.pack "2 open decisions\n", BC.pack "review needed\n")
  _ -> Just (1, BC.empty, BC.empty)

withCanon :: String -> World -> World
withCanon version world =
  (text "/w/p/canon" "" world)
    { worldEnvironment = ("CANON", "./canon") : worldEnvironment world,
      worldPrograms = [("/w/p/canon", canon version)]
    }

-- | A folder's files by relative path, in readdir order (each directory's
-- entries sorted, a folder's files at its place).
folderFiles :: FilePath -> IO [(FilePath, String)]
folderFiles directory = go directory ""
  where
    go folder prefix = do
      entries <- sort <$> listDirectory folder
      concat
        <$> mapM
          ( \name -> do
              let path' = folder </> name
              isDirectory <- doesDirectoryExist path'
              if isDirectory then go path' (prefix ++ name ++ "/") else (\content -> [(prefix ++ name, content)]) <$> readFile path'
          )
          entries

spec :: Spec
spec = describe "lawspec project and lawspec examples" $ do
  it "adopts a project Canon is set up in: the manifest and a starter unit" $ do
    let (outcome, world) = run ["project", "adopt"] (text "/w/p/canon.yaml" "{}\n" empty)
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldBe` "LawSpec created; Canon preserved in /w/p. Add an application with lawspec init --target <language>.\n"
    file "/w/p/laws/project.lawspec" world `shouldBe` Just "unit project\nend unit\n"
    fmap (":name \"p\"" `isInfixOf`) (file "/w/p/lawspec.edn" world) `shouldBe` Just True
    let (again, world') = run ["project", "adopt", "--json"] world {worldStdout = BC.empty}
    again `shouldBe` Completed 0
    out world' `shouldSatisfy` ("{\n  \"root\": \"/w/p\",\n  \"manifest\": \"preserved\",\n  \"canon\": \"preserved\",\n  \"canonSetup\": \"ricestax@0.4.3\"," `isPrefixOf`)
    worldFiles world' `shouldBe` worldFiles world
  it "checks the project before anything is written" $ do
    let failed arguments world = let (outcome, after) = run arguments world in (outcome, err after, worldFiles after == worldFiles world)
    failed ["project", "init"] (text "/w/p/canon.yaml" "{}\n" empty)
      `shouldBe` (Completed 1, "lawspec: Project metadata already exists; use lawspec project adopt\n", True)
    failed ["project", "adopt"] (text "/w/p/lawspec.json" "{}\n" empty)
      `shouldBe` (Completed 1, "lawspec: lawspec.json is no longer supported; use lawspec.edn\n", True)
    failed ["project", "init"] (text "/w/p/.ricestax/languages.json" "{}\n" empty)
      `shouldBe` (Completed 1, "lawspec: .ricestax exists without canon.yaml; review the incomplete Canon setup\n", True)
  it "sets Canon up with the presets the host ships, as ricestax@0.4.3's setup does" $ do
    let (outcome, world) = runShipped nativeCanon ["project", "init"] (shipped empty)
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldBe` "LawSpec created; Canon created in /w/p. Add an application with lawspec init --target <language>.\n"
    filesUnder "/w/p/.ricestax" world
      `shouldBe` [ ("/w/p/.ricestax/CANON-LICENSE", "MIT License\n"),
                   ("/w/p/.ricestax/grammars/folio/FolioParser.g4", "parser grammar FolioParser;\n"),
                   ("/w/p/.ricestax/grammars/golang/GoLexer.g4", "lexer grammar GoLexer;\n"),
                   ("/w/p/.ricestax/languages.json", "{\n  \"package\": \"ricestax\",\n  \"profiles\": [\n    \"folio\"\n  ]\n}\n"),
                   ("/w/p/.ricestax/provenance.json", "{\"canonCommit\": \"f639753\"}\n")
                 ]
    -- Folio embeds only the languages chosen: none here.
    file "/w/p/canon.yaml" world
      `shouldBe` Just "{\n  \"version\": \"0.1.0\",\n  \"ignore\": [\n    \".ricestax\",\n    \"node_modules\",\n    \"target\",\n    \"build\",\n    \"dist\",\n    \".venv\",\n    \"__pycache__\"\n  ],\n  \"languages\": {\n    \"folio\": {\n      \"extensions\": [\n        \".md\"\n      ],\n      \"embeds\": {},\n      \"start\": \"document\"\n    }\n  }\n}\n"
    map (`file` world) ["/w/p/canonical_decisions.yaml", "/w/p/canonical_refs.yaml", "/w/p/canonical_exemptions.yaml"] `shouldBe` replicate 3 (Just "{}\n")
    file "/w/p/laws/project.lawspec" world `shouldBe` Just "unit project\nend unit\n"
    [path' | path' <- M.keys (worldFiles world), ".ricestax-init-" `isInfixOf` path'] `shouldBe` []
  it "sets up the languages chosen, each once, with Folio embedding only those" $ do
    let project = text "/w/p/canonical_refs.yaml" "refs: []\n" (shipped empty)
        (outcome, world) = runShipped nativeCanon ["project", "adopt", "--languages", "go,folio,go", "--json"] project
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldSatisfy` ("\"canon\": \"created\",\n  \"canonSetup\": \"ricestax@0.4.3\"" `isInfixOf`)
    file "/w/p/.ricestax/languages.json" world `shouldBe` Just "{\n  \"package\": \"ricestax\",\n  \"profiles\": [\n    \"go\",\n    \"folio\"\n  ]\n}\n"
    fmap (\config -> ("\"embeds\": {\n        \"go\": {\n          \"language\": \"go\"\n        }\n      }" `isInfixOf` config, "calm" `isInfixOf` config)) (file "/w/p/canon.yaml" world)
      `shouldBe` Just (True, False)
    -- An existing ledger is never replaced.
    file "/w/p/canonical_refs.yaml" world `shouldBe` Just "refs: []\n"
  it "refuses an unknown language or a host without Canon before writing Canon's files" $ do
    let (unknown, world) = runShipped nativeCanon ["project", "init", "--languages", "go,cobol"] (shipped empty)
    (unknown, err world) `shouldBe` (Completed 1, "lawspec: Unknown language: cobol\n")
    filesUnder "/w/p" world `shouldBe` []
    let (missing, world') = run ["project", "init"] empty
    (missing, err world')
      `shouldBe` (Completed 1, "lawspec: Setting Canon up needs the Canon LawSpec ships (canon 0.2.3 with the ricestax@0.4.3 presets), which this installation lacks. Install LawSpec with its Canon for this platform.\n")
    worldFiles world' `shouldBe` worldFiles empty
  it "reports status with Canon absent, the definitions and the verification selected" $ do
    let project = text "/w/p/laws/a.lawspec" "unit a\nend unit\n" (text "/w/p/lawspec.edn" specsManifest empty)
        (outcome, world) = run ["project", "status"] project
    (outcome, err world) `shouldBe` (Completed 2, "")
    lines (out world) `shouldSatisfy` \rows -> case rows of
      [canonRow, definitions, verification] ->
        canonRow == "canon: {\"status\":\"incomplete\",\"detail\":\"No canon.yaml; run lawspec project adopt\"}"
          && definitions == "definitions: {\"status\":\"passed\",\"diagnostics\":[]}"
          && "verification: {\"layers\":[\"exhaustive\"],\"status\":\"not-verified\"" `isPrefixOf` verification
      _ -> False
    let (validated, world') = run ["project", "validate", "--json"] project
    validated `shouldBe` Completed 2
    out world' `shouldSatisfy` ("\"native\": {\n    \"status\": \"incomplete\",\n    \"detail\": \"Selected execution layers have no application target\"\n  }\n}\n" `isInfixOf`)
  it "runs the canon executable CANON names" $ do
    let project = withCanon "0.2.3" (text "/w/p/canon.yaml" "canon: \"0.2.x\"\n" (text "/w/p/laws/a.lawspec" "unit a\nend unit\n" (text "/w/p/lawspec.edn" specsManifest empty)))
        (outcome, world) = run ["project", "status"] project
    outcome `shouldBe` Completed 2
    take 1 (lines (out world))
      `shouldBe` ["canon: {\"status\":\"incomplete\",\"exitCode\":2,\"output\":\"2 open decisions\\n\",\"detail\":\"review needed\\n\",\"version\":\"0.2.3\"}"]
    let (validated, world') = run ["project", "validate"] project
    validated `shouldBe` Completed 2
    take 1 (lines (out world')) `shouldBe` ["canon: {\"status\":\"passed\",\"exitCode\":0,\"result\":{\"findings\":[]},\"version\":\"0.2.3\"}"]
    let (_, old) = run ["project", "status"] (withCanon "0.1.9" project)
    take 1 (lines (out old))
      `shouldBe` ["canon: {\"status\":\"incomplete\",\"expectedVersion\":\"0.2.x\",\"actualVersion\":\"0.1.9\",\"detail\":\"Canon version unavailable or incompatible. Set CANON to the matching native executable; existing metadata is preserved.\"}"]
  it "runs the Canon the host ships without CANON, and CANON instead of it" $ do
    let project = text "/w/p/canon.yaml" "{}\n" (text "/w/p/laws/a.lawspec" "unit a\nend unit\n" (text "/w/p/lawspec.edn" specsManifest (shipped empty)))
        canonRow tool arguments world = take 1 (lines (out (snd (runShipped tool arguments world))))
    canonRow nativeCanon ["project", "status"] project
      `shouldBe` ["canon: {\"status\":\"incomplete\",\"exitCode\":2,\"output\":\"2 open decisions\\n\",\"detail\":\"review needed\\n\",\"version\":\"0.1.0\"}"]
    -- Node running the ricestax package's CLI, the legacy CLI's way.
    canonRow ricestaxCanon ["project", "validate"] project
      `shouldBe` ["canon: {\"status\":\"passed\",\"exitCode\":0,\"result\":{\"findings\":[]},\"version\":\"0.1.0\"}"]
    canonRow nativeCanon ["project", "status"] (withCanon "0.2.3" project)
      `shouldBe` ["canon: {\"status\":\"incomplete\",\"exitCode\":2,\"output\":\"2 open decisions\\n\",\"detail\":\"review needed\\n\",\"version\":\"0.2.3\"}"]
    -- Without either, Canon is incomplete and the rest is still reported.
    let (outcome, world) = run ["project", "status"] (text "/w/p/canon.yaml" "{}\n" (text "/w/p/laws/a.lawspec" "unit a\nend unit\n" (text "/w/p/lawspec.edn" specsManifest empty)))
    outcome `shouldBe` Completed 2
    take 2 (lines (out world))
      `shouldBe` [ "canon: {\"status\":\"incomplete\",\"detail\":\"Checking Canon needs the Canon LawSpec ships (canon 0.2.3 with the ricestax@0.4.3 presets), which this installation lacks. Install LawSpec with its Canon for this platform, or set CANON to a matching canon executable.\"}",
                   "definitions: {\"status\":\"passed\",\"diagnostics\":[]}"
                 ]
  it "runs lawspec prove in this process for validate's proof row" $ do
    let project = text "/w/p/laws/a.lawspec" "unit a\nend unit\n" (text "/w/p/lawspec.edn" specsManifest empty)
        proof = text "/w/p/lawspec.edn" "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :verification {:layers [:proof]}}\n" project
        (outcome, world) = run ["project", "validate", "--json"] proof
    outcome `shouldSatisfy` \case
      Completed _ -> True
      _ -> False
    err world `shouldBe` ""
    out world `shouldSatisfy` ("\n  \"proof\": {\n    \"status\": " `isInfixOf`)
    fst (run ["project", "status"] proof) `shouldBe` Completed 2
    -- Definitions that fail skip the row.
    let (_, broken) = run ["project", "validate", "--json"] (text "/w/p/laws/b.lawspec" "unit b\nf :: \nend unit\n" proof)
    out broken `shouldSatisfy` (not . ("\n  \"proof\": {" `isInfixOf`))
  it "runs lawspec test in this process for validate's native row" $ do
    let project =
          text "/w/p/laws/a.lawspec" "unit a\nend unit\n" $
            text "/w/p/lawspec.edn" "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :go :root \".\"}] :verification {:layers [:property]}}\n" empty
        (outcome, world) = run ["project", "validate"] project
    -- Canon is absent, so the report is incomplete; the unit has no laws,
    -- so lawspec test selects no native check and passes.
    (outcome, err world) `shouldBe` (Completed 2, "")
    drop 3 (lines (out world)) `shouldSatisfy` \case
      [native] -> "native: {\"status\":\"passed\",\"exitCode\":0,\"result\":[{\"target\":\"go\",\"root\":\".\",\"seed\":" `isPrefixOf` native
      _ -> False
  -- From npm/test/project.test.mjs (0.36.0).
  it "never passes unsupported or incomplete evidence, and fails a failed definition" $ do
    let code = projectExitCode . either error id . parseJson
    [code ("{\"verification\": {\"evidence\": [{\"status\": \"" ++ status ++ "\"}]}}") | status <- ["unsupported", "unknown", "incomplete", "pending"]]
      `shouldBe` [2, 2, 2, 2]
    code "{\"definitions\": {\"status\": \"failed\"}}" `shouldBe` 1
    -- An incompatible Canon does not skip mandatory definition validation.
    code "{\"canon\": {\"status\": \"incomplete\"}, \"definitions\": {\"status\": \"passed\"}}" `shouldBe` 2
  it "reads the versions as project.mjs's patterns do" $ do
    canonExpectedVersion "x: 1\ncanon: '0.2.x'\n" `shouldBe` Just "0.2.x"
    canonExpectedVersion "{\n  \"canon\" : \"0.3.1\"\n}\n" `shouldBe` Just "0.3.1"
    canonExpectedVersion "{\"version\": \"0.1.0\"}\n" `shouldBe` Nothing
    canonReportedVersion "Canon\ncanon\t1.22.333 (build)\n" `shouldBe` Just "1.22.333"
    canonReportedVersion "canon 1.2\n" `shouldBe` Nothing
  it "embeds the bundled examples the npm package ships" $ do
    names <- sort . filter (".lawspec" `isSuffixOfName`) <$> listDirectory "examples/specs"
    shipped <- mapM (\name -> (,) name <$> readFile ("examples/specs" </> name)) names
    exampleSpecifications `shouldBe` shipped
    readFile "examples/rc1/native-payments.lawspec" >>= (paymentsSpecification `shouldBe`)
    targets <- sort <$> listDirectory "examples/native-payments"
    projects <- mapM (\target -> (,) target <$> folderFiles ("examples/native-payments" </> target)) targets
    paymentsProjects `shouldBe` projects
  it "writes each target's payments project, user-owned, and preserves it on export again" $ do
    let (outcome, world) = run ["examples", "--example", "payments", "--target", "gleam"] empty
    (outcome, err world) `shouldBe` (Completed 0, "")
    out world `shouldBe` "gleam: payment project in /w/p/native_payments/gleam; 0 user files preserved.\nOpen each project's README.md, run lawspec generate, then its native test command.\n"
    file "/w/p/native_payments/gleam/laws/payments.lawspec" world `shouldBe` Just paymentsSpecification
    fmap ("node prepare.mjs\nlawspec generate\ngleam test\n```\n" `isInfixOf`) (file "/w/p/native_payments/gleam/README.md" world) `shouldBe` Just True
    fmap (":machine-bits 64" `isInfixOf`) (file "/w/p/native_payments/gleam/lawspec.edn" world) `shouldBe` Just True
    let (again, world') = run ["examples", "--example", "payments", "--target", "gleam"] world {worldStdout = BC.empty}
    again `shouldBe` Completed 0
    out world' `shouldSatisfy` ("; 10 user files preserved." `isInfixOf`)
  -- Compiling the bundled specifications for a target is compared with the
  -- legacy CLI by tools/host-parity.mjs (examples); here only the checks
  -- made before compiling.
  it "refuses an output folder outside the working directory before compiling" $ do
    let (outcome, world) = run ["examples", "--output", "../x"] empty
    (outcome, err world) `shouldBe` (Completed 1, "lawspec: Unsafe output path: ../x\n")
    worldFiles world `shouldBe` worldFiles empty
  where
    isSuffixOfName suffix name = reverse suffix `isPrefixOf` reverse name
