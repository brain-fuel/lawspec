module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Core
import LawSpec.GoDefinitions (emitGoDefinitions)
import LawSpec.Code.Doc (Layout(..))

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    bits:directory:sourceRoot:paths@(_:_) -> do
      sources <- mapM (\path -> Source path <$> readFile path) paths
      program <- either (fail . show) pure (compileCore (read bits) defaultGeneration sources)
      files <- either fail pure (emitGoDefinitions Compact (read bits)
        (programDataDeclarations program) (programUnits program))
      mapM_ (\file -> do
        let destination = directory </> sourceRoot </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)) files
    _ -> fail "usage: go-definitions-fixture <machineBits> <directory> <sourceRoot> <sources...>"
