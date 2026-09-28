module Main where
import Control.Monad (forM_)
import LawSpec.Core
import LawSpec.KotlinData
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Code.Doc as D
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Environment (getArgs)
main :: IO ()
main = do
  [directory] <- getArgs
  let origin = GeneratedFrom (Id "kotlin-data-fixture")
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
      phantom = declaration "Phantom" [a] [ctor "Tag" []]
      left = declaration "LeftSide" [] [ctor "Across" [("value", scalarType "RightSide")]]
      right = declaration "RightSide" [] [ctor "Back" [("value", app "Maybe" [scalarType "LeftSide"])]]
      presence = declaration "Presence" [] [ctor "States"
        [("value", app "Nullable" [app "Optional" [scalarType "Int8"]]),
         ("unit", scalarType "Unit"), ("nullValue", scalarType "Null"),
         ("undefinedValue", scalarType "Undefined")]]
      shadow = declaration "String" [] [ctor "String" [("value", scalarType "Text")]]
      paramName = declaration "T0" [a] [ctor "Param" [("value", TypeVariable a)]]
      sameName = declaration "FooCase" [] [ctor "Foo" []]
      raw = declaration "Raw" [] [ctor "Raw"
        [("text", scalarType "Text"), ("points", scalarType "CodePointText"),
         ("units", scalarType "Utf16Text"), ("bytes", scalarType "Bytes"),
         ("symbol", scalarType "Symbol"), ("rational", scalarType "Rational"),
         ("complex", scalarType "Complex64")]]
  forM_ [("pretty", D.Pretty 100), ("compact", D.Compact)] $ \(mode, layout) ->
    case emitKotlinData layout [tree, pair, empty, choice, phantom, left, right, presence, raw, shadow, paramName, sameName] of
      Left problem -> fail problem
      Right files -> forM_ files $ \file -> do
        let destination = directory </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
