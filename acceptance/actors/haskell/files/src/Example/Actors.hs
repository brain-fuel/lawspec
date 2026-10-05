-- User-owned LawSpec adapter: an account's handlers, run inside an actor.
-- depositTwice uses the generated AccountActor from two threads, and
-- survivesCrash the generated bank supervisor; the adapters are pure, so
-- they run them with unsafePerformIO.
module Example.Actors (openAccount, deposit, withdrawAll, balance, close, reopen, depositTwice, survivesCrash) where

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

reopen :: Data.Account -> Data.Account
reopen (Data.Account current) = Data.Account current

-- The handlers are this module's own adapters.
handlers :: AccountHandlers
handlers = AccountHandlers
  { onOpenAccount = openAccount, onDeposit = deposit, onWithdrawAll = withdrawAll
  , onBalance = balance, onClose = close, onReopen = reopen }

{-# NOINLINE depositTwice #-}
depositTwice :: W.Word8 -> I.Int64
depositTwice amount = unsafePerformIO $ do
  account <- startAccountActor handlers
  LS.par [() <$ accountDeposit account amount, () <$ accountDeposit account amount]
  total <- accountBalance account
  stopAccountActor account
  pure total

{-# NOINLINE survivesCrash #-}
survivesCrash :: W.Word8 -> I.Int64
survivesCrash amount = unsafePerformIO $ do
  bank <- startBankSupervisor handlers
  _ <- accountDeposit (bankAccount bank) amount
  crashAccountActor (bankAccount bank)
  total <- accountBalance (bankAccount bank)
  stopBankSupervisor bank
  pure total
