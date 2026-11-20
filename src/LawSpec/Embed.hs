{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time embedding of the files the compiler carries: the reviewed
-- runtime sources, the built-in defaults, the .NET, JVM-language and Swift
-- runtimes, the bundled examples and the pinned Unicode tables. The splices
-- run in the modules that hold them (LawSpec.RuntimeSources and the like), so
-- a checkout builds from its sources with no generated Haskell in Git.
--
-- A splice records every file it reads with 'addDependentFile', so editing
-- one recompiles its module. GHC cannot watch a directory: after adding or
-- removing a file under a walked directory, touch the module that embeds it.
-- Paths are relative to the package root, where Stack and Cabal run splices.
module LawSpec.Embed
  ( Tree (..),
    embedFile,
    embedTable,
    embedTree,
    embedPaths,
    embedProjects,
    runtimeFiles,
    defaultsTree,
    dotnetTree,
    languageTree,
    caseFoldTable,
    displayWidthTable,
    unprintableTable,
  )
where

import Control.Monad (forM, unless)
import qualified Data.ByteString as B
import Data.Char (chr)
import Data.List (isSuffixOf, nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Language.Haskell.TH (Exp, Q, listE, litE, runIO, stringL, tupE)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import LawSpec.Digest (digest, digestHex)
import Numeric (readHex)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

-- | Which entries a directory walk keeps: directories by name, files by name.
data Tree = Tree {treeEnters :: String -> Bool, treeKeeps :: String -> Bool}

-- | The reviewed runtime sources, by key, under runtime/.
runtimeFiles :: [(String, FilePath)]
runtimeFiles =
  [ ("beam-scalar", "lawspec_beam_scalar.erl"), ("beam-schema", "lawspec_beam_schema.erl")
  , ("beam-regex", "lawspec_beam_regex.erl")
  , ("beam-recorded", "lawspec_beam_recorded.erl")
  , ("beam-random", "lawspec_beam_random.erl"), ("beam-values", "lawspec_beam_values.erl")
  , ("beam-model", "lawspec_beam_model.erl")
  , ("beam-model_parallel", "lawspec_beam_model_parallel.erl")
  , ("beam-history", "lawspec_beam_history.erl")
  , ("beam-scenario", "lawspec_beam_scenario.erl"), ("beam-scenario_io", "lawspec_beam_scenario_io.erl")
  , ("beam-scenario_network", "lawspec_beam_scenario_network.erl")
  , ("beam-wire", "lawspec_beam_wire.erl"), ("beam-memory_network", "lawspec_beam_memory_network.erl")
  , ("beam-channel_protocol", "lawspec_beam_channel_protocol.erl")
  , ("beam-node", "lawspec_beam_node.erl"), ("beam-endpoint", "lawspec_beam_endpoint.erl")
  , ("beam-mailbox", "lawspec_beam_mailbox.erl"), ("beam-gleam-network", "lawspec_gleam_network.gleam")
  , ("beam-session", "lawspec_beam_session.erl"), ("beam-session_task", "lawspec_beam_session_task.erl")
  , ("beam-session_ownership", "lawspec_beam_session_ownership.erl")
  , ("beam-session_network", "lawspec_beam_session_network.erl")
  , ("beam-remote", "lawspec_beam_remote.erl")
  , ("beam-transport", "lawspec_beam_transport.erl"), ("beam-network", "lawspec_beam_network.erl")
  , ("beam-network_crypto", "lawspec_beam_network_crypto.erl"), ("beam-network_config", "lawspec_beam_network_config.erl")
  , ("beam-socket_transport", "lawspec_beam_socket_transport.erl"), ("beam-socket_protocol", "lawspec_beam_socket_protocol.erl")
  , ("beam-network-api", "lawspec_network.erl"), ("beam-elixir-network", "lawspec_beam_network.ex")
  , ("beam-gleam-sessions", "lawspec_gleam_sessions.gleam")
  , ("beam-elixir-sessions", "lawspec_beam_sessions.ex")
  , ("beam-runtime", "lawspec_beam_runtime.erl"), ("beam-proper", "lawspec_beam_proper.erl")
  , ("beam-effects", "lawspec_beam_effects.erl"), ("beam-handler", "lawspec_beam_handler.erl")
  , ("beam-resource", "lawspec_beam_resource.erl"), ("beam-resources", "lawspec_beam_resources.erl")
  , ("beam-finite", "lawspec_beam_finite.erl"), ("beam-test_run", "lawspec_beam_test_run.erl"), ("beam-harness", "lawspec_beam_harness.erl")
  , ("beam-report", "lawspec_beam_report.erl")
  , ("beam-coverage", "lawspec_beam_coverage.erl")
  , ("beam-exunit-formatter", "lawspec_beam_exunit_formatter.ex"), ("beam-exunit-cases", "lawspec_beam_exunit_cases.ex")
  , ("beam-schedule", "lawspec_beam_schedule.erl"), ("beam-exunit-schedule", "lawspec_beam_exunit_schedule.ex")
  , ("beam-search", "lawspec_beam_search.erl")
  , ("beam-waits", "lawspec_beam_waits.erl")
  , ("beam-fast", "lawspec_beam_fast.erl")
  , ("beam-policy", "lawspec_beam_policy.erl"), ("beam-tasks", "lawspec_beam_tasks.erl")
  , ("beam-attempts", "lawspec_beam_attempts.erl")
  , ("beam-workflow_state", "lawspec_beam_workflow_state.erl")
  , ("beam-workflow", "lawspec_beam_workflow.erl")
  , ("beam-actors", "lawspec_beam_actors.erl"), ("beam-actor", "lawspec_beam_actor.erl")
  , ("beam-actor_sup", "lawspec_beam_actor_sup.erl"), ("beam-actor_tree", "lawspec_beam_actor_tree.erl")
  , ("beam-supervision", "lawspec_beam_supervision.erl")
  , ("beam-gleam-actors", "lawspec_gleam_actors.gleam")
  , ("beam-elixir-workflow", "lawspec_beam_workflow.ex")
  , ("beam-defaults", "lawspec_beam_defaults.erl")
  , ("beam-crypto", "lawspec_beam_crypto.erl"), ("beam-crypto_native", "lawspec_beam_crypto_native.erl")
  , ("beam-crypto-native-c", "lawspec_crypto_native.c"), ("beam-crypto-build", "lawspec_crypto_build.escript")
  , ("beam-generators", "lawspec_beam_generators.erl"), ("beam-stream-data", "lawspec_beam_stream_data.ex")
  , ("beam-index", "lawspec_beam_index.erl")
  , ("beam-qcheck", "lawspec_beam_qcheck.erl"), ("beam-gleam", "lawspec_beam_gleam.erl")
  , ("beam-gleam-types", "lawspec_gleam_types.gleam"), ("beam-gleam-scalar", "lawspec_gleam_scalar.gleam")
  , ("beam-gleam-failures", "lawspec_gleam_failures.gleam")
  , ("beam-gleam-effects", "lawspec_gleam_effects.gleam")
  , ("beam-gleam-workflow", "lawspec_gleam_workflow.gleam")
  , ("python", "lawspec_runtime.py"), ("python-schema", "lawspec_schema.py"), ("python-fast", "lawspec_fast.py")
  , ("prolog", "lawspec_prolog.pl"), ("prolog-python", "lawspec_prolog.py"), ("prolog-tests", "lawspec_prolog_tests.py")
  , ("python-data-strategies", "lawspec_data_strategies.py"), ("javascript", "lawspec_runtime.mjs")
  , ("web-schema", "lawspec_schema.mjs"), ("web-data-strategies", "lawspec_data_strategies.mjs"), ("web-fast", "lawspec_fast.mjs")
  , ("java", "LawSpecRuntime.java"), ("java-fast", "LawSpecFast.java"), ("java-schema", "LawSpecSchema.java"), ("java-masks", "LawSpecMasks.java"), ("java-masked", "LawSpecMasked.java"), ("java-masked-logback", "LawSpecMaskedConverter.java")
  -- Generated actors on Apache Pekko (:actors {:runtime :pekko}).
  , ("java-pekko", "pekko/LawSpecPekko.java"), ("java-pekko-supervisor", "pekko/LawSpecPekkoSupervisor.java")
  , ("java-pekko-crash", "pekko/LawSpecCrashInterceptor.java")
  -- serve and connect over Pekko Cluster, only with :remote :cluster.
  , ("java-pekko-cluster", "pekko/LawSpecPekkoCluster.java")
  -- Generated actors through the Spring Boot actor starter (:runtime :spring).
  , ("java-spring", "spring/LawSpecSpring.java")
  , ("java-data-strategies-body", "LawSpecDataStrategies.inc"), ("go", "lawspec_runtime.go"), ("go-fast", "lawspec_fast.go")
  , ("go-schema", "lawspec_schema.go"), ("go-codecs", "lawspec_codecs.go")
  , ("go-data-strategies", "lawspec_data_strategies.go"), ("haskell", "LawSpecRuntime.hs")
  , ("haskell-schema", "LawSpecSchema.hs"), ("haskell-codecs", "LawSpecCodecs.hs"), ("haskell-fast", "LawSpecFast.hs")
  , ("haskell-collection-codecs", "LawSpecCollectionCodecs.hs")
  , ("haskell-transports", "LawSpecTransports.hs"), ("haskell-testing", "LawSpecTesting.hs")
  , ("haskell-data-strategies", "LawSpecDataStrategies.hs"), ("rust", "lawspec_runtime.rs")
  , ("rust-strategies", "lawspec_strategies.rs"), ("kotlin-strategies", "LawSpecStrategies.kt")
  , ("kotlin-native", "LawSpecKotlin.kt"), ("kotlin-codecs", "LawSpecKotlinCodecs.kt"), ("kotlin-scalars", "LawSpecKotlinScalars.kt"), ("kotlin-testing", "LawSpecKotlinTesting.kt"), ("kotlin-draws", "LawSpecKotlinDraws.kt")
  , ("scala-scalars", "LawSpecScalaScalars.scala"), ("scala-testing", "LawSpecScalaTesting.scala"), ("scala-draws", "LawSpecScalaDraws.scala")
  , ("kotlin-data-strategies", "LawSpecKotlinStrategies.kt")
  -- Scala, over the shared JVM runtime.
  , ("scala-native", "LawSpecScala.scala"), ("scala-codecs", "LawSpecScalaCodecs.scala")
  , ("scala-strategies", "LawSpecGen.scala"), ("scala-data-strategies", "LawSpecScalaStrategies.scala")
  , ("python-harness", "lawspec_harness.py"), ("web-harness", "lawspec_harness.mjs")
  , ("go-harness", "lawspec_harness.go"), ("java-harness", "LawSpecHarness.java")
  , ("haskell-harness", "LawSpecHarness.hs"), ("rust-harness", "lawspec_harness.rs")
  -- The secure network handler, written only for programs that import
  -- lawspec.network (LawSpec.Network).
  , ("python-network", "lawspec_network.py"), ("javascript-network", "lawspec_network.mjs")
  , ("java-network", "LawSpecNetwork.java"), ("go-network", "lawspec_network.go")
  , ("haskell-network", "LawSpecNetwork.hs"), ("rust-network", "lawspec_network.rs")
  -- BLAKE3 from its Go module, written only for programs whose definitions
  -- reach it (LawSpec.Network.withBlake3Module).
  , ("go-blake3", "lawspec_blake3.go")
  -- The checker of existing Pekko actors, written only for JVM projects
  -- whose native bindings bind actors (LawSpec.JavaNativeBinding).
  , ("java-pekko-native", "pekko/LawSpecPekkoNative.java")
  , ("java-spring-native", "spring/LawSpecSpringNative.java")
  , ("java-pekko-sharding", "pekko/LawSpecPekkoSharding.java") ]

-- | runtime/defaults: sources only, no caches or editor files.
defaultsTree :: Tree
defaultsTree =
  Tree
    (\entry -> take 2 entry /= "__" && take 1 entry /= ".")
    (\entry -> take 1 entry /= "." && any (`isSuffixOf` entry) [".py", ".mjs", ".ts", ".go", ".java", ".kt", ".scala", ".hs", ".rs", ".txt", ".erl", ".ex", ".gleam"])

-- | runtime/dotnet: the F# and C# projects, without build output.
dotnetTree :: Tree
dotnetTree =
  Tree
    (\entry -> entry `notElem` ["bin", "obj"] && take 1 entry /= ".")
    (\entry -> take 1 entry /= "." && any (`isSuffixOf` entry) [".fs", ".fsproj", ".cs", ".csproj", ".props"])

-- | runtime/groovy, runtime/clojure and runtime/swift, without SwiftPM's .build.
languageTree :: Tree
languageTree =
  Tree
    (\entry -> entry /= ".build" && take 1 entry /= ".")
    (\entry -> take 1 entry /= "." && any (`isSuffixOf` entry) [".java", ".groovy", ".clj", ".edn", ".swift"])

-- | A file's text, decoded as UTF-8, recorded as a dependency.
readSource :: FilePath -> Q String
readSource path = do
  addDependentFile path
  runIO (T.unpack . T.decodeUtf8 <$> B.readFile path)

-- | A file's text as a string literal.
embedFile :: FilePath -> Q Exp
embedFile path = readSource path >>= text

-- | @[(key, text)]@ for files named by key.
embedTable :: [(String, FilePath)] -> Q Exp
embedTable files = mapM (\(key, path) -> (,) key <$> readSource path) files >>= texts

-- | @[(path, text)]@ for every kept file under a directory, by path relative
-- to it, in sorted order.
embedTree :: FilePath -> Tree -> Q Exp
embedTree root tree = do
  paths <- runIO (walk tree root "")
  mapM (\path -> (,) path <$> readSource (root </> path)) paths >>= texts

-- | The relative paths 'embedTree' would embed.
embedPaths :: FilePath -> Tree -> Q Exp
embedPaths root tree = runIO (walk tree root "") >>= listE . map text

-- | @[(name, [(path, text)])]@: each subdirectory of a directory, in sorted
-- order, with every file in it by relative path, in readdir order as libuv
-- gives it (each directory's entries by name, a folder's files at its place).
embedProjects :: FilePath -> Q Exp
embedProjects root = do
  names <- runIO (sort <$> listDirectory root)
  projects <- forM names $ \name -> do
    paths <- runIO (walk (Tree (const True) (const True)) (root </> name) "")
    files <- mapM (\path -> (,) path <$> readSource (root </> name </> path)) paths
    pure (tupE [text name, texts files])
  listE projects

-- | A string literal, not a list of character literals.
text :: String -> Q Exp
text = litE . stringL

-- | @[(String, String)]@ as literals.
texts :: [(String, String)] -> Q Exp
texts pairs = listE [tupE [text a, text b] | (a, b) <- pairs]

walk :: Tree -> FilePath -> FilePath -> IO [FilePath]
walk tree root prefix = do
  entries <- sort <$> listDirectory (root </> prefix)
  concat
    <$> mapM
      ( \entry -> do
          let path = if null prefix then entry else prefix </> entry
          directory <- doesDirectoryExist (root </> path)
          if directory
            then if treeEnters tree entry then walk tree root path else pure []
            else pure [path | treeKeeps tree entry]
      )
      entries

-- | The pinned Unicode 17.0.0 bytes of a file, checked against its digest.
pinned :: FilePath -> String -> Q B.ByteString
pinned path expected = do
  addDependentFile path
  bytes <- runIO (B.readFile path)
  unless (digestHex (digest bytes) == expected) (fail ("The pinned Unicode 17.0.0 " ++ path ++ " digest changed"))
  pure bytes

-- | The full default case folding (statuses C and F; S and the Turkic T
-- mappings are excluded), as @[(code point, folded)]@.
caseFoldTable :: Q Exp
caseFoldTable = do
  bytes <- pinned "vendor/unicode/17.0.0/CaseFolding.txt" "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"
  let mappings =
        [ ([hex key], map hex (words mapping))
        | line <- lines (latin bytes),
          not (null line),
          take 1 line /= "#",
          [key, status, mapping, _] <- [fields line],
          words status `elem` [["C"], ["F"]]
        ]
  unless (length mappings == 1585 && length (nub (map fst mappings)) == length mappings) (fail "Unexpected Unicode full default case-fold mapping inventory")
  texts mappings
  where
    hex field = case readHex (unwords (words field)) of
      [(n, "")] | n >= 0 && n <= fromEnum (maxBound :: Char) -> chr n
      _ -> error "Invalid pinned Unicode code point"
    fields line = case break (== ';') line of
      (first, ';' : rest) -> first : fields rest
      (final, _) -> [final]

-- | Display columns per code point, as the unicode-width crate measures them
-- for ruff and rustfmt: East Asian Wide and Fullwidth are two columns;
-- combining marks, format controls and Hangul medial and final jamo are none.
-- Code point ranges whose width is not one column: @[(first, last, width)]@.
displayWidthTable :: Q Exp
displayWidthTable = do
  widths <- pinned "vendor/unicode/17.0.0/EastAsianWidth.txt" "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33"
  categories <- pinned "vendor/unicode/17.0.0/DerivedGeneralCategory.txt" categoryDigest
  let wide = [r | (r, v) <- rows widths, v `elem` ["W", "F"]]
      -- Prepended concatenation marks are visible format characters.
      visible = [0x00AD, 0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2, 0x110BD, 0x110CD]
      zero = [r | (r, v) <- rows categories, v `elem` ["Mn", "Me", "Cf"]] ++ [(0x1160, 0x11FF), (0xD7B0, 0xD7FF), (0x200B, 0x200B)]
  lift (merge (latest ([(c, 0) | (lo, hi) <- zero, c <- [lo .. hi], c `notElem` visible] ++ [(c, 2) | (lo, hi) <- wide, c <- [lo .. hi]])))

-- | Code point ranges a string literal escapes to stay readable: controls,
-- format characters, surrogates, private use, unassigned code points and
-- separators other than the space. @[(first, last)]@.
unprintableTable :: Q Exp
unprintableTable = do
  categories <- pinned "vendor/unicode/17.0.0/DerivedGeneralCategory.txt" categoryDigest
  let unprintable =
        merge
          ( latest
              [ (c, 1 :: Int)
              | ((lo, hi), v) <- rows categories,
                v `elem` ["Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp", "Zs"],
                c <- [lo .. hi],
                c /= 0x20
              ]
          )
  lift [(lo, hi) | (lo, hi, _) <- unprintable]

categoryDigest :: String
categoryDigest = "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e"

latin :: B.ByteString -> String
latin = map (toEnum . fromEnum) . B.unpack

-- | The (range, value) rows of a Unicode property file.
rows :: B.ByteString -> [((Int, Int), String)]
rows bytes =
  [ (range field, unwords (words value))
  | line <- lines (latin bytes),
    let content = takeWhile (/= '#') line,
    not (all (== ' ') content),
    [field, value] <- [split content]
  ]
  where
    range field = case break (== '.') (unwords (words field)) of
      (lo, '.' : '.' : hi) -> (hex lo, hex hi)
      (lo, _) -> (hex lo, hex lo)
    hex digits = case readHex digits of
      [(n, "")] -> n
      _ -> error "Invalid pinned Unicode code point"
    split content = case break (== ';') content of
      (first, ';' : rest) -> [first, rest]
      _ -> []

-- | Sorted by code point; for a repeated code point, the later entry wins (a
-- wide combining mark is wide).
latest :: [(Int, Int)] -> [(Int, Int)]
latest = M.toList . M.fromList

merge :: [(Int, Int)] -> [(Int, Int, Int)]
merge entries = case entries of
  (c, w) : rest -> go c c w rest
  [] -> []
  where
    go lo hi width more = case more of
      (c', w') : others
        | c' == hi + 1 && w' == width -> go lo c' width others
        | otherwise -> (lo, hi, width) : go c' c' w' others
      [] -> [(lo, hi, width)]
