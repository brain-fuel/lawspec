{-# LANGUAGE DeriveGeneric, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
-- Policies a workflow stage runs under. A stage with policies becomes an
-- orchestration definition whose body each target runs through its workflow
-- runtime (run_stage). Durations are whole microseconds. Names are surface
-- names before elaboration and declaration identities after.
module LawSpec.Core.Policy
  ( StagePolicy(..), Retry(..), Strategy(..), Jitter(..), emptyPolicy
  ) where

import GHC.Generics (Generic)

data StagePolicy name = StagePolicy
  { policyStage :: String
  , policyRetry :: Maybe (Retry name)
  , policyTimeout :: Maybe Integer
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- Attempts count the first try: retry fixed 100ms 3 tries up to three times.
data Retry name = Retry
  { retryStrategy :: Strategy name
  , retryAttempts :: Integer
  , retryJitter :: Jitter
  , retryWhen :: Maybe name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- The delay before each further attempt, in microseconds (see the runtimes).
data Strategy name
  = Immediate
  | Fixed Integer
  | Linear Integer Integer
  | Exponential Integer Integer (Maybe Integer)
  | Fibonacci Integer
  | Custom name
  deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

data Jitter = NoJitter | FullJitter | EqualJitter | DecorrelatedJitter
  deriving (Eq, Show, Generic)

emptyPolicy :: String -> StagePolicy name
emptyPolicy stage = StagePolicy stage Nothing Nothing
