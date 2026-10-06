-- | Application code: the Signature and KeyExchange handlers bound in
-- lawspec.json in place of the defaults. Each passes its operations on to
-- the default handler and counts them.
module Example.Keys (newCountingSigner, newCountingExchange) where

import qualified Data.ByteString as B
import qualified Data.Bits as Bits
import qualified Data.IORef as IORef
import qualified Lawspec.Crypto as Crypto
import qualified LawSpecAbilities.Lawspec.Crypto as Abilities
import qualified LawSpecData as Data

newCountingSigner :: IO Abilities.Signature
newCountingSigner = do
  inner <- Crypto.signatureHandler
  count <- IORef.newIORef (0 :: Int)
  pure Abilities.Signature
    { Abilities.signingKeyPair = Abilities.signingKeyPair inner
    , Abilities.sign = \key message -> IORef.modifyIORef' count (+ 1) >> Abilities.sign inner key message
    , Abilities.verify = \key message signature -> Abilities.verify inner key message signature
    }

newCountingExchange :: IO Abilities.KeyExchange
newCountingExchange = do
  inner <- Crypto.keyExchangeHandler
  count <- IORef.newIORef (0 :: Int)
  pure Abilities.KeyExchange
    { Abilities.exchangeKeyPair = Abilities.exchangeKeyPair inner
    , Abilities.encapsulate = \key -> IORef.modifyIORef' count (+ 1) >> Abilities.encapsulate inner key
    , Abilities.decapsulate = \key ciphertext -> Abilities.decapsulate inner key ciphertext
    }
