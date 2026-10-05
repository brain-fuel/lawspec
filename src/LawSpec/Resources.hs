-- Built-in resources: temporary directories and files, free ports, and a
-- saved environment. They are ordinary data of a built-in unit,
-- lawspec.resources, added only to programs that name one, as
-- lawspec.collections is. A law takes them like a resource it declares
-- (law ... for dir :: TemporaryDirectory is); the runtime of each target
-- acquires and releases them (prelude helpers acquireResource,
-- releaseResource and freePort), so their acquire and release clauses are
-- built here, not written in LawSpec.
module LawSpec.Resources
  ( resourcesUnit, resourcesAlias, resourcesSource, resourcesTypes, usesResources
  , builtinResourceKind
  ) where

import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, stripPrefix, tails)

resourcesUnit :: String
resourcesUnit = "lawspec.resources"

resourcesAlias :: String
resourcesAlias = "lawspecResources"

-- What every source that uses a built-in resource imports: the types and
-- the functions that read them.
resourcesTypes :: [String]
resourcesTypes = map fst kinds ++ ["directoryPath", "filePath", "portNumber"]

-- Each type, and the kind of resource the runtimes acquire for it.
kinds :: [(String, String)]
kinds =
  [ ("TemporaryDirectory", "temporaryDirectory"), ("TemporaryFile", "temporaryFile")
  , ("FreePort", "freePort"), ("SavedEnvironment", "environment") ]

-- The runtime kind of a built-in resource type, by its Core name.
builtinResourceKind :: String -> Maybe String
builtinResourceKind name = stripPrefix (resourcesUnit ++ "::type::") name >>= (`lookup` kinds)

-- Whether a source names a built-in resource it does not declare itself.
usesResources :: String -> Bool
usesResources text =
  let tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') (stripComments text))
      declared = [name | (keyword, name) <- zip tokens (drop 1 tokens), keyword `elem` ["type", "wrapper", "handle"]]
  in any (\(t, _) -> t `elem` tokens && t `notElem` declared) kinds
  where
    stripComments = unlines . map takeComment . lines
    takeComment line = case [i | (i, rest) <- zip [0 :: Int ..] (tails line), "--" `isPrefixOf` rest] of
      i : _ -> take i line
      [] -> line

resourcesSource :: String
resourcesSource = unlines
  [ "unit " ++ resourcesUnit
  , ""
  , "-- A directory made for one case of a law, and removed with everything in it."
  , "type TemporaryDirectory is TemporaryDirectory path :: Text end"
  , ""
  , "-- An empty file made for one case of a law, and removed after it."
  , "type TemporaryFile is TemporaryFile path :: Text end"
  , ""
  , "-- A TCP port on the local host that was free when the case began."
  , "type FreePort is FreePort number :: Int32 end"
  , ""
  , "-- The process environment as the case found it; it is restored after."
  , "type SavedEnvironment is SavedEnvironment snapshot :: Text end"
  , ""
  , "definition directoryPath (d :: TemporaryDirectory) :: Text is match d with | TemporaryDirectory p -> p end end"
  , ""
  , "definition filePath (f :: TemporaryFile) :: Text is match f with | TemporaryFile p -> p end end"
  , ""
  , "definition portNumber (p :: FreePort) :: Int32 is match p with | FreePort n -> n end end"
  ]
