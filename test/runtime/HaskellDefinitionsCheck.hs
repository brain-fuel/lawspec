module Main where

import Control.Monad (unless)
import Data.Bits (finiteBitSize)
import Data.List (isInfixOf)
import Data.Ratio ((%))
import System.Environment (getArgs)
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified LawSpecDefinitionBodies as Bodies
import qualified LawSpecDefinitions.Example.Total as Total

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label)

reject :: String -> String -> Either String a -> IO ()
reject context detail value = case value of
  Left message -> check message (context `isInfixOf` message && detail `isInfixOf` message)
  Right _ -> fail ("expected rejection: " ++ context)

main :: IO ()
main = do
  [profile] <- getArgs
  let bits = read profile
  symbols <- LS.newSymbolContext
  other <- LS.newSymbolContext
  check "recursive length and forward calls"
    (Total.size symbols [] == Right 0 && Total.forward symbols [1, 2, 3] == Right 3)
  check "integer promotion"
    (Total.sumList symbols [127, 127] == Right 254 && Total.increment symbols 127 == Right 128)
  check "guard and signed remainder"
    (Total.divisible symbols 5 0 == Right False &&
     Total.divisible symbols (-6) 3 == Right True &&
     Total.divisible symbols (-5) 3 == Right False)
  check "recursive products"
    (Total.sumTree symbols (Data.TreeBranch (Data.TreeLeaf 127) (Data.TreeLeaf 127)) == Right 254)
  check "Maybe payload"
    (Total.maybeDefault symbols Nothing == Right 0 && Total.maybeDefault symbols (Just 127) == Right 127)
  check "raw UTF-16 units" (Total.raw symbols [0xd800, 0xdc00, 0xffff] == Right [0xd800, 0xdc00, 0xffff])
  mapM_ (\value -> check "nested absence" (Total.absent symbols value == Right value))
    [LS.UndefinedValue, LS.OptionalValue LS.NullValue, LS.OptionalValue (LS.NullableValue 127)]
  first <- either fail pure (Total.symbol symbols ())
  again <- either fail pure (Total.symbol symbols ())
  distinct <- either fail pure (Total.symbol other ())
  check "fixture Symbol context" (first == again && first /= distinct)
  check "exact decimal" (Total.exact symbols (LS.Decimal (1 % 10)) == Right (LS.Decimal (3 % 10)))
  reject "example.total::exact" "Decimal" (Total.exact symbols (LS.Decimal (1 % 3)))
  check "sum payloads"
    (Total.either symbols (Left 127) == Right (Left 127) && Total.either symbols (Right True) == Right (Right True))
  if bits == finiteBitSize (0 :: Int) then do
    check "machine integer" (Total.machine symbols maxBound == Right maxBound)
    check "machine field" (Total.architecture symbols (Data.ArchitectureNative maxBound) == Right (Data.ArchitectureNative maxBound))
  else do
    reject "example.total::machine" "machineBits" (Total.machine symbols 1)
    reject "example.total::architecture" "machineBits" (Total.architecture symbols Data.ArchitectureUnused)
  check "portable logical machine integer"
    (Bodies.evaluate9 symbols (LS.SInteger "IntSize" (2 ^ (bits - 1) - 1)) ==
      Right (LS.SInteger "IntSize" (2 ^ (bits - 1) - 1)))
  reject "example.total::increment" "" (Bodies.evaluate5 symbols (LS.SInteger "Int8" 128))
  reject "example.total::divisible" "" (Bodies.evaluate4 symbols (LS.SBool True) (LS.SInteger "BigInt" 0))
  reject "example.total::sumTree" "" (Bodies.evaluate2 symbols (LS.SData "bad" []))
  putStrLn ("Haskell native total definitions passed: " ++ profile)
