-- Native names for user-chosen identifiers. A name that is a keyword of the
-- target language is emitted with a leading underscore, so a definition or
-- adapter called `short` is `_short` in Java and `short` elsewhere. The
-- declaration's identity is unchanged; only its native spelling differs.
module LawSpec.TargetNames (targetKeywords, nativeName, allTargetKeywords) where

import Data.List (nub)

-- Words the target's grammar reserves in the positions LawSpec emits
-- user-chosen function names. Go exports names by capitalizing them, and its
-- keywords are lowercase, so no Go name needs escaping.
targetKeywords :: String -> [String]
targetKeywords target = case target of
  "python" -> words "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield"
  "javascript" -> web
  "typescript" -> web
  "java" -> words "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var yield _"
  "kotlin" -> words "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while"
  "rust" -> words "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen"
  "haskell" -> words "case class data default deriving do else foreign forall if import in infix infixl infixr instance let module newtype of then type where"
  _ -> []
  where
    web = words "await break case catch class const continue debugger default delete do else enum export extends false finally for function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof var void while with yield"

nativeName :: String -> String -> String
nativeName target name
  | name `elem` targetKeywords target = '_' : name
  | otherwise = name

allTargetKeywords :: [String]
allTargetKeywords = nub (concatMap targetKeywords ["python","javascript","java","kotlin","rust","haskell"])
