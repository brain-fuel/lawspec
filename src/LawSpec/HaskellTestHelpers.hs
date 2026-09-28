-- Native Hedgehog strategies and Hspec assertions downstream of checked Core.
module LawSpec.HaskellTestHelpers (generatorDoc, assertionDoc, schemaDoc) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.HaskellExpr as E

text = D.text
number :: Show a => a -> D.Doc
number = text . show
quoted :: String -> D.Doc
quoted = text . show
apply = E.apply
parens = E.parens
statements = D.joinWith D.hardline
infixDoc a operator b = D.group (a <> D.nest 2 (D.softline <> text operator <> D.softline <> b))

schemaDoc :: D.Doc
schemaDoc = statements
  [text "_lawspecSchema :: Schema.Schema",
   text "_lawspecSchema = either error id DataSchema.schema"]

assertionDoc :: D.Doc
assertionDoc = statements
  [text "_lawspecAssert :: String -> Scalar -> Scalar -> IO ()",
   text "_lawspecAssert context actual expected = catch action handler" <>
   D.nest 2 (D.hardline <> text "where" <> D.nest 2 (D.hardline <> statements
     [text "action =" <> D.nest 2 (D.hardline <> statements
        [text "if LS.equal actual expected",
         text "  then pure ()",
         text "  else" <> D.nest 4 (D.hardline <> text "expectationFailure $" <>
           D.nest 2 (D.hardline <> D.group (D.joinWith (D.softline <> text "++ ")
             [text "context",quoted " | actual=",text "show actual",quoted " expected=",text "show expected"])))]),
      text "handler :: SomeException -> IO ()",
      D.group (text "handler e =" <> D.nest 2 (D.softline <> apply "expectationFailure"
        [infixDoc (text "context") "++" (infixDoc (quoted " | ") "++" (text "displayException e"))]))]))]

-- Preserve Hedgehog's native list/maybe/choice trees and integral shrinking.
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget structural reference key = gen
  where
    gen ty | structural ty = E.checked (apply "Strategies.strategy"
      [text "_lawspecSchema",reference ty,number bits,number budget,
       apply "Strategies.primitiveStrategy" [number bits]])
    gen (C.Constructor "List" [C.TypeArgument inner]) =
      infixDoc (text "SList") "<$>" (apply "Gen.list" [text "Range.linear 0 64",gen inner])
    gen (C.Constructor "Maybe" [C.TypeArgument inner]) =
      infixDoc (parens (text "maybe (SData \"Maybe::Nothing\" []) (\\value -> SData \"Maybe::Just\" [value])"))
        "<$>" (apply "Gen.maybe" [gen inner])
    gen (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = apply "Gen.choice"
      [E.array [sumGen "Either::Left" a,sumGen "Either::Right" b]]
    gen (C.Constructor wrapper [C.TypeArgument inner]) =
      infixDoc (apply "SPresent" [quoted wrapper]) "<$>" (apply "Gen.maybe" [gen inner])
    gen (C.Constructor name []) | isInteger name =
      let (lo,hi) = maybe (if name == "BigUInt" then (0,2^(256::Int)) else (-2^(256::Int),2^(256::Int))) id (integerBounds bits name)
      in infixDoc (apply "SInteger" [quoted name]) "<$>"
        (apply "Gen.integral" [apply "Range.linearFrom" [text "0",E.integerLiteral lo,E.integerLiteral hi]])
    gen (C.Constructor "Bool" []) = infixDoc (text "SBool") "<$>" (text "Gen.bool")
    gen ty = E.checked (apply "Strategies.primitiveStrategy" [number bits,quoted (key ty)])
    sumGen tag inner = infixDoc (parens (text "\\value -> " <> apply "SData" [quoted tag,E.array [text "value"]])) "<$>" (gen inner)
