-- User-owned LawSpec adapter: the native Gateway handler.
module Example.Failures where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Text as T
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import qualified Control.Exception as E
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

-- Native adapters that fail: they throw the runtime's Fail with a
-- PaymentError, which a law expects with `fails with`.
refund :: I.Int32 -> I.Int32
refund cents
  | cents > 5000 = E.throw (LS.Fail (Data.PaymentErrorTooLarge 5000))
  | otherwise = cents

settle :: I.Int32 -> P.IO I.Int32
settle cents
  | cents < 0 = E.throwIO (LS.Fail Data.PaymentErrorBlocked)
  | cents == 0 = E.throwIO (LS.Fail (Data.PaymentErrorDeclined (T.pack "there is nothing to settle")))
  | otherwise = P.pure cents
