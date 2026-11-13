-- | Typed compilation shared by external codecs and component services. Mandatory
-- definition admission remains independent of selected law verification.
-- ref:DEC-haskell-application-port
module LawSpec.Service.Compilation (Stages, stages, stagesWithInput) where

import LawSpec.Compile (compileWithSourceOrigins)
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation)
import qualified LawSpec.Core.LawAnalysis as Analysis
import qualified LawSpec.Core.Verification as V
import LawSpec.Discharge (dischargeReporting)
import LawSpec.Frontend (elaborateCanonical)
import LawSpec.LawClaims (elaborateClaims)
import LawSpec.Memo (staged)
import LawSpec.Model
import LawSpec.ModelLaws (historyLawEvidence, modelLawEvidence)
import LawSpec.NativeRequest
import LawSpec.Packages
import LawSpec.ProofSettings (proofSettings)
import LawSpec.SourceSyntax (SourceSyntax)
import LawSpec.Testing (Plan, planTesting, planTestingWith)

-- | Checked surface/Core, native bindings, evidence, dependencies and a lazy
-- generation plan. Planning failures remain distinct from definition admission.
type Stages = ([Unit], [Expanded], C.Program, BindingPlan, ([Obligation], [Analysis.Row]), [(Package, [String])], Either [Diagnostic] Plan)

-- | Compile without a syntax inventory when no authoring consumer needs it.
stages :: Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either [Diagnostic] Stages
stages project packages sources bits settings native verification =
  fst <$> stagesWithInput (verification /= Nothing) False project packages sources bits settings native verification

-- | Keep diagnostics typed across package preparation, elaboration, admission
-- and optional evidence preparation. The external codec selects presentation.
stagesWithInput :: Bool -> Bool -> Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Maybe V.Verification -> Either [Diagnostic] (Stages, [SourceSyntax])
stagesWithInput canonical capture project packages sources bits settings native verification = case staged "packages" "" (preparePackagesWithOrigins canonical project packages sources) of
  Left ds -> Left ds
  Right (allSources, origins, visible, referenceUnit, described) -> case staged "compile" "" (compileWithSourceOrigins origins capture canonical referenceUnit visible bits settings allSources) of
    Left ds -> Left (versionedDiagnostics described ds)
    Right (us, es, syntax) -> case staged "elaborate" "" (elaborateCanonical bits us es) of
      Left ds -> Left (versionedDiagnostics described ds)
      Right core -> case resolveNativeRequest core native of
        Left message -> Left [Diagnostic "native-binding" message Nothing]
        Right bindings -> case staged "discharge" "" (dischargeReporting verification core) of
          Left ds -> Left ds
          Right evidence -> case staged "claims" "" (elaborateClaims bits us core <* proofSettings us) of
            Left ds -> Left ds
            -- The laws about each function, checked together, by default
            -- whenever proof or exhaustive checking is selected.
            Right claims ->
              let rows = Analysis.analyse core claims
               in -- Laws about a model's runs, checked over its reference by an
                  -- explicit-state search when proof, exhaustive or model
                  -- checking is selected.
                  let checking = maybe True (\config -> any (V.selected config) [V.Proof, V.Exhaustive, V.Model]) verification
                   in case staged "model-laws" "" ((++) <$> modelLawEvidence checking us core <*> historyLawEvidence checking us core) of
                        Left ds -> Left ds
                        Right modelEvidence ->
                          Right ((us, es, core, bindings, (evidence ++ modelEvidence, rows), described, staged "plan" "" (maybe planTesting planTestingWith verification core)), syntax)
