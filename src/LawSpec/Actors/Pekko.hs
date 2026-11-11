-- | Typed actors for Java and Kotlin on Apache Pekko (lawspec.edn's
-- `:actors {:runtime :pekko}`). The generated classes are the JVM emitter's,
-- over the Pekko runtime's classes, which have the LawSpec runtime's methods:
-- each actor is a Pekko Typed behaviour restarted in place by Pekko, and each
-- supervisor keeps OTP's strategies, lifetimes, restart limit and escalation
-- over them (runtime/pekko). So adapters, laws, and Groovy's and Clojure's
-- reuse of the Java classes do not change. The runtime's files are written
-- once beside the actors, never per actor or supervisor.
-- ref:DEC-pekko-runtime ref:DEC-pekko-otp-supervision
module LawSpec.Actors.Pekko (emit, emitOn, runtimeFiles, pekkoRuntime, onCluster, clusterFiles) where

import LawSpec.Actors.Jvm (Runtime(..), emitWith)
import LawSpec.Actors.Types (Actor, Supervision)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C
import LawSpec.RuntimeSources (runtimeSource)

-- | The Pekko runtime's classes, in lawspec.runtime.pekko. Its actors have
-- serve and connect only over Pekko Cluster (onCluster).
pekkoRuntime :: Runtime
pekkoRuntime = Runtime
  { runtimeActor = "LawSpecPekko.Actor"
  , runtimeSupervisor = "LawSpecPekkoSupervisor"
  , runtimeImports = ["lawspec.runtime.pekko.LawSpecPekko", "lawspec.runtime.pekko.LawSpecPekkoSupervisor"]
  , runtimeRemote = Nothing
  , runtimeSpring = False
  }

-- | A runtime whose actors serve and connect over Pekko Cluster
-- (`:remote :cluster`): a LawSpecPekkoCluster.Node registers each served
-- actor with the typed Receptionist, and calls cross Artery.
-- ref:DEC-pekko-cluster-remote
onCluster :: Runtime -> Runtime
onCluster rt = rt
  { runtimeImports = runtimeImports rt ++ ["lawspec.runtime.pekko.LawSpecPekkoCluster"]
  , runtimeRemote = Just "LawSpecPekkoCluster"
  }

emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emit = emitOn pekkoRuntime

-- | The Java and Kotlin actors over a Pekko runtime, with its files, and
-- LawSpecPekkoCluster's when its actors serve over the cluster.
emitOn :: Runtime -> String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emitOn rt target minify bits datas actors supervisions =
  ((runtimeFiles ++ [f | runtimeRemote rt /= Nothing, f <- clusterFiles]) ++) <$> emitWith rt target minify bits datas actors supervisions

-- | The runtime's Java sources, compiled with the program's Java model on
-- every JVM target.
runtimeFiles :: [Artifact]
runtimeFiles =
  [ Artifact ("src/main/java/lawspec/runtime/pekko/" ++ file) (runtimeSource key) "generated" "source"
  | (key, file) <-
      [ ("java-pekko", "LawSpecPekko.java")
      , ("java-pekko-supervisor", "LawSpecPekkoSupervisor.java")
      , ("java-pekko-crash", "LawSpecCrashInterceptor.java") ] ]

-- | LawSpecPekkoCluster, for actors served over Pekko Cluster.
clusterFiles :: [Artifact]
clusterFiles =
  [ Artifact "src/main/java/lawspec/runtime/pekko/LawSpecPekkoCluster.java" (runtimeSource "java-pekko-cluster") "generated" "source" ]
