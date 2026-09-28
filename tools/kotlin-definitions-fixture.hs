module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory, takeExtension)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Core
import LawSpec.KotlinDefinitions (emitKotlinDefinitions)
import LawSpec.Code.Doc (Layout(..))

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    bits:directory:javaRoot:kotlinRoot:paths@(_:_) -> do
      sources <- mapM (\path -> Source path <$> readFile path) paths
      program <- either (fail . show) pure (compileCore (read bits) defaultGeneration sources)
      files <- either fail pure (emitKotlinDefinitions Compact (read bits)
        (programDataDeclarations program) (programUnits program))
      mapM_ (\file -> do
        let java = takeExtension (artifactPath file) == ".java"
            root = if java then javaRoot else kotlinRoot
            prefix = if java then ("src/main/java/" :: String) else "src/main/kotlin/"
            destination = directory </> root </> drop (length prefix) (artifactPath file)
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)) files
    _ -> fail "usage: kotlin-definitions-fixture <machineBits> <directory> <javaRoot> <kotlinRoot> <sources...>"
