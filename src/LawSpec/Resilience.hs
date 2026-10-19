-- | Workflow policies as state machines: a built-in unit, lawspec.resilience,
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

-- | Resilience policies are an ordinary LawSpec unit, so their behaviour is
-- specified by laws and generated on every target.
-- ref:DEC-elaborate-before-core
resilienceUnit :: String
resilienceUnit = "lawspec.resilience"

-- | The alias the implicit import uses, chosen so no user name collides.
resilienceAlias :: String
resilienceAlias = "lawspecResilience"

-- | The types a source using policies imports.
resilienceTypes :: [String]
resilienceTypes = ["StageFailure"]

-- | Policy failures share one type, so a workflow's error type can include them.
stageFailureType :: String
stageFailureType = resilienceUnit ++ "::type::StageFailure"

-- | Each kind of policy failure is a constructor of that type.
stageFailureTag :: String -> String
stageFailureTag constructor = stageFailureType ++ "::" ++ constructor

-- | The name of a unit's copy of a resilience definition (as imports name it).
resilienceName :: String -> String
resilienceName name = "lawspecResilience" ++ capital name
  where capital (c : cs) = toUpper c : cs
        capital [] = []

-- | Every definition of the unit; a source using policies copies them all.
resilienceDefinitions :: [String]
resilienceDefinitions = [name | line <- lines resilienceSource, kind:name:_ <- [words line], kind `elem` ["function","procedure"]]

