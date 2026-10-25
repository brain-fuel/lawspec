-- | Names and string literals in the JVM targets' generated code (Java,
-- Kotlin, Scala, Groovy and the Java law cases Clojure runs). Source names
-- are kept, cased as the language writes them; a name Google Java Style
-- would reject is made acceptable without an underscore (a keyword becomes
-- classValue, a clash value2), so generated code passes the targets'
-- naming checks. Strings are the language's own literals, with bounded input
-- chunks. ref:DEC-readable-generated-names ref:DEC-native-string-literals
module LawSpec.JvmNames
  ( jvmReserved, jvmLocal, jvmClaim, jvmClaimAll, jvmLocalTable, jvmString, jvmStringChunks
  , jvmScopedNames, exampleTestNames, boundaryTestName, contractMethod, javadoc, jvmMethod, googleCase
  ) where

import Data.Char (isAlphaNum, isDigit, toLower, toUpper)
import Data.List (dropWhileEnd, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)
import LawSpec.Naming (localIdentifier)
import LawSpec.TargetNames (targetKeywords)
import LawSpec.TestNames (lawWords)

-- | Names a JVM test or definition declares for itself, which a source
-- binder must not take: the locals generated code uses around a law's
-- values, and the classes it names unqualified.
jvmReserved :: String -> [String]
jvmReserved target = targetKeywords target ++ words
  "symbols values inputs captured environment seed seeds iteration sizeHint caseIndex finiteCase measured error \
  \value native recorded matched fields group results raw bytes index integer number point units unit \
  \description real imaginary coefficient exponent numerator denominator positive released unused \
  \schema bits context actual expected type tag fields config random LawSpecRuntime Value String Object \
  \Map List HashMap Generator PropertyChecker Test MACHINE_BITS Schema MachineBits Symbols drawn"

