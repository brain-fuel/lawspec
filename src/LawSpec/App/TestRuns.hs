-- | The native invocations of lawspec test, ported from the Node CLI's
-- test-command.mjs: for each target, the commands that run exactly the
-- given laws' tests, how to read which of them ran from the runner's own
-- report, and the commands that prepare, validate and benchmark a target.
-- A law's tests are named after its label (entry.name, see
-- "LawSpec.TestNames"), then a kind after a separator no name contains, so
-- one law's name never selects another's.
--
-- An entry is a law of the compiler's test manifest (planGeneration's
-- tests), as JSON. Everything here is pure.
-- ref:DEC-haskell-application-port ref:DEC-native-property-frameworks
module LawSpec.App.TestRuns
  ( NativeRun (..),
    Report (..),
    RunOptions (..),
    nativeInvocations,
    benchmarkInvocations,
    configurationInvocations,
    preparationInvocations,
    presentationInvocations,
    coverageTool,
    regexEscape,
    nodeEventsReporter,
    entryText,
    entryField,
    isModel,
    groupOn,
    posixBasename,
    posixDirname,
    without,
  )
where

import qualified Data.ByteString.Char8 as BC
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isPrefixOf, isSuffixOf, nub)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import LawSpec.App.Json
import LawSpec.App.TestReports (SwiftGroup (..), lineTerminator)
import LawSpec.Host.Base64 (encodeBase64)
import LawSpec.Host.Path (join, relative, resolve)
import LawSpec.Scaffold (PresentationCheck (..), presentationChecks)

-- | Where a run's executed tests are read from.
data Report
  = -- | JUnit XML files, by absolute path.
    JUnitFiles [FilePath]
  | -- | The JUnit XML files a run wrote into a directory, relative to the
    -- target's root.
    JUnitDirectory FilePath
  | GoJson
  | -- | cargo test's printed lines.
    RustLines
  | HspecLines
  | -- | node-events-reporter.mjs's file and the run's identity.
    NodeEvents FilePath String
  | BeamEvents FilePath String
  | -- | Swift's JUnit files, LawSpec's lifecycle events, the run's token
    -- and the ordered groups the events must account for.
    SwiftEvents [FilePath] FilePath String [SwiftGroup]
  deriving (Eq, Show)

-- | One native invocation: the laws it covers, the command, its variables
-- (set, or removed with 'Nothing'), its report, and which laws a test of
-- its report belongs to; a run that only prepares (tsc) has neither.
data NativeRun = NativeRun
  { runLaws :: [Json],
    runProgram :: String,
    runArguments :: [String],
    runVariables :: [(String, Maybe String)],
    runReport :: Maybe Report,
    runMatches :: Maybe (Json -> [Json]),
    -- | What a BEAM run measures under --coverage.
    runCoverage :: Maybe Json
  }

