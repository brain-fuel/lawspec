-- | Non-program targets consume checked Core. Configuration values are evaluated
-- by the existing total-definition interpreter; schemas never silently discard
-- a predicate they cannot express. These artifacts are not executed law tests.
-- Every artifact is laid out for a reader: YAML in block style, JSON indented
-- as json.tool writes it, HCL as tofu fmt writes it, and ANTLR and Make in
-- their conventional layout, with names taken from the source in spec order.
-- ref:DEC-artifact-targets ref:REQ-artifact-targets ref:DEC-readable-artifacts
module LawSpec.ArtifactEmit (emitArtifacts) where

import Control.Monad (unless, forM, foldM)
import Data.Char (chr, isAlphaNum, isAscii, isAsciiLower, isAsciiUpper, ord, toLower)
import Data.List (intercalate, isInfixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Normalize as Normalize
import Numeric (showHex)
import qualified Unicode.Char.General as Unicode
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.DefinitionContracts (validateEmissionDefinitions)
import LawSpec.Core.Types (TypeRegistry, makeRegistry, lookupData, constructorFieldsFor)
import qualified LawSpec.Core.Value as V
import LawSpec.Code.Literal (literalFor, printable)
import LawSpec.Naming (Casing(..), cased, claim, nameWords, scopeWith)
import LawSpec.RecordNames (recordDisplayNames)
import LawSpec.Scalar (Scalar(..), integerBounds, isInteger)
import LawSpec.SourceLink (generatedHeader, labelled, sourceLink, unitSourceFile)
import LawSpec.Testing (Plan(..), PlannedUnit(..))

-- | Layout is explicit because artifact files have no native source/test split.
emitArtifacts :: Bool -> String -> Maybe String -> Maybe String -> Plan -> Either [Diagnostic] [Artifact]
emitArtifacts _ target sourceDir testDir plan = do
  either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
    (validateEmissionDefinitions (planMachineBits plan) (planDataDeclarations plan) (map plannedUnit (plannedUnits plan)))
  either (Left . pure . problem) Right (render target sourceDir testDir plan)
  where problem message = Diagnostic "target-unsupported" (target ++ ": " ++ message) Nothing

render :: String -> Maybe String -> Maybe String -> Plan -> Either String [Artifact]
render target sourceDir testDir plan = do
  unless (testDir == Nothing) (Left "artifact targets have no testDir; they do not emit executable law tests")
  let directory = maybe "" (++ "/") sourceDir
  unless (maybe True safeDirectory sourceDir) (Left "sourceDir must be a relative directory without traversal")
  files <- case target of
    "make" -> pure [file "Makefile" (makePipeline (specSource plan))]
    "yaml" -> configuration False plan
    "hcl" -> configuration True plan
    "antlr4" -> grammarArtifacts plan
    _ -> Left ("unsupported artifact target: " ++ target)
  pure [a { artifactPath = directory ++ artifactPath a } | a <- files]
  where
    safeDirectory path = not (null path) && all (\p -> not (null p) && p /= "." && p /= ".." &&
      all (\c -> isAscii c && (isAlphaNum c || c `elem` ("_-" :: String))) p) (split '/' path)
    split c s = case break (== c) s of (a,[]) -> [a]; (a,_:b) -> a : split c b

file :: FilePath -> String -> Artifact
file path content = Artifact path content "generated" "source"

-- | The specification a project's artifacts come from, when it is one file.
specSource :: Plan -> Maybe FilePath
specSource plan = case nub (mapMaybe (unitSourceFile . plannedUnit) (plannedUnits plan)) of
  [one] -> Just one
  _ -> Nothing

------------------------------------------------------------------------------
-- JSON and YAML documents

-- | A JSON value whose objects keep the order they are written in, so output
-- reads in spec order. Numbers are integers: configuration has no others.
data Json = JObject [(String,Json)] | JArray [Json] | JString String | JInteger Integer | JBool Bool | JNull
  deriving (Eq, Show)

-- | JSON as Python's json.dumps(indent=2, ensure_ascii=False) and json.tool
-- write it: two-space indentation, one member per line, "key": value.
prettyJson :: Json -> String
prettyJson value = go 0 value ++ "\n"
  where
    go _ (JObject []) = "{}"
    go _ (JArray []) = "[]"
    go n (JObject members) = "{\n" ++ intercalate ",\n"
      [indent (n + 2) ++ jsonString k ++ ": " ++ go (n + 2) v | (k,v) <- members] ++ "\n" ++ indent n ++ "}"
    go n (JArray items) = "[\n" ++ intercalate ",\n" [indent (n + 2) ++ go (n + 2) v | v <- items] ++
      "\n" ++ indent n ++ "]"
    go _ scalar = jsonScalar scalar

jsonScalar :: Json -> String
jsonScalar value = case value of
  JString s -> jsonString s
  JInteger n -> show n
  JBool b -> if b then "true" else "false"
  JNull -> "null"
  _ -> ""

indent :: Int -> String
indent n = replicate n ' '

-- | json.dumps's escapes: the quote, the backslash, named control escapes and
-- \u00xx for other controls; everything else as it is.
jsonString :: String -> String
jsonString s = "\"" ++ concatMap escape s ++ "\""
  where
    escape c = case c of
      '"' -> "\\\""; '\\' -> "\\\\"; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"
      '\b' -> "\\b"; '\f' -> "\\f"
      _ | ord c < 0x20 -> "\\u" ++ hex4 (ord c)
        | otherwise -> [c]

hex4 :: Int -> String
hex4 n = let h = showHex n "" in replicate (4 - length h) '0' ++ h

-- | YAML 1.2 in block style: a mapping per line, nested collections indented
-- by two, sequence items indented inside their key (yamllint's defaults).
-- Text is always double-quoted, so no plain scalar is read as a number,
-- boolean or null by a YAML 1.1 reader. Long text wraps at spaces with an
-- escaped line break, which keeps every character.
yamlDocument :: Maybe FilePath -> [(String, Maybe String, Json)] -> String
yamlDocument source entries = unlines (("# " ++ generatedHeader source) : "---" :
  if null entries then ["{}"] else
  intercalate [""] [["# " ++ comment | Just comment <- [link]] ++ yamlMember 0 key value | (key,link,value) <- entries])

yamlMember :: Int -> String -> Json -> [String]
yamlMember n key value = case value of
  JObject (_:_) -> (indent n ++ yamlKey key ++ ":") : yamlBlock (n + 2) value
  JArray (_:_) -> (indent n ++ yamlKey key ++ ":") : yamlBlock (n + 2) value
  _ -> yamlScalarLine (indent n ++ yamlKey key ++ ": ") (n + 2) value

-- | A non-empty collection's lines at an indentation.
yamlBlock :: Int -> Json -> [String]
yamlBlock n (JObject members) = concat [yamlMember n k v | (k,v) <- members]
yamlBlock n (JArray items) = concatMap item items
  where
    item v = case v of
      JObject ((k,first):rest) -> case yamlMember (n + 2) k first of
        line : more -> (indent n ++ "- " ++ drop (n + 2) line) : more ++ concat [yamlMember (n + 2) k' v' | (k',v') <- rest]
        [] -> []
      JArray (_:_) -> case yamlBlock (n + 2) v of
        line : more -> (indent n ++ "- " ++ drop (n + 2) line) : more
        [] -> []
      _ -> yamlScalarLine (indent n ++ "- ") (n + 2) v
yamlBlock n scalar = yamlScalarLine (indent n) n scalar

-- | A scalar after its prefix; text too wide for yamllint's 80 columns is
-- continued at spaces on lines indented by the continuation.
yamlScalarLine :: String -> Int -> Json -> [String]
yamlScalarLine prefix continuation value = case value of
  JString s -> wrap prefix (yamlWords s)
  JObject [] -> [prefix ++ "{}"]
  JArray [] -> [prefix ++ "[]"]
  scalar -> [prefix ++ jsonScalar scalar]
  where
    -- Words end with their escaped space, so a break after one keeps it;
    -- each line leaves a column for its closing quote or backslash.
    wrap first ws = go (first ++ "\"") True ws
      where
        go line _ [] = [line ++ "\""]
        go line fresh (w:rest)
          | not fresh && length line + length w + 1 > 80 = (line ++ "\\") : go (indent continuation ++ w) False rest
          | otherwise = go (line ++ w) False rest

-- | Escaped text split after each single space that a non-space follows.
yamlWords :: String -> [String]
yamlWords s = case s of
  [] -> [""]
  _ -> pieces (concatMap escape s)
  where
    pieces text = case breakAfterSpace text of
      (w, []) -> [w]
      (w, rest) -> w : pieces rest
    breakAfterSpace text = go [] text
      where
        go acc (' ' : next : rest) | next /= ' ' && next /= '\\' = (reverse (' ' : acc), next : rest)
        go acc (c : rest) = go (c : acc) rest
        go acc [] = (reverse acc, [])
    escape c = case c of
      '"' -> "\\\""; '\\' -> "\\\\"; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"
      '\0' -> "\\0"; '\x85' -> "\\N"; '\x2028' -> "\\L"; '\x2029' -> "\\P"
      _ | ord c >= 0x20 && ord c < 0x7f -> [c]
        | printable c && yamlPrintable (ord c) -> [c]
        | ord c < 0x100 -> "\\x" ++ drop 2 (hex4 (ord c))
        | ord c < 0x10000 -> "\\u" ++ hex4 (ord c)
        | otherwise -> "\\U" ++ replicate (8 - length (showHex (ord c) "")) '0' ++ showHex (ord c) ""
    -- YAML's printable set (c-printable) excludes the byte-order mark too.
    yamlPrintable n = (n >= 0xA0 && n <= 0xD7FF) || (n >= 0xE000 && n <= 0xFFFD && n /= 0xFEFF) || n >= 0x10000

-- | A key written plainly when it is an identifier no YAML reader coerces;
-- otherwise double-quoted.
yamlKey :: String -> String
yamlKey key
  | plain = key
  | otherwise = "\"" ++ concat (yamlWords key) ++ "\""
  where
    plain = case key of
      c : rest -> (isAsciiLower c || isAsciiUpper c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x == '_')) rest &&
        map toLower key `notElem` words "y n yes no on off true false null"
      [] -> False

------------------------------------------------------------------------------
-- Names

-- | Readable, unique names for types, given in first-use order: a type's
-- own name in camelCase, its arguments after it (listText, boxUint8), a
-- structural record by its display name. Reserved words and collisions get
-- the claim suffix (_2, _3).
typeNames :: [C.DataDeclaration] -> [String] -> [C.Type] -> M.Map C.Type String
typeNames datas reserved types = fst (foldl step (M.empty, scopeWith reserved) types)
  where
    records = recordDisplayNames datas
    step (names, scope) ty
      | M.member ty names = (names, scope)
      | otherwise = let (chosen, scope') = claim scope (cased Camel (typeNameWords ty)) in (M.insert ty chosen names, scope')
    typeNameWords ty = case typeWordsOf ty of [] -> ["value"]; ws -> ws
    typeWordsOf ty = case ty of
      C.Constructor n args -> base n ++ concatMap argument args
      C.TypeVariable v -> nameWords (C.idText v)
      C.Arrow a b -> typeWordsOf a ++ ["to"] ++ typeWordsOf b
    argument (C.TypeArgument t) = typeWordsOf t
    argument (C.IndexArgument (C.Natural n)) = [show n]
    argument (C.IndexArgument (C.IndexVariable i)) = nameWords (C.idText i)
    base n = case M.lookup (C.Id n) records of
      Just display -> nameWords display
      Nothing | "::" `isInfixOf` n -> nameWords (lastSegment n)
              | otherwise -> [map toLower n]

lastSegment :: String -> String
lastSegment s = case breakOn s of
  (_, Just rest) -> lastSegment rest
  (whole, Nothing) -> whole
  where
    breakOn text = go [] text
    go acc (':' : ':' : rest) = (reverse acc, Just rest)
    go acc (c : rest) = go (c : acc) rest
    go acc [] = (reverse acc, Nothing)

-- | A type as LawSpec writes it, with its qualified name.
typeText :: C.Type -> String
typeText ty = case ty of
  C.Constructor n [] -> n
  C.Constructor n args -> unwords (n : map argument args)
  C.TypeVariable v -> C.idText v
  C.Arrow a b -> wrapped a ++ " -> " ++ typeText b
  where
    argument (C.TypeArgument t) = wrapped t
    argument (C.IndexArgument (C.Natural n)) = show n
    argument (C.IndexArgument (C.IndexVariable i)) = C.idText i
    wrapped t = case t of
      C.Constructor _ (_:_) -> "(" ++ typeText t ++ ")"
      C.Arrow _ _ -> "(" ++ typeText t ++ ")"
      _ -> typeText t

-- | The source link of a named data type.
dataLink :: TypeRegistry -> C.Type -> Maybe String
dataLink registry ty = case ty of
  C.Constructor n _ -> either (const Nothing) (sourceLink . C.dataOrigin) (lookupData registry (C.Id n))
  _ -> Nothing

-- | Types reachable from roots, in first-visit (depth-first) order.
reachable :: String -> (C.Type -> Either String [C.Type]) -> [C.Type] -> Either String [C.Type]
reachable what children roots = reverse <$> foldM (visit []) [] roots
  where
    visit path seen t
      | t `elem` seen = pure seen
      | length path > 128 = Left (what ++ " type expansion exceeds 128 levels; non-regular recursive types are unsupported")
      | otherwise = children t >>= foldM (visit (t : path)) (t : seen)

------------------------------------------------------------------------------
-- Configuration: YAML and HCL

-- Each exported configuration entry has a stable resolved declaration identity.
-- A Unit argument is the language's ordinary representation of a constant
-- function; functions needing application inputs are not configuration entries.
data Entry = Entry C.Declaration C.Type (Maybe V.Value)

configuration :: Bool -> Plan -> Either String [Artifact]
configuration hcl plan = do
  let units = map plannedUnit (plannedUnits plan)
      datas = planDataDeclarations plan
      program = C.Program (planMachineBits plan) datas units
      definitions = [(C.declarationId (C.definitionDeclaration d),d) | u <- units, d <- C.unitDefinitions u]
  invoke <- either (Left . show) Right (prepareDefinitions program)
  registry <- makeRegistry datas
  entries <- fmap concat $ forM units $ \u -> forM
    [(d,t,args) | d <- C.unitDeclarations u,
      Just (t,args) <- [constantType (C.declarationType d)]] $ \(d,t,args) -> do
      unless (not (C.declarationAsync d) && null (C.declarationUses d))
        (Left (C.idText (C.declarationId d) ++ ": configuration cannot invoke effects or async adapters"))
      value <- case lookup (C.declarationId d) definitions of
        Nothing -> pure Nothing
        Just _ -> Just <$> invoke (C.declarationId d) args
      pure (Entry d t value)
  -- Export monomorphic named types even when there is no value declaration.
  -- Generic declarations are instantiated through the entries that use them.
  let named = [C.Constructor (C.idText (C.dataId d)) [] | d <- datas,
        null (C.dataParameters d), C.dataStructural d == Nothing]
      roots = nub (named ++ [t | Entry _ t _ <- entries])
      typeOnly = [t | t <- named, t `notElem` [ty | Entry _ ty _ <- entries]]
      bits = planMachineBits plan
      source = specSource plan
  ordered <- reachable "configuration" (fmap snd . shape registry bits (const JNull)) roots
  let names = typeNames datas [] ordered
      key t = M.findWithDefault "value" t names
      ref t = JObject [("$ref", JString ("#/$defs/" ++ key t))]
      -- Variable names: the declaration's source name in snake case, and a
      -- type-only variable as type_<type>; Terraform's reserved names and
      -- collisions take the claim suffix.
      (variableNames, typeVariableNames) =
        let reserved = words "source version providers count for_each lifecycle depends_on locals"
            (values, scope) = claimEach (scopeWith reserved) [snake (C.declarationName d) | Entry d _ _ <- entries]
            (types, _) = claimEach scope ["type_" ++ snake (key t) | t <- typeOnly]
        in (values, types)
      entryName i d = if hcl then variableNames !! i else C.idText (C.declarationId d)
      numbered = zip [0 :: Int ..] entries
  defs <- forM ordered $ \t -> (,) (key t) . fst <$> shape registry bits ref t
  values <- forM [(i,d,v) | (i, Entry d _ (Just v)) <- numbered] $ \(i,d,v) ->
    (,) (entryName i d) <$> encodeValue registry v
  let properties = [(entryName i d, ref t) | (i, Entry d t _) <- numbered]
      required = [JString (entryName i d) | (i, Entry d _ _) <- numbered]
      root = JObject [("$schema", JString "https://json-schema.org/draft/2020-12/schema"),
        ("type", JString "object"), ("properties", JObject properties), ("required", JArray required),
        ("additionalProperties", JBool False), ("$defs", JObject defs)]
      typeVariables = zip typeVariableNames typeOnly
      receipt = JObject
        [ ("target", JString (if hcl then "hcl" else "yaml"))
        , ("kind", JString "configuration"), ("lawsExecuted", JBool False)
        , ("configurationComplete", JBool (length values == length entries && (not hcl || null typeOnly)))
        , ("machineBits", JInteger (toInteger bits))
        , ("entries", JArray [JObject [("declaration", JString (C.idText (C.declarationId d))),
            ("name", JString (entryName i d)), ("type", JString (typeText t)),
            ("schema", JString (key t)), ("hasValue", JBool (maybe False (const True) v))] | (i, Entry d t v) <- numbered])
        , ("missingValues", JArray [JString (C.idText (C.declarationId d)) | Entry d _ Nothing <- entries])
        , ("missingTypeValues", JArray [JString name | hcl, (name,_) <- typeVariables])
        , ("typeVariables", JArray [JObject [("name", JString name), ("type", JString (typeText t)),
            ("schema", JString (key t))] | hcl, (name,t) <- typeVariables])
        , ("types", JObject [(key t, JString (typeText t)) | t <- roots]) ]
      link d = fmap (labelled (C.declarationName d) . Just) (sourceLink (C.declarationOrigin d))
  if not hcl then pure ([file "configuration.schema.json" (prettyJson root),
      file "lawspec-artifacts.json" (prettyJson receipt)] ++
      [file "configuration.yaml" (yamlDocument source
        [(entryName i d, link d, value) | ((i, Entry d _ _), (_, value)) <- zip [(i,e) | (i,e@(Entry _ _ (Just _))) <- numbered] values])
      | length values == length entries])
    else do
      mapM_ (terraformValue . snd) values
      variables <- forM numbered $ \(i, Entry d t _) ->
        terraformVariable registry bits (entryName i d) (C.declarationName d) (link d) t
      -- Type-only declarations are real variables too; their names are separate
      -- from the declaration entries, so values and reusable types cannot clash.
      typed <- forM typeVariables $ \(name,t) ->
        terraformVariable registry bits name (lastSegment (typeText t))
          (fmap (labelled (typeText t) . Just) (dataLink registry t)) t
      pure [file "variables.tf" (unlines (("# " ++ generatedHeader source) : concatMap ("" :) (variables ++ typed))),
        file "configuration.tfvars.json" (prettyJson (JObject values)),
        file "lawspec-artifacts.json" (prettyJson receipt)]
  where
    constantType (C.Arrow (C.Constructor "Unit" []) result) = Just (result,[V.ScalarValue (SAbsent "Unit")])
    constantType (C.Arrow _ _) = Nothing
    constantType ty = Just (ty,[])
    snake = cased Snake . (\ws -> if null ws then ["value"] else ws) . nameWords
    claimEach scope = foldl (\(done, s) n -> let (c, s') = claim s n in (done ++ [c], s')) ([], scope)

-- Shape compilation uses the same type instantiation as native emitters.
-- JSON Schema refs permit recursive products; Terraform's finite object types
-- cannot represent recursion and are rejected explicitly below.
shape :: TypeRegistry -> Int -> (C.Type -> Json) -> C.Type -> Either String (Json,[C.Type])
shape registry bits ref ty@(C.Constructor name arguments)
  | isInteger name && null arguments = pure (integerSchema bits name,[])
  | name == "Bool" && null arguments = pure (JObject [("type", JString "boolean")],[])
  | name == "Text" && null arguments = pure (JObject [("type", JString "string")],[])
  | name `elem` ["Unit","Null","Undefined"] && null arguments = pure (JObject [("type", JString "null")],[])
  | name == "List", [C.TypeArgument element] <- arguments =
      pure (JObject [("type", JString "array"), ("items", ref element)],[element])
  | otherwise = do
      declaration <- lookupData registry (C.Id name)
      unless (C.dataIndex declaration == Nothing && not (C.dataHandle declaration))
        (Left ("indexed or opaque configuration type: " ++ name))
      constructors <- forM (C.dataConstructors declaration) $ \constructor -> do
        unless (null (C.constructorExistentials constructor) && null (C.constructorEquations constructor))
          (Left ("existential or refined configuration constructor: " ++ C.constructorName constructor))
        fields <- constructorFieldsFor registry ty (C.constructorId constructor)
        restrictions <- mapM (schemaRestriction fields) (C.constructorPredicates constructor)
        let body = objectSchema [(C.binderName b,ref (C.binderType b)) | b <- fields]
            restricted = if null restrictions then body else JObject [("allOf", JArray (body : restrictions))]
            tagged = objectSchema [("tag",JObject [("const", JString (C.idText (C.constructorId constructor)))]),("fields",restricted)]
        pure (if length (C.dataConstructors declaration) == 1 then restricted else tagged, map C.binderType fields)
      let body = case constructors of
            [] -> JBool False
            [(single,_)] -> single
            _ -> JObject [("oneOf", JArray (map fst constructors))]
      pure (body,nub (concatMap snd constructors))
shape _ _ _ ty = Left ("configuration requires concrete data, got " ++ show ty)

objectSchema :: [(String,Json)] -> Json
objectSchema fields = JObject [("type", JString "object"), ("properties", JObject fields),
  ("required", JArray (map (JString . fst) fields)), ("additionalProperties", JBool False)]

integerSchema :: Int -> String -> Json
integerSchema bits name = JObject $ [("type", JString "integer")] ++
  case integerBounds bits name of
    Just (lo,hi) -> [("minimum", JInteger lo),("maximum", JInteger hi)]
    Nothing | name == "BigUInt" -> [("minimum", JInteger 0)]
    _ -> []

-- JSON Schema has numeric bounds but no general cross-field arithmetic.
-- Refuse any predicate outside that vocabulary instead of weakening the type.
schemaRestriction :: [C.Binder] -> C.Expr -> Either String Json
schemaRestriction fields expression = case C.expressionNode expression of
  C.ShortCircuit C.And a b -> (\xs -> JObject [("allOf", JArray xs)]) <$> mapM (schemaRestriction fields) [a,b]
  C.Binary op _ a b -> case (C.expressionNode a,C.expressionNode b) of
    (C.Local identity,C.Constant (SInteger _ value)) -> restriction identity op value
    (C.Constant (SInteger _ value),C.Local identity) -> restriction identity (reverseComparison op) value
    _ -> unsupported
  _ -> unsupported
  where
    unsupported = Left ("configuration schema cannot express constructor predicate: " ++ show expression)
    restriction identity op value = do
      field <- maybe (Left "schema predicate refers to a non-field binder") Right
        (lookup identity [(C.binderId b,C.binderName b) | b <- fields])
      keyword <- case op of
        C.Greater -> pure "exclusiveMinimum"; C.GreaterEqual -> pure "minimum"
        C.Less -> pure "exclusiveMaximum"; C.LessEqual -> pure "maximum"
        C.Equal -> pure "const"
        _ -> Left "configuration schema comparison is unsupported"
      pure (JObject [("properties", JObject [(field, JObject [(keyword, JInteger value)])])])

reverseComparison :: C.BinaryOp -> C.BinaryOp
reverseComparison op = case op of
  C.Less -> C.Greater; C.LessEqual -> C.GreaterEqual
  C.Greater -> C.Less; C.GreaterEqual -> C.LessEqual; other -> other

encodeValue :: TypeRegistry -> V.Value -> Either String Json
encodeValue registry value = case value of
  V.ScalarValue (SInteger _ n) -> pure (JInteger n)
  V.ScalarValue (SBool b) -> pure (JBool b)
  V.ScalarValue (SSequence "Text" xs) -> pure (JString (map chr xs))
  V.ScalarValue (SAbsent _) -> pure JNull
  V.DataValue (C.Constructor "List" _) _ _ -> V.listItems value >>= fmap JArray . mapM (encodeValue registry)
  V.DataValue ty@(C.Constructor name _) tag payload -> do
    declaration <- lookupData registry (C.Id name)
    fields <- constructorFieldsFor registry ty tag
    unless (length fields == length payload) (Left "configuration constructor arity mismatch")
    body <- JObject <$> sequence [(,) (C.binderName binder) <$> encodeValue registry v | (binder,v) <- zip fields payload]
    pure $ if length (C.dataConstructors declaration) == 1 then body else
      JObject [("tag", JString (C.idText tag)), ("fields", body)]
  _ -> Left ("configuration scalar encoding is unsupported: " ++ show value)

------------------------------------------------------------------------------
-- HCL (OpenTofu and Terraform variables)

-- | One variable block as tofu fmt lays it out: its source link, its type
-- (an object type one attribute per line), nullable = false, and one
-- validation block per restriction, each with its own message.
terraformVariable :: TypeRegistry -> Int -> String -> String -> Maybe String -> C.Type -> Either String [String]
terraformVariable registry bits name label link ty = do
  typeLines <- terraformType registry [] ty
  checks <- terraformChecks registry bits [] (Path ("var." ++ name) label False) ty
  let typeAttribute = case typeLines of
        [single] -> ["  type     = " ++ single]
        -- tofu fmt aligns = only across single-line attributes.
        first : rest -> ("  type = " ++ first) : map ("  " ++) rest
        [] -> []
  pure $ ["# " ++ comment | Just comment <- [link]] ++
    ["variable " ++ jsonString name ++ " {"] ++ typeAttribute ++ ["  nullable = false"] ++
    concat [ ["", "  validation {", "    condition     = " ++ condition,
              "    error_message = " ++ literalFor "hcl" message, "  }"] | (condition, message) <- checks ] ++
    ["}"]

-- | A type constraint; an object type is written one attribute per line.
terraformType :: TypeRegistry -> [C.Type] -> C.Type -> Either String [String]
terraformType registry seen ty@(C.Constructor name arguments)
  | isInteger name && null arguments = case integerBounds 64 name of
      Just _ -> pure ["number"]
      Nothing -> Left ("Terraform's finite numeric precision cannot represent the complete " ++ name ++ " domain")
  | name == "Bool" && null arguments = pure ["bool"]
  | name == "Text" && null arguments = pure ["string"]
  | name == "List", [C.TypeArgument element] <- arguments = do
      inner <- terraformType registry seen element
      pure (wrapLines "list(" ")" inner)
  | ty `elem` seen = Left ("Terraform cannot represent a recursive type: " ++ show ty)
  | otherwise = do
      declaration <- lookupData registry (C.Id name)
      constructor <- case C.dataConstructors declaration of
        [c] -> pure c
        _ -> Left ("Terraform has no tagged-union type: " ++ name)
      fields <- constructorFieldsFor registry ty (C.constructorId constructor)
      rendered <- forM fields $ \b -> do
        t <- terraformType registry (ty:seen) (C.binderType b)
        let name' = C.binderName b
        let validName = case name' of
              first:_ -> not (first `elem` ['0'..'9']) &&
                all (\c -> isAscii c && (isAlphaNum c || c == '_')) name'
              [] -> False
        unless validName
          (Left ("Terraform object type requires an attribute identifier: " ++ name'))
        pure (name', t)
      let width = maximum (0 : map (length . fst) rendered)
          attribute (n, t) = case t of
            first : rest -> ("  " ++ n ++ replicate (width - length n) ' ' ++ " = " ++ first) : map ("  " ++) rest
            [] -> []
      pure (if null rendered then ["object({})"] else "object({" : concatMap attribute rendered ++ ["})"])
terraformType _ _ ty = Left ("Terraform type must be concrete: " ++ show ty)

-- | Lines wrapped in an opening and a closing text.
wrapLines :: String -> String -> [String] -> [String]
wrapLines open close inner = case inner of
  [single] -> [open ++ single ++ close]
  first : rest -> (open ++ first) : init rest ++ [last rest ++ close]
  [] -> [open ++ close]

-- | A value's place: its HCL expression, how a message names it, and
-- whether it may be null (an attribute or element; the variable is not).
data Path = Path String String Bool

-- | One (condition, message) per restriction: presence of nested values,
-- integer domains and constructor predicates. A list's checks apply to each
-- item. Conditions that read a possibly null value are wrapped in try.
terraformChecks :: TypeRegistry -> Int -> [C.Type] -> Path -> C.Type -> Either String [(String, String)]
terraformChecks registry bits seen (Path expression label nullable) ty@(C.Constructor name arguments)
  | isInteger name && null arguments = pure (present ++
      [(guarded (case integerBounds bits name of
          Just (lo,hi) -> conjunction ["floor(" ++ expression ++ ") == " ++ expression,
            expression ++ " >= " ++ show lo, expression ++ " <= " ++ show hi]
          Nothing | name == "BigUInt" -> conjunction ["floor(" ++ expression ++ ") == " ++ expression, expression ++ " >= 0"]
          _ -> "floor(" ++ expression ++ ") == " ++ expression),
        subject ++ " must be " ++ integerDomain name ++ ".")])
  | name `elem` ["Text","Bool"] && null arguments = pure present
  | name == "List", [C.TypeArgument element] <- arguments = do
      let depth = length [() | C.Constructor "List" _ <- seen]
          item = if depth == 0 then "item" else "item_" ++ show (depth + 1)
      inner <- terraformChecks registry bits (ty:seen) (Path item (label ++ "[*]") True) element
      pure (present ++ [ (guarded ("alltrue([for " ++ item ++ " in " ++ expression ++ " : " ++ unwrap condition ++ "])"), message)
                       | (condition, message) <- inner ])
  | ty `elem` seen = Left "recursive Terraform validation is unsupported"
  | otherwise = do
      declaration <- lookupData registry (C.Id name)
      constructor <- case C.dataConstructors declaration of [c] -> pure c; _ -> Left "Terraform unions are unsupported"
      fields <- constructorFieldsFor registry ty (C.constructorId constructor)
      let fieldPath b = Path (expression ++ "." ++ C.binderName b) (label ++ "." ++ C.binderName b) True
      checks <- concat <$> forM fields (\b -> terraformChecks registry bits (ty:seen) (fieldPath b) (C.binderType b))
      predicates <- forM (C.constructorPredicates constructor) $ \p -> do
        condition <- terraformPredicate [(C.binderId b, (let Path e _ _ = fieldPath b in e)) | b <- fields] p
        shown <- terraformPredicate [(C.binderId b, C.binderName b) | b <- fields] p
        pure (guarded (unparen condition), subject ++ " must satisfy the restriction of " ++
          lastSegment name ++ ": " ++ unparen shown ++ ".")
      pure (present ++ checks ++ predicates)
  where
    present = [(expression ++ " != null", subject ++ " must be set.") | nullable]
    -- An item of a list is every item; its fields are every item's fields.
    subject = case reverse label of
      ']' : '*' : '[' : rest -> "Every item of " ++ reverse rest
      _ | "[*]" `isInfixOf` label -> "Every " ++ label
        | otherwise -> "The value of " ++ label
    guarded condition = if nullable then "try(" ++ condition ++ ", false)" else condition
    -- An item's own try is dropped inside alltrue's, which already guards it.
    unwrap condition = maybe condition id (stripTry condition)
    stripTry c = case splitAt 4 c of
      ("try(", rest) | drop (length rest - 8) rest == ", false)" -> Just (take (length rest - 8) rest)
      _ -> Nothing
    conjunction = intercalate " && "
terraformChecks _ _ _ _ ty = Left ("unsupported Terraform validation: " ++ show ty)

-- | How a message names an integer type's values.
integerDomain :: String -> String
integerDomain name = case integerBounds 64 name of
  Just (lo,hi) -> "a whole number from " ++ show lo ++ " to " ++ show hi ++ " (" ++ name ++ ")"
  Nothing | name == "BigUInt" -> "a whole number of at least 0 (" ++ name ++ ")"
  _ -> "a whole number (" ++ name ++ ")"

unparen :: String -> String
unparen s = case s of
  '(' : rest | not (null rest) && last rest == ')' && balanced (init rest) -> init rest
  _ -> s
  where
    balanced = go (0 :: Int)
      where
        go n [] = n == 0
        go n (c:cs)
          | c == '(' = go (n + 1) cs
          | c == ')' = n > 0 && go (n - 1) cs
          | otherwise = go n cs

-- cty normalizes its strings. Accept only stable, already-normalized literal
-- values, using an established normalizer and its pinned Unicode database.
-- Newer unassigned characters are unsupported rather than guessed unchanged.
terraformValue :: Json -> Either String ()
terraformValue (JString value) = let text = T.pack value in unless
  (T.all ((/= Unicode.NotAssigned) . Unicode.generalCategory) text && Normalize.normalize Normalize.NFC text == text)
  (Left "Terraform normalizes Text; literal values must already be NFC and assigned in Unicode 15.1")
terraformValue (JArray values) = mapM_ terraformValue values
terraformValue (JObject values) = mapM_ (terraformValue . snd) values
terraformValue _ = pure ()

terraformPredicate :: [(C.Id,String)] -> C.Expr -> Either String String
terraformPredicate environment expression = case C.expressionNode expression of
  C.Local name -> maybe (Left "unknown Terraform predicate field") Right (lookup name environment)
  C.Constant (SInteger _ n) -> pure (show n)
  C.Constant (SBool b) -> pure (if b then "true" else "false")
  C.Binary op _ a b -> do
    operator <- maybe (Left "unsupported Terraform predicate operator") Right (lookup op
      [(C.Equal,"=="),(C.NotEqual,"!="),(C.Less,"<"),(C.LessEqual,"<="),(C.Greater,">"),(C.GreaterEqual,">=")])
    x <- go a; y <- go b; pure ("(" ++ x ++ " " ++ operator ++ " " ++ y ++ ")")
  C.ShortCircuit op a b -> do
    x <- go a; y <- go b; pure ("(" ++ x ++ (if op == C.And then " && " else " || ") ++ y ++ ")")
  _ -> Left "Terraform constructor predicate is unsupported"
  where go = terraformPredicate environment

------------------------------------------------------------------------------
-- Make

-- Phony stages deliberately invoke the user's installed CLI. They neither
-- install tools nor claim execution merely because the file was generated.
makePipeline :: Maybe FilePath -> String
makePipeline source = unlines
  [ "# " ++ generatedHeader source
  , "# Run from the directory that holds lawspec.json."
  , ""
  , "LAWSPEC ?= lawspec"
  , ""
  , ".PHONY: all check generate test verify"
  , ""
  , "all: verify"
  , ""
  , "check:"
  , "\t$(LAWSPEC) check"
  , ""
  , "generate: check"
  , "\t$(LAWSPEC) generate"
  , ""
  , "test: generate"
  , "\t$(LAWSPEC) test"
  , ""
  , "verify: test"
  ]

------------------------------------------------------------------------------
-- ANTLR

-- | ANTLR owns parsing. No embedded target-language actions or custom parser
-- engine is generated. Constructor application text is unambiguous and keeps
-- qualified constructor identities, including equal-shaped sum alternatives.
-- Rules are named after their types, in first-use order, and laid out as the
-- ANTLR grammars collection lays them out.
grammarArtifacts :: Plan -> Either String [Artifact]
grammarArtifacts plan = do
  registry <- makeRegistry (planDataDeclarations plan)
  let roots = nub ([C.Constructor (C.idText (C.dataId d)) [] | d <- planDataDeclarations plan,
        null (C.dataParameters d), C.dataStructural d == Nothing] ++
        [ty | u <- plannedUnits plan, d <- C.unitDeclarations (plannedUnit u),
          let (arguments,result) = C.functionType (C.declarationType d),
          ty <- arguments ++ [result], concrete ty])
      concrete (C.TypeVariable _) = False
      concrete (C.Arrow _ _) = False
      concrete (C.Constructor _ args) = all (\a -> case a of C.TypeArgument t -> concrete t; C.IndexArgument (C.Natural _) -> True; _ -> False) args
      bits = planMachineBits plan
  unless (not (null roots)) (Left "ANTLR requires at least one concrete data type")
  ordered <- reachable "ANTLR" (fmap snd . grammarRule registry (const "")) roots
  let names = typeNames (planDataDeclarations plan) antlrReserved ordered
      key t = M.findWithDefault "value" t names
      entryRules = fst (foldl (\(done, scope) t -> let (c, s) = claim scope (key t ++ "Document") in (done ++ [(t, c)], s))
        ([], scopeWith (antlrReserved ++ M.elems names)) roots)
      entryRule t = maybe (key t ++ "Document") id (lookup t entryRules)
      ref t = JObject [("$ref", JString ("#/$defs/" ++ key t))]
  _ <- reachable "ANTLR companion schema" (fmap snd . shape registry bits (const JNull)) roots
  rules <- forM ordered $ \t -> (,) t . fst <$> grammarRule registry key t
  definitions <- forM ordered $ \t -> (,) (key t) . fst <$> shape registry bits ref t
  let rule name comment alternatives = ["// " ++ c | Just c <- [comment]] ++ [name] ++
        zipWith (\i a -> "    " ++ (if i == (0 :: Int) then ": " else "| ") ++ a) [0 ..] alternatives ++ ["    ;"]
      grammar = unlines $ intercalate [""] $
        [ ["// " ++ generatedHeader (specSource plan),
           "// The grammar checks data syntax only. Check numeric ranges and field",
           "// restrictions with data.schema.json after decoding.",
           "grammar LawSpecData;"]
        , rule "document" Nothing ["(" ++ intercalate " | " (map key roots) ++ ") EOF"] ] ++
        [ rule (entryRule ty) Nothing [key ty ++ " EOF"] | ty <- roots ] ++
        [ rule (key t) (fmap (labelled (typeText t) . Just) (dataLink registry t)) alternatives | (t, alternatives) <- rules ] ++
        [ rule "INTEGER" Nothing ["'-'? ('0' | [1-9] [0-9]*)"]
        , rule "TEXT" Nothing ["'\"' (ESC | ~[\"\\\\\\u0000-\\u001F])* '\"'"]
        , rule "fragment ESC" Nothing ["'\\\\' ([\"\\\\/bfnrt] | 'u' HEX HEX HEX HEX)"]
        , rule "fragment HEX" Nothing ["[0-9a-fA-F]"]
        , rule "WS" Nothing ["[ \\t\\r\\n]+ -> skip"] ]
  pure [file "LawSpecData.g4" grammar,
    file "data.schema.json" (prettyJson (JObject [("$schema", JString "https://json-schema.org/draft/2020-12/schema"),
      ("anyOf", JArray (map ref roots)), ("$defs", JObject definitions)])),
    file "lawspec-artifacts.json" (prettyJson (JObject [("target", JString "antlr4"),
      ("kind", JString "syntax"), ("lawsExecuted", JBool False),
      ("semanticValidation", JString "required-after-decoding"),
      ("entryPoints", JObject [(key ty, JObject [("rule", JString (entryRule ty)),
        ("schema", JString ("#/$defs/" ++ key ty))]) | ty <- roots]),
      ("types", JObject [(key ty, JString (typeText ty)) | ty <- roots])]))]

-- | Names a rule cannot take: ANTLR's keywords, the grammar's own rules, and
-- Java's keywords and the parser's methods, as the generated parser has a
-- method per rule.
antlrReserved :: [String]
antlrReserved = words
  "document grammar fragment lexer parser import returns locals throws catch finally mode options tokens channels \
  \abstract assert boolean break byte case char class const continue default do double else enum extends final \
  \float for goto if implements instanceof int interface long native new package private protected public return \
  \short static strictfp super switch synchronized this throw transient try void volatile while true false null \
  \var record yield sealed permits match consume reset error action sempred precpred enterRule exitRule"

-- | A type's alternatives, referring to other types by name.
grammarRule :: TypeRegistry -> (C.Type -> String) -> C.Type -> Either String ([String],[C.Type])
grammarRule registry name ty@(C.Constructor typeName args)
  | isInteger typeName && null args = pure (["INTEGER"],[])
  | typeName == "Bool" && null args = pure (["'true'", "'false'"],[])
  | typeName == "Text" && null args = pure (["TEXT"],[])
  | typeName `elem` ["Unit","Null","Undefined"] && null args = pure (["'" ++ typeName ++ "'"],[])
  | typeName == "List", [C.TypeArgument t] <- args =
      pure (["'[' (" ++ name t ++ " (',' " ++ name t ++ ")*)? ']'"],[t])
  | otherwise = do
      declaration <- lookupData registry (C.Id typeName)
      unless (not (C.dataHandle declaration) && C.dataIndex declaration == Nothing)
        (Left ("ANTLR indexed/opaque data syntax is unsupported: " ++ typeName))
      choices <- forM (C.dataConstructors declaration) $ \c -> do
        unless (null (C.constructorExistentials c) && null (C.constructorEquations c))
          (Left "ANTLR existential/refined data syntax is unsupported")
        fields <- constructorFieldsFor registry ty (C.constructorId c)
        let types = map C.binderType fields
        pure (antlrLiteral (C.idText (C.constructorId c)) ++
          (if null fields then "" else " '(' " ++ intercalate " ',' " (map name types) ++ " ')'"),types)
      unless (not (null choices)) (Left "ANTLR empty data types have no textual inhabitants")
      pure (map fst choices,nub (concatMap snd choices))
grammarRule _ _ ty = Left ("ANTLR requires a concrete data type: " ++ show ty)

antlrLiteral :: String -> String
antlrLiteral text = "'" ++ concatMap escape text ++ "'"
  where
    escape '\'' = "\\'"
    escape '\\' = "\\\\"
    escape c = [c]
