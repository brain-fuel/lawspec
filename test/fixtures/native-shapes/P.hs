-- Deliberately matches the alias traditionally used for qualified Prelude.
module P where

import LawSpecRuntime (Symbol)

newtype Claim = Claim { token :: Symbol } deriving (Eq, Show)

copy :: a -> a
copy value = value
