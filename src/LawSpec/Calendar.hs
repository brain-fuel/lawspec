-- | Calendar dates: a built-in unit, lawspec.calendar, added to a program
-- that imports it. A Date is a whole number of days since 1970-01-01 in the
-- proleptic Gregorian calendar, from 0001-01-01 to 9999-12-31: the range every
-- target's native date holds (Python's datetime.date is the narrowest). Its
-- operations are checked LawSpec definitions, so they mean the same on every
-- target and their laws are checked like any other.
--
-- The civil conversions are Howard Hinnant's days_from_civil and
-- civil_from_days, which count years from March so that a leap day is a
-- year's last day. Within the Date range every dividend is non-negative, so
-- prelude.quot (toward zero) agrees with the floor division they need.
-- ref:DEC-calendar-date
module LawSpec.Calendar
  ( calendarUnit, calendarSource, firstDay, lastDay
  ) where

calendarUnit :: String
calendarUnit = "lawspec.calendar"

-- | 0001-01-01 and 9999-12-31, as days since 1970-01-01.
firstDay, lastDay :: Integer
firstDay = -719162
lastDay = 2932896

calendarSource :: String
calendarSource = unlines
  [ "unit " ++ calendarUnit
  , "-- A calendar date in the proleptic Gregorian calendar: a whole number of days"
  , "-- since 1970-01-01, from 0001-01-01 to 9999-12-31."
  , "wrapper Date is Integer where value >= " ++ first ++ " && value <= " ++ lastText ++ " end wrapper"
  , ""
  , "type Weekday is one of"
  , "  | Monday"
  , "  | Tuesday"
  , "  | Wednesday"
  , "  | Thursday"
  , "  | Friday"
  , "  | Saturday"
  , "  | Sunday"
  , "end type"
  , ""
  , "type CivilDate is a record{"
  , "  year :: Integer"
  , "  month :: Integer"
  , "  day :: Integer"
  , "}"
  , "end type"
  , ""
  , "function isLeapYear (year :: Integer) -> Bool is"
  , "  prelude.rem year 4 = 0 and (prelude.rem year 100 != 0 or prelude.rem year 400 = 0)"
  , "end function"
  , ""
  , "function daysInMonth (year :: Integer) (month :: Integer) -> Integer is"
  , "  if month = 2 then (if isLeapYear year then 29 else 28 end if)"
  , "  else if month = 4 or month = 6 or month = 9 or month = 11 then 30"
  , "  else 31 end if end if"
  , "end function"
  , ""
  , "function dateFromDays (days :: Integer) -> Maybe Date is"
  , "  if days >= " ++ first ++ " and days <= " ++ lastText ++ " then Present (Date days) else Absent end if"
  , "end function"
  , ""
  , "-- Days since 1970-01-01 of a civil date, counting years from March so that"
  , "-- the leap day is a year's last day."
  , "function daysFromCivil (year :: Integer where year >= 1 && year <= 9999)"
  , "    (month :: Integer where month >= 1 && month <= 12)"
  , "    (day :: Integer where day >= 1 && day <= 31) -> Integer is"
  , "  let y = (if month <= 2 then year - 1 else year end if) in"
  , "  let era = prelude.quot y 400 in"
  , "  let yearOfEra = y - era * 400 in"
  , "  let shifted = (if month > 2 then month - 3 else month + 9 end if) in"
  , "  let dayOfYear = prelude.quot (153 * shifted + 2) 5 + day - 1 in"
  , "  let dayOfEra = yearOfEra * 365 + prelude.quot yearOfEra 4 - prelude.quot yearOfEra 100 + dayOfYear in"
  , "    era * 146097 + dayOfEra - 719468"
  , "  end let end let end let end let end let end let"
  , "end function"
  , ""
  , "function dateOf (year :: Integer) (month :: Integer) (day :: Integer) -> Maybe Date is"
  , "  if year >= 1 and year <= 9999 and month >= 1 and month <= 12 and day >= 1 and"
  , "      day <= 31 and day <= daysInMonth year month"
  , "  then dateFromDays (daysFromCivil year month day)"
  , "  else Absent end if"
  , "end function"
  , ""
  , "function civilOf (date :: Date) -> CivilDate is"
  , "  let z = valueOfDate date + 719468 in"
  , "  let era = prelude.quot z 146097 in"
  , "  let dayOfEra = z - era * 146097 in"
  , "  let yearOfEra = prelude.quot (dayOfEra - prelude.quot dayOfEra 1460 + prelude.quot dayOfEra 36524 - prelude.quot dayOfEra 146096) 365 in"
  , "  let dayOfYear = dayOfEra - (365 * yearOfEra + prelude.quot yearOfEra 4 - prelude.quot yearOfEra 100) in"
  , "  let shifted = prelude.quot (5 * dayOfYear + 2) 153 in"
  , "  let month = (if shifted < 10 then shifted + 3 else shifted - 9 end if) in"
  , "    CivilDate record{"
  , "      year = yearOfEra + era * 400 + (if month <= 2 then 1 else 0 end if),"
  , "      month = month,"
  , "      day = dayOfYear - prelude.quot (153 * shifted + 2) 5 + 1"
  , "    }"
  , "  end let end let end let end let end let end let end let"
  , "end function"
  , ""
  , "function weekdayOf (date :: Date) -> Weekday is"
  , "  let index = prelude.rem (valueOfDate date + 719162) 7 in"
  , "    if index = 0 then Monday"
  , "    else if index = 1 then Tuesday"
  , "    else if index = 2 then Wednesday"
  , "    else if index = 3 then Thursday"
  , "    else if index = 4 then Friday"
  , "    else if index = 5 then Saturday"
  , "    else Sunday end if end if end if end if end if end if"
  , "  end let"
  , "end function"
  , ""
  , "-- ISO 8601's number for a weekday: Monday is 1 and Sunday is 7."
  , "function weekdayNumber (weekday :: Weekday) -> Integer is"
  , "  first matching case of weekday:"
  , "    when Monday then 1"
  , "    when Tuesday then 2"
  , "    when Wednesday then 3"
  , "    when Thursday then 4"
  , "    when Friday then 5"
  , "    when Saturday then 6"
  , "    when Sunday then 7"
  , "  end case"
  , "end function"
  , ""
  , "function addDays (date :: Date) (days :: Integer) -> Maybe Date is"
  , "  dateFromDays (valueOfDate date + days)"
  , "end function"
  , ""
  , "function daysBetween (later :: Date) (earlier :: Date) -> Integer is"
  , "  valueOfDate later - valueOfDate earlier"
  , "end function"
  , ""
  , "end unit" ]
  where
    first = show firstDay
    lastText = show lastDay
