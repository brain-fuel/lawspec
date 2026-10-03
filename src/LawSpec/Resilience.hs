-- Workflow policies as state machines: a built-in unit, lawspec.resilience,
-- added to sources whose workflows use a rate limit, circuit breaker,
-- bulkhead or timeout. Its checked definitions are generated to every target
-- like any definition; each target's workflow runtime keeps a stage's state
-- and drives them (start, admit, record or release), so the policies behave
-- identically everywhere. Times and waits are Integer microseconds.
module LawSpec.Resilience
  ( resilienceUnit, resilienceAlias, resilienceSource, resilienceTypes, usesResilience
  , stageFailureType, stageFailureTag, resilienceName, resilienceDefinitions
  ) where

import Data.Char (isAlphaNum, toUpper)
import Data.List (isPrefixOf)

resilienceUnit :: String
resilienceUnit = "lawspec.resilience"

resilienceAlias :: String
resilienceAlias = "lawspecResilience"

-- The types a source using policies imports.
resilienceTypes :: [String]
resilienceTypes = ["StageFailure"]

stageFailureType :: String
stageFailureType = resilienceUnit ++ "::type::StageFailure"

stageFailureTag :: String -> String
stageFailureTag constructor = stageFailureType ++ "::" ++ constructor

-- The name of a unit's copy of a resilience definition (as imports name it).
resilienceName :: String -> String
resilienceName name = "lawspecResilience" ++ capital name
  where capital (c : cs) = toUpper c : cs
        capital [] = []

-- Every definition of the unit; a source using policies copies them all.
resilienceDefinitions :: [String]
resilienceDefinitions = [takeWhile (/= ' ') (drop 11 line) | line <- lines resilienceSource, "definition " `isPrefixOf` line]

