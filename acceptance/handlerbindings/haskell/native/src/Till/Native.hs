-- | Application code the till's bindings name: its own money type, a till
-- that is the production handler, and payments that throw its own
-- exceptions.
module Till.Native (Cash(..), CardDeclined(..), BadAmount(..), NativeTill(..), newNativeTill, pay) where

import Prelude hiding (take)
import Control.Exception (Exception, throwIO)
import qualified Data.IORef as IORef
import qualified Data.Int as I
import qualified LawSpecAbilities.Example.Till as Abilities
import qualified LawSpecData as Data

-- | The application's money.
data Cash = Cash { cashCents :: I.Int64 } deriving (Eq, Show)

data CardDeclined = CardDeclined deriving Show
instance Exception CardDeclined

newtype BadAmount = BadAmount String
instance Show BadAmount where
  show (BadAmount reason) = reason
instance Exception BadAmount

-- | A till that keeps what it takes, in the application's types.
data NativeTill = NativeTill
  { take :: Cash -> IO Cash
  , opening :: IO Cash
  }

newNativeTill :: IO NativeTill
newNativeTill = do
  taken <- IORef.newIORef (0 :: I.Int64)
  pure NativeTill
    { take = \money -> do
        IORef.modifyIORef' taken (+ cashCents money)
        pure (Cash (cashCents money))
    , opening = pure (Cash 0)
    }

-- | A bound adapter. It gets its drawer as the generated record.
pay :: Abilities.Drawer -> I.Int64 -> IO Cash
pay drawer cents
  | cents < 0 = throwIO (BadAmount "negative")
  | cents > 1000 = throwIO CardDeclined
  | otherwise = do
      money <- Abilities.take drawer (Data.Money cents)
      pure (Cash (Data.moneyCents money))
