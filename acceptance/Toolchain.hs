-- | The native test command for each target, shared by every acceptance suite.
module Toolchain (Toolchain(..), toolchain, Formatter(..), formatter, mutantArguments, compileFailure) where

import Data.Char (toLower, isSpace)
import Data.List (isInfixOf, isSuffixOf, sort, stripPrefix, dropWhileEnd)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory, removePathForcibly, withCurrentDirectory)
import System.IO (readFile')
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (callProcess, readProcess)
import Control.Monad (when)

data Toolchain = Toolchain
  { command :: FilePath
  , arguments :: [String]
  , prepare :: IO ()  -- run before every test invocation
  , report :: IO String  -- output kept outside the console, such as test reports
  }

-- | A target's canonical formatter in check mode, run on the generated
-- sources of a project: generated code must be a fixed point of it. The
-- version is pinned where the formatter is installed (ruff in
-- test/locks/python.txt, Go's release in test/locks/go/gofmt.txt) or
-- checked when it runs (swift-format), and is
-- part of the acceptance cache key.
-- ref:DEC-readable-output-default
data Formatter = Formatter
  { formatterName :: String
  , formatterCommand :: FilePath
  , formatterArguments :: FilePath -> [String]  -- given the directory to check
  , formatterExtensions :: [String]
  , formatterInputs :: [FilePath]  -- files outside the project that pin it
  }

formatter :: String -> IO (Maybe Formatter)
formatter target = do
  root <- getCurrentDirectory
  case target of
    "python" -> do
      python <- maybe (root </> ".integration/python/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- ruff format's default configuration, whatever a project's files say.
      pure (Just (Formatter "ruff format" python
        (\dir -> ["-m", "ruff", "format", "--check", "--diff", "--isolated", "--line-length", "80", "--no-cache", dir]) [".py"]
        ["test/locks/python.txt"]))
    "prolog" -> do
      python <- maybe (root </> ".integration/prolog/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- SWI-Prolog's conventional layout for Prolog (the SWI version is in
      -- the prolog fingerprint) and ruff format for the Python host files.
      pure (Just (Formatter "SWI-Prolog portray_clause and ruff format" "sh"
        (\dir -> ["tools/prolog-formatted.sh", python, dir]) [".pl", ".py"]
        ["tools/prolog-formatted.sh", "tools/prolog-layout.pl", "test/locks/prolog.txt"]))
    -- gofmt comes with Go, so the Go release is the pin: the one named in
    -- test/locks/go/gofmt.txt, or the step fails before checking anything.
    -- gofmt -d exits non-zero when any file would change.
    "go" -> do
      let lock = root </> "test/locks/go/gofmt.txt"
          script = unlines
            [ "want=$(tr -d '[:space:]' < \"$1\")"
            , "have=$(go env GOVERSION) || exit 2"
            , "if [ \"$have\" != \"$want\" ]; then echo \"gofmt is pinned to $want; found $have\"; exit 2; fi"
            , "exec \"$(go env GOROOT)/bin/gofmt\" -d \"$2\"" ]
      pure (Just (Formatter "gofmt" "sh" (\dir -> ["-c", script, "gofmt-check", lock, dir]) [".go"]
        ["test/locks/go/gofmt.txt"]))
    -- Fantomas's default configuration on F# (the program's model and the
    -- runtime, in a C# project too), and dotnet format's whitespace check on
    -- C#. Fantomas is the version in the tool manifest, installed in the
    -- target's integration project; dotnet format is the pinned SDK's.
    t | t `elem` ["fsharp", "csharp"] -> do
      let manifest = "test/locks/dotnet-tools.json"
          sdk = "test/locks/dotnet-sdk.json"
      pinned <- fantomasVersion <$> readFile (root </> manifest)
      let dll = root </> ".integration" </> t </> "fantomas/.store/fantomas" </> pinned </> "fantomas" </> pinned </> "tools/net10.0/any/fantomas.dll"
          script = unlines $
            [ "set -e"
            , "if [ ! -f \"$1\" ]; then echo \"Fantomas " ++ pinned ++ " is not installed: node tools/bootstrap-integration.mjs " ++ t ++ "\" >&2; exit 2; fi"
            , "dotnet \"$1\" --check \"$3\"" ] ++
            [ "cp \"$2\" \"$3/global.json\" && cd \"$3\" && dotnet format whitespace --folder --verify-no-changes ." | t == "csharp" ]
      pure (Just (Formatter (if t == "csharp" then "Fantomas " ++ pinned ++ ", dotnet format" else "Fantomas " ++ pinned) "sh"
        (\dir -> ["-c", script, "sh", dll, root </> sdk, dir]) (".fs" : [".cs" | t == "csharp"]) [manifest, sdk]))
    -- erlfmt, mix format and gleam format, each with its default
    -- configuration, at the versions test/locks/beam-formatters.txt pins:
    -- a different version fails the step rather than checking with another
    -- layout. Elixir and Gleam projects also hold the shared Erlang
    -- modules, which erlfmt checks.
    t | t `elem` ["erlang", "elixir", "gleam"] -> do
      let pinned tool versionCommand expected = "{ out=$(" ++ versionCommand ++ " 2>&1); case \"$out\" in *'" ++ expected ++
            "'*) ;; *) echo \"" ++ tool ++ " must be " ++ expected ++ " (test/locks/beam-formatters.txt), found: $out\"; exit 1;; esac; }"
          erlfmt dir = pinned "erlfmt" "erlfmt --version" "erlfmt version 1.8.0" ++
            " && if [ -n \"$(find " ++ quoted dir ++ " -name '*.erl' | head -1)\" ]; then erlfmt --check " ++ quoted (dir ++ "/**/*.erl") ++ "; fi"
          mix dir = pinned "Elixir" "elixir --version" "Elixir 1.20.4" ++
            " && mix format --dot-formatter " ++ quoted (root </> "test/locks/elixir/formatter.exs") ++ " --check-formatted " ++
            quoted (dir ++ "/**/*.{ex,exs}")
          gleam dir = pinned "gleam" "gleam --version" "gleam 1.19.0" ++ " && gleam format --check " ++ quoted dir
          script dir = case t of
            "erlang" -> erlfmt dir
            "elixir" -> mix dir ++ " && " ++ erlfmt dir
            _ -> gleam dir ++ " && " ++ erlfmt dir
          quoted p = "'" ++ p ++ "'"
      pure (Just (Formatter (case t of "erlang" -> "erlfmt"; "elixir" -> "mix format and erlfmt"; _ -> "gleam format and erlfmt")
        "sh" (\dir -> ["-c", script dir])
        (case t of "erlang" -> [".erl"]; "elixir" -> [".ex", ".exs", ".erl"]; _ -> [".gleam", ".erl"])
        ["test/locks/beam-formatters.txt", "test/locks/elixir/formatter.exs"]))
    -- Prettier's default configuration (pinned in the target's lock), with
    -- no project or repository configuration and no ignore files: the
    -- staging directory sits under the repository's ignored .artifacts.
    t | t `elem` ["javascript", "typescript"] ->
      pure (Just (Formatter "prettier" "node"
        (\dir -> [root </> ".integration" </> t </> "node_modules/prettier/bin/prettier.cjs",
          "--check", "--no-config", "--no-editorconfig", "--plugin", root </> "learn/node_modules/prettier-plugin-brace-style/dist/index.js", "--brace-style", "allman", "--single-quote", "--no-bracket-spacing", "--arrow-parens", "avoid", "--trailing-comma", "all", "--ignore-path", dir </> ".no-ignore", dir])
        [".mjs", ".js", ".ts", ".mts"] ["test/locks" </> t </> "package-lock.json", "learn/package-lock.json", ".prettierrc.json"]))
    -- ormolu has no configuration; its version is pinned in
    -- test/locks/haskell/ormolu.txt and checked before it runs.
    "haskell" -> do
      pinned <- takeWhile (not . isSpace) . dropWhile isSpace . unwords . filter (not . ("#" `isPrefixOf'`)) . lines
        <$> readFile' (root </> "test/locks/haskell/ormolu.txt")
      -- A file ormolu has passed is remembered by its content, so the
      -- runtimes every project copies are checked once.
      let cache = root </> ".artifacts/formatted-cache/ormolu-" ++ pinned
          script = "found=$(ormolu --version | head -n 1); " ++
            "if [ \"$found\" != \"ormolu " ++ pinned ++ "\" ]; then echo \"ormolu " ++ pinned ++ " is required; found: $found\"; exit 2; fi; " ++
            "mkdir -p '" ++ cache ++ "'; " ++
            "find \"$1\" -name '*.hs' | sort | while IFS= read -r f; do " ++
            "h=$(shasum -a 256 \"$f\" | cut -d ' ' -f 1); " ++
            "if [ ! -e '" ++ cache ++ "'/\"$h\" ]; then ormolu --mode check \"$f\" || exit 1; touch '" ++ cache ++ "'/\"$h\"; fi; done"
      pure (Just (Formatter ("ormolu " ++ pinned) "sh" (\dir -> ["-c", script, "sh", dir]) [".hs"]
        ["test/locks/haskell/ormolu.txt"]))
    -- swift-format from the Swift toolchain, at the pinned version, with its
    -- default configuration whatever .swift-format files lie above the
    -- project: generated code must be what it writes.
    "swift" -> pure (Just (Formatter ("swift-format " ++ swiftFormatVersion) "sh"
      (\dir -> ["-c", swiftFormatCheck, "swift-format-check", dir, swiftFormatVersion]) [".swift"] []))
    -- rustfmt's default configuration at the projects' edition (2024),
    -- from the pinned toolchain; rustup installs its rustfmt component.
    -- Files are checked one by one, as cargo fmt would, in a fixed order.
    "rust" -> pure (Just (Formatter ("rustfmt " ++ rustfmtToolchain) "sh"
      (\dir -> ["-c", "find \"$0\" -name '*.rs' | LC_ALL=C sort | xargs rustup run " ++ rustfmtToolchain ++
        " rustfmt --check --edition 2024 --config-path \"" ++ root ++ "/rustfmt.toml\" 2>&1 || exit 1", dir]) [".rs"] ["rustfmt.toml", "test/locks/rustfmt.txt"]))
    -- The JVM targets' formatters, pinned here by their Maven coordinates
    -- and run by Coursier, which fetches each once into its cache.
    -- Java has no canonical formatter: Checkstyle checks LawSpec's profile,
    -- Allman braces with Google Java Style's other rules.
    "java" -> pure (Just (Formatter "checkstyle 14.3.0 (Allman, Google)" "coursier"
      (\dir -> launch "com.puppycrawl.tools.checkstyle.Main" checkstyle ++ ["-c", root </> javaProfile, dir]) [".java"]
      [javaProfile]))
    -- Groovy has no canonical formatter and Checkstyle cannot parse it:
    -- CodeNarc checks the same profile, Allman braces with Google's rules.
    "groovy" -> pure (Just (Formatter "codenarc 4.0.0 (Allman, Google)" "coursier"
      (\dir -> ["launch", "-M", "org.codenarc.CodeNarc", "org.codenarc:CodeNarc:4.0.0", "org.apache.groovy:groovy:5.0.8", "--",
        "-basedir=" ++ dir, "-rulesetfiles=file:" ++ (root </> groovyProfile), "-report=text:stdout",
        "-maxPriority1Violations=0", "-maxPriority2Violations=0", "-maxPriority3Violations=0"]) [".groovy"]
      [groovyProfile]))
    -- ktfmt's kotlinlang style, its default for Kotlin's own conventions.
    "kotlin" -> pure (Just (Formatter "ktfmt 0.64 (kotlinlang)" "coursier"
      (\dir -> launch "com.facebook.ktfmt.cli.Main" "com.facebook:ktfmt:0.64" ++ ["--kotlinlang-style", "--dry-run", "--set-exit-if-changed", dir]) [".kt"]
      []))
    -- scalafmt's default configuration; Scala 3 is the projects' dialect.
    "scala" -> pure (Just (Formatter "scalafmt 3.11.5" "coursier"
      (\dir -> launch "org.scalafmt.cli.Cli" "org.scalameta:scalafmt-cli_2.13:3.11.5" ++
        ["--config-str", "version=3.11.5\nrunner.dialect=scala3", "--test", "--non-interactive", dir]) [".scala"]
      []))
    "clojure" -> pure (Just (Formatter "cljfmt 0.16.6" "coursier"
      (\dir -> ["launch", "-r", "clojars", "-M", "clojure.main", "dev.weavejester:cljfmt:0.16.6", "--", "-m", "cljfmt.main", "check", dir])
      [".clj", ".edn"] []))
    _ -> pure Nothing
  where
    launch main coordinates = ["launch", "-M", main, coordinates, "--"]
    checkstyle = "com.puppycrawl.tools:checkstyle:14.3.0"
    javaProfile = "acceptance/formatters/java-checkstyle.xml"
    groovyProfile = "acceptance/formatters/groovy-codenarc.xml"
    isPrefixOf' p s = take (length p) s == p

-- | The Fantomas version a dotnet tool manifest pins.
fantomasVersion :: String -> String
fantomasVersion manifest = case breakOn "\"fantomas\"" manifest of
  Just rest | Just after <- breakOn "\"version\": \"" rest -> takeWhile (/= '"') after
  _ -> "8.1.0"
  where
    breakOn needle hay = case hay of
      [] -> Nothing
      _ | take (length needle) hay == needle -> Just (drop (length needle) hay)
      _ : more -> breakOn needle more

-- | The swift-format the Swift toolchain carries (swift format), pinned.
swiftFormatVersion :: String
swiftFormatVersion = "6.3.0"

-- | Formats a copy of the directory with swift-format's default
-- configuration and shows any difference; fails when there is one, or when
-- the installed swift-format is not the pinned version.
swiftFormatCheck :: String
swiftFormatCheck = unlines
  [ "set -u"
  , "dir=$1; pinned=$2"
  , "found=$(swift format --version 2>/dev/null)"
  , "if [ \"$found\" != \"$pinned\" ]; then echo \"swift-format $pinned is required; found ${found:-none}\"; exit 2; fi"
  , "work=$(mktemp -d)"
  , "trap 'rm -rf \"$work\"' EXIT"
  , "swift format dump-configuration > \"$work/configuration.json\" || exit 2"
  , "mkdir \"$work/copy\" && cp -R \"$dir\"/. \"$work/copy\""
  , "swift format format --configuration \"$work/configuration.json\" --in-place --recursive \"$work/copy\" || exit 2"
  , "diff -ru \"$dir\" \"$work/copy\"" ]

-- | The Rust toolchain whose rustfmt lays out generated Rust. It is part of
-- the acceptance cache key, as this file is.
rustfmtToolchain :: String
rustfmtToolchain = "nightly-2026-10-22"

-- | Offline builds use existing dependency caches (LAWSPEC_OFFLINE=1).
toolchain :: FilePath -> String -> IO Toolchain
toolchain project target = do
  offline <- (== Just "1") <$> lookupEnv "LAWSPEC_OFFLINE"
  release <- (== Just "1") <$> lookupEnv "LAWSPEC_RUST_RELEASE"
  root <- getCurrentDirectory
  let flag f = [f | offline]
  case target of
    "rust" -> pure (plain "cargo" ("test" : flag "--offline" ++ ["--release" | release]))
    "java" -> pure (plain "mvn" (flag "-o" ++ ["-q", "test"]))
    "python" -> do
      python <- maybe (root </> ".integration/python/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      -- Same-size rewrites within one second can reuse Python's timestamp-based
      -- bytecode cache, so the adapter's cache is always removed first.
      pure (Toolchain python ["-B", "-m", "pytest", "-q"]
        (removePathForcibly (project </> "src/example/__pycache__")) (pure ""))
    "prolog" -> do
      python <- maybe (root </> ".integration/prolog/.venv/bin/python") id <$> lookupEnv "LAWSPEC_PYTHON"
      pure (Toolchain python ["-B", "lawspec_test.py"]
        (removePathForcibly (project </> "src/example/__pycache__")) (pure ""))
    "javascript" -> do
      tests <- sort . filter (".test.mjs" `isSuffixOf`) <$> listDirectory (project </> "test")
      pure (plain "node" ("--test" : map ("test" </>) tests))
    "typescript" -> pure (plain "npm" ["test"])
    "go" -> pure (plain "go" ["test", "./..."])
    "haskell" -> pure (plain "stack" ["--no-terminal", "test"])
    -- Rebar's source timestamps have one-second resolution. A fast mutant
    -- rewrite can otherwise run the preceding adapter's BEAM file. Clear the
    -- project's compiled modules; dependency caches remain reusable.
    "erlang" -> pure (Toolchain "rebar3" ["eunit"]
      (mapM_ (removePathForcibly . (project </>))
        ["_build/test/lib/lawspec_example/ebin", "_build/test/lib/lawspec_example/test"])
      (pure ""))
    -- Mix also misses equal-size source mutations within one timestamp tick.
    -- Remove only the application's BEAM files and compilation manifests.
    "elixir" -> pure (Toolchain "mix" ["test"]
      (mapM_ (removePathForcibly . (project </>))
        ["_build/test/lib/lawspec_example/ebin", "_build/test/lib/lawspec_example/.mix"])
      (pure ""))
    "gleam" -> pure (Toolchain "gleam" ["test"] (prepareCrypto project) (pure ""))
    -- The runner compiles the Java model when it changed, then runs every
    -- test namespace and writes JUnit XML to target/test-results.
    "clojure" -> pure (Toolchain "clojure" ["-M:test"] (pure ()) (xmlReports (project </> "target/test-results")))
    _ | target `elem` ["kotlin", "groovy"] -> do
      let local = root </> ".tools/gradle-9.3.0/bin/gradle"
      gradle <- (\exists -> if exists then local else "gradle") <$> doesFileExist local
      -- Gradle prints failing test names only; assertion messages are in the XML reports.
      pure (Toolchain gradle ["test", "--console=plain"] (pure ()) (xmlReports (project </> "build/test-results/test")))
    -- dotnet test builds the solution incrementally (MSBuild compares file
    -- contents' timestamps at full resolution) and runs it on
    -- Microsoft.Testing.Platform, as global.json selects.
    -- Scala CLI compiles incrementally on its Bloop server.
    "scala" -> pure (plain "scala" (["test", "."] ++ flag "--power" ++ flag "--offline"))
    _ | target `elem` ["fsharp", "csharp"] ->
        pure (Toolchain "dotnet" ("test" : ["--no-restore" | offline])
          (when offline (restoreDotNet project)) (pure ""))
    -- swift test builds incrementally (SwiftPM compares file contents'
    -- timestamps at full resolution) and runs the Swift Testing tests.
    "swift" -> pure (plain "swift" ["test"])
    _ -> ioError (userError ("unknown target: " ++ target))
  where plain c a = Toolchain c a (pure ()) (pure "")

-- Fresh acceptance projects have no generated NuGet imports yet. Restore
-- those from the installed package cache before asking the SDK to select its
-- test runner. A local source and disabled audit keep offline runs offline;
-- missing cached packages fail the restore instead of selecting another runner.
restoreDotNet :: FilePath -> IO ()
restoreDotNet project = do
  output <- readProcess "dotnet" ["nuget", "locals", "global-packages", "--list", "--force-english-output"] ""
  cache <- case lines output of
    [line] | Just path <- stripPrefix "global-packages: " line -> pure (dropWhileEnd isSpace path)
    _ -> ioError (userError "cannot locate the dotnet global package cache")
  withCurrentDirectory project $
    callProcess "dotnet" ["restore", "--source", cache, "-p:NuGetAudit=false", "--verbosity", "quiet"]

-- Gleam has no project precompile hook. Its native bridge is built explicitly,
-- before Gleam copies priv into the application and production shipment.
prepareCrypto :: FilePath -> IO ()
prepareCrypto project = do
  let script = project </> "lawspec_crypto_build.escript"
  present <- doesFileExist script
  when present (callProcess "escript" [script, project])

xmlReports :: FilePath -> IO String
xmlReports dir = do
  exists <- doesDirectoryExist dir
  names <- if exists then sort . filter (".xml" `isSuffixOf`) <$> listDirectory dir else pure []
  concat <$> mapM (readFile' . (dir </>)) names

-- | Stop at the first counterexample: a mutant only has to fail once.
mutantArguments :: String -> [String] -> [String]
mutantArguments "python" args = args ++ ["-x"]
mutantArguments _ args = args

-- | A mutant must fail its laws, not the build. These markers identify build and
-- type-checking failures in each toolchain's output. ANSI escape sequences are
-- stripped first, since a toolchain that colours its errors (Gleam under
-- FORCE_COLOR) would otherwise split a marker such as "error: Type mismatch".
compileFailure :: String -> Bool
compileFailure output = any rebarFailure (lines lowered) || any ((`isInfixOf` lowered) . map toLower)
  [ "error[E", "could not compile", "COMPILATION ERROR", "compileKotlin FAILED"
  , "compileTestKotlin FAILED", "compileGroovy FAILED", "compileTestGroovy FAILED", "Syntax error compiling", "Syntax error reading source", "Syntax error macroexpanding", "SyntaxError", "[build failed]", "parse error on input"
  , "not in scope", "error TS", "couldn't match expected type"
  , "syntax error before:", "undefined function", "** (CompileError)"
  , "error: Type mismatch", "error: Unknown variable", "error: Unknown type"
  , "error: Unknown module", "error: Unknown value", ": error FS", ": error CS"
  , "error compiling project" ]
    || any swiftFailure (lines lowered)
  where
    lowered = map toLower (stripAnsi output)
    rebarFailure line = all (`isInfixOf` line) ["===>", "compiling ", " failed"]
    -- Swift's compiler: path.swift:line:column: error: ...
    swiftFailure line = ".swift:" `isInfixOf` line && ": error: " `isInfixOf` line

-- | Drop ANSI escape sequences: control sequences (ESC, a bracket, parameters
-- and a final byte from 0x40 to 0x7E) and two-byte escapes (ESC and one more).
stripAnsi :: String -> String
stripAnsi ('\ESC' : '[' : rest) = stripAnsi (drop 1 (dropWhile (\c -> c < '@' || c > '~') rest))
stripAnsi ('\ESC' : _ : rest) = stripAnsi rest
stripAnsi (c : rest) = c : stripAnsi rest
stripAnsi [] = []
