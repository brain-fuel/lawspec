-- | @lawspec mutate@, ported from mutate.mjs and its wiring in lawspec.mjs:
-- each acceptance-format mutant is applied to a disposable copy of the
-- project, and @lawspec test --fresh --json@ must fail on it, for the
-- reasons the mutant expects.
--
-- The legacy CLI copied the project into a temporary directory and ran
-- itself as a child process for each test run. The port copies through the
-- host's file effects into a scratch directory of the temporary root
-- ("LawSpec.App.Doctor" temporaryDirectory), runs the ported @test@ in
-- this process (a 'Subcommand'), with the mutation timeout as the session's
-- deadline for every process it starts, and removes the scratch directory
-- with 'removeCreated' at the end.
-- ref:DEC-s1j-shared-failures ref:DEC-haskell-application-port
module LawSpec.App.Mutate
  ( Mutant (..),
    Edit (..),
    MutationRun (..),
    mutateCommand,
    parseMutant,
    classifyMutation,
  )
where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf, nub, sortBy)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Doctor (temporaryDirectory)
import LawSpec.App.Files (compareUtf16)
import LawSpec.App.Json
import LawSpec.App.Process (monotonicMicroseconds')
import LawSpec.App.Project (readManifest)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, relative, resolve, takeDirectory)

-- | One search-and-replace of a mutant, on a file named relative to the
-- project; a search of @*@ replaces the whole file.
data Edit = Edit
  { editFile :: String,
    editSearch :: String,
    editReplacement :: String
  }
  deriving (Eq, Show)

data Mutant = Mutant
  { -- | Texts the failing run's output must hold: one of each group.
    mutantExpectations :: [[String]],
    mutantForbidden :: [String],
    mutantEdits :: [Edit],
    mutantRejection :: Maybe String,
    -- | The targets on which only the failure, not its output, is checked,
    -- and why.
    mutantUnchecked :: Maybe ([String], String)
  }
  deriving (Eq, Show)

-- | One test run of a copy: the exit code, whether the deadline stopped it,
-- its JSON report when its standard output parsed, and its standard output
-- followed by its standard error.
data MutationRun = MutationRun
  { runCode :: Maybe Int,
    runDeadline :: Bool,
    runReport :: Maybe Json,
    runOutput :: String
  }
  deriving (Eq, Show)

-- | mutate.mjs parseMutant.
parseMutant :: String -> Either String Mutant
parseMutant content = header (splitLines content) (Mutant [] [] [] Nothing Nothing)
  where
    header lines' mutant = case lines' of
      line : rest
        | not ("@@ " `isPrefixOf` line) ->
            if blank line
              then header rest mutant
              else headerLine line mutant >>= header rest
      _ -> body lines' Nothing mutant
    headerLine line mutant
      | line `elem` ["rejected-at: compile", "rejected-at: generation"] = Right mutant {mutantRejection = Just (drop 13 line)}
      | Just text <- strip "expect: " line = Right mutant {mutantExpectations = mutantExpectations mutant ++ [[text]]}
      | Just text <- strip "expect-any: " line = Right mutant {mutantExpectations = mutantExpectations mutant ++ [splitOn " | " text]}
      | Just text <- strip "forbid: " line = Right mutant {mutantForbidden = mutantForbidden mutant ++ [text]}
      | Just text <- strip "output-unchecked-on: " line =
          let (targets, reason) = case splitOn "|" text of
                first : more -> (filter (not . null) (splitOn " " first), trim (joinWith "|" more))
                [] -> ([], "")
           in if null targets || null reason
                then Left "output-unchecked-on needs targets, then | and a reason"
                else Right mutant {mutantUnchecked = Just (targets, reason)}
      | otherwise = Left ("unexpected header line: " ++ line)
    body lines' file mutant = case lines' of
      [] ->
        if null (mutantEdits mutant)
          then Left "mutation has no edits"
          else Right mutant
      line : rest
        | blank line -> body rest file mutant
        | Just name <- strip "@@ " line -> body rest (Just name) mutant
        | line /= "<<<<<<<" || maybe True null file -> Left ("unexpected line: " ++ line)
        | otherwise -> do
            let (search, afterSearch) = break (== "=======") rest
            afterSeparator <- case afterSearch of
              _ : more -> Right more
              [] -> Left "missing ======="
            let (replacement, afterReplacement) = break (== ">>>>>>>") afterSeparator
            remaining <- case afterReplacement of
              _ : more -> Right more
              [] -> Left "missing >>>>>>>"
            body
              remaining
              file
              mutant {mutantEdits = mutantEdits mutant ++ [Edit (fromMaybe "" file) (joinWith "\n" search) (joinWith "\n" replacement)]}
    blank = all (== ' ')
    strip prefix line = if prefix `isPrefixOf` line then Just (drop (length prefix) line) else Nothing

