-- | lawspec prove: the Node CLI's proof.mjs, ported. Three stages stay
-- apart, as in Why3 and SPARK's gnatprove:
--
-- * obligation generation is the compiler's (proofTasks): each law's
--   SMT-LIB task, the law-set analysis queries and the model tasks, each
--   bound to its law by a fingerprint;
-- * solver execution is this module: Z3 runs each task as a process through
--   the host's spawn and poll effects, and its answer becomes an honest
--   status: proved (unsat), incomplete (sat without a confirmed
--   counterexample, unknown, timeout, resource or memory limit, a failed
--   run), unsupported (no encoding), or refuted;
-- * checking is the compiler's again: a satisfying model is a counterexample
--   only after the reference evaluator confirms it, and the law-set and
--   model answers are settled by the compiler, never by this module.
--
-- Z3 is driven by its SMT-LIB protocol: the task and @(check-sat)@, then a
-- follow-up chosen by the first answer line (@(get-model)@ or
-- @(get-value ...)@ for sat, @(get-info :reason-unknown)@ for unknown).
-- The host-effect ABI gives a process its whole standard input when it
-- starts, so the follow-up cannot be written to the same process: the task
-- runs once ending in @(exit)@, and a sat or unknown answer runs it again
-- with the follow-up, whose input is exactly the legacy host's. A second
-- run that answers differently is a failed run.
--
-- The semantic receipt cache (solver-goals-v1) keys completed proofs on the
-- law's fingerprint and the prover's identity. Its identity names the core
-- build in place of the Node host's build.json and proof.mjs digests, so a
-- receipt written by the legacy host is never reused by the core.
-- ref:DEC-haskell-application-port ref:smt-lib ref:z3 ref:why3
module LawSpec.App.Prove
  ( proveCommand,
    ProofConfig (..),
    proofConfig,
    fingerprint,
    proofTaskFingerprint,
  )
where

import Control.Monad (foldM, forM, forM_, when)
import qualified Data.ByteString as B
import Data.Char (isDigit, isSpace, toLower)
import Data.List (find, findIndex, intercalate, isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Json
import LawSpec.App.Process
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, resolve, takeDirectory)

data ProofConfig = ProofConfig
  { configBinary :: String,
    configTimeout :: Integer,
    configMemory :: Integer,
    configResourceLimit :: Integer,
    configSeed :: Integer,
    configMaxOutput :: Integer
  }
  deriving (Eq, Show)

-- | optionsWithDefaults, from the CLI's options: each given option as
-- Number() reads it, then the ranges proof.mjs allows.
proofConfig :: Arguments -> Either String ProofConfig
proofConfig arguments = do
  let number name fallback = case option name arguments of
        Nothing -> Right (Just (fromInteger fallback))
        Just text -> Right (javascriptNumber text)
  timeout <- number "proof-timeout" 5000
  memory <- number "proof-memory" 512
  rlimit <- number "proof-rlimit" 0
  seed <- number "proof-seed" 0
  let checked :: String -> Integer -> Integer -> Maybe Rational -> Either String Integer
      checked key lowest highest value = case value of
        Just exact
          | exact == fromInteger (round exact),
            abs exact <= 9007199254740991,
            round exact >= lowest,
            round exact <= highest ->
              Right (round exact)
        _ -> Left ("Invalid Z3 " ++ key)
  timeout' <- checked "timeoutMs" 1 600000 timeout
  memory' <- checked "memoryMb" 1 65536 memory
  rlimit' <- checked "resourceLimit" 0 2147483647 rlimit
  seed' <- checked "seed" 0 2147483647 seed
  let binary = fromMaybe "z3" (option "solver" arguments)
  when (null binary || '\0' `elem` binary) (Left "Invalid Z3 executable")
  pure (ProofConfig binary timeout' memory' rlimit' seed' 1048576)

configJson :: ProofConfig -> Json
configJson config =
  JObject
    [ ("binary", JString (configBinary config)),
      ("timeoutMs", integer (configTimeout config)),
      ("memoryMb", integer (configMemory config)),
      ("resourceLimit", integer (configResourceLimit config)),
      ("seed", integer (configSeed config)),
      ("maxOutputBytes", integer (configMaxOutput config))
    ]

hash :: B.ByteString -> String
hash = digestHex . digest

hashText :: String -> String
hashText = hash . utf8

-- | Length-framed values, hashed: "<UTF-8 byte length>:<value>" each.
fingerprint :: [String] -> String
fingerprint values = hashText (concat [show (B.length (utf8 value)) ++ ":" ++ value | value <- values])

str :: String -> Json -> String
str key value = maybe "" jsString (member key value)

strOf :: String -> Json -> Maybe String
strOf key value = member key value >>= stringOf

-- | String(value) of a member, as a template literal shows it.
shown :: String -> Json -> String
shown key value = maybe "undefined" jsString (member key value)

items :: String -> Json -> [Json]
items key value = fromMaybe [] (member key value >>= arrayOf)

-- | {...object, key: value, ...}
with :: Json -> [(String, Json)] -> Json
with = foldl (\object (key, value) -> setMember key value object)

isHex64 :: String -> Bool
isHex64 text = length text == 64 && all (\c -> isDigit c || c `elem` ("abcdef" :: String)) text

proofTaskFingerprint :: Json -> String
proofTaskFingerprint task =
  fingerprint [str "encoding" task, str "lawFingerprint" task, shown "machineBits" task, str "owner" task, str "declaration" task, str "script" task]

validTask :: Json -> Bool
validTask task =
  member "encoding" task `elem` map (Just . JString) ["lawspec-smtlib-v1", "lawspec-smtlib-v2"]
    && member "machineBits" task `elem` [Just (integer 32), Just (integer 64)]
    && all (\key -> isJust (strOf key task)) ["owner", "declaration", "lawFingerprint", "script", "taskFingerprint"]
    && isHex64 (str "lawFingerprint" task)
    && Just (proofTaskFingerprint task) == strOf "taskFingerprint" task

-- | The selected prover, or why none could be selected and the outcome that
-- gives every task.
data Prover = Prover
  { proverBinary :: FilePath,
    proverBinaryFingerprint :: String,
    proverVersion :: String,
    proverArguments :: [String],
    proverFingerprint :: String
  }

type Selected = Either (String, String) Prover

proverJson :: Prover -> Json
proverJson prover =
  JObject
    [ ("name", JString "z3"),
      ("version", JString (proverVersion prover)),
      ("binary", JString (proverBinary prover)),
      ("binaryFingerprint", JString (proverBinaryFingerprint prover)),
      ("fingerprint", JString (proverFingerprint prover)),
      ("arguments", JArray (map JString (proverArguments prover)))
    ]

-- | executable(binary): an explicit path, or the first PATH entry holding
-- it, with its symbolic links resolved (the realpath effect).
executable :: (Monad m) => FilePath -> String -> Command m (Maybe FilePath)
executable cwd binary = do
  pathVariable <- either (const Nothing) id <$> effectOr (GetEnvironment "PATH")
  let candidates
        | '/' `elem` binary || '\\' `elem` binary = [resolve cwd binary]
        | otherwise = [resolve cwd (resolve cwd folder `joinName` binary) | folder <- splitOn ':' (fromMaybe "" pathVariable)]
      joinName folder name = join folder name
  grantRead candidates
  foldM
    ( \found candidate -> case found of
        Just _ -> pure found
        Nothing ->
          effectOr (Stat Follow candidate) >>= \case
            Right status
              | statusKind status == FileKind ->
                  effectOr (RealPath candidate) >>= \case
                    Right resolved -> do
                      grantRead [resolved]
                      pure (Just resolved)
                    -- proof.mjs skips a candidate realpath() cannot resolve.
                    Left problem
                      | errorKind problem `elem` [NotFound, PermissionDenied, NotADirectory] -> pure Nothing
                      | otherwise -> abort (Failure (errorMessage problem) Nothing)
            _ -> pure Nothing
    )
    Nothing
    candidates
  where
    splitOn separator text = case break (== separator) text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn separator rest

