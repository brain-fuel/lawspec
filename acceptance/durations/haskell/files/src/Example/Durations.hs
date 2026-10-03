-- User-owned LawSpec adapter. A Duration holds its microseconds.
module Example.Durations (remaining) where

import qualified LawSpecData as Data

remaining :: Data.Duration -> Data.Duration -> Data.Duration
remaining (Data.Duration budget) (Data.Duration spent)
  | spent >= budget = Data.Duration 0
  | otherwise = Data.Duration (budget - spent)
