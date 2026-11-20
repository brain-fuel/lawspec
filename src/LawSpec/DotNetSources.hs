{-# LANGUAGE TemplateHaskell #-}

-- | The .NET runtime projects (F#, with the C# compatibility layer), by
-- their path under runtime/dotnet, embedded at compile time: each generated
-- project gets the files of the projects it references, in this order.
-- ref:DEC-fsharp-runtime-from-scratch
module LawSpec.DotNetSources (dotnetSource, dotnetFiles) where

import Data.Maybe (fromMaybe)
import LawSpec.Embed (dotnetTree, embedTree)

dotnetFiles :: [String]
dotnetFiles = map fst sources

dotnetSource :: String -> String
dotnetSource path = fromMaybe "" (lookup path sources)

sources :: [(String, String)]
sources = $(embedTree "runtime/dotnet" dotnetTree)
