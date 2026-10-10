-- | Names in generated F# and C#: namespaces and modules from units, PascalCase
-- types, camelCase F# functions and PascalCase C# methods, with keywords
-- escaped. One unit's names never depend on another's, except that data
-- types sharing a short name are qualified by their unit.
-- ref:DEC-idiomatic-generated-types ref:DEC-csharp-over-fsharp
module LawSpec.DotNet.Names
  ( langOf, extension, pascal, camel, unitNamespace, unitModule, unitQualified, generatedModule
  , adapterPath, functionName, parameterName, dataNames, fsharpKeywords, csharpKeywords, escapeFSharp
  , splitDots, testModule
  ) where

import qualified LawSpec.Core as C
import LawSpec.DotNet.Code (Lang(..))
import Data.Char (isAlphaNum, isAscii, isUpper, isLower, isDigit, toUpper, toLower)
import Data.List (intercalate, nub)

langOf :: String -> Lang
langOf "csharp" = CSharp
langOf _ = FSharp

extension :: Lang -> String
extension FSharp = ".fs"
extension CSharp = ".cs"

splitDots :: String -> [String]
splitDots s = case break (== '.') s of
  (a, []) -> [a]
  (a, _ : b) -> a : splitDots b

-- | Words of an identifier: split at underscores, other punctuation and case
-- changes (fooBar, HTTPServer, x2y).
identifierWords :: String -> [String]
identifierWords = filter (not . null) . go ""
  where
    go current [] = [reverse current]
    go current (c : rest)
      | not (isAscii c && isAlphaNum c) = reverse current : go "" rest
      | isUpper c, (p : _) <- current, isLower p || isDigit p = reverse current : go [c] rest
      | isUpper c, (p : _) <- current, isUpper p, (n : _) <- rest, isLower n = reverse current : go [c] rest
      | otherwise = go (c : current) rest

pascal :: String -> String
pascal s = case concatMap capital (identifierWords s) of
  name@(c : _) | isDigit c -> '_' : name
  "" -> "_"
  name -> name
  where capital (c : cs) = toUpper c : cs
        capital [] = []

camel :: String -> String
camel s = case pascal s of
  '_' : rest -> '_' : rest
  c : cs -> toLower c : cs
  [] -> "_"

-- | example.scalar_adapters is module Example.ScalarAdapters (F#) or class
-- ScalarAdapters in namespace Example (C#).
unitNamespace :: C.Id -> String
unitNamespace identity = case splitDots (C.idText identity) of
  [_] -> "Units"
  parts -> intercalate "." (map pascal (init parts))

unitModule :: C.Id -> String
unitModule = pascal . last . splitDots . C.idText

unitQualified :: C.Id -> String
unitQualified identity = unitNamespace identity ++ "." ++ unitModule identity

-- | The module holding a unit's generated entries.
generatedModule :: C.Id -> String
generatedModule identity = "LawSpec.Generated." ++ concatMap pascal (splitDots (C.idText identity))

-- | The module holding a unit's generated tests.
testModule :: C.Id -> String
testModule identity = "LawSpec.Tests." ++ concatMap pascal (splitDots (C.idText identity))

adapterPath :: Lang -> C.Id -> String
adapterPath lang identity =
  "src/" ++ intercalate "/" (map pascal (init (splitDots (C.idText identity)) ++ [last (splitDots (C.idText identity))])) ++ extension lang

fsharpKeywords :: [String]
fsharpKeywords = words "abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern false finally fixed for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not null of open or override private public rec return select sig static struct then to true try type upcast use val void when while with yield const break checked component constraint continue event external include mixin parallel process protected pure sealed tailcall trait virtual"

csharpKeywords :: [String]
csharpKeywords = words "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while"

escapeFSharp :: String -> String
escapeFSharp name
  | name `elem` fsharpKeywords = name ++ "_"
  | otherwise = name

-- | A declaration's function: camelCase in F#, PascalCase in C#.
functionName :: Lang -> C.Declaration -> String
functionName FSharp d = escapeFSharp (camelKeep (C.declarationName d))
functionName CSharp d = pascal (C.declarationName d)

-- | A declared camelCase name stays as written when it is already an F#
-- identifier.
camelKeep :: String -> String
camelKeep name
  | (c : _) <- name, all (\x -> isAscii x && (isAlphaNum x || x == '_')) name && isLower c = name
  | otherwise = camel name

parameterName :: Lang -> Int -> String
parameterName _ i = "value" ++ show i

-- | A program's data type names: PascalCase short names, qualified by unit
-- when two declarations share one, and constructors named within their type.
dataNames :: [C.DataDeclaration] -> Either String [(C.Id, String)]
dataNames declarations = do
  let shorts = [(C.dataId d, pascal (C.dataName d)) | d <- declarations]
      reserved = words "Value Schema Codec Option List Map Set Either Nullable Optional Result Unit String Object Int Bool"
      types = [ (identity, if length (filter ((== n) . snd) shorts) > 1 || n `elem` reserved
                             then concatMap pascal (splitDots (owner (C.idText identity))) ++ n else n)
              | (identity, n) <- shorts ]
      names = map snd types
      owner text = case breakOn text of (u, _) -> u
      breakOn text = go "" text
        where go acc rest@(c : cs) = if take 2 rest == "::" then (reverse acc, drop 2 rest) else go (c : acc) cs
              go acc [] = (reverse acc, "")
  if length names /= length (nub names)
    then Left ("colliding .NET data names: " ++ show [n | n <- nub names, length (filter (== n) names) > 1])
    else pure types
