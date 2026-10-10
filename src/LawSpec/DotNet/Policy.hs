-- | Workflow policies on .NET: a definition with a stage policy runs through
-- the workflow runtime (retries, timeouts, gates, caches, compensation and
-- hedging), with its callbacks calling the generated resilience entries, so
-- admission logic is shared by every target. ref:DEC-typed-core-boundary
-- ref:DEC-domain-modeling-primitives
module LawSpec.DotNet.Policy (wrapDefinition, usesPolicies, withTestRuntime) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Policy as P
import LawSpec.DotNet.Code
import LawSpec.DotNet.Entries
import Control.Monad (forM)

-- | Whether a program has workflow policies, so its tests run on the test
-- runtime.
usesPolicies :: [C.Unit] -> Bool
usesPolicies units = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)

-- | A law's case on the workflow test runtime: virtual time, no gates.
withTestRuntime :: [C.Unit] -> Ty -> Expr -> Expr
withTestRuntime units ty body
  | usesPolicies units = call "Workflow" "withTestRuntime" [Lambda [] ty body]
  | otherwise = body

long :: Integer -> Expr
long n = Raw (show n ++ "L") (show n ++ "L")

none :: Expr
none = Raw "None" "null"

optional :: (a -> Expr) -> Maybe a -> Expr
optional = maybe none . (\f v -> call "Runtime" "some" [f v])

wrapDefinition :: [C.Unit] -> Expr -> Expr -> [Expr] -> C.Definition -> Expr -> Either String Expr
wrapDefinition units schema symbols arguments definition body = case C.definitionPolicy definition of
  Nothing -> pure body
  Just policy | P.policyFrame policy -> pure (call "Workflow" "runWorkflow" [schema, Lambda [] tValue body])
  Just policy -> do
    config <- policyExpr policy
    let input = case arguments of value : _ -> value; [] -> Raw "Value.Unit" "V.Unit"
    pure (call "Workflow" "runStage" [schema, config, Lambda [] tValue body, input])
  where
    callEntry identity values = case lookup identity (entries units) of
      Nothing -> Left ("missing .NET policy callback: " ++ C.idText identity)
      Just e -> pure (entryCall e (schema : symbols : values))
    callback parameters identity values = Lambda [(p, tValue) | p <- parameters] tValue <$> callEntry identity values
    integer n = call "Runtime" "integer" [Str (show n)]
    waitExpr wait = case wait of
      Nothing -> call "Policy" "noWait" []
      Just Nothing -> call "Policy" "forever" []
      Just (Just delay) -> call "Policy" "within" [long delay]
    policyExpr policy = do
      retry <- case P.policyRetry policy of
        Nothing -> pure none
        Just r -> do
          strategy <- case P.retryStrategy r of
            P.Immediate -> pure (call "Policy" "immediate" [])
            P.Fixed delay -> pure (call "Policy" "fixedDelay" [long delay])
            P.Linear delay step -> pure (call "Policy" "linear" [long delay, long step])
            P.Exponential delay factor cap -> pure (call "Policy" "exponential" [long delay, long factor, optional long cap])
            P.Fibonacci delay -> pure (call "Policy" "fibonacciDelay" [long delay])
            P.Custom identity -> call "Policy" "custom" . pure <$> callback ["attempt", "error", "previous"] identity
              [Var "attempt", Var "error", Var "previous"]
          condition <- case P.retryWhen r of
            Nothing -> pure none
            Just identity -> (\f -> call "Runtime" "some" [f]) <$> callback ["error"] identity [Var "error"]
          let jitter = case P.retryJitter r of
                P.NoJitter -> "none"; P.FullJitter -> "full"
                P.EqualJitter -> "equal"; P.DecorrelatedJitter -> "decorrelated"
          pure (call "Runtime" "some" [call "Policy" "retry" [strategy, long (P.retryAttempts r), call "Policy" "jitterOf" [Str jitter], condition]])
      compensate <- case P.policyCompensate policy of
        Nothing -> pure none
        Just identity -> (\f -> call "Runtime" "some" [f]) <$> callback ["value"] identity [Var "value"]
      gates <- policyGates policy
      pure (call "Policy" "stage" [Str (C.idText (C.declarationId (C.definitionDeclaration definition))),
        Str (P.policyStage policy), retry, optional long (P.policyTimeout policy),
        ListOf (Ty "Policy.Gate" "Policy.Gate") gates, optional long (P.policyCache policy), compensate,
        BoolLit (not (null (P.policyFailures policy))),
        optional (\h -> TupleOf [long (P.hedgeDelay h), long (P.hedgeMost h)]) (P.policyHedge policy)])
    policyGates policy = do
      breaker <- forM (P.policyBreaker policy) $ \b -> do
        start <- callback ["now"] (P.breakerStart b) [Var "now"]
        admit <- callback ["state", "now"] (P.breakerAdmit b) [Var "state", Var "now"]
        finish <- callback ["state", "now", "succeeded"] (P.breakerRecord b)
          (map integer [P.breakerFailures b, P.breakerWindow b, P.breakerCooldown b] ++ [Var "state", Var "now", Var "succeeded"])
        pure (call "Policy" "breaker" [start, admit, finish])
      limit <- forM (P.policyLimit policy) $ \l -> do
        let numbers = map integer [P.limitCount l, P.limitPeriod l]
        start <- callback ["now"] (P.limitStart l) (numbers ++ [Var "now"])
        admit <- callback ["state", "now"] (P.limitAdmit l) (numbers ++ [Var "state", Var "now"])
        pure (call "Policy" "limit" [start, admit, waitExpr (P.limitWait l)])
      bulkhead <- forM (P.policyBulkhead policy) $ \b -> do
        let count = integer (P.bulkheadLimit b)
        start <- callback ["now"] (P.bulkheadStart b) [count, Var "now"]
        admit <- callback ["state", "now"] (P.bulkheadAdmit b) [count, Var "state", Var "now"]
        finish <- callback ["state", "now", "succeeded"] (P.bulkheadRelease b) [Var "state"]
        pure (call "Policy" "bulkhead" [start, admit, finish, waitExpr (P.bulkheadWait b)])
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
