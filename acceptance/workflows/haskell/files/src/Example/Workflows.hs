-- User-owned LawSpec adapter.
module Example.Workflows (audit, waitlist, checkName, checkAge, openAccount) where

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
