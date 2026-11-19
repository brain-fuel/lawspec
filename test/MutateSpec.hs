{-# LANGUAGE GADTs #-}

-- | lawspec mutate in the Haskell application port: the mutant format, the
-- classification of a mutant's test run, and whole runs over the in-memory
-- host, where each test run is the ported lawspec test run in-process on a
-- scratch copy of the project, which is removed afterwards. The expected
-- texts are the legacy CLI's (npm/mutate.mjs); tools/host-parity.mjs
-- compares whole runs with it.
-- ref:DEC-s1j-shared-failures ref:DEC-haskell-application-port
module MutateSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.App.Mutate
import LawSpec.Host.Effect hiding (Create)
import LawSpec.Host.Fake
import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath ((</>))
import Test.Hspec

json :: String -> Json
json = either error id . parseJson

-- | A Go project over examples/specs/refined_definitions.lawspec, with a
-- go tool whose tests pass unless their name is in the failing list, or
-- that never ends.
goWorld :: String -> Maybe (String -> Bool) -> World
goWorld source failing =
  withFile "/p/lawspec.edn" (BC.pack manifest)
    $ withFile "/p/laws/refined_definitions.lawspec" (BC.pack source)
    $ withFile "/bin/go" (BC.pack "go")
    $ withFile "/usr/bin/env" (BC.pack "env")
    $ withDirectory "/p"
    $ emptyWorld
      { worldEnvironment = [("PATH", "/bin")],
        worldPrograms = [("/bin/go", maybe (const Nothing) goTool failing), ("/usr/bin/env", const (Just (0, BC.pack "PATH=/bin\0", BC.empty)))]
      }
  where
    manifest = "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :go :root \".\"}] :verification {:layers [:property]}}\n"

goTool :: (String -> Bool) -> SpawnRequest -> Maybe (Int, BC.ByteString, BC.ByteString)
goTool failing request = case drop 1 (spawnArguments request) of
  ["version"] -> Just (0, BC.pack "go version go1.25.1 darwin/arm64\n", BC.empty)
  ["list", "-mod=readonly", "-m", "-json", _] -> Just (0, BC.pack "{\"Path\": \"pgregory.net/rapid\", \"Version\": \"v1.3.0\"}\n", BC.empty)
  ["list", "-mod=readonly", _] -> Just (0, BC.pack "pgregory.net/rapid\n", BC.empty)
  "test" : "-json" : "-count=1" : package : "-run" : [pattern] ->
    let names = splitOn '|' (takeWhile (/= ')') (drop 2 pattern))
        event action name = "{\"Action\":\"" ++ action ++ "\",\"Package\":\"example.com/p/" ++ drop 2 package ++ "\",\"Test\":\"" ++ name ++ "_Property\",\"Elapsed\":0.01}\n"
        events = concat [event (if failing name then "fail" else "pass") name | name <- names]
     in Just (if any failing names then 1 else 0, BC.pack events, BC.empty)
  _ -> Just (0, BC.empty, BC.empty)
  where
    splitOn c text = case break (== c) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn c rest

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/p" Nothing (Just (HostIdentity "test" "1")) Nothing Nothing))

next :: World -> World
next world = world {worldTrace = [], worldStdout = BC.empty, worldStderr = BC.empty}

out, err :: World -> String
out = BC.unpack . worldStdout
err = BC.unpack . worldStderr

-- | The world's files outside the temporary root, where the scratch copies
-- are made.
projectFiles :: World -> M.Map FilePath Node
projectFiles = M.filterWithKey (\path' _ -> path' /= "/tmp" && not ("/tmp/" `isPrefixOf` path')) . worldFiles

spec :: Spec
spec = describe "the lawspec mutate port" $ do
  describe "the mutant format" $ do
    let source = "expect: broken\nexpect-any: law one | law two\n@@ app.txt\n<<<<<<<\ngood\n=======\nbad\n>>>>>>>\n"
    it "reads expectations, forbidden texts and edits" $ do
      fmap mutantExpectations (parseMutant source) `shouldBe` Right [["broken"], ["law one", "law two"]]
      fmap mutantEdits (parseMutant ("forbid: secret\r\n" ++ source)) `shouldBe` Right [Edit "app.txt" "good" "bad"]
      fmap mutantForbidden (parseMutant ("forbid: secret\r\n" ++ source)) `shouldBe` Right ["secret"]
      fmap mutantUnchecked (parseMutant ("output-unchecked-on: go rust | the runner prints no law\n" ++ source))
        `shouldBe` Right (Just (["go", "rust"], "the runner prints no law"))
    it "rejects malformed mutants with mutate.mjs's messages" $ do
      parseMutant "expect: missing" `shouldBe` Left "mutation has no edits"
      parseMutant (replace "=======" "damaged" source) `shouldBe` Left "missing ======="
      parseMutant ("bogus\n" ++ source) `shouldBe` Left "unexpected header line: bogus"
      parseMutant "output-unchecked-on: go\n@@ a\n<<<<<<<\n=======\n>>>>>>>\n" `shouldBe` Left "output-unchecked-on needs targets, then | and a reason"
      parseMutant "@@ a\nfoo\n" `shouldBe` Left "unexpected line: foo"
    -- From npm/test/mutate.test.mjs (0.36.0).
    it "reads every mutant of the repository's acceptance corpus" $ do
      files <- mutantFiles "acceptance"
      length files `shouldSatisfy` (> 0)
      failures <- concat <$> mapM (\file -> either (\problem -> [(file, problem)]) (const []) . parseMutant <$> readFile file) files
      failures `shouldBe` []
  describe "classification" $ do
    let mutant = either error id (parseMutant "expect: broken\nexpect-any: law one | law two\n@@ app.txt\n<<<<<<<\ngood\n=======\nbad\n>>>>>>>\n")
        status run' = member "status" (JObject (classifyMutation run' mutant Nothing))
        failing output = MutationRun (Just 1) False (Just (json "[{\"failedLaws\": [\"unit::one\"]}]")) output
    it "classifies runs as classifyMutation does" $ do
      status (MutationRun (Just 0) False Nothing "") `shouldBe` Just (JString "surviving")
      status (MutationRun Nothing True Nothing "") `shouldBe` Just (JString "timed-out")
      status (MutationRun (Just 1) False (Just (json "{\"diagnostics\": [{\"code\": \"unsupported\"}]}")) "") `shouldBe` Just (JString "unsupported")
      status (MutationRun (Just 1) False (Just (json "{\"diagnostics\": [{\"code\": \"target-unsupported\"}]}")) "") `shouldBe` Just (JString "unsupported")
      status (MutationRun (Just 1) False (Just (json "{\"diagnostics\": [{\"code\": \"parse\"}]}")) "") `shouldBe` Just (JString "invalid")
      status (MutationRun (Just 1) False (Just (json "[]")) "") `shouldBe` Just (JString "errored")
      status (failing "wrong") `shouldBe` Just (JString "errored")
      status (failing "broken law two") `shouldBe` Just (JString "killed")
      member "status" (JObject (classifyMutation (failing "broken law two") mutant {mutantForbidden = ["law two"]} Nothing)) `shouldBe` Just (JString "errored")
    it "holds only the failure to account on a target whose output is unchecked" $ do
      let unchecked = mutant {mutantUnchecked = Just (["go"], "no law names")}
      compact (JObject (classifyMutation (failing "wrong") unchecked (Just "go")))
        `shouldBe` "{\"status\":\"killed\",\"failedLaws\":[\"unit::one\"],\"outputUnchecked\":\"no law names\"}"
      member "status" (JObject (classifyMutation (failing "wrong") unchecked (Just "rust"))) `shouldBe` Just (JString "errored")
  describe "lawspec mutate over the in-memory host" $ do
    source <- runIO (readFile "examples/specs/refined_definitions.lawspec")
    let generated failing = let (outcome, world) = run ["generate", "--no-advice"] (goWorld source failing) in (outcome, next world)
        generatedFile world = case parseJson . BC.unpack =<< maybe (Left "") Right (fileText "/p/.lawspec/generated.json" world) of
          Right record -> case [name | (name, _) <- maybe [] members (member "files" record), ".go" `isSuffixOf` name] of
            name : _ -> name
            [] -> error "no generated Go file"
          Left problem -> error problem
        fileText path' world = case M.lookup path' (worldFiles world) of
          Just (FileNode bytes) -> Just bytes
          _ -> Nothing
        mutants world =
          withFile "/p/mutants/a-spec.mutant" (BC.pack "@@ laws/refined_definitions.lawspec\n<<<<<<<\n*\n=======\nunit broken\nf :: \nend unit\n>>>>>>>\n")
            . withFile "/p/mutants/b-generated.mutant" (BC.pack ("@@ " ++ generatedFile world ++ "\n<<<<<<<\n*\n=======\npackage changed\n>>>>>>>\n"))
            . withFile "/p/mutants/c-malformed.mutant" (BC.pack "expect: nothing\n")
            . withFile "/p/mutants/notes.txt" (BC.pack "not a mutant\n")
            $ world
    it "runs the ported test on a scratch copy for each mutant, and removes the copies" $ do
      let (generatedOutcome, world0) = generated (Just (const False))
          project = mutants world0
          (outcome, world1) = run ["mutate", "--json"] project
          report = json (out world1)
          rows = maybe [] (concatMap (\row -> [(text "name" row, text "status" row, text "reason" row)])) (member "mutations" report >>= arrayOf)
          text key row = maybe "" jsString (member key row)
      generatedOutcome `shouldBe` Completed 0
      (outcome, err world1) `shouldBe` (Completed 1, "")
      member "baseline" report `shouldBe` Just (JObject [("status", JString "passed")])
      member "ok" report `shouldBe` Just (JBool False)
      -- A specification that no longer parses gives diagnostics and no
      -- failing law; the generated file a mutant edits is left as edited.
      rows
        `shouldBe` [ ("mutants/a-spec.mutant", "invalid", "No individually identified executed failing law"),
                     ("mutants/b-generated.mutant", "surviving", ""),
                     ("mutants/c-malformed.mutant", "invalid", "mutation has no edits")
                   ]
      (member "mutations" report >>= arrayOf >>= firstOf >>= member "diagnostics" >>= arrayOf >>= firstOf >>= member "code")
        `shouldBe` Just (JString "block-unclosed")
      projectFiles world1 `shouldBe` projectFiles project
      [path' | path' <- M.keys (worldFiles world1), "/tmp/lawspec-scratch/" `isPrefixOf` path'] `shouldBe` []
      let (plain, world2) = run ["mutate", "mutants/b-generated.mutant"] (next world1)
      (plain, out world2, err world2) `shouldBe` (Completed 1, "mutants/b-generated.mutant: surviving\n", "")
    it "reports a baseline that fails, and one stopped by the mutation timeout" $ do
      let (_, world0) = generated (Just (const False))
          project = mutants world0
          failing = project {worldPrograms = worldPrograms (goWorld source (Just (const True)))}
          (outcome, world1) = run ["mutate"] failing
      (outcome, out world1, err world1) `shouldBe` (Completed 1, "baseline: failed\n", "")
      let (failedJson, world1') = run ["mutate", "--json"] failing
          report = json (out world1')
      failedJson `shouldBe` Completed 1
      (member "baseline" report >>= member "status") `shouldBe` Just (JString "failed")
      fmap (const ()) (member "baseline" report >>= member "report" >>= arrayOf) `shouldBe` Just ()
      member "mutations" report `shouldBe` Just (JArray [])
      let hanging = project {worldPrograms = worldPrograms (goWorld source Nothing)}
          (timedOut, world2) = run ["mutate", "--mutation-timeout", "50"] hanging
      (timedOut, out world2, err world2) `shouldBe` (Completed 1, "baseline: timed-out\n", "")
      [path' | path' <- M.keys (worldFiles world2), "/tmp/lawspec-scratch/" `isPrefixOf` path'] `shouldBe` []
    it "checks the project and the options before copying anything" $ do
      let (_, world0) = generated (Just (const False))
          failed arguments world = let (outcome, world') = run arguments world in (outcome, err world', projectFiles world' == projectFiles world)
      failed ["mutate"] world0 `shouldBe` (Completed 1, "lawspec: ENOENT: no such file or directory, lstat '/p/mutants'\n", True)
      failed ["mutate", "--mutation-timeout", "0"] (mutants world0) `shouldBe` (Completed 1, "lawspec: mutation timeout must be a positive integer\n", True)
      failed ["mutate", "--config", "../lawspec.edn"] (mutants world0) `shouldBe` (Completed 1, "lawspec: mutation configuration must be inside the project\n", True)
      failed ["mutate", "mutants/notes.txt"] (mutants world0) `shouldBe` (Completed 1, "lawspec: expected a .mutant file: /p/mutants/notes.txt\n", True)
      failed ["mutate", "--strict"] (mutants world0) `shouldBe` (Completed 1, "lawspec: --strict applies to advise\n", True)
  where
    mutantFiles directory = do
      names <- listDirectory directory
      fmap concat . mapM (\name -> let path' = directory </> name in doesDirectoryExist path' >>= \isDirectory ->
        if isDirectory then mutantFiles path' else pure [path' | ".mutant" `isSuffixOf` name]) $ names
    firstOf items = case items of
      item : _ -> Just item
      [] -> Nothing
    replace old new text = case text of
      [] -> []
      _ | old `isPrefixOf` text -> new ++ replace old new (drop (length old) text)
      c : rest -> c : replace old new rest
