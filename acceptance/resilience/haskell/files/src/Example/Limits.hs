-- User-owned LawSpec adapter.
module Example.Limits (admitTicket, reserveSeat, chargeCard, releaseSeat) where

import qualified Data.Text as T
import qualified LawSpecData as Data

admitTicket :: Data.Ticket -> Either T.Text Data.Ticket
admitTicket = Right

reserveSeat :: Data.Ticket -> Either T.Text Data.Ticket
reserveSeat = Right

chargeCard :: Data.Ticket -> Either T.Text Data.Ticket
chargeCard ticket@(Data.Ticket number)
  | number < 0 = Left (T.pack "declined")
  | otherwise = Right ticket

releaseSeat :: Data.Ticket -> Bool
releaseSeat _ = True
