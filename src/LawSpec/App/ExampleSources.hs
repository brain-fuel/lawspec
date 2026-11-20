{-# LANGUAGE TemplateHaskell #-}

-- | The examples lawspec examples writes, as the npm package bundles them
-- (tools/wasm.sh copies the same folders into npm/examples), embedded at
-- compile time. ref:DEC-haskell-application-port
module LawSpec.App.ExampleSources (exampleSpecifications, paymentsSpecification, paymentsProjects) where

import Data.List (isSuffixOf)
import LawSpec.Embed (Tree (..), embedFile, embedProjects, embedTree)

-- | examples/specs/*.lawspec, by name, in sorted order.
exampleSpecifications :: [(FilePath, String)]
exampleSpecifications = $(embedTree "examples/specs" (Tree (const False) (".lawspec" `isSuffixOf`)))

-- | examples/rc1/native-payments.lawspec.
paymentsSpecification :: String
paymentsSpecification = $(embedFile "examples/rc1/native-payments.lawspec")

-- | Each target's examples/native-payments project: its files by relative
-- path, in readdir order.
paymentsProjects :: [(String, [(FilePath, String)])]
paymentsProjects = $(embedProjects "examples/native-payments")
