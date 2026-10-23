-- | Law explanations: the compiler's wording of a checked law, in one of three
-- registers. Each reads the same typed wire law and its evidence; none
-- evaluates, simplifies or reorders a computation, and none changes an
-- obligation or its status. Presentation only. ref:DEC-explain-registers
--
--   eng   plain English for non-mathematicians: keywords first, short lines;
--   math  ordinary mathematical notation: quantifiers, set and logic symbols;
--   dev   LawSpec's keyword notation with types, ids, sources and examples.
--
-- The input is the compiler's own expansion response, so the native core and
-- the WASM core produce byte-identical explanations.
module LawSpec.Explain
  ( View(..), viewName, parseView, explanationViews
  , ExplainOptions(..), explainResult
  ) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isDigit, isLetter, isLower, isNumber, isUpper, ord)
import Data.List (find, findIndex, sortOn)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text (Text)
import Data.Foldable (toList)
import Numeric (showHex)
import qualified LawSpec.Core as Core
import qualified LawSpec.Core.Types as CoreTypes

-- * Views

data View = Eng | Math | Dev deriving (Eq, Show, Enum, Bounded)

viewName :: View -> Text
viewName Eng = "eng"
viewName Math = "math"
viewName Dev = "dev"

explanationViews :: [View]
explanationViews = [minBound .. maxBound]

-- | The previous view names are removed, not aliased; the message names the
-- replacement so a script fails clearly.
parseView :: Text -> Either String View
parseView name = case name of
  "eng" -> Right Eng
  "math" -> Right Math
  "dev" -> Right Dev
  "business" -> renamed "eng"
  "formal" -> renamed "math"
  "developer" -> renamed "dev"
  "evidence" -> Left ("explain view \"evidence\" was removed; run lawspec evidence <unit>::<law> for a law's evidence" ++ choose)
  _ -> Left ("unknown explain view \"" ++ T.unpack name ++ "\"" ++ choose)
  where
    renamed new = Left ("explain view \"" ++ T.unpack name ++ "\" was renamed to \"" ++ new ++ "\"" ++ choose)
    choose = "; choose --view eng|math|dev"

data ExplainOptions = ExplainOptions
  { explainView :: View
  , explainLaw :: Maybe Text        -- ^ unit::law
  , explainEvidence :: Maybe Value  -- ^ evidence rows the host completed (native observations)
  }

-- | Explanations of the selected laws of an expansion response, or the reason
-- no law matched.
explainResult :: ExplainOptions -> Value -> Either String Value
explainResult options result =
  let laws = [law | law <- arr (field "laws" result), maybe True (== selector law) (explainLaw options)]
      selector law = str "owner" law <> "::" <> str "name" law
      context = presentation result
      evidence = fromMaybe (field "evidence" result) (explainEvidence options)
      explanations = map (explainOne context (explainView options) evidence) laws
  in if null laws then Left "No matching law" else Right (object
       [ "explanations" .= map explanationJson explanations
       , "text" .= T.intercalate "\n\n" (map explanationText explanations) ])

data Explanation = Explanation { exView :: View, exLaw :: Text, exName :: Text, exSections :: [(Text, [Text])] }

explanationJson :: Explanation -> Value
explanationJson e = object
  [ "view" .= viewName (exView e), "law" .= exLaw e, "name" .= exName e
  , "sections" .= [object ["kind" .= k, "lines" .= ls] | (k, ls) <- exSections e] ]

-- | The human text is exactly the sections' lines, in order.
explanationText :: Explanation -> Text
explanationText = T.intercalate "\n" . concatMap snd . exSections

-- * JSON access

field :: Text -> Value -> Value
field key (Object o) = fromMaybe Null (KM.lookup (K.fromText key) o)
field _ _ = Null

has :: Text -> Value -> Bool
has key (Object o) = KM.member (K.fromText key) o
has _ _ = False

arr :: Value -> [Value]
arr (Array xs) = toList xs
arr _ = []

strMaybe :: Value -> Maybe Text
strMaybe (String t) = Just t
strMaybe _ = Nothing

str :: Text -> Value -> Text
str key = fromMaybe "" . strMaybe . field key

strField :: Text -> Value -> Maybe Text
strField key = strMaybe . field key

kind :: Value -> Text
kind = str "kind"

nodeOf :: Value -> Value
nodeOf = field "node"

nodeKind :: Value -> Text
nodeKind = kind . nodeOf

isNull :: Value -> Bool
isNull Null = True
isNull _ = False

-- | JavaScript's String(value) for the scalars the wire carries.
jsString :: Value -> Text
jsString (String t) = t
jsString (Number n) = case properFraction n of
  (i, 0) -> T.pack (show (i :: Integer))
  _ -> T.pack (show (realToFrac n :: Double))
jsString (Bool b) = if b then "true" else "false"
jsString Null = "null"
jsString v = jsonText v

-- | JSON.stringify, for the strings and values a presentation quotes.
jsonText :: Value -> Text
jsonText (String t) = quoteJson t
jsonText (Array xs) = "[" <> T.intercalate "," (map jsonText (toList xs)) <> "]"
jsonText (Object o) = "{" <> T.intercalate "," [quoteJson (K.toText k) <> ":" <> jsonText v | (k, v) <- KM.toList o] <> "}"
jsonText v = jsString v

quoteJson :: Text -> Text
quoteJson t = "\"" <> T.concatMap escape t <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape '\b' = "\\b"
    escape '\f' = "\\f"
    escape c | ord c < 0x20 = T.pack ("\\u" ++ pad (showHex (ord c) ""))
             | otherwise = T.singleton c
    pad s = replicate (4 - length s) '0' ++ s

-- * Presentation context

data ValueName = ValueName { vnName :: Text, vnOwner :: Text, vnIdentity :: Text, vnCanonical :: Maybe Text }

data Presentation = Presentation
  { pDeclarations :: M.Map Text Value
  , pConstructors :: M.Map Text (Value, Value)    -- ^ constructor id: (declaration, constructor)
  , pNameCounts :: M.Map Text Int                -- ^ short type names
  , pRecursiveViews :: M.Map Text Value
  , pValues :: M.Map Text ValueName
  , pIdentityCounts :: M.Map Text Int
  , pAbilities :: M.Map Text (Text, Text)
  , pAbilityCounts :: M.Map Text Int
  , pAbilityIds :: [Text]
  , pResult :: Value
  }

builtinDeclarations :: [Value]
builtinDeclarations =
  [ object [ "id" .= Core.idText (Core.dataId declaration), "name" .= Core.dataName declaration
           , "constructors" .= [object [ "id" .= Core.idText (Core.constructorId constructor)
               , "name" .= Core.constructorName constructor
               , "fields" .= [object ["name" .= Core.binderName f] | f <- Core.constructorFields constructor]]
             | constructor <- Core.dataConstructors declaration]]
  | declaration <- CoreTypes.builtinDataDeclarations ]

presentation :: Value -> Presentation
presentation result = Presentation {..}
  where
    pResult = result
    declarationList = builtinDeclarations ++ arr (field "dataTypes" result)
    pDeclarations = M.fromList [(str "id" d, d) | d <- declarationList]
    pConstructors = M.fromList [(str "id" c, (d, c)) | d <- M.elems pDeclarations, c <- arr (field "constructors" d)]
    pNameCounts = M.fromListWith (+) [(shortNameIn pDeclarations (str "id" d), 1) | d <- M.elems pDeclarations]
    units = arr (field "units" result)
    pRecursiveViews = M.fromList
      [ (str "id" d, field "type" d)
      | unit <- units, d <- arr (field "declarations" unit)
      , str "representation" d == "structural-record-storage", isNull (field "source" d)
      , kind (field "origin" d) == "generated", str "declaration" (field "origin" d) == str "id" d
      , kind (field "type" d) == "function" ]
    declarationValues =
      [ (str "id" d, ValueName
          { vnName = fromMaybe (str "name" d) (strField "name" source)
          , vnOwner = fromMaybe (let i = str "id" d in if "::" `T.isInfixOf` i then fst (T.breakOn "::" i) else str "id" unit)
              (strField "unit" source)
          , vnIdentity = if isNull source then str "id" d else jsonText (toJSON [field "unit" source, field "name" source])
          , vnCanonical = strField "canonicalName" source })
      | unit <- units, d <- arr (field "declarations" unit), let source = field "source" d ]
    constructorValues =
      [ (cid, ValueName (str "name" c) (T.replace "::type::" "." (str "id" d)) cid Nothing)
      | (cid, (d, c)) <- M.toList pConstructors, kind (field "structure" d) /= "record" ]
    pValues = M.fromList (declarationValues ++ constructorValues)
    pIdentityCounts = M.map S.size (M.fromListWith S.union [(vnName v, S.singleton (vnIdentity v)) | v <- M.elems pValues])
    abilityList = [ (str "id" a, (str "name" a, fst (T.breakOn "::" (str "id" a)))) | unit <- units, a <- arr (field "abilities" unit) ]
    pAbilities = M.fromList abilityList
    pAbilityCounts = M.fromListWith (+) [(name, 1 :: Int) | (_, (name, _)) <- M.toList pAbilities]
    pAbilityIds = sortOn (negate . T.length) (M.keys pAbilities)

