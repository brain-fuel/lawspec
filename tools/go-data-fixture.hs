module Main where
import Control.Monad (forM_)
import LawSpec.Core
import LawSpec.GoData
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import Data.List (stripPrefix)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Environment (getArgs)
main :: IO ()
main = do
  [directory] <- getArgs
  let origin = GeneratedFrom (Id "go-data-fixture")
      a = Id "a"
      app name args = Constructor name (map TypeArgument args)
      ctor name fields = DataConstructor (Id ("ctor::" ++ name)) name
        [Binder (Id (name ++ "::" ++ field)) field ty | (field,ty) <- fields] [] origin
      declaration name params variants = DataDeclaration (Id name) name params variants origin
      tree = declaration "Tree" [a]
        [ctor "Leaf" [("value", TypeVariable a)],
         ctor "Branch" [("children", app "List" [app "Tree" [TypeVariable a]])]]
      pair = declaration "Pair" [a]
        [ctor "Pair" [("first", TypeVariable a), ("second", scalarType "UInt64")]]
      empty = declaration "Empty" [a] []
      phantom = declaration "Phantom" [a] [ctor "Tag" []]
      chain = declaration "Chain" []
        [ctor "Stop" [], ctor "Next" [("next", app "Maybe" [scalarType "Chain"])]]
      left = declaration "LeftSide" [] [ctor "Across" [("right", scalarType "RightSide")]]
      right = declaration "RightSide" [] [ctor "Back" [("left", app "Maybe" [scalarType "LeftSide"])]]
      machine = declaration "Machine" [] [ctor "MachineField" [("value", scalarType "IntSize")]]
      presence = declaration "Presence" [] [ctor "States"
        [("nested", app "Nullable" [app "Optional" [scalarType "Int8"]]),
         ("unit", scalarType "Unit"), ("missing", scalarType "Undefined")]]
  forM_ [("pretty", D.PrettyTabs 100), ("compact", D.Compact)] $ \(mode,layout) -> do
    let declarations = [tree,pair,empty,phantom,chain,left,right,presence,machine]
    codecs <- either fail pure (emitGoCodecs layout "fixture" declarations)
    schema <- either fail pure (emitGoSchema layout "fixture" declarations)
    content <- either fail pure (emitGoData layout "fixture" declarations)
    let output = directory </> mode
    createDirectoryIfMissing True output
    writeFile (output </> "lawspec_data.go") content
    writeFile (output </> "lawspec_data_codecs.go") codecs
    writeFile (output </> "lawspec_codecs.go") (replace "RUNTIME_PACKAGE" "fixture" (runtimeSource "go-codecs"))
    writeFile (output </> "lawspec_data_schema.go") schema
    writeFile (output </> "lawspec_runtime.go") (replace "RUNTIME_PACKAGE" "fixture" (runtimeSource "go"))
    writeFile (output </> "lawspec_schema.go") (replace "RUNTIME_PACKAGE" "fixture" (runtimeSource "go-schema"))
    writeFile (output </> "lawspec_data_strategies_test.go") (replace "RUNTIME_PACKAGE" "fixture" (runtimeSource "go-data-strategies"))
    writeFile (output </> "go.mod") "module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\n"
  where
    replace old new source | Just rest <- stripPrefix old source = new ++ replace old new rest
    replace old new (c:cs) = c:replace old new cs
    replace _ _ [] = []
