-- User-owned LawSpec adapter: a native Gateway handler and a native adapter
-- that uses Gateway through the handler it is given.
module Example.Abilities where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified LawSpecAbilities.Example.Abilities as Abilities

-- (Int32 -> Bool)
charge :: Abilities.Gateway -> I.Int32 -> P.IO P.Bool
charge gateway value0 = do
  payment <- Abilities.authorize gateway value0
  case payment of
    Data.PaymentApproved cents -> do
      receipt <- Abilities.capture gateway cents
      P.pure (Data.receiptCents receipt == value0)
    _ -> P.pure False

-- | The native handler of Gateway: authorize, capture, fee.
gatewayHandler :: P.IO Abilities.Gateway
gatewayHandler = P.pure Abilities.Gateway
  { Abilities.authorize = \value0 -> P.pure (if value0 < 0 then Data.PaymentDeclined else Data.PaymentApproved value0)
  , Abilities.capture = \value0 -> P.pure (Data.Receipt value0)
  , Abilities.fee = P.pure 25
  }
