-- | Scala layout as scalafmt's default configuration accepts it, so generated
-- Scala is a fixed point of scalafmt (DEC-readable-output-default): 2-space
-- blocks, 80 columns, a broken argument list one argument a line with its
-- closing parenthesis on a line of its own and no trailing comma, a
-- definition's broken parameters indented 4, a chained call broken before
-- each dot, and a lambda's body on lines of its own once it does not fit.
-- Strings are Scala literals and never split.
module LawSpec.ScalaLayout
  ( scalaStyle, scalaString, arrow, chainWith, call, callThen, callWith, trailingChain, trailingChain', parameters, lambda, trailing, trailingCall, bind, bindControl, bindBlock, chain, block, statements
  , condition, conjunction, conjunctionStatement, equalsBody, comment
  ) where

import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)
import LawSpec.CallText (CallTree(..), parseCall)

scalaStyle :: D.Layout
scalaStyle = D.PrettyPoints 80

-- | A string literal.
scalaString :: String -> D.Doc
scalaString = D.text . literalFor "scala"

-- | params => body: on the line when it fits, otherwise the body on the
-- next line; a body of several lines (a block) starts after the arrow.
arrow :: String -> D.Doc -> D.Doc
arrow params body
  | take 1 flat == "{" = D.text (params ++ " => ") <> body
  | '\n' `elem` flat = D.text (params ++ " =>") <> D.nest 2 (D.hardline <> body)
  | otherwise = D.group (D.text (params ++ " =>") <> D.nest 2 (D.softline <> body))
  where flat = D.render D.Compact body

-- | name(args) followed by what goes with it (a trailing lambda), indented
-- with the call when the call breaks before its method.
callThen :: String -> [D.Doc] -> D.Doc -> D.Doc
callThen name values suffix = case break (== '.') (reverse name) of
  (method@(_ : _), '.' : owner@(_ : _)) | not (null values), all (`notElem` name) ("([" :: String) ->
    D.bestFit [callWith (D.text name) values <> suffix, D.prefixChoice (name ++ "(") (callWith (D.text name) values <> suffix)
      (D.text (reverse owner) <> D.nest 2 (D.hardline <> callWith (D.text ('.' : reverse method)) values <> suffix))]
  _ -> callWith (D.text name) values <> suffix

-- | name(a, b), or broken one argument a line.
call :: String -> [D.Doc] -> D.Doc
call name values = case break (== '[') name of
  -- A method with type arguments (Scala.handler[T]) breaks before its dot
  -- when its opening does not fit, and its type arguments break inside
  -- their brackets, as scalafmt breaks a chain.
  (path, typeArgs@('[' : _)) | not (null values) ->
    let typed method = D.group (D.text (method ++ "[") <> D.nest 2 (D.softbreak <> D.text (init (drop 1 typeArgs))) <> D.softbreak <> D.text "]")
    in case break (== '.') (reverse path) of
      (method@(_ : _), '.' : owner@(_ : _)) ->
        D.bestFit [callWith (D.text name) values, D.prefixChoice (name ++ "(") (callWith (D.text name) values)
          (D.text (reverse owner) <> D.nest 2 (D.hardline <> callWith (typed ('.' : reverse method)) values))]
      _ -> callWith (typed path) values
  -- A qualified call whose opening does not fit breaks before its method.
  _ | (method@(_ : _), '.' : owner@(_ : _)) <- break (== '.') (reverse name), not (null values), all (`notElem` name) ("([" :: String) ->
      D.bestFit [callWith (D.text name) values, D.prefixChoice (name ++ "(") (callWith (D.text name) values)
        (D.text (reverse owner) <> D.nest 2 (D.hardline <> callWith (D.text ('.' : reverse method)) values))]
  _ -> callWith (D.text name) values

