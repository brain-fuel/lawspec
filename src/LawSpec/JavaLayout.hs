-- | Structured Java declarations, calls and statements. Callers provide
-- checked names, types and expressions as Docs; layout never reads Java back.
-- ref:DEC-readable-output-default
module LawSpec.JavaLayout where

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaExpr as E
import qualified Data.Set as S
import LawSpec.JvmNames (jvmClaim, jvmReserved)

call :: String -> [D.Doc] -> D.Doc
call = E.call

callWith :: D.Doc -> [D.Doc] -> D.Doc
callWith name [] = name <> D.text "()"
callWith name arguments = D.group (name <> D.text "(" <>
  D.nest 4 (D.softbreak <> D.group (D.commaSep arguments)) <> D.text ")")

applied :: String -> [D.Doc] -> D.Doc
applied name [] = D.text name
applied name arguments = D.group (D.text (name ++ "<") <>
  D.nest 4 (D.softbreak <> D.group (D.commaSep arguments)) <> D.text ">")

method :: D.Doc -> String -> [D.Doc] -> D.Doc
method receiver name arguments = D.group (receiver <> D.nest 4
  (D.softbreak <> call ('.' : name) arguments))

signature :: String -> D.Doc -> String -> [D.Doc] -> D.Doc
signature modifiers result name parameters = D.group
  (D.text modifiers <> result <> D.nest 4 (D.softline <> call name parameters))

parameter :: D.Doc -> String -> D.Doc
parameter ty name = D.group (ty <> D.nest 4 (D.softline <> D.text name))

block :: D.Doc -> [D.Doc] -> D.Doc
block header body = header <> D.hardline <> D.block 2 (D.joinWith D.hardline body)

statement :: D.Doc -> D.Doc
statement value = value <> D.text ";"

returned :: D.Doc -> D.Doc
returned value = D.group (D.text "return " <> value) <> D.text ";"

assigned :: D.Doc -> D.Doc -> D.Doc
assigned target value = D.group (target <> D.text " =" <>
  D.nest 4 (D.softline <> value)) <> D.text ";"

bind :: String -> D.Doc -> D.Doc
bind name = assigned (D.text ("var " ++ name))

lambda :: [String] -> [D.Doc] -> D.Doc
lambda parameters body = D.multiline
  (D.text (parameterNames ++ " -> ") <> D.block 2 (D.joinWith D.hardline body))
  where
    parameterNames = case parameters of
      [one] -> one
      _ -> "(" ++ comma parameters ++ ")"
    comma [] = ""
    comma [one] = one
    comma (first : rest) = first ++ ", " ++ comma rest

lambdaValue :: [String] -> D.Doc -> D.Doc
lambdaValue parameters value = D.group (D.text (parameterNames ++ " ->") <>
  D.nest 4 (D.softline <> value))
  where parameterNames = case parameters of [one] -> one; _ -> "(" ++ comma parameters ++ ")"
        comma [] = ""
        comma [one] = one
        comma (first : rest) = first ++ ", " ++ comma rest

-- | Generated binders share Java's lexical scope with the supplied parameters.
fresh :: [String] -> String -> String
fresh taken name = fst (jvmClaim (S.fromList (jvmReserved "java" ++ taken)) name)
