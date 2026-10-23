-- | Kotlin layout as ktfmt's kotlinlang style lays it out, so generated
-- Kotlin is a fixed point of ktfmt (DEC-readable-output-default): 4-space
-- blocks, 100 columns, a broken argument list one argument a line with a
-- trailing comma when it has several, a lambda's body broken onto its own
-- lines, a declaration broken after its =, and a chained call broken
-- before its dot. Strings are Kotlin literals ($ escaped) and never split.
module LawSpec.KotlinLayout
  ( kotlinString, operators, call, callThen, selects, castCall, cast, callWith, arguments, lambda, trailing, trailingCall, bind, chain, block, statements, kotlinStyle, pairTo, condition, equalsBody
  ) where

import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)

kotlinStyle :: D.Layout
kotlinStyle = D.PrettyPoints 100

-- | A string literal.
kotlinString :: String -> D.Doc
kotlinString = D.text . literalFor "kotlin"

-- | name(a, b), or broken one argument a line.
call :: String -> [D.Doc] -> D.Doc
call name values = callThen name values mempty

-- | A call followed by what goes with it (a trailing lambda), which is
-- indented with the call when the call breaks before its method.
callThen :: String -> [D.Doc] -> D.Doc -> D.Doc
callThen name values suffix = case break (== '.') (reverse name) of
  -- A qualified call whose opening does not fit breaks before its method,
  -- and a package's name (lawspec.runtime.Bodies.f) before each class.
  (method@(_ : _), '.' : receiver@(_ : _)) | not (null values) ->
    -- (Flat, a best fit takes the first; broken, the opening decides.)
    D.bestFit [callWith (D.text name) values <> suffix, D.prefixChoice (name ++ "(") (callWith (D.text name) values <> suffix)
      (D.text package <> D.nest 4 (mconcat [D.hardline <> D.text ('.' : c) | c <- classes] <> D.hardline <> callWith (D.text ('.' : reverse method)) values <> suffix))]
    where
      segments = splitDots (reverse receiver)
      (lower, upper) = span startsLower segments
      (package, classes) = case (lower, upper) of
        ([], first : rest) -> (first, rest)
        (_ : _, []) -> (joinDots lower, [])
        (_, _) -> (joinDots lower, upper)
      startsLower s = take 1 s /= [] && head s `elem` ['a' .. 'z']
      joinDots = foldr1 (\a b -> a ++ "." ++ b)
      splitDots s = case break (== '.') s of
        (a, []) -> [a]
        (a, _ : b) -> a : splitDots b
  _ -> callWith (D.text name) values <> suffix

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

-- | f(args) { params -> body }: the arguments stay on the line when they
-- fit up to the lambda's opening, as ktfmt keeps them; broken arguments
-- break the lambda's body too.
trailing :: D.Doc -> [String] -> [D.Doc] -> D.Doc
trailing invocation parameters body
  | '\n' `elem` flat = broken
  | otherwise = D.bestFit [D.text (flat ++ " ") <> lambda parameters body, D.prefixChoice opening (D.text (flat ++ " ") <> lambda parameters body) broken]
  where
    flat = D.render D.Compact invocation
    broken = invocation <> D.text " " <> D.multiline (lambdaOpening parameters <> D.nest 4 (D.hardline <> statements body) <> D.hardline <> D.text "}")
    opening = flat ++ " " ++ D.render D.Compact (lambdaOpening parameters)

-- | name(args) { params -> body }.
trailingCall :: String -> [D.Doc] -> [String] -> [D.Doc] -> D.Doc
trailingCall name args = trailing (call name args)

lambdaOpening :: [String] -> D.Doc
lambdaOpening parameters = D.text "{" <> D.text (if null parameters then "" else " " ++ foldr1 (\a b -> a ++ ", " ++ b) parameters ++ " ->")

-- | Operands joined by an operator (&&, ||). When the first operand fits on
-- the line, a chain that does not fit breaks after every operator, the
-- later operands indented; when the first must break itself, the rest
-- follow its last line, as ktfmt lays them out.
operators :: String -> [D.Doc] -> D.Doc
operators _ [] = mempty
operators _ [single] = single
operators op (first : rest) = D.prefixChoice (D.render D.Compact first ++ " " ++ op)
  (D.group (first <> D.nest 4 (mconcat [D.text (" " ++ op) <> D.softline <> o | o <- rest])))
  (first <> mconcat [D.group (D.text (" " ++ op) <> D.nest 4 (D.softline <> o)) | o <- rest])

