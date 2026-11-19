{-# LANGUAGE LambdaCase #-}

-- | What a native run records for each law and how it reaches evidence:
-- attempts, reach, seeds, attestation keys and native evidence, ported from
-- npm/test/native-evidence.test.mjs, reach.test.mjs and the native part of
-- known-discrepancy.test.mjs when the legacy CLI's native-evidence.mjs left
-- the package (0.36.0). Each example keeps the legacy test's case and
-- expected values. ref:DEC-haskell-application-port
module NativeAttemptsSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.Either (isLeft)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import LawSpec.App.Evidence (attachNativeEvidence, nativeEvidenceText)
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.App.Test (projectKey)
import LawSpec.App.TestResults
import LawSpec.Host.Fake
import Test.Hspec

json :: String -> Json
json = either error id . parseJson

model :: String -> String -> Json
model law name =
  json ("{\"law\": \"" ++ law ++ "\", \"key\": \"plan:" ++ law ++ "\", \"unit\": \"bank\", \"file\": \"bank-test\", \"name\": \"" ++ name ++ "\", \"label\": \"" ++ name ++ "\", \"obligations\": [{\"declaration\": \"bank::model::account\", \"stage\": \"model\"}]}")

first, second, supervisor :: Json
first = model "sequential" "combined_account"
second = model "parallel" "combined_account"
supervisor = model "supervision" "supervision"

settings :: Attempt
settings =
  Attempt
    { attemptKeys = M.fromList [(law, "key:" ++ law) | law <- ["sequential", "parallel", "supervision"]],
      attemptSeed = JNumber 811,
      attemptOk = True,
      attemptProfile = json "{\"target\": \"java\", \"root\": \"/bank\", \"machineBits\": 64, \"minify\": false}",
      attemptOutput = "",
      attemptAll = [],
      attemptAt = "2026-10-17T20:00:00Z",
      attemptStarted = True
    }

-- | recordNativeAttempts over a runner whose tests match laws by name.
record :: [Json] -> [String] -> Attempt -> [(String, Json)]
record entries tests options =
  recordNativeAttempts entries (Just matches) (JString "native-runner") (map json tests) options {attemptAll = entries}
  where
    matches test = [entry | entry <- entries, member "name" entry == member "name" test]

field :: [String] -> Json -> Maybe Json
field path value = foldl (\v key -> v >>= member key) (Just value) path

outcomeOf :: String -> [(String, Json)] -> Maybe Json
outcomeOf law rows = lookup law rows >>= member "outcome"

firstMember :: String -> [Json] -> Maybe Json
firstMember key = \items -> case items of
  item : _ -> member key item
  [] -> Nothing

text :: String -> Maybe Json
text = Just . JString

obligation :: String -> Json
obligation status =
  json ("{\"owner\": \"bank\", \"declaration\": \"bank::model::account\", \"stage\": \"model\", \"status\": \"" ++ status ++ "\", \"reason\": \"native model checks are planned\", \"claim\": null}")

observation :: String -> String -> String -> String -> Json
observation target outcome freshness extra =
  json
    ( "{\"target\": \""
        ++ target
        ++ "\", \"root\": \"/"
        ++ target
        ++ "\", \"check\": {\"id\": \""
        ++ target
        ++ "\", \"obligations\": [{\"declaration\": \"bank::model::account\", \"stage\": \"model\"}]}, \"outcome\": \""
        ++ outcome
        ++ "\", \"freshness\": \""
        ++ freshness
        ++ "\", \"reason\": \"native completion\", \"coverage\": {\"kind\": \"sampled\", \"scopedQuantifiers\": false}"
        ++ extra
        ++ "}"
    )

attach :: Json -> [Json] -> Json
attach evidence rows = case attachNativeEvidence [evidence] rows of
  [one] -> one
  other -> error (show other)

keyOf :: String -> Maybe String
keyOf item = lookup "charge" (attestedKeys (json ("{\"evidence\": [" ++ item ++ "]}")))

planned :: String -> String
planned dependency = "{\"declaration\": \"charge\", \"plannedEnvironment\": \"staging\", \"plannedAgainst\": [" ++ dependency ++ "]}"

guarded, plain :: Json
guarded = json "{\"law\": \"example.vacuity::law::accepted\", \"label\": \"example.vacuity::an accepted offer\", \"reach\": {\"guards\": 1, \"measured\": true, \"advice\": [{\"rule\": \"adapter-guard\", \"input\": \"offer\", \"message\": \"Consider a harness strategy.\"}]}}"
plain = json "{\"law\": \"example.vacuity::law::plain\", \"label\": \"example.vacuity::plain\"}"

statistics :: String -> String -> Json
statistics label counts = json ("{\"law\": \"" ++ label ++ "\", \"reach\": [" ++ counts ++ "]}")

passed :: String -> (String, Json)
passed law = (law, json "{\"outcome\": \"passed\"}")

spec :: Spec
spec = describe "native attempts and evidence" $ do
  describe "attempts" $ do
    it "lets a failed combined model method establish neither included check" $ do
      let rows =
            record
              [first, second, supervisor]
              ["{\"name\": \"combined_account\", \"status\": \"failed\", \"reason\": \"returned 1; model expected 2\"}", "{\"name\": \"supervision\", \"status\": \"passed\"}"]
              settings {attemptOk = False}
      map (`outcomeOf` rows) ["sequential", "parallel", "supervision"] `shouldBe` map text ["failed", "failed", "passed"]
      (lookup "sequential" rows >>= member "tests" >>= arrayOf >>= firstMember "reason") `shouldBe` text "returned 1; model expected 2"
      [(member "searchCompleteness" row, member "verification" row, member "seed" row) | (_, row) <- rows]
        `shouldBe` replicate 3 (text "not-established", text "native-execution", Just (JNumber 811))
    it "never makes zero discovery, skipped cases or a failed setup successful evidence" $ do
      outcomeOf "sequential" (record [first] [] settings) `shouldBe` text "incomplete"
      outcomeOf "sequential" (record [first] ["{\"name\": \"combined_account\", \"status\": \"skipped\"}"] settings) `shouldBe` text "skipped"
      let requirement = json "{\"law\": \"requirement\", \"key\": \"plan:sequential\", \"unit\": \"bank\", \"file\": \"bank-test\", \"name\": \"combined_account\", \"label\": \"combined_account\"}"
      outcomeOf "requirement" (record [requirement] ["{\"name\": \"combined_account\", \"status\": \"passed\"}"] settings {attemptOk = False}) `shouldBe` text "incomplete"
    it "keeps an explicitly incomplete result incomplete when its process succeeds" $ do
      let rows = record [first] ["{\"name\": \"combined_account\", \"status\": \"incomplete\", \"failure\": \"the search bound was exhausted\"}"] settings
      outcomeOf "sequential" rows `shouldBe` text "incomplete"
      (lookup "sequential" rows >>= member "tests" >>= arrayOf >>= firstMember "status") `shouldBe` text "incomplete"
      (lookup "sequential" rows >>= member "searchCompleteness") `shouldBe` text "not-established"
    it "records not-run for a law no process was started for, never incomplete or a result" $ do
      let skipped = json "{\"law\": \"supervision\", \"key\": \"plan:supervision\", \"unit\": \"bank\", \"file\": \"bank-test\", \"name\": \"supervision\", \"label\": \"supervision\", \"skip\": true}"
          rows = recordNativeAttempts [first, skipped] Nothing JNull [] settings {attemptOk = False, attemptStarted = False}
      outcomeOf "sequential" rows `shouldBe` text "not-run"
      (lookup "sequential" rows >>= member "tests") `shouldBe` Just (JArray [])
      (lookup "sequential" rows >>= field ["invocation", "command"]) `shouldBe` Just JNull
      -- A skipped law has nothing to start.
      outcomeOf "supervision" rows `shouldBe` text "skipped"
      -- Tests in a report mean a process ran, whatever the caller says.
      outcomeOf "sequential" (record [first] ["{\"name\": \"combined_account\", \"status\": \"failed\"}"] settings {attemptOk = False, attemptStarted = False}) `shouldBe` text "failed"
    it "keeps the runner's output when a framework reports no failure of its own" $ do
      let rows = record [first] ["{\"name\": \"combined_account\", \"status\": \"failed\"}"] settings {attemptOk = False, attemptOutput = "model account: actual 1, expected 2; shrunk input deposit(1)"}
      fmap jsString (lookup "sequential" rows >>= field ["invocation", "output"]) `shouldSatisfy` maybe False ("actual 1, expected 2" `isInfixOf`)
    it "keeps exact large seeds for replay and refuses rounded ones" $ do
      nativeSeed (JString "811") `shouldBe` Right (JNumber 811)
      nativeSeed (JString "0") `shouldBe` Right (JNumber 0)
      nativeSeed (JString "9007199254740993") `shouldBe` Right (JString "9007199254740993")
      nativeSeed (JString "123456789012345678901234567890") `shouldBe` Right (JString "123456789012345678901234567890")
      either ("lost precision" `isInfixOf`) (const False) (nativeSeed (JNumber 9007199254740992)) `shouldBe` True
      isLeft (nativeSeed (JString "x")) `shouldBe` True
      (lookup "sequential" (record [first] ["{\"name\": \"combined_account\", \"status\": \"passed\"}"] settings {attemptSeed = JString "9007199254740993"}) >>= member "seed")
        `shouldBe` text "9007199254740993"
    it "leaves each logical obligation of a failed combined method incomplete, not refuted" $ do
      let attempts = record [first, second] ["{\"name\": \"combined_account\", \"status\": \"failed\"}"] settings {attemptOk = False}
          attempt = fromMaybe (error "no attempt") (lookup "sequential" attempts)
          result = attach (obligation "planned") [setMember "attempt" attempt (observation "java" "failed" "matching-inputs" "")]
      field ["check", "nativeGroup"] attempt `shouldBe` Just (JArray [JString "sequential", JString "parallel"])
      member "status" result `shouldBe` text "incomplete"
      field ["nativeEvidence", "status"] result `shouldBe` text "incomplete"
      fmap jsString (member "reason" result) `shouldSatisfy` maybe False ("specific included logical check is not identified" `isInfixOf`)
    it "records a known discrepancy without making it a passing proof" $ do
      let reason = "Review the specification and implementation together"
          entry = json ("{\"law\": \"mismatch::agrees\", \"unit\": \"mismatch\", \"key\": \"plan\", \"file\": \"tests\", \"name\": \"agrees\", \"knownDiscrepancy\": \"" ++ reason ++ "\"}")
          rows = recordNativeAttempts [entry] (Just (const [entry])) (JString "runner") [json "{\"name\": \"agrees\", \"status\": \"passed\"}"] settings {attemptKeys = M.fromList [("mismatch::agrees", "key")], attemptSeed = JNumber 1, attemptProfile = json "{\"target\": \"javascript\"}"}
          evidence =
            attach
              (json ("{\"declaration\": \"mismatch::agrees\", \"stage\": \"law\", \"status\": \"known-discrepancy\", \"reason\": \"" ++ reason ++ "\"}"))
              [json "{\"target\": \"javascript\", \"root\": \"/project\", \"outcome\": \"known-discrepancy\", \"freshness\": \"matching-inputs\", \"check\": {\"id\": \"mismatch::agrees\", \"obligations\": [{\"declaration\": \"mismatch::agrees\", \"stage\": \"law\"}]}}"]
      outcomeOf "mismatch::agrees" rows `shouldBe` text "known-discrepancy"
      member "status" evidence `shouldBe` text "known-discrepancy"
      field ["nativeEvidence", "status"] evidence `shouldBe` text "known-discrepancy"
      field ["nativeEvidence", "searchCompleteness"] evidence `shouldBe` text "not-established"
  describe "native evidence" $ do
    it "keeps scope, stale results, failures and unselected obligations" $ do
      let complete = attach (obligation "planned") [observation "python" "passed" "matching-inputs" "", observation "java" "passed" "matching-inputs" ""]
      member "status" complete `shouldBe` text "property-tested"
      member "claim" complete `shouldBe` Just JNull
      field ["nativeEvidence", "status"] complete `shouldBe` text "passed"
      field ["nativeEvidence", "searchCompleteness"] complete `shouldBe` text "not-established"
      member "status" (attach (obligation "planned") [observation "python" "passed" "stale" ""]) `shouldBe` text "planned"
      field ["nativeEvidence", "status"] (attach (obligation "planned") [observation "python" "passed" "matching-inputs" "", observation "java" "not-run" "not-run" ""]) `shouldBe` text "partial"
      member "status" (attach (obligation "planned") [observation "python" "passed" "matching-inputs" "", observation "java" "failed" "matching-inputs" ""]) `shouldBe` text "incomplete"
      let unselected = attach (obligation "not-verified") [observation "python" "passed" "not-selected" ""]
      (member "status" unselected, field ["nativeEvidence", "status"] unselected) `shouldBe` (text "not-verified", text "not-selected")
      let proved = attach (obligation "proved") [observation "python" "failed" "matching-inputs" ""]
      (member "status" proved, field ["nativeEvidence", "status"] proved) `shouldBe` (text "proved", text "failed")
    it "keeps completed budget evidence measured, with its timing scope, at every target" $
      sequence_
        [ do
            let budget = setMember "executionKind" (JString "measurement") (obligation "planned")
                row outcome freshness extra tests = setMember "coverage" (json ("{\"kind\": \"" ++ kind ++ "\", \"scopedQuantifiers\": false}")) (observation target outcome freshness (", \"attempt\": {\"tests\": [" ++ tests ++ "]}" ++ extra))
                timed = "{\"name\": \"deadline\", \"status\": \"passed\", \"time\": 0.125}"
                completed = attach budget [row "passed" "matching-inputs" "" timed]
            member "status" completed `shouldBe` text "measured"
            (field ["nativeEvidence", "measurements"] completed >>= arrayOf >>= firstMember "kind") `shouldBe` text "native-check-duration"
            (field ["nativeEvidence", "measurements"] completed >>= arrayOf >>= firstMember "seconds") `shouldBe` Just (JNumber 0.125)
            nativeEvidenceText completed `shouldSatisfy` ("including harness overhead" `isInfixOf`)
            nativeEvidenceText completed `shouldSatisfy` ("exact operation timings are not exported" `isInfixOf`)
            member "status" (attach budget [row "passed" "stale" "" timed]) `shouldBe` text "planned"
            member "status" (attach budget [row "failed" "matching-inputs" "" timed]) `shouldBe` text "incomplete"
            member "status" (attach budget [row "passed" "matching-inputs" ", \"harness\": {\"flaky\": true}" timed]) `shouldBe` text "flaky"
            field ["nativeEvidence", "measurements"] (attach budget [row "passed" "matching-inputs" "" "{\"name\": \"deadline\", \"status\": \"passed\"}"]) `shouldBe` Just (JArray [])
        | target <- ["go", "python", "javascript", "typescript", "fsharp", "rust"],
          kind <- ["sampled", "finite-inputs"]
        ]
    it "keeps complete finite inputs distinct from nested witness or universal search" $ do
      let row scoped = setMember "coverage" (json ("{\"kind\": \"finite-inputs\", \"cases\": 2, \"scopedQuantifiers\": " ++ scoped ++ "}")) (observation "python" "passed" "matching-inputs" "")
      member "status" (attach (obligation "planned") [row "false"]) `shouldBe` text "exhaustively-checked"
      let scoped = attach (obligation "planned") [row "true"]
      (member "status" scoped, field ["nativeEvidence", "searchCompleteness"] scoped) `shouldBe` (text "property-tested", text "not-established")
    it "keeps retry and adequacy observations of a current run, and never promotes a stale one" $ do
      let adequacy = "[{\"test\": \"generated\", \"cases\": 20, \"cover\": [{\"label\": \"credit\", \"observed\": 50, \"required\": 40, \"met\": true}]}]"
          row freshness = observation "python" "passed" freshness (", \"harness\": {\"flaky\": true, \"adequacy\": " ++ adequacy ++ "}")
          result = attach (obligation "planned") [row "matching-inputs"]
          stale = attach (obligation "planned") [row "stale"]
      member "status" result `shouldBe` text "flaky"
      member "adequacy" result `shouldBe` Just (json adequacy)
      fmap jsString (member "reason" result) `shouldSatisfy` maybe False ("failed, then passed on a retry" `isInfixOf`)
      (member "status" stale, member "adequacy" stale) `shouldBe` (text "planned", Nothing)
      member "status" (attach (obligation "proved") [row "matching-inputs"]) `shouldBe` text "proved"
    it "shows an archived known-failing observation as a known discrepancy, without rewriting or promoting it" $ do
      let original = "{\"attempts\": {\"bank::law::balance\": {\"key\": \"old-key\", \"planKey\": \"old-plan\", \"seed\": 811, \"outcome\": \"known-failing\", \"profile\": {\"target\": \"javascript\", \"root\": \"/p\", \"machineBits\": 64, \"minify\": false, \"build\": \"old-build\"}, \"verification\": \"native-execution\", \"searchCompleteness\": \"not-established\"}}}"
          results = "/p/.lawspec/results/javascript-" ++ projectKey "/p" ++ ".json"
          source = "unit bank\nbalance :: Int32 -> Int32\nlaw balance is\n  definition: for all (x :: Int32) => balance x = balance x end for all end definition\nend law\nend unit\n"
          world =
            withFile "/p/lawspec.edn" (BC.pack "{:manifest-version 1 :component {:name \"bank\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :javascript :root \".\"}] :verification {:layers [:property]}}\n")
              . withFile "/p/laws/bank.lawspec" (BC.pack source)
              . withFile results (BC.pack original)
              $ withDirectory "/p" emptyWorld
          (outcome, ran) = runFake (lawspecMain fakeHost pureCompiler (Invocation ["evidence", "--json"] "/p" Nothing (Just (HostIdentity "test" "1")) Nothing Nothing)) world
          (_, shown) = runFake (lawspecMain fakeHost pureCompiler (Invocation ["evidence"] "/p" Nothing (Just (HostIdentity "test" "1")) Nothing Nothing)) world
          rows = fromMaybe [] (arrayOf (json (BC.unpack (worldStdout ran))))
          balance = [row | row <- rows, member "declaration" row == text "bank::law::balance"]
      (outcome, BC.unpack (worldStderr ran)) `shouldBe` (Completed 0, "")
      let observed = [o | row <- balance, Just (JArray os) <- [field ["nativeEvidence", "observations"] row], o <- os]
      map (field ["nativeEvidence", "status"]) balance `shouldBe` [text "stale"]
      -- Shown in the current vocabulary; the recorded attempt is kept as written.
      map (member "outcome") observed `shouldBe` [text "known-discrepancy"]
      map (field ["attempt", "outcome"]) observed `shouldBe` [text "known-failing"]
      map (field ["nativeEvidence", "searchCompleteness"]) balance `shouldBe` [text "not-established"]
      map (member "status") balance `shouldBe` [text "planned"]
      BC.unpack (worldStdout shown) `shouldSatisfy` (not . ("known-failing" `isInfixOf`))
      M.lookup results (worldFiles ran) `shouldBe` Just (FileNode (BC.pack original))
  describe "attestation keys" $ do
    it "include the planned wiring and change with the declared endpoint" $
      keyOf (planned "{\"endpoint\": \"one\"}") `shouldNotBe` keyOf (planned "{\"endpoint\": \"two\"}")
    it "are wiring only: what the run observed changes none" $ do
      let standIn conformance digest = "{\"identity\": \"acme/gateway\", \"version\": \"0.1.0\", \"conformance\": \"" ++ conformance ++ "\", \"historyDigest\": \"sha256:" ++ replicate 64 digest ++ "\"}"
          gateway extra = "{\"dependency\": \"Gateway\", \"endpoint\": \"localhost:9092\"" ++ extra ++ "}"
          base = keyOf (planned (gateway (", \"reached\": true, \"kind\": \"stand-in\", \"provider\": \"fixture\", \"standIn\": " ++ standIn "3" 'a')))
      keyOf (planned (gateway (", \"reached\": false, \"kind\": \"stand-in\", \"provider\": \"fixture\", \"standIn\": " ++ standIn "3" 'b' ++ ", \"completed\": {\"reached\": true, \"historyDigest\": \"sha256:" ++ replicate 64 'c' ++ "\"}, \"ranAgainst\": {\"provider\": \"fixture\"}, \"node\": \"gateway\"")))
        `shouldBe` base
      keyOf ("{\"declaration\": \"charge\", \"environment\": \"staging\", \"environmentOutcome\": \"passed\", \"against\": [" ++ gateway (", \"reached\": true, \"kind\": \"stand-in\", \"provider\": \"fixture\", \"standIn\": " ++ standIn "3" 'a') ++ "]}")
        `shouldBe` base
      keyOf (planned (gateway (", \"reached\": true, \"kind\": \"stand-in\", \"provider\": \"fixture\", \"standIn\": " ++ standIn "2" 'a'))) `shouldNotBe` base
      keyOf (planned (gateway ", \"reached\": true, \"kind\": \"real\", \"provider\": \"fixture\"")) `shouldNotBe` base
    it "change with a real provider's implementation, not with what a run observed" $ do
      let dependency described extra = planned ("{\"dependency\": \"Gateway\", \"endpoint\": \"localhost:8080\", \"kind\": \"real\", \"provider\": \"real\", \"implementation\": " ++ described ++ extra ++ "}")
          implementation version commit = "{\"kind\": \"application\", \"product\": \"gateway\", \"version\": \"" ++ version ++ "\", \"commit\": \"" ++ commit ++ "\"}"
          base = keyOf (dependency (implementation "1.0.0" "first") "")
      keyOf (dependency (implementation "1.0.0" "second") "") `shouldNotBe` base
      keyOf (dependency (implementation "1.0.1" "first") "") `shouldNotBe` base
      keyOf (dependency (implementation "1.0.0" "first") ", \"reached\": true, \"historyDigest\": \"observed\", \"completed\": {\"reached\": true}") `shouldBe` base
  describe "reach" $ do
    it "sums each guard over the files a law wrote" $
      lawReach
        guarded
        [ statistics "example.vacuity::an accepted offer" "{\"evaluated\": 100, \"held\": 40}, {\"evaluated\": 40, \"held\": 3}",
          statistics "example.vacuity::an accepted offer" "{\"evaluated\": 6, \"held\": 2}, {\"evaluated\": 2, \"held\": 0}",
          statistics "example.vacuity::plain" "{\"evaluated\": 9, \"held\": 9}",
          json "{\"law\": \"example.vacuity::an accepted offer\", \"outcome\": \"passed\"}"
        ]
        `shouldBe` Just (json "{\"status\": \"measured\", \"cases\": 106, \"reached\": 3, \"sites\": [{\"evaluated\": 106, \"held\": 42}, {\"evaluated\": 42, \"held\": 3}]}")
    it "is unknown for a guarded law without counts, and absent for an unguarded one" $ do
      (lawReach guarded [] >>= member "status") `shouldBe` text "unknown"
      fmap jsString (lawReach (setMember "reach" (json "{\"guards\": 1, \"measured\": false}") guarded) [] >>= member "reason") `shouldSatisfy` maybe False ("does not count" `isInfixOf`)
      lawReach plain [] `shouldBe` Nothing
    it "makes a passed law no generated case reached vacuous" $ do
      let (attempts, vacuous) = applyReach [passed "example.vacuity::law::accepted", passed "example.vacuity::law::plain"] [guarded, plain] [statistics "example.vacuity::an accepted offer" "{\"evaluated\": 105, \"held\": 0}"]
      vacuous `shouldBe` [guarded]
      (lookup "example.vacuity::law::accepted" attempts >>= member "outcome") `shouldBe` text "vacuous"
      (lookup "example.vacuity::law::plain" attempts >>= member "outcome") `shouldBe` text "passed"
      reachText guarded (lookup "example.vacuity::law::accepted" attempts)
        `shouldBe` ["  example.vacuity::an accepted offer: 0 of 105 generated cases reached the consequence \x2014 VACUOUS", "    Consider a harness strategy."]
      reachText plain (lookup "example.vacuity::law::plain" attempts) `shouldBe` []
    it "keeps the outcome of reached, failed and unmeasured laws" $ do
      let law = "example.vacuity::law::accepted"
          label = "example.vacuity::an accepted offer"
          (reached, none) = applyReach [passed law] [guarded] [statistics label "{\"evaluated\": 105, \"held\": 7}"]
      none `shouldBe` []
      (lookup law reached >>= member "outcome") `shouldBe` text "passed"
      reachText guarded (lookup law reached) `shouldBe` ["  example.vacuity::an accepted offer: 7 of 105 generated cases reached the consequence"]
      let (failed, _) = applyReach [(law, json "{\"outcome\": \"failed\"}")] [guarded] [statistics label "{\"evaluated\": 3, \"held\": 0}"]
      (lookup law failed >>= member "outcome") `shouldBe` text "failed"
      let (unknown, noneUnknown) = applyReach [passed law] [guarded] []
      noneUnknown `shouldBe` []
      (lookup law unknown >>= member "outcome") `shouldBe` text "passed"
      reachText guarded (lookup law unknown) `shouldSatisfy` \case
        line : _ -> "reach unknown" `isInfixOf` line
        [] -> False
      -- No case ran at all: nothing was measured to be vacuous.
      snd (applyReach [passed law] [guarded] [statistics label "{\"evaluated\": 0, \"held\": 0}"]) `shouldBe` []
