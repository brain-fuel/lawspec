{-# LANGUAGE TemplateHaskell #-}

-- | The reviewed runtime sources under runtime/, by key
-- (LawSpec.Embed.runtimeFiles), embedded at compile time.
module LawSpec.RuntimeSources (runtimeSource) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (embedTable, runtimeFiles)

runtimeSource :: String -> String
runtimeSource key = fromMaybe "" (lookup key sources)

sources :: [(String, String)]
sources = $(embedTable [(key, "runtime/" ++ file) | (key, file) <- runtimeFiles])
