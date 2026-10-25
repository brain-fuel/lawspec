-- | Lets moved out of the positions that nest them, so a JVM expression is a
-- block of declarations rather than one closure per binder. A let in a let's
-- value comes first (let x = (let y = a in b) in c is let y = a in let x = b
-- in c), and a let in a constructor's argument comes before the
-- constructor when every earlier argument is a local or a constant, so
-- nothing evaluates in a different order. A let in a match's scrutinee comes
-- before the match. Binders are fresh in Core, so no
-- name is captured.
module LawSpec.JvmLets (flattenLets, flattenStrictLets) where

import LawSpec.Core

flattenLets :: Expr -> Expr
flattenLets = flattenLetsIn False

-- | As flattenLets, and a let leaves any strictly evaluated argument list
-- (a call's, an operator's, a conversion's) on the same condition, so Java,
-- whose lines Checkstyle bounds, nests a block per binder far less.
flattenStrictLets :: Expr -> Expr
flattenStrictLets = flattenLetsIn True

flattenLetsIn :: Bool -> Expr -> Expr
flattenLetsIn strict = flatten
  where
  flatten e = case expressionNode e of
    Let binder value body -> hoist (flatten value) (\v -> e { expressionNode = Let binder v (flatten body) })
    Construct tag args -> arguments args (\xs -> e { expressionNode = Construct tag xs })
    _ | strict, Just (args, rebuild) <- strictArguments e -> arguments args rebuild
    -- match (let y = a in s) is let y = a in match s.
    Match _ _ -> let e' = mapChildren flatten e in case expressionNode e' of
      Match scrutinee branches -> hoist scrutinee (\s -> e' { expressionNode = Match s branches })
      _ -> e'
    _ -> mapChildren flatten e
  arguments args rebuild =
    let args' = map flatten args
    in case break isLet args' of
      (before, letArg : after) | all simple before ->
        case expressionNode letArg of
          Let b v inner ->
            let body = rebuild (before ++ [inner] ++ after)
            in flatten (letArg { expressionType = expressionType body, expressionNode = Let b v body })
          _ -> rebuild args'
      _ -> rebuild args'
  -- The nodes whose children are all evaluated, in order, before the node.
  strictArguments e = case expressionNode e of
    ExternalCall n args -> Just (args, \xs -> e { expressionNode = ExternalCall n xs })
    Perform op args -> Just (args, \xs -> e { expressionNode = Perform op xs })
    Helper Concurrently _ -> Nothing
    Helper name args -> Just (args, \xs -> e { expressionNode = Helper name xs })
    Binary op evidence a b -> Just ([a, b], \xs -> case xs of [a', b'] -> e { expressionNode = Binary op evidence a' b' }; _ -> e)
    Unary op a -> Just ([a], \xs -> case xs of [a'] -> e { expressionNode = Unary op a' }; _ -> e)
    Convert conversion ty a -> Just ([a], \xs -> case xs of [a'] -> e { expressionNode = Convert conversion ty a' }; _ -> e)
    _ -> Nothing

  -- let x = (let y = a in b) in c: y's let first.
  hoist value rebuild = case expressionNode value of
    Let b v inner ->
      let body = hoist inner rebuild
      in value { expressionType = expressionType body, expressionNode = Let b v body }
    _ -> rebuild value
  isLet a = case expressionNode a of
    Let {} -> True
    _ -> False
  simple a = case expressionNode a of
    Local _ -> True
    Constant _ -> True
    _ -> False
