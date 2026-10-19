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
  [ "unit lawspec.resources"
  , ""
  , "-- A directory made for one case of a law, and removed with everything in it."
  , "type TemporaryDirectory is a record{  path :: Text} end type"
  , ""
  , "-- An empty file made for one case of a law, and removed after it."
  , "type TemporaryFile is a record{  path :: Text} end type"
  , ""
  , "-- A TCP port on the local host that was free when the case began."
  , "type FreePort is a record{  number :: Int32} end type"
  , ""
  , "-- The process environment as the case found it; it is restored after."
  , "type SavedEnvironment is a record{  snapshot :: Text} end type"
  , ""
  , "function directoryPath (d :: TemporaryDirectory) -> Text is first matching case of d : when TemporaryDirectory record{ path = p} then p end case end function"
  , ""
  , "function filePath (f :: TemporaryFile) -> Text is first matching case of f : when TemporaryFile record{ path = p} then p end case end function"
  , ""
  , "function portNumber (p :: FreePort) -> Int32 is first matching case of p : when FreePort record{ number = n} then n end case end function"
  , "end unit" ]
