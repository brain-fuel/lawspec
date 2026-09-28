module HaskellConstructorCodecsCheck (checkConstructorCodecs) where

import Control.Monad (forM_, unless)
import Data.List (isInfixOf)
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S
import qualified LawSpecCodecs as C
import qualified LawSpecData as D
import qualified LawSpecDataCodecs as DC

require :: String -> Bool -> IO ()
require label condition = unless condition (error label)

reject :: String -> Either String a -> IO ()
reject fragment result = case result of
  Left message -> require message (fragment `isInfixOf` message)
  Right _ -> error ("expected codec rejection: " ++ fragment)

roundtrip :: C.Codec a -> a -> IO ()
roundtrip codec native = case C.encode codec native >>= C.decode codec >>= C.encode codec of
  Left message -> error message
  Right result -> case C.encode codec native of
    Right expected -> require "native round trip changed" (LS.equal result expected)
    Left message -> error message

checkConstructorCodecs :: IO ()
checkConstructorCodecs = forM_ [32, 64] $ \bits -> do
  scope <- LS.newSymbolContext
  other <- LS.newSymbolContext
  let treeRef = S.Named "Tree" [S.Parameter 0]
      definitions = [S.Definition "Tree" 1
        [S.Constructor "ctor::Leaf" [S.Field "value" (S.Parameter 0)],
         S.Constructor "ctor::Branch" [S.Field "children" (S.Named "List" [treeRef])]]]
      predicate _ args fields width context =
        case (args, fields) of
          ([S.Named "Symbol" []], [value]) | width == bits ->
            Right (LS.equal value
              (maybe id LS.scopeSymbols context (LS.SSymbol "fixture" "same")))
          _ -> Left "lost type argument or profile"
      schema = either error id (S.createWithContracts definitions ["Symbol"]
        [("ctor::Leaf", [predicate])])
      element = C.symbolCodec schema bits
      tree = DC.treeCodecWith (Just scope) schema bits element
      identity = LS.ScopedSymbol scope "fixture" "same"
      leaf = D.TreeLeaf identity
      branch = D.TreeBranch [leaf, D.TreeBranch [leaf]]
  roundtrip tree branch
  roundtrip (C.listCodecWith (Just scope) schema bits tree) [branch]
  roundtrip (C.maybeCodecWith (Just scope) schema bits tree) (Just branch)
  roundtrip (C.eitherCodecWith (Just scope) schema bits tree element) (Left branch)
  let nested = C.optionalCodecWith (Just scope) schema bits
        (C.nullableCodecWith (Just scope) schema bits tree)
  roundtrip nested LS.UndefinedValue
  roundtrip nested (LS.OptionalValue LS.NullValue)
  roundtrip nested (LS.OptionalValue (LS.NullableValue branch))
  reject "ctor::Leaf predicate 1"
    (C.encode tree (D.TreeLeaf (LS.ScopedSymbol scope "other" "same")))
  reject "ctor::Leaf predicate 1"
    (C.decode tree (LS.SData "ctor::Leaf"
      [LS.scopeSymbols scope (LS.SSymbol "other" "same")]))
  reject "ctor::Leaf predicate 1"
    (C.encode (DC.treeCodecWith (Just other) schema bits element) branch)
  reject "ctor::Leaf predicate 1" (C.encode (DC.treeCodec schema bits element) branch)
  let broken = either error id (S.createWithContracts definitions ["Symbol"]
        [("ctor::Leaf", [\_ _ _ _ _ -> Left "codec evaluator marker"])])
      badCodec = DC.treeCodecWith (Just scope) broken bits (C.symbolCodec broken bits)
  reject "codec evaluator marker" (C.encode badCodec branch)
  reject "codec evaluator marker" (C.decode badCodec
    (LS.SData "ctor::Leaf" [LS.scopeSymbols scope (LS.SSymbol "fixture" "same")]))
  putStrLn ("Haskell constructor codec contexts passed: " ++ show bits)
