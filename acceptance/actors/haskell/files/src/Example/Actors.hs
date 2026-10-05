-- User-owned LawSpec adapter: an account's handlers, run inside an actor.
-- depositTwice uses the generated AccountActor from two threads; the
-- adapters are pure, so it runs them with unsafePerformIO.
module Example.Actors (openAccount, deposit, withdrawAll, balance, close, depositTwice) where

import qualified Data.Int as I
import qualified Data.Word as W
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import LawSpecActors.Example.Actors

openAccount :: () -> Data.Account
openAccount _ = Data.Account 0

deposit :: Data.Account -> W.Word8 -> Data.Pair I.Int64 Data.Account
deposit (Data.Account current) amount =
  let after = current + fromIntegral amount
  in Data.Pair after (Data.Account after)

withdrawAll :: Data.Account -> Data.Pair I.Int64 Data.Account
withdrawAll (Data.Account current) = Data.Pair current (Data.Account 0)

balance :: Data.Account -> Data.Pair I.Int64 Data.Account
balance account@(Data.Account current) = Data.Pair current account

close :: Data.Account -> Data.Account
close _ = Data.Account 0

-- The handlers are this module's own adapters.
handlers :: AccountHandlers
handlers = AccountHandlers
  { onOpenAccount = openAccount, onDeposit = deposit, onWithdrawAll = withdrawAll
  , onBalance = balance, onClose = close }

{-# NOINLINE depositTwice #-}
depositTwice :: W.Word8 -> I.Int64
depositTwice amount = unsafePerformIO $ do
  account <- startAccountActor handlers
  LS.par [() <$ accountDeposit account amount, () <$ accountDeposit account amount]
  total <- accountBalance account
  stopAccountActor account
  pure total
