-- | Which runtime a JVM target's generated actors and supervisors run on,
-- chosen per target in lawspec.edn (`:actors {:runtime :pekko}`). The spec
-- stays runtime-neutral: the choice changes generated code and build
-- scaffolds, never what is checked. ref:DEC-pekko-runtime
module LawSpec.ActorRuntime
  ( ActorRuntime (..)
  , ActorRemote (..)
  , ActorSettings (..)
  , defaultActorSettings
  , actorSettings
  , actorFields
  , actorRuntimeName
  ) where

import Data.Aeson (Value (..))
import Data.Binary (Binary)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as M
import qualified Data.Text as T
import GHC.Generics (Generic)
import LawSpec.Targets (jvmTargets, targetLabel)

-- | LawSpec's own runtime (the default), Apache Pekko Typed, or Pekko through
-- the Spring Boot actor starter.
data ActorRuntime = LawSpecActors | PekkoActors | SpringActors
  deriving (Eq, Show, Generic)

-- | How serve and connect reach other nodes: LawSpec's network layer, or Pekko
-- Cluster (only on the Pekko and Spring runtimes). ref:DEC-pekko-cluster-remote
data ActorRemote = LawSpecRemote | ClusterRemote
  deriving (Eq, Show, Generic)

data ActorSettings = ActorSettings
  { actorRuntime :: ActorRuntime
  , actorRemote :: ActorRemote
  }
  deriving (Eq, Show, Generic)

instance Binary ActorRuntime

instance Binary ActorRemote

instance Binary ActorSettings

defaultActorSettings :: ActorSettings
defaultActorSettings = ActorSettings LawSpecActors LawSpecRemote

-- | The name used in lawspec.edn and in messages.
actorRuntimeName :: ActorRuntime -> String
actorRuntimeName runtime = case runtime of
  LawSpecActors -> "lawspec"
  PekkoActors -> "pekko"
  SpringActors -> "spring"

-- | A target's `actors` settings, or the problems with them. at names the
-- field in messages; target is the target's language, when known.
actorSettings :: String -> Maybe String -> Maybe Value -> Either [String] ActorSettings
actorSettings _ _ Nothing = Right defaultActorSettings
actorSettings _ _ (Just Null) = Right defaultActorSettings
actorSettings at target (Just (Object fields)) =
  actorFields at target (map K.toString (M.keys fields)) (look "runtime") (look "remote")
  where
    look key = fmap (\case String text -> Just (T.unpack text); _ -> Nothing) (M.lookup key fields)
actorSettings at _ (Just _) = Left [at ++ " must be a map, such as {:runtime :pekko}"]

-- | The checks behind actorSettings, over the field names and the runtime and
-- remote fields: Nothing when absent, Just Nothing when not a keyword.
actorFields :: String -> Maybe String -> [String] -> Maybe (Maybe String) -> Maybe (Maybe String) -> Either [String] ActorSettings
actorFields at target keys runtimeField remoteField =
  case unknown ++ runtimeProblems ++ remoteProblems ++ placement of
    [] -> Right (ActorSettings runtime remote)
    problems -> Left problems
  where
    unknown = [at ++ ": unknown field " ++ key | key <- keys, key `notElem` ["runtime", "remote"]]
    (runtime, runtimeProblems) = case runtimeField of
      Nothing -> (LawSpecActors, [])
      Just (Just "lawspec") -> (LawSpecActors, [])
      Just (Just "pekko") -> (PekkoActors, [])
      Just (Just "spring") -> (SpringActors, [])
      Just _ -> (LawSpecActors, [at ++ ".runtime must be :lawspec, :pekko or :spring"])
    (remote, remoteProblems) = case remoteField of
      Nothing -> (LawSpecRemote, [])
      Just (Just "cluster") -> (ClusterRemote, [])
      Just _ -> (LawSpecRemote, [at ++ ".remote must be :cluster"])
    placement =
      [ at ++ ".runtime :" ++ actorRuntimeName runtime ++ " runs on the JVM, so it is only for Java, Kotlin, Scala, Groovy and Clojure, not " ++ targetLabel t
      | runtime /= LawSpecActors, Just t <- [target], t `notElem` jvmTargets ]
        ++ [ at ++ ".remote :cluster is Pekko Cluster, so it needs :runtime :pekko or :spring"
           | remote == ClusterRemote, runtime == LawSpecActors ]
