module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Core
import LawSpec.WebDefinitions (emitWebDefinitions)
import LawSpec.Code.Doc (Layout(..))

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    target:bits:directory:sourceRoot:paths@(_:_) -> do
      sources <- mapM (\path -> Source path <$> readFile path) paths
      program <- either (fail . show) pure (compileCore (read bits) defaultGeneration sources)
      files <- either fail pure (emitWebDefinitions (target == "typescript") Compact (read bits)
        (programDataDeclarations program) (programUnits program))
      mapM_ (\file -> do
        let destination = directory </> sourceRoot </> drop (length ("src/" :: String)) (artifactPath file)
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)) files
    _ -> fail "usage: web-definitions-fixture <target> <machineBits> <directory> <sourceRoot> <sources...>"
