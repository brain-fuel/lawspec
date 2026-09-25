-- Compatibility entry points for Haskell compiler clients. Elaboration and
-- planning happen before crossing into any target emitter.
module LawSpec.Emit (emit, emitWithLayout, emitWithProfile, emitWithLayoutProfile, targets) where
import LawSpec.Model (Unit, Expanded)
import LawSpec.Common
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (targets, emitPlan, emitPlanWithLayout)

emit :: String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emit = emitWithProfile 64
emitWithProfile :: Int -> String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithProfile bits target units properties = elaborate bits units properties >>= planTesting >>= emitPlan target
emitWithLayout :: String -> Maybe String -> Maybe String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithLayout = emitWithLayoutProfile 64
emitWithLayoutProfile :: Int -> String -> Maybe String -> Maybe String -> [Unit] -> [Expanded] -> Either [Diagnostic] [Artifact]
emitWithLayoutProfile bits target sourceDir testDir units properties =
  elaborate bits units properties >>= planTesting >>= emitPlanWithLayout target sourceDir testDir
