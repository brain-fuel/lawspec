-- Typed channel ends for implementation code. Every protocol becomes, on
-- each target, a type per step for each of its two ends: the first end
-- follows the protocol, the second the reverse. A send or receive returns
-- the end's next step, so the target's compiler rejects steps out of order;
-- an end used twice fails at run time (Rust's moves reject it at compile
-- time). Channels, spawn and par come from each target's runtime, behind a
-- small send/receive interface a networked transport can also implement.
module LawSpec.Sessions (sessionArtifacts) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import qualified LawSpec.Sessions.Python as Python
import qualified LawSpec.Sessions.Web as Web
import qualified LawSpec.Sessions.Go as Go
import qualified LawSpec.Sessions.Jvm as Jvm
import qualified LawSpec.Sessions.Rust as Rust
import qualified LawSpec.Sessions.Haskell as Haskell

sessionArtifacts :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
sessionArtifacts minify target plan
  | all (null . C.unitSessions) units = Right []
  | otherwise = either (\message -> Left [Diagnostic "sessions" message Nothing]) Right (emitter target minify bits datas units)
  where
    units = map plannedUnit (plannedUnits plan)
    datas = planDataDeclarations plan
    bits = planMachineBits plan
    emitter t = case t of
      "python" -> Python.emit t
      "javascript" -> Web.emit t
      "typescript" -> Web.emit t
      "go" -> Go.emit t
      "java" -> Jvm.emit t
      "kotlin" -> Jvm.emit t
      "rust" -> Rust.emit t
      _ -> Haskell.emit t
