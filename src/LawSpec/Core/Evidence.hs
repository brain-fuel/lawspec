-- How each obligation of a checked program is discharged. Definition
-- postconditions are proved by the totality audit (compilation fails
-- otherwise), so emitters never re-check them at runtime. Preconditions guard
-- native callers, and adapter contracts cover code LawSpec cannot inspect, so
-- both are checked at runtime. Adapters themselves are native code taken on
-- trust: the laws that call them are their only evidence. LawSpec.Discharge
-- adds the laws, whose status depends on the testing plan.
module LawSpec.Core.Evidence
  ( Status(..), Obligation(..), statusName, statuses, programEvidence, runtimePostconditions
  , adapterDeclarations
  ) where

import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Core.Machine (Machine(..), Supervisor(..), Consistency(..))
import qualified LawSpec.Core.Program as P

-- Strongest first.
data Status = Proved | ExhaustivelyChecked | PropertyTested | RuntimeChecked | Assumed
  deriving (Eq, Ord, Show, Enum, Bounded)

statuses :: [Status]
statuses = [minBound .. maxBound]

statusName :: Status -> String
statusName Proved = "proved"
statusName ExhaustivelyChecked = "exhaustively-checked"
statusName PropertyTested = "property-tested"
statusName RuntimeChecked = "runtime-checked"
statusName Assumed = "assumed"

data Obligation = Obligation
  { obligationUnit :: Id
  , obligationDeclaration :: Id
  , obligationStage :: String
  , obligationClaim :: Maybe Expr
  , obligationStatus :: Status
  , obligationReason :: String
  } deriving (Eq, Show)

-- Declarations with no checked body: the native functions a unit calls.
adapterDeclarations :: Unit -> [Declaration]
adapterDeclarations unit =
  let definitions = S.fromList [declarationId (definitionDeclaration d) | d <- unitDefinitions unit]
  in [d | d <- unitDeclarations unit, isFunction (declarationType d), not (declarationId d `S.member` definitions)]
  where isFunction (Arrow _ _) = True
        isFunction _ = False

