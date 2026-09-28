module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.CoreNativeScalarEmit
import LawSpec.Frontend (compileCore)
import LawSpec.Testing
import qualified LawSpec.HaskellDefinitions as Definitions
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>), takeDirectory)

-- Exercise deterministic native test emission independently of random draws.
-- The companion definitions fixture supplies the schema, codecs and definitions.
main :: IO ()
main = do
  [bits, directory, source] <- getArgs
  content <- readFile source
  program <- either (fail . show) pure
    (compileCore (read bits) defaultGeneration [Source source content])
  plan <- either (fail . show) pure (planTesting program)
  forM_ [("pretty", False), ("compact", True)] $ \(mode, minify) ->
    forM_ (plannedUnits plan) $ \unit -> do
      let boundaries property = property {finiteCases = Just (boundaryCases property)}
      files <- either (fail . show) pure (nativeScalarEmitWithFormat minify
        (programDataDeclarations program)
        (Definitions.definitionCalls (programUnits program))
        (read bits) "haskell" (plannedUnit unit)
        (map boundaries (plannedProperties unit)))
      forM_ files $ \file -> do
        let destination = directory </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
