-- | @lawspec fmt [paths...] [--check] [--compile] [--json]@: format LawSpec
-- sources in place, or report which need formatting. Ported from the Node
-- CLI's formatCommand (templates/npm/bin/lawspec.mjs); output, exit codes and
-- written files match it. The compiler is called in process, with the
-- request the Node CLI sends.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Format
  ( FormatOptions (..),
    formatCommand,
  )
where

import Control.Monad (forM_, unless)
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Files (atomicWrite, collectSources)
import LawSpec.App.Json
import LawSpec.Host.Path (resolve)

data FormatOptions = FormatOptions
  { formatPaths :: [String],
    formatCheck :: Bool,
    formatCompile :: Bool,
    formatJson :: Bool,
    formatMachineBits :: Integer
  }
  deriving (Eq, Show)

-- | The Node CLI's formatCommand, given the root the entries are relative
-- to and, without paths, the manifest's package input. Returns the exit code.
formatCommand :: (Monad m) => FormatOptions -> FilePath -> [String] -> [(String, Json)] -> Command m Int
formatCommand options root entries packageInput = do
  files <- collectSources root entries root
  result <-
    call
      "format"
      ( jsObject
          ( [ ("sources", JArray [JObject [("path", JString file), ("content", JString text)] | (file, text) <- files]),
              ("compile", JBool (formatCompile options)),
              ("machineBits", integer (formatMachineBits options))
            ]
              ++ packageInput
              ++ [ ("languageProfile", JString "1.0-rc.2"),
                   ("verification", JObject [("layers", JArray [])])
                 ]
          )
      )
      >>= diagnostics (formatJson options)
  formatted <- case member "formattedSources" result >>= arrayOf of
    Just items -> pure items
    Nothing -> failWith "Cannot read properties of undefined (reading 'filter')"
  let changed =
        [ (path', content')
        | (index, source) <- zip [0 :: Int ..] formatted,
          let path' = maybe "" jsString (member "path" source)
              content' = maybe "" jsString (member "content" source),
          Just content' /= fmap snd (lookup' index files)
        ]
  unless (formatCheck options) $
    forM_ changed $ \(path', content') -> atomicWrite (resolve root path') content' False
  if formatJson options
    then printJson (JObject [("changed", JArray [JString path' | (path', _) <- changed]), ("check", JBool (formatCheck options))])
    else
      printLine $
        if null changed
          then "All sources are formatted."
          else show (length changed) ++ " source file(s) " ++ (if formatCheck options then "need formatting" else "formatted") ++ "."
  pure (if formatCheck options && not (null changed) then 1 else 0)
  where
    lookup' index list = case drop index list of
      item : _ | index >= 0 -> Just item
      _ -> Nothing
