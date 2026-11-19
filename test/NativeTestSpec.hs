{-# LANGUAGE GADTs #-}

-- | lawspec test in the Haskell application port: the native invocations it
-- builds, the runner reports it reads, the JUnit report it merges, the
-- result keys that name the host, and the result cache and failure
-- database over the in-memory host. The expected reports are the legacy
-- CLI's (npm/test-command.mjs) for the same input; tools/host-parity.mjs
-- compares whole runs with it.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module NativeTestSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import LawSpec.App.Command
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.App.TestReports (goJsonTests, junitFromTests, junitTests, mergeJunit, nodeEventTests)
import LawSpec.App.TestResults (hostIdentity, lawKeys)
import LawSpec.App.TestRuns
import LawSpec.Host.Effect hiding (Create)
import LawSpec.Host.Fake
import Test.Hspec

json :: String -> Json
json = either error id . parseJson

options :: RunOptions
options = RunOptions False "/s" Nothing False "/p" Nothing "node" Nothing "token"

-- | A Go project over examples/specs/refined_definitions.lawspec, with a
-- go tool whose tests pass unless their name is in the failing list.
goWorld :: String -> [String] -> World
goWorld source failing =
  withFile "/p/lawspec.edn" (BC.pack manifest)
    $ withFile "/p/laws/refined_definitions.lawspec" (BC.pack source)
    $ withFile "/bin/go" (BC.pack "go")
    $ withFile "/usr/bin/env" (BC.pack "env")
    $ withDirectory "/p"
    $ emptyWorld
      { worldEnvironment = [("PATH", "/bin")],
        worldPrograms = [("/bin/go", goTool failing), ("/usr/bin/env", const (Just (0, BC.pack "PATH=/bin\0HOME=/h\0", BC.empty)))]
      }
  where
    manifest = "{:manifest-version 1 :component {:name \"p\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :go :root \".\"}] :verification {:layers [:property]}}\n"

goTool :: [String] -> SpawnRequest -> Maybe (Int, BC.ByteString, BC.ByteString)
goTool failing request = case drop 1 (spawnArguments request) of
  ["version"] -> Just (0, BC.pack "go version go1.25.1 darwin/arm64\n", BC.empty)
  ["list", "-mod=readonly", "-m", "-json", _] -> Just (0, BC.pack "{\"Path\": \"pgregory.net/rapid\", \"Version\": \"v1.3.0\"}\n", BC.empty)
  ["list", "-mod=readonly", _] -> Just (0, BC.pack "pgregory.net/rapid\n", BC.empty)
  "test" : "-json" : "-count=1" : package : "-run" : [pattern] ->
    let names = splitOn '|' (takeWhile (/= ')') (drop 2 pattern))
        event action name = "{\"Action\":\"" ++ action ++ "\",\"Package\":\"example.com/p/" ++ drop 2 package ++ "\",\"Test\":\"" ++ name ++ "_Property\",\"Elapsed\":0.01}\n"
        events = concat [event (if name `elem` failing then "fail" else "pass") name | name <- names]
     in Just (if any (`elem` failing) names then 1 else 0, BC.pack events, BC.empty)
  _ -> Just (0, BC.empty, BC.empty)
  where
    splitOn c text = case break (== c) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn c rest

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/p" Nothing (Just (HostIdentity "test" "1")) Nothing Nothing))

goTests :: World -> [[String]]
goTests world = [drop 1 (spawnArguments request) | SomeEffect (Spawn request) <- worldTrace world, take 2 (spawnArguments request) == ["/bin/go", "test"], "-json" `elem` spawnArguments request]

file :: FilePath -> World -> Maybe String
file path' world = case M.lookup path' (worldFiles world) of
  Just (FileNode bytes) -> Just (BC.unpack bytes)
  _ -> Nothing

-- | A fresh trace and output for the next command over the same files.
next :: World -> World
next world = world {worldTrace = [], worldStdout = BC.empty, worldStderr = BC.empty}

spec :: Spec
spec = describe "the lawspec test port" $ do
  describe "native invocations" $ do
    let entries =
          [ json "{\"law\": \"u::law::|a|\", \"label\": \"a\", \"name\": \"A\", \"file\": \"example/u/lawspec_test.go\"}",
            json "{\"law\": \"u::law::|b|\", \"label\": \"b\", \"name\": \"B.c\", \"file\": \"example/u/lawspec_test.go\"}",
            json "{\"law\": \"v::law::|m|\", \"label\": \"m\", \"name\": \"M\", \"file\": \"example/v/lawspec_test.go\"}"
          ]
        target = json "{\"language\": \"go\", \"root\": \".\"}"
    it "runs go test once per package, selecting exactly its laws' tests" $ do
      let runs = either error id (nativeInvocations target entries options)
      [(runProgram r, runArguments r, map (fromMaybe "" . fmap jsString . member "law") (runLaws r)) | r <- runs]
        `shouldBe` [ ("go", ["test", "-json", "-count=1", "./example/u", "-run", "^(A|B\\.c)_"], ["u::law::|a|", "u::law::|b|"]),
                     ("go", ["test", "-json", "-count=1", "./example/v", "-run", "^(M)_"], ["v::law::|m|"])
                   ]
      map runReport runs `shouldBe` [Just GoJson, Just GoJson]
    it "matches a test to the law whose name prefixes it, never another's" $ do
      let runs = either error id (nativeInvocations target entries options)
          matched name = case runs of
            r : _ -> map (fromMaybe "" . fmap jsString . member "law") (maybe [] ($ json ("{\"name\": \"" ++ name ++ "\"}")) (runMatches r))
            [] -> []
      matched "A_Property" `shouldBe` ["u::law::|a|"]
      matched "AB_Property" `shouldBe` []
      matched "A_Boundaries/Boundary1" `shouldBe` ["u::law::|a|"]
      matched "A_Boundaries" `shouldBe` []
    it "rejects a target lawspec test does not support" $
      either id (const "") (nativeInvocations (json "{\"language\": \"cobol\"}") entries options) `shouldBe` "lawspec test does not support cobol"
  describe "runner reports" $ do
    let junit = "<?xml version=\"1.0\"?>\n<testsuite name=\"S\" tests=\"2\">\n  <testcase classname=\"C\" name=\"a()\" time=\"0.5\"/>\n  <testcase classname=\"C\" name=\"b\"><failure message=\"boom &amp; more\">trace</failure></testcase>\n  <testcase name=\"c\"><skipped/></testcase>\n</testsuite>\n"
        goOutput = "{\"Action\":\"run\",\"Package\":\"p\",\"Test\":\"TestA_property\"}\n{\"Action\":\"pass\",\"Package\":\"p\",\"Test\":\"TestA_property\",\"Elapsed\":0.01}\nok p\n{\"Action\":\"fail\",\"Package\":\"p\",\"Test\":\"TestB_property\",\"Elapsed\":0}\n{\"Action\":\"pass\",\"Package\":\"p\",\"Elapsed\":0.2}\n"
    it "reads JUnit XML as the legacy CLI does" $
      compact (JArray (junitTests [junit]))
        `shouldBe` "[{\"name\":\"a\",\"classname\":\"C\",\"status\":\"passed\",\"time\":0.5},{\"name\":\"b\",\"classname\":\"C\",\"status\":\"failed\",\"failure\":\"boom & more\\ntrace\"},{\"name\":\"c\",\"classname\":\"\",\"status\":\"skipped\",\"reason\":\"\"}]"
    it "reads go test -json events, ignoring package events and plain lines" $
      compact (JArray (goJsonTests goOutput))
        `shouldBe` "[{\"name\":\"TestA_property\",\"classname\":\"p\",\"status\":\"passed\",\"time\":0.01},{\"name\":\"TestB_property\",\"classname\":\"p\",\"status\":\"failed\",\"time\":0}]"
    it "reads only a sealed node-events report of the same run" $ do
      let row = "{\"version\":1,\"run\":\"r\",\"event\":\"test\",\"name\":\"a\",\"classname\":\"f\",\"status\":\"passed\",\"time\":0.1}"
          sealed = "{\"version\":1,\"run\":\"r\",\"event\":\"start\"}\n" ++ row ++ "\n{\"version\":1,\"run\":\"r\",\"event\":\"end\",\"count\":1}\n"
      map (member "name") (nodeEventTests "r" sealed) `shouldBe` [Just (JString "a")]
      nodeEventTests "other" sealed `shouldBe` []
      nodeEventTests "r" (unlines (take 2 (lines sealed))) `shouldBe` []
    it "merges every target's suites into one report with the totals" $
      mergeJunit [("go (.)", junitFromTests (goJsonTests goOutput)), ("java (j)", junit), ("node", "<testsuites><testcase name=\"x\" classname=\"y\"/></testsuites>")]
        `shouldBe` "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites tests=\"5\" failures=\"2\" errors=\"0\" skipped=\"1\">\n<testsuite name=\"go (.): lawspec\" tests=\"2\" failures=\"1\">\n  <testcase classname=\"p\" name=\"TestA_property\" time=\"0.01\"/>\n  <testcase classname=\"p\" name=\"TestB_property\" time=\"0\"><failure message=\"failed\"/></testcase>\n</testsuite>\n<testsuite name=\"java (j): S\" tests=\"2\">\n  <testcase classname=\"C\" name=\"a()\" time=\"0.5\"/>\n  <testcase classname=\"C\" name=\"b\"><failure message=\"boom &amp; more\">trace</failure></testcase>\n  <testcase name=\"c\"><skipped/></testcase>\n</testsuite>\n<testsuite name=\"node: native\" tests=\"1\" failures=\"0\" errors=\"0\" skipped=\"0\">\n<testcase name=\"x\" classname=\"y\"/>\n</testsuite>\n</testsuites>\n"
    it "keeps the node-events reporter equal to npm's" $ do
      reporter <- readFile "templates/npm/node-events-reporter.mjs"
      nodeEventsReporter `shouldBe` reporter
  describe "result keys" $ do
    let target = json "{\"language\": \"go\", \"root\": \".\"}"
        tests = [json "{\"law\": \"u::law::|a|\", \"key\": \"k\"}"]
        keys environment = lawKeys "build" target (integer 64) tests environment "project" "" []
    it "names the host: its kind, its version and the core it ran" $ do
      let node = hostIdentity (Just (HostIdentity "node" "v24.0.0")) "core"
      node `shouldBe` hostIdentity (Just (HostIdentity "node" "v24.0.0")) "core"
      [hostIdentity (Just (HostIdentity "go" "v24.0.0")) "core", hostIdentity (Just (HostIdentity "node" "v25.0.0")) "core", hostIdentity (Just (HostIdentity "node" "v24.0.0")) "other", hostIdentity Nothing "core"]
        `shouldNotContain` [node]
    it "changes a law's key with its environment, and only then" $ do
      keys "environment" `shouldBe` keys "environment"
      M.lookup "u::law::|a|" (keys "environment") `shouldNotBe` M.lookup "u::law::|a|" (keys "other")
      M.size (keys "environment") `shouldBe` 1
  describe "lawspec test over the in-memory host" $ do
    source <- runIO (readFile "examples/specs/refined_definitions.lawspec")
    let generated failing = let (outcome, world) = run ["generate", "--no-advice"] (goWorld source failing) in (outcome, next world)
        resultsOf world = [content | (path', FileNode content) <- M.toList (worldFiles world), "/p/.lawspec/results/go-" `isPrefixOf` path']
        failuresOf world = [BC.unpack content | (path', FileNode content) <- M.toList (worldFiles world), "/p/.lawspec/failures/go/" `isPrefixOf` path', "/laws.json" `isSuffixOf` path']
    it "refuses to test generated files that are out of date" $ do
      let (outcome, world) = run ["test", "--seed", "1"] (goWorld source [])
      outcome `shouldBe` Completed 1
      BC.unpack (worldStderr world) `shouldBe` "lawspec: go: generated files are out of date; run lawspec generate\n"
      goTests world `shouldBe` []
    it "runs the laws once, then reuses their passing results until a key changes" $ do
      let (generatedOutcome, world0) = generated []
          (outcome, world1) = run ["test", "--seed", "1"] world0
          (again, world2) = run ["test", "--seed", "1"] (next world1)
          (fresh, world3) = run ["test", "--seed", "1", "--fresh"] (next world2)
      generatedOutcome `shouldBe` Completed 0
      (outcome, BC.unpack (worldStderr world1)) `shouldBe` (Completed 0, "")
      length (goTests world1) `shouldBe` 1
      BC.unpack (worldStdout world1) `shouldSatisfy` ("go: ran 3 law(s) with seed 1, 0 unchanged since their last passing run.\n" `isSuffixOf`)
      length (resultsOf world1) `shouldBe` 1
      file "/p/.lawspec/results/.gitignore" world1 `shouldBe` Just "*\n"
      again `shouldBe` Completed 0
      goTests world2 `shouldBe` []
      BC.unpack (worldStdout world2) `shouldBe` "go: nothing to run, 3 unchanged since their last passing run.\n"
      resultsOf world2 `shouldBe` resultsOf world1
      fresh `shouldBe` Completed 0
      length (goTests world3) `shouldBe` 1
    -- A law shares the outcome of the invocation it ran in: one that passed
    -- beside a failing law is not credited, and runs again.
    it "records a failing law, runs it again first, and forgets it once it passes" $ do
      let (_, world0) = generated []
          (_, world1) = run ["test", "--seed", "1"] world0
          failing = take 1 (concat [names | arguments <- goTests world1, let names = testNames arguments])
          (outcome, world2) = run ["test", "--seed", "2", "--fresh", "--json"] (next world1) {worldPrograms = [("/bin/go", goTool failing), ("/usr/bin/env", const (Just (0, BC.pack "PATH=/bin\0", BC.empty)))]}
          database = concat (failuresOf world2)
          (rerun, world3) = run ["test", "--seed", "3"] (next world2)
      failing `shouldSatisfy` (not . null)
      outcome `shouldBe` Completed 1
      database `shouldSatisfy` ("\"seed\": 2" `isInfixOf`)
      BC.unpack (worldStdout world2) `shouldSatisfy` ("\"ok\": false" `isInfixOf`)
      BC.unpack (worldStdout world2) `shouldSatisfy` ("\"failedLaws\": [\n      \"" `isInfixOf`)
      rerun `shouldBe` Completed 1
      take 1 (concatMap testNames (goTests world3)) `shouldBe` failing
      BC.unpack (worldStdout world3) `shouldSatisfy` ("go: ran 3 law(s) with seed 3, 0 unchanged since their last passing run. FAILED\n" ==)
      let (fixed, world4) = run ["test", "--seed", "4"] (next world3) {worldPrograms = [("/bin/go", goTool []), ("/usr/bin/env", const (Just (0, BC.pack "PATH=/bin\0", BC.empty)))]}
      fixed `shouldBe` Completed 0
      concat (failuresOf world4) `shouldBe` "{}\n"
    -- lawspec evidence and explain read the attempts a run recorded, which
    -- count only while every input still matches: not once a generated
    -- file is missing.
    it "shows recorded native results in evidence and explain while their inputs match" $ do
      let (_, world0) = generated []
          (_, world1) = run ["test", "--seed", "1"] world0
          (outcome, world2) = run ["evidence", "--json"] (next world1)
          (text', world3) = run ["evidence"] (next world2)
          (explained, world4) = run ["explain", "--view", "dev"] (next world3)
          changed = (next world4) {worldFiles = M.delete "/p/example/refined_definitions/lawspec_definitions.go" (worldFiles world4)}
          (stale, world5) = run ["evidence"] changed
      (outcome, BC.unpack (worldStderr world2)) `shouldBe` (Completed 0, "")
      BC.unpack (worldStdout world2) `shouldSatisfy` ("\"freshness\": \"matching-inputs\"" `isInfixOf`)
      BC.unpack (worldStdout world2) `shouldSatisfy` ("\"status\": \"property-tested\"" `isInfixOf`)
      text' `shouldBe` Completed 0
      BC.unpack (worldStdout world3) `shouldSatisfy` ("    Native conformance: passed; search completeness: not-established\n    go (/p): passed; matching-inputs; seed 1; " `isInfixOf`)
      explained `shouldBe` Completed 0
      BC.unpack (worldStdout world4) `shouldSatisfy` ("Native conformance: passed" `isInfixOf`)
      (stale, BC.unpack (worldStderr world5)) `shouldBe` (Completed 0, "")
      BC.unpack (worldStdout world5) `shouldSatisfy` ("go (/p): passed; stale; seed 1; " `isInfixOf`)
      BC.unpack (worldStdout world5) `shouldSatisfy` ("Generated files differ from the recorded/current plan" `isInfixOf`)
    it "writes the merged JUnit report --report names" $ do
      let (_, world0) = generated []
          (outcome, world1) = run ["test", "--seed", "1", "--report", "junit=out/junit.xml"] world0
      outcome `shouldBe` Completed 0
      file "/p/out/junit.xml" world1 `shouldSatisfy` maybe False ("<testsuites tests=\"3\" failures=\"0\" errors=\"0\" skipped=\"0\">\n<testsuite name=\"go (.): lawspec\" tests=\"3\" failures=\"0\">" `isInfixOf`)
    -- The report's directory contains the project: it must be read, not
    -- made a write root, which the guard refuses.
    it "writes a report into a directory that contains the project" $ do
      let (_, world0) = generated []
          (outcome, world1) = run ["test", "--seed", "1", "--report", "junit=../junit.xml"] world0
      (outcome, BC.unpack (worldStderr world1)) `shouldBe` (Completed 0, "")
      file "/junit.xml" world1 `shouldSatisfy` maybe False ("<testsuites tests=\"3\"" `isInfixOf`)
    it "rejects a report it cannot write" $ do
      let (outcome, world) = run ["test", "--report", "xml=out.xml"] (goWorld source [])
      (outcome, BC.unpack (worldStderr world)) `shouldBe` (Completed 1, "lawspec: --report takes junit=<path>\n")
  where
    testNames arguments = case reverse arguments of
      pattern : "-run" : _ -> testNamesOf [pattern]
      _ -> []
    testNamesOf arguments = case reverse arguments of
      pattern : _ -> splitOn '|' (takeWhile (/= ')') (drop 2 pattern))
      [] -> []
    splitOn c text = case break (== c) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn c rest
