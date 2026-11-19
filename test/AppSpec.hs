{-# LANGUAGE GADTs #-}

-- | The Haskell application port over the in-memory host: generated-file
-- ownership (files.mjs), the CLI's option checks and texts, the compiler
-- cache directory rules and the compile commands. The equivalence corpus in
-- tools/host-parity.mjs compares the same behaviour with the legacy CLI.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module AppSpec (spec) where

import Control.Monad (forM_)
import Control.Monad.State.Strict (State)
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.Doctor (beamDoctorRuntime, compatibility, satisfiesRequirement)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.App.Files
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.App.Project (extension, isoTime)
import LawSpec.App.Prove (proofTaskFingerprint)
import LawSpec.Host.Effect hiding (Create)
import LawSpec.Host.Fake
import Test.Hspec

-- | Run a command step over the fake host with the project root writable.
step :: World -> Command (State World) a -> (Either Abort a, World)
step world command = runFake (fst <$> runCommand session (grantWrite ["/p"] >> command)) world
  where
    session = newSession fakeHost pureCompiler

generated :: String -> String -> Artifact
generated path' content = Artifact path' content Generated Nothing

user :: String -> String -> Artifact
user path' content = Artifact path' content User Nothing

project :: World
project = withDirectory "/p" emptyWorld

plan :: World -> [Artifact] -> (Either Abort Plan, World)
plan world artifacts = step world (planWrites "/p" artifacts ".lawspec/generated.json" (const False))

apply :: World -> [Artifact] -> (Either Abort Plan, World)
apply world artifacts = step world $ do
  planned <- planWrites "/p" artifacts ".lawspec/generated.json" (const False)
  applyWrites [planned]
  pure planned

file :: FilePath -> World -> Maybe String
file path' world = case M.lookup path' (worldFiles world) of
  Just (FileNode bytes) -> Just (BC.unpack bytes)
  _ -> Nothing

actions :: Either Abort Plan -> Either Abort [(Action, String)]
actions = fmap (\p -> [(changeAction c, changeRelative c) | c <- planChanges p])

writes :: World -> [FilePath]
writes world = [path' | SomeEffect (WriteFile _ _ path' _) <- worldTrace world]

failure :: Either Abort a -> Maybe String
failure (Left (Aborted f)) = Just (failureMessage f)
failure _ = Nothing

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/p" Nothing Nothing Nothing Nothing))

out, err :: World -> String
out = BC.unpack . worldStdout
err = BC.unpack . worldStderr

source :: String
source = "unit configuration\ntype Settings is a record{port :: UInt16 enabled :: Bool} end type\nfunction settings (unused :: Unit) -> Settings is Settings record{port = 8080, enabled = true} end function\nend unit\n"

manifest :: String -> String
manifest fields = "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] " ++ fields ++ "}\n"

component :: String -> World
component fields =
  withFile "/p/lawspec.edn" (BC.pack (manifest fields)) $
    withFile "/p/laws/configuration.lawspec" (BC.pack source) $
      withDirectory "/p/yaml" emptyWorld

