{-# LANGUAGE DeriveGeneric, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
-- Stateful models: a system's commands, each paired with a reference
-- definition over an abstract model state. Each target's model runtime
-- generates runs of commands, executes them against the adapters and checks
-- every result, state and invariant against the reference. Names are surface
-- names before elaboration and declaration identities after.
module LawSpec.Core.Machine
  ( Machine(..), MachineStart(..), Command(..), Invariant(..), Need(..), Shift(..)
  , admits, shifted
  ) where

import GHC.Generics (Generic)
import LawSpec.Core.Program (Program)

-- A linear machine threads a flow-typed state through its commands and runs
-- sequentially; a shared machine's commands take one handle, whose type
-- never changes, and may also run in parallel.
data Machine name = Machine
  { machineName :: String
  , machineShared :: Bool
  -- The state type: the indexed family, data type or handle type.
  , machineState :: String
  -- How many indices the state type has; typestate tracks each.
  , machineIndices :: Int
  , machineStart :: Maybe (MachineStart name)
  , machineCommands :: [Command name]
  -- The system state's abstraction to the model state, when given, and
  -- the definition that calls it.
  , machineAbstract :: Maybe name
  , machineAbstractRun :: Maybe name
  , machineInvariants :: [Invariant name]
  -- Whether each command touches one key of a set or map, so a parallel
  -- history can be checked key by key.
  , machinePerKey :: Bool
  -- The scenarios that run this model.
  , machineScenarios :: [Program]
  -- An actor: the system is a mailbox that runs the commands (its
  -- handlers, adapters over the actor's own state) one at a time, and the
  -- start makes that state.
  , machineActor :: Bool
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- The command that makes the first state, and the definition giving the
-- model state for the same arguments. indices are the start state's, when
-- its type fixes them.
data MachineStart name = MachineStart
  { startSystem :: name, startModel :: name, startIndices :: Maybe [Integer]
  -- The definition that calls the start command.
  , startRun :: name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- A command: the adapter that runs it, its reference definition over the
-- model state (taking the command's other arguments, then the model state,
-- and returning Pair result state, or the state alone for a Unit result),
-- a precondition over the model state, and, per state index, what the index
-- must be before the command and how the command changes it.
data Command name = Command
  { commandName :: String
  , commandSystem :: name
  -- The generated definition that calls the command's adapter, so the model
  -- runtime calls it with logical values like any definition.
  , commandRun :: name
  , commandReference :: name
  , commandWhen :: Maybe name
  -- The positions of the command's arguments other than the state.
  , commandArguments :: [Int]
  -- The position of the state (flow or handle) argument.
  , commandStatePosition :: Int
  , commandReturnsUnit :: Bool
  , commandNeeds :: [Need]
  , commandShifts :: [Shift]
  -- Which of the command's other arguments is the key it touches, for a
  -- model that behaves like a set or map.
  , commandKey :: Maybe Int
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

data Need = AtLeast Integer | Exactly Integer
  deriving (Eq, Show, Generic)

data Shift = By Integer | To Integer
  deriving (Eq, Show, Generic)

data Invariant name = OnModel name | OnState name
  deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- Whether a command may run at the given state indices.
admits :: Command name -> [Integer] -> Bool
admits command indices = and (zipWith need (commandNeeds command) indices)
  where
    need (AtLeast k) i = i >= k
    need (Exactly k) i = i == k

-- The state indices after a command.
shifted :: Command name -> [Integer] -> [Integer]
shifted command = zipWith shift (commandShifts command)
  where
    shift (By d) i = i + d
    shift (To k) _ = k
