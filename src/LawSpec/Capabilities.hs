-- | Capability discharge shared by declaration and law checking.
module LawSpec.Capabilities (satisfiedWithData, satisfiedWithContext) where

import LawSpec.Model (Constraint)
import qualified LawSpec.Core as Core
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import qualified LawSpec.SourceContext as Source

-- | Use the same contextual lowering for ordinary and structural types. The
-- resulting record declarations participate in equality/key requirements;
-- field validation never needs to import this higher-level elaborator again.
satisfiedWithData :: [Core.DataDeclaration] -> Int -> [Constraint] -> Constraint -> Bool
satisfiedWithData = satisfiedWithContext Source.emptyContext

satisfiedWithContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> [Constraint] -> Constraint -> Bool
satisfiedWithContext context declarations bits = checkCapability (coreTypeWithSourceRecords context declarations bits) declarations bits
