-- | Benchmarks of generated checked definitions and stateful spec handlers,
-- run from the repository root:
--
--   lawspec-dev bench kafka                      rust, go, java and kotlin
--   lawspec-dev bench kafka --scale 10000 rust   a smaller workload
--   lawspec-dev bench kafka --generate go        write the project only
--   lawspec-dev bench kafka --typed              which definitions and
--                                                handlers stay dynamic, and why
--
-- A benchmark lives in bench/<name>/: bench.json names its specs, the
-- packages they use and their dependencies, as an acceptance suite's does,
-- and bench/<name>/<target>/ holds the native driver copied over the
-- generated project in .artifacts/bench/<name>/<target>. The driver runs a
-- fixed workload against the generated code and prints, one per line,
-- "phase <name> <operations> <seconds>" and "memory <label> <bytes>"; the
-- harness adds the process's peak resident memory (/usr/bin/time -l) and
-- writes the summary to .artifacts/bench/<name>/<target>.txt.
module Bench (benchCommand) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.Directory
import System.Exit (ExitCode(..), die)
import System.FilePath ((</>), takeDirectory)
import System.IO (hFlush, stdout)
import System.Process (CreateProcess(..), proc, readCreateProcessWithExitCode)
import Text.Printf (printf)
import LawSpec.Api (dispatch)
import LawSpec.Scaffold (scaffoldFilesWith)
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Typed.Plan (typedPlan, typedPlanWith, typedFallbacks, isTypedHandler)
import LawSpec.Typed.Jvm (jvmScalars)

benchCommand :: [String] -> IO ()
benchCommand arguments = case arguments of
  [name, "--typed"] -> typedReport name
  name : rest -> do
    let (scale, generateOnly, targets) = options rest (Nothing, False, [])
    run name scale generateOnly (if null targets then ["rust", "go", "java", "kotlin"] else targets)
  [] -> die "usage: lawspec-dev bench <name> [--scale N] [--generate] [target...] | --typed"
  where
    options ("--scale" : n : rest) (_, g, ts) = options rest (Just n, g, ts)
    options ("--generate" : rest) (s, _, ts) = options rest (s, True, ts)
    options (t : rest) (s, g, ts) = options rest (s, g, ts ++ [t])
    options [] acc = acc

