module Main where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

fails :: String -> Either String a -> IO ()
fails fragment (Left message) =
  assert ("missing context: " ++ message) (fragment `isInfixOf` message)
fails fragment _ = error ("expected failure: " ++ fragment)

n :: String -> [S.TypeRef] -> S.TypeRef
n = S.Named

integer :: S.TypeRef
integer = n "Int8" []

a, b :: S.TypeRef
a = S.Parameter 0
b = S.Parameter 1

c :: String -> [S.TypeRef] -> S.Constructor
c tag types = S.Constructor tag
  [S.Field ("field" ++ show index) ty
  | (index, ty) <- zip [0 :: Int ..] types]

number :: Integer -> LS.Scalar
number = LS.SInteger "Int8"

positive, negative, unused :: LS.Scalar -> Either String LS.Scalar
positive (LS.SInteger _ value) = Right (LS.SBool (value > 0))
positive _ = Left "integer required"
negative (LS.SInteger _ value) = Right (LS.SBool (value < 0))
negative _ = Left "integer required"
unused _ = error "unstored or short-circuited callback evaluated"

schema :: S.Schema
schema = either error id $ S.createWithContracts
  [ S.Definition "Tree" 1
      [c "Tree::Leaf" [a, integer], c "Tree::Forest" [n "List" [n "Tree" [a]]]]
  , S.Definition "Pair" 2 [c "Pair::Pair" [a, b]]
  , S.Definition "Nest" 1
      [c "Nest::Stop" [a], c "Nest::Next" [n "Nest" [n "List" [a]]]]
  , S.Definition "Phantom" 1 [c "Phantom::Tag" []]
  , S.Definition "A" 2 [c "A::End" [a], c "A::Next" [n "B" [b, a]]]
  , S.Definition "B" 2 [c "B::End" [a], c "B::Next" [n "A" [b, a]]]
  , S.Definition "Wrapped" 1
      [c "Wrapped::Wrap" [n "Nullable" [n "Optional" [n "List" [a]]]]]
  , S.Definition "Checked" 1 [c "Checked::Value" [a]]
  , S.Definition "SymbolBox" 1 [c "SymbolBox::Value" [a]]
  ] ["Int8", "Bool", "Symbol"]
  [ ("Checked::Value", [\_ _ fields _ _ ->
        LS.truth <$> positive (head fields)])
  , ("SymbolBox::Value", [\_ _ fields _ scope -> Right
        (LS.equal (head fields)
          (maybe id LS.scopeSymbols scope
            (LS.SSymbol "shared" "description")))])
  ]

main :: IO ()
main = forM_ [32, 64] $ \bits -> do
  scope <- LS.newSymbolContext
  let tree = n "Tree" [integer]
      check ty value predicates expected = assert ("traversal: " ++ show ty)
        (S.allPayloadsWith (Just scope) schema ty bits value predicates ==
          Right (LS.SBool expected))
      leaf value = LS.SData "Tree::Leaf" [number value, number (-128)]
      forest value = LS.SData "Tree::Forest" [LS.SList [value]]
      call ty value = S.allPayloads schema ty bits value
  forM_ [0, 1] $ \value -> do
    check tree (iterate forest (leaf value) !! 40) [positive] (value > 0)
    check (n "Pair" [integer, integer])
      (LS.SData "Pair::Pair" [number 1, number (-value)])
      [positive, negative] (value > 0)
    check (n "A" [integer, integer])
      (LS.SData "A::Next" [LS.SData "B::End" [number (-value)]])
      [positive, negative] (value > 0)
    check (n "Nest" [integer])
      (LS.SData "Nest::Next"
        [LS.SData "Nest::Stop" [LS.SList [number 1, number value]]])
      [positive] (value > 0)
  check (n "Phantom" [integer]) (LS.SData "Phantom::Tag" []) [unused] True
  check (n "List" [integer]) (LS.SList []) [unused] True
  check (n "Maybe" [integer]) (LS.SData "Maybe::Nothing" []) [unused] True
  check (n "Maybe" [integer]) (LS.SData "Maybe::Just" [number 1])
    [positive] True
  check (n "Either" [integer, integer])
    (LS.SData "Either::Left" [number 1]) [positive, unused] True
  check (n "Either" [integer, integer])
    (LS.SData "Either::Right" [number (-1)]) [unused, negative] True
  forM_ [LS.SPresent "Nullable" Nothing,
         LS.SPresent "Nullable" (Just (LS.SPresent "Optional" Nothing))] $
    \value -> check (n "Wrapped" [integer])
      (LS.SData "Wrapped::Wrap" [value]) [unused] True
  check (n "Wrapped" [integer])
    (LS.SData "Wrapped::Wrap" [LS.SPresent "Nullable"
      (Just (LS.SPresent "Optional" (Just (LS.SList [number 0]))))])
    [positive] False
  check (n "List" [n "Optional" [integer]])
    (LS.SList [LS.SPresent "Optional" Nothing])
    [\value -> case value of
      LS.SPresent "Optional" Nothing -> Right (LS.SBool True)
      _ -> Left "whole argument was flattened"] True
  check (n "Pair" [integer, integer])
    (LS.SData "Pair::Pair" [number 0, number 1]) [positive, unused] False
  check (n "List" [integer]) (LS.SList [number 0, number 1])
    [\value -> if value == number 0 then Right (LS.SBool False)
      else unused value] False
  fails "Tree::Leaf.field0: callback fault"
    (call tree (leaf 1) [\_ -> Left "callback fault"])
  fails "Tree::Leaf.field0: Bool required"
    (call tree (leaf 1) [\_ -> Right (number 1)])
  fails "arity" (call tree (leaf 1) [])
  fails "require a data type" (call integer (number 1) [])
  fails "Tree::Leaf.field1"
    (call tree (LS.SData "Tree::Leaf" [number 1, number 128]) [unused])
  fails "constructor field contract rejected"
    (call (n "Checked" [integer])
      (LS.SData "Checked::Value" [number 0]) [unused])
  -- Even a rejected first callback cannot hide invalid later storage.
  fails "List[1]" (call (n "List" [integer])
    (LS.SList [number 0, number 128]) [positive])
  let symbol identity =
        LS.scopeSymbols scope (LS.SSymbol identity "description")
  check (n "SymbolBox" [n "Symbol" []])
    (LS.SData "SymbolBox::Value" [symbol "shared"])
    [\value -> Right (LS.SBool (LS.equal value (symbol "shared")))] True
  forM_ ["shared", "different"] $ \identity ->
    check (n "List" [n "Symbol" []]) (LS.SList [symbol identity])
      [\value -> Right (LS.SBool (LS.equal value (symbol "shared")))]
      (identity == "shared")
  putStrLn ("Haskell payload checks pass at " ++ show bits ++ " bits")
