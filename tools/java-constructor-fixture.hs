module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.JavaData (emitJavaSchema)
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Environment (getArgs)

main :: IO ()
main = do
  [source, directory] <- getArgs
  content <- readFile source
  forM_ [32,64] $ \bits -> do
    core <- either (fail . show) pure (compileCore bits defaultGeneration [Source source content])
    forM_ [("pretty",D.Pretty 100),("compact",D.Compact)] $ \(mode,layout) -> do
      schema <- either fail pure (emitJavaSchema bits layout (programDataDeclarations core))
      let destination = directory </> show bits </> mode
      createDirectoryIfMissing True destination
      forM_ [("LawSpecDataSchema.java",schema),("LawSpecSchema.java",runtimeSource "java-schema"),
        ("LawSpecRuntime.java",runtimeSource "java")] $ \(name,body) ->
          writeFile (destination </> name) body
