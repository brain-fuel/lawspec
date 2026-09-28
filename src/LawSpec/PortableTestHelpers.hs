-- Framework-specific assertion helpers, with layout supplied by the caller.
module LawSpec.PortableTestHelpers (assertionHelperDoc, dataHelperDoc) where

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonExpr as Python
import qualified LawSpec.WebExpr as Web

assertionHelperDoc :: Bool -> D.Doc
assertionHelperDoc py = assertionHelper py Nothing

dataHelperDoc :: Bool -> Int -> Int -> [D.Doc] -> D.Doc
dataHelperDoc py bits budget entries = D.joinWith separation
  [statement ((if py then "" else "const ") ++ "_lawspec_schema = ")
    (call (if py then "data.make_schema" else "data.makeSchema") []),
   statement ((if py then "" else "const ") ++ "_lawspec_primitive_generators = ")
    (D.delimitTrailing indentation "{" "}" entries),
   function py "_lawspec_data_generator" ["ty"]
    (statement "return " (call "_data_strategy"
      [D.text "_lawspec_schema",D.text "ty",D.text (show bits),D.text (show budget),
       D.text (if py then "_lawspec_primitive_generators.__getitem__"
         else "(name) => _lawspec_primitive_generators[name]")])),
   assertionHelper py (Just bits)]
  where
    indentation = if py then 4 else 2
    separation = D.hardline <> D.hardline <> if py then D.hardline else mempty
    call = if py then Python.call else Web.call
    statement prefix value = D.text prefix <> value <> if py then mempty else D.text ";"

function :: Bool -> String -> [String] -> D.Doc -> D.Doc
function py name parameters body =
  let signature = D.text ((if py then "def " else "function ") ++ name) <>
        D.delimitTrailing (if py then 4 else 2) "(" ")" (map D.text parameters)
  in if py then Python.suite signature body else signature <> D.text " " <> D.block 2 body

assertionHelper :: Bool -> Maybe Int -> D.Doc
assertionHelper py profile = function py name parameters guarded
  where
    call = if py then Python.call else Web.call
    structural = maybe False (const True) profile
    name = if structural then "_lawspec_data_assert" else if py then "_lawspec_assert" else "_lawspecAssert"
    parameters = ["context","actual","expected"] ++ if structural then ["ty","symbols"] else ["ta","tb"]
    equal = case profile of
      Nothing -> call "ls.equal" (map D.text ["a","b","ta","tb"])
      Just bits -> call "_lawspec_schema.equal" (map D.text
        (["ty"] ++ (if py then ["a","b"] else ["actual()","expected()"]) ++ [show bits] ++ ["symbols"]))
    pythonAssert = D.group (D.text "assert (" <> D.nest 4 (D.softbreak <> equal) <>
      D.softbreak <> D.text "), f'{context} | actual={a!r}, expected={b!r}'")
    javascriptAssert = call "assert.ok"
      [equal,D.text (if structural then "context" else "`${context} | actual=${String(a)}, expected=${String(b)}`")] <> D.text ";"
    body = D.joinWith D.hardline $
      (if py then [D.text "a, b = actual(), expected()"]
       else if structural then [] else [D.text "const a = actual();",D.text "const b = expected();"]) ++
      [if py then pythonAssert else javascriptAssert]
    guarded = if py then Python.suite (D.text "try") body <> D.hardline <>
      Python.suite (D.text "except Exception as error")
        (D.text "raise AssertionError(f'{context}: {error}') from error")
      else D.text "try " <> D.block 2 body <>
        D.text " catch (error) " <> D.block 2
          (D.text "throw " <> call "new Error"
            [D.text "`${context}: ${error.message}`",D.text "{cause: error}"] <> D.text ";")
