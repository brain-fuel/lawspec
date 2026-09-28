module Main where

import Control.Monad (unless)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as Schema
import qualified LawSpecCodecs as Codec

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label)

main :: IO ()
main = do
  first <- LS.newSymbolContext
  second <- LS.newSymbolContext
  let literal = LS.SSymbol "fixture" "same description"
      a = LS.scopeSymbols first literal
      b = LS.scopeSymbols first literal
      c = LS.scopeSymbols second literal
      d = LS.scopeSymbols first (LS.SSymbol "other" "same description")
  check "same fixture context" (LS.equal a b)
  check "different context" (not (LS.equal a c))
  check "different fixture" (not (LS.equal a d))
  check "description does not affect identity"
    (LS.equal a (LS.scopeSymbols first (LS.SSymbol "fixture" "different")))
  check "unscoped symbol cannot collide" (not (LS.equal a literal))
  check "scope preserves an existing identity" (LS.equal a (LS.scopeSymbols second a))
  schema <- either fail pure (Schema.create [] (map LS.primitiveName LS.primitives))
  let symbolCodec = Codec.symbolCodec schema 64
  nativeA <- either fail pure (Codec.decode symbolCodec a)
  nativeB <- either fail pure (Codec.decode symbolCodec b)
  nativeC <- either fail pure (Codec.decode symbolCodec c)
  check "native identity" (nativeA == nativeB && nativeA /= nativeC)
  encoded <- either fail pure (Codec.encode symbolCodec nativeA)
  check "native round trip" (LS.equal encoded a)
  let ty = Schema.Named "List" [Schema.Named "Optional" [Schema.Named "Symbol" []]]
      nested = LS.SList [LS.SPresent "Optional" (Just literal)]
      scoped = LS.scopeSymbols first nested
  valid <- either fail pure (Schema.validate schema ty 64 scoped)
  same <- either fail pure (Schema.equal schema ty 64 scoped valid)
  different <- either fail pure (Schema.equal schema ty 64 scoped (LS.scopeSymbols second nested))
  check "nested identity" (same && not different)
  check "invalid text rejected" $ case LS.validateScalar 64
    (LS.scopeSymbols first (LS.SSymbol "bad" ['\xd800'])) of
      Left _ -> True
      Right _ -> False
  LS.forceScalar scoped `seq` putStrLn "Haskell scoped Symbol identity passed"
