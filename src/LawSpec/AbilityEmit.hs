-- Each target's native pieces of the program's abilities: an interface per
-- ability, a class (or record of functions) per spec handler and a
-- recording per ability. See LawSpec.AbilityNames for their names, and
-- docs/explanation/abilities.md for how handlers reach the code that
-- performs operations.
module LawSpec.AbilityEmit (abilityArtifacts) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import LawSpec.AbilityNames (unitAbilityPieces)
import qualified LawSpec.AbilityEmit.Python as Python
import qualified LawSpec.AbilityEmit.Web as Web
import qualified LawSpec.AbilityEmit.Go as Go

abilityArtifacts :: Bool -> String -> Plan -> Either [Diagnostic] [Artifact]
abilityArtifacts minify target plan
  | not (any unitAbilityPieces units) = Right []
  | otherwise = either (\message -> Left [Diagnostic "abilities" message Nothing]) Right (emitter target)
  where
    units = map plannedUnit (plannedUnits plan)
    datas = planDataDeclarations plan
    bits = planMachineBits plan
    emitter t = case t of
      "python" -> Python.emit minify bits datas units
      "javascript" -> Web.emit False minify bits datas units
      "typescript" -> Web.emit True minify bits datas units
      "go" -> Go.emit minify bits datas units
      _ -> Left ("abilities are not generated for " ++ t ++ " yet")
