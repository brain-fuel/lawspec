-- | Scenarios of processes and channels.
module ScenarioSpec (test_scenariosAreAcceptedOnlyWhenDeadlockAndRaceFree) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Model hiding (Expectation)

counter :: String
counter = unlines
  [ "unit example.counter"
  , "type Counter is Counter id :: Int32 end"
  , "newCounter :: Unit -> Counter"
  , "async increment :: Counter -> Int64"
  , "definition modelIncrement (n :: Int64 where n >= 0 && n <= 1000) :: Pair Int64 Int64 is Pair (n + 1) (n + 1) end"
  , "model counter :: shared Counter by Int64 is"
  , "  start newCounter ~ 0"
  , "  increment ~ modelIncrement"
  , "end"
  , "protocol Reply is"
  , "  send Int64"
  , "end"
  , "protocol Back is"
  , "  receive Int64"
  , "end"
  , "protocol Request is"
  , "  send Reply"
  , "end" ]

checks :: String -> Either String ()
checks extra = case compile [Source "scenario.lawspec" (counter ++ extra)] of
  Left diagnostics -> Left (concatMap show diagnostics)
  Right _ -> Right ()

rejects :: String -> String -> Expectation
rejects fragment extra = case checks extra of
  Left message -> message `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

-- | A scenario is reported as proved deadlock-free and race-free, so it may be
-- accepted only when its channels form a tree and every receive has a sender.
-- ref:DEC-sessions-by-construction ref:REQ-deadlock-free-scenarios
test_scenariosAreAcceptedOnlyWhenDeadlockAndRaceFree :: Spec
test_scenariosAreAcceptedOnlyWhenDeadlockAndRaceFree = describe "scenarios" $ do
  it "accept a mailbox with two senders" $
    checks (unlines
      [ "scenario `two report` in counter is"
      , "  mailbox reports of Int64"
      , "  par"
      , "    n <- increment"
      , "    send reports n"
      , "  with"
      , "    k <- increment"
      , "    send reports k"
      , "  with"
      , "    receive reports a"
      , "    receive reports b"
      , "  end"
      , "end" ]) `shouldBe` Right ()
  it "accept two channels between the same processes when neither waits for the other in a cycle" $
    checks (unlines
      [ "scenario `echo` in counter is"
      , "  channel a :: Reply"
      , "  channel b :: Back"
      , "  par"
      , "    n <- increment"
      , "    send a n"
      , "    receive b k"
      , "  with"
      , "    receive a m"
      , "    send b m"
      , "  end"
      , "end" ]) `shouldBe` Right ()
  it "accept a reply over a channel" $
    checks (unlines
      [ "scenario `a count is passed on` in counter is"
      , "  channel report :: Reply"
      , "  par"
      , "    n <- increment"
      , "    send report n"
      , "    expect n = 1"
      , "  with"
      , "    receive report m"
      , "  end"
      , "end" ]) `shouldBe` Right ()
  it "accept a delegated channel end" $
    checks (unlines
      [ "scenario `a delegated reply` in counter is"
      , "  channel ask :: Request"
      , "  channel answer :: Reply"
      , "  par"
      , "    send ask answer"
      , "  with"
      , "    receive ask reply"
      , "    n <- increment"
      , "    send reply n"
      , "  with"
      , "    receive answer m"
      , "  end"
      , "end" ]) `shouldBe` Right ()
  describe "reject" $ do
    it "an unfinished protocol" $
      rejects "is not finished: it still expects receive Int64" (unlines
        [ "protocol Exchange is"
        , "  send Int64"
        , "  receive Int64"
        , "end"
        , "scenario `x` in counter is"
        , "  channel trade :: Exchange"
        , "  par"
        , "    n <- increment"
        , "    send trade n"
        , "  with"
        , "    receive trade m"
        , "    send trade m"
        , "  end"
        , "end" ])
    it "a mailbox received from by two processes" $
      rejects "a mailbox has one receiver" (unlines
        [ "scenario `x` in counter is"
        , "  mailbox m of Int64"
        , "  par"
        , "    n <- increment"
        , "    send m n"
        , "    k <- increment"
        , "    send m k"
        , "  with"
        , "    receive m a"
        , "  with"
        , "    receive m b"
        , "  end"
        , "end" ])
    it "a mailbox message never received" $
      rejects "every message sent must be received" (unlines
        [ "scenario `x` in counter is"
        , "  mailbox m of Int64"
        , "  par"
        , "    n <- increment"
        , "    send m n"
        , "    send m n"
        , "  with"
        , "    receive m a"
        , "  end"
        , "end" ])
    it "a mailbox closing a cycle with a channel" $
      rejects "closes a cycle between processes" (unlines
        [ "scenario `x` in counter is"
        , "  mailbox m of Int64"
        , "  channel a :: Reply"
        , "  par"
        , "    receive m x"
        , "    n <- increment"
        , "    send a n"
        , "  with"
        , "    receive a y"
        , "    send m y"
        , "  end"
        , "end" ])
    it "processes that wait for each other in a cycle" $
      rejects "waits to receive on b before it sends on a" (unlines
        [ "scenario `x` in counter is"
        , "  channel a :: Reply"
        , "  channel b :: Back"
        , "  par"
        , "    receive b k"
        , "    n <- increment"
        , "    send a n"
        , "  with"
        , "    receive a m"
        , "    send b m"
        , "  end"
        , "end" ])
    it "a step out of order" $
      rejects "must send Int64 here, not receive" (unlines
        [ "scenario `x` in counter is"
        , "  channel a :: Reply"
        , "  par"
        , "    receive a m"
        , "  with"
        , "    n <- increment"
        , "    send a n"
        , "  end"
        , "end" ])
    it "a channel end used after it was delegated" $
      rejects "does not hold an end of channel answer" (unlines
        [ "scenario `x` in counter is"
        , "  channel ask :: Request"
        , "  channel answer :: Reply"
        , "  par"
        , "    send ask answer"
        , "    n <- increment"
        , "    send answer n"
        , "  with"
        , "    receive ask reply"
        , "    k <- increment"
        , "    send reply k"
        , "  with"
        , "    receive answer m"
        , "  end"
        , "end" ])
    it "a channel used by one process" $
      rejects "is used by one process only" (unlines
        [ "scenario `x` in counter is"
        , "  channel a :: Reply"
        , "  par"
        , "    n <- increment"
        , "    send a n"
        , "  with"
        , "    k <- increment"
        , "  end"
        , "end" ])
    it "an unknown model" $
      rejects "there is no model pool" (unlines
        [ "scenario `x` in pool is"
        , "  n <- increment"
        , "end" ])