-- | A source binder's identifier: camelCase, a keyword or reserved name
-- followed by Value.
jvmLocal :: String -> [String] -> String -> String
jvmLocal target reserved source
  | candidate `elem` reserved || candidate `elem` targetKeywords target =
      candidate ++ if length candidate == 1 then "2" else "Value"
  | otherwise = candidate
  where
    candidate = googleCase (dropWhileEnd (== '_') (localIdentifier target source'))
    -- A record view's field is a view; its hash would only widen the line.
    source' = if target == "java" && "lawspecRecordView" `isPrefixOf` source then "view" else source

-- Google Java Style's local names have a lower-case second letter (aValue
-- would read as an abbreviation): a single leading letter word joins the
-- next.
googleCase :: String -> String
googleCase name = noRuns $ case name of
  c : d : rest | d `elem` ['A' .. 'Z'] -> c : toLowerChar d : rest
  _ -> filter (/= '_') name
  where
    toLowerChar x = toEnum (fromEnum x + 32)
    -- No two capitals together (boundedUInt16 is boundedUint16), as
    -- Google's names allow none.
    noRuns (a : b : rest) | upper a && upper b = a : noRuns (toLowerChar b : rest)
    noRuns (a : rest) = a : noRuns rest
    noRuns [] = []
    upper x = x `elem` ['A' .. 'Z']

-- | The first free spelling: itself, then name2, name3, ...
jvmClaim :: S.Set String -> String -> (String, S.Set String)
jvmClaim taken name = (chosen, S.insert chosen taken)
  where
    chosen = case [c | c <- name : [name ++ show n | n <- [2 :: Int ..]], c `S.notMember` taken] of
      c : _ -> c
      [] -> name

jvmClaimAll :: S.Set String -> [String] -> ([String], S.Set String)
jvmClaimAll taken [] = ([], taken)
jvmClaimAll taken (n : rest) = let (c, t) = jvmClaim taken n
                                   (cs, t') = jvmClaimAll t rest
                               in (c : cs, t')

-- | Identifiers for binders, in order, distinct from each other and the
-- reserved names; a binder seen again keeps its first name.
jvmLocalTable :: String -> [String] -> [C.Binder] -> M.Map C.Id String
jvmLocalTable target reserved = snd . foldl allocate (S.fromList reserved, M.empty)
  where
    allocate (taken, table) binder
      | M.member (C.binderId binder) table = (taken, table)
      | otherwise = let (chosen, taken') = jvmClaim taken (jvmLocal target reserved (C.binderName binder))
                    in (taken', M.insert (C.binderId binder) chosen table)

-- | A string's literal pieces, preferring spaces but bounding long unbroken
-- payloads too. Splitting the input never changes the concatenated value.
jvmStringChunks :: Int -> String -> [String]
jvmStringChunks width value = case value of
  "" -> [""]
  _ -> go value
  where
    go "" = []
    go rest
      | length rest <= width = [rest]
      | otherwise =
          let spaces = [i + 1 | (i, c) <- zip [0 :: Int ..] (take width rest), c == ' ', i > 0]
              cut = case reverse spaces of
                n : _ -> n
                [] -> max 1 width
          in take cut rest : go (drop cut rest)

-- | Wrap literal payloads before encoding, accounting for escape width. Java
-- additionally separates literal backslashes from following text: Checkstyle
-- otherwise mistakes displayed escapes in example labels for source escapes.
jvmString :: String -> String -> D.Doc
jvmString target value = case map (D.text . literalFor target) pieces of
  [] -> D.text "\"\""
  [single] -> single
  first : rest ->
    let broken = D.group (first <> D.nest 4
          (mconcat [D.softline <> D.text "+ " <> piece | piece <- rest]))
    in if target == "java" && '\\' `elem` value then broken
       else D.bestFit [D.text (literalFor target value), broken]
  where
    pieces = concatMap (bounded 0 []) (concatMap separate (jvmStringChunks 60 value))
    separate text | target == "java" = case break (== '\\') text of
      (before, '\\' : after) -> (before ++ "\\") : separate after
      (before, _) -> [before | not (null before)]
    separate text = [text]
    bounded _ acc [] = [reverse acc | not (null acc)]
    bounded width acc text@(c : rest)
      | width + cost > 60 && not (null acc) = reverse acc : bounded 0 [] text
      | otherwise = bounded (width + cost) (c : acc) rest
      where cost = length (literalFor target [c]) - 2

capital :: String -> String
capital (c : cs) = toUpper c : cs
capital [] = []

-- | The test names of a law's examples, after the law's name and an
-- underscore (Google's JUnit convention): each example's words in
-- lowerCamelCase, numbered from 1 when it has none or they repeat.
exampleTestNames :: [String] -> [String] -> [String]
exampleTestNames taken names = fst $ jvmClaimAll (S.fromList taken)
  [ case shortened (case filter (\w -> length w > 1 || all isDigit w) (lawWords n) of [] -> lawWords n; kept -> kept) of
      ["law"] -> "example" ++ show i
      w@(c : _) : more | not (isDigit c) -> w ++ concatMap capital more
      ws -> "example" ++ concatMap capital ws
  | (i, n) <- zip [1 :: Int ..] names ]

-- | An example's words, at most about 32 characters: whole words, so a
-- test's name (its law's, then its example's) stays short enough to read.
shortened :: [String] -> [String]
shortened = go 0
  where
    go _ [] = []
    go n (w : rest)
      | n > 0 && n + length w > 32 = []
      | otherwise = w : go (n + length w) rest

-- | Boundary cases have no names; they are numbered from 1.
boundaryTestName :: Int -> String
boundaryTestName i = "boundary" ++ show (i + 1)

-- | The method that checks a contract around its adapter: checkedNormalize.
contractMethod :: String -> String
contractMethod n = "checked" ++ capital n

-- | A documentation comment: one line when it fits the width at its
-- indentation, otherwise its words wrapped after " * ".
javadoc :: Int -> String -> D.Doc
javadoc width content
  | length ("/** " ++ content ++ " */") <= width = D.text ("/** " ++ content ++ " */")
  | otherwise = D.text "/**" <> D.hardline <>
      mconcat [D.text (" * " ++ l) <> D.hardline | l <- wrap [] (words content)] <> D.text " */"
  where
    wrap current [] = [unwords current | not (null current)]
    wrap current (w : rest)
      | not (null current) && length (unwords (current ++ [w])) > width - 3 = unwords current : wrap [w] rest
      | otherwise = wrap (current ++ [w]) rest

-- | A generated method named by a verb and an identity's words, in
-- lowerCamelCase: jvmMethod "call" "example.shop::charge" is
-- callExampleShopCharge. Distinct identities give distinct names unless
-- they differ only in punctuation.
jvmMethod :: String -> String -> String
jvmMethod verb identity = verb ++ concatMap capital (words (map (\c -> if isAlphaNum c then toLower c else ' ') identity))

-- | An expression whose binders shadow no name already in scope (an
-- enclosing binder's or a free local's): such a binder gets a fresh id,
-- named with the first free 2, 3 suffix (Google Java Style's camel case
-- has no underscores). Expansion can bind one id again inside itself, so
-- renaming stops where the id is bound anew. ref:DEC-readable-generated-names
jvmScopedNames :: (C.Id -> String) -> C.Expr -> (C.Expr, M.Map C.Id String)
jvmScopedNames named whole = (renamed, M.fromList [(i, drop 1 (dropWhile (/= '\x1f') (C.idText i))) | i <- freshIds renamed])
  where
    renamed = go (S.fromList (map named (S.toList (freeLocals whole)))) whole
    freeLocals e = case C.expressionNode e of
      C.Local i -> S.singleton i
      C.Let b v body -> freeLocals v `S.union` S.delete (C.binderId b) (freeLocals body)
      C.AllElements v b body -> freeLocals v `S.union` S.delete (C.binderId b) (freeLocals body)
      C.SearchElements _ v b body -> freeLocals v `S.union` S.delete (C.binderId b) (freeLocals body)
      C.AllPayloads v ps -> S.unions (freeLocals v : [S.delete (C.binderId b) (freeLocals x) | (b, x) <- ps])
      C.Match v cs -> S.unions (freeLocals v : [freeLocals (C.caseBody c) `S.difference` S.fromList (map C.binderId (C.caseBinders c)) | c <- cs])
      _ -> S.unions (map freeLocals (C.children e))
    go scope e = case C.expressionNode e of
      C.Let b value body -> let ([b'], body0, inner) = bindAll scope [b] body
        in e { C.expressionNode = C.Let b' (go scope value) (go inner body0) }
      C.AllElements value b body -> let ([b'], body0, inner) = bindAll scope [b] body
        in e { C.expressionNode = C.AllElements (go scope value) b' (go inner body0) }
      C.SearchElements universal value b body -> let ([b'], body0, inner) = bindAll scope [b] body
        in e { C.expressionNode = C.SearchElements universal (go scope value) b' (go inner body0) }
      C.AllPayloads value ps -> e { C.expressionNode = C.AllPayloads (go scope value)
        [let ([b'], x0, inner) = bindAll scope [b] x in (b', go inner x0) | (b, x) <- ps] }
      C.Match value cs -> e { C.expressionNode = C.Match (go scope value)
        [let (bs', body0, inner) = bindAll scope (C.caseBinders c) (C.caseBody c) in c { C.caseBinders = bs', C.caseBody = go inner body0 } | c <- cs] }
      _ -> C.mapChildren (go scope) e
    bindAll scope bs body = foldl one ([], body, scope) bs
      where
        one (done, b0, sc) b =
          let base = named (C.binderId b)
          in if base `S.notMember` sc then (done ++ [b], b0, S.insert base sc)
             else
               let name = head [n | n <- [base ++ show k | k <- [2 :: Int ..]], n `S.notMember` sc]
                   -- The chosen name rides in the id, after a separator no source id holds.
                   fresh = C.Id (C.idText (C.binderId b) ++ "\x1f" ++ name)
               in (done ++ [b { C.binderId = fresh }], renameFree (C.binderId b) fresh b0, S.insert name sc)
    -- Uses of one id renamed, up to where the id is bound again.
    renameFree from to e = case C.expressionNode e of
      C.Local i | i == from -> e { C.expressionNode = C.Local to }
      C.Let b v body | C.binderId b == from -> e { C.expressionNode = C.Let b (renameFree from to v) body }
      C.AllElements v b body | C.binderId b == from -> e { C.expressionNode = C.AllElements (renameFree from to v) b body }
      C.SearchElements universal v b body | C.binderId b == from -> e { C.expressionNode = C.SearchElements universal (renameFree from to v) b body }
      _ -> C.mapChildren (renameFree from to) e
    freshIds e = [C.binderId b | b <- introduced e, '\x1f' `elem` C.idText (C.binderId b)] ++ concatMap freshIds (C.children e)
    introduced e = case C.expressionNode e of
      C.Let b _ _ -> [b]
      C.AllElements _ b _ -> [b]
      C.SearchElements _ _ b _ -> [b]
      C.AllPayloads _ ps -> map fst ps
      C.Match _ cs -> concatMap C.caseBinders cs
      _ -> []
