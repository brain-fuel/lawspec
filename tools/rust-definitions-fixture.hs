module Main where

import System.Environment (getArgs)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Core
import LawSpec.RustDefinitions (emitRustDefinitions)
import LawSpec.Code.Doc (Layout(..))

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    bits:output:paths@(_:_) -> do
      sources <- mapM (\path -> Source path <$> readFile path) paths
      program <- either (fail . show) pure (compileCore (read bits) defaultGeneration sources)
      content <- either fail pure (emitRustDefinitions Compact (read bits)
        (programDataDeclarations program) (programUnits program))
      writeFile output content
    _ -> fail "usage: rust-definitions-fixture <machineBits> <output> <sources...>"
