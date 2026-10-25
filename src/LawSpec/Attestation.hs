-- | An environment attestation: a versioned JSON document, written by any
-- tool, recording for one run in one environment which endpoint each
-- dependency was wired to and whether it was the real dependency or a
-- stand-in. lawspec evidence reads it to say which obligations were tested
-- against stand-ins. It is reporting only: it never changes what a law means
-- or whether it passes, and no status changes because of it.
-- ref:DEC-environment-attestation
--
-- A dependency is matched by name to what a law relies on: an ability, by its
-- resolved identity (unit::ability::Name, or unit::Name), whose production
-- handler the law runs under, or a native adapter or bound function
-- (unit::name) the law calls, directly or through the definitions it calls.
module LawSpec.Attestation
  ( Attestation(..), Dependency(..), StandIn(..), Completed(..), Execution(..), ExecutionStatus(..)
  , Architecture(..), Application(..), Contract(..), Implementation(..)
  , parseAttestation, attestedFields, attestationView, completable
  ) where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Types (Pair, Parser, parseEither)
import qualified Data.Aeson.Key as K
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core hiding (Contract)
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.Discharge (callees)

data Attestation = Attestation
  { attestationEnvironment :: String
  , attestationRun :: String
  , attestationStarted :: String
  , attestationRecorded :: String
  , attestationProducer :: Maybe (String, String)
  , attestationDependencies :: [Dependency]
  -- What the document records: wiring alone, a run under way or a completed
  -- run. Nothing when the writer does not say.
  , attestationExecution :: Maybe Execution
  -- The architecture the wiring was resolved from, and the application the
  -- run exercised, by identity.
  , attestationArchitecture :: Maybe Architecture
  , attestationApplication :: Maybe Application
  } deriving (Eq, Show)

data Dependency = Dependency
  { dependencyName :: String
  , dependencyEndpoint :: String
  , dependencyReached :: Bool
  -- Nothing for the real dependency.
  , dependencyStandIn :: Maybe StandIn
  -- The architecture node it is and the relationship it was reached through.
  , dependencyNode :: Maybe String
  , dependencyEdge :: Maybe String
  -- The contract its binding had to satisfy, and what implemented it.
  , dependencyContract :: Maybe Contract
  , dependencyImplementation :: Maybe Implementation
  -- What was observed when the run completed.
  , dependencyCompleted :: Maybe Completed
  } deriving (Eq, Show)

-- | What stood in: its identity and version, the conformance level its maker
-- declares (recorded, never judged), and optionally a digest of the history
-- it was recorded from and the contract it stands in for.
data StandIn = StandIn
  { standInIdentity :: String
  , standInVersion :: String
  , standInConformance :: String
  , standInHistory :: Maybe String
  , standInFor :: Maybe Contract
  } deriving (Eq, Show)

data Completed = Completed
  { completedReached :: Bool
  , completedHistory :: Maybe String
  , completedEntries :: Maybe Integer
  } deriving (Eq, Show)

data ExecutionStatus = Wired | Running | Finished deriving (Eq, Show)

data Execution = Execution
  { executionStatus :: ExecutionStatus
  -- Present exactly when the run completed.
  , executionExitCode :: Maybe Integer
  , executionFinished :: Maybe String
  } deriving (Eq, Show)

data Architecture = Architecture
  { architectureDocument :: String
  , architectureDigest :: String
  , architectureUniqueId :: Maybe String
  , architectureDecorators :: Maybe String
  , architectureDecoratorsDigest :: Maybe String
  , architectureTopologyDigest :: Maybe String
  , architectureElements :: [String]
  } deriving (Eq, Show)

data Contract = Contract
  { contractPackage :: String
  , contractVersion :: String
  , contractAbilities :: [String]
  , contractDigest :: Maybe String
  } deriving (Eq, Show)