shortNameIn :: M.Map Text Value -> Text -> Text
shortNameIn declarations name = case name of
  "BigUInt" -> "Whole"
  "BigInt" -> "Integer"
  "Natural" -> "Whole"
  _ -> fromMaybe (last (T.splitOn "::type::" name)) (M.lookup name declarations >>= strField "name")

nominalName :: Presentation -> Text -> Text
nominalName p name =
  let display = shortNameIn (pDeclarations p) name
      (before, after) = T.breakOn "::type::" name
  in if M.findWithDefault 0 display (pNameCounts p) > 1 && not (T.null after) then before <> "." <> display else display

positionalFields :: Value -> Maybe [Value]
positionalFields declaration = do
  let structure = field "structure" declaration
  positions <- case field "positions" structure of
    Array xs -> traverse strMaybe (toList xs)
    _ -> Nothing
  constructor <- case arr (field "constructors" declaration) of
    [c] -> Just c
    _ -> Nothing
  if kind structure /= "record" || length positions < 2
     || S.size (S.fromList positions) /= length positions then Nothing else do
    let fields = arr (field "fields" constructor)
        byName = M.fromList [(str "name" f, f) | f <- fields]
    if length fields /= length positions || M.size byName /= length positions
       || not (all (`M.member` byName) positions) then Nothing
      else Just [byName M.! label | label <- positions]

-- * Types

sameType :: Value -> Value -> Bool
sameType left right
  | isNull left || isNull right || kind left /= kind right = False
  | kind left == "variable" = field "id" left == field "id" right
  | kind left == "function" = sameType (field "parameter" left) (field "parameter" right) && sameType (field "result" left) (field "result" right)
  | kind left /= "constructor" || field "name" left /= field "name" right
    || length (arr (field "arguments" left)) /= length (arr (field "arguments" right)) = False
  | otherwise = and (zipWith argument (arr (field "arguments" left)) (arr (field "arguments" right)))
  where
    argument a b = kind a == kind b && case kind a of
      "type" -> sameType (field "type" a) (field "type" b)
      "natural" -> field "value" a == field "value" b
      "indexVariable" -> field "id" a == field "id" b
      _ -> False

-- | Only compiler-generated storage views which copy every field in order.
storageView :: Presentation -> Value -> Maybe Value
storageView p expression =
  let node = nodeOf expression in case kind node of
    "call" -> do
      signature <- M.lookup (str "declaration" node) (pRecursiveViews p)
      case arr (field "arguments" node) of
        [argument] | sameType (field "parameter" signature) (field "type" argument)
                   , sameType (field "result" signature) (field "type" expression) -> Just argument
        _ -> Nothing
    "match" -> case arr (field "cases" node) of
      [branch] -> do
        let body = nodeOf (field "body" branch)
            binders = arr (field "binders" branch)
        (source, sourceConstructor) <- M.lookup (str "constructor" branch) (pConstructors p)
        (target, targetConstructor) <- M.lookup (str "constructor" body) (pConstructors p)
        let sourceFields = arr (field "fields" sourceConstructor)
            targetFields = arr (field "fields" targetConstructor)
            arguments = arr (field "arguments" body)
            copies = and [ str "name" s == str "name" t && localId (unwrapWith (storageView p) a) == Just (str "id" b)
                         | (s, t, a, b) <- zip4 sourceFields targetFields arguments binders ]
        if kind body /= "construct" || kind (field "structure" source) /= "record" || kind (field "structure" target) /= "record"
           || kind (field "origin" expression) /= "generated" || null binders
           || not (all (("lawspec::record-view::" `T.isPrefixOf`) . str "id") binders)
           || length binders /= length sourceFields || length arguments /= length binders
           || length targetFields /= length binders || not copies then Nothing else Just (field "value" node)
      _ -> Nothing
    _ -> Nothing
  where
    localId argument = if nodeKind argument == "local" then Just (str "id" (nodeOf argument)) else Nothing
    zip4 (a:as) (b:bs) (c:cs) (d:ds) = (a, b, c, d) : zip4 as bs cs ds
    zip4 _ _ _ _ = []

unwrapWith :: (Value -> Maybe Value) -> Value -> Value
unwrapWith view expression = maybe expression (unwrapWith view) (view expression)

-- | Names for a type in a register. Nominal records stay nominal; only
-- structural records are spelled out.
typeName :: Presentation -> View -> Value -> Text
typeName p view = go M.empty S.empty
  where
    go substitutions active t = case kind t of
      "variable" -> maybe (str "id" t) (go M.empty S.empty) (M.lookup (str "id" t) substitutions)
      "function" -> let from = go substitutions active (field "parameter" t); to = go substitutions active (field "result" t)
        in case view of
          Eng -> "function from " <> from <> " to " <> to
          Math -> "(" <> from <> " → " <> to <> ")"
          Dev -> "(" <> from <> " -> " <> to <> ")"
      "constructor" -> constructorName substitutions active t
      _ -> str "id" t
    constructorName substitutions active t =
      let name = str "name" t
          declaration = M.lookup name (pDeclarations p)
          arguments = arr (field "arguments" t)
          argText a
            | kind a /= "type" = if has "value" a && not (isNull (field "value" a)) then jsString (field "value" a) else str "id" a
            | otherwise = let text = go substitutions active (field "type" a)
                              nested = kind (field "type" a) == "constructor" && not (null (arr (field "arguments" (field "type" a))))
                          in if nested && view /= Eng then "(" <> text <> ")" else text
          nominal = nominalName p name
          named = case view of
            Eng -> englishTypeName nominal <> (if null arguments then "" else " of " <> joinEnglish (map argText arguments) "and")
            Math -> mathTypeName nominal <> T.concat [" " <> argText a | a <- arguments]
            Dev -> nominal <> T.concat [" " <> argText a | a <- arguments]
      in case declaration of
        Just d | kind (field "structure" d) == "record", not (S.member name active) -> record substitutions active t d
        _ -> named
    record substitutions active t d =
      let constructor = case arr (field "constructors" d) of { c : _ -> c; [] -> Null }
          bindings = foldl (\m (parameter, argument) -> if kind argument == "type"
                              then M.insert parameter (substitute substitutions (field "type" argument)) m else m)
                       substitutions (zip (mapMaybe strMaybe (arr (field "parameters" d))) (arr (field "arguments" t)))
          nested = S.insert (str "name" t) active
          positions = positionalFields d
          ordered = fromMaybe (arr (field "fields" constructor)) positions
          locals = M.fromList [ (str "id" f, if isJust positions then "component" <> T.pack (show i) else str "name" f)
                              | (i, f) <- zip [1 :: Int ..] ordered ]
          structureFields = arr (field "fields" (field "structure" d))
          one f =
            let base = go bindings nested (field "type" f)
                predicates = maybe [] (arr . field "predicates") (find ((== str "name" f) . str "name") structureFields)
                name = M.findWithDefault "" (str "id" f) locals
                restrictions = map (restrictionText p view locals) predicates
                refined | null predicates = base
                        | otherwise = case view of
                            Eng -> base <> " where " <> joinEnglish restrictions "and"
                            Math -> "{" <> name <> " ∈ " <> base <> " | " <> T.intercalate " ∧ " restrictions <> "}"
                            Dev -> "(" <> name <> " of type " <> base <> " where " <> T.intercalate " and " restrictions <> ")"
            in if isJust positions then refined else case view of
                 Eng -> words' (str "name" f) <> " (" <> refined <> ")"
                 Math -> str "name" f <> ": " <> refined
                 Dev -> str "name" f <> " of type " <> refined
          fields = map one ordered
      in case (positions, view) of
           (Just _, Eng) -> "tuple of " <> joinEnglish fields "and"
           (Just _, Math) -> "(" <> T.intercalate " × " fields <> ")"
           (Just _, Dev) -> "(" <> T.intercalate ", " fields <> ")"
           (Nothing, Eng) -> if null fields then "empty record" else "record with " <> joinEnglish fields "and"
           (Nothing, Math) -> "⟨" <> T.intercalate ", " fields <> "⟩"
           (Nothing, Dev) -> "record{" <> T.intercalate ", " fields <> "}"
    substitute bindings t = case kind t of
      "variable" -> M.findWithDefault t (str "id" t) bindings
      "function" -> setFields t [("parameter", substitute bindings (field "parameter" t)), ("result", substitute bindings (field "result" t))]
      "constructor" -> setFields t [("arguments", toJSON [ if kind a == "type" then setFields a [("type", substitute bindings (field "type" a))] else a
                                                          | a <- arr (field "arguments" t)])]
      _ -> t

