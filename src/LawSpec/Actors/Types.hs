-- What an actor's typed class on a target is made from (see LawSpec.Actors).
module LawSpec.Actors.Types (Actor(..), Handler(..), actorsOf) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine

-- What a target needs of one actor.
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
  }

data Handler = Handler
  { handlerName :: String
  , handlerDeclaration :: C.Declaration
  -- The arguments after the state, named.
  , handlerArguments :: [(String, C.Type)]
  -- The reply's type; Nothing when the handler returns the state alone.
  , handlerReply :: Maybe C.Type
  }

-- The unit's actors, with each adapter's argument names from its contract.
actorsOf :: C.Unit -> [Actor]
actorsOf u =
  [ Actor u (machineName m) (lastSegment (machineState m)) own start (named start)
      [Handler (commandName c) d (drop 1 (named d)) (reply own d) | c <- machineCommands m, not (commandRestart c), Just d <- [declaration (commandSystem c)]]
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