-- | The real provider, a fixture, or the application itself.
data Implementation = Implementation
  { implementationKind :: String
  , implementationProduct :: String
  , implementationVersion :: String
  , implementationCommit :: Maybe String
  , implementationImage :: Maybe String
  } deriving (Eq, Show)

data Application = Application
  { applicationNode :: String
  , applicationContract :: Maybe Contract
  , applicationImplementation :: Implementation
  , applicationComponent :: Maybe Value
  } deriving (Eq, Show)

-- | Version 1 of the format. Unknown fields are ignored, so a writer may add
-- fields without changing the version; an unknown format or version is
-- rejected, as is a document that breaks the format's rules, including the
-- optional fields this reader knows.
parseAttestation :: Value -> Either String Attestation
parseAttestation = parseEither $ withObject "attestation" $ \o -> do
  format <- o .: "format"
  unless (format == ("environment-attestation" :: String))
    (fail ("format must be \"environment-attestation\", not " ++ show format))
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail ("version " ++ show version ++ " is not known; this reader knows version 1"))
  environment <- nonEmpty o "environment"
  (run, started, recorded) <- o .: "run" >>= withObject "run" (\r -> do
    run <- nonEmpty r "id"
    started <- time r "started_at"
    recorded <- time r "recorded_at"
    when (instant recorded < instant started) (fail "run.recorded_at is before run.started_at")
    pure (run, started, recorded))
  producer <- o .:? "producer" >>= traverse (withObject "producer" (\p -> (,) <$> p .: "name" <*> p .: "version"))
  dependencies <- o .: "dependencies" >>= mapM dependency
  execution <- o .:? "execution" >>= traverse (withObject "execution" (\e -> do
    status <- e .: "status"
    code <- e .:? "exit_code"
    finished <- e .:? "finished_at" >>= traverse (\t -> case instant t of
      Just _ -> pure t
      Nothing -> fail ("execution.finished_at must be an RFC 3339 time, not " ++ show t))
    when (maybe False ((< instant started) . instant) finished) (fail "execution.finished_at is before run.started_at")
    case (status :: String) of
      "completed" | isJust code -> pure (Execution Finished code finished)
                  | otherwise -> fail "a completed execution needs exit_code"
      _ | isJust code -> fail ("an execution that is " ++ status ++ " has no exit_code")
      "wired" -> pure (Execution Wired Nothing finished)
      "running" -> pure (Execution Running Nothing finished)
      _ -> fail ("execution.status " ++ show status ++ " is not wired, running or completed")))
  architecture <- o .:? "architecture" >>= traverse (withObject "architecture" (\a ->
    Architecture <$> nonEmpty a "document" <*> a .: "digest" <*> a .:? "unique_id" <*> a .:? "decorators"
      <*> a .:? "decorators_digest" <*> a .:? "topology_digest" <*> a .:? "elements" .!= []))
  application <- o .:? "application" >>= traverse (withObject "application" (\a -> do
    selected <- a .:? "contract" >>= traverse contract
    component <- a .:? "component"
    unless (isJust selected || isJust component) (fail "application needs contract or component")
    case component of
      Nothing -> pure ()
      Just value -> withObject "component" (\c -> do
        _ <- nonEmpty c "name"
        _ <- nonEmpty c "version"
        digest <- nonEmpty c "fingerprint"
        unless (length digest == 64 && all (`elem` ("0123456789abcdef" :: String)) digest)
          (fail "component fingerprint must be a SHA-256 digest")) value
    Application <$> nonEmpty a "node" <*> pure selected <*> (a .: "implementation" >>= implementation) <*> pure component))
  let named = map dependencyName dependencies
  case [n | (n, i) <- zip named [0 :: Int ..], n `elem` take i named] of
    n : _ -> fail ("dependency " ++ show n ++ " is named twice")
    [] -> pure (Attestation environment run started recorded producer dependencies execution architecture application)
  where
    nonEmpty :: Object -> String -> Parser String
    nonEmpty o key = do
      text <- o .: K.fromString key
      when (null text) (fail (key ++ " must not be empty"))
      pure text
    time o key = do
      text <- o .: K.fromString key
      case instant text of
        Just _ -> pure text
        Nothing -> fail (key ++ " must be an RFC 3339 time, not " ++ show text)
    dependency = withObject "dependency" $ \d -> do
      name <- nonEmpty d "name"
      endpoint <- nonEmpty d "endpoint"
      reached <- d .: "reached"
      kind <- d .: "kind"
      standIn <- d .:? "stand_in"
      node <- d .:? "node"
      edge <- d .:? "edge"
      bound <- d .:? "contract" >>= traverse contract
      implemented <- d .:? "implementation" >>= traverse implementation
      completed <- d .:? "completed" >>= traverse (withObject "completed" (\c ->
        Completed <$> c .: "reached" <*> c .:? "history_digest" <*> c .:? "history_entries"))
      -- A real dependency is not implemented by a fixture, nor a stand-in by
      -- the real provider.
      case (kind :: String, fmap implementationKind implemented) of
        ("real", Just "fixture") -> fail ("dependency " ++ show name ++ " is real, so a fixture does not implement it")
        ("stand-in", Just "real-provider") -> fail ("dependency " ++ show name ++ " is a stand-in, so the real provider does not implement it")
        _ -> pure ()
      let made s = Dependency name endpoint reached s node edge bound implemented completed
      case (kind, standIn) of
        ("real", Nothing) -> pure (made Nothing)
        ("real", Just _) -> fail ("dependency " ++ show name ++ " is real, so it has no stand_in")
        ("stand-in", Just s) -> made . Just <$> standInOf s
        ("stand-in", Nothing) -> fail ("dependency " ++ show name ++ " is a stand-in, so it needs stand_in")
        _ -> fail ("dependency " ++ show name ++ " has kind " ++ show kind ++ "; expected real or stand-in")
    standInOf = withObject "stand_in" $ \s ->
      StandIn <$> nonEmpty s "product" <*> nonEmpty s "version" <*> nonEmpty s "conformance" <*> s .:? "history_digest"
        <*> (s .:? "stands_in_for" >>= traverse contract)
    contract = withObject "contract" $ \c ->
      Contract <$> nonEmpty c "package" <*> nonEmpty c "version" <*> (c .:? "abilities" .!= []) <*> c .:? "digest"
    implementation = withObject "implementation" $ \i -> do
      kind <- i .: "kind"
      unless (kind `elem` ["real-provider", "fixture", "application"])
        (fail ("implementation.kind " ++ show kind ++ " is not real-provider, fixture or application"))
      Implementation kind <$> i .: "product" <*> i .: "version" <*> i .:? "commit" <*> i .:? "image_digest"