-- | val name = value, broken after the = when it does not fit.
bind :: String -> D.Doc -> D.Doc
bind name value = D.group (D.text ("val " ++ name ++ " =") <> D.nest 4 (D.softline <> value))

-- | receiver.a(...).b(...): broken before each dot after the first call;
-- a broken receiver's arguments are indented past the chain's, as ktfmt
-- indents them.
chain :: D.Doc -> [(String, [D.Doc])] -> D.Doc
chain receiver methods = D.group (D.nest 4 (receiver' <> mconcat [D.softbreak <> call ("." ++ m) args | (m, args) <- methods]))
  where
    -- A receiver that is a call on a class (Codecs.orderCodec(...)) stays
    -- whole when it fits; otherwise it breaks before its method, at the
    -- chain's indentation. One on a value breaks before each dot.
    flat = D.render D.Compact receiver
    receiver' = case qualifiedCall flat of
      Just (owner, method, args) ->
        let broken = D.text owner <> D.softbreak <> callWith (D.text ('.' : method)) (map D.text args)
        in if take 1 owner `elem` map pure ['a' .. 'z'] && '.' `notElem` owner then broken
           -- A constant (SCHEMA) is a value, not a class: its call keeps its dot.
           else if all (\c -> c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c == '_') owner then receiver
           else D.bestFit [D.text flat, broken]
      Nothing -> receiver

-- | Owner.method(a, b) in one line's text: the owner, method and arguments.
qualifiedCall :: String -> Maybe (String, String, [String])
qualifiedCall text
  | '\n' `elem` text = Nothing
  | otherwise = case break (== '(') text of
      (path, '(' : rest) | not (null rest), last rest == ')', all pathChar path, closes (init rest) ->
        case break (== '.') (reverse path) of
          (method@(_ : _), '.' : owner@(_ : _)) -> Just (reverse owner, reverse method, arguments (init rest))
          _ -> Nothing
      _ -> Nothing
  where
    pathChar c = c `elem` ("._" :: String) || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9']
    -- The arguments' text closes every bracket it opens, outside strings.
    closes s = go (0 :: Int) s
      where
        go depth [] = depth == 0
        go depth ('"' : rest) = go depth (skipString rest)
        go depth (c : rest)
          | c `elem` ("([{<" :: String) = go (depth + 1) rest
          | c `elem` (")]}>" :: String) = depth > 0 && go (depth - 1) rest
          | otherwise = go depth rest
    skipString ('\\' : _ : rest) = skipString rest
    skipString ('"' : rest) = rest
    skipString (_ : rest) = skipString rest
    skipString [] = []
    -- Top-level arguments, split at commas outside brackets and strings.
    arguments s = map (dropWhile (== ' ')) (split (0 :: Int) "" s)
    split _ current [] = [reverse current | not (null current)]
    split depth current ('"' : rest) = let (str, after) = stringPrefix rest in split depth (reverse ('"' : str) ++ current) after
    split depth current (c : rest)
      | c == ',' && depth == 0 = reverse current : split depth "" rest
      | c `elem` ("([{<" :: String) = split (depth + 1) (c : current) rest
      | c `elem` (")]}>" :: String) = split (depth - 1) (c : current) rest
      | otherwise = split depth (c : current) rest
    stringPrefix s = go' "" s
      where
        go' acc ('\\' : c : rest) = go' (c : '\\' : acc) rest
        go' acc ('"' : rest) = (reverse ('"' : acc), rest)
        go' acc (c : rest) = go' (c : acc) rest
        go' acc [] = (reverse acc, [])

-- | (name(args) as T): when the call fits on the line it stays whole and the
-- cast breaks before its as; otherwise the call breaks its arguments and
-- the cast follows its closing parenthesis, as ktfmt chooses.
castCall :: String -> [D.Doc] -> String -> D.Doc
castCall name values target = D.prefixChoice ("(" ++ flat)
  (D.text "(" <> call name values <> D.group (D.nest 4 (D.softline <> D.group (D.text "as" <> D.softline <> D.text target))) <> D.text ")")
  (D.text "(" <> callThen name values (D.text (" as " ++ target ++ ")")))
  where flat = D.render D.Compact (call name values)

-- | (value as T), broken before the as when it does not fit.
cast :: D.Doc -> String -> D.Doc
cast value target = D.text "(" <> value <> D.group (D.nest 4 (D.softline <> D.text ("as " ++ target))) <> D.text ")"

-- | receiver.a(...).b: selections broken before each dot, as chain.
selects :: D.Doc -> [D.Doc] -> D.Doc
selects receiver parts = D.group (D.nest 4 (receiver <> mconcat [D.softbreak <> p | p <- parts]))

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