-- | Whether a source's workflows use a stateful or failing policy.
usesResilience :: String -> Bool
usesResilience text = any (`elem` tokens) ["rateLimit", "circuitBreaker", "bulkhead", "timeout", "StageFailure"]
  where tokens = words (map (\c -> if isAlphaNum c then c else ' ') (unlines (map (takeWhile' ) (lines text))))
        takeWhile' line = go line
        go ('-' : '-' : _) = ""
        go (c : rest) = c : go rest
        go [] = []

-- | The unit is compiled from source like a user's, so its laws are checked.
resilienceSource :: String
resilienceSource = unlines
  [ "unit lawspec.resilience"
  , ""
  , "-- What a stage's runtime does with a call: run it now, wait first, or fail it."
  , "type Gate is one of | Admit | WaitFor  of type Integer | Reject end type"
  , ""
  , "-- A policy's next state and its decision."
  , "type Step (s :: Type) is a record{  state :: s gate :: Gate} end type"
  , ""
  , "-- What a stage with primitives fails with."
  , "type StageFailure (e :: Type) is one of | StepFailed  of type e | RateLimited | TimedOut | CircuitOpen | Saturated end type"
  , ""
  , "function atLeastZero (x :: Integer) -> Integer is prelude.select (x < 0) 0 x end function"
  , ""
  , "function ceilingQuotient (a :: Integer) (b :: Integer where b >= 1) -> Integer is"
  , "  prelude.quot (atLeastZero a + b - 1) b"
  , "end function"
  , ""
  , "-- Token bucket: n tokens per period, at most n stored. The level is in"
  , "-- token-microseconds (tokens times the period), so refilling stays exact."
  , "type TokenBucket is a record{  level :: Integer last :: Integer} end type"
  , ""
  , "function tokenBucketStart (n :: Integer) (period :: Integer) (now :: Integer) -> TokenBucket is"
  , "  TokenBucket record{ level = (n * period) , last = now}"
  , "end function"
  , ""
  , "function refilled (n :: Integer) (period :: Integer) (level :: Integer) (elapsed :: Integer) -> Integer is"
  , "  prelude.select (level + atLeastZero elapsed * n > n * period) (n * period) (level + atLeastZero elapsed * n)"
  , "end function"
  , ""
  , "function tokenBucketDecide (n :: Integer where n >= 1) (period :: Integer where period >= 1) (level :: Integer) (now :: Integer) -> Step TokenBucket is"
  , "  prelude.select (level >= period)"
  , "    (Step record{ state = (TokenBucket record{ level = (level - period) , last = now}) , gate = Admit})"
  , "    (Step record{ state = (TokenBucket record{ level = level , last = now}) , gate = (WaitFor (ceilingQuotient (period - level) n))})"
  , "end function"
  , ""
  , "function tokenBucketAdmit (n :: Integer where n >= 1) (period :: Integer where period >= 1) (state :: TokenBucket) (now :: Integer) -> Step TokenBucket is"
  , "  first matching case of state :"
  , "  when TokenBucket record{ level = level , last = last} then tokenBucketDecide n period (refilled n period level (now - last)) now"
  , "  end case"
  , "end function"
  , ""
  , "-- Fixed window: at most n calls in each period-long window."
  , "type FixedWindow is a record{  window :: Integer count :: Integer} end type"
  , ""
  , "function fixedWindowStart (n :: Integer) (period :: Integer) (now :: Integer) -> FixedWindow is FixedWindow record{ window = (-1) , count = 0} end function"
  , ""
  , "function fixedWindowDecide (n :: Integer) (period :: Integer) (window :: Integer) (count :: Integer) (now :: Integer) -> Step FixedWindow is"
  , "  prelude.select (count < n)"
  , "    (Step record{ state = (FixedWindow record{ window = window , count = (count + 1)}) , gate = Admit})"
  , "    (Step record{ state = (FixedWindow record{ window = window , count = count}) , gate = (WaitFor (atLeastZero ((window + 1) * period - now)))})"
  , "end function"
  , ""
  , "function fixedWindowAdmit (n :: Integer) (period :: Integer where period >= 1) (state :: FixedWindow) (now :: Integer) -> Step FixedWindow is"
  , "  first matching case of state :"
  , "  when FixedWindow record{ window = window , count = count} then"
  , "      prelude.select (prelude.quot (atLeastZero now) period = window)"
  , "        (fixedWindowDecide n period window count now)"
  , "        (fixedWindowDecide n period (prelude.quot (atLeastZero now) period) 0 now)"
  , "  end case"
  , "end function"
  , ""
  , "-- Sliding window: at most n calls in any period-long span. The state keeps"
  , "-- the times of the calls admitted in the last period, oldest first."
  , "type SlidingWindow is a record{  times :: List Integer} end type"
  , ""
  , "function slidingWindowStart (n :: Integer) (period :: Integer) (now :: Integer) -> SlidingWindow is SlidingWindow record{ times = []} end function"
  , ""
  , "function recent (times :: List Integer) (since :: Integer) -> List Integer is"
  , "  first matching case of times :"
  , "  when Nil then times"
  , "  when Cons t rest then prelude.select (t > since) times (recent rest since)"
  , "  end case"
  , "end function"
  , ""
  , "function appended (times :: List Integer) (time :: Integer) -> List Integer is"
  , "  first matching case of times :"
  , "  when Nil then Cons time Nil"
  , "  when Cons t rest then Cons t (appended rest time)"
  , "  end case"
  , "end function"
  , ""
  , "function oldest (times :: List Integer) (fallback :: Integer) -> Integer is"
  , "  first matching case of times :"
  , "  when Nil then fallback"
  , "  when Cons t rest then t"
  , "  end case"
  , "end function"
  , ""
  , "function slidingWindowDecide (n :: Integer) (period :: Integer) (times :: List Integer) (now :: Integer) -> Step SlidingWindow is"
  , "  prelude.select (prelude.length times < n)"
  , "    (Step record{ state = (SlidingWindow record{ times = (appended times now)}) , gate = Admit})"
  , "    (Step record{ state = (SlidingWindow record{ times = times}) , gate = (WaitFor (atLeastZero (oldest times now + period - now)))})"
  , "end function"
  , ""
  , "function slidingWindowAdmit (n :: Integer) (period :: Integer) (state :: SlidingWindow) (now :: Integer) -> Step SlidingWindow is"
  , "  first matching case of state :"
  , "  when SlidingWindow record{ times = times} then slidingWindowDecide n period (recent times (now - period)) now"
  , "  end case"
  , "end function"
  , ""
  , "-- Leaky bucket: calls start one interval apart (period / n), waiting their turn."
  , "type LeakyBucket is a record{  next :: Integer} end type"
  , ""
  , "function leakyBucketStart (n :: Integer) (period :: Integer) (now :: Integer) -> LeakyBucket is LeakyBucket record{ next = now} end function"
  , ""
  , "function leakyBucketAdmit (n :: Integer where n >= 1) (period :: Integer where period >= 1) (state :: LeakyBucket) (now :: Integer) -> Step LeakyBucket is"
  , "  first matching case of state :"
  , "  when LeakyBucket record{ next = next} then"
  , "      prelude.select (next <= now)"
  , "        (Step record{ state = (LeakyBucket record{ next = (now + ceilingQuotient period n)}) , gate = Admit})"
  , "        (Step record{ state = (LeakyBucket record{ next = next}) , gate = (WaitFor (next - now))})"
  , "  end case"
  , "end function"
  , ""
  , "-- Circuit breaker: after `failures` failures within `window`, calls fail"
  , "-- for `cooldown`; then one trial call decides whether it closes again."
  , "type Breaker is one of | Closed  of type List Integer | Open  of type Integer | HalfOpen end type"
  , ""
  , "function breakerStart (now :: Integer) -> Breaker is Closed [] end function"
  , ""
  , "function breakerAdmit (state :: Breaker) (now :: Integer) -> Step Breaker is"
  , "  first matching case of state :"
  , "  when Closed failures then Step record{ state = state , gate = Admit}"
  , "  when Open until then prelude.select (now >= until) (Step record{ state = HalfOpen , gate = Admit}) (Step record{ state = state , gate = Reject})"
  , "  when HalfOpen then Step record{ state = state , gate = Reject}"
  , "  end case"
  , "end function"
  , ""
  , "function breakerRecord (failures :: Integer) (window :: Integer) (cooldown :: Integer) (state :: Breaker) (now :: Integer) (succeeded :: Bool) -> Breaker is"
  , "  first matching case of state :"
  , "  when Closed times then"
  , "      prelude.select succeeded state"
  , "        (prelude.select (prelude.length (appended (recent times (now - window)) now) >= failures)"
  , "          (Open (now + cooldown))"
  , "          (Closed (appended (recent times (now - window)) now)))"
  , "  when Open until then state"
  , "  when HalfOpen then prelude.select succeeded (Closed []) (Open (now + cooldown))"
  , "  end case"
  , "end function"
  , ""
  , "-- Bulkhead: at most n calls of the stage at once."
  , "type Bulkhead is a record{  running :: Integer} end type"
  , ""
  , "function bulkheadStart (n :: Integer) (now :: Integer) -> Bulkhead is Bulkhead record{ running = 0} end function"
  , ""
  , "function bulkheadAdmit (n :: Integer) (state :: Bulkhead) (now :: Integer) -> Step Bulkhead is"
  , "  first matching case of state :"
  , "  when Bulkhead record{ running = running} then prelude.select (running < n) (Step record{ state = (Bulkhead record{ running = (running + 1)}) , gate = Admit}) (Step record{ state = state , gate = (WaitFor 1000)})"
  , "  end case"
  , "end function"
  , ""
  , "function bulkheadRelease (state :: Bulkhead) -> Bulkhead is"
  , "  first matching case of state :"
  , "  when Bulkhead record{ running = running} then Bulkhead record{ running = (atLeastZero (running - 1))}"
  , "  end case"
  , "end function"
  , "end unit" ]
