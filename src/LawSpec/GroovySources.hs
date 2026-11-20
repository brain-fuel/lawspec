{-# LANGUAGE TemplateHaskell #-}

-- | The Groovy runtime over the Java one, by its path under runtime/groovy,
-- embedded at compile time. ref:DEC-groovy-over-java
module LawSpec.GroovySources (groovySource) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (embedTree, languageTree)

groovySource :: String -> String
groovySource path = fromMaybe "" (lookup path sources)

sources :: [(String, String)]
sources = $(embedTree "runtime/groovy" languageTree)
