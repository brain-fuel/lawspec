-- | Typed actors for implementation code. Every actor declaration becomes, on
-- each target, a class (or its idiom) named for the actor's handle type:
-- start makes the state with the actor's start adapter and runs it in a
-- runtime actor; each handler becomes a method that sends the message and
-- waits for the reply, and a tell form that sends it without waiting. The
-- handlers are the user's own adapters, called with native values.
module LawSpec.Actors (actorArtifacts) where

import LawSpec.ActorRuntime (ActorRemote(..), ActorRuntime(..), ActorSettings(..), actorRuntimeName)
import LawSpec.Actors.Types (actorsOf, supervisionsOf)
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import qualified LawSpec.Actors.Python as Python
import qualified LawSpec.Actors.Go as Go
import qualified LawSpec.Actors.Web as Web
import qualified LawSpec.Actors.Jvm as Jvm
import qualified LawSpec.Actors.Scala as Scala
import qualified LawSpec.Actors.Rust as Rust
import qualified LawSpec.Actors.Haskell as Haskell
import qualified LawSpec.Actors.Pekko as Pekko
import qualified LawSpec.Actors.PekkoScala as PekkoScala
import qualified LawSpec.Actors.Spring as Spring

-- | Programs without actors get no actor files; the others get a typed class per
-- actor on every target. ref:DEC-actors-otp-supervision
actorArtifacts :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
actorArtifacts minify target plan = case concatMap actorsOf units of
  [] -> Right []
  actors -> either (\message -> Left [Diagnostic "actors" message Nothing]) Right
    (emitter target minify bits datas actors (concatMap supervisionsOf units))
  where
    units = map plannedUnit (plannedUnits plan)
    datas = planDataDeclarations plan
    bits = planMachineBits plan
    settings = planActors plan
    -- A JVM target's actors run on its chosen runtime (lawspec.edn's
    -- :actors); what is not implemented yet is refused, never ignored.
    -- ref:DEC-pekko-runtime
    emitter t = case (actorRuntime settings, actorRemote settings) of
      (LawSpecActors, _) -> lawspecEmitter t
      (_, ClusterRemote) -> unsupported "serve and connect over Pekko Cluster (:remote :cluster) are not implemented yet"
      (PekkoActors, _) | t `elem` ["java", "kotlin"] -> Pekko.emit t
      (PekkoActors, _) | t == "scala" -> PekkoScala.emit t
      (SpringActors, _) | t `elem` ["java", "kotlin"] -> Spring.emit t
      (SpringActors, _) | t == "scala" -> unsupported "generated actors on :spring are not supported for Scala: the Spring Boot actor starter is a Java and Kotlin library; use :runtime :pekko"
      (runtime, _) -> unsupported ("generated actors on :" ++ actorRuntimeName runtime ++ " are not implemented for " ++ t ++ " yet")
    unsupported message = \_ _ _ _ _ -> Left message
    lawspecEmitter t = case t of
      "python" -> Python.emit t
      "go" -> Go.emit t
      "javascript" -> Web.emit t
      "typescript" -> Web.emit t
      "java" -> Jvm.emit t
      "kotlin" -> Jvm.emit t
      "scala" -> Scala.emit t
      "rust" -> Rust.emit t
      "haskell" -> Haskell.emit t
      _ -> \_ _ _ _ _ -> Right []

