-- | Compatibility entry points for Haskell compiler clients. Elaboration and
-- planning happen before crossing into any target emitter.
module LawSpec.Emit (emit, emitWithLayout, emitWithProfile, emitWithLayoutProfile, targets) where
import LawSpec.Model (Unit, Expanded)
import LawSpec.Common
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (targets, emitPlan, emitPlanWithLayout)

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
emit :: String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emit = emitWithProfile 64
-- | Surface units go through elaboration and planning before any emitter, so no
-- emitter sees source syntax. ref:DEC-typed-core-boundary
emitWithProfile :: Int -> String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithProfile bits target units properties = elaborate bits units properties >>= planTesting >>= emitPlan target
-- | The 64-bit profile unless a caller states another.
emitWithLayout :: String -> Maybe String -> Maybe String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithLayout = emitWithLayoutProfile 64
-- | Projects may put sources and tests where their build expects them.
emitWithLayoutProfile :: Int -> String -> Maybe String -> Maybe String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithLayoutProfile bits target sourceDir testDir units properties =
  elaborate bits units properties >>= planTesting >>= emitPlanWithLayout target sourceDir testDir