-- | An RFC 3339 time as UTC seconds (from a fixed epoch) and its fraction,
-- for ordering; Nothing when it is not one. ref:rfc3339
instant :: String -> Maybe (Integer, String)
instant text = do
  let (stamp, rest) = splitAt 19 text
  [y1,y2,y3,y4,'-',m1,m2,'-',d1,d2,t,h1,h2,':',n1,n2,':',s1,s2] <- Just stamp
  unless (t `elem` ("Tt " :: String) && all isDigit [y1,y2,y3,y4,m1,m2,d1,d2,h1,h2,n1,n2,s1,s2]) Nothing
  let number = read :: String -> Integer
      (year, month, day) = (number [y1,y2,y3,y4], number [m1,m2], number [d1,d2])
      (hour, minute, second) = (number [h1,h2], number [n1,n2], number [s1,s2])
  unless (month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour <= 23 && minute <= 59 && second <= 60) Nothing
  (fraction, zone) <- case rest of
    '.' : more -> case span isDigit more of
      ("", _) -> Nothing
      split -> Just split
    _ -> Just ("", rest)
  offset <- case zone of
    [z] | z `elem` ("Zz" :: String) -> Just 0
    [sign,a,b,':',c,d] | sign `elem` ("+-" :: String), all isDigit [a,b,c,d] ->
      Just ((if sign == '-' then negate else id) (number [a,b] * 3600 + number [c,d] * 60))
    _ -> Nothing
  let (y', m') = if month <= 2 then (year - 1, month + 9) else (year, month - 3)
      days = 365 * y' + y' `div` 4 - y' `div` 100 + y' `div` 400 + (153 * m' + 2) `div` 5 + day
  pure (days * 86400 + hour * 3600 + minute * 60 + second - offset, take 12 (fraction ++ replicate 12 '0'))

-- | The names a dependency may use for each identity a law relies on.
spellings :: String -> [String]
spellings text = nub [text, readable text]
  where
    -- unit::ability::Name(args) is also unit::Name(args).
    readable s = case s of
      ':' : ':' : rest | take 9 rest == "ability::" -> "::" ++ drop 9 rest
      c : rest -> c : readable rest
      [] -> []

-- | What each tested law relies on: the abilities whose production handler it
-- runs under (each by its identity and by its key with type arguments), and
-- the native functions it calls, directly or through definitions.
relied :: Program -> M.Map Id [String]
relied program = M.fromList
  [ (propertyId p, nub (abilities ++ natives))
  | u <- programUnits program, p <- unitProperties u
  , let abilities = concat [ concatMap spellings [idText (abilityRefId a), abilityKey a]
                           | (a, h) <- propertyHandlers p, not (isFail a), production h ]
        natives = concatMap (spellings . idText) (filter (`M.notMember` definitionTable)
          (S.toList (reach S.empty (concatMap callees (propertyExpressions p))))) ]
  where
    definitionTable = M.fromList [(declarationId (definitionDeclaration d), d) | u <- programUnits program, d <- unitDefinitions u]
    reach seen [] = seen
    reach seen (n : rest)
      | n `S.member` seen = reach seen rest
      | Just d <- M.lookup n definitionTable = reach (S.insert n seen) (callees (definitionBody d) ++ rest)
      | otherwise = reach (S.insert n seen) rest
    production h = case h of
      ProductionHandler -> True
      RecordingHandler inner -> production inner
      SpecHandler _ -> False
    abilityRefId (AbilityRef identity _) = identity

-- | The dependencies an obligation's evidence touched. Only an obligation
-- whose evidence comes from tests that ran is touched: a proof, a law the
-- harness skips and one taken on trust do not depend on the environment.
touched :: Attestation -> M.Map Id [String] -> Obligation -> [(Dependency, [String])]
touched attestation reliance o
  | obligationStage o /= "law" = []
  | obligationStatus o `notElem` [ExhaustivelyChecked, PropertyTested, Measured, KnownDiscrepancy] = []
  | otherwise =
      [ (d, matched) | d <- attestationDependencies attestation
      , let matched = filter (== dependencyName d) names, not (null matched) ]
  where names = M.findWithDefault [] (obligationDeclaration o) reliance

-- | Dependencies a planned native check would reach. This is a plan, never
-- evidence that the named environment ran a test.
plannedTouches :: Attestation -> M.Map Id [String] -> Obligation -> [Dependency]
plannedTouches attestation reliance o
  | obligationStage o /= "law" || obligationStatus o /= Planned = []
  | otherwise = [d | d <- attestationDependencies attestation,
      dependencyName d `elem` M.findWithDefault [] (obligationDeclaration o) reliance]

-- | Whether the document may record a completed run: it says the run
-- completed, or it does not say. Wiring alone, or a run under way, is never
-- linked to a result.
completable :: Attestation -> Bool
completable = maybe True ((== Finished) . executionStatus) . attestationExecution

-- | The recorded outcome of a planned native check in this attestation's run:
-- the host passes, for each law, the outcome lawspec test recorded under this
-- run's id, and a document that may record a completed run links it.
linked :: Attestation -> M.Map String String -> Obligation -> Maybe String
linked attestation outcomes o
  | completable attestation = M.lookup (idText (obligationDeclaration o)) outcomes
  | otherwise = Nothing

-- | The dependencies an obligation's evidence touched, and those it would
-- touch but no completed run of this attestation links.
reaches :: Attestation -> M.Map String String -> M.Map Id [String] -> Obligation -> ([Dependency], [Dependency], Maybe String)
reaches attestation outcomes reliance o = case map fst (touched attestation reliance o) of
  [] -> case (plannedTouches attestation reliance o, linked attestation outcomes o) of
    (ds@(_ : _), Just outcome) -> (ds, [], Just outcome)
    (ds, _) -> ([], ds, Nothing)
  ds -> (ds, [], Nothing)

-- | The fields an attestation adds to each obligation of the API's evidence
-- list, in the same order; empty for an obligation it does not touch.
attestedFields :: Attestation -> M.Map String String -> Program -> [Obligation] -> [[Pair]]
attestedFields attestation outcomes program obligations = map fields obligations
  where
    reliance = relied program
    fields o = case reaches attestation outcomes reliance o of
      ([], [], _) -> []
      ([], ds, _) -> [ "plannedEnvironment" .= attestationEnvironment attestation
                     , "plannedEnvironmentRun" .= runView attestation
                     , "plannedAgainst" .= map dependencyView ds
                     , "plannedEnvironmentProviders" .= providers ds ]
      (ds, _, outcome) -> [ "environment" .= attestationEnvironment attestation
                          , "environmentRun" .= runView attestation
                          , "against" .= map dependencyView ds
                          , "environmentProviders" .= providers ds ] ++
                          [ "environmentOutcome" .= result | Just result <- [outcome] ]
    providers = sort . nub . map provider

runView :: Attestation -> Value
runView a = object (["id" .= attestationRun a, "startedAt" .= attestationStarted a, "recordedAt" .= attestationRecorded a] ++
  [ "execution" .= object (
      [ "status" .= (case executionStatus e of Wired -> "wired"; Running -> "running"; Finished -> "completed" :: String) ] ++
      [ "exitCode" .= c | Just c <- [executionExitCode e] ] ++
      [ "finishedAt" .= f | Just f <- [executionFinished e] ])
  | Just e <- [attestationExecution a] ])

-- | Whether the real provider or a fixture implemented a dependency: as its
-- implementation says, or else by its kind.
provider :: Dependency -> String
provider d = maybe (maybe "real-provider" (const "fixture") (dependencyStandIn d)) implementationKind (dependencyImplementation d)

-- | The history a stand-in served when the run completed, or else the one it
-- was recorded from when the run began.
history :: Dependency -> Maybe (String, String)
history d = case (dependencyCompleted d >>= completedHistory, dependencyStandIn d >>= standInHistory) of
  (Just h, _) -> Just (h, "completed")
  (_, Just h) -> Just (h, "stand-in")
  _ -> Nothing

dependencyView :: Dependency -> Value
dependencyView = object . dependencyPairs

dependencyPairs :: Dependency -> [Pair]
dependencyPairs d =
  [ "dependency" .= dependencyName d, "endpoint" .= dependencyEndpoint d, "reached" .= dependencyReached d
  , "kind" .= (maybe "real" (const "stand-in") (dependencyStandIn d) :: String)
  , "provider" .= provider d ] ++
  [ "standIn" .= object (
      [ "identity" .= standInIdentity s, "version" .= standInVersion s, "conformance" .= standInConformance s ] ++
      [ "historyDigest" .= h | Just h <- [standInHistory s] ] ++
      [ "standsInFor" .= contractView c | Just c <- [standInFor s] ])
  | Just s <- [dependencyStandIn d] ] ++
  [ "node" .= n | Just n <- [dependencyNode d] ] ++
  [ "edge" .= e | Just e <- [dependencyEdge d] ] ++
  [ "contract" .= contractView c | Just c <- [dependencyContract d] ] ++
  [ "implementation" .= implementationView i | Just i <- [dependencyImplementation d] ] ++
  [ "completed" .= object (["reached" .= completedReached c] ++
      [ "historyDigest" .= h | Just h <- [completedHistory c] ] ++
      [ "historyEntries" .= n | Just n <- [completedEntries c] ])
  | Just c <- [dependencyCompleted d] ] ++
  -- The identity of what the law ran against.
  [ "ranAgainst" .= object (
      [ "provider" .= provider d ] ++
      (case (dependencyImplementation d, dependencyStandIn d) of
        (Just i, _) -> [ "product" .= implementationProduct i, "version" .= implementationVersion i ]
        (_, Just s) -> [ "product" .= standInIdentity s, "version" .= standInVersion s ]
        _ -> []) ++
      concat [ [ "historyDigest" .= h, "historyFrom" .= from ] | Just (h, from) <- [history d] ]) ]

contractView :: Contract -> Value
contractView c = object (["package" .= contractPackage c, "version" .= contractVersion c] ++
  [ "abilities" .= contractAbilities c | not (null (contractAbilities c)) ] ++
  [ "digest" .= digest | Just digest <- [contractDigest c] ])

implementationView :: Implementation -> Value
implementationView i = object (
  [ "kind" .= implementationKind i, "product" .= implementationProduct i, "version" .= implementationVersion i ] ++
  [ "commit" .= c | Just c <- [implementationCommit i] ] ++
  [ "imageDigest" .= g | Just g <- [implementationImage i] ])

-- | The attestation as the API reports it: the environment and run, the
-- architecture and application by identity, and for each dependency the
-- obligations it touched in a completed run and those only planned against
-- it (none, when its name matches nothing the laws rely on).
attestationView :: Attestation -> M.Map String String -> Program -> [Obligation] -> Value
attestationView attestation outcomes program obligations = object (
  [ "environment" .= attestationEnvironment attestation, "run" .= runView attestation ] ++
  [ "producer" .= object ["name" .= n, "version" .= v] | Just (n, v) <- [attestationProducer attestation] ] ++
  [ "architecture" .= object (
      [ "document" .= architectureDocument a, "digest" .= architectureDigest a ] ++
      [ "uniqueId" .= u | Just u <- [architectureUniqueId a] ] ++
      [ "decorators" .= u | Just u <- [architectureDecorators a] ] ++
      [ "decoratorsDigest" .= u | Just u <- [architectureDecoratorsDigest a] ] ++
      [ "topologyDigest" .= u | Just u <- [architectureTopologyDigest a] ] ++
      [ "elements" .= architectureElements a | not (null (architectureElements a)) ])
  | Just a <- [attestationArchitecture attestation] ] ++
  [ "application" .= object ([ "node" .= applicationNode a
                            , "implementation" .= implementationView (applicationImplementation a) ] ++
                            ["contract" .= contractView c | Just c <- [applicationContract a]] ++
                            ["component" .= c | Just c <- [applicationComponent a]])
  | Just a <- [attestationApplication attestation] ] ++
  [ "dependencies" .=
      [ object (dependencyPairs d ++
          [ "obligations" .= [ idText (obligationDeclaration o) | (o, (ds, _, _)) <- reach, d `elem` ds ]
          , "plannedObligations" .= [ idText (obligationDeclaration o) | (o, (_, ds, _)) <- reach, d `elem` ds ] ])
      | d <- attestationDependencies attestation ] ])
  where
    reliance = relied program
    reach = [ (o, reaches attestation outcomes reliance o) | o <- obligations ]
