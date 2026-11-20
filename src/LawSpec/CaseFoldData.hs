{-# LANGUAGE TemplateHaskell #-}

-- | The full default case folding of the pinned Unicode 17.0.0
-- vendor/unicode/17.0.0/CaseFolding.txt (statuses C and F), embedded at
-- compile time.
module LawSpec.CaseFoldData (caseFoldMappings) where

import LawSpec.Embed (caseFoldTable)

caseFoldMappings :: [(String, String)]
caseFoldMappings = $(caseFoldTable)
