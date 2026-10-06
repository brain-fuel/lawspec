-- User-owned LawSpec adapter.
module Example.Harness where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified LawSpecAbilities.Example.Harness as Abilities

-- (example.harness::type::Order -> Int32)
-- Ten percent off orders of more than ten items.
discount :: Data.Order -> I.Int32
discount order = if Data.orderItems order > 10 then Data.orderTotal order `P.quot` 10 else 0

-- (Int32 -> Int32)
-- To the nearest ten cents, halves down: known to break a law.
roundCents :: I.Int32 -> I.Int32
roundCents value0 = (value0 + 4) `P.quot` 10 * 10

-- (Int32 -> Bool)
book :: Abilities.Ledger -> I.Int32 -> P.IO P.Bool
book ledger value0 = Abilities.accept ledger value0

-- | The native handler of Ledger: accept.
ledgerHandler :: P.IO Abilities.Ledger
ledgerHandler = P.pure Abilities.Ledger
  { Abilities.accept = \value0 -> P.pure (value0 > 0)
  }