setFields :: Value -> [(Text, Value)] -> Value
setFields (Object o) updates = Object (foldl (\m (k, v) -> KM.insert (K.fromText k) v m) o updates)
setFields v _ = v

-- | Field restrictions inside a type: a small renderer that keeps every
-- unfamiliar expression verbatim rather than omitting a restriction.
restrictionText :: Presentation -> View -> M.Map Text Text -> Value -> Text
restrictionText p view locals = go
  where
    go expression = case storageView p expression of
      Just inner -> go inner
      Nothing -> let node = nodeOf expression in case kind node of
        "local" -> M.findWithDefault (str "text" expression) (str "id" node) locals
        "field" -> case M.lookup (str "constructor" node) (pConstructors p) >>= \(_, c) -> index (arr (field "fields" c)) (field "index" node) of
          Nothing -> str "text" expression
          Just f -> let value = unwrapWith (storageView p) (field "value" node)
                        text = go value
                        simple = nodeKind value `elem` ["local", "field"]
                    in case view of
                         Eng -> "the " <> words' (str "name" f) <> " of " <> (if simple then text else "(" <> text <> ")")
                         _ -> (if simple then text else "(" <> text <> ")") <> "." <> str "name" f
        k | k `elem` ["binary", "shortCircuit"] ->
          let operator = str "operator" node
          in "(" <> go (field "left" node) <> " " <> operatorIn view operator <> " " <> go (field "right" node) <> ")"
        "unary" -> let operator = str "operator" node; argument = go (field "argument" node) in case view of
          Eng -> (if operator == "!" then "it is not true that " else "minus ") <> "(" <> argument <> ")"
          Math -> (if operator == "!" then "¬" else operator) <> "(" <> argument <> ")"
          Dev -> (if operator == "!" then "not" else operator) <> " (" <> argument <> ")"
        _ -> str "text" expression

index :: [a] -> Value -> Maybe a
index xs (Number n) = let i = floor n :: Int in if i >= 0 && i < length xs && fromIntegral i == n then Just (xs !! i) else Nothing
index _ _ = Nothing

-- * Registers

operatorIn :: View -> Text -> Text
operatorIn Dev operator = fromMaybe operator (lookup operator [("==", "="), ("&&", "and"), ("||", "or")])
operatorIn Math operator = fromMaybe operator (lookup operator [("==", "="), ("!=", "≠"), ("<=", "≤"), (">=", "≥"), ("&&", "∧"), ("||", "∨"), ("*", "·")])
operatorIn Eng operator = fromMaybe operator (lookup operator
  [ ("==", "is"), ("!=", "is not"), ("<", "is less than"), ("<=", "is at most"), (">", "is greater than"), (">=", "is at least")
  , ("&&", "and"), ("||", "or"), ("+", "plus"), ("-", "minus"), ("*", "times"), ("/", "divided by"), ("++", "followed by") ])

negatedComparison :: Text -> Maybe Text
negatedComparison operator = lookup operator
  [ ("==", "is not"), ("!=", "is"), ("<", "is not less than"), ("<=", "is not more than")
  , (">", "is not greater than"), (">=", "is not less than") ]

-- Binding strength, weakest first.
pQuantifier, pOr, pAnd, pComparison, pAdditive, pMultiplicative, pUnary, pPhrase, pAtom :: Int
pQuantifier = 0
pOr = 1
pAnd = 2
pComparison = 3
pAdditive = 4
pMultiplicative = 5
pUnary = 6
pPhrase = 8
pAtom = 9

operatorStrength :: Text -> Int
operatorStrength operator
  | operator == "||" = pOr
  | operator == "&&" = pAnd
  | operator `elem` ["==", "!=", "<", "<=", ">", ">="] = pComparison
  | operator `elem` ["+", "-", "++"] = pAdditive
  | otherwise = pMultiplicative

-- | requestedAmount -> requested amount; a phrase name keeps its own words.
words' :: Text -> Text
words' name
  | Just inner <- T.stripPrefix "\"|" name >>= T.stripSuffix "|" = unescapePhrase inner
  | otherwise = T.toLower (splitCase (T.replace "_" " " name))
  where
    splitCase t = T.pack (go (T.unpack t))
    go (a:b:rest) | (isLower a || isNumber a) && isUpper b = a : ' ' : go (b : rest)
    go (a:b:c:rest) | isUpper a && isUpper b && isLower c = a : ' ' : go (b : c : rest)
    go (a:rest) = a : go rest
    go [] = []

unescapePhrase :: Text -> Text
unescapePhrase = T.pack . go . T.unpack
  where
    go ('\\':c:rest) | c `elem` ("\\|" :: String) = c : go rest
    go (c:rest) = c : go rest
    go [] = []

