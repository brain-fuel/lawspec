module Main where
import Control.Monad (forM_)
import LawSpec.Core
import LawSpec.JavaData
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Environment (getArgs)
main :: IO ()
main = do
  [directory] <- getArgs
  let origin = GeneratedFrom (Id "java-data-fixture")
      a = Id "a"
      app name args = Constructor name (map TypeArgument args)
      ctor name fields = DataConstructor (Id ("ctor::" ++ name)) name
        [Binder (Id (name ++ "::" ++ field)) field ty | (field, ty) <- fields] [] origin
      declaration name params variants = DataDeclaration (Id name) name params variants origin
      tree = declaration "Tree" [a]
        [ctor "Leaf" [("value", TypeVariable a)],
         ctor "Branch" [("children", app "List" [app "Tree" [TypeVariable a]])]]
      pair = declaration "Pair" [a]
        [ctor "Pair" [("first", TypeVariable a), ("second", scalarType "UInt64")]]
      empty = declaration "Empty" [a] []
      choice = declaration "Choice" [a]
        [ctor "Choose" [("value", app "Either" [app "Maybe" [TypeVariable a], app "Pair" [scalarType "Text"]])]]
  forM_ [("pretty", D.Pretty 100), ("compact", D.Compact)] $ \(mode, layout) ->
    case emitJavaData layout [tree, pair, empty, choice] of
      Left problem -> fail problem
      Right files -> forM_ files $ \file -> do
        let destination = directory </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
