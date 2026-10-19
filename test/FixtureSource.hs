-- | Assemble declarations inside a complete canonical unit in test fixtures.
-- This handles the unit envelope only; every declaration supplies its own
-- explicit closing syntax and is checked by the normal compiler.
module FixtureSource (extendUnit) where

import Data.List (stripPrefix)
import Data.Char (isSpace)

extendUnit :: String -> String -> String
extendUnit source declarations = case stripPrefix (reverse "end unit")
    (dropWhile isSpace (reverse source)) of
  Just body -> reverse body ++ "\n" ++ declarations ++ "\nend unit\n"
  Nothing -> error "extendUnit expects a complete canonical unit fixture"