-- | A Boolean field reads as a property of its record.
englishProperty :: Text -> Text -> Bool -> Text
englishProperty subject label negated =
  let spoken = T.words (words' label)
      verbs = [("is", "is", "is not"), ("has", "has", "does not have"), ("can", "can", "cannot"),
               ("was", "was", "was not"), ("should", "should", "should not"), ("must", "must", "must not")]
  in case [ (yes, no) | (prefix, yes, no) <- verbs, take 1 spoken == [prefix], length spoken > 1 ] of
       (yes, no) : _ -> subject <> " " <> (if negated then no else yes) <> " " <> T.unwords (drop 1 spoken)
       [] -> subject <> " " <> (if negated then "is not" else "is") <> " " <> T.unwords spoken

joinEnglish :: [Text] -> Text -> Text
joinEnglish items connective
  | length items < 3 = T.intercalate (" " <> connective <> " ") items
  | otherwise = T.intercalate ", " (init items) <> ", " <> connective <> " " <> last items

article :: Text -> Text
article noun = case T.unpack (T.toLower noun) of
  c : _ | c `elem` ("aeiou" :: String), not (any (`T.isPrefixOf` T.toLower noun) ["uni", "use", "one"]) -> "an " <> noun
  _ -> "a " <> noun

mathTypeName :: Text -> Text
mathTypeName name = fromMaybe name (lookup name [("Integer", "ℤ"), ("Whole", "ℕ"), ("Bool", "𝔹")])

englishTypeName :: Text -> Text
englishTypeName name = fromMaybe name (lookup name
  [("Integer", "integer"), ("Whole", "whole number"), ("Bool", "true or false value"), ("Text", "text")])

-- * Checked expressions

data Rendered = Rendered
  { rText :: Text, rAtomic :: Bool, rStrength :: Maybe Int
  , rConnective :: Maybe (Text, Int)          -- ^ eng connective and item count
  , rComparison :: Maybe (Text, Text, Text)   -- ^ eng operator, left, right
  }

plain :: Text -> Bool -> Rendered
plain text atomic = Rendered text atomic Nothing Nothing Nothing

worded :: Text -> Int -> Rendered
worded text strength = Rendered text (strength >= pAtom) (Just strength) Nothing Nothing

strengthOf :: Rendered -> Int
strengthOf r = fromMaybe (if rAtomic r then pAtom else pQuantifier) (rStrength r)

slot :: Rendered -> Int -> Text
slot r minimum' = if strengthOf r >= minimum' then rText r else "(" <> rText r <> ")"

argumentText :: Rendered -> Text
argumentText r = if rAtomic r then rText r else "(" <> rText r <> ")"

data Context = Term | Condition deriving Eq

type Scope = M.Map Text Text
type Reserved = S.Set Text

-- | A term renderer for one register. Nothing means a node the presentation
-- does not know; the whole expression then keeps its compiler text.
data Terms = Terms
  { termText :: Scope -> Value -> Text
  , termCondition :: Scope -> Value -> Text
  , termConditions :: Scope -> Value -> [Text]
  , termStrength :: Scope -> Value -> (Text, Int) }

terms :: Presentation -> View -> Terms
terms p view = Terms (\s -> rText . top Term s) (\s -> rText . top Condition s) conditions
  (\s e -> let r = top Condition s e in (rText r, strengthOf r))
  where
    english = view == Eng
    mathematical = view == Math
    unwrap = unwrapWith (storageView p)
    isStored expression = field "lawspec-stored-value" expression == Bool True
    isBool expression = kind (field "type" expression) == "constructor" && str "name" (field "type" expression) == "Bool"

    -- Fall back for the entire expression, including its original binders:
    -- mixing renamed binders with opaque child text could capture a local.
    top context scope expression = case freeLocals expression of
      Nothing -> plain (str "text" expression) False
      Just free ->
        let reserved = S.fromList [name | (i, name) <- M.toList free, not (M.member i scope)]
        in fromMaybe (plain (str "text" expression) False) (render (M.union scope free) reserved context expression)
    conditions scope expression = map (rText . top Condition scope) (fromMaybe [expression] (chain "&&" expression))

    spelling name
      | "\"|" `T.isPrefixOf` name = name
      | Just (c, rest) <- T.uncons name, isLetter c || c == '_', T.all (\x -> isLetter x || isNumber x || x == '_') rest = name
      | otherwise = "\"|" <> T.replace "|" "\\|" (T.replace "\\" "\\\\" name) <> "|"

    abilityName key = case find (\i -> key == i || (i <> "(") `T.isPrefixOf` key) (pAbilityIds p) of
      Nothing -> key
      Just i -> let (name, owner) = pAbilities p M.! i; spelled = spelling name
                in (if M.findWithDefault 0 name (pAbilityCounts p) > 1 then owner <> "." <> spelled else spelled) <> T.drop (T.length i) key

    globalName i scope = do
      value <- M.lookup i (pValues p)
      case vnCanonical value of
        Just canonical -> Just canonical
        Nothing -> let name = spelling (vnName value)
                   in Just (if M.findWithDefault 0 (vnName value) (pIdentityCounts p) > 1 || name `elem` M.elems scope
                              then vnOwner value <> "." <> name else name)

    -- Free locals in traversal order; Nothing for an unknown node.
    freeLocals :: Value -> Maybe (M.Map Text Text)
    freeLocals expression = M.fromList <$> children S.empty expression
    children bound expression = let node = nodeOf expression; visit = children bound
                                    scoped binders = S.union bound (S.fromList (map (str "id") binders))
                                    many = fmap concat . traverse visit in
      if isNull node then Nothing else case kind node of
        "constant" -> Just []
        "local" -> Just [(str "id" node, str "text" expression) | not (S.member (str "id" node) bound)]
        "let" -> (++) <$> visit (field "value" node) <*> children (scoped [field "binder" node]) (field "body" node)
        "match" -> (++) <$> visit (field "value" node) <*> (concat <$> traverse (\b -> children (scoped (arr (field "binders" b))) (field "body" b)) (arr (field "cases" node)))
        "allElements" -> (++) <$> visit (field "value" node) <*> children (scoped [field "binder" node]) (field "predicate" node)
        "allPayloads" -> (++) <$> visit (field "value" node) <*> (concat <$> traverse (\q -> children (scoped [field "binder" q]) (field "predicate" q)) (arr (field "predicates" node)))
        "field" -> visit (field "value" node)
        "update" -> (++) <$> visit (field "value" node) <*> visit (field "field" node)
        k | k `elem` ["binary", "shortCircuit"] -> (++) <$> visit (field "left" node) <*> visit (field "right" node)
        k | k `elem` ["unary", "convert"] -> visit (field "argument" node)
        "if" -> many [field "condition" node, field "then" node, field "else" node]
        "handle" -> visit (field "body" node)
        k | k `elem` ["construct", "call", "helper", "perform", "calls"] -> many (arr (field "arguments" node))
        _ -> Nothing

    bind binder scope reserved =
      let name0 = str "name" binder
          generated = any (`T.isPrefixOf` name0) ["lawspec", "~lawspec", "_lawspec"]
          base = if generated then "value" else name0
          used = S.union (S.fromList (M.elems scope)) reserved
          stem = if "\"|" `T.isPrefixOf` base then "value" else base
          name = firstFree used (base : [stem <> T.pack (show k) | k <- [1 :: Int ..]])
      in (name, M.insert (str "id" binder) name scope)

    freshComponent base scope reserved =
      let used = S.unions [S.fromList (M.elems scope), reserved, S.fromList (map vnName (M.elems (pValues p)))]
          name = firstFree used (base : [base <> "_" <> T.pack (show k) | k <- [1 :: Int ..]])
      in (name, S.insert name reserved)

    listElements expression = go [] expression
      where
        go items e
          | kind (field "type" e) == "constructor" && str "name" (field "type" e) == "List" =
              let node = nodeOf e; arguments = arr (field "arguments" node) in
              if kind node /= "construct" then Nothing
              else if str "constructor" node == "List::Nil" && null arguments then Just (reverse items)
              else case arguments of
                [h, t] | str "constructor" node == "List::Cons" -> go (h : items) t
                _ -> Nothing
          | otherwise = Nothing

    constructed tag entries scope reserved stored = do
      (declaration, _) <- M.lookup tag (pConstructors p)
      case positionalFields declaration of
        Just positions -> do
          let byName = M.fromList entries
          if length entries /= length positions || M.size byName /= length positions
             || not (all ((`M.member` byName) . str "name") positions) then Nothing
          else if stored || and (zipWith (\f (label, _) -> str "name" f == label) positions entries)
            then Just (plain ("(" <> T.intercalate ", " [rText (byName M.! str "name" f) | f <- positions] <> ")") True)
            else
              let step (used, done, named) (label, value) =
                    let position = maybe 0 (+ 1) (findIndex ((== label) . str "name") positions)
                        (name, used') = freshComponent ("component" <> T.pack (show position)) scope used
                    in (used', done ++ ["let " <> name <> " = " <> rText value <> " in "], M.insert label name named)
                  (_, lets, names) = foldl step (reserved, [], M.empty) entries
              in Just (plain (T.concat lets <> "(" <> T.intercalate ", " [M.findWithDefault "" (str "name" f) names | f <- positions] <> ")"
                         <> T.replicate (length lets) " end let") False)
        Nothing
          -- eng: a named construction reads as a description of the new value.
          | english, not (null entries) -> do
              name <- if kind (field "structure" declaration) == "record" then Just "record" else plainName <$> globalName tag scope
              Just (worded (article name <> " with " <> joinEnglish [words' label <> " " <> slot value pPhrase | (label, value) <- entries] "and") 7)
          | kind (field "structure" declaration) == "record" ->
              Just (plain ("record{" <> T.intercalate ", " [label <> " = " <> rText value | (label, value) <- entries] <> "}") True)
          | otherwise -> do
              name <- globalName tag scope
              Just (plain (if null entries then name else name <> "(" <> T.intercalate ", " [label <> " = " <> rText value | (label, value) <- entries] <> ")") True)

    projection expression = let node = nodeOf expression in case (kind node, arr (field "cases" node)) of
      ("match", [branch]) -> do
        entry@(declaration, constructor) <- M.lookup (str "constructor" branch) (pConstructors p)
        let binders = arr (field "binders" branch); fields = arr (field "fields" constructor); body = nodeOf (field "body" branch)
        if length (arr (field "constructors" declaration)) /= 1 || length binders /= length fields || kind body /= "local" then Nothing else do
          i <- findIndex ((== str "id" body) . str "id") binders
          Just (field "value" node, entry, str "name" (fields !! i))
      _ -> Nothing

    fieldParts expression = case projection expression of
      Just parts -> Just parts
      Nothing -> let node = nodeOf expression in
        if kind node /= "field" then Nothing else do
          entry@(_, constructor) <- M.lookup (str "constructor" node) (pConstructors p)
          f <- index (arr (field "fields" constructor)) (field "index" node)
          Just (field "value" node, entry, str "name" f)

    selectedField (declaration, _) label value scope reserved = case positionalFields declaration of
      Nothing -> plain (argumentText value <> "." <> label) True
      Just positions ->
        let (name, _) = freshComponent "component" scope reserved
            pattern = T.intercalate ", " [if str "name" f == label then name else "#any" | f <- positions]
        in plain ("first matching case of " <> rText value <> ": when (" <> pattern <> ") then " <> name <> " end case") False

    iterationCollection expression =
      let node = nodeOf expression in case (kind node, str "name" node, arr (field "arguments" node)) of
        ("helper", "prelude.octets", [argument]) | str "name" (field "type" argument) == "Bytes" -> argument
        ("match", _, _) | [branch] <- arr (field "cases" node)
                        , Just (declaration, constructor) <- M.lookup (str "constructor" branch) (pConstructors p)
                        , str "id" declaration `elem` ["lawspec.collections::type::" <> n | n <- ["EqSet", "Set", "Queue", "Stack", "Deque", "KeyVal"]]
                        , str "name" (field "type" (field "value" node)) == str "id" declaration
                        , length (arr (field "fields" constructor)) == 1
                        , [binder] <- arr (field "binders" branch)
                        , nodeKind (field "body" branch) == "local"
                        , str "id" (nodeOf (field "body" branch)) == str "id" binder -> field "value" node
        _ -> expression

    membership expression scope reserved = do
      let outer = nodeOf expression; inner = nodeOf (field "body" outer)
      if kind outer /= "let" || kind inner /= "let" || str "id" (field "binder" outer) == str "id" (field "binder" inner) then Nothing else do
        innerFree <- freeLocals (field "value" inner)
        let negated = nodeOf (field "body" inner); iteration = nodeOf (field "argument" negated)
            collection = iterationCollection (field "value" iteration); comparison = nodeOf (field "predicate" iteration)
            localIs e i = nodeKind e == "local" && str "id" (nodeOf e) == i
        if M.member (str "id" (field "binder" outer)) innerFree || kind negated /= "unary" || str "operator" negated /= "!"
           || kind iteration /= "allElements" || not (localIs collection (str "id" (field "binder" inner)))
           || kind comparison /= "binary" || str "operator" comparison /= "!="
           || not (localIs (field "left" comparison) (str "id" (field "binder" outer)))
           || not (localIs (field "right" comparison) (str "id" (field "binder" iteration))) then Nothing
        else (,) <$> render scope reserved Term (field "value" outer) <*> render scope reserved Term (field "value" inner)

    literal expression scope reserved = do
      let collect bs e = if nodeKind e == "let" then collect (nodeOf e : bs) (field "body" (nodeOf e)) else (reverse bs, e)
          (bindings, body0) = collect [] expression
          body = unwrap body0
          node = nodeOf body
          arguments = arr (field "arguments" node)
      (_, constructor) <- M.lookup (str "constructor" node) (pConstructors p)
      let fields = arr (field "fields" constructor)
      if kind node /= "construct" || length arguments /= length bindings || length arguments /= length fields then Nothing else do
        let locals = [nodeOf (unwrap a) | a <- arguments]
        if any ((/= "local") . kind) locals || S.size (S.fromList (map (str "id") locals)) /= length locals
           || S.size (S.fromList (map (str "id" . field "binder") bindings)) /= length bindings then Nothing else do
          let positions = M.fromList (zip (map (str "id") locals) [0 :: Int ..])
              step (preceding, entries) binding = do
                position <- M.lookup (str "id" (field "binder" binding)) positions
                free <- freeLocals (field "value" binding)
                if any (`S.member` preceding) (M.keys free) then Nothing else do
                  value <- render scope reserved Term (field "value" binding)
                  Just (S.insert (str "id" (field "binder" binding)) preceding, entries ++ [(str "name" (fields !! position), value)])
          (_, entries) <- foldlM step (S.empty, []) bindings
          constructed (str "constructor" node) entries scope reserved False

    chain operator expression0 = let expression = unwrap expression0; node = nodeOf expression in
      if kind node == "shortCircuit" && str "operator" node == operator
        then Just (flatten operator (field "left" node) ++ flatten operator (field "right" node))
        else Nothing

    flatten operator expression = fromMaybe [unwrap expression] (chain operator expression)

    anyPattern node =
      let iteration = nodeOf (field "argument" node); predicate = nodeOf (field "predicate" iteration)
      in if str "operator" node == "!" && kind iteration == "allElements" && kind predicate == "unary" && str "operator" predicate == "!"
           then Just (iteration, predicate) else Nothing

    quantified universal binder collection body scope reserved = do
      let (name, inner) = bind binder scope reserved
      set <- render scope reserved Term collection
      predicate <- render inner reserved Condition body
      Just (if mathematical
        then worded ((if universal then "∀ " else "∃ ") <> name <> " ∈ " <> slot set pAtom <> ". " <> rText predicate) pQuantifier
        else worded ("for " <> (if universal then "every " else "at least one ") <> name <> " in " <> slot set pPhrase <> ", " <> rText predicate) pQuantifier)

    plainName name = case T.breakOnEnd "\"|" name of
      (before, rest) | not (T.null before), Just inner <- T.stripSuffix "|" rest -> T.dropEnd 2 before <> unescapePhrase inner
      _ -> name

    -- The eng and math wording of one node; Nothing keeps the dev rendering.
    phrase scope reserved context expression = let node = nodeOf expression; go c = render scope reserved c in
      case fieldParts expression of
        Just (value, entry@(declaration, _), label) | Nothing <- positionalFields declaration -> do
          subject <- go Term value
          let _ = entry
          Just (if mathematical then worded (slot subject pAtom <> "." <> label) pAtom
                else if context == Condition && isBool expression then worded (englishProperty (slot subject pPhrase) label False) pComparison
                else worded ("the " <> words' label <> " of " <> slot subject pPhrase) pPhrase)
        Just _ -> Nothing
        Nothing -> case kind node of
          "let" -> do
            (element, collection) <- membership expression scope reserved
            Just (if mathematical then worded (slot element pAdditive <> " ∈ " <> slot collection pAdditive) pComparison
                  else worded (slot element pPhrase <> " is in " <> slot collection pPhrase) pComparison)
          k | k `elem` ["binary", "shortCircuit"] -> do
            let operator = str "operator" node; strength = operatorStrength operator
            if operator `elem` ["&&", "||"] then do
              parts <- traverse (go Condition) (flatten operator expression)
              Just (if mathematical then worded (T.intercalate (" " <> operatorIn Math operator <> " ") [slot r pComparison | r <- parts]) strength
                else let grouped = [ case rConnective r of
                                       Just (c, n) | c /= operator -> (if c == "||" then "either " else if n == 2 then "both " else "all of ") <> rText r
                                       _ -> rText r | r <- parts ]
                     in (worded (joinEnglish grouped (operatorIn Eng operator)) strength) { rConnective = Just (operator, length parts) })
            else do
              left <- go Term (field "left" node)
              right <- go Term (field "right" node)
              let comparison = strength == pComparison
                  l = slot left (if comparison then pAdditive else strength)
                  r = slot right (if comparison then pAdditive else strength + 1)
              Just ((worded (l <> " " <> operatorIn view operator <> " " <> r) strength)
                      { rComparison = if comparison then Just (operator, l, r) else Nothing })
          "unary"
            | Just (iteration, predicate) <- anyPattern node ->
                quantified False (field "binder" iteration) (iterationCollection (field "value" iteration)) (field "argument" predicate) scope reserved
            | str "operator" node /= "!" -> do
                argument <- go Term (field "argument" node)
                Just (worded ((if mathematical then str "operator" node else "minus ") <> slot argument pUnary) pUnary)
            | mathematical -> do
                argument <- go Condition (field "argument" node)
                Just (worded ("¬" <> slot argument pUnary) pUnary)
            | otherwise -> do
                let inner = unwrap (field "argument" node)
                case fieldParts inner of
                  Just (value, (declaration, _), label) | isBool inner, Nothing <- positionalFields declaration -> do
                    subject <- go Term value
                    Just (worded (englishProperty (slot subject pPhrase) label True) pComparison)
                  _ -> do
                    shown <- go Condition inner
                    Just (case rComparison shown of
                      Just (operator, l, r) | Just negated <- negatedComparison operator -> worded (l <> " " <> negated <> " " <> r) pComparison
                      _ -> worded ("it is not true that " <> rText shown) pQuantifier)
          "allElements" -> quantified True (field "binder" node) (field "value" node) (field "predicate" node) scope reserved
          "if" | english -> do
            condition <- go Condition (field "condition" node)
            yes <- go context (field "then" node)
            no <- go context (field "else" node)
            Just (worded ("if " <> rText condition <> " then " <> rText yes <> ", otherwise " <> rText no) pQuantifier)
          k | k `elem` ["call", "helper"] -> do
            let setOf = k == "call" && (M.lookup (str "declaration" node) (pValues p) >>= vnCanonical) == Just "prelude.setOf"
            if setOf then Nothing else do
              name <- if k == "call" then globalName (str "declaration" node) scope else Just (str "name" node)
              parts <- traverse (go Term) (arr (field "arguments" node))
              Just (if mathematical
                then worded (if null parts then name else name <> "(" <> T.intercalate ", " (map rText parts) <> ")") pAtom
                else if null parts then worded (plainName name) pAtom
                else worded (plainName name <> " of " <> T.intercalate " and " [slot r pPhrase | r <- parts]) 7)
          _ -> Nothing

    render :: Scope -> Reserved -> Context -> Value -> Maybe Rendered
    render scope reserved context expression0 = do
      let expression = unwrap expression0
          node = nodeOf expression
          go = render scope reserved Term
          goIn s = render s reserved Term
          args values = T.unwords . map argumentText <$> traverse go values
      if isNull node then Nothing else
        case listElements expression of
          Just items -> do
            shown <- traverse go items
            Just (plain ("[" <> T.intercalate ", " (map rText shown) <> "]") True)
          Nothing -> case (if view /= Dev then phrase scope reserved context expression else Nothing) of
            Just phrased -> Just phrased
            Nothing -> case projection expression of
              Just (value, entry, label) -> do
                shown <- go value
                Just (selectedField entry label shown scope reserved)
              Nothing -> dev scope reserved expression node go goIn args

    dev scope reserved expression node go goIn args = case kind node of
      "constant" -> Just (if str "type" (field "value" node) == "Unit" then plain "()" True
                          else let text = str "text" expression in plain text (constantAtomic text || "\"" `T.isPrefixOf` text))
      "local" -> Just (plain (M.findWithDefault (str "text" expression) (str "id" node) scope) True)
      "construct"
        | str "constructor" node == "lawspec.collections::type::EqSet::EqSetItems", isStored expression
        , [items] <- arr (field "arguments" node), Just elements <- listElements items -> do
            shown <- traverse go elements
            Just (plain ("#S{" <> T.intercalate ", " (map rText shown) <> "}") True)
        | otherwise -> do
            (_, constructor) <- M.lookup (str "constructor" node) (pConstructors p)
            let fields = arr (field "fields" constructor); arguments = arr (field "arguments" node)
            if length fields /= length arguments then Nothing else do
              shown <- traverse go arguments
              constructed (str "constructor" node) (zip (map (str "name") fields) shown) scope reserved (isStored expression)
      "let" -> case membership expression scope reserved of
        Just (element, collection) -> Just (plain ("(" <> argumentText element <> " in " <> argumentText collection <> ")") True)
        Nothing -> case literal expression scope reserved of
          Just record -> Just record
          Nothing -> do
            let (name, inner) = bind (field "binder" node) scope reserved
            value <- go (field "value" node)
            body <- goIn inner (field "body" node)
            Just (plain ("let " <> name <> " = " <> rText value <> " in " <> rText body <> " end let") False)
      "field" -> do
        entry@(_, constructor) <- M.lookup (str "constructor" node) (pConstructors p)
        f <- index (arr (field "fields" constructor)) (field "index" node)
        value <- go (field "value" node)
        Just (selectedField entry (str "name" f) value scope reserved)
      "update" -> do
        entry@(declaration, constructor) <- M.lookup (str "constructor" node) (pConstructors p)
        f <- index (arr (field "fields" constructor)) (field "index" node)
        let _ = entry
        value <- go (field "value" node)
        replacement <- go (field "field" node)
        case positionalFields declaration of
          Just positions ->
            let (r, used1) = freshComponent "replacement" scope reserved
                (names, _) = foldl (\(ns, used) i -> let (n, used') = freshComponent ("component" <> T.pack (show i)) scope used in (ns ++ [n], used'))
                                   ([], used1) [1 .. length positions]
                result = [if str "name" position == str "name" f then r else n | (position, n) <- zip positions names]
            in Just (plain ("let " <> r <> " = " <> rText replacement <> " in first matching case of " <> rText value <> ": when ("
                       <> T.intercalate ", " names <> ") then (" <> T.intercalate ", " result <> ") end case end let") False)
          Nothing -> Just (plain (argumentText value <> " with " <> str "name" f <> " = " <> rText replacement) False)
      "call"
        | (M.lookup (str "declaration" node) (pValues p) >>= vnCanonical) == Just "prelude.setOf"
        , [items] <- arr (field "arguments" node), Just elements <- listElements items -> do
            shown <- traverse go elements
            Just (plain ("#S{" <> T.intercalate ", " (map rText shown) <> "}") True)
        | otherwise -> do
            name <- globalName (str "declaration" node) scope
            shown <- args (arr (field "arguments" node))
            Just (plain (name <> (if null (arr (field "arguments" node)) then "" else " " <> shown)) False)
      "helper" -> do
        shown <- args (arr (field "arguments" node))
        Just (plain (str "name" node <> (if null (arr (field "arguments" node)) then "" else " " <> shown)) False)
      k | k `elem` ["binary", "shortCircuit"] -> do
        left <- go (field "left" node)
        right <- go (field "right" node)
        Just (plain ("(" <> argumentText left <> " " <> operatorIn Dev (str "operator" node) <> " " <> argumentText right <> ")") True)
      "unary" -> case anyPattern node of
        Just (iteration, predicate) -> do
          let (name, inner) = bind (field "binder" iteration) scope reserved
          collection <- go (iterationCollection (field "value" iteration))
          body <- goIn inner (field "argument" predicate)
          Just (plain ("any " <> name <> " in (" <> rText collection <> ") satisfies (" <> rText body <> ")") False)
        Nothing -> do
          argument <- go (field "argument" node)
          Just (plain ((if str "operator" node == "!" then "not" else str "operator" node) <> " (" <> rText argument <> ")") False)
      "if" -> do
        c <- go (field "condition" node); t <- go (field "then" node); e <- go (field "else" node)
        Just (plain ("if " <> rText c <> " then " <> rText t <> " else " <> rText e <> " end if") False)
      "convert" -> do
        argument <- go (field "argument" node)
        Just (plain (str "conversion" node <> " conversion of (" <> rText argument <> ") to " <> typeName p Dev (field "type" expression)) False)
      "match" -> do
        value <- go (field "value" node)
        branches <- traverse (\branch -> do
          let (names, bindings) = foldl (\(ns, s) b -> let (n, s') = bind b s reserved in (ns ++ [n], s')) ([], scope) (arr (field "binders" branch))
          (declaration, constructor) <- M.lookup (str "constructor" branch) (pConstructors p)
          let fields = arr (field "fields" constructor)
          if length fields /= length names then Nothing else do
            let fieldNames = M.fromList (zip (map (str "name") fields) names)
            pattern <- case positionalFields declaration of
              Just positions -> Just ("(" <> T.intercalate ", " [M.findWithDefault "" (str "name" f) fieldNames | f <- positions] <> ")")
              Nothing | kind (field "structure" declaration) == "record" ->
                          Just ("record{" <> T.intercalate ", " [str "name" f <> " = " <> n | (f, n) <- zip fields names] <> "}")
                      | otherwise -> do
                          name <- globalName (str "constructor" branch) scope
                          Just (name <> T.concat [" " <> n | n <- names])
            body <- goIn bindings (field "body" branch)
            Just ("when " <> pattern <> " then " <> rText body)) (arr (field "cases" node))
        Just (plain ("first matching case of " <> argumentText value <> ": " <> T.unwords branches <> " end case") False)
      "allElements" -> do
        let (name, inner) = bind (field "binder" node) scope reserved
        value <- go (field "value" node)
        predicate <- goIn inner (field "predicate" node)
        Just (plain ("every " <> name <> " in (" <> rText value <> ") satisfies (" <> rText predicate <> ")") False)
      "allPayloads" -> do
        value <- go (field "value" node)
        predicates <- traverse (\q -> do
          let (name, inner) = bind (field "binder" q) scope reserved
          body <- goIn inner (field "predicate" q)
          Just (name <> " of type " <> typeName p Dev (field "type" (field "binder" q)) <> " => " <> rText body)) (arr (field "predicates" node))
        Just (plain ("allPayloads (" <> rText value <> ") [" <> T.intercalate "; " predicates <> "]") False)
      "perform" -> do
        shown <- traverse go (arr (field "arguments" node))
        Just (plain ("perform " <> abilityName (str "ability" node) <> "." <> str "operation" node <> "(" <> T.intercalate ", " (map rText shown) <> ")") False)
      "handle" -> do
        body <- go (field "body" node)
        case str "handling" node of
          "catchFailure" -> Just (plain ("catch failure of " <> abilityName (str "ability" node) <> " in (" <> rText body <> ")") False)
          "withHandler" -> Just (plain ("handle (" <> rText body <> ") with " <> str "handler" node <> " for " <> abilityName (str "ability" node) <> " end handle") False)
          _ -> Nothing
      "calls" -> do
        shown <- case field "arguments" node of
          Null -> Just Nothing
          a -> Just <$> traverse go (arr a)
        Just (plain ("calls of " <> abilityName (str "ability" node) <> "." <> str "operation" node
                     <> maybe "" (\xs -> " with (" <> T.intercalate ", " (map rText xs) <> ")") shown) False)
      _ -> Nothing

firstFree :: S.Set Text -> [Text] -> Text
firstFree used candidates = case filter (not . (`S.member` used)) candidates of
  name : _ -> name
  [] -> ""

constantAtomic :: Text -> Bool
constantAtomic text = text `elem` ["true", "false"] || number (T.unpack text)
  where
    number s = case sign s of
      d@(_:_) | (digits, rest) <- span isDigit d, not (null digits) -> fraction rest
      _ -> False
    sign ('+':s) = s
    sign ('-':s) = s
    sign s = s
    fraction ('.':s) | (digits, rest) <- span isDigit s, not (null digits) = exponent' rest
    fraction s = exponent' s
    exponent' (e:s) | e `elem` ("eE" :: String) = case sign s of
      d | (digits, rest) <- span isDigit d, not (null digits) -> null rest
      _ -> False
    exponent' s = null s

foldlM :: Monad m => (b -> a -> m b) -> b -> [a] -> m b
foldlM _ z [] = return z
foldlM f z (x:xs) = f z x >>= \z' -> foldlM f z' xs

-- * Values

showScalar :: Value -> Text
showScalar v
  | has "coefficient" v = jsString (field "coefficient" v) <> "e" <> jsString (field "exponent" v)
  | has "numerator" v = "rational(" <> jsString (field "numerator" v) <> ", " <> jsString (field "denominator" v) <> ")"
  | has "bits" v = (if str "type" v == "Float32" then "float32Bits" else "float64Bits") <> "(" <> jsonText (field "bits" v) <> ")"
  | has "real" v = str "type" v <> "(" <> showScalar (field "real" v) <> ", " <> showScalar (field "imaginary" v) <> ")"
  | has "units" v = if str "type" v == "Text"
      then quoteJson (T.pack [toEnum (floor n) | Number n <- arr (field "units" v)])
      else str "type" v <> "([" <> T.intercalate ", " (map jsString (arr (field "units" v))) <> "])"
  | str "type" v == "Symbol" = "symbol(" <> jsonText (field "id" v) <> ", " <> jsonText (field "description" v) <> ")"
  | str "type" v `elem` ["Optional", "Nullable"] = if isNull (field "value" v)
      then (if str "type" v == "Optional" then "undefined" else "null")
      else T.toLower (str "type" v) <> "(" <> showScalar (field "value" v) <> ")"
  | has "value" v = jsString (field "value" v)
  | otherwise = fromMaybe (str "type" v) (lookup (str "type" v) [("Unit", "unitValue"), ("Null", "null"), ("Undefined", "undefined")])

-- | Example bindings are checked concrete values: rendered through the same
-- constructor metadata, never executed.
valueExpression :: Value -> Value
valueExpression value
  | kind value == "data" = object
      [ "type" .= field "type" value, "text" .= jsonText value, "lawspec-stored-value" .= True
      , "node" .= object ["kind" .= ("construct" :: Text), "constructor" .= field "constructor" value
                        , "arguments" .= map valueExpression (arr (field "fields" value))] ]
  | otherwise = object
      [ "type" .= object ["kind" .= ("constructor" :: Text), "name" .= field "type" value, "arguments" .= ([] :: [Value])]
      , "text" .= showScalar value, "node" .= object ["kind" .= ("constant" :: Text), "value" .= value] ]

-- * Laws

explainOne :: Presentation -> View -> Value -> Value -> Explanation
explainOne p view evidenceRows law = Explanation view (str "id" law) (str "name" law) (filter (not . null . snd) sections)
  where
    scope = M.fromList [(str "id" input, str "name" input) | input <- inputs]
    inputs = arr (field "inputs" law)
    evidence = [e | e <- arr evidenceRows, str "declaration" e == str "id" law]
    metadata = field "metadata" law
    documentary = [ "Requirement: " <> t | Just t <- [jsStringMaybe (field "id" metadata)] ]
               ++ [ "Owner: " <> t | Just t <- [jsStringMaybe (field "owner" metadata)] ]
               ++ [ "Reference: " <> referenceText r | r <- arr (field "references" law) ]
    jsStringMaybe Null = Nothing
    jsStringMaybe v = Just (jsString v)
    devTerms = terms p Dev
    restrictionsIn ts = concat [map (termText ts scope) (arr (field "predicates" input)) | input <- inputs]
    sections = case view of
      Dev -> devSections
      Math -> mathSections
      Eng -> engSections
    -- dev: the identity, documentary facts, configured strategies, typed
    -- inputs, the law in LawSpec notation, its source and its examples.
    devSections =
      let quantifiers = [str "name" input <> " of type " <> typeName p Dev (field "type" input) | input <- inputs]
          restrictions = restrictionsIn devTerms
          harness = field "harness" law
          strategies = [ "Configured witness (not completed evidence): definition." <> T.intercalate "." (map jsString (arr (field "path" w)))
                         <> " = " <> termText devTerms scope (field "expression" w) | w <- arr (field "witnesses" harness) ]
                    ++ [ "Configured search (not completed evidence): definition." <> T.intercalate "." (map jsString (arr (field "path" s)))
                         <> " uses " <> str "strategy" s | s <- arr (field "searches" harness) ]
          location = field "location" law
          examples = arr (field "examples" law)
      in [ ("law", [str "id" law]), ("documentary", documentary), ("trace", map jsString (arr (field "trace" law)))
         , ("strategies", strategies)
         , ("inputs", ["Inputs: " <> T.intercalate "; " quantifiers | not (null quantifiers)])
         , ("restrictions", ["Restrictions: " <> T.intercalate " and " restrictions | not (null restrictions)])
         , ("statement", splitLines (devProposition p scope (field "assertion" law)))
         , ("source", ["Source: " <> str "file" location <> ":" <> jsString (field "line" location) <> ":" <> jsString (field "column" location)])
         , ("examples", ("Examples: " <> T.pack (show (length examples))) : concatMap (exampleLines p scope) examples)
         , ("native-evidence", concatMap (splitLines . nativeEvidenceText) [e | e <- evidence, not (isNull (field "nativeEvidence" e))]) ]
    -- math: quantifiers over sets, then one formula.
    mathSections =
      let mathTerms = terms p Math
          binders = [str "name" input <> " ∈ " <> typeName p Math (field "type" input) | input <- inputs]
          restrictions = restrictionsIn mathTerms
          (formula, strength) = mathProposition p scope (field "assertion" law)
          guarded = if null restrictions then formula
                    else let r = T.intercalate " ∧ " restrictions
                             r' = if length restrictions > 1 then "(" <> r <> ")" else r
                         in r' <> " ⇒ " <> (if strength <= mImplies then "(" <> formula <> ")" else formula)
      in [ ("title", ["Law: " <> words' (str "name" law)])
         , ("quantifiers", ["∀ " <> T.intercalate ", " binders <> "." | not (null binders)])
         , ("formula", [if null binders then guarded else "  " <> guarded]) ]
    -- eng: the law's name, what it is for, then the rule in short lines.
    engSections =
      let engTerms = terms p Eng
          binders = [str "name" input <> " (" <> article (typeName p Eng (field "type" input)) <> ")" | input <- inputs]
          restrictions = concat [map (termCondition engTerms scope) (arr (field "predicates" input)) | input <- inputs]
          statement = finish (engProposition p scope True (field "assertion" law))
          header | null binders = []
                 | null restrictions = ["For every " <> joinEnglish binders "and" <> ":"]
                 | otherwise = ["For every " <> joinEnglish binders "and", "where " <> joinEnglish restrictions "and" <> ":"]
      in [ ("title", ["Law: " <> words' (str "name" law)]), ("documentary", documentary)
         , ("description", [l | Just t <- [strField "description" law], not (T.null t), l <- splitLines t])
         , ("inputs", header)
         , ("statement", if null header then statement else map ("  " <>) statement)
         , ("reason", ["Reason: " <> t | Just t <- [strField "rationale" law], not (T.null t)]) ]
    finish [] = []
    finish ls = let l = last ls in init ls ++ [if T.null l || T.last l `elem` (":." :: String) then l else l <> "."]

-- | JavaScript's split on newlines: an empty text is one empty line.
splitLines :: Text -> [Text]
splitLines = T.splitOn "\n"

exampleName :: Text -> Text
exampleName name
  | "\"|" `T.isPrefixOf` name && "|" `T.isSuffixOf` name = name
  | otherwise = "\"|" <> T.replace "|" "\\|" (T.replace "\\" "\\\\" name) <> "|"

exampleLines :: Presentation -> Scope -> Value -> [Text]
exampleLines p scope example =
  let bindings = arr (field "bindings" example)
      locals = foldl (\m b -> M.insert (str "id" b) (str "name" b) m) scope bindings
  in ["example " <> exampleName (str "name" example) <> ":"]
     ++ ["  " <> str "name" b <> " = " <> termText (terms p Dev) locals (valueExpression (field "value" b)) | b <- bindings]
     ++ ["  expect " <> devProposition p locals e | e <- arr (field "expectations" example)]
     ++ ["end example"]

referenceText :: Value -> Text
referenceText (String t) = t
referenceText r
  | kind r == "external" = (if T.null (str "name" r) then "" else str "name" r <> ": ") <> str "resource" r
  | otherwise =
      let selector = field "selector" r
          section | kind selector == "named-reference" = " references." <> str "name" selector
                  | isNull selector = ""
                  | otherwise = " " <> kind selector
          raw = str "name" (field "target" r)
          identifier = case T.uncons raw of
            Just (c, rest) -> isLetter c && T.all (\x -> isLetter x || isNumber x || x == '_') rest
            Nothing -> False
          -- Built-in laws retain legacy source names internally; present
          -- their canonical phrase spelling as authored names are presented.
          name = if "\"|" `T.isPrefixOf` raw || identifier then raw
                 else "\"|" <> T.concatMap (\c -> if c `elem` ("\\|" :: String) then T.pack ['\\', c] else T.singleton c) raw <> "|"
      in "ref " <> kind r <> " " <> str "unit" (field "target" r) <> "." <> name <> section

-- | Native conformance a host observed and passed in; reporting only.
nativeEvidenceText :: Value -> Text
nativeEvidenceText item =
  let summary = field "nativeEvidence" item
      rows = arr (field "observations" summary)
      present v = not (isNull v)
      attempt row = field "attempt" row
      firstPresent xs = case filter present xs of { v : _ -> jsString v; [] -> "native test failed" }
  in T.intercalate "\n" $
       ["Native conformance: " <> jsString (field "status" summary) <> "; search completeness: " <> jsString (field "searchCompleteness" summary)]
       ++ [ jsString (field "target" row) <> " (" <> jsString (field "root" row) <> "): " <> jsString (field "outcome" row) <> "; " <> jsString (field "freshness" row)
            <> (if present (attempt row) then "; seed " <> jsString (field "seed" (attempt row)) <> "; " <> jsString (field "at" (attempt row)) else "")
            <> "; " <> jsString (field "reason" row) | row <- rows ]
       ++ [ jsString (field "name" t) <> ": " <> firstPresent [field "reason" t, field "failure" t, field "message" t]
          | row <- rows, t <- arr (field "tests" (attempt row)), str "status" t == "failed" ]
       ++ [ "Native invocation output (scoped to that invocation):\n" <> output
          | row <- rows, let output = str "output" (field "invocation" (attempt row)), not (T.null output) ]

-- | dev: LawSpec's keyword notation.
devProposition :: Presentation -> Scope -> Value -> Text
devProposition p = go
  where
    ts = terms p Dev
    go scope a = case kind a of
      "equal" -> termText ts scope (field "left" a) <> " = " <> termText ts scope (field "right" a)
      "implies" -> "(" <> termText ts scope (field "guard" a) <> ") implies (" <> go scope (field "body" a) <> ")"
      "all" -> T.intercalate " and " ["(" <> go scope i <> ")" | i <- arr (field "items" a)]
      "not" -> case notShape a of
        Disjunction items -> T.intercalate " or " ["(" <> go scope i <> ")" | i <- items]
        Implication premise conclusion -> "(" <> go scope premise <> ") implies (" <> go scope conclusion <> ")"
        Negation body -> "not (" <> go scope body <> ")"
      k | k `elem` ["forall", "exists"] ->
        let universal = k == "forall"
            (binder, nested, restrictions) = quantifier p Dev scope a
            restricted = if null restrictions then "" else " where " <> T.intercalate " and " restrictions
        in (if universal then "for all" else "there exists") <> " (" <> binder <> restricted <> ") "
             <> (if universal then "=>" else "such that") <> "\n" <> go nested (field "body" a)
             <> "\nend " <> (if universal then "for all" else "exists")
      k -> "unsupported typed assertion " <> k

-- | The compiler's negation/conjunction representation also expresses
-- disjunction and implications with proposition premises.
data NotShape = Disjunction [Value] | Implication Value Value | Negation Value

notShape :: Value -> NotShape
notShape a =
  let body = field "body" a
      items = if kind body == "all" then arr (field "items" body) else []
  in case items of
       _ | length items > 1, all ((== "not") . kind) items -> Disjunction (map (field "body") items)
       [premise, negated] | kind negated == "not" -> Implication premise (field "body" negated)
       _ -> Negation body

-- | A quantifier's binder text, its scope and its restrictions.
quantifier :: Presentation -> View -> Scope -> Value -> (Text, Scope, [Text])
quantifier p view scope a =
  let binder = field "binder" a
      nested = M.insert (str "id" binder) (str "name" binder) scope
      ts = terms p view
      restrictions = map ((if view == Eng then termCondition else termText) ts nested) (arr (field "predicates" a))
      t = typeName p view (field "type" binder)
      shown = case view of
        Dev -> str "name" binder <> " of type " <> t
        Math -> str "name" binder <> " ∈ " <> t
        Eng -> str "name" binder <> " (" <> article t <> ")"
  in (shown, nested, restrictions)

-- Formula strength, weakest first.
mQuantifier, mImplies, mOr, mAnd, mAtom :: Int
mQuantifier = 0
mImplies = 1
mOr = 2
mAnd = 3
mAtom = 4

-- | math: one formula, bracketed wherever a reader could misgroup it.
mathProposition :: Presentation -> Scope -> Value -> (Text, Int)
mathProposition p = go
  where
    ts = terms p Math
    wrap minimum' (t, s) = if s < minimum' then "(" <> t <> ")" else t
    condition scope e = let (t, s) = termStrength ts scope e in if s < pComparison then "(" <> t <> ")" else t
    implication premise conclusion = (wrap mOr premise <> " ⇒ " <> wrap mOr conclusion, mImplies)
    go scope a = case kind a of
      "equal" -> (termText ts scope (field "left" a) <> " = " <> termText ts scope (field "right" a), mAtom)
      "implies" -> implication (condition scope (field "guard" a), mAtom) (go scope (field "body" a))
      "all" -> (T.intercalate " ∧ " [wrap mAnd (go scope i) | i <- arr (field "items" a)], mAnd)
      "not" -> case notShape a of
        Disjunction items -> (T.intercalate " ∨ " [wrap mOr (go scope i) | i <- items], mOr)
        Implication premise conclusion -> implication (go scope premise) (go scope conclusion)
        Negation body -> ("¬(" <> fst (go scope body) <> ")", mAtom)
      k | k `elem` ["forall", "exists"] ->
        let universal = k == "forall"
            (binder, nested, _) = quantifier p Math scope a
            restrictions = map (condition nested) (arr (field "predicates" a))
            body = go nested (field "body" a)
            restriction = T.intercalate " ∧ " restrictions
            formula | null restrictions = fst body
                    | universal = wrap mAnd (restriction, if length restrictions > 1 then mAnd else mAtom) <> " ⇒ " <> wrap mOr body
                    | otherwise = restriction <> " ∧ " <> wrap mAnd body
        in ((if universal then "∀ " else "∃ ") <> binder <> ". " <> formula, mQuantifier)
      k -> ("unsupported typed assertion " <> k, mAtom)

-- | eng: short lines, keywords first, one requirement per line. A modal
-- statement is an obligation ("must be"); inside a premise, a negation or an
-- existence it is a plain statement ("is").
engProposition :: Presentation -> Scope -> Bool -> Value -> [Text]
engProposition p = go
  where
    ts = terms p Eng
    indent = map ("  " <>)
    bullets = concatMap (\case (l : rest) -> ("  - " <> l) : map ("    " <>) rest; [] -> [])
    conditional conditions body = case (conditions, body) of
      ([c], [b]) -> ["If " <> c <> ", then " <> b]
      ([c], _) -> ("If " <> c <> ", then:") : indent body
      _ -> "If all of these are true:" : map ("  - " <>) conditions ++ case body of
        [b] -> ["then " <> b]
        _ -> "then:" : indent body
    go scope modal a = case kind a of
      "equal" -> [termText ts scope (field "left" a) <> (if modal then " must be " else " is ") <> termText ts scope (field "right" a)]
      "implies" -> conditional (termConditions ts scope (field "guard" a)) (go scope modal (field "body" a))
      "all" -> (if modal then "All of these must be true:" else "All of these are true:") : bullets [go scope modal i | i <- arr (field "items" a)]
      "not" -> case notShape a of
        Disjunction items -> (if modal then "At least one of these must be true:" else "At least one of these is true:")
          : bullets [go scope modal i | i <- items]
        Implication premise conclusion -> case go scope False premise of
          [c] -> conditional [c] (go scope modal conclusion)
          premiseLines -> "If this is true:" : indent premiseLines ++ ("then:" : indent (go scope modal conclusion))
        Negation body | kind body == "exists" -> existence scope modal True body
        Negation body -> (if modal then "This must not be true:" else "This is not true:") : indent (go scope False body)
      "forall" ->
        let (binder, nested, restrictions) = quantifier p Eng scope a
        in ("For every " <> binder <> whereText restrictions <> ":") : indent (go nested modal (field "body" a))
      "exists" -> existence scope modal False a
      k -> ["unsupported typed assertion " <> k]
    existence scope modal negated a =
      let (binder, nested, restrictions) = quantifier p Eng scope a
          opening | negated = if modal then "There must be no " else "There is no "
                  | otherwise = if modal then "There must be at least one " else "There is at least one "
      in (opening <> binder <> whereText restrictions <> " for which:") : indent (go nested False (field "body" a))
    whereText restrictions = if null restrictions then "" else " where " <> joinEnglish restrictions "and"
