module Main where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import LawSpec.Common
import DefinitionContractFixture
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonData as P
import qualified LawSpec.PythonDefinitions as P
import qualified LawSpec.WebData as W
import qualified LawSpec.WebDefinitions as W

main = do
  [directory] <- getArgs
  forM_ [32,64] $ \bits -> forM_ [("pretty",D.Pretty 80),("compact",D.Compact)] $ \(mode,layout) ->
    forM_ ["python","javascript","typescript"] $ \target -> do
      let ts = target == "typescript"
          dat = if target == "python" then P.emitPythonData else W.emitWebData ts
          defs = if target == "python" then P.emitPythonDefinitions else W.emitWebDefinitions ts
          runtime = case target of
            "python" -> Artifact "src/lawspec_runtime.py" (runtimeSource "python") "generated" "source"
            "typescript" -> Artifact "src/lawspec_runtime.ts" ("// @ts-nocheck\n" ++ runtimeSource "javascript") "generated" "source"
            _ -> Artifact "src/lawspec_runtime.mjs" (runtimeSource "javascript") "generated" "source"
      forM_ invalidUnits $ \units -> unless (isLeft (defs layout bits [] units))
        (fail (target ++ ": invalid definition contract accepted"))
      units <- fixtureUnits bits
      support <- either fail pure (dat layout [])
      bodies <- either fail pure (defs layout bits [] units)
      forM_ (runtime : support ++ bodies) $ \file -> do
        let destination = directory </> target </> show bits </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
