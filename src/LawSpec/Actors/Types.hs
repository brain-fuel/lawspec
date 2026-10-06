-- | What an actor's typed class on a target is made from (see LawSpec.Actors).
module LawSpec.Actors.Types (Actor(..), Handler(..), Supervision(..), Child(..), actorsOf, supervisionsOf) where

import qualified LawSpec.Core as C
import Data.Char (toUpper)
import LawSpec.Core.Machine

-- | What a target needs of one actor.
data Actor = Actor
  { actorUnit :: C.Unit
  , actorName :: String
  -- The handle type's name, such as AccountActor.
  , actorClass :: String
  -- The actor's own state type.
  , actorState :: C.Type
  , actorStart :: C.Declaration
  -- The start adapter's arguments, named.
  , actorStartArguments :: [(String, C.Type)]
  , actorHandlers :: [Handler]
  -- The adapter giving the state after a crash from the last one (restart
  -- from); without it the actor restarts from its start.
  , actorRestart :: Maybe C.Declaration
  }

-- | What a target needs of one supervisor.
data Supervision = Supervision
  { supervisionUnit :: C.Unit
  , supervisionName :: String
  -- The generated class's name, such as BankSupervisor.
  , supervisionClass :: String
  , supervisionStrategy :: SupervisionStrategy
  , supervisionRestarts :: Integer
  -- The period, in microseconds.
  , supervisionPeriod :: Integer
  -- In start order: a child is an actor or another supervisor.
  , supervisionChildren :: [(Lifetime, String, Child)]
  }

-- | A supervisor's children are actors or other supervisors, as in OTP's
-- supervision trees. ref:erlang-otp-supervisors
data Child = ActorChild Actor | SupervisorChild String

-- | Each message an actor handles becomes a typed method on every target, so a
-- caller cannot send a message the actor does not understand.
-- ref:DEC-actors-otp-supervision
data Handler = Handler
  { handlerName :: String
  , handlerDeclaration :: C.Declaration
  -- The arguments after the state, named.
  , handlerArguments :: [(String, C.Type)]
  -- The reply's type; Nothing when the handler returns the state alone.
  , handlerReply :: Maybe C.Type
  }

-- | The unit's actors, with each adapter's argument names from its contract.
actorsOf :: C.Unit -> [Actor]
actorsOf u =
  [ Actor u (machineName m) (lastSegment (machineState m)) own start (named start)
      [Handler (commandName c) d (drop 1 (named d)) (reply own d) | c <- machineCommands m, not (commandRestart c), Just d <- [declaration (commandSystem c)]]
      (case [d | c <- machineCommands m, commandRestart c, Just d <- [declaration (commandSystem c)]] of
        d : _ -> Just d
        [] -> Nothing)
  | m <- C.unitMachines u, machineActor m
  , Just s <- [machineStart m], Just start <- [declaration (startSystem s)]
  , let own = snd (arrows (C.declarationType start)) ]
  where
    declaration i = case [d | d <- C.unitDeclarations u, C.declarationId d == i] of
      d : _ -> Just d
      [] -> Nothing
    named d = case [c | c <- C.unitContracts u, C.contractDeclaration c == C.declarationId d] of
      c : _ -> [(C.binderName b, C.binderType b) | b <- C.contractArguments c]
      [] -> [("value" ++ show i, t) | (i, t) <- zip [0 :: Int ..] (fst (arrows (C.declarationType d)))]
    -- A handler returns Pair reply state, or the state alone.
    reply own d = case snd (arrows (C.declarationType d)) of
      result | result == own -> Nothing
      C.Constructor n [C.TypeArgument r, C.TypeArgument _] | lastSegment n == "Pair" -> Just r
      _ -> Nothing

-- | The unit's supervisors, each child resolved to an actor or a supervisor's
-- class name.
supervisionsOf :: C.Unit -> [Supervision]
supervisionsOf u =
  [ Supervision u (supervisorName s) (supervisorClassName (supervisorName s)) (supervisorStrategy s)
      (supervisorRestarts s) (supervisorPeriod s)
      [ (lifetime, c, maybe (SupervisorChild (supervisorClassName c)) ActorChild (lookup c actors))
      | (lifetime, c) <- supervisorChildren s ]
  | s <- C.unitSupervisors u ]
  where
    actors = [(actorName a, a) | a <- actorsOf u]

-- | bank's class is BankSupervisor.
supervisorClassName :: String -> String
supervisorClassName n = case n of
  c : cs -> toUpper c : cs ++ "Supervisor"
  [] -> "Supervisor"

arrows :: C.Type -> ([C.Type], C.Type)
arrows (C.Arrow a b) = let (as, r) = arrows b in (a : as, r)
arrows t = ([], t)

lastSegment :: String -> String
lastSegment n = go n n
  where
    go acc s = case s of
      [] -> acc
      ':' : ':' : rest -> go rest rest
      _ : rest -> go acc rest
