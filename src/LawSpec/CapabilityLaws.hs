-- | The capability laws' unit as Core, for a harness that cites one of its
-- laws. It is compiled here from its source (LawSpec.Instances), apart from
-- the program that cites it: the program gains no unit, no adapter and no
-- task. ref:DEC-capability-laws
module LawSpec.CapabilityLaws (capabilityLaws, capabilityLawsProgram) where

import Data.List (find)
import LawSpec.Common (Diagnostic(..), Source(..), defaultGeneration)
import qualified LawSpec.Core as C
import LawSpec.Compile (compileWithSettings)
import LawSpec.Frontend (elaborate)
import qualified LawSpec.Model as S
import LawSpec.Instances (instanceLawsUnit)

capabilityLaws :: Either String C.Unit
capabilityLaws = do
  (_, program) <- capabilityLawsProgram
  maybe (Left "the capability laws are missing from their program") Right
    (find ((== C.Id instanceLawsUnit) . C.unitId) (C.programUnits program))

-- | The program the laws are proved in: as written, and as Core.
capabilityLawsProgram :: Either String ([S.Unit], C.Program)
capabilityLawsProgram = either (\diagnostics -> Left ("the capability laws do not compile: " ++ unwords (map message diagnostics))) Right $ do
  (units, properties) <- compileWithSettings 64 defaultGeneration [Source "<lawspec.capability.laws.use>" use]
  program <- C.lowerProgramFields <$> elaborate 64 units properties
  pure (units, program)
  where
    use = unlines ["unit lawspec.capability.use", "import " ++ instanceLawsUnit ++ " (negated)", "end unit"]
