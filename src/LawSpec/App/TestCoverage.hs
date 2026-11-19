-- | lawspec test's coverage collection and Scala build-failure capture,
-- ported from the Node CLI's beam-coverage.mjs, scala-coverage.mjs and
-- scala-build-state.mjs. BEAM line coverage is imported and analysed by an
-- escript (OTP's cover), whose JSON this renders as HTML pages; Scala's is
-- reported by the scoverage reporter, which Scala CLI fetches and runs. A
-- failed Scala compilation's state is kept for diagnosis; it is never
-- native execution evidence.
-- ref:DEC-haskell-application-port ref:DEC-s1j-shared-failures
module LawSpec.App.TestCoverage
  ( beamCoverageRequirement,
    collectBeamCoverage,
    collectScalaCoverage,
    isScalaCompilationFailure,
    captureScalaBuildFailure,
    freshToken,
  )
where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Char (isDigit, toLower)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sortBy)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import LawSpec.App.Command
import LawSpec.App.Files (atomicWrite, compareUtf16)
import LawSpec.App.Json
import LawSpec.App.Process
import LawSpec.App.Project (isoTime)
import LawSpec.App.TestReports (toFixed)
import LawSpec.App.TestRuns (posixBasename)
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, relative, resolve, takeDirectory)

-- | A fresh identity in randomUUID's form. The core has no randomness of
-- its own; the host's clock and the purpose make it unique in a run.
freshToken :: (Monad m) => String -> Command m String
freshToken purpose = do
  clock <- either (const (Clock 0 0)) id <$> effectOr GetClock
  let hex = digestHex (digest (utf8 (purpose ++ "\0" ++ show (wallMilliseconds clock) ++ "\0" ++ show (monotonicMicroseconds clock))))
      part from count = take count (drop from hex)
  pure (part 0 8 ++ "-" ++ part 8 4 ++ "-4" ++ part 13 3 ++ "-" ++ variant (hex !! 16) : part 17 3 ++ "-" ++ part 20 12)
  where
    variant c = "89ab" !! (fromMaybe 0 (lookup c (zip "0123456789abcdef" [0 ..])) `mod` 4)

-- | beamCoverageRequirement: what a BEAM target lacks for source coverage.
beamCoverageRequirement :: Json -> Json -> Maybe (String, String)
beamCoverageRequirement target report
  | language == "gleam" && minor < 19 = Just ("Gleam 1.19 for source coverage", "upgrade Gleam to 1.19 so native counters refer to the original source lines")
  | language == "elixir" && (member "coverage" report >>= member "tool") /= Just (JString "Mix.Tasks.Test.Coverage") =
      Just ("Mix.Tasks.Test.Coverage", "set test_coverage[:tool] to Mix.Tasks.Test.Coverage in mix.exs")
  | otherwise = Nothing
  where
    language = maybe "" jsString (member "language" target)
    -- Number(report?.versions?.gleam?.split('.')[1] ?? 0)
    minor :: Double
    minor = case member "versions" report >>= member "gleam" of
      Just (JString version) -> case drop 1 (splitOn '.' version) of
        part : _ -> case reads part of
          [(n, "")] | all isDigit part, not (null part) -> n
          _ -> if null part then 0 else 1 / 0
        [] -> 0
      _ -> 0

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn separator rest

