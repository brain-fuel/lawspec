{-# LANGUAGE PatternSynonyms #-}
-- | Presentation-only accessors over Core and Testing. No source syntax,
-- substitution, type inference, or refinement expansion belongs here.
module LawSpec.Backend where
import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as Doc
import LawSpec.Testing (PlannedProperty(..), GeneratorRequirement(..))
import LawSpec.Common (Generation, Location(..), Quantification(..), renderReference, documentaryUnit, documentaryName)
import LawSpec.Scalar (prettyScalar)
import Data.List (intercalate, stripPrefix, isPrefixOf)
import Data.Char (isAlphaNum, isDigit)
import qualified Data.Map.Strict as M
import Numeric (showHex)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Code.Literal (printable)
import LawSpec.Naming (displayLabel, sourceDefinitionName)
import LawSpec.SourceLink (labelled, locationLink)

-- | Emitters were written against these names; the aliases keep their code
-- unchanged while their input is Core. ref:DEC-typed-core-boundary
type Type = C.Type
pattern Named :: String -> Type
pattern Named n = C.Constructor n []
pattern Applied :: String -> Type -> Type
pattern Applied n a = C.Constructor n [C.TypeArgument a]
pattern Arrow :: Type -> Type -> Type
pattern Arrow a b = C.Arrow a b

-- | As Type, Core expressions under the emitters' name.
type Expr = C.Expr
-- | As Type, Core propositions under the emitters' name.
type Assertion = C.Proposition
pattern AssertEqual :: Expr -> Expr -> Assertion
pattern AssertEqual a b <- C.Equation _ a b
pattern AssertImplies :: Expr -> Assertion -> Assertion
pattern AssertImplies a b = C.Implication a b
pattern AssertAll :: [Assertion] -> Assertion
pattern AssertAll ps = C.Conjunction ps
-- | As Type, Core units under the emitters' name.
type Unit = C.Unit
-- | As Type, quantifiers under the emitters' name.
type Input = C.Quantifier
-- | Emitters receive planned properties, so every target emits the same cases.
-- ref:DEC-planned-generation
type Expanded = PlannedProperty
-- | As Type, Core examples under the emitters' name.
type Example = C.Example
-- | As Type, Core contracts under the emitters' name.
type Contract = C.Contract

-- | Generated modules are named after the unit as written.
unitName :: Unit -> String
unitName = C.idText . C.unitId
-- | Each adapter becomes a stub the user implements. ref:DEC-adapter-ownership
functions :: Unit -> [(String,Type)]
functions u = [(C.declarationName d,C.declarationType d) | d <- C.unitDeclarations u]
-- | The adapters declared async: tests await each call where it is made.
asyncFunctions :: Unit -> [String]
asyncFunctions u = [C.declarationName d | d <- C.unitDeclarations u, C.declarationAsync d]
contracts :: Unit -> [Contract]
-- Checked definitions enforce their contracts in reusable implementation bodies.
-- Test-only wrappers are exclusively for user adapters, which have native stubs.
contracts unit = [contract | contract <- C.unitContracts unit,
  C.contractDeclaration contract `notElem` definitionIds]
  where definitionIds = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
functionType :: Type -> ([Type],Type)
functionType = C.functionType
expressionType :: Expr -> Type
expressionType = C.expressionType
inputName, inputId :: Input -> String
inputName = C.binderName . C.quantifiedBinder
inputId = localName . C.binderId . C.quantifiedBinder
inputType :: Input -> Type
inputType = C.binderType . C.quantifiedBinder
inputRefinements :: Input -> [Expr]
inputRefinements = C.quantifiedPredicates
inputs :: Expanded -> [Input]
inputs = C.propertyInputs . plannedProperty
assertion :: Expanded -> Assertion
assertion = C.propertyBody . plannedProperty
-- | Tests are grouped by the unit that declares the law.
owner, name :: Expanded -> String
owner e = fst (splitOnce "::law::" (C.idText (C.propertyId (plannedProperty e))))
name = C.propertyName . plannedProperty
trace :: Expanded -> [String]
trace = C.propertyTrace . plannedProperty
original :: Expanded -> C.Property
original = plannedProperty
description, rationale :: C.Property -> String
description = C.propertyDescription
rationale = C.propertyRationale
references :: C.Property -> [String]
references = map (renderReference (\target -> documentaryUnit target ++ "." ++ documentaryName target)) . C.propertyReferences
location :: C.Property -> Location
location = C.propertyLocation
generation :: Expanded -> Generation
generation = C.propertyGeneration . plannedProperty
-- | Contracts and laws are reported differently in test headers.
propertyKind :: Expanded -> String
propertyKind e = if take 9 (name e) == "contract " then "contract" else "law"
examples :: C.Property -> [Example]
examples = C.propertyExamples
exampleName :: Example -> String
exampleName = C.exampleName
bindings :: Example -> [(String,Expr)]
bindings e = [(localName i,v) | (i,v) <- C.exampleBindings e]
expectations :: Example -> [Assertion]
expectations = C.exampleExpectations
contractName :: Contract -> String
contractName = declarationName . C.contractDeclaration
contractArguments :: Contract -> [(String,Type)]
contractArguments c = [(localName (C.binderId b),C.binderType b) | b <- C.contractArguments c]
contractResult :: Contract -> (String,Type)
contractResult c = let b = C.contractResult c in (localName (C.binderId b),C.binderType b)
contractPreconditions, contractPostconditions :: Contract -> [Expr]
contractPreconditions = C.contractPreconditions
contractPostconditions = C.contractPostconditions

-- | The native name of an adapter, which may be escaped for the target
-- (LawSpec.TargetNames); messages keep the declared name.
adapterName :: Unit -> C.Id -> String
adapterName u identity = case [C.declarationName d | d <- C.unitDeclarations u, C.declarationId d == identity] of
  name : _ -> name
  [] -> declarationName identity
-- | Generated code uses the declared name without its unit qualification.
declarationName :: C.Id -> String
declarationName = lastPart . C.idText where
  lastPart s = case splitOnce "::" s of (_,Just rest) -> lastPart rest; _ -> s
-- | Compiler-made binders get names no user can write, so they never clash with
-- an input or adapter in generated code.
localName :: C.Id -> String
localName i | (_,Just suffix) <- splitOnce "::payload::" (C.idText i) =
  let (depth,rest) = splitOnce "::" suffix
      index = fst (splitOnce "::" (maybe "" id rest))
  in "_payload" ++ map (\c -> if isAlphaNum c then c else '_') (depth ++ "_" ++ index)
localName i | (_,Just suffix) <- splitOnce "::let::" (C.idText i) =
  "_let" ++ map (\c -> if isAlphaNum c then c else '_') suffix
localName i | (_,Just suffix) <- splitOnce "::match::" (C.idText i) =
  "_match" ++ map (\c -> if isAlphaNum c then c else '_') suffix
localName i | (_,Just n) <- splitOnce "::resource::" (C.idText i) = "_resource" ++ takeWhile isAlphaNum n
localName i | (_,Just n) <- splitOnce "::logical::" (C.idText i) =
  "_logical" ++ map (\c -> if isAlphaNum c then c else '_') n
localName i = case splitOnce "::input::" (C.idText i) of
  (_,Just n) -> "_input" ++ n
  _ -> case splitOnce "::contract::" (C.idText i) of
    (_,Just n) -> "_arg" ++ n
    _ -> declarationName i
-- | Identities are paths joined by ::, and names are recovered from them.
splitOnce :: String -> String -> (String,Maybe String)
splitOnce needle = go [] where
  go prefix rest | Just after <- stripPrefix needle rest = (reverse prefix,Just after)
  go prefix (c:rest) = go (c:prefix) rest
  go prefix [] = (reverse prefix,Nothing)

-- | Each input's generator requirements, in input order.
generationPlan :: Expanded -> [GeneratorRequirement]
generationPlan = generatorRequirements
domainInput :: GeneratorRequirement -> Input
domainInput g = C.Quantifier (generatorBinder g) (generatorPredicates g) (generatorBounds g)
domainBounds :: GeneratorRequirement -> [(String,Expr)]
domainBounds g = [(C.binaryName op,e) | (op,e) <- generatorBounds g]

-- | Portable runtime keys retain nested presence and Either argument boundaries.
scalarTypeKey :: Type -> String
scalarTypeKey (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) =
  "Either (" ++ scalarTypeKey a ++ ") (" ++ scalarTypeKey b ++ ")"
scalarTypeKey (C.Constructor n [C.TypeArgument t]) = n ++ " " ++ scalarTypeKey t
scalarTypeKey t = prettyType t

-- | Test headers show types as LawSpec writes them.
prettyType :: Type -> String
prettyType (C.Constructor n args) = unwords (n:map argument args) where
  argument (C.TypeArgument t) = "(" ++ prettyType t ++ ")"
  argument (C.IndexArgument (C.Natural n')) = show n'
  argument (C.IndexArgument (C.IndexVariable i)) = C.idText i
prettyType (C.TypeVariable n) = C.idText n
prettyType (C.Arrow a b) = "(" ++ prettyType a ++ " -> " ++ prettyType b ++ ")"
-- | Test headers show the expanded law, so a failure names what was tested.
prettyExpr :: Expr -> String
prettyExpr = prettyExprWith False localName

-- | As prettyExpr, with binders named by a function and, when readable, text
-- written with its characters rather than escapes.
prettyExprWith :: Bool -> (C.Id -> String) -> Expr -> String
prettyExprWith readable local = prettyExpr' where
 prettyExpr' e = case C.expressionNode e of
  C.Constant s -> if readable then readableScalar s else prettyScalar s
  C.Construct tag args -> C.idText tag ++ "(" ++ intercalate ", " (map prettyExpr' args) ++ ")"
  C.Match value branches -> "match (" ++ prettyExpr' value ++ ") { " ++ intercalate "; "
    [C.idText (C.caseConstructor branch) ++ " " ++ unwords (map (local . C.binderId) (C.caseBinders branch)) ++
      " -> " ++ prettyExpr' (C.caseBody branch) | branch <- branches] ++ " }"
  C.AllElements value binder predicate -> "allElements (" ++ prettyExpr' value ++ ") (" ++
    local (C.binderId binder) ++ " -> " ++ prettyExpr' predicate ++ ")"
  C.SearchElements universal value binder predicate -> "searchElements " ++ show universal ++ " (" ++ prettyExpr' value ++ ") (" ++
    local (C.binderId binder) ++ " -> " ++ prettyExpr' predicate ++ ")"
  C.AllPayloads value predicates -> "allPayloads (" ++ prettyExpr' value ++ ") [" ++
    intercalate ", " [local (C.binderId binder) ++ " -> " ++ prettyExpr' predicate
      | (binder,predicate) <- predicates] ++ "]"
  C.Local n -> local n
  C.ExternalCall n args -> unwords ((if readable then sourceDefinitionName else id) (declarationName n):map argument args)
  C.Binary op _ a b -> "(" ++ prettyExpr' a ++ " " ++ C.binaryName op ++ " " ++ prettyExpr' b ++ ")"
  C.Unary op a -> show op ++ "(" ++ prettyExpr' a ++ ")"
  C.ShortCircuit op a b -> "(" ++ prettyExpr' a ++ " " ++ show op ++ " " ++ prettyExpr' b ++ ")"
  C.If c a b -> "(if " ++ prettyExpr' c ++ " then " ++ prettyExpr' a ++ " else " ++ prettyExpr' b ++ ")"
  C.Convert _ t a -> "(" ++ prettyExpr' a ++ " :: " ++ prettyType t ++ ")"
  -- Matchers read as they are written.
  C.Helper C.Recorded [key, value] -> prettyExpr' value ++ " = recorded " ++ prettyExpr' key
  C.Helper C.StartsWith [a, b] -> "(" ++ prettyExpr' a ++ " starts with " ++ prettyExpr' b ++ ")"
  C.Helper C.EndsWith [a, b] -> "(" ++ prettyExpr' a ++ " ends with " ++ prettyExpr' b ++ ")"
  C.Helper C.TextContains [a, b] -> "(" ++ prettyExpr' a ++ " contains " ++ prettyExpr' b ++ ")"
  C.Helper C.RegexMatches [p, t] -> "(" ++ prettyExpr' t ++ " matches regex " ++ prettyExpr' p ++ ")"
  C.Helper b args -> show b ++ "(" ++ intercalate ", " (map prettyExpr' args) ++ ")"
  C.Perform op args -> unwords (C.operationName op : map argument args)
  C.Handle (C.CatchFailure _) body -> "attempt (" ++ prettyExpr' body ++ ")"
  C.Handle (C.WithHandler _ _) body -> "handle (" ++ prettyExpr' body ++ ")"
  C.Project _ index value -> prettyExpr' value ++ "." ++ show index
  C.Update _ index value field -> "(" ++ prettyExpr' value ++ " with " ++ show index ++ " = " ++ prettyExpr' field ++ ")"
  C.Let binder _ _ | searchDecision (C.binderId binder) -> "the scoped requirement"
  C.Let binder value body -> "let " ++ local (C.binderId binder) ++ " = " ++ prettyExpr' value ++ " in " ++ prettyExpr' body
  C.Calls op args -> "calls of " ++ C.operationName op ++ maybe "" (\xs -> " with (" ++ intercalate ", " (map prettyExpr' xs) ++ ")") args
 -- Readable text leaves a name or a literal argument unparenthesised.
 argument a = case C.expressionNode a of
   C.Local _ | readable -> prettyExpr' a
   C.Constant _ | readable -> prettyExpr' a
   _ -> "(" ++ prettyExpr' a ++ ")"

-- | A scalar as a reader writes it: text with its own characters, escaping
-- only quotes, backslashes, line breaks, tabs and unprintable characters.
readableScalar :: Scalar -> String
readableScalar s = case s of
  SSequence "Text" xs -> "\"" ++ concatMap escape (map toEnum xs) ++ "\""
  SCharacter "Char" c -> "char(\"" ++ escape (toEnum c) ++ "\")"
  _ -> prettyScalar s
  where
    escape c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\t' -> "\\t"
      '\r' -> "\\r"
      _ | printable c -> [c]
        | otherwise -> "\\u{" ++ showHex (fromEnum c) "" ++ "}"

-- Internal search decisions are execution machinery. The surrounding failure
-- already names the authoritative law and its inputs; keep its label readable.
searchDecision :: C.Id -> Bool
searchDecision identity = let (digits,rest) = span isDigit (reverse (C.idText identity))
  in not (null digits) && reverse "::logical::decision" `isPrefixOf` rest

-- | As in LawSpec.Compile, the quantified statement a test checks.
prettyExpanded :: Expanded -> String
prettyExpanded = prettyExpandedWith False localName

-- | As prettyExpanded, as prettyExprWith writes expressions.
prettyExpandedWith :: Bool -> (C.Id -> String) -> Expanded -> String
prettyExpandedWith _ _ e | propertyKind e == "contract" = description (original e)
prettyExpandedWith readable local e
  | null (inputs e) = propositionTextWith readable local (sourceBody e)
  | otherwise = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ ")" | i <- inputs e] ++ " => " ++ propositionTextWith readable local (sourceBody e) ++ " end for all"
-- | As prettyExpr, for propositions.
propositionText :: Assertion -> String
propositionText = propositionTextWith False localName

propositionTextWith :: Bool -> (C.Id -> String) -> Assertion -> String
propositionTextWith readable local = go where
 expr = prettyExprWith readable local
 go (AssertEqual a b) = expr a ++ " = " ++ expr b
 go (AssertImplies g p) = expr g ++ " implies " ++ go p
 go (AssertAll ps) = intercalate " and " (map go ps)
 go (C.Negation body) = "not (" ++ go body ++ ")"
 go (C.Quantified kind q body) =
  (if kind == ForEvery then "for all " else "there exists ") ++ "(" ++ C.binderName (C.quantifiedBinder q) ++
  " :: " ++ prettyType (C.binderType (C.quantifiedBinder q)) ++ ") " ++
  (if kind == ForEvery then "=> " else "such that ") ++ go body ++ (if kind == ForEvery then " end for all" else " end exists")
 go _ = ""

-- | Each binder's source name, for readable text about a law: its inputs,
-- resources and every binder inside it. Others keep their generated names.
sourceNames :: C.Property -> C.Id -> String
sourceNames property identity = M.findWithDefault (localName identity) identity table
  where
    table = M.fromList [(C.binderId b, C.binderName b) | b <- reverse (propertyBinders property)]

-- | A law's binders in the order they appear: inputs, resources, then those
-- inside its statement and examples.
propertyBinders :: C.Property -> [C.Binder]
propertyBinders property =
  map C.quantifiedBinder (C.propertyInputs property) ++
  map C.resourceBinder (C.propertyResources property) ++
  concatMap expressionBinders (C.propertyExpressions property)

-- | The binders an expression introduces, in order.
expressionBinders :: Expr -> [C.Binder]
expressionBinders term = (case C.expressionNode term of
  C.AllElements _ binder _ -> [binder]
  C.SearchElements _ _ binder _ -> [binder]
  C.AllPayloads _ predicates -> map fst predicates
  C.Match _ cases -> concatMap C.caseBinders cases
  C.Let binder _ _ -> [binder]
  _ -> []) ++ concatMap expressionBinders (C.children term)

-- | A law's source line, when it has one.
propertyLink :: C.Property -> Maybe String
propertyLink p = let l = location p in if null (file l) then Nothing else Just (locationLink l)

-- | The comment above a law's tests: its name and source line, what it
-- says, and the statement its tests check, written with source names and
-- real characters. Empty fields are left out; examples are linked from
-- their own tests. ref:DEC-readable-output-default
lawCommentLines :: Expanded -> [String]
lawCommentLines e = map (map safe) (concatMap lines (
  [labelled (displayLabel (name e)) (propertyLink (original e))] ++
  [description (original e) | not (null (description (original e)))] ++
  ["Rationale: " ++ rationale (original e) | not (null (rationale (original e)))] ++
  ["References: " ++ intercalate ", " (references (original e)) | not (null (references (original e)))] ++
  ["Expands: " ++ intercalate "; " (map displayLabel (drop 1 (trace e))) | length (trace e) > 1] ++
  [prettyExpandedWith True (sourceNames (original e)) e]))
  where
    safe c | c < ' ' || c == '\x2028' || c == '\x2029' || c == '\x85' = ' '
           | otherwise = c

-- | Every generated test begins with its law's description, rationale and
-- references, so the test explains why it exists.
metadata :: String -> Expanded -> String
metadata prefix e = unlines [prefix ++ " " ++ line | line <- metadataLines e]

-- | As metadata, laid out by the target's formatter. ref:DEC-readable-output-default
metadataDocument :: Int -> String -> Expanded -> Doc.Doc
metadataDocument width prefix = mconcat . map (Doc.lineComment width (prefix ++ " ")) . metadataLines

-- | Backslashes and line separators are replaced, because they would end or
-- escape a comment in some target.
metadataLines :: Expanded -> [String]
metadataLines e = map (map safe) (lines text) where
  text = "Law: " ++ owner e ++ "::" ++ name e ++ "\nDescription: " ++ description (original e)
    ++ "\nRationale: " ++ rationale (original e) ++ "\nReferences: " ++ intercalate ", " (references (original e))
    ++ "\nExpansion:\n" ++ unlines (trace e) ++ prettyExpanded e
    ++ concat ["\nExample: " ++ exampleName ex ++ "\n" ++ unlines ["expect " ++ propositionText p | p <- expectations ex] | ex <- examples (original e)]
  safe '\\' = '／'
  safe c | c < ' ' || c == '\x2028' || c == '\x2029' = ' '
         | otherwise = c