callWith :: D.Doc -> [D.Doc] -> D.Doc
callWith name [] = name <> D.text "()"
callWith name values
  -- An argument of several lines puts every argument on a line of its own.
  | any (('\n' `elem`) . D.render D.Compact) values =
      D.multiline (name <> D.text "(" <> D.nest 2 (D.hardline <> joined values) <> D.hardline <> D.text ")")
  | otherwise = D.group (name <> D.text "(" <> D.nest 2 (D.softbreak <> D.commaSep values) <> D.softbreak <> D.text ")")
  where
    -- A block argument follows the argument before it, as scalafmt puts it.
    joined (a : b : rest) | take 1 (D.render D.Compact b) == "{" = joined ((a <> D.text ", " <> b) : rest)
    joined (a : rest@(_ : _)) = a <> D.text "," <> D.hardline <> joined rest
    joined [a] = a
    joined [] = mempty

-- | A definition's parameters: (a: A, b: B), or one a line, indented 4.
parameters :: D.Doc -> [D.Doc] -> D.Doc
parameters name [] = name <> D.text "()"
parameters name values = D.group (name <> D.text "(" <> D.nest 4 (D.softbreak <> D.commaSep values) <> D.softbreak <> D.text ")")

-- | { a => body }: on one line when it fits, otherwise the body on lines of
-- its own. A body of several statements always breaks.
lambda :: [String] -> [D.Doc] -> D.Doc
lambda names body
  | length body > 1 || any spansLines body = D.multiline (opening <> D.nest 2 (D.hardline <> statements body) <> D.hardline <> D.text "}")
  | otherwise = D.group (opening <> D.nest 2 (D.softline <> statements body) <> D.softline <> D.text "}")
  where
    spansLines doc = '\n' `elem` D.render D.Compact doc
    opening = D.text "{" <> D.text (case names of
      [] -> ""
      [one] -> " " ++ one ++ " =>"
      many -> " (" ++ foldr1 (\a b -> a ++ ", " ++ b) many ++ ") =>")

-- | f(args) { params => body }.
trailing :: D.Doc -> [String] -> [D.Doc] -> D.Doc
trailing invocation names body = invocation <> D.text " " <> lambda names body

trailingCall :: String -> [D.Doc] -> [String] -> [D.Doc] -> D.Doc
trailingCall name args = trailing (call name args)

-- | val name = value: a call stays after the = when its opening fits there,
-- and breaks its arguments; otherwise the value goes on the next line.
bind :: String -> D.Doc -> D.Doc
bind name value = case break (== '(') flat of
  (opening, '(' : _) | '\n' `notElem` flat, all (`notElem` (" {" :: String)) opening ->
    D.bestFit [D.text (prefix ++ flat), D.prefixChoice (prefix ++ opening ++ "(") (D.text prefix <> value) broken]
  -- An if goes on the line after the =, as scalafmt puts it.
  _ | take 4 flat == "if (" -> if '\n' `elem` flat
        then D.text ("val " ++ name ++ " =") <> D.nest 2 (D.hardline <> value)
        else D.group broken
  -- A value of several lines (a block) starts after the =.
  _ | '\n' `elem` flat -> D.text prefix <> value
  _ -> D.group broken
  where
    prefix = "val " ++ name ++ " = "
    flat = D.render D.Compact value
    broken = D.text ("val " ++ name ++ " =") <> D.nest 2 (D.softline <> value)

-- | Computed control flow keeps its document tree. In particular, a typed
-- lambda must not flatten the binding's nested conditions after its first line.
bindControl :: String -> D.Doc -> D.Doc
bindControl name value = D.multiline (D.group
  (D.text ("val " ++ name ++ " =") <> D.nest 2 (D.softline <> value)))

-- | A braced value opens on the binding's line, without extra block nesting.
bindBlock :: String -> D.Doc -> D.Doc
bindBlock name value = D.text ("val " ++ name ++ " = ") <> value

-- | receiver.a(...).b(...): a chain of two or more calls is broken before
-- each call's dot when it does not fit, the receiver's own call included
-- (Codecs.stackCodec(...).encode(...)), as scalafmt breaks select chains. A
-- single call keeps its dot and breaks its arguments.
chain :: D.Doc -> [(String, [D.Doc])] -> D.Doc
chain receiver methods = chainWith receiver methods Nothing

