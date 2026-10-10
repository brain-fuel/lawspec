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
  ( Attestation(..), Dependency(..), StandIn(..)
  , parseAttestation, attestedFields, attestationView
  ) where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Types (Pair, Parser, parseEither)
import qualified Data.Aeson.Key as K
import Data.Char (isDigit)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.Discharge (callees)

data Attestation = Attestation
  { attestationEnvironment :: String
  , attestationRun :: String
  , attestationStarted :: String
  , attestationRecorded :: String
  , attestationProducer :: Maybe (String, String)
  , attestationDependencies :: [Dependency]
  } deriving (Eq, Show)

data Dependency = Dependency
  { dependencyName :: String
  , dependencyEndpoint :: String
  , dependencyReached :: Bool
  -- Nothing for the real dependency.
  , dependencyStandIn :: Maybe StandIn
  } deriving (Eq, Show)

-- | What stood in: its identity and version, the conformance level its maker
-- declares (recorded, never judged), and optionally a digest of the history
-- it was recorded from.
data StandIn = StandIn
  { standInIdentity :: String
  , standInVersion :: String
  , standInConformance :: String
  , standInHistory :: Maybe String
  } deriving (Eq, Show)

-- | Version 1 of the format. Unknown fields are ignored, so a writer may add
-- fields without changing the version; an unknown format or version is
-- rejected, as is a document that breaks the format's rules.
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
  let named = map dependencyName dependencies
  case [n | (n, i) <- zip named [0 :: Int ..], n `elem` take i named] of
    n : _ -> fail ("dependency " ++ show n ++ " is named twice")
    [] -> pure (Attestation environment run started recorded producer dependencies)
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
      case (kind :: String, standIn) of
        ("real", Nothing) -> pure (Dependency name endpoint reached Nothing)
        ("real", Just _) -> fail ("dependency " ++ show name ++ " is real, so it has no stand_in")
        ("stand-in", Just s) -> Dependency name endpoint reached . Just <$> standInOf s
        ("stand-in", Nothing) -> fail ("dependency " ++ show name ++ " is a stand-in, so it needs stand_in")
        _ -> fail ("dependency " ++ show name ++ " has kind " ++ show kind ++ "; expected real or stand-in")
    standInOf = withObject "stand_in" $ \s ->
      StandIn <$> nonEmpty s "product" <*> nonEmpty s "version" <*> nonEmpty s "conformance" <*> s .:? "history_digest"

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
  | obligationStatus o `notElem` [ExhaustivelyChecked, PropertyTested, Measured, KnownFailing] = []
  | otherwise =
      [ (d, matched) | d <- attestationDependencies attestation
      , let matched = filter (== dependencyName d) names, not (null matched) ]
  where names = M.findWithDefault [] (obligationDeclaration o) reliance

-- | The fields an attestation adds to each obligation of the API's evidence
-- list, in the same order; empty for an obligation it does not touch.
attestedFields :: Attestation -> Program -> [Obligation] -> [[Pair]]
attestedFields attestation program obligations = map fields obligations
  where
    reliance = relied program
    fields o = case touched attestation reliance o of
      [] -> []
      ds -> [ "environment" .= attestationEnvironment attestation
            , "environmentRun" .= runView attestation
            , "against" .= map (dependencyView . fst) ds ]

runView :: Attestation -> Value
runView a = object ["id" .= attestationRun a, "startedAt" .= attestationStarted a, "recordedAt" .= attestationRecorded a]

dependencyView :: Dependency -> Value
dependencyView = object . dependencyPairs

dependencyPairs :: Dependency -> [Pair]
dependencyPairs d =
  [ "dependency" .= dependencyName d, "endpoint" .= dependencyEndpoint d, "reached" .= dependencyReached d
  , "kind" .= (maybe "real" (const "stand-in") (dependencyStandIn d) :: String) ] ++
  [ "standIn" .= object (
      [ "identity" .= standInIdentity s, "version" .= standInVersion s, "conformance" .= standInConformance s ] ++
      [ "historyDigest" .= h | Just h <- [standInHistory s] ])
  | Just s <- [dependencyStandIn d] ]

-- | The attestation as the API reports it: the environment and run, and for
-- each dependency the obligations it touched (none, when its name matches
-- nothing the laws rely on).
attestationView :: Attestation -> Program -> [Obligation] -> Value
attestationView attestation program obligations = object (
  [ "environment" .= attestationEnvironment attestation, "run" .= runView attestation ] ++
  [ "producer" .= object ["name" .= n, "version" .= v] | Just (n, v) <- [attestationProducer attestation] ] ++
  [ "dependencies" .=
      [ object (dependencyPairs d ++
          [ "obligations" .= [ idText (obligationDeclaration o)
                             | o <- obligations, d `elem` map fst (touched attestation reliance o) ] ])
      | d <- attestationDependencies attestation ] ])
  where reliance = relied program