-- | The executable's SHA-256. proof.mjs reads and hashes it again after
-- every run, to notice an executable replaced while it ran; this keeps the
-- digest with the file's size and modification time and hashes it again
-- only when either changed, since a 16 MB Z3 hashed after each of dozens of
-- runs dominated a prove run.
binaryDigest :: (Monad m) => FilePath -> Command m (Maybe String)
binaryDigest file =
  effectOr (Stat Follow file) >>= \case
    Left _ -> pure Nothing
    Right status -> do
      let stamp = (statusSize status, statusModified status)
      known <- M.lookup file . sessionDigests <$> getSession
      case known of
        Just (stamp', value) | stamp' == stamp -> pure (Just value)
        _ ->
          effectOr (ReadFile file) >>= \case
            Left _ -> pure Nothing
            Right bytes -> do
              let value = hash bytes
              modifySession (\s -> s {sessionDigests = M.insert file (stamp, value) (sessionDigests s)})
              pure (Just value)

-- | One Z3 run as proof.mjs's execute() reports it.
data Execution = Execution
  { executionStdout :: String,
    executionStderr :: String,
    executionInput :: String,
    executionOutcome :: Maybe String,
    executionError :: Maybe String,
    executionTimeout :: Bool,
    executionOutputLimit :: Bool,
    executionExit :: Maybe ExitStatus,
    executionMicroseconds :: Integer
  }

exitCodeJson :: Execution -> Json
exitCodeJson run = case executionExit run of
  Just (ExitCode code) -> integer (toInteger code)
  _ -> JNull

signalJson :: Execution -> Json
signalJson run = case executionExit run of
  Just (Signalled name) -> JString name
  _ -> JNull

elapsedJson :: Execution -> Json
elapsedJson run = JNumber (realToFrac (fromIntegral (executionMicroseconds run) / 1000 :: Double))

exitedZero :: Execution -> Bool
exitedZero run = executionExit run == Just (ExitCode 0)

followUp :: String -> String
followUp token = case token of
  "sat" -> "(get-model)\n(exit)\n"
  "unknown" -> "(get-info :reason-unknown)\n(exit)\n"
  _ -> "(exit)\n"

-- | execute(): one non-interactive run, or a protocol run whose follow-up
-- 'finishFor' chooses from the first answer line (see the module header).
execute :: (Monad m) => FilePath -> FilePath -> [String] -> String -> ProofConfig -> Integer -> Maybe (String -> String) -> Command m Execution
execute cwd binary arguments initial config timeoutMs protocol = case protocol of
  Nothing -> once initial
  Just finishFor -> do
    first <- once (initial ++ "(exit)\n")
    case answer first of
      -- No answer line (the run timed out or failed first): the legacy
      -- host had sent only the task, so that is the run's input.
      Nothing -> pure first {executionInput = initial}
      Just token
        | finishFor token == "(exit)\n" -> pure (classified token first)
        | otherwise -> do
            second <- once (initial ++ finishFor token)
            let total = executionMicroseconds first + executionMicroseconds second
            pure $ case answer second of
              Just again
                | again == token -> (classified token second) {executionMicroseconds = total}
              Just _ -> second {executionMicroseconds = total, executionError = Just "Z3 answered the same task differently when it ran again for the follow-up"}
              Nothing -> second {executionMicroseconds = total}
  where
    once input = do
      run <-
        runProcess
          (launch binary arguments cwd)
            { launchInput = Just (utf8 input),
              launchTimeout = Just timeoutMs,
              launchLimit = Just (fromInteger (configMaxOutput config))
            }
      pure
        Execution
          { executionStdout = fromUtf8 (runStdout run),
            executionStderr = fromUtf8 (runStderr run),
            executionInput = input,
            executionOutcome = Nothing,
            executionError = runError run,
            executionTimeout = runTimedOut run,
            executionOutputLimit = runOverLimit run,
            executionExit = runExit run,
            executionMicroseconds = runMicroseconds run
          }
    answer run
      | '\n' `elem` executionStdout run = Just (trim (takeWhile (/= '\n') (executionStdout run)))
      | otherwise = Nothing
    classified token run
      | token `elem` ["sat", "unsat", "unknown"] = run {executionOutcome = Just token}
      | otherwise = run {executionError = Just (fromMaybe "unexpected Z3 protocol response" (executionError run))}

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | prover(config): the executable, its digest, its version and identity.
selectProver :: (Monad m) => FilePath -> ProofConfig -> Command m Selected
selectProver cwd config = do
  found <- executable cwd (configBinary config)
  case found of
    Nothing -> pure (Left ("Z3 executable is unavailable: " ++ configBinary config, "unavailable"))
    Just binary -> do
      fingerprint' <- binaryDigest binary
      case fingerprint' of
        Nothing -> pure (Left ("Z3 executable is unavailable: " ++ configBinary config, "failed"))
        Just binaryFingerprint -> do
          run <- execute cwd binary ["-version"] "" config 30000 Nothing
          let version = trim (executionStdout run)
          if not (exitedZero run) || isJust (executionError run) || executionTimeout run || executionOutputLimit run || not (versionLine version)
            then pure (Left ("The selected executable did not return a successful Z3 version response", if executionTimeout run then "timeout" else "failed"))
            else do
              let arguments = ["-in", "-smt2", "-t:" ++ show (configTimeout config), "-memory:" ++ show (configMemory config)]
                  identity = fingerprint [binaryFingerprint, version, compact (JArray (map JString arguments)), compact (configJson config)]
              pure (Right (Prover binary binaryFingerprint version arguments identity))
  where
    versionLine text = case stripPrefix' "Z3 version " text of
      Just rest -> let (major, more) = span isDigit rest in not (null major) && case more of '.' : minor : _ -> isDigit minor; _ -> False
      Nothing -> False

stripPrefix' :: String -> String -> Maybe String
stripPrefix' prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing

data Cache = Cache {cacheFolder :: FilePath, cacheIdentity :: String}

recursionName :: Maybe Json -> String
recursionName recursion = case recursion >>= strOf "encoding" of
  Just "guarded-axioms" -> "unfolding step by step up to " ++ maybe "undefined" (shown "fuel") recursion ++ " times"
  Just "define-fun-rec" -> "solver recursion"
  _ -> ""

-- | The SMT-LIB preamble every task starts with.
preamble :: ProofConfig -> String -> String
preamble config script =
  "(set-option :print-success false)\n(set-option :produce-models true)\n(set-option :random-seed "
    ++ show (configSeed config)
    ++ ")\n(set-option :rlimit "
    ++ show (configResourceLimit config)
    ++ ")\n"
    ++ script
    ++ "(check-sat)\n"

-- | The text after the first answer line, trimmed.
afterFirstLine :: String -> String
afterFirstLine text = case break (== '\n') text of
  (_, _ : rest) -> trim rest
  _ -> trim text

data Context = Context
  { contextCwd :: FilePath,
    contextConfig :: ProofConfig,
    contextSelected :: Selected
  }

-- | attempt(): one task's script through Z3, as an evidence row.
attempt :: (Monad m) => Context -> Json -> String -> String -> Maybe [String] -> Command m Json
attempt context task script taskFingerprint names = do
  let config = contextConfig context
      common =
        jsObject
          ( [ ("owner", fromMaybe JNull (member "owner" task)),
              ("declaration", fromMaybe JNull (member "declaration" task))
            ]
              ++ [("at", value) | Just value <- [member "at" task]]
              ++ [ (key, value)
                 | key <- ["lawFingerprint", "taskFingerprint", "encoding", "machineBits"],
                   Just value <- [member key task]
                 ]
              ++ [("configuration", configJson config)]
          )
  case (strOf "status" task, contextSelected context) of
    (Just "unsupported", _) -> pure (with common [("status", JString "unsupported"), ("outcome", JString "unsupported"), ("reason", fromMaybe JNull (member "reason" task))])
    (status, _)
      | status /= Just "ready" || not (validTask task) ->
          pure (with common [("status", JString "incomplete"), ("outcome", JString "failed"), ("reason", JString "Compiler proof task binding is invalid")])
    (_, Left (message, outcome)) -> pure (with common [("status", JString "incomplete"), ("outcome", JString outcome), ("reason", JString message)])
    (_, Right prover) -> do
      let input = preamble config script
          finish token = case (token, names) of
            ("sat", Just wanted@(_ : _)) -> "(get-value (" ++ unwords wanted ++ "))\n(exit)\n"
            _ -> followUp token
      run <- execute (contextCwd context) (proverBinary prover) (proverArguments prover) input config (configTimeout config) (Just finish)
      unchanged <- (== Just (proverBinaryFingerprint prover)) <$> binaryDigest (proverBinary prover)
      let metadata =
            with
              common
              [ ("prover", proverJson prover),
                ("configuration", configJson config),
                ("runFingerprint", JString (fingerprint [taskFingerprint, proverFingerprint prover, executionInput run])),
                ("elapsedMs", elapsedJson run),
                ("exitCode", exitCodeJson run),
                ("signal", signalJson run),
                ("stdout", JString (executionStdout run)),
                ("stderr", JString (executionStderr run))
              ]
          everything = map toLower (executionStdout run ++ "\n" ++ executionStderr run)
          (outcome, reason)
            | not unchanged = (Just "failed", "Z3 executable changed during execution")
            | executionTimeout run = (Just "timeout", "Z3 exceeded the host wall-clock limit")
            | executionOutputLimit run = (Just "failed", "Z3 exceeded the output limit")
            | not (exitedZero run) && ("out of memory" `isInfixOf` everything || "out_of_memory" `isInfixOf` everything) =
                (Just "out-of-memory", "Z3 reported memory exhaustion")
            | isJust (executionError run) || not (exitedZero run) || isNothing (executionOutcome run) || "(error " `isInfixOf` executionStdout run =
                (Just "failed", fromMaybe "Z3 did not complete the task protocol successfully" (executionError run))
            | executionOutcome run == Just "unsat" =
                (Just "unsat", "Z3 established this law, including required definedness; trusts the typed translation and selected solver, without a kernel-checked certificate")
            | executionOutcome run == Just "sat" =
                (Just "sat", "Z3 returned a satisfying model for the negated proof task; it has not been validated as a LawSpec counterexample")
            | otherwise =
                ( Just
                    (if reasonIs "timeout" then "timeout" else if reasonIs "max. resource limit exceeded" then "resource-limit" else fromMaybe "unknown" (executionOutcome run)),
                  "Z3 could not decide this task: " ++ trim (drop 1 (dropWhile (/= '\n') (executionStdout run)))
                )
          reasonIs text = any (\line -> (":reason-unknown" `isInfixOf` line) && ("\"" ++ text ++ "\"") `isInfixOf` line) (lines (executionStdout run))
          model = if executionOutcome run == Just "sat" then Just (afterFirstLine (executionStdout run)) else Nothing
          named = maybe False (not . null) names
      pure $
        with
          metadata
          ( [ ("status", JString (if outcome == Just "unsat" then "proved" else "incomplete")),
              ("outcome", maybe JNull JString outcome),
              ("reason", JString reason)
            ]
              ++ maybe [] (\text -> if named then [("values", JString text)] else [("model", JString text), ("modelValidated", JBool False)]) model
          )

-- | solve(): the task in its encoding, its alternative encoding, then by
-- induction, as the compiler's task asks.
solve :: (Monad m) => Context -> Json -> Command m Json
solve context task = do
  first <- attempt context task (str "script" task) (str "taskFingerprint" task) Nothing
  let recursion = member "recursion" task
      induction = member "induction" task
      selectedError = either (const True) (const False) (contextSelected context)
      outcomeOf = str "outcome"
      tried row fingerprint' rec' = JObject ([("recursion", value) | Just value <- [rec']] ++ [("taskFingerprint", JString fingerprint'), ("outcome", fromMaybe JNull (member "outcome" row)), ("runFingerprint", fromMaybe JNull (member "runFingerprint" row)), ("elapsedMs", fromMaybe JNull (member "elapsedMs" row))])
  if isNothing recursion && isNothing induction
    then pure first
    else
      if str "status" first == "unsupported" || (str "status" first == "incomplete" && outcomeOf first == "failed" && isNothing (member "prover" first))
        then pure first
        else do
          let attempts0 = [tried first (str "taskFingerprint" task) recursion]
          if outcomeOf first == "unsat"
            then pure (with first ([("recursion", value) | Just value <- [recursion]] ++ [("attempts", JArray attempts0), ("reason", JString (str "reason" first ++ maybe "" (\r -> "; by " ++ recursionName (Just r)) recursion))]))
            else do
              let best0 = with first ([("recursion", value) | Just value <- [recursion]] ++ [("attempts", JArray attempts0)])
              alternativeResult <- case member "alternative" task of
                Just alternative | not selectedError ->
                  case strOf "script" alternative of
                    Just script
                      | proofTaskFingerprint (setMember "script" (JString script) task) == str "taskFingerprint" alternative -> do
                          second <- attempt context task script (str "taskFingerprint" alternative) Nothing
                          let attempts1 = attempts0 ++ [tried second (str "taskFingerprint" alternative) (member "recursion" alternative)]
                              alternativeRecursion = member "recursion" alternative
                          if outcomeOf second == "unsat"
                            then
                              pure
                                ( Left
                                    ( with
                                        second
                                        ( [("taskFingerprint", fromMaybe JNull (member "taskFingerprint" alternative))]
                                            ++ [("recursion", value) | Just value <- [alternativeRecursion]]
                                            ++ [ ("attempts", JArray attempts1),
                                                 ("reason", JString (str "reason" second ++ "; by " ++ recursionName alternativeRecursion ++ " after " ++ recursionName recursion ++ " gave " ++ outcomeOf first))
                                               ]
                                        )
                                    )
                                )
                            else pure (Right (with best0 [("attempts", JArray attempts1), ("reason", JString (str "reason" first ++ "; " ++ recursionName alternativeRecursion ++ " gave " ++ outcomeOf second))]))
                    _ -> pure (Left (with best0 [("reason", JString (str "reason" first ++ "; the alternative encoding's binding is invalid"))]))
                _ -> pure (Right best0)
              case alternativeResult of
                Left done -> pure done
                Right best -> case induction of
                  Nothing -> pure best
                  Just _ | selectedError -> pure best
                  Just plan
                    | str "status" plan /= "ready" ->
                        pure
                          ( with
                              best
                              [ ("induction", JObject [("on", fromMaybe JNull (member "on" plan)), ("using", fromMaybe JNull (member "using" plan)), ("cases", JArray [])]),
                                ("reason", JString (str "reason" best ++ "; induction on " ++ shown "on" plan ++ " is unsupported: " ++ shown "reason" plan))
                              ]
                          )
                    | otherwise -> inductively best plan
  where
    inductively best plan = do
      let bound item = proofTaskFingerprint (setMember "script" (fromMaybe JNull (member "script" item)) task) == str "taskFingerprint" item
      cases <- forM (items "cases" plan) $ \item ->
        if isNothing (strOf "script" item) || not (bound item)
          then pure (JObject [("case", fromMaybe JNull (member "case" item)), ("outcome", JString "failed"), ("reason", JString "the case's binding is invalid")])
          else do
            let runs =
                  (member "recursion" item, str "script" item, str "taskFingerprint" item)
                    : [ (member "recursion" alternative, str "script" alternative, str "taskFingerprint" alternative)
                      | Just alternative <- [member "alternative" item],
                        isJust (strOf "script" alternative),
                        bound alternative
                      ]
                inputs = case member "inputs" item >>= arrayOf of
                  Just values -> Just (map jsString values)
                  Nothing -> Nothing
            let go receipt [] = pure receipt
                go receipt ((rec', script, fingerprint') : more) = do
                  done <- attempt context task script fingerprint' inputs
                  let attemptRow = JObject ([("recursion", value) | Just value <- [rec']] ++ [("taskFingerprint", JString fingerprint'), ("outcome", fromMaybe JNull (member "outcome" done)), ("runFingerprint", fromMaybe JNull (member "runFingerprint" done)), ("elapsedMs", fromMaybe JNull (member "elapsedMs" done))])
                      receipt' =
                        with
                          receipt
                          ( [("attempts", JArray (items "attempts" receipt ++ [attemptRow])), ("outcome", fromMaybe JNull (member "outcome" done))]
                              ++ [("recursion", value) | Just value <- [rec']]
                              ++ [("taskFingerprint", JString fingerprint'), ("runFingerprint", fromMaybe JNull (member "runFingerprint" done))]
                          )
                      receipt'' = case member "values" done of
                        Just values | isNothing (member "values" receipt') -> setMember "values" values receipt'
                        _ -> receipt'
                  if str "outcome" done == "unsat" then pure receipt'' else go receipt'' more
            go (JObject [("case", fromMaybe JNull (member "case" item)), ("attempts", JArray [])]) runs
      let record = JObject [("on", fromMaybe JNull (member "on" plan)), ("using", fromMaybe JNull (member "using" plan)), ("asked", fromMaybe JNull (member "asked" plan)), ("cases", JArray cases)]
          -- The compiler names what the proof cites (induction.citing,
          -- from inductionCiting in LawSpec.Core.Smt); this only joins it.
          citing = map jsString (items "citing" plan)
      if all (\c -> str "outcome" c == "unsat") cases
        then
          pure
            ( dropMember "modelValidated" . dropMember "model" $
                with
                  best
                  [ ("status", JString "proved"),
                    ("outcome", JString "unsat"),
                    ("induction", record),
                    ( "reason",
                      JString
                        ( "Z3 established this law by induction on "
                            ++ shown "on" plan
                            ++ ", every case: "
                            ++ intercalate ", " [shown "case" c ++ " by " ++ recursionName (member "recursion" c) | c <- cases]
                            ++ (if null citing then "" else "; citing " ++ intercalate ", " citing)
                            ++ "; trusts the typed translation and selected solver, without a kernel-checked certificate"
                        )
                    )
                  ]
            )
        else
          pure
            ( with
                best
                [ ("induction", record),
                  ("reason", JString (str "reason" best ++ "; induction on " ++ shown "on" plan ++ ": " ++ intercalate ", " ["case " ++ shown "case" c ++ " gave " ++ shown "outcome" c | c <- cases, str "outcome" c /= "unsat"]))
                ]
            )

-- | The part after the last occurrence of a separator (split().pop()).
lastPart :: String -> String -> String
lastPart separator text = go text text
  where
    go kept rest
      | null rest = kept
      | separator `isPrefixOf` rest = let after = drop (length separator) rest in go after after
      | otherwise = go kept (drop 1 rest)

-- | cachedSolve(): a completed semantic receipt, or a new solver run whose
-- proof is then kept.
cachedSolve :: (Monad m) => Context -> Maybe Cache -> Json -> Command m Json
cachedSolve context cache task = case (cache, contextSelected context) of
  (Just store, Right prover)
    | str "status" task == "ready",
      validTask task -> do
        let key = fingerprint [cacheIdentity store, str "encoding" task, str "lawFingerprint" task, shown "machineBits" task]
            file = join (cacheFolder store) (key ++ ".json")
        saved <- either (const Nothing) (either (const Nothing) Just . parseJson . fromUtf8) <$> effectOr (ReadFile file)
        reusable <- case saved of
          Just record | complete key record prover -> do
            unchanged <- (== Just (proverBinaryFingerprint prover)) <$> binaryDigest (proverBinary prover)
            pure (if unchanged then Just record else Nothing)
          _ -> pure Nothing
        case reusable of
          Just record -> do
            let receipt = fromMaybe JNull (member "receipt" record)
                savedTask = fromMaybe JNull (member "task" record)
            pure $
              with
                receipt
                ( [ ("owner", fromMaybe JNull (member "owner" task)),
                    ("declaration", fromMaybe JNull (member "declaration" task))
                  ]
                    ++ [("at", value) | Just value <- [member "at" task]]
                    ++ [("currentTaskFingerprint", fromMaybe JNull (member "taskFingerprint" task))]
                    ++ [ ("currentInduction", JObject [("on", fromMaybe JNull (member "on" induction)), ("using", fromMaybe JNull (member "using" induction))])
                       | Just recorded <- [member "induction" receipt],
                         isTruthy recorded,
                         Just induction <- [member "induction" task],
                         isTruthy induction
                       ]
                    ++ [ ( "reused",
                           JObject
                             [ ("key", JString key),
                               ("owner", fromMaybe JNull (member "owner" savedTask)),
                               ("declaration", fromMaybe JNull (member "declaration" savedTask)),
                               ("taskFingerprint", fromMaybe JNull (member "taskFingerprint" receipt)),
                               ("runFingerprint", fromMaybe JNull (member "runFingerprint" receipt))
                             ]
                         ),
                         ("reason", JString (shown "reason" receipt ++ "; reused a completed semantic proof receipt; no new solver task ran"))
                       ]
                )
          Nothing -> do
            receipt <- solve context task
            when (str "status" receipt == "proved" && str "outcome" receipt == "unsat" && member "exitCode" receipt == Just (integer 0)) $ do
              let record = JObject [("version", integer 1), ("key", JString key), ("task", task), ("receipt", receipt), ("digest", JString (hashText (compact (JArray [task, receipt]))))]
              _ <- effectOr (MakeDirectories Nothing (cacheFolder store))
              _ <- effectOr (WriteFile Replace Nothing file (utf8 (compact record ++ "\n")))
              pure ()
            pure receipt
  _ -> solve context task
  where
    complete key record prover =
      let receipt = fromMaybe JNull (member "receipt" record)
          savedTask = fromMaybe JNull (member "task" record)
       in member "version" record == Just (integer 1)
            && member "key" record == Just (JString key)
            && validTask savedTask
            && member "lawFingerprint" savedTask == member "lawFingerprint" task
            && member "encoding" savedTask == member "encoding" task
            && member "machineBits" savedTask == member "machineBits" task
            && member "status" receipt == Just (JString "proved")
            && member "outcome" receipt == Just (JString "unsat")
            && member "exitCode" receipt == Just (integer 0)
            && member "lawFingerprint" receipt == member "lawFingerprint" task
            && isHex64 (fromMaybe "" (strOf "runFingerprint" receipt))
            && (member "prover" receipt >>= strOf "fingerprint") == Just (proverFingerprint prover)
            && member "digest" record == Just (JString (hashText (compact (JArray [savedTask, receipt]))))

-- | counterexampleValues(): the law's outer inputs at a model of its
-- counterexample query, for the compiler's evaluator to check.
counterexampleValues :: (Monad m) => Context -> Prover -> Json -> Command m (Maybe Json)
counterexampleValues context prover task = case member "counterexample" task of
  Just query
    | Just script <- strOf "script" query,
      Just inputs <- member "inputs" query >>= arrayOf ->
        if fingerprint ["lawspec-smtlib-v2", str "lawFingerprint" task, shown "machineBits" task, str "owner" task, str "declaration" task, script] /= str "fingerprint" query
          then pure Nothing
          else do
            let names = map (shown "name") inputs
                config = contextConfig context
            if null names
              then pure (Just (JObject [("outcome", JString "sat"), ("values", JString "()"), ("fingerprint", fromMaybe JNull (member "fingerprint" query)), ("runFingerprint", JNull)]))
              else do
                let finish token = if token == "sat" then "(get-value (" ++ unwords names ++ "))\n(exit)\n" else "(exit)\n"
                run <- execute (contextCwd context) (proverBinary prover) (proverArguments prover) (preamble config script) config (configTimeout config) (Just finish)
                if executionOutcome run /= Just "sat" || executionTimeout run || executionOutputLimit run || isJust (executionError run) || not (exitedZero run)
                  then pure (Just (JObject [("outcome", JString (fromMaybe "failed" (executionOutcome run))), ("stdout", JString (executionStdout run))]))
                  else
                    pure
                      ( Just
                          ( JObject
                              [ ("outcome", JString "sat"),
                                ("values", JString (afterFirstLine (executionStdout run))),
                                ("fingerprint", fromMaybe JNull (member "fingerprint" query)),
                                ("runFingerprint", JString (fingerprint [str "fingerprint" query, proverFingerprint prover, executionInput run]))
                              ]
                          )
                      )
  _ -> pure Nothing

-- | One law-set or model query, possibly answered from the cache.
data Query = Query
  { queryOutcome :: String,
    queryValues :: String,
    queryInvariant :: String,
    queryInputs :: Maybe Json,
    queryRun :: Maybe Execution,
    queryRunFingerprint :: Maybe String,
    queryReused :: Maybe Json,
    queryCacheFile :: Maybe FilePath,
    queryPending :: Maybe (FilePath, String, Json),
    queryError :: Maybe String
  }

queryFingerprint :: Json -> Json -> String
queryFingerprint row task =
  if str "kind" row == "model"
    then hashText (str "declaration" row ++ "\0" ++ str "kind" task ++ "\0" ++ str "script" task)
    else fingerprint [str "declaration" row, str "stage" row, str "script" task]

verifiedOutcome :: (Monad m) => Prover -> Execution -> Command m String
verifiedOutcome prover run
  | executionTimeout run = pure "timeout"
  | otherwise = do
      unchanged <- (== Just (proverBinaryFingerprint prover)) <$> binaryDigest (proverBinary prover)
      pure $
        if not unchanged || executionOutputLimit run || isJust (executionError run) || not (exitedZero run) || isNothing (executionOutcome run) || "(error " `isInfixOf` executionStdout run
          then "failed"
          else fromMaybe "failed" (executionOutcome run)

-- | analysisQuery(): a saved, still valid answer to the same logical query,
-- or a new run whose answer may be saved once the compiler settles it.
analysisQuery :: (Monad m) => Maybe Cache -> Prover -> Json -> Json -> Bool -> Command m Query -> Command m Query
analysisQuery cache prover row task fresh executeQuery = do
  let semantic = fromMaybe "" (strOf "semanticFingerprint" task)
      model = str "kind" row == "model"
      eligible = case cache of
        Just _ -> isHex64 semantic && strOf "fingerprint" task == Just (queryFingerprint row task)
        Nothing -> False
      key = case cache of
        Just store | eligible -> Just (fingerprint [cacheIdentity store, if model then "model" else "analysis", if model then "" else str "stage" row, semantic])
        _ -> Nothing
      file = case (cache, key) of
        (Just store, Just k) -> Just (join (cacheFolder store) (k ++ ".json"))
        _ -> Nothing
  saved <- case (file, fresh) of
    (Just path', False) -> either (const Nothing) (either (const Nothing) Just . parseJson . fromUtf8) <$> effectOr (ReadFile path')
    _ -> pure Nothing
  reused <- case (saved, key) of
    (Just document, Just k)
      | Just record <- member "record" document,
        member "version" document == Just (integer 1),
        member "key" document == Just (JString k),
        member "digest" document == Just (JString (hashText (compact record))),
        strOf "semanticFingerprint" record == Just semantic,
        strOf "solverFingerprint" record == Just (proverFingerprint prover),
        str "outcome" record `elem` ["sat", "unsat"],
        member "completed" record == Just (JBool True),
        (member "run" record >>= member "exitCode") == Just (integer 0),
        strOf "taskFingerprint" record == Just (queryFingerprint record (JObject [("kind", fromMaybe JNull (member "taskKind" record)), ("script", fromMaybe JNull (member "script" record))])) -> do
          unchanged <- (== Just (proverBinaryFingerprint prover)) <$> binaryDigest (proverBinary prover)
          pure (if unchanged then Just record else Nothing)
    _ -> pure Nothing
  case reused of
    Just record ->
      pure
        Query
          { queryOutcome = str "outcome" record,
            queryValues = str "values" record,
            queryInvariant = str "invariant" record,
            queryInputs = member "inputs" record,
            queryRun = Nothing,
            queryRunFingerprint = strOf "runFingerprint" record,
            queryReused =
              Just
                ( JObject
                    [ ("key", JString (fromMaybe "" key)),
                      ("owner", fromMaybe JNull (member "owner" record)),
                      ("declaration", fromMaybe JNull (member "declaration" record)),
                      ("taskFingerprint", fromMaybe JNull (member "taskFingerprint" record)),
                      ("runFingerprint", fromMaybe JNull (member "runFingerprint" record))
                    ]
                ),
            queryCacheFile = file,
            queryPending = Nothing,
            queryError = Nothing
          }
    Nothing -> do
      done <- executeQuery
      let pending = case (file, key, queryRun done) of
            (Just path', Just k, Just run)
              | eligible ->
                  Just
                    ( path',
                      k,
                      jsObject
                        ( [ ("kind", fromMaybe JNull (member "kind" row)),
                            ("taskKind", fromMaybe JNull (member "kind" task)),
                            ("owner", fromMaybe JNull (member "owner" row)),
                            ("declaration", fromMaybe JNull (member "declaration" row))
                          ]
                            ++ [("stage", value) | Just value <- [member "stage" row]]
                            ++ [ ("taskFingerprint", fromMaybe JNull (member "fingerprint" task)),
                                 ("semanticFingerprint", fromMaybe JNull (member "semanticFingerprint" task)),
                                 ("script", fromMaybe JNull (member "script" task)),
                                 ("solverFingerprint", JString (proverFingerprint prover))
                               ]
                            ++ [("inputs", value) | Just value <- [member "inputs" task]]
                            ++ [ ("outcome", JString (queryOutcome done)),
                                 ("values", JString (queryValues done))
                               ]
                            ++ [("invariant", JString (queryInvariant done)) | model]
                            ++ [ ("run", runJson run),
                                 ("runFingerprint", maybe JNull JString (queryRunFingerprint done)),
                                 ("completed", JBool True)
                               ]
                        )
                    )
            _ -> Nothing
      pure done {queryInputs = member "inputs" task, queryPending = pending}

-- | A run as proof.mjs keeps it in a saved query: execute()'s result.
runJson :: Execution -> Json
runJson run =
  JObject
    [ ("stdout", JString (executionStdout run)),
      ("stderr", JString (executionStderr run)),
      ("input", JString (executionInput run)),
      ("outcome", maybe JNull JString (executionOutcome run)),
      ("error", maybe JNull JString (executionError run)),
      ("timeout", JBool (executionTimeout run)),
      ("outputLimit", JBool (executionOutputLimit run)),
      ("exitCode", exitCodeJson run),
      ("signal", signalJson run),
      ("elapsedMs", elapsedJson run)
    ]

saveQuery :: (Monad m) => Query -> Command m ()
saveQuery done = case (queryPending done, queryRun done) of
  (Just (file, key, record), Just run)
    | queryOutcome done `elem` ["sat", "unsat"],
      exitedZero run -> do
        _ <- effectOr (MakeDirectories Nothing (takeDirectory file))
        _ <- effectOr (WriteFile Replace Nothing file (utf8 (compact (JObject [("version", integer 1), ("key", JString key), ("record", record), ("digest", JString (hashText (compact record)))]) ++ "\n")))
        pure ()
  _ -> pure ()

-- | Run one law-set or model query's script.
runQuery :: (Monad m) => Context -> Prover -> Json -> (String -> String) -> Bool -> Command m Query
runQuery context prover task finish spacer = do
  let config = contextConfig context
  run <- execute (contextCwd context) (proverBinary prover) (proverArguments prover) (preamble config (str "script" task)) config (configTimeout config) (Just finish)
  outcome <- verifiedOutcome prover run
  let body = if outcome == "sat" then drop 1 (dropWhile (/= '\n') (executionStdout run)) else ""
      invariant = if spacer && outcome == "sat" then definition body else ""
      inputs = map jsString (items "inputs" task)
      values
        | spacer = ""
        | not (null inputs) || str "kind" task /= "" = trim body
        | otherwise = trim body
  pure
    Query
      { queryOutcome = outcome,
        queryValues = if spacer then "" else if null inputs && not (isModelTask task) then "" else values,
        queryInvariant = invariant,
        queryInputs = Nothing,
        queryRun = Just run,
        queryRunFingerprint = Just (fingerprint [str "fingerprint" task, proverFingerprint prover, executionInput run]),
        queryReused = Nothing,
        queryCacheFile = Nothing,
        queryPending = Nothing,
        queryError = Nothing
      }
  where
    isModelTask = isJust . member "kind"
    -- The balanced (define-fun Inv ...) form of a Spacer model.
    definition body = case findIndex' "(define-fun Inv " body of
      Nothing -> ""
      Just at -> balanced (drop at body)
    balanced text = go (0 :: Int) "" text
      where
        go _ kept [] = if null kept then "" else ""
        go depth kept (c : rest)
          | c == '(' = go (depth + 1) (c : kept) rest
          | c == ')' = if depth - 1 == 0 then reverse (c : kept) else go (depth - 1) (c : kept) rest
          | otherwise = go depth (c : kept) rest
    findIndex' needle haystack = findIndex (isPrefixOf needle) (tailsOf haystack)
    tailsOf text = case text of
      [] -> [[]]
      _ : rest -> text : tailsOf rest

-- | proveWithZ3(): every task, then the compiler's checks of every answer.
proveWithZ3 :: (Monad m) => Invocation -> ProofConfig -> Json -> Command m Json
proveWithZ3 invocation config request0 = do
  let request = foldr dropMember request0 ["analysisResults", "modelResults", "proofCounterexamples"]
      cwd = invocationDirectory invocation
  result <- call "proofTasks" request
  if not (null (items "diagnostics" result))
    then pure (with result [("solverEvidence", JArray [])])
    else do
      let tasks = items "proofTasks" result
          analysis = items "analysisTasks" result
          modelTasks = items "modelTasks" result
          ready row = str "status" row == "ready"
          needed = any ready tasks || any ready analysis || any (not . null . items "tasks") modelTasks
      -- No task is ready: no solver is selected, and none runs.
      selected <- if needed then selectProver cwd config else pure (Right (Prover "" "" "" [] ""))
      let context' = Context cwd config selected
          available = needed && either (const False) (const True) selected
          selectedError = either (Just . fst) (const Nothing) selected
      cache <- case (strOf "cacheDirectory" request, selected) of
        (Just directory, Right prover)
          | available,
            not (null directory) ->
              pure (Just (Cache (join (takeDirectory directory) "solver-goals-v1") (fingerprint ["lawspec.solver-cache.v1", buildDigestOf invocation, "lawspec-core", proverFingerprint prover])))
        _ -> pure Nothing
      evidence0 <- forM tasks (cachedSolve context' cache)
      -- Counterexample values for each unproved law.
      searched <- fmap concat . forM (zip3 [0 :: Int ..] evidence0 tasks) $ \(index, item, task) ->
        if str "status" item `elem` ["proved", "unsupported"] || isJust selectedError || not available
          then pure []
          else do
            found <-
              if str "outcome" item == "sat" || isJust (member "recursion" task)
                then either (const (pure Nothing)) (\prover -> counterexampleValues context' prover task) selected
                else pure Nothing
            let fromQuery = case found of
                  Just values | str "outcome" values == "sat" -> [(index, values, Nothing)]
                  _ -> []
                inductionCases =
                  [ (index, JObject [("outcome", JString "sat"), ("values", values), ("fingerprint", fromMaybe JNull (member "taskFingerprint" c)), ("runFingerprint", fromMaybe JNull (member "runFingerprint" c))], Just (shown "case" c))
                  | c <- maybe [] (items "cases") (member "induction" item),
                    str "outcome" c == "sat",
                    Just values <- [member "values" c],
                    isTruthy values
                  ]
            pure (Left (index, found, item) : map Right (fromQuery ++ inductionCases))
      let noValues = [(index, found, item) | Left (index, Just found, item) <- searched, str "outcome" found /= "sat", str "outcome" item == "sat"]
          evidence1 =
            [ case [found | (i, found, _) <- noValues, i == index] of
                found : _ -> setMember "reason" (JString (str "reason" item ++ "; the counterexample query gave no values (" ++ shown "outcome" found ++ ")")) item
                [] -> item
            | (index, item) <- zip [0 ..] evidence0
            ]
          candidates = [entry | Right entry <- searched]
      (evidence2, diagnostics1) <-
        if null candidates
          then pure (evidence1, items "diagnostics" result)
          else do
            checked <-
              call
                "proofTasks"
                ( setMember
                    "proofCounterexamples"
                    ( JArray
                        [ JObject
                            [ ("owner", fromMaybe JNull (member "owner" (evidence1 !! index))),
                              ("declaration", fromMaybe JNull (member "declaration" (evidence1 !! index))),
                              ("taskFingerprint", fromMaybe JNull (member "taskFingerprint" (tasks !! index))),
                              ("values", fromMaybe JNull (member "values" found))
                            ]
                        | (index, found, _) <- candidates
                        ]
                    )
                    request
                )
            let checks = items "counterexampleChecks" checked
            pure (foldl (applyCheck tasks) (evidence1, items "diagnostics" result) (zip candidates (map Just checks ++ repeat Nothing)))
      -- Induction rests on the laws it cites.
      let current0 = M.fromList [(str "declaration" row, str "status" row) | row <- items "evidence" result, str "stage" row == "law"]
          current1 =
            foldl
              ( \known item ->
                  if isJust (member "declaration" item) && isNothing (member "kind" item)
                    then
                      let previous = M.lookup (str "declaration" item) known
                       in M.insert (str "declaration" item) (if str "status" item == "proved" then "proved" else if previous `elem` [Just "proved", Just "exhaustively-checked"] then fromMaybe "" previous else str "status" item) known
                    else known
              )
              current0
              evidence2
          settle (rows, known) =
            let step (done, known', changed) item =
                  let cited = map jsString (maybe [] (items "using") (member "currentInduction" item `orElse` member "induction" item))
                      open = [law | law <- cited, M.lookup law known' `notElem` [Just "proved", Just "exhaustively-checked"]]
                   in if str "status" item /= "proved" || null cited || null open
                        then (done ++ [item], known', changed)
                        else
                          ( done ++ [with item [("status", JString "incomplete"), ("reason", JString (str "reason" item ++ "; it cites " ++ intercalate ", " [lastPart "::law::" law ++ ", which is " ++ fromMaybe "not proved" (M.lookup law known') | law <- open]))]],
                            M.insert (str "declaration" item) "incomplete" known',
                            True
                          )
                (rows', known'', changed') = foldl step ([], known, False) rows
             in if changed' then settle (rows', known'') else rows'
          evidence3 = settle (evidence2, current1)
      let (evidenceRows, diagnostics2) = foldl settleEvidence ([], diagnostics1) (items "evidence" result)
          settleEvidence (rows, found) row =
            case find (\item -> member "owner" item == member "owner" row && member "declaration" item == member "declaration" row) evidence3 of
              Just found'
                | str "stage" row == "law" ->
                    if str "status" found' /= "proved"
                      then
                        if str "status" row `elem` ["proved", "exhaustively-checked", "known-discrepancy", "skipped", "flaky"]
                          then (rows ++ [row], found)
                          else (rows ++ [with row [("status", JString (case str "status" found' of "unsupported" -> "unsupported"; "refuted" -> "refuted"; _ -> "incomplete")), ("reason", fromMaybe JNull (member "reason" found'))]], found)
                      else
                        if str "status" row == "known-discrepancy"
                          then (rows ++ [row], found ++ [JObject [("code", JString "harness"), ("message", JString ("Z3 proved " ++ shown "declaration" row ++ "; its harness cannot mark it as a known discrepancy")), ("at", fromMaybe JNull (member "at" found'))]])
                          else (rows ++ [with row [("status", JString "proved"), ("reason", JString (shown "reason" found' ++ "; task " ++ shown "taskFingerprint" found'))]], found)
              _ -> (rows ++ [row], found)
      (settled, found, solverEvidence) <-
        lawSets context' selected cache request analysis evidenceRows diagnostics2 evidence3
      (settled', found', solverEvidence') <- models context' selected cache request modelTasks settled found solverEvidence
      pure (with result [("diagnostics", JArray found'), ("evidence", JArray settled'), ("solverEvidence", JArray solverEvidence')])
  where
    orElse (Just value) _ = Just value
    orElse Nothing other = other

-- | The core build that names the receipt cache's identity.
buildDigestOf :: Invocation -> String
buildDigestOf invocation = fromMaybe "native" (invocationBuild invocation)

-- | One counterexample check from the compiler, applied to its law.
applyCheck :: [Json] -> ([Json], [Json]) -> ((Int, Json, Maybe String), Maybe Json) -> ([Json], [Json])
applyCheck tasks (evidence, found) ((index, values, inductionCase), check') = case check' of
  Nothing -> (evidence, found)
  Just check
    | member "owner" check /= member "owner" item || member "declaration" check /= member "declaration" item || str "status" item == "refuted" -> (evidence, found)
    | otherwise ->
        let counterexample =
              JObject
                [ ("inputs", fromMaybe (JArray []) (member "inputs" check)),
                  ("values", fromMaybe JNull (member "values" values)),
                  ("fingerprint", fromMaybe JNull (member "fingerprint" values)),
                  ("runFingerprint", fromMaybe JNull (member "runFingerprint" values)),
                  ("check", fromMaybe JNull (member "status" check))
                ]
            status = str "status" check
            reason = shown "reason" check
            shownInputs = intercalate ", " [shown "name" input ++ " = " ++ shown "value" input | input <- items "inputs" check]
            replace row = (take index evidence ++ [row] ++ drop (index + 1) evidence, found)
         in case () of
              _
                | status == "refuted" ->
                    replace
                      ( with
                          item
                          [ ("status", JString "refuted"),
                            ("modelValidated", JBool True),
                            ("counterexample", counterexample),
                            ( "reason",
                              JString
                                ( (if maybe False isTruthy (member "runFingerprint" values) then "Z3 found " else "the law has no inputs; ")
                                    ++ (if null shownInputs then "that the law fails" else "the input " ++ shownInputs)
                                    ++ maybe "" (\c -> " in case " ++ c ++ " of the induction") inductionCase
                                    ++ "; the reference evaluator confirms it: "
                                    ++ reason
                                )
                            )
                          ]
                      )
                | isJust inductionCase && status == "model-not-confirmed" ->
                    replace (with item [("counterexample", counterexample), ("reason", JString (str "reason" item ++ "; in case " ++ fromMaybe "" inductionCase ++ " the induction hypothesis is too weak: the law holds at Z3's input, " ++ reason))])
                | status == "model-not-confirmed" && (maybe False isTruthy (member "recursion" item) || maybe False isTruthy (member "recursion" (tasks !! index))) ->
                    replace (with item [("counterexample", counterexample), ("reason", JString (str "reason" item ++ "; Z3 gave a model the reference evaluator does not confirm, after unfolding that may have stopped early: " ++ reason))])
                | status == "model-not-confirmed" ->
                    let (rows, _) = replace (with item [("counterexample", counterexample), ("reason", JString ("Z3 gave a model the reference evaluator does not confirm: " ++ reason))])
                     in (rows, found ++ [JObject [("code", JString "proof-translation"), ("message", JString ("Z3's model for " ++ shown "declaration" item ++ " is not a counterexample: " ++ reason)), ("at", fromMaybe JNull (member "at" item))]])
                | str "outcome" item == "sat" -> replace (with item [("counterexample", counterexample), ("reason", JString (str "reason" item ++ "; " ++ reason))])
                | otherwise -> (evidence, found)
  where
    item = evidence !! index

-- | The law-set checks the compiler left undecided: Z3 runs each query and
-- the compiler settles every answer.
lawSets :: (Monad m) => Context -> Selected -> Maybe Cache -> Json -> [Json] -> [Json] -> [Json] -> [Json] -> Command m ([Json], [Json], [Json])
lawSets context selected cache request analysis evidence diagnostics' solverEvidence
  | null analysis = pure (evidence, diagnostics', solverEvidence)
  | otherwise = do
      let config = configJson (contextConfig context)
      (unsupportedRows, ran0, answers0) <-
        foldM
          ( \(rows, ran, answers) row ->
              if str "status" row /= "ready"
                then
                  pure
                    ( rows ++ [JObject [("owner", fromMaybe JNull (member "owner" row)), ("declaration", fromMaybe JNull (member "declaration" row)), ("stage", fromMaybe JNull (member "stage" row)), ("kind", JString "analysis"), ("encoding", JString "lawspec-smtlib-v2"), ("status", JString "unsupported"), ("outcome", JString "unsupported"), ("reason", fromMaybe JNull (member "reason" row)), ("configuration", config)]],
                      ran,
                      answers
                    )
                else
                  foldM
                    ( \(rows', ran', answers') task -> case selected of
                        Left (message, outcome) ->
                          pure (rows', ran' ++ [(str "fingerprint" task, (row, emptyQuery {queryOutcome = outcome, queryError = Just message}))], answers')
                        Right prover -> do
                          let inputs = map jsString (items "inputs" task)
                              finish token = if token == "sat" && not (null inputs) then "(get-value (" ++ unwords inputs ++ "))\n(exit)\n" else "(exit)\n"
                          done <- analysisQuery cache prover row task False (analysisRun prover task finish)
                          pure
                            ( rows',
                              replaceRan (str "fingerprint" task) (row, done) ran',
                              answers' ++ [JObject [("fingerprint", fromMaybe JNull (member "fingerprint" task)), ("outcome", JString (queryOutcome done)), ("values", JString (queryValues done)), ("inputs", fromMaybe JNull (queryInputs done))]]
                            )
                    )
                    (rows, ran, answers)
                    (items "tasks" row)
          )
          ([], [], [])
          analysis
      checked0 <- if null answers0 then pure (JObject []) else call "proofTasks" (setMember "analysisResults" (JArray answers0) request)
      -- A reused SAT model that no longer decodes runs once more.
      (ran1, retried) <-
        foldM
          ( \(ran, retried) verdict -> case lookup (str "fingerprint" verdict) ran of
              Just (row, done)
                | str "status" verdict == "incomplete",
                  isJust (queryReused done),
                  Right prover <- selected -> do
                    forM_ (queryCacheFile done) (\file -> effectOr (Remove NotRecursive file))
                    let task = head' [t | t <- items "tasks" row, str "fingerprint" t == str "fingerprint" verdict]
                        inputs = map jsString (items "inputs" task)
                        finish token = if token == "sat" && not (null inputs) then "(get-value (" ++ unwords inputs ++ "))\n(exit)\n" else "(exit)\n"
                    again <- analysisQuery cache prover row task True (analysisRun prover task finish)
                    pure (replaceRan (str "fingerprint" verdict) (row, again) ran, True)
              _ -> pure (ran, retried)
          )
          (ran0, False)
          (items "analysisChecks" checked0)
      checked <-
        if retried
          then
            call
              "proofTasks"
              ( setMember
                  "analysisResults"
                  (JArray [maybe answer (\(_, done) -> with answer [("outcome", JString (queryOutcome done)), ("values", JString (queryValues done)), ("inputs", fromMaybe JNull (queryInputs done))]) (lookup (str "fingerprint" answer) ran1) | answer <- answers0])
                  request
              )
          else pure checked0
      let rows = M.fromList [((str "declaration" row, str "stage" row), row) | row <- items "analysisEvidence" checked]
          settled = [M.findWithDefault row (str "declaration" row, str "stage" row) rows | row <- evidence]
          found = diagnostics' ++ [row | row <- items "diagnostics" checked, str "code" row == "refuted"]
          verdicts = items "analysisChecks" checked
      verdictRows <- forM verdicts $ \verdict -> do
        let done = maybe emptyQuery snd (lookup (str "fingerprint" verdict) ran1)
        when (str "status" verdict `elem` ["proved", "refuted", "exempted"]) (saveQuery done)
        pure $
          jsObject
            ( [ ("owner", fromMaybe JNull (member "owner" verdict)),
                ("declaration", fromMaybe JNull (member "declaration" verdict)),
                ("stage", fromMaybe JNull (member "stage" verdict)),
                ("kind", JString "analysis"),
                ("encoding", JString "lawspec-smtlib-v2"),
                ("taskFingerprint", fromMaybe (fromMaybe JNull (member "fingerprint" verdict)) (queryReused done >>= member "taskFingerprint")),
                ("status", fromMaybe JNull (member "status" verdict))
              ]
                ++ concat [[("currentTaskFingerprint", fromMaybe JNull (member "fingerprint" verdict)), ("reused", reused)] | Just reused <- [queryReused done]]
                ++ [ ("outcome", JString (if null (queryOutcome done) then "failed" else queryOutcome done)),
                     ("reason", JString (shown "reason" verdict ++ (if isJust (queryReused done) then "; reused a completed query; model revalidated by the current evaluator" else ""))),
                     ("check", fromMaybe JNull (member "check" verdict)),
                     ("configuration", config)
                   ]
                ++ case (queryRun done, selected) of
                  (Just run, Right prover) ->
                    [ ("prover", proverJson prover),
                      ("runFingerprint", maybe JNull JString (queryRunFingerprint done)),
                      ("elapsedMs", elapsedJson run),
                      ("exitCode", exitCodeJson run),
                      ("stdout", JString (executionStdout run)),
                      ("stderr", JString (executionStderr run))
                    ]
                  _ -> []
            )
      let failedRows =
            [ JObject [("kind", JString "analysis"), ("owner", fromMaybe JNull (member "owner" row)), ("declaration", fromMaybe JNull (member "declaration" row)), ("stage", fromMaybe JNull (member "stage" row)), ("taskFingerprint", JString fingerprint'), ("encoding", JString "lawspec-smtlib-v2"), ("status", JString "incomplete"), ("outcome", JString (queryOutcome done)), ("reason", JString message), ("configuration", config)]
            | (fingerprint', (row, done)) <- ran1,
              Just message <- [queryError done],
              not (any (\verdict -> str "fingerprint" verdict == fingerprint') verdicts)
            ]
      pure (settled, found, solverEvidence ++ unsupportedRows ++ verdictRows ++ failedRows)
  where
    analysisRun prover task finish = runQuery context prover task finish False
    head' list = case list of
      first : _ -> first
      [] -> JNull

emptyQuery :: Query
emptyQuery = Query "" "" "" Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Map.set on an insertion-ordered list: an existing key keeps its place.
replaceRan :: String -> a -> [(String, a)] -> [(String, a)]
replaceRan key value list
  | any ((== key) . fst) list = [(k, if k == key then value else v) | (k, v) <- list]
  | otherwise = list ++ [(key, value)]

-- | Model laws the compiler's own search left open, in rounds while the
-- compiler asks for new tasks.
models :: (Monad m) => Context -> Selected -> Maybe Cache -> Json -> [Json] -> [Json] -> [Json] -> [Json] -> Command m ([Json], [Json], [Json])
models context selected cache request modelTasks settled found solverEvidence
  | null modelTasks = pure (settled, found, solverEvidence)
  | Left (message, outcome) <- selected =
      pure
        ( settled,
          found,
          solverEvidence
            ++ [ JObject [("kind", JString "model"), ("owner", fromMaybe JNull (member "owner" law)), ("declaration", fromMaybe JNull (member "declaration" law)), ("task", fromMaybe JNull (member "kind" task)), ("taskFingerprint", fromMaybe JNull (member "fingerprint" task)), ("encoding", JString "lawspec-smtlib-v2"), ("status", JString "incomplete"), ("outcome", JString outcome), ("reason", JString message), ("configuration", configJson (contextConfig context))]
               | law <- modelTasks,
                 task <- items "tasks" law
               ]
        )
  | Right prover <- selected = do
      let finishFor task token
            | token /= "sat" = "(exit)\n"
            | str "kind" task == "spacer" = "(get-model)\n(exit)\n"
            | not (null (items "inputs" task)) = "(get-value (" ++ unwords (map jsString (items "inputs" task)) ++ "))\n(exit)\n"
            | otherwise = "(exit)\n"
          answerOf task done = JObject [("fingerprint", fromMaybe JNull (member "fingerprint" task)), ("outcome", JString (queryOutcome done)), ("values", JString (queryValues done)), ("invariant", JString (queryInvariant done)), ("inputs", fromMaybe (fromMaybe JNull (member "inputs" task)) (queryInputs done))]
          round' (pending, answered, answers, runs, modelRows, found') number
            | number >= (4 :: Int) = pure (pending, answered, answers, runs, modelRows, found', True)
            | otherwise = do
                (answered', answers', runs', fresh) <-
                  foldM
                    ( \(answered1, answers1, runs1, fresh1) (law, task) ->
                        if str "fingerprint" task `elem` answered1
                          then pure (answered1, answers1, runs1, fresh1)
                          else do
                            let row = JObject [("kind", JString "model"), ("owner", fromMaybe JNull (member "owner" law)), ("declaration", fromMaybe JNull (member "declaration" law)), ("stage", fromMaybe JNull (member "kind" task))]
                            done <- analysisQuery cache prover row task False (runQuery context prover task (finishFor task) (str "kind" task == "spacer"))
                            pure (answered1 ++ [str "fingerprint" task], answers1 ++ [answerOf task done], replaceRan (str "fingerprint" task) (row, task, done) runs1, fresh1 + (1 :: Int))
                    )
                    (answered, answers, runs, 0)
                    [(law, task) | law <- pending, task <- items "tasks" law]
                if fresh == 0
                  then pure (pending, answered', answers', runs', modelRows, found', True)
                  else do
                    checked0 <- call "proofTasks" (setMember "modelResults" (JArray answers') request)
                    (runs'', answers'', retry) <-
                      foldM
                        ( \(runs1, answers1, retry1) check -> case lookup (str "fingerprint" check) runs1 of
                            Just (row, task, done)
                              | str "status" check == "model-not-confirmed",
                                isJust (queryReused done) -> do
                                  forM_ (queryCacheFile done) (\file -> effectOr (Remove NotRecursive file))
                                  again <- analysisQuery cache prover row task True (runQuery context prover task (finishFor task) (str "kind" task == "spacer"))
                                  let answer = answerOf task again
                                  pure (replaceRan (str "fingerprint" task) (row, task, again) runs1, [if member "fingerprint" a == member "fingerprint" task then answer else a | a <- answers1], True)
                            _ -> pure (runs1, answers1, retry1)
                        )
                        (runs', answers', False)
                        (items "modelChecks" checked0)
                    checked <- if retry then call "proofTasks" (setMember "modelResults" (JArray answers'') request) else pure checked0
                    let modelRows' = foldl (\rows row -> replaceRan (str "declaration" row) row rows) modelRows (items "modelEvidence" checked)
                        found'' = foldl (\kept d -> if str "code" d == "refuted" && not (any (\e -> member "message" e == member "message" d) kept) then kept ++ [d] else kept) found' (items "diagnostics" checked)
                    round' (items "modelTasks" checked, answered', answers'', runs'', modelRows', found'') (number + 1)
      (_, _, _, runs, modelRows, found', _) <- round' (modelTasks, [], [], [], [], found) 0
      rows <- forM runs $ \(_, (row, task, done)) -> do
        when (str "kind" task /= "bounded search" || queryOutcome done /= "sat" || (lookup (str "declaration" row) modelRows >>= strOf "status") == Just "refuted") (saveQuery done)
        let outcome = queryOutcome done
        pure $
          jsObject
            ( [ ("kind", JString "model"),
                ("owner", fromMaybe JNull (member "owner" row)),
                ("declaration", fromMaybe JNull (member "declaration" row)),
                ("task", fromMaybe JNull (member "kind" task)),
                ("taskFingerprint", fromMaybe (fromMaybe JNull (member "fingerprint" task)) (queryReused done >>= member "taskFingerprint"))
              ]
                ++ concat [[("currentTaskFingerprint", fromMaybe JNull (member "fingerprint" task)), ("reused", reused)] | Just reused <- [queryReused done]]
                ++ [ ("encoding", JString "lawspec-smtlib-v2"),
                     ("status", JString (if outcome == "unsat" then "proved" else "incomplete")),
                     ("outcome", JString outcome),
                     ("reason", JString (shown "kind" task ++ ": " ++ outcome ++ (if isJust (queryReused done) then "; reused original solver query; current compiler rechecks the model evidence" else ""))),
                     ("prover", proverJson prover),
                     ("runFingerprint", maybe JNull JString (queryRunFingerprint done))
                   ]
                ++ maybe
                  []
                  (\run -> [("elapsedMs", elapsedJson run), ("exitCode", exitCodeJson run), ("signal", signalJson run), ("stdout", JString (executionStdout run)), ("stderr", JString (executionStderr run))])
                  (queryRun done)
                ++ [("configuration", configJson (contextConfig context))]
            )
      let settled' = [if str "stage" row == "law" then maybe row (\found'' -> with row (members found'')) (lookup (str "declaration" row) modelRows) else row | row <- settled]
      pure (settled', found', solverEvidence ++ rows)

-- | lawspec prove, after main()'s checks: the result, as text or JSON, and
-- the exit code (1 for a refuted law, 2 for one neither proved nor
-- exempted).
proveCommand :: (Monad m) => Invocation -> Arguments -> Json -> Command m Int
proveCommand invocation arguments input = do
  config <- either failWith pure (proofConfig arguments)
  let json = flag "json" arguments
  result <- proveWithZ3 invocation config input >>= diagnostics json
  let rows = items "solverEvidence" result
      layers = maybe [] (items "layers") (member "verification" input)
  if json
    then printJson result
    else
      printLine $
        if not (null rows)
          then intercalate "\n" [shown "declaration" row ++ (if str "kind" row == "analysis" then " " ++ shown "stage" row else "") ++ ": " ++ shown "status" row ++ " (" ++ shown "outcome" row ++ "). " ++ shown "reason" row | row <- rows]
          else
            if JString "proof" `elem` layers
              then "No source law obligations are available. No solver was invoked."
              else "No proof layer selected. Intrinsic definition checks passed; no solver was invoked."
  pure $
    if any (\row -> str "status" row == "refuted") rows
      then 1
      else if any (\row -> str "status" row `notElem` ["proved", "exempted"]) rows then 2 else 0
