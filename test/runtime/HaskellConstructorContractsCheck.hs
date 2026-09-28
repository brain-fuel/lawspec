module Main where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

assert :: String -> Bool -> IO ()
assert label condition = unless condition (error label)

accepted :: Either a b -> Bool
accepted (Right _) = True
accepted _ = False

rejected :: String -> Either S.ValidationFailure a -> IO ()
rejected fragment result = case result of
  Left (S.Rejected message) ->
    assert ("missing rejection context: " ++ message) (fragment `isInfixOf` message)
  _ -> error ("expected refinement rejection: " ++ fragment)

failed :: String -> Either S.ValidationFailure a -> IO ()
failed fragment result = case result of
  Left (S.EvaluationFailure message) ->
    assert ("missing failure context: " ++ message) (fragment `isInfixOf` message)
  _ -> error ("expected evaluation failure: " ++ fragment)

main :: IO ()
main = forM_ [32, 64] $ \bits -> do
  scope <- LS.newSymbolContext
  other <- LS.newSymbolContext
  let named name = S.Named name []
      box = S.Named "Box" [named "Int8"]
      number n = LS.SInteger "Int8" n
      value n = LS.SData "Box::Box" [number n]
      positive _ args fields width _ = case (args, fields) of
        ([S.Named "Int8" []], [LS.SInteger "Int8" n])
          | width == bits -> Right (n > 0)
        _ -> Left "lost generic type or machine profile"
      guarded _ _ fields _ _ = case fields of
        [LS.SInteger _ 0] -> Left "division by zero"
        _ -> Right True
      identity _ _ fields _ context = case fields of
        [symbol] -> Right (LS.equal symbol
          (maybe id LS.scopeSymbols context (LS.SSymbol "fixture" "same")))
        _ -> Left "invalid predicate fields"
      definitions =
        [ S.Definition "Box" 1
            [S.Constructor "Box::Box" [S.Field "value" (S.Parameter 0)]]
        , S.Definition "Identity" 0
            [S.Constructor "Identity::Identity" [S.Field "value" (named "Symbol")]]
        , S.Definition "Broken" 0 [S.Constructor "Broken::Broken" []]
        ]
      contracts =
        [ ("Box::Box", [positive, guarded])
        , ("Identity::Identity", [identity])
        , ("Broken::Broken", [\_ _ _ _ _ -> Left "evaluator marker"])
        ]
      create = S.createWithContracts definitions ["Int8", "Symbol"]
      schema = either error id (create contracts)
      validate = S.validateChecked (Just scope) schema
      identifier = LS.scopeSymbols scope (LS.SSymbol "fixture" "same")
      boxed = LS.SData "Identity::Identity" [identifier]
      idType = named "Identity"
  assert "missing contracts" (S.hasContracts schema)
  assert "valid generic constructor rejected" (accepted (validate box bits (value 1)))
  rejected "Box::Box predicate 1" (validate box bits (value 0))
  rejected "Box::Box predicate 1" (validate box bits (value (-1)))
  failed "Box::Box.value" (validate box bits (value 128))
  failed "wrong field count" (validate box bits (LS.SData "Box::Box" []))
  failed "machineBits" (validate box 16 (value 1))
  failed "Broken::Broken predicate 1: evaluator marker"
    (validate (named "Broken") bits (LS.SData "Broken::Broken" []))
  rejected "List[0]: Box::Box predicate 1"
    (validate (S.Named "List" [box]) bits (LS.SList [value 0]))
  assert "identity rejected" (accepted (validate idType bits boxed))
  rejected "predicate 1" (S.validateChecked (Just other) schema idType bits boxed)
  rejected "predicate 1" (S.validateChecked Nothing schema idType bits boxed)
  rejected "predicate 1" (validate idType bits
    (LS.SData "Identity::Identity"
      [LS.scopeSymbols scope (LS.SSymbol "other" "same")]))
  forM_
    [ (S.Named "List" [idType], LS.SList [boxed])
    , (S.Named "Maybe" [idType], LS.SData "Maybe::Just" [boxed])
    , (S.Named "Either" [box, idType], LS.SData "Either::Right" [boxed])
    , (S.Named "Nullable" [idType], LS.SPresent "Nullable" (Just boxed))
    , (S.Named "Optional" [idType], LS.SPresent "Optional" (Just boxed))
    ] $ \(ty, item) -> do
      assert "nested context lost" (accepted (validate ty bits item))
      rejected "predicate 1" (S.validateChecked (Just other) schema ty bits item)
  assert "construct context lost" (accepted
    (S.constructWith (Just scope) schema idType bits "Identity::Identity" [identifier]))
  assert "equality context lost"
    (S.equalWith (Just scope) schema idType bits boxed boxed == Right True)
  assert "match context or branch laziness lost"
    (S.matchWith (Just scope) schema idType bits boxed
      [("Identity::Identity", const True), ("unused", error "unselected branch")] == Right True)
  assert "unknown predicate registration accepted"
    (not (accepted (create [("missing", [])])))
  assert "duplicate predicate registration accepted"
    (not (accepted (create (contracts ++ take 1 contracts))))
  let legacy = either error id (S.create definitions ["Int8", "Symbol"])
  assert "legacy metadata gained constraints"
    (not (S.hasContracts legacy) && accepted (S.validate legacy box bits (value 0)))
  putStrLn ("Haskell constructor contracts passed: " ++ show bits)
