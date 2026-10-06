-- User-owned LawSpec adapter.
module Example.Crypto where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified LawSpecAbilities.Example.Crypto as Abilities
import qualified Data.ByteString.Char8 as BC

-- Native code that gets lawspec.crypto's handlers as arguments.

-- (Bytes -> Bytes)
fingerprint :: Abilities.Hash -> B.ByteString -> P.IO B.ByteString
fingerprint hash key = do
  Data.Digest digest <- Abilities.sha3 hash key
  pure (B.take 8 digest)

-- (Bytes -> Bool)
roundTrip :: Abilities.Aead -> B.ByteString -> P.IO P.Bool
roundTrip aead message = do
  key <- Abilities.aeadKey aead
  let label = BC.pack "round trip"
  sealed <- Abilities.seal aead key message label
  opened <- Abilities.unseal aead key sealed label
  pure (opened == Just message)
