-- Typed channel ends for implementation code: each protocol's steps as
-- types of this target (see LawSpec.Sessions).
module LawSpec.Sessions.Jvm (emit) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))

-- The session library for the given target, for every unit's protocols.
emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit _ _ _ _ _ = Right []
