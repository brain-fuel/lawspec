-- | Names and string literals in the JVM targets' generated code (Java,
-- Kotlin, Scala, Groovy and the Java law cases Clojure runs). Source names
-- are kept, cased as the language writes them; a name Google Java Style
-- would reject is made acceptable without an underscore (a keyword becomes
-- classValue, a clash value2), so generated code passes the targets'
-- naming checks. Strings are the language's own literals, wrapped only at
-- spaces. ref:DEC-readable-generated-names ref:DEC-native-string-literals
module LawSpec.JvmNames
  ( jvmReserved, jvmLocal, jvmClaim, jvmClaimAll, jvmLocalTable, jvmString, jvmStringChunks
  , exampleTestNames, boundaryTestName, contractMethod
  ) where

import Data.Char (isDigit, toUpper)
import Data.List (dropWhileEnd)
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
  "symbols values inputs captured environment seed seeds iteration sizeHint caseIndex measured error \
  \value native recorded matched fields group results raw bytes index integer number point units unit \
  \description real imaginary coefficient exponent numerator denominator positive released unused \
  \schema bits context actual expected type LawSpecRuntime Value String Object \
  \Map List HashMap Generator PropertyChecker Test MACHINE_BITS"

-- | A source binder's identifier: camelCase, a keyword or reserved name
-- followed by Value.
jvmLocal :: String -> [String] -> String -> String
jvmLocal target reserved source
  | candidate `elem` reserved || candidate `elem` targetKeywords target =
      candidate ++ if length candidate == 1 then "2" else "Value"
  | otherwise = candidate
  where
    candidate = googleCase (dropWhileEnd (== '_') (localIdentifier target source))

-- Google Java Style's local names have a lower-case second letter (aValue
-- would read as an abbreviation): a single leading letter word joins the
-- next.
googleCase :: String -> String
googleCase name = case name of
  c : d : rest | d `elem` ['A' .. 'Z'] -> c : toLowerChar d : rest
  _ -> filter (/= '_') name
  where toLowerChar x = toEnum (fromEnum x + 32)

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

-- | A string's literal pieces, each at most about width characters, broken
-- only after a space, so no word is ever split.
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
                [] -> case [i + 1 | (i, c) <- zip [0 :: Int ..] rest, c == ' ', i > 0] of
                  n : _ -> n
                  [] -> length rest
          in take cut rest : go (drop cut rest)

-- | A string literal, wrapped at spaces with + when it does not fit.
jvmString :: String -> String -> D.Doc
jvmString target value = case map (D.text . literalFor target) (jvmStringChunks 60 value) of
  [] -> D.text "\"\""
  [single] -> single
  first : rest -> D.bestFit [D.text (literalFor target value),
    D.group (first <> D.nest 4 (mconcat [D.softline <> D.text "+ " <> piece | piece <- rest]))]

capital :: String -> String
capital (c : cs) = toUpper c : cs
capital [] = []

-- | The test names of a law's examples, after the law's name and an
-- underscore (Google's JUnit convention): each example's words in
-- lowerCamelCase, numbered from 1 when it has none or they repeat.
exampleTestNames :: [String] -> [String] -> [String]
exampleTestNames taken names = fst $ jvmClaimAll (S.fromList taken)
  [ case (case filter (\w -> length w > 1 || all isDigit w) (lawWords n) of [] -> lawWords n; kept -> kept) of
      ["law"] -> "example" ++ show i
      w@(c : _) : more | not (isDigit c) -> w ++ concatMap capital more
      ws -> "example" ++ concatMap capital ws
  | (i, n) <- zip [1 :: Int ..] names ]

-- | Boundary cases have no names; they are numbered from 1.
boundaryTestName :: Int -> String
boundaryTestName i = "boundary" ++ show (i + 1)

-- | The method that checks a contract around its adapter: checkedNormalize.
contractMethod :: String -> String
contractMethod n = "checked" ++ capital n
