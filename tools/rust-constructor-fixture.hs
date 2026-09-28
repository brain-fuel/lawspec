module Main where

import Control.Monad (forM_)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.RustData (emitRustData)
import LawSpec.RustDefinitions (emitRustDefinitions)
import LawSpec.RustEmit (emitRustSchema)
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
    core <- either (fail . show) pure
      (compileCore bits defaultGeneration [Source source content])
    forM_ [("pretty",D.Pretty 100),("compact",D.Compact)] $ \(mode,layout) -> do
      let declarations = programDataDeclarations core
      schema <- either fail pure (emitRustSchema bits layout declarations)
      types <- either fail pure (emitRustData layout declarations)
      definitions <- either fail pure
        (emitRustDefinitions layout bits declarations (programUnits core))
      let destination = directory </> show bits </> mode </> "src"
      createDirectoryIfMissing True destination
      forM_ [("lawspec_schema.rs",schema),("lawspec_data.rs",types),
        ("lawspec_definitions.rs",definitions),("lawspec_runtime.rs",runtimeSource "rust")] $
        \(name,body) -> writeFile (destination </> name) body