collector :: String
collector =
  unlines
    [ "#!/usr/bin/env escript",
      "-mode(compile).",
      "main([Input, Output]) ->",
      "    try",
      "        {ok, Bytes} = file:read_file(Input),",
      "        #{<<\"runs\">> := Runs, <<\"directory\">> := Directory} = json:decode(Bytes),",
      "        {ok, _} = cover:start(),",
      "        [ok = cover:import(text(maps:get(<<\"file\">>, Run))) || Run <- Runs],",
      "        Beams = lists:foldl(fun(Run, Acc) -> maps:merge(Acc, maps:get(<<\"beams\">>, Run, #{})) end, #{}, Runs),",
      "        Modules = [analyse(Module, text(Directory), Beams) || Module <- lists:sort(cover:imported_modules())],",
      "        true = Modules =/= [],",
      "        ok = file:write_file(Output, json:encode(Modules)),",
      "        cover:stop()",
      "    catch Class:Reason:Stack ->",
      "        io:format(standard_error, \"Cannot collect BEAM coverage: ~tp:~tp~n~tp~n\", [Class, Reason, Stack]), halt(1)",
      "    end.",
      "",
      "analyse(Module, Directory, Beams) ->",
      "    {ok, Calls} = cover:analyse(Module, calls, line),",
      "    Lines = lists:foldl(fun",
      "        ({{_, Line}, Hits}, Acc) when Line > 0 -> maps:update_with(Line, fun(N) -> N + Hits end, Hits, Acc);",
      "        (_, Acc) -> Acc",
      "    end, #{}, Calls),",
      "    Name = atom_to_binary(Module),",
      "    Rows = [#{line => Line, hits => Hits} || {Line, Hits} <- lists:sort(maps:to_list(Lines))],",
      "    case maps:find(Name, Beams) of",
      "        {ok, Beam} -> #{name => Name, lines => Rows, source => source(Module, text(Beam))};",
      "        error ->",
      "            File = binary_to_list(binary:encode_hex(crypto:hash(sha256, Name), lowercase)) ++ \".html\",",
      "            {ok, _} = cover:analyse_to_file(Module, [html, {outfile, filename:join(Directory, File)}]),",
      "            #{name => Name, lines => Rows, report => unicode:characters_to_binary(File)}",
      "    end.",
      "",
      "source(Module, Beam) ->",
      "    {ok, {Module, [{compile_info, Info}]}} = beam_lib:chunks(Beam, [compile_info]),",
      "    Source = case proplists:get_value(source, Info) of",
      "        undefined ->",
      "            {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(Beam, [abstract_code]),",
      "            [File | _] = [F || {attribute, _, file, {F, _}} <- Forms], File;",
      "        File -> File",
      "    end,",
      "    unicode:characters_to_binary(Source).",
      "text(Value) -> unicode:characters_to_list(Value)."
    ]

-- | beam-coverage.mjs escape.
escapeHtml :: String -> String
escapeHtml = concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#39;"
  c -> [c]

percentage :: (Integer, Integer) -> String
percentage (covered, total)
  | total == 0 = "no executable lines"
  | otherwise = toFixed 1 (100 * fromInteger covered / fromInteger total) ++ "%"

page :: String -> String -> String
page title body =
  "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>"
    ++ escapeHtml title
    ++ "</title>\n<style>body{font:16px system-ui;margin:2rem;color:#222}table{border-collapse:collapse;width:100%}td,th{padding:.3rem .7rem;text-align:left;border-bottom:1px solid #ddd}pre{margin:0;tab-size:4}.hit{background:#e4f5e9}.miss{background:#ffe6e6}.line,.count{width:4rem;text-align:right;color:#555}a{color:#174da8}</style>\n<h1>"
    ++ escapeHtml title
    ++ "</h1>"
    ++ body
    ++ "</html>\n"

