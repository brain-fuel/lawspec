module Main where

import Control.Monad (unless)
import Data.Bits (finiteBitSize)
import Data.List (isInfixOf)
import Data.Ratio ((%))
import System.Environment (getArgs)
import qualified LawSpecData as D
import qualified LawSpecRuntime as LS
import qualified LawSpecDefinitions.Native.Fields as F

require :: String -> Bool -> IO ()
require label condition = unless condition (error label)

accepted :: Either String a -> IO ()
accepted = either error (const (pure ()))

rejected :: Either String a -> IO ()
rejected result = case result of
  Left message -> require message
    ("constructor field contract rejected" `isInfixOf` message &&
      not ("division by zero" `isInfixOf` message))
  Right _ -> error "invalid native field accepted"

main :: IO ()
main = do
  [profile] <- getArgs
  let bits = read profile :: Int
  symbols <- LS.newSymbolContext
  other <- LS.newSymbolContext
  require "undefined literal" (F.missing symbols () == Right LS.UndefinedValue)
  require "present null literal"
    (F.presentNull symbols () == Right (LS.OptionalValue LS.NullValue))
  require "nested present literal"
    (F.presentValue symbols () == Right (LS.OptionalValue (LS.NullableValue 7)))
  require "promoted gap arithmetic"
    (F.inverseGap symbols (D.GapGap (-128) 127) == Right (1 % 255))
  rejected (F.inverseGap symbols (D.GapGap 0 0))
  rejected (F.inverseGap symbols (D.GapGap 127 (-128)))
  accepted (F.echoBucket symbols (D.BucketBucket [1]))
  rejected (F.echoBucket symbols (D.BucketBucket []))
  accepted (F.echoPositives symbols (D.PositivesPositives [1, 127]))
  rejected (F.echoPositives symbols (D.PositivesPositives [1, 0]))
  accepted (F.echoChoice symbols (D.ChoiceAccepted 1))
  accepted (F.echoChoice symbols (D.ChoiceRejected (read "\"no\"")))
  rejected (F.echoChoice symbols (D.ChoiceAccepted 0))
  accepted (F.echoGuarded symbols (D.GuardedGuarded 1))
  rejected (F.echoGuarded symbols (D.GuardedGuarded 0))
  rejected (F.echoGuarded symbols (D.GuardedGuarded (-1)))
  let identity = LS.ScopedSymbol symbols "fixture" "same"
      box = D.IdentityIdentity identity
  require "identity changed" (F.echoIdentity symbols box == Right box)
  rejected (F.echoIdentity other box)
  rejected (F.echoIdentity symbols (D.IdentityIdentity (LS.ScopedSymbol symbols "other" "same")))
  accepted (F.echoList symbols [Nothing, Just box])
  accepted (F.echoIdentityBucket symbols (D.BucketBucket [box]))
  rejected (F.echoIdentityBucket other (D.BucketBucket [box]))
  accepted (F.echoPresent symbols (D.PresentPresent (Just box)))
  rejected (F.echoPresent symbols (D.PresentPresent Nothing))
  mapM_ (\value -> require "presence state changed" (F.echoNested symbols value == Right value))
    [LS.UndefinedValue, LS.OptionalValue LS.NullValue,
     LS.OptionalValue (LS.NullableValue box)]
  if bits == finiteBitSize (0 :: Int) then do
    accepted (F.echoMachine symbols (D.MachineMachine 1))
    rejected (F.echoMachine symbols (D.MachineMachine 0))
  else case F.echoMachine symbols (D.MachineMachine 1) of
    Left message -> require message ("architecture" `isInfixOf` message)
    Right _ -> error "native architecture mismatch accepted"
  putStrLn ("Haskell native constructor contracts passed: " ++ profile)
