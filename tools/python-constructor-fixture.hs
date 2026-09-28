module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.PythonData (emitPythonDataWithProfile)
import LawSpec.PythonDefinitions (emitPythonDefinitions)
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Environment (getArgs)

main :: IO ()
main = do
  [source, directory] <- getArgs
  content <- readFile source
  forM_ [32,64] $ \bits -> do
    core <- either (fail . show) pure
      (compileCore bits defaultGeneration [Source source content])
    forM_ [("pretty",D.Pretty 79),("compact",D.Compact)] $ \(mode,layout) -> do
      files <- either fail pure $ (++)
        <$> emitPythonDataWithProfile bits layout (programDataDeclarations core)
        <*> emitPythonDefinitions layout bits (programDataDeclarations core) (programUnits core)
      forM_ ([Artifact "src/lawspec_runtime.py" (runtimeSource "python") "generated" "source",
              Artifact "tests/lawspec_data_strategies.py" (runtimeSource "python-data-strategies") "generated" "test"] ++ files) $ \file -> do
        let destination = directory </> show bits </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