-- | content.split(/\r?\n/).
splitLines :: String -> [String]
splitLines text = case break (== '\n') text of
  (line, []) -> [line]
  (line, _ : rest) -> (if "\r" `isSuffixOf` line then init line else line) : splitLines rest

splitOn :: String -> String -> [String]
splitOn separator text = go "" text
  where
    go part [] = [reverse part]
    go part rest@(c : more)
      | separator `isPrefixOf` rest = reverse part : go "" (drop (length separator) rest)
      | otherwise = go (c : part) more

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith separator items = foldr1 (\a b -> a ++ separator ++ b) items

-- | String.prototype.trim: JavaScript's white space and line terminators.
trim :: String -> String
trim = dropWhileEnd' javascriptSpace . dropWhile javascriptSpace
  where
    dropWhileEnd' p = reverse . dropWhile p . reverse
    javascriptSpace c = isSpace c || c `elem` ("\x00a0\x1680\x2028\x2029\x202f\x205f\x3000\xfeff" :: String) || (c >= '\x2000' && c <= '\x200a')

-- | mutate.mjs classifyMutation: the row of one mutant's run on the target
-- the invocation named, if any.
classifyMutation :: MutationRun -> Mutant -> Maybe String -> [(String, Json)]
classifyMutation run mutant target
  | runDeadline run = status "timed-out" []
  | any unsupported diagnostics = status "unsupported" []
  | runCode run == Just 0 = status "surviving" []
  | null failedLaws =
      status
        (if not reportIsArray && nonEmpty (reportDiagnostics) then "invalid" else "errored")
        ( ("reason", JString "No individually identified executed failing law")
            : [("diagnostics", value) | Just value <- [reportDiagnostics]]
        )
  | Just (targets, reason) <- mutantUnchecked mutant,
    maybe False (`elem` targets) target =
      status "killed" [("outputUnchecked", JString reason)]
  | not (all (any (`T.isInfixOf` output) . map T.pack) (mutantExpectations mutant))
      || any ((`T.isInfixOf` output) . T.pack) (mutantForbidden mutant) =
      status "errored" [("reason", JString "Failure did not meet the mutation expectations")]
  | otherwise = status "killed" []
  where
    status name more = ("status", JString name) : ("failedLaws", JArray (map JString failedLaws)) : more
    output = T.pack (runOutput run)
    rows = case runReport run of
      Just (JArray items) -> items
      _ -> []
    reportIsArray = case runReport run of
      Just (JArray _) -> True
      _ -> False
    failedLaws = sortBy compareUtf16 (nub [law | row <- rows, Just (JArray laws) <- [member "failedLaws" row], JString law <- laws])
    reportDiagnostics = case runReport run of
      Just report@(JObject _) -> member "diagnostics" report
      _ -> Nothing
    diagnostics = case reportDiagnostics of
      Just (JArray items) -> items
      _ -> []
    unsupported row = member "code" row `elem` map (Just . JString) ["unsupported", "target-unsupported"]
    nonEmpty = \case
      Just (JArray items) -> not (null items)
      Just (JString text) -> not (null text)
      _ -> False

-- | lawspec mutate [paths...] [--target <language>] [--mutation-timeout <ms>]
-- [--config <file>] [--project <directory>] [--json]: mutateProject and
-- what main() prints of its report.
mutateCommand :: (Monad m) => Subcommand m -> Arguments -> FilePath -> Command m Int
mutateCommand run arguments cwd = do
  let json = flag "json" arguments
      target = option "target" arguments
  report <-
    mutateProject
      run
      (resolve cwd (fromMaybe cwd (option "project" arguments)))
      (positional arguments)
      target
      (fromMaybe "lawspec.edn" (option "config" arguments))
      (fromMaybe "120000" (option "mutation-timeout" arguments))
  let mutations = fromMaybe [] (member "mutations" report >>= arrayOf)
      row mutation =
        text "name" mutation
          ++ ": "
          ++ text "status" mutation
          ++ case fromMaybe [] (member "failedLaws" mutation >>= arrayOf) of
            [] -> ""
            laws -> " (" ++ joinWith ", " (map jsString laws) ++ ")"
  if json
    then printJson report
    else
      printLine $
        if null mutations
          then "baseline: " ++ maybe "undefined" (text "status") (member "baseline" report)
          else joinWith "\n" (map row mutations)
  pure (if member "ok" report == Just (JBool True) then 0 else 1)
  where
    text key value = maybe "undefined" jsString (member key value)

