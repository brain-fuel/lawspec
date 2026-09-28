module Main where
import Control.Monad (forM_)
import LawSpec.Core
import LawSpec.HaskellData
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Environment (getArgs)
main :: IO ()
main = do
  [directory] <- getArgs
  let origin = GeneratedFrom (Id "haskell-data-fixture")
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
      presence = declaration "Presence" [] [ctor "States"
        [("nested", app "Nullable" [app "Optional" [scalarType "Int8"]]),
         ("unit", scalarType "Unit"), ("missing", scalarType "Undefined")]]
      machine = declaration "Machine" []
        [ctor "MachineEmpty" [], ctor "MachineValue" [("value", scalarType "IntSize")]]
      selectors = declaration "Selectors" []
        [ctor "X" [("yValue", scalarType "Bool")],
         ctor "XY" [("value", scalarType "Bool")]]
      strings = declaration "Strings" [] [ctor "Texts"
        [("text", scalarType "Text"), ("characters", app "List" [scalarType "Char"]),
         ("points", scalarType "CodePointText"), ("units", scalarType "Utf16Text")]]
  forM_ [("pretty", D.Pretty 80), ("compact", D.Compact)] $ \(mode,layout) -> do
    let declarations = [tree,pair,empty,phantom,chain,left,right,presence,strings,selectors,machine]
    content <- either fail pure (emitHaskellData layout declarations)
    codecs <- either fail pure (emitHaskellCodecs layout declarations)
    schema <- either fail pure (emitHaskellSchema layout declarations)
    let output = directory </> mode
    createDirectoryIfMissing True output
    writeFile (output </> "LawSpecData.hs") content
    writeFile (output </> "LawSpecDataCodecs.hs") codecs
    writeFile (output </> "LawSpecCodecs.hs") (runtimeSource "haskell-codecs")
    writeFile (output </> "LawSpecDataSchema.hs") schema
    writeFile (output </> "LawSpecSchema.hs") (runtimeSource "haskell-schema")
    writeFile (output </> "LawSpecRuntime.hs") (runtimeSource "haskell")
