-- | A law never releases a resource it takes, directly or through what it
-- calls: each case releases its resources when it ends, so a law that also
-- released one could use it after its release.
--
-- The check is a conservative data-flow analysis over Core, not a flow type.
-- A value is derived from a resource when it is the resource or is computed
-- from one (a let, a match field or a collection element bound from an
-- expression that mentions it). A call releases when it calls an operation of
-- the resource's release clause, or a checked definition or spec handler
-- clause that may release one of its arguments, with an argument derived from
-- the resource. Definitions that may release are found as a fixed point over
-- the whole program, so a resource handed down any chain of checked
-- definitions is caught. The analysis over-approximates: a call that passes a
-- derived value to a releasing definition is rejected even when that branch
-- never runs. Native adapters other than the release clause's own are opaque
-- and trusted not to release.
module LawSpec.Release (checkResourceReleases) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common (Diagnostic(..))
import LawSpec.Core

-- | One diagnostic for each law that may release a resource it takes.
checkResourceReleases :: Program -> Either [Diagnostic] ()
checkResourceReleases program =
  case concatMap lawProblems [p | u <- programUnits program, p <- unitProperties u, not (null (propertyResources p))] of
    [] -> Right ()
    problems -> Left problems
  where
    definitions = M.fromList [(declarationId (definitionDeclaration d), d) | u <- programUnits program, d <- unitDefinitions u]
    -- Each operation's spec handler clauses, from every handler of its ability.
    clauses = M.fromListWith (++)
      [ (operationId (Operation (handlerAbility h) op), [clause])
      | u <- programUnits program, h <- unitHandlers u, (op, clause) <- handlerClauses h ]
    lawProblems p =
      [ Diagnostic "resource"
          (propertyName p ++ " releases " ++ binderName (resourceBinder r) ++
           ", directly or through what it calls, but a law's resources are released after each case, so it could use " ++
           binderName (resourceBinder r) ++ " after its release")
          (Just (propertyLocation p))
      | r <- propertyResources p
      , let (callees, operations) = releaseActions r
            known = S.union callees (releasers callees operations)
            releases = releasing known (S.union operations (operationsOf known))
            tainted = S.singleton (binderId (resourceBinder r))
      , any (releases tainted) (concatMap propositionExpressions (propertyBody p : concatMap exampleExpectations (propertyExamples p))) ]
    -- What a release clause calls: the callees and operations that release.
    releaseActions r = go (resourceRelease r)
      where
        go e = let (cs, os) = unzip (map go (children e)) in case expressionNode e of
          ExternalCall callee _ -> (S.insert callee (S.unions cs), S.unions os)
          Perform op _ -> (S.unions cs, S.insert (operationId op) (S.unions os))
          _ -> (S.unions cs, S.unions os)
    -- Checked definitions (spec handler clauses among them) that may release
    -- one of their arguments: the least fixed point from the release actions.
    releasers callees operations = grow S.empty
      where
        grow found =
          let known = S.union callees found
              next = S.fromList
                [ i | (i, d) <- M.toList definitions, not (i `S.member` found)
                , releasing known (S.union operations (operationsOf known)) (S.fromList (map binderId (definitionArguments d))) (definitionBody d) ]
          in if S.null next then found else grow (S.union found next)
    -- Operations a spec handler clause among these releasers answers.
    operationsOf known = S.fromList [op | (op, cs) <- M.toList clauses, any (`S.member` known) cs]

-- | Whether an expression calls a releasing callee or operation with an
-- argument derived from the tainted locals.
releasing :: S.Set Id -> S.Set Id -> S.Set Id -> Expr -> Bool
releasing callees operations = go
  where
    go tainted e = case expressionNode e of
      ExternalCall callee args
        | callee `S.member` callees, any (mentions tainted) args -> True
      Perform op args
        | operationId op `S.member` operations, any (mentions tainted) args -> True
      Let binder value body -> go tainted value || go (bindIf value [binder] tainted) body
      Match value cases -> go tainted value || or [go (bindIf value (caseBinders c) tainted) (caseBody c) | c <- cases]
      AllElements value binder body -> go tainted value || go (bindIf value [binder] tainted) body
      AllPayloads value predicates -> go tainted value || or [go (bindIf value [b] tainted) x | (b, x) <- predicates]
      _ -> any (go tainted) (children e)
    bindIf value binders tainted
      | mentions tainted value = S.union tainted (S.fromList (map binderId binders))
      | otherwise = tainted

-- | Whether an expression mentions a tainted local anywhere: its value may be
-- derived from one.
mentions :: S.Set Id -> Expr -> Bool
mentions tainted e = case expressionNode e of
  Local i -> i `S.member` tainted
  _ -> any (mentions tainted) (children e)
