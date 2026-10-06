{-# LANGUAGE DeriveGeneric, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
-- | Policies a workflow stage runs under. A stage with policies becomes an
-- orchestration definition whose body each target runs through its workflow
-- runtime (run_stage). Durations are whole microseconds. Names are surface
-- names before elaboration and declaration identities after.
module LawSpec.Core.Policy
  ( StagePolicy(..), Retry(..), Strategy(..), Jitter(..), Limit(..), Breaker(..), Bulkhead(..), Hedge(..), emptyPolicy
  , policyFailures
  ) where

import GHC.Generics (Generic)

-- | A workflow stage's resilience policies, applied by each target's workflow
-- runtime with the same semantics.
data StagePolicy name = StagePolicy
  { policyStage :: String
  , policyRetry :: Maybe (Retry name)
  , policyTimeout :: Maybe Integer
  , policyLimit :: Maybe (Limit name)
  , policyBreaker :: Maybe (Breaker name)
  , policyBulkhead :: Maybe (Bulkhead name)
  -- How long a stage's successful result is reused for the same input.
  , policyCache :: Maybe Integer
  -- The definition undoing the stage's success, when a later stage fails.
  , policyCompensate :: Maybe name
  -- Set on a workflow whose stages compensate: it runs in a frame that
  -- undoes its completed stages, in reverse, when it fails.
  , policyFrame :: Bool
  , policyHedge :: Maybe Hedge
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | A rate limit: kind is tokenBucket, leakyBucket, fixedWindow or
-- slidingWindow; count calls per period. start and admit are definitions of
-- lawspec.resilience, which the runtime drives. When the limit is reached,
-- the stage waits (Just: at most the given time, when there is one) or fails
-- at once (Nothing); a bulkhead's wait means the same.
data Limit name = Limit
  { limitKind :: String, limitCount :: Integer, limitPeriod :: Integer
  , limitWait :: Maybe (Maybe Integer), limitStart :: name, limitAdmit :: name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | After failures within window, calls fail for cooldown, then one trial call
-- decides.
data Breaker name = Breaker
  { breakerFailures :: Integer, breakerWindow :: Integer, breakerCooldown :: Integer
  , breakerStart :: name, breakerAdmit :: name, breakerRecord :: name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | When an attempt has not succeeded after delay, another starts beside it, up
-- to most attempts in all; the first success wins.
data Hedge = Hedge { hedgeDelay :: Integer, hedgeMost :: Integer }
  deriving (Eq, Show, Generic)

-- | At most limit calls at once.
data Bulkhead name = Bulkhead
  { bulkheadLimit :: Integer, bulkheadWait :: Maybe (Maybe Integer)
  , bulkheadStart :: name, bulkheadAdmit :: name, bulkheadRelease :: name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | Attempts count the first try: retry fixed 100ms 3 tries up to three times.
data Retry name = Retry
  { retryStrategy :: Strategy name
  , retryAttempts :: Integer
  , retryJitter :: Jitter
  , retryWhen :: Maybe name
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | The delay before each further attempt, in microseconds (see the runtimes).
data Strategy name
  = Immediate
  | Fixed Integer
  | Linear Integer Integer
  | Exponential Integer Integer (Maybe Integer)
  | Fibonacci Integer
  | Custom name
  deriving (Eq, Show, Generic, Functor, Foldable, Traversable)

-- | The jitter schemes retries may use, named as the common backoff literature
-- names them.
data Jitter = NoJitter | FullJitter | EqualJitter | DecorrelatedJitter
  deriving (Eq, Show, Generic)

-- | A stage with no policies behaves as its step alone.
emptyPolicy :: String -> StagePolicy name
emptyPolicy stage = StagePolicy stage Nothing Nothing Nothing Nothing Nothing Nothing Nothing False Nothing

-- | The failures a stage's policies can cause besides its step's: a limit or
-- bulkhead that rejects or waits at most so long, a breaker, a timeout.
policyFailures :: StagePolicy name -> [String]
policyFailures policy =
  ["RateLimited" | Just limit <- [policyLimit policy], bounded (limitWait limit)] ++
  ["CircuitOpen" | Just _ <- [policyBreaker policy]] ++
  ["Saturated" | Just bulkhead <- [policyBulkhead policy], bounded (bulkheadWait bulkhead)] ++
  ["TimedOut" | Just _ <- [policyTimeout policy]]
  where bounded wait = wait /= Just Nothing
