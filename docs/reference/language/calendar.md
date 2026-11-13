---
id: lawspec.reference.language.calendar
kind: reference
title: Calendar dates
---
# Calendar dates

A `Date` is a day in the proleptic Gregorian calendar, from 0001-01-01 to
9999-12-31. It is a whole number of days since 1970-01-01, so a date means the
same on every target. That range is the one every target's native date type
holds. A program uses dates by importing the built-in unit `lawspec.calendar`.

```lawspec
unit guide.meetings

import lawspec.calendar (Date, Weekday, addDays, weekdayOf, weekdayNumber,
  daysBetween)

-- The next day a weekly meeting falls on, on or after a date.
function nextOn (weekday :: Weekday) (date :: Date) -> Maybe Date is
  addDays date
    (prelude.rem (weekdayNumber weekday - weekdayNumber (weekdayOf date) + 7) 7)
end function

law "|the next meeting is on its weekday, within a week| is
  definition:
    for all (date :: Date where valueOfDate date <= 2932890) =>
      first matching case of nextOn Friday date:
        when Absent then false
        when Present meeting then
          weekdayOf meeting = Friday and daysBetween meeting date >= 0 and
            daysBetween meeting date <= 6
      end case
    end for all
  end definition
  example "|from a Thursday| :
    date = Date 20769
    expect nextOn Friday date = Present (Date 20770)
  end example
end law
end unit
```

## Types

| Type | Meaning |
| --- | --- |
| `Date` | A wrapper over `Integer`: days since 1970-01-01, from -719162 (0001-01-01) to 2932896 (9999-12-31). `valueOfDate date` is that number. |
| `Weekday` | `Monday`, `Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday` or `Sunday`. |
| `CivilDate` | A record with `year`, `month` (1 to 12) and `day` (1 to 31), each an `Integer`. |

## Operations

Every operation is a [checked definition](definitions.md), so it is total and
generated for every target; none needs native code.

| Expression | Result | Notes |
| --- | --- | --- |
| `dateOf year month day` | `Maybe Date` | `Absent` when the three numbers name no day in range, such as 29 February of a common year |
| `dateFromDays days` | `Maybe Date` | `Absent` outside the range |
| `civilOf date` | `CivilDate` | |
| `weekdayOf date` | `Weekday` | |
| `weekdayNumber weekday` | `Integer` | ISO 8601: Monday is 1, Sunday is 7 |
| `addDays date days` | `Maybe Date` | `days` may be negative; `Absent` outside the range |
| `daysBetween later earlier` | `Integer` | negative when `later` is the earlier date |
| `isLeapYear year` | `Bool` | |
| `daysInMonth year month` | `Integer` | 31 for a month outside 1 to 12 |
| `daysFromCivil year month day` | `Integer` | needs `year` from 1 to 9999, `month` from 1 to 12 and `day` from 1 to 31 |

Compare dates through `valueOfDate`: `valueOfDate a < valueOfDate b`. `=` and
`!=` apply to dates directly.

## What is checked

`examples/specs/calendar.lawspec` states the unit's laws, and
`lawspec prove --solver z3` proves each of them for every date in range:

- a date's civil form names that date;
- a week later is the same weekday;
- a year has 365 days, or 366 when it is a leap year;
- a month's last day is followed by the first of the next month;
- adding days moves a date by that many days.

The `calendar` acceptance suite runs the same laws on every target.

## Limits

- A `Date` has no time of day and no time zone. Turning an
  [`Instant`](time.md) into a date needs a zone's rules, which this unit does
  not hold.
- Generated code represents `Date` as a wrapper over the target's integer, not
  as the target's native date type.
- The calendar is Gregorian throughout. Dates before a country adopted it do
  not match that country's records.