run :: String -> Maybe String -> Bool -> [String] -> IO ()
run name scale generateOnly targets = do
  let base = "bench" </> name
  manifest <- BL.readFile (base </> "bench.json") >>= maybe (die ("invalid " ++ base </> "bench.json")) pure . decode
  let strings key = [T.unpack s | Just (Array values) <- [field key manifest], String s <- V.toList values]
  sources <- forM (strings "specs") $ \path -> (,) path <$> readFile path
  packages <- mapM loadPackage (strings "packages")
  let extra = [("packages", toJSON packages) | not (null packages)] ++
        [("dependencies", d) | Just d <- [field "dependencies" manifest]]
  forM_ targets $ \target -> do
    let project = ".artifacts" </> "bench" </> name </> target
    putStr (target ++ ": generating ... ") >> hFlush stdout
    generated <- either (\message -> die (target ++ ": generation failed: " ++ message)) pure
      (planGeneration extra sources target)
    removePathForcibly project
    createDirectoryIfMissing True project
    scaffolds <- either die pure (scaffoldFilesWith False False target)
    forM_ scaffolds $ \(path, content) -> writeAt (project </> path) content
    forM_ generated $ \(path, content) -> writeAt (project </> path) content
    drivers <- walk (base </> target)
    forM_ drivers $ \file -> readFile file >>= writeAt (project </> drop (length (base </> target) + 1) file)
    when (target == "go") (copyFile "test/locks/go/go.sum" (project </> "go.sum"))
    let lines' = [p | (p, _) <- generated]
    putStrLn (show (length lines') ++ " files")
    unless generateOnly $ do
      (build, runCommand) <- commands target project
      forM_ build $ \(command, args) -> do
        (code, out, err) <- readCreateProcessWithExitCode (proc command args) { cwd = Just project } ""
        when (code /= ExitSuccess) (die (target ++ ": " ++ unwords (command : args) ++ " failed\n" ++ out ++ err))
      let (command, args) = runCommand
          scaleArgs = maybe [] pure scale
      (code, out, err) <- readCreateProcessWithExitCode
        (proc "/usr/bin/time" (["-l", command] ++ args ++ scaleArgs)) { cwd = Just project } ""
      when (code /= ExitSuccess) (die (target ++ ": the benchmark failed\n" ++ out ++ err))
      let peak = case [w | l <- lines err, "maximum resident set size" `isSuffixOf` l, w : _ <- [words l]] of
            w : _ -> read w :: Integer
            [] -> 0
          summary = report target out peak
      writeFile (".artifacts" </> "bench" </> name </> (target ++ ".txt")) (unlines summary)
      mapM_ putStrLn summary

-- | Which of the benchmark's definitions and spec handlers stay on the
-- dynamic path, and why: on Rust and Go, and on the JVM (no UInt64).
typedReport :: String -> IO ()
typedReport name = do
  let base = "bench" </> name
  manifest <- BL.readFile (base </> "bench.json") >>= maybe (die ("invalid " ++ base </> "bench.json")) pure . decode
  let strings key = [T.unpack s | Just (Array values) <- [field key manifest], String s <- V.toList values]
  packageFiles <- concat <$> mapM (\directory -> filter (".lawspec" `isSuffixOf`) <$> walk directory) (strings "packages")
  sources <- forM (strings "specs" ++ sort packageFiles) $ \path -> Source path <$> readFile path
  program <- either (die . show) pure (compileCore 64 defaultGeneration sources)
  let declarations = C.programDataDeclarations program
      units = C.programUnits program
      definitions = length (concatMap C.unitDefinitions units)
  forM_ [("rust, go", typedPlan declarations units), ("java, kotlin", typedPlanWith jvmScalars declarations units)] $ \(label, plan) -> do
    let fallbacks = typedFallbacks plan
        handlers = [(C.handlerName h, isTypedHandler plan h) | u <- units, h <- C.unitHandlers u]
    putStrLn (label ++ ": " ++ show (definitions - length fallbacks) ++ " of " ++ show definitions ++ " definitions typed")
    forM_ fallbacks $ \(n, why) -> putStrLn ("  dynamic " ++ n ++ ": " ++ why)
    forM_ handlers $ \(n, typed) -> putStrLn ("  handler " ++ n ++ (if typed then " typed" else " dynamic"))

-- | The build commands and the command that runs the driver, from the project.
commands :: String -> FilePath -> IO ([(String, [String])], (String, [String]))
commands target project = case target of
  "rust" -> pure ([("cargo", ["build", "--release", "--example", "kafka_bench"])],
    ("target/release/examples/kafka_bench", []))
  "go" -> pure ([("go", ["build", "-o", "kafka-bench.bin", "./cmd/kafkabench"])], ("./kafka-bench.bin", []))
  "java" -> pure ([("mvn", ["-q", "compile"])],
    ("java", ["-Xmx8g", "-cp", "target/classes", "bench.KafkaBench"]))
  "kotlin" -> do
    (code, out, err) <- readCreateProcessWithExitCode (proc "gradle" ["-q", "--console=plain", "classes", "benchClasspath"]) { cwd = Just project } ""
    when (code /= ExitSuccess) (die ("kotlin: gradle failed\n" ++ out ++ err))
    let classpath = last ("" : [l | l <- lines out, not (null l)])
    pure ([], ("java", ["-Xmx8g", "-cp", classpath, "bench.KafkaBenchKt"]))
  _ -> die ("no benchmark runner for " ++ target)

-- | Throughput per phase and memory, from the driver's lines.
report :: String -> String -> Integer -> [String]
report target out peak =
  [target] ++
  [ printf "  %-14s %10d ops %9.3f s %12.0f ops/s" phase ops seconds (fromIntegral ops / max 1e-9 seconds :: Double)
  | l <- lines out, ["phase", phase, n, s] <- [words l], let ops = read n :: Integer, let seconds = read s :: Double ] ++
  [ printf "  memory %-12s %8.1f MiB" label (fromIntegral bytes / 1048576 :: Double)
  | l <- lines out, ["memory", label, n] <- [words l], let bytes = read n :: Integer ] ++
  [ printf "  peak resident  %8.1f MiB" (fromIntegral peak / 1048576 :: Double) ] ++
  [ "  " ++ l | l <- lines out, "check " `isPrefixOf` l ]

-- | The JSON request the CLI would send, answered in process.
planGeneration :: [(K.Key, Value)] -> [(FilePath, String)] -> String -> Either String [(FilePath, String)]
planGeneration extra sources target = do
  let request = object $
        [ "method" .= ("planGeneration" :: String), "target" .= target, "machineBits" .= (64 :: Int), "minify" .= False
        , "sources" .= [object ["path" .= reverse (takeWhile (/= '/') (reverse path)), "content" .= content] | (path, content) <- sources]
        ] ++ extra
      response = fromMaybe Null (decode (dispatch (encode request)))
  case field "diagnostics" response of
    Just (Array ds) | not (V.null ds) -> Left (show (encode ds))
    _ -> pure ()
  pure [ (T.unpack p, T.unpack c)
       | Just (Array files) <- [field "files" response], Object f <- V.toList files
       , Just (String p) <- [KM.lookup "path" f], Just (String c) <- [KM.lookup "content" f] ]

-- | A package as the lawspec CLI sends it: its manifest with the sources read.
loadPackage :: FilePath -> IO Value
loadPackage directory = do
  manifest <- BL.readFile (directory </> "lawspec-package.json")
  value <- maybe (die ("invalid " ++ directory ++ "/lawspec-package.json")) pure (decode manifest)
  let roots = [T.unpack s | Just (Array values) <- [field "sources" value], String s <- V.toList values]
  files <- concat <$> mapM (walk . (directory </>)) roots
  sources <- forM (sort (filter (".lawspec" `isSuffixOf`) files)) $ \path -> do
    content <- readFile path
    pure (object ["path" .= path, "content" .= content])
  case value of
    Object o -> pure (Object (KM.insert "sources" (toJSON sources) o))
    _ -> die ("invalid " ++ directory ++ "/lawspec-package.json")

field :: K.Key -> Value -> Maybe Value
field key (Object o) = KM.lookup key o
field _ _ = Nothing

walk :: FilePath -> IO [FilePath]
walk path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then concat <$> (listDirectory path >>= mapM (walk . (path </>)) . sort)
    else do
      exists <- doesFileExist path
      pure [path | exists]

writeAt :: FilePath -> String -> IO ()
writeAt path content = do
  createDirectoryIfMissing True (takeDirectory path)
  writeFile path content
