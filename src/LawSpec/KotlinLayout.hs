-- | Kotlin layout as ktfmt's kotlinlang style lays it out, so generated
-- Kotlin is a fixed point of ktfmt (DEC-readable-output-default): 4-space
-- blocks, 100 columns, a broken argument list one argument a line with a
-- trailing comma when it has several, a lambda's body broken onto its own
-- lines, a declaration broken after its =, and a chained call broken
-- before its dot. Strings are Kotlin literals ($ escaped) and never split.
module LawSpec.KotlinLayout
  ( kotlinString, call, callWith, arguments, lambda, trailing, bind, chain, block, statements, kotlinStyle, pairTo, condition, equalsBody
  ) where

import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)

kotlinStyle :: D.Layout
kotlinStyle = D.PrettyDisplay 100

-- | A string literal.
kotlinString :: String -> D.Doc
kotlinString = D.text . literalFor "kotlin"

-- | name(a, b), or broken one argument a line.
call :: String -> [D.Doc] -> D.Doc
call name values = case break (== '.') (reverse name) of
  -- A qualified call whose opening does not fit breaks before its method.
  (method@(_ : _), '.' : receiver@(_ : _)) | not (null values) ->
    -- (Flat, a best fit takes the first; broken, the opening decides.)
    D.bestFit [callWith (D.text name) values, D.prefixChoice (name ++ "(") (callWith (D.text name) values)
      (D.text (reverse receiver) <> D.nest 4 (D.hardline <> callWith (D.text ('.' : reverse method)) values))]
  _ -> callWith (D.text name) values

callWith :: D.Doc -> [D.Doc] -> D.Doc
callWith name [] = name <> D.text "()"
callWith name [single] = D.group (name <> D.text "(" <> D.nest 4 (D.softbreak <> single) <> D.softbreak <> D.text ")")
callWith name values = D.group (name <> D.text "(" <> D.nest 4 (D.softbreak <> D.commaSep values <> D.whenBroken (D.text ",")) <>
  D.softbreak <> D.text ")")

-- | (a, b), or broken one argument a line, as a call's arguments.
arguments :: [D.Doc] -> D.Doc
arguments = callWith mempty

-- | { a, b -> body }: on one line when it fits, otherwise the body on
-- lines of its own. A body of several statements always breaks.
lambda :: [String] -> [D.Doc] -> D.Doc
lambda parameters body
  | length body > 1 || any spansLines body = D.multiline (opening <> D.nest 4 (D.hardline <> statements body) <> D.hardline <> D.text "}")
  | otherwise = D.group (opening <> D.nest 4 (D.softline <> statements body) <> D.softline <> D.text "}")
  where
    spansLines doc = '\n' `elem` D.render D.Compact doc
    opening = D.text "{" <> D.text (if null parameters then "" else " " ++ commaList parameters ++ " ->")
    commaList = foldr1 (\a b -> a ++ ", " ++ b)

-- | f(args) { params -> body }.
trailing :: D.Doc -> [String] -> [D.Doc] -> D.Doc
trailing invocation parameters body = invocation <> D.text " " <> lambda parameters body

-- | val name = value, broken after the = when it does not fit.
bind :: String -> D.Doc -> D.Doc
bind name value = D.group (D.text ("val " ++ name ++ " =") <> D.nest 4 (D.softline <> value))

-- | receiver.a(...).b(...): broken before each dot after the first call;
-- a broken receiver's arguments are indented past the chain's, as ktfmt
-- indents them.
chain :: D.Doc -> [(String, [D.Doc])] -> D.Doc
chain receiver methods = D.group (D.nest 4 (receiver <> mconcat [D.softbreak <> call ("." ++ m) args | (m, args) <- methods]))

-- | { ... } over statements.
block :: [D.Doc] -> D.Doc
block body = D.block 4 (statements body)

statements :: [D.Doc] -> D.Doc
statements = D.joinWith D.hardline

-- | a to b, broken after the to.
pairTo :: D.Doc -> D.Doc -> D.Doc
pairTo a b = D.group (a <> D.text " to" <> D.nest 4 (D.softline <> b))

-- | if (c) or while (c), the condition broken onto its own line when it
-- does not fit.
condition :: String -> D.Doc -> D.Doc
condition keyword c = D.group (D.text (keyword ++ " (") <> D.nest 4 (D.softbreak <> c) <> D.softbreak <> D.text ")")

-- | header = body, the body on its own line only when it does not fit after
-- the header's last line.
equalsBody :: D.Doc -> D.Doc -> D.Doc
equalsBody header body = header <> D.group (D.text " =" <> D.nest 4 (D.softline <> body))
