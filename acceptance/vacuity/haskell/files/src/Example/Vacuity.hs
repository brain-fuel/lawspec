-- User-owned LawSpec adapter for example.vacuity.
module Example.Vacuity where

import qualified Data.Char as Char
import qualified Data.Text as T
import qualified LawSpecData as Data
import Prelude
import qualified Prelude as P

-- shout :: Text -> Text — vacuity.lawspec:26
shout :: T.Text -> T.Text
shout name = T.toUpper name

-- abbreviate :: example.vacuity::type::Stage -> Text — vacuity.lawspec:27
abbreviate :: Data.Stage -> T.Text
abbreviate stage = Data.stageToken stage

-- accepts :: example.vacuity::type::Proposal -> Bool — vacuity.lawspec:28
-- Accepts only codes such as OFFER-2026-AB: no random record has one.
accepts :: Data.Proposal -> P.Bool
accepts offer = offerCode (T.unpack (Data.proposalCode offer)) P.&& Data.proposalAmount offer P.> 0
  where
    offerCode ('O' : 'F' : 'F' : 'E' : 'R' : '-' : a : b : c : d : '-' : [x, y]) =
      P.all Char.isDigit [a, b, c, d] P.&& P.all (`P.elem` ['A' .. 'Z']) [x, y]
    offerCode _ = P.False

-- describe :: example.vacuity::type::Proposal -> Text — vacuity.lawspec:29
describe :: Data.Proposal -> T.Text
describe offer = Data.proposalCode offer

-- keep :: Text -> Text — vacuity.lawspec:30
keep :: T.Text -> T.Text
keep key = key
