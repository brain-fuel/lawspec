module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.HaskellData
import LawSpec.HaskellDefinitions
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>), takeDirectory)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    bits:directory:paths@(_:_) -> do
      sources <- mapM (\path -> Source path <$> readFile path) paths
      program <- either (fail . show) pure (compileCore (read bits) defaultGeneration sources)
      let declarations = programDataDeclarations program
      forM_ [("pretty", D.Pretty 80), ("compact", D.Compact)] $ \(mode,layout) -> do
        definitions <- either fail pure (emitHaskellDefinitions layout (read bits)
          declarations (programUnits program))
        dat <- either fail pure (emitHaskellData layout declarations)
        schema <- either fail pure (emitHaskellSchemaWithProfile (read bits) layout declarations)
        codecs <- either fail pure (emitHaskellCodecs layout declarations)
        let generated = [(drop 4 (artifactPath file),artifactContent file) | file <- definitions]
            support = [("LawSpecData.hs",dat),("LawSpecDataSchema.hs",schema),
              ("LawSpecDataCodecs.hs",codecs)] ++
              [(name ++ ".hs",runtimeSource key) | (name,key) <-
                [("LawSpecRuntime","haskell"),("LawSpecSchema","haskell-schema"),
                 ("LawSpecCodecs","haskell-codecs")]]
        forM_ (generated ++ support) $ \(name,content) -> do
          let destination = directory </> mode </> name
          createDirectoryIfMissing True (takeDirectory destination)
          writeFile destination content
    _ -> fail "usage: haskell-definitions-fixture <machineBits> <directory> <sources...>"
