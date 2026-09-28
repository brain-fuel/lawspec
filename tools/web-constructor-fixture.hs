module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.WebData (emitWebDataWithProfile)
import LawSpec.WebDefinitions (emitWebDefinitions)
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
    forM_ [("javascript",False),("typescript",True)] $ \(target,ts) ->
      forM_ [("pretty",D.Pretty 80),("compact",D.Compact)] $ \(mode,layout) -> do
        files <- either fail pure $ (++)
          <$> emitWebDataWithProfile ts bits layout (programDataDeclarations core)
          <*> emitWebDefinitions ts layout bits (programDataDeclarations core) (programUnits core)
        let extension = if ts then "ts" else "mjs"
            runtime = (if ts then "// @ts-nocheck\n" else "") ++ runtimeSource "javascript"
        forM_ (Artifact ("src/lawspec_runtime." ++ extension) runtime "generated" "source" : files) $ \file -> do
          let destination = directory </> target </> show bits </> mode </> artifactPath file
          createDirectoryIfMissing True (takeDirectory destination)
          writeFile destination (artifactContent file)
