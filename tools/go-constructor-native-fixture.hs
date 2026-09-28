module Main where

import Control.Monad (forM_)
import Data.List (stripPrefix)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Frontend (compileCore)
import LawSpec.GoData
import LawSpec.GoDefinitions (emitGoDefinitions)
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Environment (getArgs)

main :: IO ()
main = do
  [source, directory] <- getArgs
  content <- readFile source
  let extra = unlines
        [ "definition echoList (xs :: List (Maybe Identity)) :: List (Maybe Identity) is xs end"
        , "definition echoNested (x :: Optional (Nullable Identity)) :: Optional (Nullable Identity) is x end"
        , "definition echoIdentityBucket (x :: Bucket Identity) :: Bucket Identity is x end"
        , "type Present (a :: Type) is Present item :: (m :: Maybe a where match m with | Nothing -> false | Just value -> true end) end"
        , "definition echoPresent (x :: Present Identity) :: Present Identity is x end"
        ]
  forM_ [32,64] $ \bits -> do
    core <- either (fail . show) pure (compileCore bits defaultGeneration [Source source (content ++ "\n" ++ extra)])
    forM_ [("pretty",D.PrettyTabs 100),("compact",D.Compact)] $ \(mode,layout) -> do
      let declarations = programDataDeclarations core
          output = directory </> show bits </> mode
          folder = output </> "native/fields"
      createDirectoryIfMissing True folder
      forM_ [("lawspec_data.go",emitGoData),("lawspec_data_codecs.go",emitGoCodecs),
             ("lawspec_data_schema.go",emitGoSchemaWithProfile bits)] $ \(name,emit) ->
        either fail (writeFile (folder </> name)) (emit layout "fields" declarations)
      forM_ [("lawspec_runtime.go","go"),("lawspec_schema.go","go-schema"),("lawspec_codecs.go","go-codecs")] $
        \(name,target) -> writeFile (folder </> name) (replace "RUNTIME_PACKAGE" "fields" (runtimeSource target))
      files <- either fail pure (emitGoDefinitions layout bits declarations (programUnits core))
      forM_ files $ \file -> do
        let destination = output </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
      writeFile (output </> "go.mod") "module fixture\n\ngo 1.24.0\n"
  where
    replace old new source | Just rest <- stripPrefix old source = new ++ replace old new rest
    replace old new (c:cs) = c : replace old new cs
    replace _ _ [] = []
