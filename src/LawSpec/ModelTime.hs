-- | `time passes by r [when p]`: an actor's step in which time passes, by as
-- much as its reference says, so the actor's timers fire. The reference takes
-- the model state and returns how long passes and the model state after it
-- (Model -> Pair Duration Model), as a discrete-event simulation advances its
-- clock to the next event. The step is the actor's command timePasses, whose
-- adapter LawSpec declares (<actor>TimePasses :: State -> Pair Duration State)
-- and only a natively bound Pekko actor runs, on virtual time; every other
-- implementation is reported unsupported. ref:DEC-time-passes
module LawSpec.ModelTime (timeStep, timePasses, timeAdapter, timeSignature, isTimeStep) where

import LawSpec.Core.Machine (Machine(..), Command(..))
import LawSpec.Model (Type(..))

-- | How the parser marks the step among an actor's handlers.
timeStep :: String
timeStep = "time passes"

-- | The step's command name: in runs, traces, bindings and fairness
-- (`assuming fairness for time passes`).
timePasses :: String
timePasses = "timePasses"

-- | The adapter LawSpec declares for an actor's step.
timeAdapter :: String -> String
timeAdapter actor = actor ++ "TimePasses"

-- | Its signature over the actor's own state.
timeSignature :: Type -> Type
timeSignature own = Arrow own (Application "Pair" [Named "Duration", own])

-- | Whether a command is an actor's time step.
isTimeStep :: Machine name -> Command name -> Bool
isTimeStep machine command = machineActor machine && commandName command == timePasses
