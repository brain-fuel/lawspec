{-# LANGUAGE TemplateHaskell #-}

-- | The Clojure runtime over the Java one, by its path under runtime/clojure,
-- embedded at compile time. ref:DEC-groovy-over-java
module LawSpec.ClojureSources (clojureSource) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (embedTree, languageTree)

clojureSource :: String -> String
clojureSource path = fromMaybe "" (lookup path sources)

sources :: [(String, String)]
sources = $(embedTree "runtime/clojure" languageTree)
