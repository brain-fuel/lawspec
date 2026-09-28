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
import qualified LawSpec.HaskellData as H
import qualified LawSpec.HaskellDefinitions as H

main :: IO ()
main = do
  [directory] <- getArgs
  forM_ [32,64] $ \bits -> forM_ [("pretty",D.Pretty 80),("compact",D.Compact)] $ \(mode,layout) -> do
    forM_ invalidUnits $ \units -> unless (isLeft (H.emitHaskellDefinitions layout bits [] units))
      (fail "invalid Haskell definition contract accepted")
    units <- fixtureUnits bits
    definitions <- either fail pure (H.emitHaskellDefinitions layout bits [] units)
    support <- sequence [either fail pure (emit layout []) | emit <- [H.emitHaskellData,H.emitHaskellSchema,H.emitHaskellCodecs]]
    let files = [(drop 4 (artifactPath file),artifactContent file) | file <- definitions] ++
          zip ["LawSpecData.hs","LawSpecDataSchema.hs","LawSpecDataCodecs.hs"] support ++
          [(name ++ ".hs",runtimeSource key) | (name,key) <-
            [("LawSpecRuntime","haskell"),("LawSpecSchema","haskell-schema"),("LawSpecCodecs","haskell-codecs")]]
    forM_ files $ \(name,content) -> do
      let destination = directory </> show bits </> mode </> name
      createDirectoryIfMissing True (takeDirectory destination)
      writeFile destination content
