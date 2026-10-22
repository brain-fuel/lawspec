-- | Non-program targets consume checked Core. Configuration values are evaluated
-- by the existing total-definition interpreter; schemas never silently discard
-- a predicate they cannot express. These artifacts are not executed law tests.
-- ref:DEC-artifact-targets ref:REQ-artifact-targets
module LawSpec.ArtifactEmit (emitArtifacts) where

import Control.Monad (unless, forM)
import Data.Aeson (Value(..), object, (.=), encode, toJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as B
import Data.Char (chr, isAlphaNum, isAscii, toLower)
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.Normalize as Normalize
import qualified Unicode.Char.General as Unicode
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.DefinitionContracts (validateEmissionDefinitions)
import LawSpec.Core.Types (TypeRegistry, makeRegistry, lookupData, constructorFieldsFor)
import qualified LawSpec.Core.Value as V
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Scalar (Scalar(..), integerBounds, isInteger)
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
    "make" -> pure [file "Makefile" makePipeline]
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

json :: Value -> String
json = T.unpack . TextEncoding.decodeUtf8 . B.toStrict . encode

-- Each exported configuration entry has a stable resolved declaration identity.
-- A Unit argument is the language's ordinary representation of a constant
-- function; functions needing application inputs are not configuration entries.
data Entry = Entry C.Declaration C.Type (Maybe V.Value)

configuration :: Bool -> Plan -> Either String [Artifact]
configuration hcl plan = do
  let units = map plannedUnit (plannedUnits plan)
      program = C.Program (planMachineBits plan) (planDataDeclarations plan) units
      definitions = [(C.declarationId (C.definitionDeclaration d),d) | u <- units, d <- C.unitDefinitions u]
  invoke <- either (Left . show) Right (prepareDefinitions program)
  registry <- makeRegistry (planDataDeclarations plan)
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
  let named = [C.Constructor (C.idText (C.dataId d)) [] | d <- planDataDeclarations plan,
        null (C.dataParameters d), C.dataStructural d == Nothing]
      roots = nub (named ++ [t | Entry _ t _ <- entries])
      typeOnly = [t | t <- named, t `notElem` [ty | Entry _ ty _ <- entries]]
      bits = planMachineBits plan
      key = typeKey
      ref t = object ["$ref" .= ("#/$defs/" ++ key t)]
      schema seen t | t `elem` seen = pure []
      schema seen _ | length seen > 128 = Left "configuration type expansion exceeds 128 levels; non-regular recursive types are unsupported"
      schema seen t = do
        (body,children) <- shape registry bits ref t
        rest <- fmap concat (mapM (schema (t:seen)) children)
        pure ((key t,body):rest)
  definitions' <- M.toList . M.fromList . concat <$> mapM (schema []) roots
  values <- forM [(d,t,v) | Entry d t (Just v) <- entries] $ \(d,_,v) ->
    (,) (entryName hcl d) <$> encodeValue registry v
  let properties = [(entryName hcl d, ref t) | Entry d t _ <- entries]
      required = [entryName hcl d | Entry d _ _ <- entries]
      root = object ["$schema" .= ("https://json-schema.org/draft/2020-12/schema" :: String),
        "type" .= ("object" :: String), "$defs" .= dict definitions',
        "properties" .= dict properties, "required" .= required, "additionalProperties" .= False]
      receipt = object ["target" .= (if hcl then "hcl" else "yaml" :: String),
        "kind" .= ("configuration" :: String), "lawsExecuted" .= False,
        "configurationComplete" .= (length values == length entries && (not hcl || null typeOnly)),
        "missingValues" .= [C.idText (C.declarationId d) | Entry d _ Nothing <- entries],
        "missingTypeValues" .= ["type_" ++ typeKey t | hcl, t <- typeOnly],
        "types" .= dict [(typeKey t,String (T.pack (show t))) | t <- roots],
        "typeVariables" .= [object ["name" .= ("type_" ++ typeKey t), "type" .= show t,
          "schema" .= typeKey t] | hcl, t <- typeOnly],
        "machineBits" .= bits, "entries" .=
          [object ["declaration" .= C.idText (C.declarationId d), "name" .= entryName hcl d,
            "type" .= show t, "hasValue" .= maybe False (const True) v] | Entry d t v <- entries]]
  if not hcl then pure ([file "configuration.schema.json" (json root ++ "\n"),
      -- JSON is the YAML 1.2 subset, avoiding implicit scalar coercions and
      -- loss of integer precision in a host YAML emitter.
      file "lawspec-artifacts.json" (json receipt ++ "\n")] ++
      [file "configuration.yaml" (json (dict values) ++ "\n") | length values == length entries])
    else do
      mapM_ (terraformValue . snd) values
      variables <- forM entries $ \(Entry d t _) -> do
        ty <- terraformType registry [] t
        condition <- terraformChecks registry bits [] ("var." ++ entryName True d) t
        pure $ unlines ["variable " ++ json (String (T.pack (entryName True d))) ++ " {",
          "  type = " ++ ty, "  nullable = false"] ++
          (if condition == "true" then "" else unlines ["  validation {", "    condition = " ++ condition,
            "    error_message = \"Value violates the LawSpec type or its field restrictions.\"", "  }"]) ++ "}\n"
      -- Type-only declarations are real variables too; their names are separate
      -- from the declaration entries, so values and reusable types cannot clash.
      typeVariables <- forM typeOnly $ \t -> do
        ty <- terraformType registry [] t
        let name = "type_" ++ typeKey t
        condition <- terraformChecks registry bits [] ("var." ++ name) t
        pure $ unlines ["variable " ++ show name ++ " {", "  type = " ++ ty, "  nullable = false"] ++
          (if condition == "true" then "" else unlines ["  validation {", "    condition = " ++ condition,
            "    error_message = \"Value violates the LawSpec type or its field restrictions.\"", "  }"]) ++ "}\n"
      pure [file "variables.tf" (concat (variables ++ typeVariables)),
        file "configuration.tfvars.json" (json (dict values) ++ "\n"),
        file "lawspec-artifacts.json" (json receipt ++ "\n")]
  where
    constantType (C.Arrow (C.Constructor "Unit" []) result) = Just (result,[V.ScalarValue (SAbsent "Unit")])
    constantType (C.Arrow _ _) = Nothing
    constantType ty = Just (ty,[])

dict :: [(String,Value)] -> Value
dict = Object . KM.fromList . map (\(k,v) -> (K.fromString k,v))

typeKey :: C.Type -> String
typeKey ty = "t_" ++ take 24 (digestHex (digestString (show ty)))

entryName :: Bool -> C.Declaration -> String
entryName False declaration = C.idText (C.declarationId declaration)
entryName True declaration = "value_" ++ map (\c -> if isAscii c && isAlphaNum c then toLower c else '_') identity ++
  "_" ++ take 12 (digestHex (digestString identity))
  where identity = C.idText (C.declarationId declaration)

-- Shape compilation uses the same type instantiation as native emitters.
-- JSON Schema refs permit recursive products; Terraform's finite object types
-- cannot represent recursion and are rejected explicitly below.
shape :: TypeRegistry -> Int -> (C.Type -> Value) -> C.Type -> Either String (Value,[C.Type])
shape registry bits ref ty@(C.Constructor name arguments)
  | isInteger name && null arguments = pure (integerSchema bits name,[])
  | name == "Bool" && null arguments = pure (object ["type" .= ("boolean" :: String)],[])
  | name == "Text" && null arguments = pure (object ["type" .= ("string" :: String)],[])
  | name `elem` ["Unit","Null","Undefined"] && null arguments = pure (object ["type" .= ("null" :: String)],[])
  | name == "List", [C.TypeArgument element] <- arguments =
      pure (object ["type" .= ("array" :: String), "items" .= ref element],[element])
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
            restricted = if null restrictions then body else object ["allOf" .= (body : restrictions)]
            tagged = objectSchema [("tag",object ["const" .= C.idText (C.constructorId constructor)]),("fields",restricted)]
        pure (if length (C.dataConstructors declaration) == 1 then restricted else tagged, map C.binderType fields)
      let body = case constructors of
            [] -> Bool False
            [(single,_)] -> single
            _ -> object ["oneOf" .= map fst constructors]
      pure (body,concatMap snd constructors)
shape _ _ _ ty = Left ("configuration requires concrete data, got " ++ show ty)

objectSchema :: [(String,Value)] -> Value
objectSchema fields = object ["type" .= ("object" :: String), "properties" .= dict fields,
  "required" .= map fst fields, "additionalProperties" .= False]

integerSchema :: Int -> String -> Value
integerSchema bits name = object $ ["type" .= ("integer" :: String)] ++
  case integerBounds bits name of
    Just (lo,hi) -> ["minimum" .= lo,"maximum" .= hi]
    Nothing | name == "BigUInt" -> ["minimum" .= (0 :: Int)]
    _ -> []

-- JSON Schema has numeric bounds but no general cross-field arithmetic.
-- Refuse any predicate outside that vocabulary instead of weakening the type.
schemaRestriction :: [C.Binder] -> C.Expr -> Either String Value
schemaRestriction fields expression = case C.expressionNode expression of
  C.ShortCircuit C.And a b -> object . (\xs -> ["allOf" .= xs]) <$> mapM (schemaRestriction fields) [a,b]
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
      pure (object ["properties" .= dict [(field,dict [(keyword,toJSONInteger value)])]])
    toJSONInteger n = Number (fromInteger n)

reverseComparison :: C.BinaryOp -> C.BinaryOp
reverseComparison op = case op of
  C.Less -> C.Greater; C.LessEqual -> C.GreaterEqual
  C.Greater -> C.Less; C.GreaterEqual -> C.LessEqual; other -> other

encodeValue :: TypeRegistry -> V.Value -> Either String Value
encodeValue registry value = case value of
  V.ScalarValue (SInteger _ n) -> pure (Number (fromInteger n))
  V.ScalarValue (SBool b) -> pure (Bool b)
  V.ScalarValue (SSequence "Text" xs) -> pure (String (T.pack (map chr xs)))
  V.ScalarValue (SAbsent _) -> pure Null
  V.DataValue (C.Constructor "List" _) _ _ -> V.listItems value >>= fmap toJSON . mapM (encodeValue registry)
  V.DataValue ty@(C.Constructor name _) tag payload -> do
    declaration <- lookupData registry (C.Id name)
    fields <- constructorFieldsFor registry ty tag
    unless (length fields == length payload) (Left "configuration constructor arity mismatch")
    body <- dict <$> sequence [(,) (C.binderName binder) <$> encodeValue registry v | (binder,v) <- zip fields payload]
    pure $ if length (C.dataConstructors declaration) == 1 then body else
      object ["tag" .= C.idText tag,"fields" .= body]
  _ -> Left ("configuration scalar encoding is unsupported: " ++ show value)

terraformType :: TypeRegistry -> [C.Type] -> C.Type -> Either String String
terraformType registry seen ty@(C.Constructor name arguments)
  | isInteger name && null arguments = case integerBounds 64 name of
      Just _ -> pure "number"
      Nothing -> Left ("Terraform's finite numeric precision cannot represent the complete " ++ name ++ " domain")
  | name == "Bool" && null arguments = pure "bool"
  | name == "Text" && null arguments = pure "string"
  | name == "List", [C.TypeArgument element] <- arguments =
      (\t -> "list(" ++ t ++ ")") <$> terraformType registry seen element
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
        pure (name' ++ " = " ++ t)
      pure ("object({" ++ intercalate ", " rendered ++ "})")
terraformType _ _ ty = Left ("Terraform type must be concrete: " ++ show ty)

terraformChecks :: TypeRegistry -> Int -> [C.Type] -> String -> C.Type -> Either String String
terraformChecks registry bits seen path ty@(C.Constructor name arguments)
  | isInteger name && null arguments = pure (andChecks $
      [path ++ " != null", "floor(" ++ path ++ ") == " ++ path] ++
      case integerBounds bits name of
        Just (lo,hi) -> [path ++ " >= " ++ show lo,path ++ " <= " ++ show hi]
        Nothing | name == "BigUInt" -> [path ++ " >= 0"]
        _ -> [])
  | name `elem` ["Text","Bool"] && null arguments = pure (path ++ " != null")
  | name == "List", [C.TypeArgument element] <- arguments = do
      let variable = "element" ++ show (length seen)
      check <- terraformChecks registry bits (ty:seen) variable element
      pure ("try(" ++ path ++ " != null && alltrue([for " ++ variable ++ " in " ++ path ++ " : " ++ check ++ "]), false)")
  | ty `elem` seen = Left "recursive Terraform validation is unsupported"
  | otherwise = do
      declaration <- lookupData registry (C.Id name)
      constructor <- case C.dataConstructors declaration of [c] -> pure c; _ -> Left "Terraform unions are unsupported"
      fields <- constructorFieldsFor registry ty (C.constructorId constructor)
      checks <- forM fields $ \b -> terraformChecks registry bits (ty:seen)
        (path ++ "[" ++ json (String (T.pack (C.binderName b))) ++ "]") (C.binderType b)
      predicates <- mapM (terraformPredicate [(C.binderId b,path ++ "[" ++ json (String (T.pack (C.binderName b))) ++ "]") | b <- fields])
        (C.constructorPredicates constructor)
      pure ("try(" ++ andChecks ((path ++ " != null") : checks ++ predicates) ++ ", false)")
terraformChecks _ _ _ _ ty = Left ("unsupported Terraform validation: " ++ show ty)

andChecks :: [String] -> String
andChecks [] = "true"
andChecks xs = "(" ++ intercalate " && " xs ++ ")"

-- cty normalizes its strings. Accept only stable, already-normalized literal
-- values, using an established normalizer and its pinned Unicode database.
-- Newer unassigned characters are unsupported rather than guessed unchanged.
terraformValue :: Value -> Either String ()
terraformValue (String value) = unless
  (T.all ((/= Unicode.NotAssigned) . Unicode.generalCategory) value && Normalize.normalize Normalize.NFC value == value)
  (Left "Terraform normalizes Text; literal values must already be NFC and assigned in Unicode 15.1")
terraformValue (Array values) = mapM_ terraformValue values
terraformValue (Object values) = mapM_ terraformValue values
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

-- Phony stages deliberately invoke the user's installed CLI. They neither
-- install tools nor claim execution merely because the file was generated.
makePipeline :: String
makePipeline = unlines
  [ "# Generated LawSpec pipeline. Run from the directory containing lawspec.json."
  , "LAWSPEC ?= lawspec"
  , ".PHONY: all check generate test verify"
  , "all: verify"
  , "check:"
  , "\t$(LAWSPEC) check"
  , "generate: check"
  , "\t$(LAWSPEC) generate"
  , "test: generate"
  , "\t$(LAWSPEC) test"
  , "verify: test"
  ]

-- | ANTLR owns parsing. No embedded target-language actions or custom parser
-- engine is generated. Constructor application text is unambiguous and keeps
-- qualified constructor identities, including equal-shaped sum alternatives.
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
      collect seen t | t `elem` seen = pure []
      collect seen _ | length seen > 128 = Left "ANTLR type expansion exceeds 128 levels"
      collect seen t = do
        (rule,children) <- grammarRule registry t
        rest <- concat <$> mapM (collect (t:seen)) children
        pure ((typeKey t,rule):rest)
  unless (not (null roots)) (Left "ANTLR requires at least one concrete data type")
  rules <- M.toList . M.fromList . concat <$> mapM (collect []) roots
  let ref t = object ["$ref" .= ("#/$defs/" ++ typeKey t)]
      schemas seen t | t `elem` seen = pure []
      schemas seen _ | length seen > 128 = Left "ANTLR companion schema expansion exceeds 128 levels"
      schemas seen t = do
        (body,children) <- shape registry (planMachineBits plan) ref t
        rest <- concat <$> mapM (schemas (t:seen)) children
        pure ((typeKey t,body):rest)
  definitions <- M.toList . M.fromList . concat <$> mapM (schemas []) roots
  let grammar = unlines (["// Generated data syntax; semantic constraints require validation after decoding.",
        "grammar LawSpecData;", "document : (" ++ intercalate " | " (map typeKey roots) ++ ") EOF ;"] ++
        ["document_" ++ typeKey ty ++ " : " ++ typeKey ty ++ " EOF ;" | ty <- roots] ++
        [name ++ " : " ++ body ++ " ;" | (name,body) <- rules] ++
        ["INTEGER : '-'? ('0' | [1-9] [0-9]*) ;",
         "TEXT : '\"' (ESC | ~[\"\\\\\\u0000-\\u001F])* '\"' ;",
         "fragment ESC : '\\\\' ([\"\\\\/bfnrt] | 'u' HEX HEX HEX HEX) ;",
         "fragment HEX : [0-9a-fA-F] ;", "WS : [ \\t\\r\\n]+ -> skip ;"])
  pure [file "LawSpecData.g4" grammar,
    file "data.schema.json" (json (object ["$schema" .= ("https://json-schema.org/draft/2020-12/schema" :: String),
      "$defs" .= dict definitions, "anyOf" .= map ref roots]) ++ "\n"),
    file "lawspec-artifacts.json" (json (object ["target" .= ("antlr4" :: String),
      "kind" .= ("syntax" :: String), "lawsExecuted" .= False,
      "semanticValidation" .= ("required-after-decoding" :: String),
      "entryPoints" .= dict [(typeKey ty, object ["rule" .= ("document_" ++ typeKey ty),
        "schema" .= ("#/$defs/" ++ typeKey ty)]) | ty <- roots],
      "types" .= dict [(typeKey ty,String (T.pack (show ty))) | ty <- roots]]) ++ "\n")]

grammarRule :: TypeRegistry -> C.Type -> Either String (String,[C.Type])
grammarRule registry ty@(C.Constructor name args)
  | isInteger name && null args = pure ("INTEGER",[])
  | name == "Bool" && null args = pure ("'true' | 'false'",[])
  | name == "Text" && null args = pure ("TEXT",[])
  | name `elem` ["Unit","Null","Undefined"] && null args = pure ("'" ++ name ++ "'",[])
  | name == "List", [C.TypeArgument t] <- args =
      pure ("'[' (" ++ typeKey t ++ " (',' " ++ typeKey t ++ ")*)? ']'",[t])
  | otherwise = do
      declaration <- lookupData registry (C.Id name)
      unless (not (C.dataHandle declaration) && C.dataIndex declaration == Nothing)
        (Left ("ANTLR indexed/opaque data syntax is unsupported: " ++ name))
      choices <- forM (C.dataConstructors declaration) $ \c -> do
        unless (null (C.constructorExistentials c) && null (C.constructorEquations c))
          (Left "ANTLR existential/refined data syntax is unsupported")
        fields <- constructorFieldsFor registry ty (C.constructorId c)
        let types = map C.binderType fields
        pure (antlrLiteral (C.idText (C.constructorId c)) ++
          (if null fields then "" else " '(' " ++ intercalate " ',' " (map typeKey types) ++ " ')'"),types)
      unless (not (null choices)) (Left "ANTLR empty data types have no textual inhabitants")
      pure (intercalate " | " (map fst choices),concatMap snd choices)
grammarRule _ ty = Left ("ANTLR requires a concrete data type: " ++ show ty)

antlrLiteral :: String -> String
antlrLiteral text = "'" ++ concatMap escape text ++ "'"
  where
    escape '\'' = "\\'"
    escape '\\' = "\\\\"
    escape c = [c]
