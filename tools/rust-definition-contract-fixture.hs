module Main where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import DefinitionContractFixture
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.RustDefinitions as R

main :: IO ()
main = do
  [directory] <- getArgs
  forM_ [32,64] $ \bits -> forM_ [("pretty",D.Pretty 100),("compact",D.Compact)] $ \(mode,layout) -> do
    forM_ invalidUnits $ \units -> unless (isLeft (R.emitRustDefinitions layout bits [] units))
      (fail "invalid Rust definition contract accepted")
    units <- fixtureUnits bits
    definitions <- either fail pure (R.emitRustDefinitions layout bits [] units)
    forM_ [("lawspec_definitions.rs",definitions),("lawspec_runtime.rs",runtimeSource "rust")] $ \(name,content) -> do
      let destination = directory </> show bits </> mode </> "src" </> name
      createDirectoryIfMissing True (takeDirectory destination)
      writeFile destination content
