-- | Recognise closed scalar List data without evaluating a term. Backends
-- whose List representation is an array can emit the same ordered leaves
-- directly, while retaining each leaf's ordinary checked rendering.
-- ref:DEC-planned-generation ref:DEC-typed-core-boundary
module LawSpec.Core.ListLiteral (constantListElements) where

import LawSpec.Core

constantListElements :: Expr -> Maybe [Expr]
constantListElements expression = case expressionType expression of
  ty@(Constructor "List" [TypeArgument element]) -> walk ty element expression
  _ -> Nothing
  where
    walk ty element term
      | expressionType term /= ty = Nothing
      | otherwise = case expressionNode term of
          Construct (Id "List::Nil") [] -> Just []
          Construct (Id "List::Cons") [first, rest]
            | expressionType first == element
            , Constant _ <- expressionNode first -> (first :) <$> walk ty element rest
          _ -> Nothing
