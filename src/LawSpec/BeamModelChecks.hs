-- | Stateful evidence identities shared by BEAM emission and CLI selection.
-- Each native completion covers one sequential model, parallel model,
-- scenario, or supervision check. ref:DEC-never-pass-vacuously
module LawSpec.BeamModelChecks (Check(..), Action(..), checks, machineNames) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine (Machine(..))
import qualified LawSpec.Core.Program as P
import LawSpec.TestNames (unitTestNames)

data Action
  = Sequential String (Machine C.Id)
  | Parallel String (Machine C.Id)
  | Scenario String (Machine C.Id) P.Program
  | Supervision
  deriving (Eq, Show)

data Check = Check
  { checkIdentity :: C.Id, checkName :: String, checkLabel :: String
  , checkAction :: Action }
  deriving (Eq, Show)

machineNames :: C.Unit -> [String]
machineNames = map (("model_" ++) . drop 4) . unitTestNames "erlang" . map machineName . C.unitMachines

checks :: C.Unit -> [Check]
checks unit = concatMap model (zip (machineNames unit) (C.unitMachines unit)) ++
  [Check (C.Id (owner ++ "::supervision")) "supervision" (owner ++ "::supervision") Supervision
    | not (null (C.unitSupervisors unit))]
  where
    owner = C.idText (C.unitId unit)
    escape = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])
    model (name, machine) =
      let identity = owner ++ "::model::" ++ escape (machineName machine)
          label = owner ++ "::model " ++ machineName machine
          -- Normalized model names never contain a double underscore. Keep
          -- the kind after that separator so another model's name cannot
          -- alias a scenario (for example a/scenario x and a_scenario_x).
          scenarioNames = map ((name ++ "__scenario_") ++) (map (drop 4)
            (unitTestNames "erlang" (map P.programTitle (machineScenarios machine))))
      in [Check (C.Id (identity ++ "::sequential")) (name ++ "__sequential") label (Sequential name machine)] ++
         [Check (C.Id (identity ++ "::parallel")) (name ++ "__parallel") (label ++ " parallel") (Parallel name machine)
           | machineShared machine] ++
         [Check (C.Id (identity ++ "::scenario::" ++ escape (P.programTitle program))) entry
           (label ++ "::scenario " ++ P.programTitle program) (Scenario name machine program)
           | (entry, program) <- zip scenarioNames (machineScenarios machine)]
