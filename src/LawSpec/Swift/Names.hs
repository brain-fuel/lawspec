-- | Names in generated Swift: unit namespaces as caseless enums, UpperCamelCase
-- types, lowerCamelCase functions, cases and fields, with Swift's keywords
-- escaped in backticks. One unit's names never depend on another's, except
-- that data types sharing a short name are qualified by their unit.
-- ref:DEC-idiomatic-generated-types ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Names
  ( pascal, camel, escape, unitNamespace, unitPath, unitQualified, generatedName, apiName
  , adapterPath, functionName, parameterName, dataNames, swiftKeywords, splitDots, testName
  , handleKey, moduleName, testModuleName, typeParameter, localName, reservedLocals, exampleSuffixes
  ) where

import qualified LawSpec.Naming as N

import qualified LawSpec.Core as C
import Data.Char (isAlphaNum, isAscii, isUpper, isLower, isDigit, toUpper, toLower)
import Data.List (intercalate, nub)

-- | The module the program's sources compile to, and its tests.
moduleName, testModuleName :: String
moduleName = "App"
testModuleName = "AppTests"

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

-- | Swift's keywords, which a name escapes in backticks.
swiftKeywords :: [String]
swiftKeywords = words "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while Any as await false is nil self Self super throws true try async consume copy discard each borrowing consuming macro some any package repeat"

escape :: String -> String
escape name
  | name `elem` swiftKeywords = "`" ++ name ++ "`"
  | otherwise = name

-- | A source binder's Swift name: its words in lowerCamelCase (a
-- compiler-made binder named by what it holds), a keyword escaped in
-- backticks. ref:DEC-readable-generated-names
localName :: String -> String
localName = escape . N.localIdentifier "swift"

-- | The names generated code binds around a law's or a definition's
-- values, which a source binder's name must not shadow.
reservedLocals :: [String]
reservedLocals = words "schema symbols inputs resources values scoped withResources generation generator result scope native handler argument"

-- | The suffixes naming a law's example tests (after its name and _): each
-- example's words in lowerCamelCase, numbered when they repeat or have
-- none; never one of the kinds the law's other tests take.
-- They are cut at a whole word to fit their budget, so a test's
-- declaration fits a line.
exampleSuffixes :: Int -> [String] -> [String]
exampleSuffixes budget names = map (filter (/= '_')) $ fst (N.claimAll (N.scopeWith kinds) (map (fit . concatMap N.nameWords . splitUnderscores)
  (N.exampleTestSuffix "swift" ["boundary", "property", "statistics", "search", "skipped", "known_failing"] names)))
  where
    kinds = ["boundary", "property", "statistics", "search", "skipped", "knownFailing"]
    fit ws = N.cased N.Camel (case takeFitting 0 ws of [] -> take 1 ws; kept -> kept)
    takeFitting _ [] = []
    takeFitting n (w : rest)
      | n + length w > max 8 (budget - 3) = []
      | otherwise = w : takeFitting (n + length w) rest
    splitUnderscores s = case break (== '_') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitUnderscores rest

-- | The type parameter at a position: T0, T1, ...
typeParameter :: Int -> String
typeParameter i = "T" ++ show i

-- | example.scalar_adapters is Example.ScalarAdapters: a caseless enum per
-- dotted part, the last holding the unit's adapters.
unitNamespace :: C.Id -> [String]
unitNamespace identity = map pascal (splitDots (C.idText identity))

unitQualified :: C.Id -> String
unitQualified = intercalate "." . unitNamespace

-- | The source file of a unit's adapter, under src.
unitPath :: C.Id -> String
unitPath identity = intercalate "/" (unitNamespace identity) ++ ".swift"

adapterPath :: C.Id -> String
adapterPath identity = "src/" ++ unitPath identity

-- | The enum holding a unit's generated entries: LawSpec.Generated.ExampleShop.
generatedName :: C.Id -> String
generatedName identity = "LawSpec.Generated." ++ concatMap pascal (splitDots (C.idText identity))

-- | The enum holding a unit's checked definitions on native values.
apiName :: C.Id -> String
apiName identity = "LawSpec.Definitions." ++ concatMap pascal (splitDots (C.idText identity))

-- | A declaration's function: lowerCamelCase, kept as written when it already is.
functionName :: C.Declaration -> String
functionName d = escape (camelKeep (C.declarationName d))

camelKeep :: String -> String
camelKeep name
  | (c : _) <- name, all (\x -> isAscii x && (isAlphaNum x || x == '_')) name && isLower c = name
  | otherwise = camel name

parameterName :: Int -> String
parameterName i = "value" ++ show i

-- | A unit's test suite: LawsOfExampleShop.
testName :: C.Id -> String
testName identity = concatMap pascal (splitDots (C.idText identity))

-- | A program's data type names: UpperCamelCase short names, qualified by unit
-- when two declarations share one or one would shadow a name the generated
-- code uses, and constructors named within their type.
dataNames :: [C.DataDeclaration] -> Either String [(C.Id, String)]
dataNames declarations = do
  let shorts = [(C.dataId d, pascal (C.dataName d)) | d <- declarations]
      roots = nub [pascal (takeWhile (/= '.') (owner (C.idText (C.dataId d)))) | d <- declarations]
      reserved = words "Value Schema Codec Codecs Unit Null Undefined Symbol Either Nullable Undefinable Rational ExactDecimal Complex64 Complex128 BigInt SortedSet SortedMap Effects Runtime Scalar Typed Fail Recorded Regex Random Descriptors Defaults Portable LawSpec App Optional Array Dictionary Set String Int Bool Character Result Error Never Duration Double Float Any Void Sendable Hashable Equatable Comparable Task Actor Gen Tree Property Harness Generators Handler"
      types = [ (identity, if length (filter ((== n) . snd) shorts) > 1 || n `elem` reserved || n `elem` roots
                             then concatMap pascal (splitDots (owner (C.idText identity))) ++ n else n)
              | (identity, n) <- shorts ]
      names = map snd types
      owner text = fst (breakOn text)
      breakOn text = go "" text
        where go acc rest@(c : cs) = if take 2 rest == "::" then (reverse acc, drop 2 rest) else go (c : acc) cs
              go acc [] = (reverse acc, "")
  if length names /= length (nub names)
    then Left ("colliding Swift data names: " ++ show [n | n <- nub names, length (filter (== n) names) > 1])
    else pure (types ++ [(handleKey (C.dataId d), n) | d <- declarations, C.dataHandle d, Just n <- [lookup (C.dataId d) types]])

-- | The marker key under which dataNames lists a handle.
handleKey :: C.Id -> C.Id
handleKey identity = C.Id ("handle#" ++ C.idText identity)