-- Whether a source's workflows use a stateful or failing policy.
usesResilience :: String -> Bool
usesResilience text = any (`elem` tokens) ["rateLimit", "circuitBreaker", "bulkhead", "timeout", "StageFailure"]
  where tokens = words (map (\c -> if isAlphaNum c then c else ' ') (unlines (map (takeWhile' ) (lines text))))
        takeWhile' line = go line
        go ('-' : '-' : _) = ""
        go (c : rest) = c : go rest
        go [] = []

resilienceSource :: String
resilienceSource = unlines
  [ "unit " ++ resilienceUnit
  , ""
  , "-- What a stage's runtime does with a call: run it now, wait first, or fail it.",
  "type Gate is | Admit | WaitFor micros :: Integer | Reject end",
  "",
  "-- A policy's next state and its decision.",
  "type Step (s :: Type) is Step state :: s gate :: Gate end",
  "",
  "-- What a stage with primitives fails with.",
  "type StageFailure (e :: Type) is | StepFailed error :: e | RateLimited | TimedOut | CircuitOpen | Saturated end",
  "",
  "definition atLeastZero (x :: Integer) :: Integer is prelude.select (x < 0) 0 x end",
  "",
  "definition ceilingQuotient (a :: Integer) (b :: Integer where b >= 1) :: Integer is",
  "  prelude.quot (atLeastZero a + b - 1) b",
  "end",
  "",
  "-- Token bucket: n tokens per period, at most n stored. The level is in",
  "-- token-microseconds (tokens times the period), so refilling stays exact.",
  "type TokenBucket is TokenBucket level :: Integer last :: Integer end",
  "",
  "definition tokenBucketStart (n :: Integer) (period :: Integer) (now :: Integer) :: TokenBucket is",
  "  TokenBucket (n * period) now",
  "end",
  "",
  "definition refilled (n :: Integer) (period :: Integer) (level :: Integer) (elapsed :: Integer) :: Integer is",
  "  prelude.select (level + atLeastZero elapsed * n > n * period) (n * period) (level + atLeastZero elapsed * n)",
  "end",
  "",
  "definition tokenBucketDecide (n :: Integer where n >= 1) (period :: Integer where period >= 1) (level :: Integer) (now :: Integer) :: Step TokenBucket is",
  "  prelude.select (level >= period)",
  "    (Step (TokenBucket (level - period) now) Admit)",
  "    (Step (TokenBucket level now) (WaitFor (ceilingQuotient (period - level) n)))",
  "end",
  "",
  "definition tokenBucketAdmit (n :: Integer where n >= 1) (period :: Integer where period >= 1) (state :: TokenBucket) (now :: Integer) :: Step TokenBucket is",
  "  match state with",
  "  | TokenBucket level last -> tokenBucketDecide n period (refilled n period level (now - last)) now",
  "  end",
  "end",
  "",
  "-- Fixed window: at most n calls in each period-long window.",
  "type FixedWindow is FixedWindow window :: Integer count :: Integer end",
  "",
  "definition fixedWindowStart (n :: Integer) (period :: Integer) (now :: Integer) :: FixedWindow is FixedWindow (-1) 0 end",
  "",
  "definition fixedWindowDecide (n :: Integer) (period :: Integer) (window :: Integer) (count :: Integer) (now :: Integer) :: Step FixedWindow is",
  "  prelude.select (count < n)",
  "    (Step (FixedWindow window (count + 1)) Admit)",
  "    (Step (FixedWindow window count) (WaitFor (atLeastZero ((window + 1) * period - now))))",
  "end",
  "",
  "definition fixedWindowAdmit (n :: Integer) (period :: Integer where period >= 1) (state :: FixedWindow) (now :: Integer) :: Step FixedWindow is",
  "  match state with",
  "  | FixedWindow window count ->",
  "      prelude.select (prelude.quot (atLeastZero now) period == window)",
  "        (fixedWindowDecide n period window count now)",
  "        (fixedWindowDecide n period (prelude.quot (atLeastZero now) period) 0 now)",
  "  end",
  "end",
  "",
  "-- Sliding window: at most n calls in any period-long span. The state keeps",
  "-- the times of the calls admitted in the last period, oldest first.",
  "type SlidingWindow is SlidingWindow times :: List Integer end",
  "",
  "definition slidingWindowStart (n :: Integer) (period :: Integer) (now :: Integer) :: SlidingWindow is SlidingWindow [] end",
  "",
  "definition recent (times :: List Integer) (since :: Integer) :: List Integer is",
  "  match times with",
  "  | Nil -> times",
  "  | Cons t rest -> prelude.select (t > since) times (recent rest since)",
  "  end",
  "end",
  "",
  "definition appended (times :: List Integer) (time :: Integer) :: List Integer is",
  "  match times with",
  "  | Nil -> Cons time Nil",
  "  | Cons t rest -> Cons t (appended rest time)",
  "  end",
  "end",
  "",
  "definition oldest (times :: List Integer) (fallback :: Integer) :: Integer is",
  "  match times with",
  "  | Nil -> fallback",
  "  | Cons t rest -> t",
  "  end",
  "end",
  "",
  "definition slidingWindowDecide (n :: Integer) (period :: Integer) (times :: List Integer) (now :: Integer) :: Step SlidingWindow is",
  "  prelude.select (prelude.length times < n)",
  "    (Step (SlidingWindow (appended times now)) Admit)",
  "    (Step (SlidingWindow times) (WaitFor (atLeastZero (oldest times now + period - now))))",
  "end",
  "",
  "definition slidingWindowAdmit (n :: Integer) (period :: Integer) (state :: SlidingWindow) (now :: Integer) :: Step SlidingWindow is",
  "  match state with",
  "  | SlidingWindow times -> slidingWindowDecide n period (recent times (now - period)) now",
  "  end",
  "end",
  "",
  "-- Leaky bucket: calls start one interval apart (period / n), waiting their turn.",
  "type LeakyBucket is LeakyBucket next :: Integer end",
  "",
  "definition leakyBucketStart (n :: Integer) (period :: Integer) (now :: Integer) :: LeakyBucket is LeakyBucket now end",
  "",
  "definition leakyBucketAdmit (n :: Integer where n >= 1) (period :: Integer where period >= 1) (state :: LeakyBucket) (now :: Integer) :: Step LeakyBucket is",
  "  match state with",
  "  | LeakyBucket next ->",
  "      prelude.select (next <= now)",
  "        (Step (LeakyBucket (now + ceilingQuotient period n)) Admit)",
  "        (Step (LeakyBucket next) (WaitFor (next - now)))",
  "  end",
  "end",
  "",
  "-- Circuit breaker: after `failures` failures within `window`, calls fail",
  "-- for `cooldown`; then one trial call decides whether it closes again.",
  "type Breaker is | Closed failures :: List Integer | Open until :: Integer | HalfOpen end",
  "",
  "definition breakerStart (now :: Integer) :: Breaker is Closed [] end",
  "",
  "definition breakerAdmit (state :: Breaker) (now :: Integer) :: Step Breaker is",
  "  match state with",
  "  | Closed failures -> Step state Admit",
  "  | Open until -> prelude.select (now >= until) (Step HalfOpen Admit) (Step state Reject)",
  "  | HalfOpen -> Step state Reject",
  "  end",
  "end",
  "",
  "definition breakerRecord (failures :: Integer) (window :: Integer) (cooldown :: Integer) (state :: Breaker) (now :: Integer) (succeeded :: Bool) :: Breaker is",
  "  match state with",
  "  | Closed times ->",
  "      prelude.select succeeded state",
  "        (prelude.select (prelude.length (appended (recent times (now - window)) now) >= failures)",
  "          (Open (now + cooldown))",
  "          (Closed (appended (recent times (now - window)) now)))",
  "  | Open until -> state",
  "  | HalfOpen -> prelude.select succeeded (Closed []) (Open (now + cooldown))",
  "  end",
  "end",
  "",
  "-- Bulkhead: at most n calls of the stage at once.",
  "type Bulkhead is Bulkhead running :: Integer end",
  "",
  "definition bulkheadStart (n :: Integer) (now :: Integer) :: Bulkhead is Bulkhead 0 end",
  "",
  "definition bulkheadAdmit (n :: Integer) (state :: Bulkhead) (now :: Integer) :: Step Bulkhead is",
  "  match state with",
  "  | Bulkhead running -> prelude.select (running < n) (Step (Bulkhead (running + 1)) Admit) (Step state (WaitFor 1000))",
  "  end",
  "end",
  "",
  "definition bulkheadRelease (state :: Bulkhead) :: Bulkhead is",
  "  match state with",
  "  | Bulkhead running -> Bulkhead (atLeastZero (running - 1))",
  "  end",
  "end"
  ]
