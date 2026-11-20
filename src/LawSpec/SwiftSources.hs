{-# LANGUAGE TemplateHaskell #-}

-- | The Swift runtime and test support (LawSpecRuntime and LawSpecTesting),
-- by their path under runtime/swift, embedded at compile time: each
-- generated package gets them as SwiftPM targets of its own.
-- ref:DEC-swift-runtime-from-scratch
module LawSpec.SwiftSources (swiftSource, swiftFiles) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (embedTree, languageTree)

swiftFiles :: [String]
swiftFiles = map fst sources

swiftSource :: String -> String
swiftSource path = fromMaybe "" (lookup path sources)

sources :: [(String, String)]
sources = $(embedTree "runtime/swift" languageTree)
