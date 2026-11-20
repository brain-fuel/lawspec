{-# LANGUAGE TemplateHaskell #-}

-- | The built-in abilities' default handlers and known-answer vectors, by
-- their path under runtime/defaults (LawSpec.BuiltinDefaults), in their own
-- module so the scalar runtimes stay apart. Embedded at compile time.
module LawSpec.DefaultSources (defaultSource) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (defaultsTree, embedTree)

defaultSource :: String -> String
defaultSource path = fromMaybe "" (lookup path sources)

sources :: [(String, String)]
sources = $(embedTree "runtime/defaults" defaultsTree)
