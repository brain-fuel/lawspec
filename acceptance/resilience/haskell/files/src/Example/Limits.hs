-- User-owned LawSpec adapter.
module Example.Limits (admitTicket) where

import qualified Data.Text as T
import qualified LawSpecData as Data

admitTicket :: Data.Ticket -> Either T.Text Data.Ticket
admitTicket = Right
