-- | Checked workflow policy callbacks. Gate transitions call the generated
-- resilience definitions, so admission logic is shared by every target.
-- ref:DEC-typed-core-boundary ref:DEC-domain-modeling-primitives
module LawSpec.BeamPolicy (wrapDefinition) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Policy as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamEffects as Effects
import Control.Monad (forM)

wrapDefinition :: [C.Unit] -> D.Doc -> D.Doc -> [D.Doc] -> C.Definition -> D.Doc -> Either String D.Doc
wrapDefinition units schema symbols arguments definition body = case C.definitionPolicy definition of
  Nothing -> pure body
  Just policy | P.policyFrame policy -> pure
    (E.remote "lawspec_beam_workflow" "run_workflow" [schema,E.lambda [] body])
  Just policy -> do
    config <- policyDoc policy
    let input = case arguments of value:_ -> value; [] -> E.atom "ls_unit"
    pure (E.remote "lawspec_beam_workflow" "run_stage" [schema,config,E.lambda [] body,input])
  where
    variable = D.text
    integer = D.text . show
    none = E.atom "none"
    optional make = maybe none make
    flag value = E.atom (if value then "true" else "false")
    object = E.record . map (\(key,value) -> (E.atom key,value))
    call identity values = case lookup identity (Effects.entries units) of
      Nothing -> Left ("missing BEAM policy callback: " ++ C.idText identity)
      Just name -> pure (E.remote "lawspec_definitions" name (schema:symbols:values))
    callback parameters identity values = E.lambda (map variable parameters) <$> call identity values
    waitDoc wait = case wait of
      Nothing -> none
      Just Nothing -> E.atom "infinity"
      Just (Just delay) -> integer delay
    policyDoc policy = do
      retry <- case P.policyRetry policy of
        Nothing -> pure none
        Just r -> do
          strategy <- case P.retryStrategy r of
            P.Immediate -> pure (E.atom "immediate")
            P.Fixed delay -> pure (E.tuple [E.atom "fixed",integer delay])
            P.Linear delay step -> pure (E.tuple [E.atom "linear",integer delay,integer step])
            P.Exponential delay factor cap -> pure
              (E.tuple [E.atom "exponential",integer delay,integer factor,optional integer cap])
            P.Fibonacci delay -> pure (E.tuple [E.atom "fibonacci",integer delay])
            P.Custom identity -> do
              decided <- call identity [variable "_LsAttempt",variable "_LsError",
                E.tuple [E.atom "ls_data",E.binary "lawspec.time::type::Duration::Duration",
                  E.array [variable "_LsPrevious"]]]
              pure (E.tuple [E.atom "custom",E.lambda (map variable ["_LsAttempt","_LsError","_LsPrevious"])
                (E.remote "lawspec_beam_policy" "retry_decision" [decided])])
          condition <- case P.retryWhen r of
            Nothing -> pure none
            Just identity -> callback ["_LsError"] identity [variable "_LsError"]
          let jitter = case P.retryJitter r of
                P.NoJitter -> "none"; P.FullJitter -> "full"
                P.EqualJitter -> "equal"; P.DecorrelatedJitter -> "decorrelated"
          pure (object [("strategy",strategy),("attempts",integer (P.retryAttempts r)),
            ("jitter",E.atom jitter),("when",condition)])
      compensate <- case P.policyCompensate policy of
        Nothing -> pure none
        Just identity -> callback ["_LsValue"] identity [variable "_LsValue"]
      gates <- policyGates policy
      pure (object [("key",E.binary (C.idText (C.declarationId (C.definitionDeclaration definition)))),
        ("stage",E.binary (P.policyStage policy)),("retry",retry),
        ("timeout",optional integer (P.policyTimeout policy)),("gates",E.array gates),
        ("cache",optional integer (P.policyCache policy)),("compensate",compensate),
        ("wraps",flag (not (null (P.policyFailures policy)))),
        ("hedge",optional (\h -> E.tuple [integer (P.hedgeDelay h),integer (P.hedgeMost h)]) (P.policyHedge policy))])
    policyGates policy = do
      breaker <- forM (P.policyBreaker policy) $ \b -> do
        start <- callback ["_LsNow"] (P.breakerStart b) [variable "_LsNow"]
        admit <- callback ["_LsState","_LsNow"] (P.breakerAdmit b) (map variable ["_LsState","_LsNow"])
        finish <- callback ["_LsState","_LsNow","_LsSucceeded"] (P.breakerRecord b)
          (map integer [P.breakerFailures b,P.breakerWindow b,P.breakerCooldown b] ++ map variable ["_LsState","_LsNow","_LsSucceeded"])
        pure (object [("kind",E.atom "breaker"),("start",start),("admit",admit),("finish",finish),("wait",none)])
      limit <- forM (P.policyLimit policy) $ \l -> do
        let numbers = map integer [P.limitCount l,P.limitPeriod l]
        start <- callback ["_LsNow"] (P.limitStart l) (numbers ++ [variable "_LsNow"])
        admit <- callback ["_LsState","_LsNow"] (P.limitAdmit l) (numbers ++ map variable ["_LsState","_LsNow"])
        pure (object [("kind",E.atom "limit"),("start",start),("admit",admit),("finish",none),("wait",waitDoc (P.limitWait l))])
      bulkhead <- forM (P.policyBulkhead policy) $ \b -> do
        let count = integer (P.bulkheadLimit b)
        start <- callback ["_LsNow"] (P.bulkheadStart b) [count,variable "_LsNow"]
        admit <- callback ["_LsState","_LsNow"] (P.bulkheadAdmit b) (count:map variable ["_LsState","_LsNow"])
        finish <- callback ["_LsState","_LsNow","_LsSucceeded"] (P.bulkheadRelease b) [variable "_LsState"]
        pure (object [("kind",E.atom "bulkhead"),("start",start),("admit",admit),("finish",finish),("wait",waitDoc (P.bulkheadWait b))])
      pure (maybe [] pure breaker ++ maybe [] pure limit ++ maybe [] pure bulkhead)
