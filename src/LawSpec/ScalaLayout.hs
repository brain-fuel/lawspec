-- | Scala layout as scalafmt's default configuration accepts it, so generated
-- Scala is a fixed point of scalafmt (DEC-readable-output-default): 2-space
-- blocks, 80 columns, a broken argument list one argument a line with its
-- closing parenthesis on a line of its own and no trailing comma, a
-- definition's broken parameters indented 4, a chained call broken before
-- each dot, and a lambda's body on lines of its own once it does not fit.
-- Strings are Scala literals and never split.
module LawSpec.ScalaLayout
  ( scalaStyle, scalaString, arrow, Receiver, referenceReceiver, callReceiver, typedReceiver, chainedReceiver, trailingReceiver, receiverDoc, chainWith, call, callThen, callWith, trailingChain, trailingChain', parameters, lambda, trailing, trailingCall, signature, bind, bindControl, bindBlock, chain, block, statements
  , condition, conjunction, conjunctionStatement, equalsBody, comment
  ) where

import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)

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

-- | A method signature retains the result type's legal break before its
-- colon. With no parameters, scalafmt uses that break for a long result.
signature :: D.Doc -> [D.Doc] -> D.Doc -> D.Doc
signature name args result
  | null args = D.group (parameters name args <> D.nest 4 (D.softbreak <> D.text ": " <> result))
  | otherwise = parameters name args <> D.text ": " <> result

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

-- | A receiver retains its call boundaries. References are already-known
-- logical names; invocation ownership and generic arguments come
-- from the checked producer, never from rendered source.
data Receiver
  = ReceiverReference D.Doc
  | ReceiverCall (Maybe D.Doc) D.Doc [D.Doc]
  | ReceiverChain Receiver [(String,[D.Doc])]
  | ReceiverBlock Receiver [String] [D.Doc]

-- | An indivisible logical reference, such as a local value or namespace.
referenceReceiver :: D.Doc -> Receiver
referenceReceiver = ReceiverReference

-- | An ordinary logical callee path supplied by the producer. Generic
-- invocations retain their type-argument documents through typedReceiver.
callReceiver :: String -> [D.Doc] -> Receiver
callReceiver name arguments = case break (== '.') (reverse name) of
  (method@(_:_),'.':owner@(_:_)) -> ReceiverCall (Just (D.text (reverse owner))) (D.text (reverse method)) arguments
  _ -> ReceiverCall Nothing (D.text name) arguments

typedReceiver :: String -> String -> [D.Doc] -> [D.Doc] -> Receiver
typedReceiver owner method types = ReceiverCall (Just (D.text owner))
  (D.text method <> (if null types then mempty else D.delimit 2 "[" "]" types))

chainedReceiver :: Receiver -> [(String,[D.Doc])] -> Receiver
chainedReceiver = ReceiverChain

-- | A known invocation followed by its trailing lambda.
trailingReceiver :: Receiver -> [String] -> [D.Doc] -> Receiver
trailingReceiver = ReceiverBlock

receiverDoc :: Receiver -> D.Doc
receiverDoc receiver = chainWith receiver [] Nothing

-- | receiver.a(...).b(...): a chain of two or more calls is broken before
-- each call's dot when it does not fit, the receiver's own call included
-- (Codecs.stackCodec(...).encode(...)), as scalafmt breaks select chains. A
-- single call keeps its dot and breaks its arguments.
chain :: Receiver -> [(String, [D.Doc])] -> D.Doc
chain receiver methods = chainWith receiver methods Nothing

-- | receiver.a(...).name { params => body }.
trailingChain :: Receiver -> [(String, [D.Doc])] -> String -> [String] -> [D.Doc] -> D.Doc
trailingChain receiver methods name params body = chainWith receiver methods (Just (D.text ("." ++ name ++ " ") <> lambda params body))

-- | A chain ending in one parenthesized lambda.
trailingChain' :: Receiver -> String -> String -> D.Doc -> D.Doc
trailingChain' receiver name param body = chainWith receiver []
  (Just (D.group (D.text ("." ++ name ++ "(" ++ param ++ " =>") <> D.nest 2 (D.softline <> body) <> D.softbreak <> D.text ")")))

chainWith :: Receiver -> [(String, [D.Doc])] -> Maybe D.Doc -> D.Doc
chainWith receiver methods final =
  let (root,prior) = unroll receiver
      steps = prior ++ methods
      calls = rootCalls root + length steps + maybe 0 (const 1) final
      pieces separator = mconcat [separator <> call ("." ++ method) arguments | (method,arguments) <- steps] <>
        maybe mempty (separator <>) final
  in if calls <= 1 then rootDoc False root <> pieces mempty
     else D.group (rootDoc True root <> D.nest 2 (pieces D.softbreak))
  where
    rootCalls (ReceiverReference _) = 0
    rootCalls (ReceiverCall {}) = 1
    rootCalls (ReceiverBlock inner _ _) = max 1 (rootCalls inner)
    rootCalls (ReceiverChain inner steps) = rootCalls inner + length steps
    unroll (ReceiverChain inner steps) = let (root,prior) = unroll inner in (root,prior ++ steps)
    unroll root = (root,[])
    rootDoc _ (ReceiverReference doc) = doc
    rootDoc chained (ReceiverCall owner method arguments) = case owner of
      Nothing -> callWith method arguments
      Just ownerDoc ->
        let normal = callWith (ownerDoc <> D.text "." <> method) arguments
            divided line = ownerDoc <> D.nest 2 (line <> callWith (D.text "." <> method) arguments)
            opening = D.render D.Compact (ownerDoc <> D.text "." <> method <> D.text "(")
        in if chained then divided D.softbreak
           else D.bestFit [normal,D.prefixChoice opening normal (divided D.hardline)]
    rootDoc chained (ReceiverBlock (ReceiverCall owner method []) parameters body) =
      (case owner of
        Nothing -> method
        Just ownerDoc | chained -> ownerDoc <> D.nest 2 (D.softbreak <> D.text "." <> method)
                      | otherwise -> ownerDoc <> D.text "." <> method) <> D.text " " <> lambda parameters body
    rootDoc chained (ReceiverBlock inner parameters body) = rootDoc chained inner <> D.text " " <> lambda parameters body
    rootDoc chained (ReceiverChain inner steps) = chainWith inner steps Nothing

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
