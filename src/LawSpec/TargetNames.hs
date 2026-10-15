-- | Native names for user-chosen identifiers. A name that is a keyword of the
-- target language is emitted with a leading underscore, so a definition or
-- adapter called `short` is `_short` in Java and `short` elsewhere. The
-- declaration's identity is unchanged; only its native spelling differs.
module LawSpec.TargetNames (targetKeywords, nativeName, phraseNativeName, allTargetKeywords) where

import Data.List (nub)
import Data.Char (isAlphaNum, isAscii, isDigit, toLower, toUpper)

-- | Words the target's grammar reserves in the positions LawSpec emits
-- user-chosen function names. Go exports names by capitalizing them, and its
-- keywords are lowercase, so no Go name needs escaping.
targetKeywords :: String -> [String]
targetKeywords target = case target of
  "python" -> words "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield"
  "javascript" -> web
  "typescript" -> web
  "java" -> words "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var yield _"
  -- Groovy reserves Java's words and its own.
  "groovy" -> targetKeywords "java" ++ words "as def in trait"
  -- Clojure's special forms cannot name a function; Java's model needs Java's.
  "clojure" -> targetKeywords "java" ++ words "def if do let quote var fn loop recur throw try catch finally new letfn case"
  "kotlin" -> words "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while"
  "rust" -> words "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen"
  "scala" -> words "abstract case catch class def do else enum export extends false final finally for forSome given if implicit import lazy macro match new null object override package private protected return sealed super then this throw trait true try type val var while with yield"
  "haskell" -> words "case class data default deriving do else foreign forall if import in infix infixl infixr instance let module newtype of then type where"
  _ -> []
  where
    web = words "await break case catch class const continue debugger default delete do else enum export extends false finally for function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof var void while with yield"

-- | A keyword gets a leading underscore, which every target accepts in an
-- identifier, while messages keep the declared name.
nativeName :: String -> String -> String
nativeName target written
  | name `elem` targetKeywords target = '_' : name
  | otherwise = name
  where name = phraseNativeName written

-- | Split phrase words deterministically before applying the target's existing
-- naming/keyword rules. Ordinary identifiers preserve their existing spelling.
phraseNativeName :: String -> String
phraseNativeName ('"' : '|' : body) = case words (map separator (take (max 0 (length body - 1)) body)) of
  first : rest -> prefix (lowerFirst first ++ concatMap capital rest)
  [] -> "phrase"
  where
    separator c = if isAscii c && isAlphaNum c then c else ' '
    lowerFirst (c:cs) = toLower c : cs
    lowerFirst [] = []
    capital (c:cs) = toUpper c : cs
    capital [] = []
    prefix name@(c:_) | isDigit c = '_' : name
    prefix name = name
phraseNativeName name = name

-- | A name that is a keyword anywhere is escaped everywhere it matters, so one
-- specification produces valid code for every target.
-- ref:DEC-idiomatic-generated-types
allTargetKeywords :: [String]
allTargetKeywords = nub (concatMap targetKeywords ["python","javascript","java","kotlin","rust","haskell","groovy"])