-- | collectBeamCoverage: the coverage the runs exported, analysed by the
-- collector escript and written as coverage.json and HTML pages. Only
-- exports this run's invocations named are imported; a missing export is
-- an error even when the runner exited successfully. Nothing when no run
-- was measured.
collectBeamCoverage :: (Monad m) => FilePath -> FilePath -> [Json] -> Command m (Maybe Json)
collectBeamCoverage _ _ [] = pure Nothing
collectBeamCoverage root directory runs = do
  -- beam-coverage.mjs assembled the pages in a folder of os.tmpdir(); the
  -- guard lets the core remove only what lies strictly inside a write
  -- root, so they are assembled in the coverage folder instead and the
  -- folder is removed all the same.
  token <- freshToken "beam-coverage"
  let temporary = join directory (".lawspec-beam-coverage-" ++ take 6 (filter (/= '-') token))
  effect (nodeFailure "mkdtemp" temporary) (MakeDirectories Nothing temporary)
  result <- recover (Right <$> collect temporary) (pure . Left)
  _ <- effectOr (Remove Recursive temporary)
  either abort (pure . Just) result
  where
    text key value = maybe "" jsString (member key value)
    collect temporary = do
      (inputs, _, _) <-
        foldM
          ( \(kept, seen, rebar) run -> do
              let name = text "run" run
                  file = text "file" run
              when (null name || name `elem` seen || posixBasename file "" /= name ++ ".coverdata") (failWith "Invalid or duplicate BEAM coverage invocation")
              grantRead [file]
              info <- effectOr (Stat Follow file)
              case info of
                Right status | statusKind status == FileKind, statusSize status > 0 -> pure ()
                _ -> failWith ("Native runner did not export coverage for " ++ name ++ ": " ++ file)
              rebar' <-
                if member "tool" run == Just (JString "rebar3") && rebar == Nothing
                  then do
                    found <- execTool (launch "rebar3" ["as", "test", "path", "--ebin", "--separator", "\n"] root)
                    directories <- either failWith (pure . filter (not . null) . lines . trimText) found
                    when (null directories || not (all isAbsolute directories)) (failWith "Cannot resolve Rebar's application beam directories after coverage")
                    pure (Just directories)
                  else pure rebar
              let directories
                    | member "tool" run == Just (JString "rebar3") = fromMaybe [] rebar'
                    | Just (JArray items) <- member "beamDirectories" run = map jsString items
                    | Just value <- member "beamDirectory" run, isTruthy value = [jsString value]
                    | otherwise = []
              beams <-
                foldM
                  ( \acc folder -> do
                      grantRead [folder]
                      entries <- effect (nodeFailure "scandir" folder) (ListDirectory folder)
                      pure (Just (fromMaybe [] acc ++ [(take (length n - 5) n, JString (resolve folder n)) | Entry n _ <- entries, ".beam" `isSuffixOf` n]))
                  )
                  Nothing
                  directories
              beams' <- case member "metadata" run of
                Just (JString metadataFile) -> do
                  grantRead [metadataFile]
                  raw <- effect (nodeFailure "open" metadataFile) (ReadFile metadataFile)
                  metadata <- either failWith pure (parseJson (fromUtf8 raw))
                  let modules = fromMaybe [] (member "modules" metadata >>= arrayOf)
                  when (member "run" metadata /= Just (JString name) || member "file" metadata /= Just (JString file) || null modules) $
                    failWith ("Gleam coverage metadata does not match invocation " ++ name)
                  pure (Just [(text "name" m, fromMaybe JNull (member "beam" m)) | m <- modules])
                _ -> pure beams
              pure
                ( kept ++ [jsObject ([("file", JString (resolve root file))] ++ [("beams", jsObject b) | Just b <- [beams']])],
                  seen ++ [name],
                  rebar'
                )
          )
          ([], [], Nothing)
          runs
      let pages = join temporary "modules"
          input = join temporary "input.json"
          output = join temporary "output.json"
          script = join temporary "collect.escript"
      effect (nodeFailure "mkdir" pages) (MakeDirectories Nothing pages)
      atomicWrite script collector False
      atomicWrite input (compact (JObject [("runs", JArray inputs), ("directory", JString pages)])) False
      ran <- runProcess (launch "escript" [script, input, output] root) {launchLimit = Just (8 * 1024 * 1024)}
      unless (runSucceeded ran) (failWith (commandFailed (launch "escript" [script, input, output] root) ran))
      raw <- effect (nodeFailure "open" output) (ReadFile output)
      modules <- either failWith (pure . fromMaybe [] . arrayOf) (parseJson (fromUtf8 raw))
      rendered <- forM modules $ \module' -> do
        let rows = fromMaybe [] (member "lines" module' >>= arrayOf)
            hitsOf row = case member "hits" row of
              Just (JNumber n) -> n
              _ -> 0
            summary = (fromIntegral (length [() | row <- rows, hitsOf row > 0]), fromIntegral (length rows)) :: (Integer, Integer)
            summaryJson = JObject [("covered", integer (fst summary)), ("total", integer (snd summary))]
            withSummary = setMember "summary" summaryJson module'
        case member "source" module' of
          Just source | isTruthy source -> do
            let first = resolve root (jsString source)
            grantRead [first]
            content <- fromUtf8 <$> effect (nodeFailure "open" first) (ReadFile first)
            let marker = "/_gleam_artefacts/"
            source' <-
              if marker `isInfixOf` first
                then do
                  let original = join root (join "src" (lastAfter marker first))
                  grantRead [original]
                  same <- either (const False) ((== content) . fromUtf8) <$> effectOr (ReadFile original)
                  pure (if same then original else first)
                else pure first
            let shown = relative root source'
                sourceLines = splitLines content
                hits = M.fromList [(lineOf row, hitsOf row) | row <- rows]
                lineOf row = case member "line" row of
                  Just (JNumber n) -> n
                  _ -> 0
            when (any ((> fromIntegral (length sourceLines)) . lineOf) rows) (failWith ("Coverage lines do not match source " ++ shown))
            let name = text "name" module'
                report = digestHex (digest (utf8 name)) ++ ".html"
                tableRows =
                  [ "<tr class=\"" ++ maybe "" (\c -> if c /= 0 then "hit" else "miss") count ++ "\" id=\"L" ++ show index ++ "\"><td class=\"line\">" ++ show index ++ "</td><td class=\"count\">" ++ maybe "" (numberText) count ++ "</td><td><pre>" ++ escapeHtml line ++ "</pre></td></tr>"
                  | (index, line) <- zip [1 :: Integer ..] sourceLines,
                    let count = M.lookup (fromInteger index) hits
                  ]
            atomicWrite (join pages report) (page name ("<p>" ++ escapeHtml shown ++ " \x2014 " ++ percentage summary ++ "</p><table>" ++ joinLines tableRows ++ "</table>")) False
            pure (setMember "report" (JString report) (setMember "source" (JString shown) withSummary), summary)
          _ -> pure (withSummary, summary)
      let total = (sum (map (fst . snd) rendered), sum (map (snd . snd) rendered))
          modules' = map fst rendered
          result =
            JObject
              [ ("version", integer 1),
                ("root", JString root),
                ("runs", JArray [fromMaybe JNull (member "run" run) | run <- runs]),
                ("summary", JObject [("covered", integer (fst total)), ("total", integer (snd total))]),
                ("modules", JArray modules')
              ]
          indexRows =
            [ "<tr><td><a href=\"modules/" ++ text "report" m ++ "\">" ++ escapeHtml (text "name" m) ++ "</a></td><td>" ++ show c ++ "/" ++ show t ++ "</td><td>" ++ percentage (c, t) ++ "</td></tr>"
            | (m, (c, t)) <- rendered
            ]
      effect (nodeFailure "mkdir" (join directory "modules")) (MakeDirectories Nothing (join directory "modules"))
      forM_ modules' $ \m -> do
        let report = text "report" m
        bytes <- effect (nodeFailure "open" (join pages report)) (ReadFile (join pages report))
        effect (nodeFailure "open" (join directory ("modules/" ++ report))) (WriteFile Replace Nothing (join directory ("modules/" ++ report)) bytes)
      atomicWrite (join directory "coverage.json") (stringify result ++ "\n") False
      atomicWrite
        (join directory "index.html")
        ( page
            "BEAM line coverage"
            ( "<p>"
                ++ show (fst total)
                ++ "/"
                ++ show (snd total)
                ++ " executable lines covered ("
                ++ percentage total
                ++ "); "
                ++ show (length runs)
                ++ " native run(s).</p><table><thead><tr><th>Module</th><th>Lines</th><th>Coverage</th></tr></thead><tbody>"
                ++ joinLines indexRows
                ++ "</tbody></table>"
            )
        )
        False
      pure result
    lastAfter marker path' = case [i | i <- [0 .. length path' - length marker], marker `isPrefixOf` drop i path'] of
      [] -> path'
      found -> drop (last found + length marker) path'
    trimText = reverse . dropWhile (`elem` (" \t\r\n" :: String)) . reverse . dropWhile (`elem` (" \t\r\n" :: String))
    -- text.split(/\r?\n/)
    splitLines content = case break (== '\n') content of
      (line, []) -> [line]
      (line, _ : rest) -> dropCarriage line : splitLines rest
    dropCarriage line = if "\r" `isSuffixOf` line then init line else line
    joinLines [] = ""
    joinLines items = foldr1 (\a b -> a ++ "\n" ++ b) items

scoverageReporter :: String
scoverageReporter = "2.5.2"

reportScript :: String
reportScript =
  foldr1
    (\a b -> a ++ "\n" ++ b)
    [ "//> using scala 3.9.0",
      "//> using dep org.scoverage::scalac-scoverage-reporter:" ++ scoverageReporter,
      "//> using javaOpt --sun-misc-unsafe-memory-access=allow",
      "import java.io.File",
      "import scoverage.reporter.{CoberturaXmlWriter, IOUtils, ScoverageHtmlWriter, ScoverageXmlWriter}",
      "import scoverage.serialize.Serializer",
      "",
      "@main def report(data: String, sources: String, output: String): Unit = {",
      "  val dataDir = File(data)",
      "  val root = File(sources)",
      "  val coverage = Serializer.deserialize(Serializer.coverageFile(dataDir), root)",
      "  coverage.apply(IOUtils.invoked(IOUtils.findMeasurementFiles(dataDir).toIndexedSeq))",
      "  val out = File(output)",
      "  out.mkdirs()",
      "  CoberturaXmlWriter(Seq(root), out, None).write(coverage)",
      "  ScoverageXmlWriter(Seq(root), out, false, None).write(coverage)",
      "  ScoverageHtmlWriter(Seq(root), out, None).write(coverage)",
      "  println(f\"Statement coverage: ${coverage.statementCoveragePercent}%.2f%%\")",
      "}",
      ""
    ]

-- | collectScalaCoverage: the scoverage reports from the runs' data; False
-- when no run was measured. The reporter's output reaches the CLI's own
-- streams, as stdio: 'inherit' gave it.
collectScalaCoverage :: (Monad m) => FilePath -> FilePath -> String -> Bool -> Command m Bool
collectScalaCoverage root directory command offline = do
  let data' = join directory "data"
  files <- either (const []) (map entryName) <$> effectOr (ListDirectory data')
  if "scoverage.coverage" `notElem` files
    then pure False
    else do
      let script = join directory "reporter/Report.scala"
          arguments = ["run"] ++ ["--offline" | offline] ++ [script, "--", data', root, join directory "report"]
      effect (nodeFailure "mkdir" (takeDirectory script)) (MakeDirectories Nothing (takeDirectory script))
      effect (nodeFailure "open" script) (WriteFile Replace Nothing script (utf8 reportScript))
      ran <- runProcess (launch command arguments (takeDirectory script)) {launchEcho = EchoTo Stdout}
      forM_ (runError ran) failWith
      unless (runExit ran == Just (ExitCode 0)) (failWith ("the scoverage reporter failed (" ++ command ++ " " ++ unwords arguments ++ ")"))
      pure True

-- | /error compiling project|compilation failed|unexpected error when (?:compiling|copying)/i
isScalaCompilationFailure :: String -> Bool
isScalaCompilationFailure output = any (`isInfixOf` lowered) ["error compiling project", "compilation failed", "unexpected error when compiling", "unexpected error when copying"]
  where
    lowered = map toLower output

-- | captureScalaBuildFailure: the failed compiler's state under
-- .lawspec/scala-build-failures/<id>, before an adapter restore or another
-- build changes it; the folder, or nothing when it could not be captured.
captureScalaBuildFailure :: (Monad m) => FilePath -> String -> [String] -> String -> Command m (Maybe FilePath)
captureScalaBuildFailure root0 command arguments output = recover capture (const (pure Nothing))
  where
    capture = do
      root <- effectOr (RealPath root0) >>= either (const (failWith "realpath")) pure
      status <- effectOr (Stat Follow root) >>= either (const (failWith "stat")) pure
      if statusKind status /= DirectoryKind
        then pure Nothing
        else do
          token <- freshToken "scala-build-failure"
          let directory = join root (".lawspec/scala-build-failures/" ++ token)
              build = join root ".scala-build"
          grantRead [root]
          grantWrite [root]
          effect (nodeFailure "mkdir" directory) (MakeDirectories Nothing directory)
          (inventory, configurations, errors) <- visit root directory build ([], [], [])
          clock <- effect (\p -> Failure (errorMessage p) Nothing) GetClock
          let plain = stripColours output
              lines' = splitLines plain
              first = case [i | (i, line) <- zip [0 :: Int ..] lines', isErrorLine line] of
                i : _ -> Just i
                [] -> Nothing
              state =
                JObject
                  [ ("version", integer 1),
                    ("capturedAt", JString (isoTime (wallMilliseconds clock))),
                    ("root", JString root),
                    ("phase", JString "native"),
                    ("command", JString command),
                    ("args", JArray (map JString arguments)),
                    ("firstCompilerError", JArray (maybe [] (\i -> map JString (take (i + 18 - max 0 (i - 2)) (drop (max 0 (i - 2)) lines'))) first)),
                    ("configurations", JArray configurations),
                    ("inventory", JArray inventory),
                    ("errors", JArray errors)
                  ]
          effect (nodeFailure "open" (join directory "state.json")) (WriteFile Replace Nothing (join directory "state.json") (utf8 (stringify state ++ "\n")))
          effect (nodeFailure "open" (join directory "compiler.log")) (WriteFile Replace Nothing (join directory "compiler.log") (utf8 output))
          pure (Just directory)
    isErrorLine line = let lowered = map toLower line in "[error]" `isInfixOf` lowered || "error:" `isInfixOf` lowered
    stripColours text = case text of
      '\x1b' : '[' : rest -> case span (\c -> isDigit c || c == ';') rest of
        (_, 'm' : more) -> stripColours more
        _ -> '\x1b' : stripColours ('[' : rest)
      c : rest -> c : stripColours rest
      [] -> []
    splitLines content = case break (== '\n') content of
      (line, []) -> [line]
      (line, _ : rest) -> line : splitLines rest
    visit root directory folder state@(inventory, configurations, errors) = do
      listed <- effectOr (ListDirectory folder)
      case listed of
        Left problem
          | errorKind problem == NotFound -> pure state
          | otherwise -> pure (inventory, configurations, errors ++ [JObject [("path", JString (relative root folder)), ("code", JString (code problem))]])
        Right entries ->
          foldM
            ( \(inv, conf, errs) (Entry name kind) -> do
                let file = join folder name
                    rel = relative root file
                case kind of
                  SymbolicLinkKind -> pure (inv ++ [JObject [("path", JString rel), ("kind", JString "symlink")]], conf, errs)
                  DirectoryKind -> visit root directory file (inv, conf, errs)
                  FileKind -> do
                    (inv', errs') <-
                      if any (`isSuffixOf` name) [".class", ".tasty", ".betasty", ".sig"]
                        then
                          effectOr (Stat Follow file) >>= \case
                            Right info -> pure (inv ++ [JObject [("path", JString rel), ("bytes", integer (statusSize info)), ("modified", JString (isoTime (statusModified info)))]], errs)
                            Left problem -> pure (inv, errs ++ [JObject [("path", JString rel), ("code", JString (code problem))]])
                        else pure (inv, errs)
                    if takeName folder == ".bloop" && ".json" `isSuffixOf` name
                      then
                        effectOr (ReadFile file) >>= \case
                          Left problem -> pure (inv', conf, errs' ++ [JObject [("path", JString rel), ("code", JString (code problem))]])
                          Right raw -> do
                            effect (nodeFailure "open" (join directory name)) (WriteFile Replace Nothing (join directory name) raw)
                            case parseJson (fromUtf8 raw) of
                              Right value | isObjectValue value -> do
                                let project = fromMaybe JNull (member "project" value)
                                    get key = [(key, v) | Just v <- [member key project]]
                                pure (inv', conf ++ [jsObject ([("file", JString rel)] ++ concatMap get ["name", "directory", "workspaceDir", "classesDir", "sources", "dependencies", "classpath"])], errs')
                              _ -> pure (inv', conf, errs' ++ [JObject [("path", JString rel), ("code", JString "invalid-json")]])
                      else pure (inv', conf, errs')
                  _ -> pure (inv, conf, errs)
            )
            state
            (sortBy (\a b -> localeOrder (entryName a) (entryName b)) entries)
    isObjectValue = \case
      JObject _ -> True
      JArray _ -> True
      _ -> False
    takeName path' = reverse (takeWhile (/= '/') (reverse path'))
    -- localeCompare, approximated: case-insensitive first, then by code unit.
    localeOrder a b = compare (map toLower a) (map toLower b) <> compareUtf16 a b
    code problem = case errorKind problem of
      NotFound -> "ENOENT"
      PermissionDenied -> "EACCES"
      NotADirectory -> "ENOTDIR"
      IsADirectory -> "EISDIR"
      _ -> "EIO"