-- | mutate.mjs mutateProject.
mutateProject :: (Monad m) => Subcommand m -> FilePath -> [String] -> Maybe String -> String -> String -> Command m Json
mutateProject run start paths target config timeoutText = do
  grantRead [start]
  root <- effect (nodeFailure "realpath" start) (RealPath start)
  grantRead [root]
  timeout <- case javascriptNumber timeoutText of
    Just value
      | value > 0,
        value == fromInteger (round value),
        abs value <= 9007199254740991 ->
          pure (round value :: Integer)
    _ -> failWith "mutation timeout must be a positive integer"
  let configRelative = relative root (resolve root config)
  when (".." `isPrefixOf` configRelative || isAbsolute configRelative) $
    failWith "mutation configuration must be inside the project"
  manifest <- readManifest (resolve root configRelative)
  forM_ (strings (member "sources" manifest)) $ \source ->
    when (isAbsolute source || ".." `elem` splitSeparators source) $
      failWith "mutation sources must be relative paths inside the project"
  let targets = fromMaybe [] (member "targets" manifest >>= arrayOf)
      targetRoot entry = maybe "." jsString (member "root" entry)
  forM_ targets $ \entry -> do
    let relative' = relative root (resolve root (targetRoot entry))
    when (".." `isPrefixOf` relative' || isAbsolute relative') $
      failWith "mutation targets must be inside the project"
  -- Do not let generation or the native runner follow a link back into the
  -- original workspace. Internal dependency links are copied by value.
  checkLinks root root
  files <- discover root paths
  when (null files) (failWith "no .mutant files found")
  -- The copy's real path: applyMutant compares each edited file's real
  -- path with the path it names, and the temporary root is often a link
  -- (/var on macOS).
  created <- temporaryDirectory "lawspec-mutate-"
  grantRead [created]
  directory <- effect (nodeFailure "realpath" created) (RealPath created)
  grantRead [directory]
  grantWrite [takeDirectory directory]
  let copy = join directory "project"
      arguments = ["--config", configRelative] ++ maybe [] (\language -> ["--target", language]) target
      -- The compiler cache is content-addressed, so every run shares one: a
      -- mutant that edits no specification compiles nothing again, and one
      -- that does misses only what its edit reaches. Native results are
      -- never shared.
      cache = join directory "compiler-cache"
      copiedCache = join copy ".lawspec/cache"
      reset = do
        renameIfPresent copiedCache cache
        _ <- effectOr (Remove Recursive copy)
        copyTree root copy True
        effect (nodeFailure "mkdir" (takeDirectory copiedCache)) (MakeDirectories Nothing (takeDirectory copiedCache))
        renameIfPresent cache copiedCache
      -- The generated files a mutant edits, which its test run must not
      -- replace.
      editedGenerated mutant = do
        owned <- fmap concat . forM targets $ \entry -> do
          let generatedRoot = resolve copy (targetRoot entry)
              record = join generatedRoot ".lawspec/generated.json"
          found <- effectOr (ReadFile record)
          case found of
            Left (HostError NotFound _) -> pure []
            Left problem -> abort (nodeFailure "open" record problem)
            Right bytes -> case parseJson (fromUtf8 bytes) of
              Left problem -> failWith problem
              Right recorded -> pure [resolve generatedRoot name | (name, _) <- maybe [] members (member "files" recorded)]
        pure [relative copy file | edit <- mutantEdits mutant, let file = resolve copy (editFile edit), file `elem` owned]
      test extra = do
        clock <- monotonicMicroseconds'
        nested <- run (["test", "--fresh", "--json"] ++ arguments ++ extra) copy (Just (clock + timeout * 1000))
        let stdout = fromUtf8 (nestedStdout nested)
        pure
          MutationRun
            { runCode = nestedExit nested,
              runDeadline = not (isJust (nestedExit nested)),
              runReport = either (const Nothing) Just (parseJson stdout),
              runOutput = stdout ++ fromUtf8 (nestedStderr nested)
            }
  result <-
    recover
      ( Right <$> do
          copyIfPresent (join root ".lawspec/cache") cache
          reset
          baseline <- test []
          let passing = case runReport baseline of
                Just (JArray rows) -> any (\row -> maybe False isTruthy (member "ok" row) && maybe False nonEmpty (member "ran" row)) rows
                _ -> False
          if runCode baseline /= Just 0 || not passing
            then
              pure
                ( JObject
                    [ ("ok", JBool False),
                      ( "baseline",
                        JObject
                          ( ("status", JString (if runDeadline baseline then "timed-out" else "failed"))
                              : [("report", value) | Just value <- [runReport baseline]]
                          )
                      ),
                      ("mutations", JArray []),
                      ("killMatrix", JObject []),
                      ("uniqueKills", JObject [])
                    ]
                )
            else do
              mutations <- forM files $ \file -> do
                let name = relative root file
                outcome <-
                  recover
                    ( Right <$> do
                        bytes <- effect (nodeFailure "open" file) (ReadFile file)
                        mutant <- either failWith pure (parseMutant (fromUtf8 bytes))
                        reset
                        generated <- editedGenerated mutant
                        applyMutant copy mutant
                        pure (mutant, generated)
                    )
                    (pure . Left . (,) "invalid")
                row <- case outcome of
                  Left (phase, failure) -> pure (failed phase failure)
                  Right (mutant, generated) ->
                    recover
                      ( do
                          ran <- test (if null generated then [] else ["--mutated-generated", joinWith "," generated])
                          pure (classifyMutation ran mutant target)
                      )
                      (pure . failed "errored")
                pure (JObject (("name", JString name) : row))
              let killed = [(name, laws) | mutation <- mutations, member "status" mutation == Just (JString "killed"), Just (JString name) <- [member "name" mutation], let laws = [law | JString law <- fromMaybe [] (member "failedLaws" mutation >>= arrayOf)]]
                  killMatrix = group [(law, name) | (name, laws) <- killed, law <- laws]
                  uniqueKills = group [(law, name) | (name, [law]) <- killed]
              pure
                ( JObject
                    [ ("ok", JBool (all ((== Just (JString "killed")) . member "status") mutations)),
                      ("baseline", JObject [("status", JString "passed")]),
                      ("mutations", JArray mutations),
                      ("killMatrix", killMatrix),
                      ("uniqueKills", uniqueKills)
                    ]
                )
      )
      (pure . Left)
  _ <- removeCreated Recursive directory
  either abort pure result
  where
    strings value = [entry | Just items <- [value >>= arrayOf], JString entry <- items]
    splitSeparators text = case break (`elem` ("\\/" :: String)) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitSeparators rest
    nonEmpty = \case
      JArray items -> not (null items)
      JString text -> not (null text)
      _ -> False
    failed phase failure = [("status", JString phase), ("failedLaws", JArray []), ("reason", JString (failureMessage failure))]
    -- Laws in the order they were first killed, each with its mutants.
    group pairs = JObject [(law, JArray [JString name | (law', name) <- pairs, law' == law]) | law <- nub (map fst pairs)]

-- | rename(from, to), where a missing source is not an error.
renameIfPresent :: (Monad m) => FilePath -> FilePath -> Command m ()
renameIfPresent from to =
  effectOr (Rename from to) >>= \case
    Right () -> pure ()
    Left (HostError NotFound _) -> pure ()
    Left problem -> abort (nodeFailure "rename" from problem)

-- | cp(source, destination, {recursive: true}), where a missing source is
-- not an error.
copyIfPresent :: (Monad m) => FilePath -> FilePath -> Command m ()
copyIfPresent source destination =
  effectOr (Stat Follow source) >>= \case
    Left (HostError NotFound _) -> pure ()
    Left problem -> abort (nodeFailure "stat" source problem)
    Right _ -> copyTree source destination False

-- | cp(source, destination, {recursive: true, dereference: true}), with
-- mutateProject's filter when the copy is of the project: no .git, and no
-- compiler cache or native results of a .lawspec folder.
copyTree :: (Monad m) => FilePath -> FilePath -> Bool -> Command m ()
copyTree source destination project = do
  status <- effect (nodeFailure "stat" source) (Stat Follow source)
  case statusKind status of
    -- A directory keeps the default mode: one that is read-only would
    -- refuse its own entries, and nothing a test run reads depends on it.
    DirectoryKind -> do
      effect (nodeFailure "mkdir" destination) (MakeDirectories Nothing destination)
      entries <- effect (nodeFailure "scandir" source) (ListDirectory source)
      forM_ (sortBy compareUtf16 (map entryName entries)) $ \name ->
        unless (project && excluded source name) $
          copyTree (join source name) (join destination name) project
    _ -> do
      bytes <- effect (nodeFailure "open" source) (ReadFile source)
      effect (nodeFailure "open" destination) (WriteFile Replace (statusPermissions status) destination bytes)
  where
    excluded parent name = name == ".git" || (baseName parent == ".lawspec" && name `elem` ["cache", "results"])

baseName :: FilePath -> String
baseName = reverse . takeWhile (/= '/') . reverse

-- | Every symbolic link below the project must resolve inside it, except in
-- .git and a .lawspec folder's cache and results.
checkLinks :: (Monad m) => FilePath -> FilePath -> Command m ()
checkLinks root directory = do
  entries <- effect (nodeFailure "scandir" directory) (ListDirectory directory)
  forM_ (sortBy compareUtf16 (map entryName entries)) $ \name ->
    unless (name == ".git" || (baseName directory == ".lawspec" && name `elem` ["cache", "results"])) $ do
      let file = join directory name
      status <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind status of
        SymbolicLinkKind -> do
          actual <- effect (nodeFailure "realpath" file) (RealPath file)
          let relative' = relative root actual
          when (".." `isPrefixOf` relative' || isAbsolute relative') $
            failWith ("external symbolic link in mutation project: " ++ file)
        DirectoryKind -> checkLinks root file
        _ -> pure ()

-- | The .mutant files the paths name, relative to the project (mutants by
-- default), each once, in order.
discover :: (Monad m) => FilePath -> [String] -> Command m [FilePath]
discover root paths = do
  found <- foldM (\kept name -> (kept ++) <$> visit True (resolve root name)) [] (if null paths then ["mutants"] else paths)
  pure (sortBy compareUtf16 (nub found))
  where
    visit explicit file = do
      grantRead [file]
      status <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind status of
        SymbolicLinkKind -> failWith ("symbolic mutation path: " ++ file)
        DirectoryKind -> do
          entries <- effect (nodeFailure "scandir" file) (ListDirectory file)
          concat <$> forM (sortBy compareUtf16 (map entryName entries)) (visit False . join file)
        _
          | ".mutant" `isSuffixOf` file -> pure [file]
          | explicit -> failWith ("expected a .mutant file: " ++ file)
          | otherwise -> pure []

-- | mutate.mjs applyMutant: each edit must stay inside the copy, reach no
-- symbolic link, and match exactly once.
applyMutant :: (Monad m) => FilePath -> Mutant -> Command m ()
applyMutant directory mutant = do
  root <- effect (nodeFailure "realpath" directory) (RealPath directory)
  forM_ (mutantEdits mutant) $ \(Edit file search replacement) -> do
    let target = resolve root file
        relative' = relative root target
    when (null relative' || ".." `isPrefixOf` relative' || isAbsolute relative') $
      failWith ("edit leaves project: " ++ file)
    actual <- effect (nodeFailure "realpath" target) (RealPath target)
    when (actual /= target) (failWith ("mutation edits through a symbolic link: " ++ file))
    bytes <- effect (nodeFailure "open" target) (ReadFile target)
    permissions <- either (const Nothing) statusPermissions <$> effectOr (Stat Follow target)
    let text = T.pack (fromUtf8 bytes)
        needle = T.pack search
        (before, after) = T.breakOn needle text
    edited <-
      if search == "*"
        then pure (T.pack replacement)
        else
          if null search || T.null after || needle `T.isInfixOf` T.drop (T.length needle) after
            then failWith ("edit must match exactly once: " ++ file)
            else pure (before <> T.pack replacement <> T.drop (T.length needle) after)
    effect (nodeFailure "open" target) (WriteFile Replace permissions target (utf8 (T.unpack edited)))
