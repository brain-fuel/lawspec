-- | Canonical anonymous record source shared by native and WASM probes.
-- ref:DEC-readable-notation ref:DEC-typed-core-boundary
module SourceRecordCanonicalFixtures (recordSource) where

recordSource :: String
recordSource = unlines
  [ "unit example.records"
  , "function double (value of type record{count of type Integer}) -> record{count of type Integer} is"
  , "  record{count = value.count + value.count}"
  , "end function"
  , "function wrap (value of type a) -> record{wrapped of type a} is record{wrapped = value} end function"
  , "law doubles is"
  , "  definition: for all (value of type record{count of type Integer}) =>"
  , "    (double value).count = value.count + value.count"
  , "  end end"
  , "  expect double value = expected"
  , "  in table (value, expected):"
  , "    row record{count = -1}, record{count = -2}"
  , "    row record{count = 0}, record{count = 0}"
  , "    row record{count = 1}, record{count = 2}"
  , "  end"
  , "end"
  , "law wraps is definition: (wrap true).wrapped = true end end"
  , "law ordered is definition: record{a = 1, b = true} = record{b = true, a = 1} end end"
  , "law nested is definition: record{inner = record{count = 4}}.inner.count = 4 end end"
  , "law empty is definition: record{} = record{} end end" ]
