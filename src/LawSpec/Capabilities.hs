-- | Capability discharge shared by declaration and law checking.
module LawSpec.Capabilities (satisfiedWithData) where

import LawSpec.Model (Constraint)
import qualified LawSpec.Core as Core
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Elaboration (coreTypeWithRecords)

-- | Use the same contextual lowering for ordinary and structural types. The
-- resulting record declarations participate in equality/key requirements;
-- field validation never needs to import this higher-level elaborator again.
satisfiedWithData :: [Core.DataDeclaration] -> Int -> [Constraint] -> Constraint -> Bool
satisfiedWithData declarations bits = checkCapability (coreTypeWithRecords declarations bits) declarations bits
