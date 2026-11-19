-- | @lawspec fetch@, @lawspec update@ and @lawspec package@, ported from
-- lawspec.mjs: the first two resolve the manifest's dependencies and
-- rewrite lawspec.lock.edn, the last checks a package's own sources and
-- summarises what it publishes, writing the archive with --output.
-- ref:DEC-haskell-application-port
module LawSpec.App.PackageCommands
  ( fetchCommand,
    packageCommand,
  )
where

import Data.List (intercalate, isPrefixOf)
import Data.Maybe (fromMaybe)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Files (collectSources)
import LawSpec.App.Json
import LawSpec.App.Packages
import LawSpec.App.Project (dependencyRanges, readManifest)
import LawSpec.Host.Path (join, resolve, takeDirectory)

-- | fetch and update: resolveDependencies with options.update set as
-- lawspec.mjs sets it, then the lock or a count.
fetchCommand :: (Monad m) => Invocation -> Arguments -> String -> FilePath -> Command m Int
fetchCommand invocation arguments name configFile = do
  let root = takeDirectory configFile
      update
        | name /= "update" = NoUpdate
        | otherwise = maybe UpdateAll UpdateOne (case positional arguments of first : _ -> Just first; [] -> Nothing)
  manifest <- readManifest configFile
  grantProject [root]
  grantWrite [root]
  resolved <-
    resolveDependencies
      configFile
      manifest
      (resolveOptions (invocationDirectory invocation))
        { resolveLocked = flag "locked" arguments,
          resolveOffline = flag "offline" arguments,
          resolveUpdate = update
        }
  if flag "json" arguments
    then printJson (resolvedLock resolved)
    else printLine ("Resolved " ++ show (length (resolvedPackages resolved)) ++ " contract package(s).")
  pure 0

-- | packageCommand: the package's own units, laws and data types, and
-- the archive when --output names one.
packageCommand :: (Monad m) => Invocation -> Arguments -> Maybe Integer -> FilePath -> FilePath -> Command m Int
packageCommand invocation arguments machineBits configFile configRoot = do
  let cwd = invocationDirectory invocation
      file
        | present "config" arguments = configFile
        | otherwise = resolve cwd (join (fromMaybe "." (option "project" arguments)) "lawspec.edn")
      directory = takeDirectory file
      json = flag "json" arguments
  grantRead [directory]
  manifest <- readManifest file
  identity <- maybe (failWith (file ++ ": expected a package identity")) pure (member "package" manifest)
  let text key = maybe "undefined" jsString (member key identity)
      ownName = text "name"
      dependencies = dependencyRanges manifest
  sources <- collectSources directory [entry | Just items <- [member "sources" manifest >>= arrayOf], JString entry <- items] configRoot
  grantProject [directory]
  grantWrite [directory]
  resolved <-
    resolveDependencies
      (join directory "lawspec.edn")
      manifest
      (resolveOptions cwd)
        { resolveLocked = flag "locked" arguments,
          resolveOffline = flag "offline" arguments
        }
  result <-
    call
      "check"
      ( jsObject
          [ ("languageProfile", JString "1.0-rc.2"),
            ("verification", JObject [("layers", JArray [])]),
            ("sources", JArray [JObject [("path", JString path'), ("content", JString content)] | (path', content) <- sources]),
            ("package", identity),
            ("packages", JArray (resolvedPackages resolved)),
            ("dependencies", dependencies),
            ("machineBits", integer (fromMaybe 64 machineBits))
          ]
      )
      >>= diagnostics json
  -- A package owns the units in its namespace; its dependencies' units are
  -- not its own.
  let ids key = [maybe "undefined" jsString (member "id" item) | item <- items key]
      items key = fromMaybe [] (member key result >>= arrayOf)
      units = [unit | unit <- ids "units", unit == ownName || (ownName ++ ".") `isPrefixOf` unit]
      laws =
        [ maybe "undefined" jsString (member "owner" law) ++ "::" ++ maybe "undefined" jsString (member "name" law)
        | law <- items "laws",
          maybe False ((`elem` units) . jsString) (member "owner" law)
        ]
      dataTypes = [declared | declared <- ids "dataTypes", any (\unit -> (unit ++ "::") `isPrefixOf` declared) units]
  archive <- traverse (packComponent cwd file) (option "output" arguments)
  let summary =
        jsObject
          ( [(key, value) | key <- ["name", "version"], Just value <- [member key identity]]
              ++ [ ("dependencies", dependencies),
                   ("units", JArray (map JString units)),
                   ("laws", JArray (map JString laws)),
                   ("dataTypes", JArray (map JString dataTypes))
                 ]
              ++ [("archive", value) | Just value <- [archive]]
          )
      ranges = [name ++ " " ++ jsString range | (name, range) <- members dependencies]
  if json
    then printJson summary
    else
      printLine
        ( ownName
            ++ " "
            ++ text "version"
            ++ ": "
            ++ show (length units)
            ++ " unit(s), "
            ++ show (length laws)
            ++ " law(s), "
            ++ show (length dataTypes)
            ++ " data type(s).\nUnits: "
            ++ intercalate ", " units
            ++ "\nDependencies: "
            ++ (if null ranges then "none" else intercalate ", " ranges)
        )
  pure 0