programEvidence :: Program -> [Obligation]
programEvidence program =
  concatMap unitEvidence (programUnits program) ++ concatMap dataEvidence (programDataDeclarations program)
  where
    -- Constructor field refinements, including wrapper constraints, make an
    -- invalid value unrepresentable: construction and native decoding check them.
    dataEvidence declaration =
      [ Obligation (dataId declaration) (constructorId constructor) "construction" (Just claim) RuntimeChecked
          "checked whenever a value is constructed or decoded"
      | constructor <- dataConstructors declaration, claim <- constructorPredicates constructor ]
    unitEvidence unit =
      let definitions = S.fromList [declarationId (definitionDeclaration d) | d <- unitDefinitions unit]
      in concatMap (contractEvidence (unitId unit) definitions) (unitContracts unit) ++
         [ Obligation (unitId unit) (declarationId adapter) "adapter" Nothing Assumed (adapterReason unit adapter)
         | adapter <- adapterDeclarations unit ] ++
         concatMap (machineEvidence (unitId unit)) (unitMachines unit) ++
         [ Obligation (unitId unit) (Id (idText (unitId unit) ++ "::supervisor::" ++ supervisorName s)) "supervision" Nothing PropertyTested
             "the runtime's supervision (strategies, lifetimes, restart limits, escalation, links and monitors) is checked by its own conformance test"
         | s <- unitSupervisors unit ]
    -- A model is tested against its reference; a shared one's histories
    -- must also linearize. A scenario's shape is proved when it compiles.
    machineEvidence owner machine =
      let named role = Id (idText owner ++ "::model::" ++ machineName machine ++ role)
      in [ Obligation owner (named "") "model" Nothing PropertyTested
             "the system runs generated command sequences and must agree with the reference model at every step" ] ++
         [ case machineConsistency machine of
             Linearizable -> Obligation owner (named "") "linearizable" Nothing PropertyTested
               "commands run at the same time on several threads; every history must linearize against the model"
             Sequential -> Obligation owner (named "") "sequentially consistent" Nothing PropertyTested
               "commands run at the same time on several threads; some order keeping each thread's own order must give every result"
             Causal -> Obligation owner (named "") "causally consistent" Nothing PropertyTested
               "commands run at the same time on several threads; each thread's results must follow from what happened before them"
             Eventual -> Obligation owner (named "") "eventually consistent" Nothing PropertyTested
               "commands run at the same time on several threads; once all are done, the state must be that of some order of them"
         | machineShared machine ] ++
         [ Obligation owner (named "") "restart" Nothing PropertyTested
             "runs crash the actor between messages; after each restart it must agree with the model's restart"
         | machineActor machine ] ++
         concat
         [ [ Obligation owner scenario "deadlock-free" Nothing Proved
               (if P.programCyclic program
                  then "no process waits for another in a cycle (checked when compiled)"
                  else "its channels join the processes as a tree, and a tree of sessions cannot deadlock (checked when compiled)")
           , Obligation owner scenario "race-free" Nothing Proved
               "every channel end has one owner and sending it gives it up; shared state is reached only through the model's commands (checked when compiled)"
           , Obligation owner scenario "scenario" Nothing PropertyTested
               "runs on many schedules, some with a process crashed; a receive from a failed process fails or runs its or else, so no run blocks; every history must linearize against the model and every expect must hold" ]
         | program <- machineScenarios machine, let scenario = named ("::scenario::" ++ P.programTitle program) ]
    contractEvidence owner definitions contract
      | contractDeclaration contract `S.member` definitions =
          [ obligation "precondition" claim RuntimeChecked "checked before a native caller's arguments reach the definition"
          | claim <- contractPreconditions contract ] ++
          [ obligation "postcondition" claim Proved "proved from the definition body by the totality audit"
          | claim <- contractPostconditions contract ] ++
          [ obligation "postcondition" claim RuntimeChecked
              "non-linear index arithmetic is beyond the prover; checked on each result"
          | claim <- contractRuntimePostconditions contract ]
      | otherwise =
          [ obligation "precondition" claim RuntimeChecked "checked before each adapter call"
          | claim <- contractPreconditions contract ] ++
          [ obligation "postcondition" claim RuntimeChecked "checked on each native adapter result"
          | claim <- contractPostconditions contract ]
      where obligation stage claim = Obligation owner (contractDeclaration contract) stage (Just claim)
    adapterReason unit adapter = (if declarationAsync adapter then "asynchronous " else "") ++
      case [propertyName p | p <- unitProperties unit, calls (declarationId adapter) p] of
        [] -> "native implementation taken on trust; no law calls it"
        laws -> "native implementation taken on trust; called by " ++ show (length laws) ++ " law(s)"

-- Whether a property calls the declaration, in its body, domain or examples.
calls :: Id -> Property -> Bool
calls name p = any (mentions name) (propertyExpressions p)

mentions :: Id -> Expr -> Bool
mentions name e = case expressionNode e of
  ExternalCall n args -> n == name || any (mentions name) args
  Construct _ args -> any (mentions name) args
  Match value cases -> mentions name value || any (mentions name . caseBody) cases
  AllElements value _ body -> mentions name value || mentions name body
  AllPayloads value predicates -> mentions name value || any (mentions name . snd) predicates
  Binary _ _ a b -> mentions name a || mentions name b
  Unary _ a -> mentions name a
  ShortCircuit _ a b -> mentions name a || mentions name b
  If c a b -> mentions name c || mentions name a || mentions name b
  Convert _ _ a -> mentions name a
  _ -> any (mentions name) (children e)

-- Definition emitters call this for the result checks they generate. Proved
-- postconditions need none; deferred non-linear claims are checked.
runtimePostconditions :: Contract -> [Expr]
runtimePostconditions = contractRuntimePostconditions
