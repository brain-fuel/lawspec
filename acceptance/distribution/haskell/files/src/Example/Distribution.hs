-- User-owned LawSpec adapter: the wire encoding, and nodes talking over
-- in-memory, TCP and HTTP transports (the asynchronous adapters, in IO).
module Example.Distribution (encoded, roundTrips, remoteShifted, openTally, add, remoteAdds, remoteDoubling) where

import Control.Exception (finally)
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecRemote as Remote
import qualified LawSpecRuntime as LS
import LawSpecTransports (httpTransport, tcpTransport)
import LawSpecActors.Example.Distribution
import LawSpecSessions.Example.Distribution

encoded :: T.Text -> W.Word64 -> I.Int32 -> I.Int32 -> [T.Text]
encoded descriptor seed size count =
  map T.pack (LS.wireEncoded (T.unpack descriptor) seed (toInteger size) (toInteger count))

roundTrips :: T.Text -> W.Word64 -> I.Int32 -> I.Int32 -> Bool
roundTrips descriptor seed size count = LS.wireRoundTrips (T.unpack descriptor) seed (toInteger size) (toInteger count)

remoteShifted :: I.Int32 -> IO I.Int64
remoteShifted x = do
  network <- LS.newMemoryNetwork (fromIntegral x) 0.2 0.2 0
  here <- LS.newNode (LS.memoryTransport network "here")
  there <- LS.newNode (LS.memoryTransport network "there")
  _ <- Remote.serve there
  result <- Remote.evaluate here (LS.nodeAddress there) "example.distribution::shifted" [LS.SInteger "Int32" (toInteger x)]
  case result of
    LS.SInteger _ n -> pure (fromInteger n)
    other -> error ("not an integer: " ++ LS.renderValue other)

openTally :: () -> Data.Tally
openTally _ = Data.Tally 0

add :: Data.Tally -> W.Word8 -> Data.Pair I.Int64 Data.Tally
add (Data.Tally count) n = let after = count + fromIntegral n in Data.Pair after (Data.Tally after)

remoteAdds :: W.Word8 -> IO I.Int64
remoteAdds n = do
  server <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  client <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  (do
    tally <- startTallyActor (TallyHandlers { onOpenTally = openTally, onAdd = add })
    address <- serveTallyActor server "tally" tally
    let remote = connectTallyActor client address
    _ <- remoteTallyAdd remote n
    remoteTallyAdd remote n) `finally` (LS.closeNode client >> LS.closeNode server)

remoteDoubling :: I.Int32 -> IO I.Int64
remoteDoubling x = do
  server <- LS.newNode =<< httpTransport "127.0.0.1" 0
  client <- LS.newNode =<< httpTransport "127.0.0.1" 0
  (do
    first <- listenDoubling server "doubling"
    second <- dialDoubling client (LS.nodeAddress server ++ "/doubling")
    worker <- LS.spawn (do
      (value, reply) <- LS.receive second
      _ <- LS.send reply (2 * fromIntegral value :: I.Int64)
      pure ())
    next <- LS.send first x
    (result, _) <- LS.receive next
    LS.join worker
    pure result) `finally` (LS.closeNode client >> LS.closeNode server)
