-- User-owned LawSpec adapter: adds through a server process, talking to it
-- through the generated Serve ends, directly or through a hired manager. The
-- adapters are asynchronous: they run their processes in IO.
module Example.Sessions (add, addHired) where

import qualified Data.Int as I
import qualified LawSpecRuntime as LS
import LawSpecSessions.Example.Sessions

-- Receives two numbers and sends their sum.
server :: ServeFirstReceiveInt32Step1 -> IO ServeFirstDone
server end0 = do
  (a, end1) <- receive end0
  (b, end2) <- receive end1
  send end2 (fromIntegral a + fromIntegral b :: I.Int64)

-- Sends two numbers and receives their sum.
client :: I.Int32 -> I.Int32 -> ServeSecondSendInt32Step1 -> IO I.Int64
client a b end0 = do
  end1 <- send end0 a
  end2 <- send end1 b
  (total, _) <- receive end2
  pure total

-- Receives a server's end over a Hire channel and serves it.
manager :: HireSecondReceiveServe -> IO ()
manager hired = do
  (serving, _) <- receive hired
  _ <- server serving
  pure ()

add :: I.Int32 -> I.Int32 -> IO LS.IntegerValue
add a b = do
  (serving, asking) <- openServe
  worker <- spawn (server serving)
  total <- client a b asking
  _ <- join worker
  pure (LS.integerValue total)

addHired :: I.Int32 -> I.Int32 -> IO LS.IntegerValue
addHired a b = do
  (serving, asking) <- openServe
  (hiring, hired) <- openHire
  worker <- spawn (manager hired)
  _ <- send hiring serving
  total <- client a b asking
  join worker
  pure (LS.integerValue total)