data RunOptions = RunOptions
  { optionOffline :: Bool,
    -- | The folder for reports (.lawspec/reports/<target>/<project>).
    optionScratch :: FilePath,
    -- | The coverage folder under --coverage, when the tool is available.
    optionCoverage :: Maybe FilePath,
    optionXdist :: Bool,
    optionRoot :: FilePath,
    -- | The doctor's BEAM coverage settings.
    optionCoverageConfig :: Maybe Json,
    -- | The node that runs JavaScript tests (process.execPath in the legacy
    -- CLI, the PATH's node here).
    optionNode :: FilePath,
    -- | navigator.hardwareConcurrency, when known.
    optionProcessors :: Maybe Int,
    -- | A fresh identity for this call (randomUUID).
    optionToken :: String
  }

-- | A member of an entry, treating null as absent (??).
entryField :: String -> Json -> Maybe Json
entryField key entry = case member key entry of
  Just JNull -> Nothing
  other -> other

-- | A member as a template literal shows it ("undefined" when absent).
entryText :: String -> Json -> String
entryText key entry = maybe "undefined" jsString (member key entry)

isModel :: Json -> Bool
isModel entry = member "kind" entry == Just (JString "model")

truthy :: String -> Json -> Bool
truthy key entry = maybe False isTruthy (member key entry)

-- | The regular expression's metacharacters escaped (test-command.mjs regex).
regexEscape :: String -> String
regexEscape = concatMap (\c -> if c `elem` (".*+?^${}()|[]\\" :: String) then ['\\', c] else [c])

-- | file.slice(0, -extension.length).
without :: String -> String -> String
without file extension = take (length file - length extension) file

-- | Groups in the order their keys first appear (groupBy).
groupOn :: (Eq k) => (a -> k) -> [a] -> [(k, [a])]
groupOn key = foldl add []
  where
    add groups item =
      let k = key item
       in if any ((== k) . fst) groups
            then [(k', if k' == k then items ++ [item] else items) | (k', items) <- groups]
            else groups ++ [(k, [item])]

-- | path.posix.basename(file, extension).
posixBasename :: String -> String -> String
posixBasename file extension =
  let trimmed = reverse (dropWhile (== '/') (reverse file))
      base = reverse (takeWhile (/= '/') (reverse trimmed))
   in if not (null extension) && extension `isSuffixOf` base && base /= extension then without base extension else base

-- | path.posix.dirname(file).
posixDirname :: String -> String
posixDirname file
  | null file = "."
  | otherwise =
      let trimmed = case reverse (dropWhile (== '/') (reverse file)) of
            "" -> "/"
            t -> t
       in if trimmed == "/"
            then "/"
            else case break (== '/') (reverse trimmed) of
              (_, []) -> "."
              (_, _ : parent) -> case reverse (dropWhile (== '/') parent) of
                "" -> "/"
                p -> p

-- | String.prototype.replaceAll with a one-character pattern.
replaceChar :: Char -> Char -> String -> String
replaceChar from to = map (\c -> if c == from then to else c)

-- | Hpack discovers generated modules before native result keys are
-- computed; Stack owns that metadata, and no compilation or tests run.
configurationInvocations :: Json -> [(String, [String])]
configurationInvocations target
  | language target == "haskell" = [("stack", ["--no-terminal", "config", "build-files"])]
  | otherwise = []

language :: Json -> String
language target = maybe "" jsString (member "language" target)

-- | Rebar and Mix run their compile hooks; Gleam builds its generated crypto
-- bridge before a native test VM starts.
preparationInvocations :: Json -> [Json] -> [(String, [String])]
preparationInvocations target files
  | language target == "gleam" && any ((== Just (JString "priv/lawspec_crypto_native.c")) . member "path") files = [("escript", ["lawspec_crypto_build.escript"])]
  | otherwise = []

-- | A changed layout must pass the target's compiler or parser before a
-- semantic execution result is reused. No property cases run.
presentationInvocations :: Json -> [Json] -> Bool -> [(String, [String], [(String, Maybe String)])]
presentationInvocations target files offline =
  concatMap invocationsOf (presentationChecks (language target))
  where
    override command = case lookup command [("python3", "python"), ("mvn", "maven"), ("gradle", "gradle"), ("scala", "scala"), ("swift", "swift"), ("clojure", "clojure")] of
      Just key | Just value <- entryField key target -> jsString value
      _ -> command
    invocationsOf check =
      let paths = case checkSuffix check of
            Just suffix -> [path | file <- files, Just (JString path) <- [member "path" file], suffix `isSuffixOf` path]
            Nothing -> []
          extra
            | offline = fromMaybe [] (lookup (checkCommand check) [("cargo", ["--offline"]), ("mvn", ["-o"]), ("gradle", ["--offline"]), ("dotnet", ["--no-restore"])])
            | otherwise = []
          arguments = checkArguments check ++ extra
       in [ (override (checkCommand check), arguments ++ selected, [(k, Just v) | (k, v) <- checkEnvironment check])
          | selected <- if checkEach check then map pure paths else [paths]
          ]

-- | The node-events reporter LawSpec's JavaScript runs report through
-- (node-events-reporter.mjs, which an Hspec test keeps equal): the legacy
-- CLI named its file in the npm package; a core has no package, so the
-- reporter is given to node as a data: URL module.
nodeEventsReporter :: String
nodeEventsReporter =
  "// Node's structured reporter stream preserves names without XML encoding.\n\
  \// A nonce and final seal tie execution evidence to this invocation only.\n\
  \export default async function* report(source) {\n\
  \  const run=process.env.LAWSPEC_NODE_RUN;\n\
  \  if(!run) throw new Error('LawSpec Node reporting requires an invocation identity');\n\
  \  const row=value=>JSON.stringify({version:1,run,...value})+'\\n';\n\
  \  let count=0;\n\
  \  yield row({event:'start'});\n\
  \  for await(const event of source) {\n\
  \    if(!['test:pass','test:fail'].includes(event.type)||event.data?.details?.type==='suite') continue;\n\
  \    const data=event.data;\n\
  \    const skipped=[data.skip,data.todo].some(value=>value!==undefined&&value!==false);\n\
  \    const duration=data.details?.duration_ms;\n\
  \    const failure=data.details?.error?.message;\n\
  \    yield row({event:'test',name:data.name,classname:data.file??'',\n\
  \      status:skipped?'skipped':event.type==='test:pass'?'passed':'failed',\n\
  \      ...(Number.isFinite(duration)&&duration>=0?{time:duration/1000}:{}),\n\
  \      ...(event.type==='test:fail'?{failure:typeof failure==='string'?failure:'native test failed'}:{})});\n\
  \    count++;\n\
  \  }\n\
  \  yield row({event:'end',count});\n\
  \}\n"

reporterUrl :: String
reporterUrl = "data:text/javascript;base64," ++ BC.unpack (encodeBase64 (TE.encodeUtf8 (T.pack nodeEventsReporter)))

-- | A test's name, when it is a string.
testName :: Json -> String
testName test = maybe "" jsString (member "name" test)

classnameOf :: Json -> Maybe String
classnameOf test = case member "classname" test of
  Just (JString text) -> Just text
  _ -> Nothing

-- | new RegExp(`^${regex(name)}${model ? '$' : '_'}`).test(test.name)
named :: Json -> String -> Bool
named entry name
  | isModel entry = name == entryText "name" entry
  | otherwise = (entryText "name" entry ++ "_") `isPrefixOf` name

-- | The rest of a string after a prefix.
after :: String -> String -> Maybe String
after prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing

-- | Text .* matches entirely (no line terminator).
anyLine :: String -> Bool
anyLine = not . any lineTerminator

digits1 :: String -> Maybe String
digits1 text = case span isDigit text of
  (_ : _, rest) -> Just rest
  _ -> Nothing

-- | The invocations that run exactly the given laws' tests.
nativeInvocations :: Json -> [Json] -> RunOptions -> Either String [NativeRun]
nativeInvocations _ [] _ = Right []
nativeInvocations target entries options = case language' of
  "prolog"
    | isJust coverage -> Left "Prolog coverage instrumentation is not integrated"
    | otherwise ->
        let report = join scratch "prolog.xml"
            selections = nub [entryText "file" e ++ "::" ++ entryText "name" e | e <- entries]
         in Right
              [ NativeRun
                  entries
                  (setting "python" "python3")
                  (["lawspec_test.py"] ++ concatMap (\slot -> ["--select", slot]) selections ++ ["--junitxml", report])
                  []
                  (Just (JUnitFiles [report]))
                  (Just (\test -> [e | e <- entries, if isModel e then testName test == entryText "name" e else (entryText "name" e ++ "__") `isPrefixOf` testName test]))
                  Nothing
              ]
  l | l `elem` ["erlang", "elixir", "gleam"] -> beam l
  "python" -> Right (concat (zipWith python [0 :: Int ..] (groupOn (entryText "file") entries)))
  l | l `elem` ["javascript", "typescript"] -> Right (javascript l)
  "go" ->
    Right
      [ NativeRun
          laws
          "go"
          ( ["test", "-json", "-count=1"]
              ++ maybe [] (\c -> ["-cover", "-coverprofile=" ++ join c ("go-" ++ nonEmpty (replaceChar '/' '_' directory) "root" ++ ".out")]) coverage
              ++ [ "./" ++ directory,
                   "-run",
                   if any isModel laws
                     then "^(" ++ intercalate' "|" (nub [regexEscape (entryText "name" e) ++ (if isModel e then "$" else "_") | e <- laws]) ++ ")"
                     else "^(" ++ intercalate' "|" [regexEscape (entryText "name" e) | e <- laws] ++ ")_"
                 ]
          )
          []
          (Just GoJson)
          (Just (\test -> [e | e <- laws, named e (testName test), testName test /= entryText "name" e ++ "_Boundaries"]))
          Nothing
      | (directory, laws) <- groupOn (posixDirname . entryText "file") entries
      ]
  "java" ->
    let byClass = groupOn (\e -> className (entryText "file" e) "src/test/java" ".java") entries
     in Right
          [ NativeRun
              entries
              (setting "maven" "mvn")
              ( ["-o" | offline]
                  ++ ["-B"]
                  ++ ["org.jacoco:jacoco-maven-plugin:prepare-agent" | isJust coverage]
                  ++ ["test"]
                  ++ ["org.jacoco:jacoco-maven-plugin:report" | isJust coverage]
                  ++ ["-Dtest=" ++ intercalate' "," [name ++ "#" ++ intercalate' "+" (nub [if isModel e then entryText "name" e else entryText "name" e ++ "_*" | e <- laws]) | (name, laws) <- byClass]]
              )
              [("LAWSPEC_CASE", Just "")]
              (Just (JUnitDirectory "target/surefire-reports"))
              (Just (\test -> [e | e <- entries, classnameOf test == Just (scopeOr e (className (entryText "file" e) "src/test/java" ".java")), named e (testName test)]))
              Nothing
          ]
  "kotlin" ->
    Right
      [ let filter'
              | any isModel laws = "(" ++ intercalate' "|" (nub [regexEscape (entryText "name" e) ++ (if isModel e then "" else "_.*") | e <- laws]) ++ ")"
              | otherwise = "(" ++ intercalate' "|" [entryText "name" e ++ "_" | e <- laws] ++ ")*"
            name = className file "src/test/kotlin" ".kt"
         in NativeRun
              laws
              (setting "gradle" "gradle")
              (["--offline" | offline] ++ ["--console=plain", "--no-watch-fs", "test"] ++ ["koverXmlReport" | isJust coverage] ++ ["--rerun", "--tests", name])
              [("kotest.filter.tests", Just filter'), ("kotest_filter_tests", Just filter')]
              (Just (JUnitDirectory "build/test-results/test"))
              (Just (\test -> [e | e <- laws, classnameOf test == Just (scopeOr e name), named e (testName test)]))
              Nothing
      | (file, laws) <- groupOn (entryText "file") entries
      ]
  "scala" ->
    Right
      [ let name = className file "src/test/scala" ".scala"
            directory = join scratch ("scalatest-" ++ show n)
            testRoot = maybe "src/test/scala" jsString (truthyField "testDir")
            measured = case coverage of
              Just c -> ["-O", "-coverage-out:" ++ resolve c "data", "-O", "-coverage-exclude-files:.*/" ++ regexEscape testRoot ++ "/.*"]
              Nothing -> []
            selectors = lastByKey [((if isModel e then "exact:" else "prefix:") ++ entryText "name" e, e) | e <- laws]
         in NativeRun
              laws
              (setting "scala" "scala")
              ( ["test", "."]
                  ++ (if offline then ["--power", "--offline"] else [])
                  ++ measured
                  ++ ["--test-only", name, "--"]
                  ++ concat [if isModel e then ["-t", entryText "name" e] else ["-z", entryText "name" e ++ "_"] | e <- selectors]
                  ++ ["-u", directory]
              )
              []
              (Just (JUnitDirectory (nonEmpty (relative root directory) ".")))
              (Just (\test -> [e | e <- laws, classnameOf test == Just (scopeOr e name), named e (testName test)]))
              Nothing
      | (n, (file, laws)) <- zip [0 :: Int ..] (groupOn (entryText "file") entries)
      ]
  "clojure" ->
    let ns e = scopeOr e (replaceChar '_' '-' (replaceChar '/' '.' (without (relativeTo (entryText "file" e) "test") ".clj")))
        selectors = lastByKey [((if isModel e then "exact:" else "prefix:") ++ ns e ++ "/" ++ entryText "name" e, e) | e <- entries]
     in Right
          [ NativeRun
              entries
              (setting "clojure" "clojure")
              (["-M:test"] ++ concat [[if isModel e then "--select-exact" else "--select", ns e ++ "/" ++ entryText "name" e ++ (if isModel e then "" else "--")] | e <- selectors])
              []
              (Just (JUnitDirectory "target/test-results"))
              (Just (\test -> [e | e <- entries, classnameOf test == Just (ns e), if isModel e then testName test == entryText "name" e else (entryText "name" e ++ "--") `isPrefixOf` testName test]))
              Nothing
          ]
  "groovy" ->
    let name e = className (entryText "file" e) "src/test/groovy" ".groovy"
     in Right
          [ NativeRun
              entries
              (setting "gradle" "gradle")
              ( ["--offline" | offline]
                  ++ ["--console=plain", "--no-watch-fs", "test"]
                  ++ ["jacocoTestReport" | isJust coverage]
                  ++ ["--rerun"]
                  ++ concatMap (\selector -> ["--tests", selector]) (nub [scopeOr e (name e) ++ "." ++ entryText "name" e ++ (if isModel e then "" else ": *") | e <- entries])
              )
              [("LAWSPEC_CASE", Just "")]
              (Just (JUnitDirectory "build/test-results/test"))
              (Just (\test -> [e | e <- entries, classnameOf test == Just (scopeOr e (name e)), if isModel e then testName test == entryText "name" e else (entryText "name" e ++ ": ") `isPrefixOf` testName test]))
              Nothing
          ]
  "rust" ->
    Right
      [ NativeRun
          laws
          "cargo"
          ( ["llvm-cov" | isJust coverage]
              ++ ["--no-report" | isJust coverage]
              ++ ["test"]
              ++ ["--offline" | offline]
              ++ ["--test", posixBasename file ".rs", "--"]
              ++ ( if any isModel (take 1 laws)
                     then "--exact" : nub (map (entryText "name") laws)
                     else nub [entryText "name" e ++ "::" | e <- laws]
                 )
          )
          []
          (Just RustLines)
          (Just (\test -> [e | e <- laws, if isModel e then testName test == entryText "name" e else (entryText "name" e ++ "::") `isPrefixOf` testName test]))
          Nothing
      | (file, group) <- groupOn (entryText "file") entries,
        laws <- filter (not . null) [filter (not . isModel) group, filter isModel group]
      ]
  l
    | l `elem` ["fsharp", "csharp"] ->
        let report = "lawspec-junit.xml"
            results = resolve scratch "dotnet-results"
            measured = (\c -> resolve c "dotnet.cobertura.xml") <$> coverage
         in Right
              [ NativeRun
                  entries
                  "dotnet"
                  ( ["test"]
                      ++ concatMap (\e -> ["--filter-query", "/*/*/*/" ++ entryText "name" e ++ "_*", "--filter-query", "/*/*/*/" ++ entryText "name" e]) entries
                      ++ ["--report-xunit-junit", "--report-xunit-junit-filename", report, "--results-directory", results]
                      ++ maybe [] (\m -> ["--coverage", "--coverage-output-format", "cobertura", "--coverage-output", m]) measured
                  )
                  []
                  (Just (JUnitFiles [join results report]))
                  (Just (\test -> [e | e <- entries, dotnetName (entryText "label" e) (testName test)]))
                  Nothing
              ]
  "swift" ->
    let results = resolve scratch "."
        suite e = posixBasename (entryText "file" e) ".swift"
        ordered = [e | e <- entries, member "scope" e == Just (JString "ordered")]
        output = if null ordered then "swift-lawspec" else "swift-lawspec-" ++ token
        files = [join results (output ++ "-swift-testing.xml")]
        events = join results (output ++ ".jsonl")
        selector e
          | member "scope" e == Just (JString "ordered") = regexEscape (suite e) ++ "/ordered\\("
          | otherwise = regexEscape (suite e) ++ "/" ++ regexEscape (entryText "name" e) ++ "(_[A-Za-z0-9]+)?\\("
        lawsJson = compact (JArray [jsObject ([("unit", u) | Just u <- [member "unit" e]] ++ [("name", n) | Just n <- [member "name" e]]) | e <- ordered])
     in Right
          [ NativeRun
              entries
              (setting "swift" "swift")
              (["test"] ++ ["--enable-code-coverage" | isJust coverage] ++ concatMap (\s -> ["--filter", s]) (nub (map selector entries)) ++ ["--xunit-output", join results (output ++ ".xml")])
              [ ("LAWSPEC_SWIFT_LAWS", Just lawsJson),
                ("LAWSPEC_SWIFT_REPORT", Just (if null ordered then "" else events)),
                ("LAWSPEC_SWIFT_RUN", Just (if null ordered then "" else token))
              ]
              ( Just $
                  if null ordered
                    then JUnitFiles files
                    else
                      SwiftEvents
                        files
                        events
                        token
                        [ SwiftGroup
                            (fromMaybe JNull (member "unit" e))
                            (fromMaybe JNull (member "name" e))
                            (suite e)
                            ( case member "knownDiscrepancy" e of
                                Just (JString _) -> 1
                                _ -> max 1 (fromMaybe 1 (entryField "coverage" e >>= entryField "cases" >>= wholeNumber))
                            )
                        | e <- ordered
                        ]
              )
              ( Just
                  ( \result ->
                      [ e
                      | e <- entries,
                        if member "scope" e == Just (JString "ordered")
                          then member "unit" result == member "unit" e && member "nativeName" result == member "name" e
                          else maybe False ((== suite e) . lastSegment) (classnameOf result) && swiftName (entryText "name" e) (testName result)
                      ]
                  )
              )
              Nothing
          ]
  "haskell" ->
    let module' e = replaceChar '/' '.' (without (relativeTo (entryText "file" e) "test") "Spec.hs")
        matches =
          nub
            [ if isModel e
                then "/" ++ scopeOr e (module' e) ++ "/" ++ entryText "unit" e ++ " models/" ++ entryText "name" e ++ "/"
                else module' e ++ "/" ++ entryText "name" e ++ "_"
            | e <- entries
            ]
     in Right
          [ NativeRun
              entries
              "stack"
              (["--no-terminal", "test"] ++ ["--coverage" | isJust coverage] ++ ["--test-arguments", unwords' ["--match " ++ (if ' ' `elem` m then compact (JString m) else m) | m <- matches]])
              []
              (Just HspecLines)
              (Just (\test -> [e | e <- entries, classnameOf test == Just (scopeOr e (module' e)), named e (testName test)]))
              Nothing
          ]
  _ -> Left ("lawspec test does not support " ++ language')
  where
    language' = language target
    offline = optionOffline options
    scratch = optionScratch options
    coverage = optionCoverage options
    root = optionRoot options
    token = optionToken options
    setting key fallback = case entryField key target of
      Just value | isTruthy value -> jsString value
      _ -> fallback
    truthyField key = case entryField key target of
      Just value | isTruthy value -> Just value
      _ -> Nothing
    testDir = case entryField "generatedTestDir" target of
      Just value -> Just value
      Nothing -> entryField "testDir" target
    relativeTo file defaultDir =
      let directory = case testDir of
            Just value | isTruthy value -> jsString value
            _ -> defaultDir
       in fromMaybe file (after (directory ++ "/") file)
    className file defaultDir extension = replaceChar '/' '.' (without (relativeTo file defaultDir) extension)
    scopeOr e fallback = maybe fallback jsString (entryField "scope" e)
    nonEmpty text fallback = if null text then fallback else text
    lastSegment text = reverse (takeWhile (/= '.') (reverse text))
    -- new Map(entries.map(e => [key, e])).values(): each key at its first
    -- place, with its last entry.
    lastByKey pairs = [last [e | (k', e) <- pairs, k' == k] | k <- nub (map fst pairs)]
    wholeNumber = \case
      JNumber n | Just i <- toWhole n -> Just i
      _ -> Nothing
    toWhole n = let i = round n :: Integer in if fromInteger i == n then Just i else Nothing
    beam l =
      let file = join scratch ("beam-" ++ token ++ ".jsonl")
          identity e = entryText "unit" e ++ "::" ++ entryText "name" e
          matching test = [e | e <- entries, member "identity" test == Just (JString (identity e))]
          measuredFile c = resolve c ("runs/" ++ token ++ ".coverdata")
          measured =
            ( \c ->
                jsObject
                  ( [("run", JString token), ("file", JString (measuredFile c))]
                      ++ (if l == "elixir" then [("beamDirectory", v) | Just v <- [optionCoverageConfig options >>= member "compilePath"]] else [])
                      ++ [("tool", JString "rebar3") | l == "erlang"]
                      ++ [("metadata", JString (resolve c ("runs/" ++ token ++ ".json"))) | l == "gleam"]
                  )
            )
              <$> coverage
          lawsJson = compact (JArray [jsObject ([("unit", u) | Just u <- [member "unit" e]] ++ [("name", n) | Just n <- [member "name" e]]) | e <- entries])
          base = [("LAWSPEC_BEAM_REPORT", Just file), ("LAWSPEC_BEAM_RUN", Just token)]
       in do
            (command, arguments, variables) <- case l of
              "elixir" -> do
                coverageArguments <- case coverage of
                  Nothing -> Right []
                  Just c -> case optionCoverageConfig options of
                    Just config
                      | member "tool" config == Just (JString "Mix.Tasks.Test.Coverage"),
                        Just output <- member "output" config,
                        isTruthy output,
                        Just compilePath <- member "compilePath" config,
                        isTruthy compilePath ->
                          Right ["--cover", "--export-coverage", relative (resolve root (jsString output)) (without (measuredFile c) ".coverdata")]
                    _ -> Left "BEAM coverage requires Mix.Tasks.Test.Coverage and its effective output directory from lawspec doctor"
                Right
                  ( "mix",
                    ["test"] ++ nub (map (entryText "file") entries) ++ concatMap (\e -> ["--only", "lawspec_identity:" ++ identity e]) entries ++ coverageArguments,
                    base ++ [("HEX_OFFLINE", Just "1") | offline]
                  )
              "erlang" ->
                Right
                  ( "rebar3",
                    ["eunit", "--generator", "lawspec_generated_tests:lawspec_test_"] ++ maybe [] (\c -> ["--cover", "--cover_export_name", without (measuredFile c) ".coverdata"]) coverage,
                    base ++ [("LAWSPEC_BEAM_LAWS", Just lawsJson)]
                  )
              _ ->
                Right
                  ( "gleam",
                    ["test", "--target", "erlang"],
                    base ++ [("LAWSPEC_BEAM_LAWS", Just lawsJson)] ++ [("LAWSPEC_BEAM_COVERAGE", Just (compact m)) | Just m <- [measured]]
                  )
            Right [NativeRun entries command arguments variables (Just (BeamEvents file token)) (Just matching) measured]
    python n (file, selected) =
      let laws = filter (not . isModel) selected
          models = filter isModel selected
          report = join scratch ("pytest-" ++ show n ++ ".xml")
          workers = if optionXdist options && any (truthy "parallel") selected then ["-p", "xdist", "-n", "auto"] else []
          pytest = ["-m", "pytest", "-q"] ++ workers ++ [file, "-k", intercalate' " or " [entryText "name" e ++ "__" | e <- laws], "--junitxml=" ++ report]
          measuredArguments arguments = case coverage of
            Just c -> ["-m", "coverage", "run", "--append", "--data-file=" ++ join c ".coverage"] ++ drop 1 arguments
            Nothing -> arguments
          modelReport = join scratch ("pytest-model-" ++ show n ++ ".xml")
          modelArguments = ["-m", "pytest", "-q"] ++ workers ++ nub [file ++ "::" ++ entryText "name" e | e <- models] ++ ["--junitxml=" ++ modelReport]
       in [ NativeRun laws (setting "python" "python3") (measuredArguments pytest) [] (Just (JUnitFiles [report])) (Just (\test -> [e | e <- laws, (entryText "name" e ++ "__") `isPrefixOf` testName test])) Nothing
          | not (null laws)
          ]
            ++ [ NativeRun models (setting "python" "python3") (measuredArguments modelArguments) [] (Just (JUnitFiles [modelReport])) (Just (\test -> [e | e <- models, testName test == entryText "name" e])) Nothing
               | not (null models)
               ]
    javascript l =
      let files = nub [if l == "typescript" then "dist/" ++ without (entryText "file" e) ".ts" ++ ".js" else entryText "file" e | e <- entries]
          file = join scratch "node-events.jsonl"
          pattern e
            | isModel e = "^" ++ regexEscape (entryText "label" e) ++ "$"
            | otherwise = "^" ++ regexEscape (entryText "label" e) ++ "( example: .*| boundary \\d+| property| known discrepancy| skipped| replay| search)?$"
          matching test = [e | e <- entries, javascriptName e (testName test)]
          node =
            ["--test"]
              ++ ["--test-concurrency=" ++ show (max 2 (fromMaybe 2 (optionProcessors options))) | any (truthy "parallel") entries]
              ++ [ "--test-name-pattern=(" ++ intercalate' "|" (map pattern entries) ++ ")",
                   "--test-reporter=spec",
                   "--test-reporter-destination=stdout",
                   "--test-reporter=" ++ reporterUrl,
                   "--test-reporter-destination=" ++ file
                 ]
              ++ files
          run =
            NativeRun
              entries
              (if isJust coverage then "npx" else optionNode options)
              (maybe node (\c -> ["--no-install", "c8", "--reporter=text", "--reports-dir=" ++ c, optionNode options] ++ node) coverage)
              [("LAWSPEC_NODE_RUN", Just token), ("NODE_TEST_CONTEXT", Nothing)]
              (Just (NodeEvents file token))
              (Just matching)
              Nothing
       in if l == "typescript" then [NativeRun [] "npm" ["exec", "--", "tsc", "-p", "tsconfig.json"] [] Nothing Nothing Nothing, run] else [run]
    -- \^label( example: .*| boundary \d+| property| known discrepancy| skipped| replay| search)?$
    javascriptName e name = case after (entryText "label" e) name of
      Nothing -> False
      Just rest
        | isModel e -> null rest
        | otherwise ->
            null rest
              || rest `elem` [" property", " known discrepancy", " skipped", " replay", " search"]
              || maybe False anyLine (after " example: " rest)
              || maybe False (\r -> digits1 r == Just "") (after " boundary " rest)
    -- \^label( (example \d+: .*|boundary(?: \d+(?: — .*)?(?:\(caseIndex: \d+\))?)?|statistics|property|search|replay|skipped|known discrepancy))?$
    dotnetName label name = case after label name of
      Nothing -> False
      Just "" -> True
      Just rest -> case after " " rest of
        Nothing -> False
        Just kind ->
          kind `elem` ["statistics", "property", "search", "replay", "skipped", "known discrepancy"]
            || maybe False (\r -> maybe False anyLine (digits1 r >>= after ": ")) (after "example " kind)
            || maybe False boundary (after "boundary" kind)
    boundary rest
      | null rest = True
      | otherwise = case after " " rest >>= digits1 of
          Nothing -> False
          Just tail' -> null tail' || maybe False anyLine (after " \x2014 " tail') || caseIndex tail'
    caseIndex text = case after "(caseIndex: " text >>= digits1 of
      Just ")" -> True
      _ -> False
    -- \^name(_[A-Za-z0-9]+)?(\(|$)
    swiftName name text = case after name text of
      Nothing -> False
      Just rest ->
        callOrEnd rest || case rest of
          '_' : more -> case span alphanumeric more of
            (_ : _, tail') -> callOrEnd tail'
            _ -> False
          _ -> False
    callOrEnd text = null text || take 1 text == "("
    alphanumeric c = isAsciiLower c || isAsciiUpper c || isDigit c

intercalate' :: String -> [String] -> String
intercalate' _ [] = ""
intercalate' separator items = foldr1 (\a b -> a ++ separator ++ b) items

unwords' :: [String] -> String
unwords' = intercalate' " "

-- | The invocations that run the harness's benchmarks (--benchmarks), by
-- the names the manifest gives them.
benchmarkInvocations :: Json -> [Json] -> Bool -> FilePath -> Either String [(String, [String], [(String, Maybe String)])]
benchmarkInvocations _ [] _ _ = Right []
benchmarkInvocations target entries offline node = case l of
  "prolog" -> Right [(setting "python" "python3", "lawspec_test.py" : concatMap (\e -> ["--select", entryText "file" e ++ "::" ++ entryText "name" e]) entries, [])]
  "erlang" -> Right [("rebar3", ["eunit", "--generator", posixBasename (entryText "file" e) ".erl" ++ ":" ++ entryText "name" e ++ "_cases"], []) | e <- entries]
  "elixir" -> Right [("mix", ["test", file] ++ concatMap (\e -> ["--only", "lawspec:" ++ entryText "name" e]) marks, []) | (file, marks) <- groupOn (entryText "file") entries]
  "gleam" ->
    Right
      [ ( "gleam",
          ["test", "--target", "erlang"],
          [("LAWSPEC_BEAM_BENCHMARKS", Just (compact (JArray [JObject [("module", JString (posixBasename (entryText "file" e) ".gleam")), ("function", JString (entryText "name" e ++ "_test"))] | e <- entries])))]
        )
      ]
  "python" -> Right [(setting "python" "python3", ["-m", "pytest", "-q", "-s", file, "-k", intercalate' " or " (map (entryText "name") marks)], []) | (file, marks) <- groupOn (entryText "file") entries]
  _
    | l `elem` ["javascript", "typescript"] ->
        let files = nub [if l == "typescript" then "dist/" ++ without (entryText "file" e) ".ts" ++ ".js" else entryText "file" e | e <- entries]
            run = (node, ["--test", "--test-name-pattern=^(" ++ intercalate' "|" (map (regexEscape . entryText "name") entries) ++ ")$"] ++ files, [])
         in Right (if l == "typescript" then [("npm", ["exec", "--", "tsc", "-p", "tsconfig.json"], []), run] else [run])
  "go" -> Right [("go", ["test", "-count=1", "-v", "./" ++ directory, "-run", "^(" ++ intercalate' "|" (map (regexEscape . entryText "name") marks) ++ ")$"], []) | (directory, marks) <- groupOn (posixDirname . entryText "file") entries]
  "java" ->
    let byClass = groupOn (\e -> className (entryText "file" e) "src/test/java" ".java") entries
     in Right [(setting "maven" "mvn", ["-o" | offline] ++ ["-B", "test", "-Dtest=" ++ intercalate' "," [name ++ "#" ++ intercalate' "+" (map (entryText "name") marks) | (name, marks) <- byClass]], [("LAWSPEC_CASE", Just "")])]
  "kotlin" ->
    Right
      [ let filter' = "(" ++ intercalate' "|" (map (entryText "name") marks) ++ ")"
         in (setting "gradle" "gradle", ["--offline" | offline] ++ ["--console=plain", "--no-watch-fs", "test", "--rerun", "--tests", className file "src/test/kotlin" ".kt"], [("kotest.filter.tests", Just filter'), ("kotest_filter_tests", Just filter')])
      | (file, marks) <- groupOn (entryText "file") entries
      ]
  "clojure" ->
    let ns file = replaceChar '_' '-' (replaceChar '/' '.' (without (relativeTo file "test") ".clj"))
     in Right [(setting "clojure" "clojure", "-M:test" : concatMap (\e -> ["--select", ns (entryText "file" e) ++ "/" ++ entryText "name" e]) entries, [])]
  "groovy" -> Right [(setting "gradle" "gradle", ["--offline" | offline] ++ ["--console=plain", "--no-watch-fs", "test", "--rerun"] ++ concatMap (\e -> ["--tests", className (entryText "file" e) "src/test/groovy" ".groovy" ++ "." ++ entryText "name" e]) entries, [("LAWSPEC_CASE", Just "")])]
  "rust" -> Right [("cargo", ["test"] ++ ["--offline" | offline] ++ ["--test", posixBasename file ".rs", "--", "--exact", "--nocapture"] ++ map (entryText "name") marks, []) | (file, marks) <- groupOn (entryText "file") entries]
  _ | l `elem` ["fsharp", "csharp"] -> Right [("dotnet", "test" : concatMap (\e -> ["--filter-query", "/*/*/*/" ++ entryText "name" e]) entries, [])]
  "scala" -> Right [(setting "scala" "scala", ["test", "."] ++ ["--offline" | offline] ++ ["--test-only", className file "src/test/scala" ".scala", "--"] ++ concatMap (\e -> ["-z", entryText "name" e]) marks, []) | (file, marks) <- groupOn (entryText "file") entries]
  "swift" ->
    Right
      [ ( setting "swift" "swift",
          "test" : concatMap (\e -> ["--filter", "/" ++ regexEscape (entryText "name" e) ++ "\\(", "--filter", regexEscape (posixBasename (entryText "file" e) ".swift") ++ "/ordered\\("]) entries,
          [ ("LAWSPEC_SWIFT_LAWS", Just (compact (JArray [jsObject ([("unit", u) | Just u <- [member "unit" e]] ++ [("name", n) | Just n <- [member "name" e]]) | e <- entries]))),
            ("LAWSPEC_SWIFT_REPORT", Just ""),
            ("LAWSPEC_SWIFT_RUN", Just "")
          ]
        )
      ]
  "haskell" ->
    let module' e = replaceChar '/' '.' (without (relativeTo (entryText "file" e) "test") "Spec.hs")
     in Right [("stack", ["--no-terminal", "test", "--test-arguments", unwords' (nub ["--match " ++ module' e ++ "/benchmark" | e <- entries])], [])]
  _ -> Left ("lawspec test does not support " ++ l)
  where
    l = language target
    setting key fallback = case entryField key target of
      Just value | isTruthy value -> jsString value
      _ -> fallback
    testDir = case entryField "generatedTestDir" target of
      Just value -> Just value
      Nothing -> entryField "testDir" target
    relativeTo file defaultDir =
      let directory = case testDir of
            Just value | isTruthy value -> jsString value
            _ -> defaultDir
       in fromMaybe file (after (directory ++ "/") file)
    className file defaultDir extension = replaceChar '/' '.' (without (relativeTo file defaultDir) extension)

-- | What --coverage needs on each target, and how to say it is missing:
-- the tool, the probe's arguments (Python's) and how to install it.
coverageTool :: String -> Maybe (String, Maybe [String], String)
coverageTool = \case
  "erlang" -> Just ("OTP cover", Nothing, "install Erlang/OTP with the tools application")
  "elixir" -> Just ("OTP cover", Nothing, "install Erlang/OTP with the tools application")
  "gleam" -> Just ("OTP cover", Nothing, "install Erlang/OTP with the tools application")
  "python" -> Just ("coverage.py", Just ["-c", "import coverage"], "python -m pip install coverage")
  "javascript" -> Just ("c8", Nothing, "npm install --save-dev c8")
  "typescript" -> Just ("c8", Nothing, "npm install --save-dev c8")
  "go" -> Just ("go test -cover", Nothing, "(built in)")
  "java" -> Just ("JaCoCo", Nothing, "(resolved by Maven as org.jacoco:jacoco-maven-plugin)")
  "kotlin" -> Just ("Kover", Nothing, "add id(\"org.jetbrains.kotlinx.kover\") to the plugins of build.gradle.kts")
  "clojure" -> Just ("cloverage", Nothing, "add cloverage to a :coverage alias in deps.edn")
  "groovy" -> Just ("JaCoCo", Nothing, "add id 'jacoco' to the plugins of build.gradle")
  "rust" -> Just ("cargo-llvm-cov", Nothing, "cargo install cargo-llvm-cov")
  "haskell" -> Just ("hpc", Nothing, "(built into GHC; stack test --coverage)")
  "fsharp" -> Just ("Microsoft code coverage", Nothing, "add the Microsoft.Testing.Extensions.CodeCoverage package to the test project")
  "csharp" -> Just ("Microsoft code coverage", Nothing, "add the Microsoft.Testing.Extensions.CodeCoverage package to the test project")
  "scala" -> Just ("scoverage", Nothing, "(built into Scala 3; Scala CLI fetches the scoverage reporter)")
  "swift" -> Just ("llvm-cov", Nothing, "(built into the Swift toolchain; swift test --enable-code-coverage)")
  _ -> Nothing
