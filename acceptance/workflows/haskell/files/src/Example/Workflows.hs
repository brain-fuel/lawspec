-- User-owned LawSpec adapter.
module Example.Workflows (audit, waitlist, checkName, checkAge, openAccount, checkStock, checkCredit, finished) where

import Control.Concurrent (threadDelay)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as T
import qualified LawSpecData as Data

audit :: Data.Account -> Bool
audit _ = True

waitlist :: Data.SignupError -> Either Data.SignupError Data.Account
waitlist Data.SignupErrorUnavailable = Right (Data.Account (T.pack "waitlist") 18 0)
waitlist failure = Left failure

checkName :: Data.Signup -> Either Data.SignupError Data.Signup
checkName signup@(Data.Signup name _)
  | T.null name = Left Data.SignupErrorMissingName
  | otherwise = Right signup

checkAge :: Data.Signup -> Either T.Text Data.Signup
checkAge signup@(Data.Signup _ age)
  | age < 18 = Left (T.pack "too young")
  | otherwise = Right signup

openAccount :: Data.Signup -> Either Data.SignupError Data.Account
openAccount (Data.Signup name age)
  | name == T.pack "taken" = Left Data.SignupErrorUnavailable
  | otherwise = Right (Data.Account name age 1)

-- | Each check records when it fails, so approvalErrors can tell completion
-- order from declaration order.
{-# NOINLINE finished #-}
finished :: IORef [T.Text]
finished = unsafePerformIO (newIORef [])

check :: Int -> T.Text -> Data.Order -> IO (Either T.Text Data.Order)
check micros problem order@(Data.Order number) = do
  if number == -1 then threadDelay micros else pure ()
  if number >= 0
    then pure (Right order)
    else do
      atomicModifyIORef' finished (\messages -> (messages ++ [problem], ()))
      pure (Left problem)

-- | Order -1's stock check takes 400ms; a negative order has no stock.
checkStock :: Data.Order -> IO (Either T.Text Data.Order)
checkStock = check 400000 (T.pack "no stock")

-- | Order -1's credit check takes 250ms; a negative order has no credit.
checkCredit :: Data.Order -> IO (Either T.Text Data.Order)
checkCredit = check 250000 (T.pack "no credit")
