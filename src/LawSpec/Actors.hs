-- Typed actors for implementation code. Every actor declaration becomes, on
-- each target, a class (or its idiom) named for the actor's handle type:
-- start makes the state with the actor's start adapter and runs it in a
-- runtime actor; each handler becomes a method that sends the message and
-- waits for the reply, and a tell form that sends it without waiting. The
-- handlers are the user's own adapters, called with native values.
module LawSpec.Actors (actorArtifacts) where

import LawSpec.Actors.Types (actorsOf)
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import qualified LawSpec.Actors.Python as Python
import qualified LawSpec.Actors.Go as Go
import qualified LawSpec.Actors.Web as Web

actorArtifacts :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
actorArtifacts minify target plan = case concatMap actorsOf units of
  [] -> Right []
  actors -> either (\message -> Left [Diagnostic "actors" message Nothing]) Right (emitter target minify bits datas actors)
  where
    units = map plannedUnit (plannedUnits plan)
    datas = planDataDeclarations plan
    bits = planMachineBits plan
    emitter t = case t of
      "python" -> Python.emit t
      "go" -> Go.emit t
      "javascript" -> Web.emit t
      "typescript" -> Web.emit t
      _ -> \_ _ _ _ -> Right []

