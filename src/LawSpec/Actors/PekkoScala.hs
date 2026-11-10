-- | Typed actors for Scala on Apache Pekko (lawspec.edn's
-- `:actors {:runtime :pekko}`). The generated classes and companions are the
-- Scala emitter's, with the same public surface as on LawSpec's own runtime
-- (start, a blocking method and a tell method per handler, crash, monitor,
-- link and stop), over the Pekko runtime's classes. Scala 3 calls the Java
-- runtime directly, passing its lambdas as the runtime's functional
-- interfaces, as the default Scala actors call LawSpecRuntime
-- (DEC-scala-on-the-jvm-runtime), so no Scala copy of the runtime is
-- generated. Each actor is a Pekko Typed behaviour restarted in place by
-- Pekko, and each supervisor keeps OTP's strategies, lifetimes, restart limit
-- and escalation (LawSpecPekkoSupervisor). The runtime's files are written
-- once beside the actors, never per actor or supervisor.
-- ref:DEC-pekko-runtime ref:DEC-pekko-otp-supervision
module LawSpec.Actors.PekkoScala (emit, emitOn) where

import LawSpec.Actors.Jvm (Runtime(..))
import LawSpec.Actors.Pekko (pekkoRuntime, runtimeFiles, clusterFiles)
import qualified LawSpec.Actors.Scala as Scala
import LawSpec.Actors.Types (Actor, Supervision)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Core as C

emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emit = emitOn pekkoRuntime

-- | The Scala actors over a Pekko runtime, with LawSpecPekkoCluster when its
-- actors serve over the cluster. ref:DEC-pekko-cluster-remote
emitOn :: Runtime -> String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emitOn rt target minify bits datas actors supervisions =
  ((runtimeFiles ++ [f | runtimeRemote rt /= Nothing, f <- clusterFiles]) ++) <$> Scala.emitWith rt target minify bits datas actors supervisions
