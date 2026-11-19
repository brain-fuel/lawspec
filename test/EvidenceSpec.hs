{-# LANGUAGE GADTs #-}

-- | lawspec evidence in the Haskell application port, and the native
-- observations lawspec explain reads: how recorded native results attach
-- to evidence, the texts lawspec evidence prints, and whole runs over the
-- in-memory host. The expected values are the legacy CLI's
-- (npm/native-evidence.mjs, bin/lawspec.mjs) for the same input;
-- tools/host-parity.mjs compares whole runs with it.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module EvidenceSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import LawSpec.App.Command
import LawSpec.App.Evidence
import LawSpec.App.Json
import LawSpec.App.Main
import LawSpec.Host.Fake
import Test.Hspec

json :: String -> Json
json = either error id . parseJson

-- | Native rows as readNativeObservations writes them.
observation :: String -> String -> String -> String
observation law outcome extra =
  "{\"target\": \"go\", \"root\": \"/p\", \"check\": {\"id\": \""
    ++ law
    ++ "\", \"obligations\": [{\"declaration\": \""
    ++ law
    ++ "\", \"stage\": \"law\"}]}, \"outcome\": \""
    ++ outcome
    ++ "\", \"freshness\": \"matching-inputs\", \"attempt\": {\"seed\": 1, \"at\": \"T\", \"tests\": [{\"name\": \"A\", \"status\": \""
    ++ (if outcome == "failed" then "failed" else "passed")
    ++ "\", \"time\": 0.25, \"message\": \"boom\"}], \"invocation\": {\"ok\": "
    ++ (if outcome == "failed" then "false, \"output\": \"out\"" else "true")
    ++ "}}, \"reason\": \"why\""
    ++ extra
    ++ "}"

-- | The attestation specification of evidence.test.mjs, with a result
-- lawspec test recorded under an attested run.
attestedWorld :: World
attestedWorld =
  withFile "/p/lawspec.edn" (BC.pack manifest)
    $ withFile "/p/laws/orders.lawspec" (BC.pack source)
    $ withFile "/p/.lawspec/results/javascript-000000000000.json" (BC.pack results)
    $ withDirectory "/p" emptyWorld
  where
    manifest = "{:manifest-version 1 :component {:name \"shop\" :version \"0.1.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [] :verification {:layers [:proof :exhaustive :property :examples :runtime :model]}}\n"
    source = "unit shop.orders\n\ntype Receipt is a record{cents :: Int32} end type\nability Gateway is\n  capture :: Int32 -> Receipt\nend ability\nnormalize :: Int32 -> Int32\nfunction twice (x :: Int32) -> Integer is x + x end function\nprocedure checkout (cents :: Int32) -> Bool uses Gateway is\n  first matching case of capture cents:\n    when Receipt record{cents = paid} then paid = cents\n  end case\nend procedure\n\nlaw checkoutCharges is\n  definition: for all (cents :: Int32) => checkout cents = true end for all end definition\nend law\nlaw normalizing is\n  definition: for all (x :: Int32) => normalize (normalize x) = normalize x end for all end definition\nend law\nlaw doubling is\n  definition: for all (x :: Int32) => twice x = x * 2 end for all end definition\nend law\n\nend unit\n"
    results = "{\"version\": 1, \"laws\": {\"shop.orders::law::checkoutCharges\": {\"key\": \"k\", \"seed\": 1, \"passed\": \"2026-10-09T19:31:00.000Z\", \"environment\": \"run-4\"}}, \"attestations\": {\"run-4\": {\"format\": \"environment-attestation\", \"version\": 1, \"environment\": \"staging\", \"run\": {\"id\": \"run-4\", \"started_at\": \"2026-10-09T19:30:31Z\", \"recorded_at\": \"2026-10-09T19:30:33Z\"}, \"dependencies\": [{\"name\": \"shop.orders::Gateway\", \"endpoint\": \"localhost:9092\", \"reached\": true, \"kind\": \"stand-in\", \"stand_in\": {\"product\": \"acme/gateway\", \"version\": \"0.1.0\", \"conformance\": \"3\"}}, {\"name\": \"payments\", \"endpoint\": \"https://payments.example.com\", \"reached\": false, \"kind\": \"real\"}]}}}"

run :: [String] -> World -> (Outcome, World)
run arguments = runFake (lawspecMain fakeHost pureCompiler (Invocation arguments "/p" Nothing (Just (HostIdentity "test" "1")) Nothing Nothing))

spec :: Spec
spec = describe "the lawspec evidence port" $ do
  describe "native evidence" $ do
    let evidence =
          map
            json
            [ "{\"declaration\": \"u::law::a\", \"stage\": \"law\", \"status\": \"planned\", \"reason\": \"r\"}",
              "{\"declaration\": \"u::law::b\", \"stage\": \"law\", \"status\": \"planned\", \"reason\": \"r\", \"executionKind\": \"measurement\"}",
              "{\"declaration\": \"u::law::c\", \"stage\": \"law\", \"status\": \"proved\", \"reason\": \"p\"}",
              "{\"declaration\": \"u::law::d\", \"stage\": \"law\", \"status\": \"planned\", \"reason\": \"r\"}"
            ]
        observations =
          map
            json
            [ observation "u::law::a" "passed" ", \"coverage\": {\"kind\": \"finite-inputs\", \"scopedQuantifiers\": false}",
              observation "u::law::b" "passed" "",
              observation "u::law::c" "passed" "",
              observation "u::law::d" "failed" ""
            ]
        attached = attachNativeEvidence evidence observations
    it "completes, measures and fails planned laws as the legacy CLI does" $
      compact (JArray attached) `shouldBe` "[{\"declaration\":\"u::law::a\",\"stage\":\"law\",\"status\":\"exhaustively-checked\",\"reason\":\"Recorded native checks completed for 1 requested target(s); every finite input was checked.\",\"nativeEvidence\":{\"kind\":\"native-conformance\",\"status\":\"passed\",\"searchCompleteness\":\"complete-finite-inputs\",\"observations\":[{\"target\":\"go\",\"root\":\"/p\",\"check\":{\"id\":\"u::law::a\",\"obligations\":[{\"declaration\":\"u::law::a\",\"stage\":\"law\"}]},\"outcome\":\"passed\",\"freshness\":\"matching-inputs\",\"attempt\":{\"seed\":1,\"at\":\"T\",\"tests\":[{\"name\":\"A\",\"status\":\"passed\",\"time\":0.25,\"message\":\"boom\"}],\"invocation\":{\"ok\":true}},\"reason\":\"why\",\"coverage\":{\"kind\":\"finite-inputs\",\"scopedQuantifiers\":false}}]},\"plannedEvidence\":{\"status\":\"planned\",\"reason\":\"r\"}},{\"declaration\":\"u::law::b\",\"stage\":\"law\",\"status\":\"measured\",\"reason\":\"Recorded native checks completed for 1 requested target(s); the performance budget was checked against the real clock. This is measurement evidence, not proof. Reported durations cover the native check, including harness overhead; exact operation timings are not exported by these runners.\",\"executionKind\":\"measurement\",\"nativeEvidence\":{\"kind\":\"native-conformance\",\"status\":\"passed\",\"searchCompleteness\":\"not-established\",\"observations\":[{\"target\":\"go\",\"root\":\"/p\",\"check\":{\"id\":\"u::law::b\",\"obligations\":[{\"declaration\":\"u::law::b\",\"stage\":\"law\"}]},\"outcome\":\"passed\",\"freshness\":\"matching-inputs\",\"attempt\":{\"seed\":1,\"at\":\"T\",\"tests\":[{\"name\":\"A\",\"status\":\"passed\",\"time\":0.25,\"message\":\"boom\"}],\"invocation\":{\"ok\":true}},\"reason\":\"why\"}],\"measurements\":[{\"kind\":\"native-check-duration\",\"target\":\"go\",\"root\":\"/p\",\"test\":\"A\",\"seconds\":0.25}],\"measurementScope\":\"Reported durations cover the native check, including harness overhead; exact operation timings are not exported by these runners.\"},\"plannedEvidence\":{\"status\":\"planned\",\"reason\":\"r\"}},{\"declaration\":\"u::law::c\",\"stage\":\"law\",\"status\":\"proved\",\"reason\":\"p\",\"nativeEvidence\":{\"kind\":\"native-conformance\",\"status\":\"passed\",\"searchCompleteness\":\"not-established\",\"observations\":[{\"target\":\"go\",\"root\":\"/p\",\"check\":{\"id\":\"u::law::c\",\"obligations\":[{\"declaration\":\"u::law::c\",\"stage\":\"law\"}]},\"outcome\":\"passed\",\"freshness\":\"matching-inputs\",\"attempt\":{\"seed\":1,\"at\":\"T\",\"tests\":[{\"name\":\"A\",\"status\":\"passed\",\"time\":0.25,\"message\":\"boom\"}],\"invocation\":{\"ok\":true}},\"reason\":\"why\"}]}},{\"declaration\":\"u::law::d\",\"stage\":\"law\",\"status\":\"incomplete\",\"reason\":\"A recorded native implementation check failed; no successful conformance result is established.\",\"nativeEvidence\":{\"kind\":\"native-conformance\",\"status\":\"failed\",\"searchCompleteness\":\"not-established\",\"observations\":[{\"target\":\"go\",\"root\":\"/p\",\"check\":{\"id\":\"u::law::d\",\"obligations\":[{\"declaration\":\"u::law::d\",\"stage\":\"law\"}]},\"outcome\":\"failed\",\"freshness\":\"matching-inputs\",\"attempt\":{\"seed\":1,\"at\":\"T\",\"tests\":[{\"name\":\"A\",\"status\":\"failed\",\"time\":0.25,\"message\":\"boom\"}],\"invocation\":{\"ok\":false,\"output\":\"out\"}},\"reason\":\"why\"}]},\"plannedEvidence\":{\"status\":\"planned\",\"reason\":\"r\"}}]"
    it "leaves an obligation no native row discharges unchanged" $
      attachNativeEvidence evidence [] `shouldBe` evidence
    it "words each law's native conformance as lawspec evidence shows it" $
      map nativeEvidenceText attached
        `shouldBe` [ "Native conformance: passed; search completeness: complete-finite-inputs\ngo (/p): passed; matching-inputs; seed 1; T; why",
                     "Native conformance: passed; search completeness: not-established\nNative check duration: A [go] 0.25 s\nReported durations cover the native check, including harness overhead; exact operation timings are not exported by these runners.\ngo (/p): passed; matching-inputs; seed 1; T; why",
                     "Native conformance: passed; search completeness: not-established\ngo (/p): passed; matching-inputs; seed 1; T; why",
                     "Native conformance: failed; search completeness: not-established\ngo (/p): failed; matching-inputs; seed 1; T; why\nA: boom\nNative invocation output (scoped to that invocation):\nout"
                   ]
    it "compares recorded values as util.isDeepStrictEqual does" $ do
      deepEqual (Just (json "{\"a\": 1, \"b\": [1, {\"c\": 2}]}")) (Just (json "{\"b\": [1, {\"c\": 2}], \"a\": 1}")) `shouldBe` True
      deepEqual (Just (json "[1, 2]")) (Just (json "[2, 1]")) `shouldBe` False
      deepEqual (Just (json "{\"a\": null}")) (Just (json "{}")) `shouldBe` False
      deepEqual Nothing Nothing `shouldBe` True
    it "reads the times Date.parse reads" $ do
      map parsesAsDate ["2026-10-09T19:31:00.000Z", "2026-10-09T19:31:00Z", "2026-10-09", "2026-10-09T19:31+02:00"] `shouldBe` [True, True, True, True]
      map parsesAsDate ["", "T", "2026-13-01", "yesterday"] `shouldBe` [False, False, False, False]
  describe "the texts of lawspec evidence" $ do
    it "words an attested dependency" $ do
      dependencyText (json "{\"dependency\": \"g\", \"endpoint\": \"e\", \"reached\": true, \"standIn\": {\"identity\": \"acme/g\", \"version\": \"0.1.0\", \"conformance\": \"3\", \"historyDigest\": \"h\"}, \"ranAgainst\": {\"historyFrom\": \"completed\"}, \"node\": \"n\", \"edge\": \"x\"}")
        `shouldBe` "g: stand-in acme/g 0.1.0 (conformance level 3, history h when completed) at e; node n via x"
      dependencyText (json "{\"dependency\": \"p\", \"endpoint\": \"e\", \"reached\": false, \"completed\": {\"reached\": false}}")
        `shouldBe` "p: real at e (not reached when recorded) (not reached when completed)"
    it "words a law's harness and its last run's adequacy" $
      harnessText (json "{\"declaration\": \"u::law::a\", \"harness\": {\"tags\": [\"slow\", \"io\"], \"repeat\": 2, \"orderRandom\": true}, \"adequacy\": [{\"cases\": 8, \"cover\": [{\"label\": \"big\", \"observed\": 25, \"required\": 50, \"met\": false}], \"classes\": {\"small\": 6}, \"labels\": {\"x\": 2}}]}")
        `shouldBe` "  u::a: tags slow, io; repeat 2; order random\n    last run: 8 generated case(s); cover \"big\" 25% (needs 50%) NOT MET\n    small: 75.0%, label x: 25.0%"
  describe "lawspec evidence over the in-memory host" $ do
    it "shows the attested run a law last passed in, from lawspec test results" $ do
      let (outcome, world) = run ["evidence"] attestedWorld
          out = BC.unpack (worldStdout world)
      (outcome, BC.unpack (worldStderr world)) `shouldBe` (Completed 0, "")
      out `shouldSatisfy` ("PROVED (1)\n" `isInfixOf`)
      out `shouldSatisfy` ("\n    passed in completed run run-4 in environment staging against " `isInfixOf`)
      out `shouldSatisfy` ("\n\nENVIRONMENT staging (run run-4, recorded 2026-10-09T19:30:33Z)\n" `isInfixOf`)
      out `shouldSatisfy` ("payments: real at https://payments.example.com (not reached when recorded); no tested obligation relies on it" `isInfixOf`)
    it "lists one declaration's obligations, and fails when none matches" $ do
      let (outcome, world) = run ["evidence", "shop.orders::doubling", "--json"] attestedWorld
          (missing, world') = run ["evidence", "no.such::law"] attestedWorld
      outcome `shouldBe` Completed 0
      map (member "declaration") (maybe [] id (arrayOf (json (BC.unpack (worldStdout world))))) `shouldBe` [Just (JString "shop.orders::law::doubling")]
      (missing, BC.unpack (worldStderr world')) `shouldBe` (Completed 1, "lawspec: No matching obligation\n")
    it "explains without native results when no target recorded any" $
      fst (run ["explain"] attestedWorld) `shouldBe` Completed 0
