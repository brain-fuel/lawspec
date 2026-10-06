-- | Application code: a Clock bound in lawspec.json in place of the default
-- one. It keeps the default clock's readings.
module Example.Clocks (newSteadyClock) where

import qualified Data.IORef as IORef
import qualified Lawspec.Time as Time
import qualified LawSpecAbilities.Lawspec.Time as Abilities
import qualified LawSpecData as Data

newSteadyClock :: IO Abilities.Clock
newSteadyClock = do
  inner <- Time.clockHandler
  readings <- IORef.newIORef (0 :: Integer)
  pure Abilities.Clock
    { Abilities.now = do
        IORef.modifyIORef' readings (+ 1)
        Abilities.now inner
    , Abilities.sleep = Abilities.sleep inner
    }
