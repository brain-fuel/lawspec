module SessionsPythonSpec (spec) where

import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Sessions.Python (pythonSessions)

-- Serve: receive two Int32s, send an Int64; Hire: send Serve's first end.
unit :: C.Unit
unit = C.MkUnit (C.Id "example.sessions") [] [] [] [] [] []
  [ C.Session (C.Id "example.sessions::session::Serve") "Serve"
      [(False, int32), (False, int32), (True, C.scalarType "Int64")]
  , C.Session (C.Id "example.sessions::session::Hire") "Hire"
      [(True, C.scalarType "example.sessions::session::Serve")] ]
  where int32 = C.scalarType "Int32"

spec :: Spec
spec = describe "Python sessions" $ do
  let source = either error id (pythonSessions [] [unit])
      has fragment = source `shouldSatisfy` isInfixOf fragment
  it "names each end's steps, numbering repeated names" $ do
    has "class ReceiveInt32Step1(ls.SessionEnd):"
    has "class ReceiveInt32Step2(ls.SessionEnd):"
    has "class SendInt64(ls.SessionEnd):"
    has "class SendInt32Step1(ls.SessionEnd):"
    has "class ReceiveInt64(ls.SessionEnd):"
  it "returns the next end from each step and opens both start ends" $ do
    has "def receive(self) -> tuple[int, Serve.First.ReceiveInt32Step2]:"
    has "def send(self, value: int) -> Serve.First.Done:"
    has "return Serve.First.ReceiveInt32Step1(channel, 0), Serve.Second.SendInt32Step1(channel, 1)"
  it "sends a delegated protocol's first end" $
    has "return self._send_end(value, Serve.First.ReceiveInt32Step1, Hire.First.Done)"
