-- | Lets moved out of the positions that nest them, so a JVM expression is a
-- block of declarations rather than one closure per binder. A let in a let's
-- value comes first (let x = (let y = a in b) in c is let y = a in let x = b
-- in c), and a let in a constructor's argument comes before the
-- constructor when every earlier argument is a local or a constant, so
-- nothing evaluates in a different order. A let in a match's scrutinee comes
-- before the match. Binders are fresh in Core, so no
-- name is captured.
module LawSpec.JvmLets (flattenLets) where

import LawSpec.Core

flattenLets :: Expr -> Expr
flattenLets e = case expressionNode e of
  Let binder value body -> hoist (flattenLets value) (\v -> e { expressionNode = Let binder v (flattenLets body) })
  Construct tag args ->
    let args' = map flattenLets args
    in case break isLet args' of
      (before, letArg : after) | all simple before ->
        case expressionNode letArg of
          Let b v inner -> flattenLets (letArg { expressionNode = Let b v (e { expressionNode = Construct tag (before ++ [inner] ++ after) }) })
          _ -> e { expressionNode = Construct tag args' }
      _ -> e { expressionNode = Construct tag args' }
  -- match (let y = a in s) is let y = a in match s.
  Match _ _ -> let e' = mapChildren flattenLets e in case expressionNode e' of
    Match scrutinee branches -> hoist scrutinee (\s -> e' { expressionNode = Match s branches })
    _ -> e'
  _ -> mapChildren flattenLets e
  where
    -- let x = (let y = a in b) in c: y's let first.
    hoist value rebuild = case expressionNode value of
      Let b v inner -> value { expressionNode = Let b v (hoist inner rebuild) }
      _ -> rebuild value
    isLet a = case expressionNode a of
      Let {} -> True
      _ -> False
    simple a = case expressionNode a of
      Local _ -> True
      Constant _ -> True
      _ -> False
