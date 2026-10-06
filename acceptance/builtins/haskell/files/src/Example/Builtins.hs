-- User-owned LawSpec adapter.
module Example.Builtins where

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
import qualified LawSpecAbilities.Example.Builtins as Abilities
import qualified Control.Exception as Exception
import qualified Network.Socket as Socket

-- Native code that gets the built-in abilities' handlers as arguments.

-- (Int32 -> lawspec.time::type::Duration)
elapsed :: Abilities.Clock -> I.Int32 -> P.IO Data.Duration
elapsed clock n = do
  Data.Instant start <- Abilities.now clock
  P.mapM_ (P.const (Abilities.now clock)) [1 .. n]
  Data.Instant end <- Abilities.now clock
  pure (Data.Duration (P.toInteger (end - start)))

-- (Int32 -> Bytes)
token :: Abilities.SecureRandom -> I.Int32 -> P.IO B.ByteString
token secureRandom n = Abilities.secureBytes secureRandom n

-- (Int32 -> Bool)
listening :: Abilities.Ports -> I.Int32 -> P.IO P.Bool
listening ports _ = do
  port <- Abilities.freePort ports
  Exception.bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \server -> do
    Socket.setSocketOption server Socket.ReuseAddr 1
    Socket.bind server (Socket.SockAddrInet (P.fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
    pure True

-- (Int32 -> Bool)
charge :: Abilities.Log -> I.Int32 -> P.IO P.Bool
charge log' cents
  | P.even cents = do
      Abilities.logMessage log' Data.LogLevelInfo (T.pack ("charged " ++ P.show cents))
      pure True
  | otherwise = pure False
