-- | Python's assertion helpers, with layout supplied by the caller.
-- (JavaScript's are the runtime's ls.check and ls.checkData.)
module LawSpec.PortableTestHelpers (assertionHelperDoc, dataHelperDoc) where

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonExpr as Python

-- | Assertions report the law, the inputs and both sides, so a failure
-- explains itself.
assertionHelperDoc :: D.Doc
assertionHelperDoc = assertionHelper False

-- | Data values are built and compared through helpers emitted once per test
-- module rather than at every use.
dataHelperDoc :: Int -> Int -> [D.Doc] -> D.Doc
dataHelperDoc _ budget entries = D.joinWith separation
  [D.text "_lawspec_schema = " <> Python.call "data.make_schema" [],
   D.text "_lawspec_primitive_generators = " <> D.delimitTrailing 4 "{" "}" entries,
   function "_lawspec_data_generator" ["ty"]
    (D.text "return " <> Python.call "_data_strategy"
      [D.text "_lawspec_schema",D.text "ty",D.text "MACHINE_BITS",D.text (show budget),
       D.text "_lawspec_primitive_generators.__getitem__"]),
   assertionHelper True]
  where
    separation = D.hardline <> D.hardline <> D.hardline

function :: String -> [String] -> D.Doc -> D.Doc
function name parameters body =
  Python.suite (D.text ("def " ++ name) <> D.delimitTrailing 4 "(" ")" (map D.text parameters)) body

assertionHelper :: Bool -> D.Doc
assertionHelper structural = function name parameters guarded
  where
    name = if structural then "_lawspec_data_assert" else "_lawspec_assert"
    parameters = ["context","actual","expected"] ++ if structural then ["ty","symbols"] else ["ta","tb"]
    equal = if structural
      then Python.call "_lawspec_schema.equal" (map D.text ["ty","a","b","MACHINE_BITS","symbols"])
      else Python.call "ls.equal" (map D.text ["a","b","ta","tb"])
    -- As ruff lays it out: the message moves into parentheses of its own.
    pythonAssert = D.text "assert " <> equal <> D.text ", (" <> D.nest 4 (D.hardline <>
      D.text "f\"{context} | actual={a!r}, expected={b!r}{ls.difference(a, b)}\"") <> D.hardline <> D.text ")"
    body = D.joinWith D.hardline [D.text "a, b = actual(), expected()", pythonAssert]
    guarded = Python.suite (D.text "try") body <> D.hardline <>
      Python.suite (D.text "except Exception as error")
        (D.text "raise AssertionError(f\"{context}: {error}\") from error")