spec :: Spec
spec = describe "the application port" $ do
  describe "generated-file ownership" $ do
    it "creates generated files and records their digests" $ do
      let (result, world) = apply project [generated "a.txt" "a\n", user "b.txt" "b\n"]
      actions result `shouldBe` Right [(Create, "a.txt"), (Create, "b.txt"), (Create, ".lawspec/generated.json")]
      file "/p/a.txt" world `shouldBe` Just "a\n"
      fmap ("\"a.txt\": \"" `isInfixOf`) (file "/p/.lawspec/generated.json" world) `shouldBe` Just True
    it "plans nothing when the files are as generated" $ do
      let (_, world) = apply project [generated "a.txt" "a\n"]
      actions (fst (plan world [generated "a.txt" "a\n"])) `shouldBe` Right []
    it "updates and removes what it owns" $ do
      let (_, world) = apply project [generated "a.txt" "a\n", generated "c.txt" "c\n"]
      actions (fst (plan world [generated "a.txt" "a2\n"])) `shouldBe` Right [(Update, "a.txt"), (RemoveFile, "c.txt"), (Update, ".lawspec/generated.json")]
    it "refuses to overwrite or remove an edited or unowned file" $ do
      let (_, world) = apply project [generated "a.txt" "a\n", generated "c.txt" "c\n"]
          edited = withFile "/p/a.txt" (BC.pack "mine\n") world
      failure (fst (plan edited [generated "a.txt" "a\n"])) `shouldBe` Just "Refusing to overwrite unowned or edited generated file: a.txt"
      failure (fst (plan (withFile "/p/c.txt" (BC.pack "mine\n") world) [generated "a.txt" "a\n"])) `shouldBe` Just "Refusing to remove edited generated file: c.txt"
      failure (fst (plan (withFile "/p/new.txt" (BC.pack "x") project) [generated "new.txt" "y"])) `shouldBe` Just "Refusing to overwrite unowned or edited generated file: new.txt"
    it "keeps a mutation run's edits to generated files" $ do
      let (_, world) = apply project [generated "a.txt" "a\n"]
          edited = withFile "/p/a.txt" (BC.pack "mutant\n") world
          (result, _) = step edited (planWrites "/p" [generated "a.txt" "a\n"] ".lawspec/generated.json" (== "/p/a.txt"))
      actions result `shouldBe` Right []
    it "preserves user files and reports a changed adapter" $ do
      let (_, world) = apply project [user "b.txt" "b\n"]
          (result, _) = plan (withFile "/p/b.txt" (BC.pack "my code\n") world) [user "b.txt" "b2\n"]
      fmap planPreserved result `shouldBe` Right ["b.txt"]
      fmap planAdapterUpdates result `shouldBe` Right [AdapterUpdate "b.txt" "b2\n"]
    it "checks output paths as files.mjs does" $ do
      failure (fst (plan project [generated "../x" ""])) `shouldBe` Just "Unsafe output path: ../x"
      failure (fst (plan project [generated "/x" ""])) `shouldBe` Just "Unsafe output path: /x"
      failure (fst (plan project [generated "a/./b" ""])) `shouldBe` Just "Unsafe output path: a/./b"
      failure (fst (plan project [generated "a" "", generated "a" ""])) `shouldBe` Just "Duplicate output: a"
      failure (fst (plan project [Artifact "a" "" UnknownOwnership Nothing])) `shouldBe` Just "Unknown artifact ownership"
      failure (fst (plan project [Artifact "a" "" User (Just (Left JNull))])) `shouldBe` Just "Invalid adapter reference: a"
      failure (fst (step emptyWorld (planWrites "/p" [] ".lawspec/generated.json" (const False))))
        `shouldBe` Just "Output root does not exist: /p. Create it or initialize the target before generation."
      let linked = project {worldFiles = M.insert "/p/out" (LinkNode "/elsewhere") (worldFiles project)}
      failure (fst (plan linked [generated "out/a" ""])) `shouldBe` Just "Refusing symbolic-link output: out/a"
    it "rejects a malformed ownership manifest" $
      failure (fst (plan (withFile "/p/.lawspec/generated.json" (BC.pack "{\"version\":2}") project) []))
        `shouldBe` Just "Invalid ownership manifest"
    it "rechecks every file before writing" $ do
      case plan project [generated "a.txt" "a\n"] of
        (Right planned, world) -> do
          let changed = withFile "/p/a.txt" (BC.pack "raced\n") world
          failure (fst (step changed (applyWrites [planned]))) `shouldBe` Just "File changed during generation: a.txt"
          file "/p/.lawspec/generated.json" changed `shouldBe` Nothing
        (other, _) -> expectationFailure (show (actions other))
  describe "JSON as JavaScript reads it" $ do
    it "keeps member order, index keys first" $
      fmap stringify (parseJson "{\"b\":1,\"2\":[true,null],\"a\":\"\\u00e9\\ud83d\\ude00\",\"b\":2}")
        `shouldBe` Right "{\n  \"2\": [\n    true,\n    null\n  ],\n  \"b\": 2,\n  \"a\": \"\233\128512\"\n}"
    it "writes canonical JSON with sorted keys" $
      fmap canonical (parseJson "{\"b\":[1,{\"d\":1,\"c\":2}],\"a\":\"x\"}") `shouldBe` Right "{\"a\":\"x\",\"b\":[1,{\"c\":2,\"d\":1}]}"
    it "rejects what JSON.parse rejects" $
      mapM_ (\text -> parseJson text `shouldSatisfy` either (const True) (const False)) ["", "{", "[1,]", "01", "{\"a\" 1}", "\"\t\"", "1 2"]
  describe "the project helpers" $ do
    it "words times as toISOString" $
      map isoTime [0, 1767225600123, 951782400000] `shouldBe` ["1970-01-01T00:00:00.000Z", "2026-01-01T00:00:00.123Z", "2000-02-29T00:00:00.000Z"]
    it "takes extensions as path.extname" $
      map extension ["a.edn", "/x/.edn", "a.b/c", "a.", "/d/lawspec.json"] `shouldBe` [".edn", "", "", ".", ".json"]
  describe "the CLI" $ do
    it "prints the usage and the version" $ do
      let (outcome, world) = run [] emptyWorld
      outcome `shouldBe` Completed 0
      out world `shouldSatisfy` ("LawSpec " `isPrefixOf`)
      out world `shouldSatisfy` ("\nTargets: " `isInfixOf`)
      fmap out (Just (snd (run ["--version"] emptyWorld))) `shouldSatisfy` maybe False (\text -> text /= "" && '\n' == last text)
    it "makes main()'s option checks in order" $ do
      let failed arguments = let (outcome, world) = run arguments project in (outcome, err world)
      failed ["check", "--machine-bits", "16"] `shouldBe` (Completed 1, "lawspec: machineBits must be 32 or 64\n")
      failed ["prelude", "a", "b"] `shouldBe` (Completed 1, "lawspec: Usage: lawspec prelude [query] [--json]\n")
      failed ["check", "--strict", "--view", "eng"] `shouldBe` (Completed 1, "lawspec: --strict applies to advise\n")
      failed ["check", "--view", "eng"] `shouldBe` (Completed 1, "lawspec: --view applies to explain\n")
      failed ["check", "a", "b"] `shouldBe` (Completed 1, "lawspec: Unexpected argument: a b\n")
      failed ["test", "--seed", "x"] `shouldBe` (Completed 1, "lawspec: --seed must be a whole number\n")
      failed ["lsp"] `shouldBe` (Completed 1, "lawspec: lsp requires --stdio\n")
      failed ["check"] `shouldBe` (Completed 1, "lawspec: /p: No lawspec.edn found in this directory or its parents\n")
    it "reports an unknown option or a missing value as a usage error" $ do
      let failed arguments = let (outcome, world) = run arguments project in (outcome, out world, err world)
      failed ["check", "--frob"]
        `shouldBe` (Completed 1, "", "lawspec: Unknown option: --frob\nUsage: lawspec check [--warn-matches] [--no-advice] | doctor | explain [<unit>::<law>] [--view eng|math|dev] | generate\n")
      failed ["lsp", "--port"]
        `shouldBe` (Completed 1, "", "lawspec: Missing value for --port\nUsage: lawspec lsp --stdio | lawspec mcp\n")
      failed ["--version", "--x"] `shouldBe` (Completed 1, "", "lawspec: Unknown option: --x\nRun lawspec help for the commands and their options.\n")
      let (_, json, _) = failed ["fmt", "--json", "--bogus"]
      json `shouldSatisfy` ("\"code\": \"usage\"" `isInfixOf`)
    it "reports a manifest failure as diagnostics under --json" $ do
      let (outcome, world) = run ["check", "--json"] (withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1") project)
      outcome `shouldBe` Completed 1
      out world `shouldSatisfy` ("\"code\": \"manifest\"" `isInfixOf`)
      out world `shouldSatisfy` ("\"file\": \"/p/lawspec.edn\"" `isInfixOf`)
    it "checks a component and keeps the compiler cache in .lawspec/cache" $ do
      let (outcome, world) = run ["check"] (component ":targets []")
      (outcome, err world) `shouldBe` (Completed 0, "")
      out world `shouldSatisfy` ("Compiled 0 law(s). Intrinsic definition checks passed." `isPrefixOf`)
      file "/p/.lawspec/cache/.gitignore" world `shouldBe` Just "*\n"
    it "removes the .lawspec folder a failed run created" $ do
      let broken = withFile "/p/laws/broken.lawspec" (BC.pack "unit broken\nf :: \nend unit\n") (component ":targets []")
          (outcome, world) = run ["check"] broken
      outcome `shouldBe` Completed 1
      [path' | path' <- M.keys (worldFiles world), "/p/.lawspec" `isPrefixOf` path'] `shouldBe` []
    it "names other cache directories without owning them" $ do
      let (outcome, world) = run ["check", "--no-cache"] (component ":targets []")
      outcome `shouldBe` Completed 0
      M.member "/p/.lawspec" (worldFiles world) `shouldBe` False
      let (_, shared) = run ["check"] (component ":targets [] :cache-directory \"../shared\"")
      [path' | path' <- M.keys (worldFiles shared), "/shared" `isPrefixOf` path'] `shouldSatisfy` (not . null)
      M.member "/p/.lawspec" (worldFiles shared) `shouldBe` False
    it "generates an artifact target and records what it owns" $ do
      let (outcome, world) = run ["generate"] (component ":targets [{:language :yaml :root \"yaml\"}] :verification {:layers []}")
      (outcome, err world) `shouldBe` (Completed 0, "")
      out world `shouldBe` "yaml: 4 applied change(s), 0 user adapter(s) preserved.\nArtifact generation complete.\n"
      file "/p/yaml/configuration.yaml" world `shouldSatisfy` (/= Nothing)
      file "/p/yaml/.lawspec/generated.json" world `shouldSatisfy` (/= Nothing)
      let (again, world') = run ["generate", "--check"] world
      (again, out world') `shouldBe` (Completed 0, out world ++ "yaml: 0 planned change(s), 0 user adapter(s) preserved.\nArtifact generation complete.\n")
    it "advises on a program target's native sources" $ do
      let program =
            withFile "/p/clone.mjs" (BC.pack "export class Settings {}\n") $
              component ":targets [{:language :javascript :root \".\"}] :verification {:layers []}"
          (outcome, world) = run ["advise", "--json"] program
      (outcome, err world) `shouldBe` (Completed 0, "")
      out world `shouldSatisfy` ("\"rule\": \"native-model\",\n      \"target\": \"javascript\",\n      \"path\": \"clone.mjs\",\n      \"declaration\": \"clone.mjs::Settings\"" `isInfixOf`)
      writes world `shouldBe` []
      let (strict, strictWorld) = run ["advise", "--strict"] program
      strict `shouldBe` Completed 1
      err strictWorld `shouldSatisfy` ("warning native-model: clone.mjs::Settings: Declaration shares a generated model name" `isPrefixOf`)
      out strictWorld `shouldBe` "Authoring review required; see findings and analysis limits.\n"
      let (checked, checkedWorld) = run ["check", "--no-cache"] program
      checked `shouldBe` Completed 0
      err checkedWorld `shouldSatisfy` ("warning native-model: clone.mjs::Settings:" `isPrefixOf`)
    it "excepts a declaration the manifest names, and advises without targets" $ do
      let excepted =
            withFile "/p/clone.mjs" (BC.pack "export class Settings {}\n") $
              component ":targets [{:language :javascript :root \".\"}] :verification {:layers []} :authoring-exceptions [{:declaration \"clone.mjs::Settings\" :rule \"native-model\" :reason \"Independent reference model\"}]"
          (outcome, world) = run ["advise", "--strict"] excepted
      (outcome, err world, out world) `shouldBe` (Completed 0, "", "Selected authoring checks complete; no unresolved findings.\n")
      let (plain, plainWorld) = run ["advise", "--strict"] (component ":targets []")
      (plain, out plainWorld) `shouldBe` (Completed 0, "Selected authoring checks complete; no unresolved findings.\n")
    it "reads the sources the manifest declares outside its directory" $ do
      let shared = withFile "/shared/laws/configuration.lawspec" (BC.pack source) (withFile "/p/lawspec.edn" (BC.pack (manifest ":targets []" `withSources` "../shared/laws")) project)
          (outcome, world) = run ["check", "--no-cache"] shared
      (outcome, err world) `shouldBe` (Completed 0, "")
  describe "lawspec prove" $ do
    let increment =
          "unit example.p\nfunction increment (x :: Int8 where x < 127) -> (result :: Int8 where result > x) is\n  prelude.Int8 (x + 1)\nend function\nlaw \"|checked increment| is\n  definition : for all (x :: Int8 where x < 127) => increment x = x + 1 end for all end definition\nend law\nend unit\n"
        proofProject =
          withFile "/p/lawspec.edn" (BC.pack (manifest ":targets [] :verification {:layers [:proof]}")) $
            withFile "/p/laws/p.lawspec" (BC.pack increment) project
        z3 answer request = case spawnArguments request of
          [_, "-version"] -> Just (0, BC.pack "Z3 version 4.13.0 - 64 bit\n", BC.empty)
          _
            | maybe False (BC.isInfixOf (BC.pack "(get-info :reason-unknown)")) (spawnInput request) ->
                Just (0, BC.pack (answer ++ "\n(:reason-unknown \"timeout\")\n"), BC.empty)
            | otherwise -> Just (0, BC.pack (answer ++ "\n"), BC.empty)
        solver answer world =
          withFile "/bin/z3" (BC.pack "z3") world
            { worldEnvironment = [("PATH", "/bin")],
              worldPrograms = [("/bin/z3", z3 answer)]
            }
        proofs :: World -> [SpawnRequest]
        proofs world = [request | SomeEffect (Spawn request) <- worldTrace world, drop 1 (spawnArguments request) /= ["-version"]]
    it "proves a law Z3 answers unsat for, and keeps its receipt" $ do
      let (outcome, world) = run ["prove"] (solver "unsat" proofProject)
      (outcome, err world) `shouldBe` (Completed 0, "")
      out world `shouldSatisfy` ("example.p::law::|checked increment|: proved (unsat). Z3 established this law" `isPrefixOf`)
      map spawnArguments (proofs world) `shouldBe` [["/bin/z3", "-in", "-smt2", "-t:5000", "-memory:512"]]
      map (fmap (("(check-sat)\n(exit)\n" `isSuffixOf`) . BC.unpack) . spawnInput) (proofs world) `shouldBe` [Just True]
      let (again, world') = run ["prove"] world
      again `shouldBe` Completed 0
      out world' `shouldSatisfy` ("reused a completed semantic proof receipt; no new solver task ran" `isInfixOf`)
      length (proofs world') `shouldBe` length (proofs world)
    it "asks for the reason Z3 gave unknown by running the task again" $ do
      let (outcome, world) = run ["prove", "--proof-timeout", "100"] (solver "unknown" proofProject)
      outcome `shouldBe` Completed 2
      out world `shouldSatisfy` (": incomplete (timeout). Z3 could not decide this task: (:reason-unknown \"timeout\")" `isInfixOf`)
      map spawnArguments (proofs world) `shouldBe` replicate 2 ["/bin/z3", "-in", "-smt2", "-t:100", "-memory:512"]
      fmap (("(get-info :reason-unknown)\n(exit)\n" `isSuffixOf`) . BC.unpack) (spawnInput (last (proofs world))) `shouldBe` Just True
    it "reports an unavailable solver as incomplete" $ do
      let (outcome, world) = run ["prove"] proofProject {worldEnvironment = [("PATH", "/nowhere")]}
      outcome `shouldBe` Completed 2
      out world `shouldBe` "example.p::law::|checked increment|: incomplete (unavailable). Z3 executable is unavailable: z3\n"
    -- From npm/test/smt-proof.test.mjs (0.36.0): an answer followed by an
    -- error is a failed run, never a proof.
    it "fails a run that reports an error after its unsat answer" $ do
      let (outcome, world) = run ["prove", "--json"] (solver "unsat\n(error \"invalid task\")" proofProject)
      outcome `shouldBe` Completed 2
      let evidence = either error id (parseJson (out world)) `at'` "solverEvidence"
          at' value key = maybe [] id (member key value >>= arrayOf)
      [(member "outcome" row, member "status" row) | row <- evidence] `shouldBe` [(Just (JString "failed"), Just (JString "incomplete"))]
      -- The task binding the compiler gives each task is the one the
      -- prover checks (npm/test/smt-proof.test.mjs, 0.36.0).
      let tasks = either error id (parseJson (out world)) `at'` "proofTasks"
      [Just (JString (proofTaskFingerprint task)) | task <- tasks] `shouldBe` map (member "taskFingerprint") tasks
      length tasks `shouldBe` 1
    it "checks the Z3 options" $ do
      let failed arguments = let (outcome, world) = run arguments proofProject in (outcome, err world)
      failed ["prove", "--proof-timeout", "0"] `shouldBe` (Completed 1, "lawspec: Invalid Z3 timeoutMs\n")
      failed ["prove", "--proof-seed", "1.5"] `shouldBe` (Completed 1, "lawspec: Invalid Z3 seed\n")
      failed ["prove", "--proof-memory", "x"] `shouldBe` (Completed 1, "lawspec: Invalid Z3 memoryMb\n")
  describe "lawspec doctor" $ do
    let goProject rapid =
          withFile "/p/lawspec.edn" (BC.pack (manifest ":targets [{:language :go :root \"go\"}] :cache-directory \"/c\"")) $
            withDirectory "/p/go" $
              withDirectory "/c" $
                withFile "/bin/go" (BC.pack "go") $
                  withFile "/usr/bin/env" (BC.pack "env") $
                    emptyWorld
                      { worldEnvironment = [("PATH", "/bin")],
                        worldPrograms = [("/bin/go", goTool rapid), ("/usr/bin/env", const (Just (0, BC.pack "PATH=/bin\0HOME=/h\0", BC.empty)))]
                      }
        goTool rapid request = case drop 1 (spawnArguments request) of
          ["version"] -> Just (0, BC.pack "go version go1.25.1 darwin/arm64\n", BC.empty)
          ["list", "-mod=readonly", "-m", "-json", _] -> Just (0, BC.pack ("{\"Path\": \"pgregory.net/rapid\", \"Version\": \"" ++ rapid ++ "\"}\n"), BC.empty)
          ["list", "-mod=readonly", _] -> Just (0, BC.pack "pgregory.net/rapid\n", BC.empty)
          _ -> Nothing
        spawned :: World -> [SpawnRequest]
        spawned world = [request | SomeEffect (Spawn request) <- worldTrace world]
        cacheLine = "compiler cache: ready (/c; deepest entry 56 characters)\n"
    it "reports a ready Go toolchain and a writable cache" $ do
      let (outcome, world) = run ["doctor"] (goProject "v1.3.0")
      (outcome, out world, err world) `shouldBe` (Completed 0, "go: ready\n" ++ cacheLine, "")
      [spawnEnvironment request | request <- spawned world, spawnArguments request == ["/bin/go", "list", "-mod=readonly", "pgregory.net/rapid"]]
        `shouldBe` [Just [("PATH", "/bin"), ("HOME", "/h"), ("GOTOOLCHAIN", "local"), ("GOFLAGS", "")]]
      M.keys (M.filterWithKey (\k _ -> "/c/" `isPrefixOf` k) (worldFiles world)) `shouldBe` []
    it "reports the versions it found as JSON" $ do
      let (outcome, world) = run ["doctor", "--json"] (goProject "v1.3.0")
      outcome `shouldBe` Completed 0
      out world `shouldSatisfy` ("\"versions\": {\n      \"go\": \"1.25.1\",\n      \"rapid\": \"v1.3.0\"\n    }" `isInfixOf`)
    it "reports a dependency outside the verified profile with the setup advice" $ do
      let (outcome, world) = run ["doctor"] (goProject "v1.4.0")
      outcome `shouldBe` Completed 1
      out world `shouldSatisfy` ("go: Stable Rapid >=1.2.0 <1.4.0 without local replacement is required\nUse Go " `isPrefixOf`)
    it "reports a missing toolchain as spawn.mjs does" $ do
      let (outcome, world) = run ["doctor"] (goProject "v1.3.0") {worldEnvironment = [("PATH", "/nowhere")]}
      outcome `shouldBe` Completed 1
      out world `shouldSatisfy` ("go: go was not found on PATH; searched /nowhere; install Go or add its directory to PATH\n" `isPrefixOf`)
    it "removes the cache folders its probe created" $ do
      let (outcome, world) = run ["doctor"] (component ":targets [{:language :yaml :root \"yaml\"}]")
      (outcome, out world) `shouldBe` (Completed 0, "yaml: generation ready\ncompiler cache: ready (/p/.lawspec/cache; deepest entry 71 characters)\n")
      [k | k <- M.keys (worldFiles world), "/p/.lawspec" `isPrefixOf` k] `shouldBe` []
    it "removes nothing it did not create" $ do
      let project' =
            withFile "/q/keep" (BC.pack "kept") $
              withFile "/p/.lawspec/cache/old" (BC.pack "old") $
                component ":targets [{:language :yaml :root \"yaml\"}]"
          (outcome, world) = run ["doctor"] project'
          (outcome', world') = run ["doctor"] project' {worldFiles = M.delete "/p/.lawspec/cache/old" (worldFiles project')}
      outcome `shouldBe` Completed 0
      [k | k <- M.keys (worldFiles world), "/p/.lawspec" `isPrefixOf` k || "/q" `isPrefixOf` k]
        `shouldBe` ["/p/.lawspec", "/p/.lawspec/cache", "/p/.lawspec/cache/old", "/q", "/q/keep"]
      outcome' `shouldBe` Completed 0
      [k | k <- M.keys (worldFiles world'), "/p/.lawspec" `isPrefixOf` k] `shouldBe` ["/p/.lawspec", "/p/.lawspec/cache"]
    it "keeps the compatibility profiles equal to npm/compatibility.json" $ do
      text' <- readFile "npm/compatibility.json"
      let profiles = either error id (parseJson text')
          listed =
            [ (target, [(dependency, (low, high)) | (dependency, JArray [JString low, JString high]) <- members ranges])
            | Just targets' <- [member "targets" profiles],
              (target, ranges) <- members targets'
            ]
      listed `shouldBe` compatibility
    it "stages the runtime files the BEAM doctor compiles" $
      forM_ beamDoctorRuntime $ \(key, name) -> do
        staged <- readFile ("runtime/" ++ name)
        (name, runtimeSource key == staged) `shouldBe` (name, True)
    it "reads Hex requirements as the BEAM doctor does" $ do
      satisfiesRequirement "1.5.0" "~> 1.5" `shouldBe` Right True
      satisfiesRequirement "2.0.0" "~> 1.5" `shouldBe` Right False
      satisfiesRequirement "1.0.5" ">= 1.0.0 and < 2.0.0" `shouldBe` Right True
      satisfiesRequirement "1.0.5" "== 1.0.4 or == 1.0.5" `shouldBe` Right True
      satisfiesRequirement "1.0.5" "1.0.x" `shouldBe` Left "Cannot verify Hex requirement \"1.0.x\"; use an exact stable version"
  where
    withSources text directory = let (front, back) = breakOn "[\"laws\"]" text in front ++ "[\"" ++ directory ++ "\"]" ++ drop 8 back
    breakOn needle haystack = go "" haystack
      where
        go kept rest@(c : more)
          | needle `isPrefixOf` rest = (reverse kept, rest)
          | otherwise = go (c : kept) more
        go kept [] = (reverse kept, [])
