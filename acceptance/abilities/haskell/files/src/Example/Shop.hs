-- User-owned LawSpec adapter: native handlers for the shop's abilities, and
-- a native adapter that fails through LS.Fail.
module Example.Shop where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified Data.IORef as IORef
import qualified Control.Exception as E
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified LawSpecAbilities.Example.Shop as Abilities

-- (Int32 -> Int32)
refund :: Abilities.Gateway -> I.Int32 -> P.IO I.Int32
refund gateway value0
  | value0 > 100000 = E.throwIO (LS.Fail Data.PaymentErrorTooLarge)
  | otherwise = do
      receipt <- Abilities.capture gateway value0
      P.pure (Data.receiptCents receipt)

-- | The native handler of Log: note.
logHandler :: P.IO Abilities.Log
logHandler = do
  lines' <- IORef.newIORef []
  P.pure Abilities.Log
    { Abilities.note = \value0 -> IORef.modifyIORef' lines' (value0 :)
    }

-- | The native handler of Store Int32: load, save.
storeInt32Handler :: P.IO Abilities.StoreInt32
storeInt32Handler = do
  stored <- IORef.newIORef 0
  P.pure Abilities.StoreInt32
    { Abilities.storeInt32Load = IORef.readIORef stored
    , Abilities.storeInt32Save = \value0 -> IORef.writeIORef stored value0
    }

-- | The native handler of Store Text: load, save.
storeTextHandler :: P.IO Abilities.StoreText
storeTextHandler = do
  stored <- IORef.newIORef T.empty
  P.pure Abilities.StoreText
    { Abilities.storeTextLoad = IORef.readIORef stored
    , Abilities.storeTextSave = \value0 -> IORef.writeIORef stored value0
    }

-- | The native handler of Meter: reading.
meterHandler :: P.IO Abilities.Meter
meterHandler = P.pure Abilities.Meter
  { Abilities.reading = P.pure 3
  }
