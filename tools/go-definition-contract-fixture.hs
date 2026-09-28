module Main where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import Data.List (stripPrefix)
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import LawSpec.Common
import DefinitionContractFixture
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.GoData as G
import qualified LawSpec.GoDefinitions as G

main = do
  [directory] <- getArgs
  forM_ [32,64] $ \bits -> forM_ [("pretty",D.PrettyTabs 100),("compact",D.Compact)] $ \(mode,layout) -> do
    forM_ invalidUnits $ \units -> unless (isLeft (G.emitGoDefinitions layout bits [] units))
      (fail "invalid Go definition contract accepted")
    units <- fixtureUnits bits
    definitions <- either fail pure (G.emitGoDefinitions layout bits [] units)
    support <- sequence [either fail pure (emit layout "fixture" []) | emit <- [G.emitGoData,G.emitGoSchema,G.emitGoCodecs]]
    let files = [(artifactPath file,artifactContent file) | file <- definitions] ++
          zip ["fixture/lawspec_data.go","fixture/lawspec_data_schema.go","fixture/lawspec_data_codecs.go"] support ++
          [("fixture/" ++ filename,replace "RUNTIME_PACKAGE" "fixture" (runtimeSource key)) |
            (filename,key) <- [("lawspec_runtime.go","go"),("lawspec_schema.go","go-schema"),("lawspec_codecs.go","go-codecs")]]
    forM_ files $ \(name,content) -> do
      let destination = directory </> show bits </> mode </> name
      createDirectoryIfMissing True (takeDirectory destination)
      writeFile destination content
  where
    replace old new value | Just rest <- stripPrefix old value = new ++ replace old new rest
    replace old new (c:rest) = c : replace old new rest
    replace _ _ [] = []