-- | receiver.a(...).name { params => body }: a chain ending in a trailing
-- lambda, broken before each dot as chain breaks.
trailingChain :: D.Doc -> [(String, [D.Doc])] -> String -> [String] -> [D.Doc] -> D.Doc
trailingChain receiver methods name params body = chainWith receiver methods (Just (D.text ("." ++ name ++ " ") <> lambda params body))

-- | receiver.name(param => body): a chain ending in a call of one lambda,
-- which scalafmt keeps in the call's parentheses.
trailingChain' :: D.Doc -> String -> String -> D.Doc -> D.Doc
trailingChain' receiver name param body = chainWith receiver []
  (Just (D.group (D.text ("." ++ name ++ "(" ++ param ++ " =>") <> D.nest 2 (D.softline <> body) <> D.softbreak <> D.text ")")))

chainWith :: D.Doc -> [(String, [D.Doc])] -> Maybe D.Doc -> D.Doc
chainWith receiver methods final
  | calls <= 1 = receiver <> mconcat [call ("." ++ m) args | (m, args) <- methods] <> maybe mempty id final
  | otherwise = D.group (start <> D.nest 2 (mconcat [D.softbreak <> call ("." ++ m) args | (m, args) <- methods] <>
      maybe mempty (D.softbreak <>) final))
  where
    flat = D.render D.Compact receiver
    (path, applied) = break (== '(') flat
    qualified = not (null applied) && '\n' `notElem` flat && last flat == ')' && all (\c -> c `elem` ("._[], " :: String) || c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || c `elem` ['0'..'9']) path
    calls = length methods + (if not (null applied) then 1 else 0) + maybe 0 (const 1) final
    -- The receiver's own method, split from its owner before any type
    -- arguments (Codecs.scalar[T]).
    (bare, typeArgs) = break (== '[') path
    start = case (break (== '.') (reverse bare), parseCall flat) of
      ((method@(_ : _), '.' : owner@(_ : _)), Just (Apply _ args)) | qualified ->
        D.text (reverse owner) <> D.nest 2 (D.softbreak <> call ('.' : reverse method ++ typeArgs) (map rebuilt args))
      _ -> receiver
    rebuilt tree = case tree of
      Atom t -> D.text t
      Apply n args -> call n (map rebuilt args)
      Select r m args -> chain (rebuilt r) [(m, map rebuilt args)]

-- | { ... } over statements.
block :: [D.Doc] -> D.Doc
block body = D.block 2 (statements body)

statements :: [D.Doc] -> D.Doc
statements = D.joinWith D.hardline

-- | if (c) or while (c), the condition broken onto its own lines when it
-- does not fit.
condition :: String -> D.Doc -> D.Doc
condition keyword c = D.group (D.text (keyword ++ " (") <> D.nest 2 (D.softbreak <> c) <> D.softbreak <> D.text ")")

-- | Conditions joined by &&, broken after each operator, the later ones
-- indented as scalafmt indents an operator's continuation.
conjunction :: [D.Doc] -> D.Doc
conjunction [] = D.text "true"
conjunction (x : xs) = D.group (x <> D.nest 2 (mconcat [D.text " &&" <> D.softline <> y | y <- xs]))

-- | Conditions joined by && as a block's statement, where scalafmt does not
-- indent the continuation.
conjunctionStatement :: [D.Doc] -> D.Doc
conjunctionStatement [] = D.text "true"
conjunctionStatement (x : xs) = D.group (x <> mconcat [D.text " &&" <> D.softline <> y | y <- xs])

-- | header = body, the body on its own line when it does not fit.
equalsBody :: D.Doc -> D.Doc -> D.Doc
equalsBody header body
  -- A body of several lines (synchronized { ... }) stays after the = when
  -- its first line fits there.
  | '\n' `elem` flatBody = D.prefixChoice (D.render D.Compact header ++ " = " ++ takeWhile (/= '\n') flatBody)
      (header <> D.text " = " <> body) (header <> D.text " =" <> D.nest 2 (D.hardline <> body))
  | otherwise = header <> D.group (D.text " =" <> D.nest 2 (D.softline <> body))
  where flatBody = D.render D.Compact body

-- | A line comment, wrapped at the page's width.
comment :: Int -> String -> D.Doc
comment width = D.lineComment width "// "
