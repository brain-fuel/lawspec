-- Existing features as abilities (docs/reference/language/abilities-mapping.md).
--
-- Every effect-like construct LawSpec had before abilities is sugar over
-- them. The syntax stays; this module states what each construct uses, as
-- an ability row, and which handler answers it by default. `lawspec check
-- --json` shows the rows (a unit's "abilityRows"), and the mapping page
-- documents them:
--
--   async f ::              uses Async (lawspec.concurrent); the default
--                           handler is the target's native async
--   a workflow stage's      Async, Clock and Fail E: timeout, retry, hedge,
--   policies                circuitBreaker, rateLimit, bulkhead and cache are
--                           handler transformers of lawspec.resilience
--   protocol P              the Session P ability; typestate through flow types
--   mailbox m of T          Mailbox T, whose receive … within d uses Clock
--   actor                   Process (spawn, link, monitor) with its state as a
--                           State handler
--   supervisor              Process, with a Fail handler that restarts
--   model                   State: the reference is a stateful spec handler,
--                           checked against the native one through abstract
--   scenario                Session and Mailbox programs over Process, under
--                           a Scheduler handler
--   remote definitions      Network; transports are its handlers, the default
--                           one secure (ML-KEM-768, ML-DSA-65, AES-256-GCM)
--
-- Abilities without a declaring unit are built in, as Fail is, and are named
-- lawspec::ability::<Name>.
module LawSpec.Unification
  ( AbilityRow(..), abilityRows, builtinAbility, asyncAbility
  ) where

import Data.List (nub)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine (Machine(..), Supervisor(..), SupervisionStrategy(..))
import LawSpec.Core.Policy (StagePolicy(..), Retry(..), Strategy(..), Limit(..), Bulkhead(..))
import qualified LawSpec.Core.Program as P

-- What one construct uses, and the handler that answers it by default.
data AbilityRow = AbilityRow
  { rowConstruct :: String, rowName :: String, rowUses :: [String], rowHandler :: String }
  deriving (Eq, Show)

builtinAbility :: String -> String
builtinAbility name = "lawspec::ability::" ++ name

asyncAbility :: String
asyncAbility = "lawspec.concurrent::ability::Async"

clockAbility :: String
clockAbility = "lawspec.time::ability::Clock"

applied :: String -> String -> String
applied ability argument = ability ++ "(" ++ argument ++ ")"

abilityRows :: C.Unit -> [AbilityRow]
abilityRows u =
  [ AbilityRow "async" (C.declarationName d) [asyncAbility] "the target's native async"
  | d <- C.unitDeclarations u, C.declarationAsync d ] ++
  [ AbilityRow "workflow stage" (C.declarationName (C.definitionDeclaration d)) (policyRow policy)
      "lawspec.resilience's transformers over the Async, Clock and Fail handlers"
  | d <- C.unitDefinitions u, Just policy <- [C.definitionPolicy d], not (null (policyRow policy)) ] ++
  [ AbilityRow "protocol" (C.sessionName s) [applied (builtinAbility "Session") (C.sessionName s)]
      "the runtime's typed channel ends; between nodes, the Network handler"
  | s <- C.unitSessions u ] ++
  [ AbilityRow "mailbox" (C.mailboxName m) [applied (builtinAbility "Mailbox") (typeText (C.mailboxType m)), clockAbility]
      "the runtime's mailbox; receive within waits on the Clock handler"
  | m <- C.unitMailboxes u ] ++
  concatMap machineRows (C.unitMachines u) ++
  [ AbilityRow "supervisor" (supervisorName s) [builtinAbility "Process", applied (builtinAbility "Fail") "Crash"]
      ("a Fail handler that restarts its children " ++ strategy (supervisorStrategy s))
  | s <- C.unitSupervisors u ]
  where
    machineRows m =
      [ if machineActor m
          then AbilityRow "actor" (machineName m) [builtinAbility "Process", applied (builtinAbility "State") (machineState m)]
                 "the runtime's actor: one message at a time, its state a State handler"
          else AbilityRow "model" (machineName m) [applied (builtinAbility "State") (machineState m)]
                 "the reference is a stateful spec handler; the native handler is checked against it through abstract" ] ++
      [ AbilityRow "scenario" (P.programTitle p)
          (nub ([applied (builtinAbility "Session") protocol | protocol <- P.programProtocols p] ++
                [applied (builtinAbility "Mailbox") t | (_, t) <- P.programMailboxes p] ++
                [builtinAbility "Process", builtinAbility "Scheduler"]))
          "the scheduler handler: every schedule, some with a crash, some over a faulty network"
      | p <- machineScenarios m ]
    strategy s = case s of
      OneForOne -> "one for one"
      OneForAll -> "one for all"
      RestForOne -> "rest for one"

-- What a stage's policies use.
policyRow :: StagePolicy C.Id -> [String]
policyRow policy = nub $
  [asyncAbility | timed || hedged] ++
  [clockAbility | timed || hedged || waits] ++
  [builtinAbility "Random" | jittered] ++
  [applied (builtinAbility "Fail") "StageFailure" | not (null failures)]
  where
    timed = policyTimeout policy /= Nothing
    hedged = policyHedge policy /= Nothing
    waits = any delayed (policyRetry policy) || policyLimit policy /= Nothing || policyBreaker policy /= Nothing
      || maybe False (\b -> bulkheadWait b /= Nothing) (policyBulkhead policy) || policyCache policy /= Nothing
    delayed r = case retryStrategy r of
      Immediate -> False
      _ -> True
    jittered = maybe False (\r -> show (retryJitter r) /= "NoJitter") (policyRetry policy)
    failures = [() | timed] ++ [() | Just l <- [policyLimit policy], limitWait l /= Just Nothing] ++
      [() | Just _ <- [policyBreaker policy]] ++ [() | Just b <- [policyBulkhead policy], bulkheadWait b /= Just Nothing]

typeText :: C.Type -> String
typeText t = case t of
  C.Constructor n [] -> n
  C.Constructor n args -> n ++ "(" ++ concatMap (\a -> argument a ++ ";") args ++ ")"
  C.TypeVariable v -> C.idText v
  C.Arrow a b -> typeText a ++ "->" ++ typeText b
  where argument (C.TypeArgument x) = typeText x
        argument other = show other
