-- User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
module Example.Overlap where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Control.Concurrent as Concurrent
import Example.Sequencing (note)

-- (Int32 -> Bool)
nap :: I.Int32 -> P.IO P.Bool
nap n = do
  note "start" n
  Concurrent.threadDelay 300000
  note "end" n
  P.pure P.True
