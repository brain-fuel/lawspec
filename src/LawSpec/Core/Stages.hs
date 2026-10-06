-- | What a workflow stage's runtime returns when a policy fails the call: the
-- stage's Left of a StageFailure, as typed Core expressions, so each target
-- renders them as it renders any value of the stage's result type.
module LawSpec.Core.Stages (stageFailures) where

import LawSpec.Core
import LawSpec.Core.Policy (policyFailures)

-- | Each failure a stage's policies can cause, with the stage's result for it.
stageFailures :: Definition -> [(String, Expr)]
stageFailures d = case (definitionPolicy d, snd (functionType (declarationType declaration))) of
  (Just policy, resultType@(Constructor "Either" [TypeArgument failureType, _])) ->
    [ (kind, node resultType (Construct (Id "Either::Left") [node failureType (Construct (Id (constructor failureType kind)) [])]))
    | kind <- policyFailures policy ]
  _ -> []
  where
    declaration = definitionDeclaration d
    node t n = Expr t n (GeneratedFrom (declarationId declaration))
    constructor failureType kind = case failureType of
      Constructor name _ -> name ++ "::" ++ kind
      _ -> kind
