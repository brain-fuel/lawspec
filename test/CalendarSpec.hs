-- | Calendar dates: the built-in unit lawspec.calendar.
module CalendarSpec (test_calendarDatesAreCheckedDefinitions) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Calendar (calendarSource, firstDay, lastDay)
import LawSpec.Compile
import LawSpec.Model hiding (Expectation)

check :: String -> Either [Diagnostic] ([Unit], [Expanded])
check source = compile [Source "source.lawspec" source]

unit :: [String] -> String
unit body = unlines (["unit probe.calendar", ""] ++ body ++ ["end unit"])

-- | A date means the same day on every target, so the unit is LawSpec source
-- that the compiler checks, joined to a program only when it is imported.
-- ref:DEC-calendar-date
test_calendarDatesAreCheckedDefinitions :: Spec
test_calendarDatesAreCheckedDefinitions = describe "calendar dates" $ do
  it "span 0001-01-01 to 9999-12-31 as days since 1970-01-01" $ do
    (firstDay, lastDay) `shouldBe` (-719162, 2932896)
    calendarSource `shouldSatisfy` isInfixOf "value >= -719162 && value <= 2932896"
  it "are available to a unit that imports lawspec.calendar" $
    case check (unit
      [ "import lawspec.calendar (Date, Weekday, weekdayOf, dateOf)"
      , "law \"|the epoch| is definition: weekdayOf (Date 0) = Thursday and dateOf 1970 1 1 = Present (Date 0) end definition end law" ]) of
      Left diagnostics -> expectationFailure (concatMap show diagnostics)
      Right _ -> pure ()
  it "are not added to a unit that does not import them" $
    case check (unit ["law \"|no dates| is definition: weekdayOf (Date 0) = Thursday end definition end law"]) of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected Date to be unknown without the import"
  it "reserve the unit name" $
    case check "unit lawspec.calendar\n\ntype T is one of | A end type\nend unit\n" of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "reserved"
      Right _ -> expectationFailure "expected the unit name to be reserved"
