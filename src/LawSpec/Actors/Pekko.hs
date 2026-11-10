-- | Typed actors for Java and Kotlin on Apache Pekko (lawspec.edn's
-- `:actors {:runtime :pekko}`). The generated classes are the JVM emitter's,
-- over the Pekko runtime's classes, which have the LawSpec runtime's methods:
-- each actor is a Pekko Typed behaviour restarted in place by Pekko, and each
-- supervisor keeps OTP's strategies, lifetimes, restart limit and escalation
-- over them (runtime/pekko). So adapters, laws, and Groovy's and Clojure's
-- reuse of the Java classes do not change. The runtime's files are written
-- once beside the actors, never per actor or supervisor.
-- ref:DEC-pekko-runtime ref:DEC-pekko-otp-supervision
module LawSpec.Actors.Pekko (emit, runtimeFiles, pekkoRuntime) where

import LawSpec.Actors.Jvm (Runtime(..), emitWith)
import LawSpec.Actors.Types (Actor, Supervision)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C
import LawSpec.RuntimeSources (runtimeSource)

-- | The Pekko runtime's classes, in lawspec.runtime.pekko. serve and connect
-- over Pekko Cluster are not generated yet (DEC-pekko-cluster-remote).
pekkoRuntime :: Runtime
pekkoRuntime = Runtime
  { runtimeActor = "LawSpecPekko.Actor"
  , runtimeSupervisor = "LawSpecPekkoSupervisor"
  , runtimeImports = ["lawspec.runtime.pekko.LawSpecPekko", "lawspec.runtime.pekko.LawSpecPekkoSupervisor"]
  , runtimeRemote = False
  , runtimeSpring = False
  }

emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emit target minify bits datas actors supervisions =
  (runtimeFiles ++) <$> emitWith pekkoRuntime target minify bits datas actors supervisions

-- | The runtime's Java sources, compiled with the program's Java model on
-- every JVM target.
runtimeFiles :: [Artifact]
runtimeFiles =
  [ Artifact ("src/main/java/lawspec/runtime/pekko/" ++ file) (runtimeSource key) "generated" "source"
  | (key, file) <-
      [ ("java-pekko", "LawSpecPekko.java")
      , ("java-pekko-supervisor", "LawSpecPekkoSupervisor.java")
      , ("java-pekko-crash", "LawSpecCrashInterceptor.java") ] ]
