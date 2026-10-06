-- User-owned LawSpec adapter: the native Gateway handler.
module Example.Failures where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Text as T
import qualified LawSpecData as Data
import qualified LawSpecAbilities.Example.Failures as Abilities

-- | The native handler of Gateway: decide.
gatewayHandler :: P.IO Abilities.Gateway
gatewayHandler = P.pure Abilities.Gateway
  { Abilities.decide = \cents -> P.pure (decide cents)
  }

decide :: I.Int32 -> Data.Decision
decide cents
  | cents < 0 = Data.DecisionBlock
  | cents `mod` 2 == 1 = Data.DecisionDecline (T.pack "an odd amount")
  | otherwise = Data.DecisionApprove
