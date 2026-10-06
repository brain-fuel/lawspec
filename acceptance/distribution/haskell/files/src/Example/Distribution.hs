-- User-owned LawSpec adapter: the wire encoding, and nodes talking over
-- in-memory, TCP and HTTP transports (the asynchronous adapters, in IO).
module Example.Distribution (encoded, roundTrips, remoteShifted, openTally, add, remoteAdds, remoteDoubling, remoteLedger, remoteHandoff, remoteHandoffOnward, sealedOnTheWire, handshakeAgrees) where

import Control.Exception (finally)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecNetwork as Network
import qualified LawSpecRemote as Remote
import qualified LawSpecRuntime as LS
import LawSpecTransports (httpTransport, tcpTransport)
import LawSpecActors.Example.Distribution
import LawSpecSessions.Example.Distribution
import LawSpecMailboxes.Example.Distribution

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

remoteLedger :: I.Int32 -> IO I.Int64
remoteLedger x = do
  here <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  there <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  (do
    ledger <- serveLedger there "ledger"
    let sender = connectLedger here (LS.nodeAddress there ++ "/ledger")
    sendLedgerTo sender (fromIntegral x)
    sendLedgerTo sender (fromIntegral x)
    a <- receiveLedger ledger
    b <- receiveLedger ledger
    -- receive within: nothing more comes, so it gives Nothing in time.
    more <- receiveLedgerWithin 20000 ledger
    pure (maybe (a + b) (const (-1)) more)) `finally` (LS.closeNode here >> LS.closeNode there)

remoteHandoff :: I.Int32 -> IO I.Int64
remoteHandoff x = do
  here <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  there <- LS.newNode =<< tcpTransport "127.0.0.1" 0
  (do
    -- A local conversation on this node; its first end goes to the other.
    (first, second) <- openDoubling
    worker <- LS.spawn (do
      (value, reply) <- LS.receive second
      _ <- LS.send reply (2 * fromIntegral value :: I.Int64)
      pure ())
    giving <- listenHandoff here "handoff"
    taking <- dialHandoff there (LS.nodeAddress here ++ "/handoff")
    _ <- LS.send giving first
    (end, _) <- LS.receive taking
    next <- LS.send end x
    (result, _) <- LS.receive next
    LS.join worker
    pure result) `finally` (LS.closeNode there >> LS.closeNode here)

remoteHandoffOnward :: I.Int32 -> IO I.Int64
remoteHandoffOnward x = do
  network <- LS.newMemoryNetwork (fromIntegral x) 0.1 0.1 0.005
  [a, b, c, d] <- mapM (LS.newNode . LS.memoryTransport network) ["a", "b", "c", "d"]
  (do
    -- A conversation between A and C, which sends at once; A's end moves to
    -- B, then to D, and answers from there.
    first <- listenAnswering a "answering"
    dialled <- dialAnswering c (LS.nodeAddress a ++ "/answering")
    second <- LS.send dialled x
    toB <- listenPassing a "to-b"
    atB <- dialPassing b (LS.nodeAddress a ++ "/to-b")
    _ <- LS.send toB first
    (moved, _) <- LS.receive atB
    toD <- listenPassing b "to-d"
    atD <- dialPassing d (LS.nodeAddress b ++ "/to-d")
    _ <- LS.send toD moved
    (end, _) <- LS.receive atD
    -- The end no longer needs A or B.
    LS.closeNode a
    LS.closeNode b
    (value, reply) <- LS.receive end
    _ <- LS.send reply (2 * fromIntegral value :: I.Int64)
    (result, _) <- LS.receive second
    pure result) `finally` mapM_ LS.closeNode [a, b, c, d]

-- | A definition evaluated on another node: its request names the
-- definition's content hash, which shows on the wire only in the clear.
sealedOnTheWire :: I.Int32 -> IO Bool
sealedOnTheWire x = case Remote.digest name of
  Nothing -> pure False
  Just digest -> do
    let needle = TE.encodeUtf8 (T.pack digest)
    secure <- seen needle False
    insecure <- seen needle True
    pure (secure == Just False && insecure == Just True)
  where
    name = "example.distribution::shifted"
    seen needle insecure = do
      network <- LS.newRecordingMemoryNetwork (fromIntegral x .&. 0xFFFF) 0 0 0
      let make label = if insecure
            then LS.newNode (LS.insecureTransportForTests network label)
            else LS.newNode (LS.memoryTransport network label)
      here <- make "here"
      there <- make "there"
      (do
        _ <- Remote.serve there
        result <- Remote.evaluate here (LS.nodeAddress there) name [LS.SInteger "Int32" (toInteger x)]
        case result of
          LS.SInteger _ n | n == toInteger x + 1000 -> do
            records <- LS.networkRecorded network
            pure (Just (any (B.isInfixOf needle) records))
          _ -> pure Nothing) `finally` (LS.closeNode here >> LS.closeNode there)

-- | The handshake vector's thirteen fields, separated by single spaces.
handshakeAgrees :: T.Text -> Bool
handshakeAgrees text = case map T.unpack (T.splitOn (T.pack " ") text) of
  [a, b, c, d, e, f, g, h, i, j, k, l, m] -> Network.handshakeVector a b c d e f g h i j k l m
  _ -> False
