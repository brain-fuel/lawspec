{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
-- | The surface syntax tree shared by the parser, inference and expansion. It
-- stays out of Core and the emitters, which the boundary check enforces.
-- ref:DEC-typed-core-boundary
module LawSpec.Model (module LawSpec.Model, module LawSpec.Common) where

import LawSpec.Core.Policy (StagePolicy)
import LawSpec.Core.Machine (Machine, Supervisor)
import qualified LawSpec.Core.Positional as Positional
import LawSpec.Common

import Data.Aeson hiding (Number)
import LawSpec.Scalar
import LawSpec.IndexTerm (FamilyIndex,IndexGuard,indexGuardText)
import GHC.Generics (Generic)
import Data.List (intercalate, nub)

data Type = Named String | Variable String | Arrow Type Type | Applied String Type | Application String [Type] | Record [RecordField] | Refined String Type (Maybe Expr) | RefinementApp String [RefinementArgument] | Qualified [Constraint] Type | CheckedType [Expr] Type | IndexedRecord [RecordField] RecordIndexConstraints deriving (Eq, Show, Generic)
-- Internal elaboration metadata stays on the product type through substitution.
-- It is never a new authored declaration or an extra stored witness field.
newtype RecordIndexConstraints = RecordIndexConstraints [IndexGuard] deriving (Eq,Show,Generic)
instance ToJSON RecordIndexConstraints where
  toJSON (RecordIndexConstraints guards)=toJSON (map indexGuardText guards)

typeRecordFields :: Type -> Maybe [RecordField]
typeRecordFields (Record fields)=Just fields
typeRecordFields (IndexedRecord fields _)=Just fields
typeRecordFields _=Nothing

pattern RecordShape :: [RecordField] -> Type
pattern RecordShape fields <- (typeRecordFields -> Just fields)

withRecordFields :: Type -> [RecordField] -> Type
withRecordFields (IndexedRecord _ constraints) fields=IndexedRecord fields constraints
withRecordFields _ fields=Record fields

recordIndexConditions :: Type -> [IndexGuard]
recordIndexConditions (IndexedRecord _ (RecordIndexConstraints guards))=guards
recordIndexConditions (Refined _ ty _)=recordIndexConditions ty
recordIndexConditions (Qualified _ ty)=recordIndexConditions ty
recordIndexConditions (CheckedType _ ty)=recordIndexConditions ty
recordIndexConditions _=[]

-- A field's public label and lexical binder start with the same spelling.
-- Substitution can rename the binder without renaming the property. Fields
-- retain declaration order: their binders scope over their own restrictions
-- and subsequent fields, never over earlier fields.
data RecordField = RecordField
  { recordFieldLabel :: String, recordFieldBinding :: String, recordFieldType :: Type }
  deriving (Eq, Show, Generic)
instance ToJSON RecordField
data Expr = Located Span Expr | Var String | Apply Expr Expr | Compose Expr Expr | Number Integer | DecimalNumber Integer Integer | StringLit String | BoolLit Bool | ScalarLit Scalar | ListLit [Expr] | RecordLit [(String,Expr)] | ConstructLit String [Expr] | MatchExpr Expr [MatchBranch] | AllElementsExpr Expr String Expr | AllPayloadsExpr Expr [(String, Expr)] | Binary String Expr Expr | Unary String Expr | Annotate Expr Type | TypeBound String Type deriving (Eq, Show, Generic)
data MatchBranch = MatchBranch String [String] Expr deriving (Eq, Show, Generic)
data TypedCase = TypedCase String [(String,Type)] TypedExpr deriving (Eq, Show, Generic)
data Definition = Forall [(String, Type)] Definition | Equal Expr Expr | Holds Expr | Implies Expr Definition | And Definition Definition | Invoke String [Expr] | Exists [(String, Type)] Definition | Not Definition deriving (Eq, Show, Generic)
data Constraint = Capability String Type deriving (Eq, Show, Generic)
data RefinementArgument = TypeArgument Type | ValueArgument Expr deriving (Eq, Show, Generic)
data Refinement = Refinement { refinementName :: String, refinementParameters :: [(String,Type)], refinementRequirements :: [Constraint], refinementBody :: Type } deriving (Eq, Show, Generic)
data Contract = Contract { contractName :: String, contractArguments :: [(String,Type)], contractResult :: (String,Type), contractPreconditions :: [Expr], contractPostconditions :: [Expr] } deriving (Eq, Show, Generic)
data DomainPlan = DomainPlan { domainInput :: Input, domainBounds :: [(String,Expr)] } deriving (Eq, Show, Generic)
instance ToJSON Constraint
instance ToJSON RefinementArgument
instance ToJSON Refinement
instance ToJSON Contract
instance ToJSON DomainPlan

data Literal = IntLiteral Integer | DecimalLiteral Integer Integer | TextLiteral String | BoolLiteral Bool | ScalarLiteral Scalar | ListLiteral [Literal] | ConstructorLiteral String [Literal] | RecordLiteral [(String,Literal)] | SetLiteral String [Literal] deriving (Eq, Show, Generic)
instance ToJSON Literal where
  toJSON (DecimalLiteral c e) = toJSON (SDecimal c e)
  toJSON (IntLiteral n) = toJSON (SInteger "BigInt" n)
  toJSON (TextLiteral s) = toJSON (textScalar s)
  toJSON (BoolLiteral b) = toJSON (SBool b)
  toJSON (ScalarLiteral s) = toJSON s
  toJSON (ConstructorLiteral name fields) = object ["constructor" .= name, "fields" .= fields]
  toJSON (ListLiteral xs) = object ["list" .= xs]
  toJSON (RecordLiteral fields) = object ["record" .= fields]
  toJSON (SetLiteral _ items) = object ["set" .= items]

data Expectation = Expectation { actual :: Expr, expected :: Literal } deriving (Eq, Show, Generic)
instance ToJSON Expectation

data Example = Example { exampleName :: String, bindings :: [(String, Literal)], expectations :: [Expectation] } deriving (Eq, Show, Generic)
-- lawResources are the resources a law takes (law ... for db :: Database
-- is): each case acquires them first and releases them after, even when it
-- fails.
-- Qualification is parsed without alias lookup; resolution is a separate,
-- documentary pass before executable import expansion.
data SourceReferenceTarget = ParsedReferenceTarget [String] Span
  | ResolvedReferenceTarget DocumentaryTarget deriving (Eq, Show, Generic)
instance ToJSON SourceReferenceTarget
data Law = Law { lawName :: String, parameters :: [(String, Type)], requirements :: [Constraint], definition :: Definition, description :: String, rationale :: String, examples :: [Example], references :: [DocumentaryReference SourceReferenceTarget], location :: Location, lawResources :: [(String, Type)], lawMetadata :: LawMetadata } deriving (Eq, Show, Generic)
data DataTypeDeclaration = DataTypeDeclaration
  { dataTypeName :: String, dataTypeParameters :: [String]
  , dataTypeConstructors :: [ConstructorDeclaration], dataTypeSpan :: Span
  , dataTypeIndex :: Maybe FamilyIndex
  } deriving (Eq, Show, Generic)
-- | A GADT constructor refines type parameters: `where a = Int32` makes it a
-- value of T Int32 only. Free variables of a refinement or a field that are not
-- parameters are the constructor's existential types.
data ConstructorDeclaration = ConstructorDeclaration
  { dataConstructorName :: String, dataConstructorFields :: [(String,Type)]
  , dataConstructorSpan :: Span
  , dataConstructorEquations :: [(String,Type)]
  } deriving (Eq, Show, Generic)
-- | import shop.money [as money] [(Amount, add, `associative`)]: qualified
-- access through the alias, plus unqualified access to the listed names. Law
-- names are listed with their backticks.
data Import = Import
  { importUnit :: String, importAlias :: String
  , importItems :: [String], importSpan :: Span
  } deriving (Eq, Show, Generic)
data FunctionDefinition = MkFunctionDefinition
  { functionName :: String, functionArguments :: [(String, Type)]
  , functionResult :: Type, functionRequirements :: [Constraint]
  , functionBody :: Expr, functionSpan :: Span
  -- Owning source unit and authored spelling, retained through copies and
  -- specialization independently of generated executable identities.
  , functionSource :: Maybe (String,String)
  , functionTemplate :: Maybe String
  -- Source mapping obligations remain intrinsic after ordinary desugaring.
  -- Only origins and row boundaries are stored here; typed bodies are the
  -- authoritative values, so import/type rewriting has one expression tree.
  , functionMapping :: Maybe MappingOrigin
  } deriving (Eq, Show, Generic)
data MappingRole = MappingForward | MappingPreimages | MappingInverse deriving (Eq, Show, Generic)
data MappingOrigin = MappingOrigin
  { mappingOwner :: String, mappingName :: String, mappingRole :: MappingRole
  , mappingRowSpans :: [Span], mappingFallbackSpan :: Maybe Span
  } deriving (Eq, Show, Generic)
pattern FunctionDefinition :: String -> [(String,Type)] -> Type -> [Constraint] -> Expr -> Span -> FunctionDefinition
pattern FunctionDefinition name arguments result requirements body range <- MkFunctionDefinition name arguments result requirements body range _ _ _
  where FunctionDefinition name arguments result requirements body range = MkFunctionDefinition name arguments result requirements body range Nothing Nothing Nothing
{-# COMPLETE FunctionDefinition #-}
-- | asyncFunctions names the adapters declared `async`: their results arrive
-- later, as each target's task, and tests await them where they are called.
-- orchestrations names the definitions that may call adapters: workflows,
-- whose composition LawSpec generates and every target runs natively.
data Unit = Unit { unitName :: String, functions :: [(String, Type)], laws :: [Law], refinements :: [Refinement], contracts :: [Contract], declarationSpans :: [(String,Span)], dataTypes :: [DataTypeDeclaration], functionDefinitions :: [FunctionDefinition], asyncFunctions :: [String], orchestrations :: [String], policies :: [(String, StagePolicy String)], machines :: [Machine String], handles :: [String], protocols :: [Protocol], supervisors :: [Supervisor], mailboxes :: [(String, Type, Span)]
  -- Abilities (LawSpec.Abilities): what the unit declares, and what the
  -- abilities pass derives from it. See docs/explanation/abilities.md.
  , abilities :: [AbilityDeclaration], handlerDeclarations :: [HandlerDeclaration]
  -- The abilities each signature or definition says it uses (`uses A, B`,
  -- `fails with E`), by name; a definition may leave its list out.
  , declaredUses :: [(String, [Type])]
  -- The handlers each law names with `using`, by law name.
  , lawHandlers :: [(String, [HandlerUse])]
  -- Derived: every function's ability row (declared, or inferred for a
  -- definition), and the handler each law runs under for each ability.
  , abilityRows :: [(String, [Type])]
  , lawAssignments :: [(String, [(Type, HandlerChoice)])]
  -- The harness unit that serves this unit, if any (LawSpec.Harness): how
  -- its laws are tested, never what they mean.
  , unitHarness :: Maybe HarnessDeclaration
  -- Derived: each law's harness plan, by the law's final name.
  , lawHarness :: [(String, HarnessPlan)]
  -- The unit's resources (resource T is acquire ... release ... end).
  , resourceDeclarations :: [ResourceDeclaration]
  -- handlers name is h1, h2 end: spec handlers that answer their abilities
  -- together, so every law that uses them also runs under all of them.
  , handlerSets :: [HandlerSet] } deriving (Eq, Show, Generic)

data HandlerSet = HandlerSet { handlerSetName :: String, handlerSetMembers :: [String], handlerSetSpan :: Span }
  deriving (Eq, Show, Generic)

-- harness name for unit is item* end: the implementation plane of a unit.
-- It chooses how laws are tested (strategies, handlers, adequacy, run
-- metadata, sharing, benchmarks) and can never change what a law means.
data HarnessDeclaration = HarnessDeclaration
  { harnessName :: String, harnessFor :: String
  , harnessItems :: [HarnessItem], harnessSpan :: Span }
  deriving (Eq, Show, Generic)

data HarnessItem
  = HarnessStrategy StrategyDeclaration
  -- Settings for every law (before the first `for` block).
  | HarnessDefault HarnessSetting Span
  -- for law `a` / for laws `a`, `b`: settings for those laws (a group).
  | HarnessFor [String] [(HarnessSetting, Span)] Span
  | HarnessShare String ShareScope Span
  | HarnessBenchmark String Expr Span
  | HarnessOrderRandom Span
  | HarnessParallel Span
  deriving (Eq, Show, Generic)

data ShareScope = SharePerGroup | SharePerUnit | SharePerRun deriving (Eq, Show, Generic)

-- strategy name :: T is gen end
data StrategyDeclaration = StrategyDeclaration
  { strategyName :: String, strategyType :: Type, strategyBody :: Gen, strategySpan :: Span }
  deriving (Eq, Show, Generic)

-- How a strategy draws a value.
data Gen
  = GenAny (Maybe Type)                 -- the refinement-directed default
  | GenNamed String                     -- another strategy
  | GenOneOf [Expr]                     -- one of these values
  | GenFrequency [(Integer, Gen)]       -- frequency 9 a, 1 b
  | GenSuchThat Gen Expr Integer        -- g such that p (of it) at most n discards
  | GenBind String Type Gen Gen         -- bind x :: T from g in g'
  deriving (Eq, Show, Generic)

data HarnessSetting
  = UseStrategy String String           -- use strategy for input
  -- Imports remain delayed until expansion establishes the actual lexical
  -- binder scope. A local binder must win over an imported value of its name.
  | WitnessSetting [String] Expr [(String, Expr)]
  | TestWith [String]                   -- which lawful handlers (native or spec)
  | CoverSetting Integer String Expr    -- cover p% "label" when e
  | ClassifySetting Expr String         -- classify e as "label"
  | LabelSetting Expr                   -- label e
  | TargetMaximize Expr                 -- target maximize e
  | TagsSetting [String]
  | SkipSetting String
  | KnownFailingSetting String
  | TimeoutSetting Integer              -- milliseconds
  | RepeatSetting Integer
  | RetryFlakySetting Integer
  deriving (Eq, Show, Generic)

-- One law's harness, merged from the unit defaults and its `for` blocks:
-- strategies inlined, expressions still surface syntax over the law's
-- inputs (LawSpec.Frontend elaborates them).
data HarnessPlan = HarnessPlan
  { planHarness :: String, planTags :: [String], planSkip :: Maybe String
  , planKnownFailing :: Maybe String, planTimeout :: Maybe Integer
  , planRepeat :: Integer, planRetries :: Integer
  , planCover :: [(Integer, String, Expr)], planClassify :: [(Expr, String)]
  , planLabels :: [Expr], planTarget :: Maybe Expr
  , planDraws :: [(String, String, Type, Gen)]   -- input, strategy, its type, its body
  , planGroup :: Maybe String
  , planWitnesses :: [([String], Expr, [(String, Expr)], Span)]
  , planResolvedWitnesses :: [HarnessWitness]
  , planDrawLocations :: [(String,Span)] }
  deriving (Eq, Show, Generic)

data HarnessWitness = HarnessWitness
  { witnessPath :: [String], witnessInput :: Input, witnessScope :: [Input]
  , witnessExpression :: Expr, witnessSourceSpan :: Span } deriving (Eq, Show, Generic)

-- resource T is acquire is e end release x is e end [reset x is e end] end.
-- A law that takes a T acquires one before each case and releases it after
-- the case, even when the case fails. reset readies a T for another case;
-- the harness may use it to share one T between cases.
data ResourceDeclaration = ResourceDeclaration
  { resourceType :: Type, resourceAcquire :: Expr
  , resourceRelease :: (String, Expr), resourceReset :: Maybe (String, Expr)
  , resourceSpan :: Span
  -- resource T is concurrent ...: cases may use one shared T at the same
  -- time without interfering, so a harness may share it under parallel.
  , resourceConcurrent :: Bool }
  deriving (Eq, Show, Generic)

-- ability Name (a :: Type)* is (op :: Type)* [laws law*] end. Operations are
-- written like signatures; the laws are obligations on every handler.
data AbilityDeclaration = AbilityDeclaration
  { abilityName :: String, abilityParameters :: [String]
  , abilityOperations :: [(String, Type)], abilityLaws :: [Law], abilitySpan :: Span
  -- The unit that declares it: empty for this unit's own, the declaring
  -- unit's name for a copy an import brought in (LawSpec.Imports).
  , abilityOrigin :: String
  -- What each operation that `fails with E` fails with: E, by operation.
  , abilityFailures :: [(String, Type)]
  -- ability A with T: native handlers of A are made with a T, a resource
  -- the case acquires and shares among them.
  , abilityResource :: Maybe Type }
  deriving (Eq, Show, Generic)

-- handler name for Ability [with state s :: S start e] is clause* end. A
-- clause is `op x y is body end`; in a handler with state, the body may
-- update it with `~s := e;` before giving the result.
data HandlerDeclaration = HandlerDeclaration
  { handlerName :: String, handlerAbility :: Type
  , handlerState :: Maybe (String, Type, Expr)
  , handlerClauses :: [HandlerClause], handlerSpan :: Span
  -- As for abilities: empty here, the declaring unit's name for a copy.
  , handlerOrigin :: String
  -- handler h for A, B, C: the abilities after the first, which h answers
  -- too, from the same state.
  , handlerAlso :: [Type] }
  deriving (Eq, Show, Generic)

data HandlerClause = HandlerClause
  { clauseOperation :: String, clauseParameters :: [String], clauseBody :: Expr, clauseSpan :: Span }
  deriving (Eq, Show, Generic)

-- What a law's `using` names: a spec handler, an ability (whichever lawful
-- handler the harness picks), or a recording of either.
data HandlerUse = UseHandler String | UseAbility String | UseRecording HandlerUse
  deriving (Eq, Show, Generic)

-- The handler a law runs under for one ability: the native production
-- handler, a spec handler, or a recording of one.
data HandlerChoice = ChooseProduction | ChooseSpec String | ChooseRecording HandlerChoice
  deriving (Eq, Ord, Show, Generic)

-- `let x = e in body` and `a; b` are a match with this tag and one binder:
-- every traversal then scopes the binder, and elaboration makes Core's Let.
letTag :: String
letTag = "prelude.Let"

-- Parser-only marker: an empty record pattern still checks its selected type.
-- The colon prevents this from being an authored prelude identifier. It lowers
-- to an ordinary checked record match, with no runtime helper or new Core node.
recordPatternCheckName :: String
recordPatternCheckName = "prelude.record-pattern:"

tuplePatternCheckName :: String
tuplePatternCheckName = "prelude.tuple-pattern:"

-- Positional products use structural fields that source identifiers cannot
-- spell. Arity and nesting remain part of their structural identity; Pair and
-- named records retain their nominal identities.
positionalFields :: [a] -> [(String,a)]
positionalFields = Positional.positionalFields

positionalItems :: [(String,a)] -> Maybe [a]
positionalItems = Positional.positionalItems

-- Source-only admission of every authored pattern. A branch omitted entirely
-- by ordered specialization also retains its guard and body for type checking.
-- Those bodies occur only in the checks, never in executable Core.
selectionValidationName :: String
selectionValidationName = "prelude.selection-validation:"

selectionBranchCheckName :: String
selectionBranchCheckName = "prelude.selection-branch-check:"

-- An unspellable source-only local supplies the already known result type for
-- outcomes outside an independently checked row. No value is ever generated.
selectionBranchResultName :: String
selectionBranchResultName = "_lawspecUnreachableBranchResult_"

selectionBranchCheck :: Expr -> Maybe Expr
selectionBranchCheck value = case unlocated value of
  Apply function body | Var name <- unlocated function, name == selectionBranchCheckName -> Just body
  _ -> Nothing

selectionValidation :: Expr -> Maybe (Expr,[Expr])
selectionValidation expression = case application [] expression of
  (Var name,value:checks) | name==selectionValidationName -> Just (value,checks)
  _ -> Nothing
  where
    application arguments (Located _ value)=application arguments value
    application arguments (Apply function value)=application (value:arguments) function
    application arguments value=(value,arguments)

-- Field access and record update, as the parser writes them:
-- `b.logs` is prelude.field:logs b, and `b with logs = v` is
-- prelude.update:logs b v. Inference makes each a match on b's single
-- constructor, so no later stage sees them.
fieldAccessPrefix, fieldUpdatePrefix :: String
fieldAccessPrefix = "prelude.field:"
fieldUpdatePrefix = "prelude.update:"

-- A handler clause written `op by f` has the body prelude.by f: the clause
-- is f applied to the operation's values (and then the handler's state,
-- when it has one).
clauseBy :: String
clauseBy = "prelude.by"

-- The handler a `handle e with h end` names, from its builtin's name.
handledBy :: String -> Maybe String
handledBy name = case splitAt (length ("prelude.handle:" :: String)) name of
  ("prelude.handle:", handler) | not (null handler) -> Just handler
  _ -> Nothing

-- The built-in failure ability: `fails with E` is `uses Fail E`.
-- The built-in Async ability (lawspec.concurrent), which `async` means.
asyncAbilityName :: String
asyncAbilityName = "Async"

failAbilityName :: String
failAbilityName = "Fail"

-- An ability's name, without its type arguments.
abilityTypeName :: Type -> String
abilityTypeName t = case t of
  Named n -> n
  Applied n _ -> n
  Application n _ -> n
  _ -> prettyType t

-- Every ability a handler answers: handler h for A, B answers A and B.
handlerAbilities :: HandlerDeclaration -> [Type]
handlerAbilities h = handlerAbility h : handlerAlso h

-- The names of a unit's ability operations.
operationNames :: Unit -> [String]
operationNames u = [op | a <- abilities u, (op, _) <- abilityOperations a]

-- | A protocol: what one end of a channel sends and receives, in order (see
-- LawSpec.Scenario).
data Step = Send Type | Receive Type
  deriving (Eq, Show, Generic)

data Protocol = Protocol
  { protocolName :: String, protocolSteps :: [Step], protocolSpan :: Span }
  deriving (Eq, Show, Generic)
data Input = Input { inputName :: String, inputId :: String, inputType :: Type, inputRefinements :: [Expr] } deriving (Eq, Show, Generic)
data Assertion = AssertEqual Expr Expr | AssertImplies Expr Assertion | AssertAll [Assertion] | AssertQuantified Quantification Input Assertion | AssertNot Assertion deriving (Eq, Show, Generic)
instance ToJSON Assertion

data Expanded = Expanded { owner :: String, name :: String, inputs :: [Input], left :: Expr, right :: Expr, guards :: [Expr], assertion :: Assertion, trace :: [String], original :: Law, typedExpressions :: [TypedExpr], propertyKind :: String, generation :: Generation, generationPlan :: [DomainPlan], refinementArgumentChecks :: [Expr], inputDomain :: InputDomain } deriving (Eq, Show, Generic)
instance ToJSON Type
instance ToJSON Expr where
  toJSON (DecimalNumber c e) = object ["tag" .= ("DecimalNumber" :: String), "contents" .= [show c,show e]]
  toJSON (Number n) = object ["tag" .= ("Number" :: String), "contents" .= show n]
  toJSON e = genericToJSON defaultOptions e
instance ToJSON Example
instance ToJSON Definition
instance ToJSON Law
instance ToJSON Input
instance ToJSON Expanded

prettyType :: Type -> String
prettyType (Refined n t p) = "(" ++ n ++ " :: " ++ prettyType t ++ maybe "" ((" where " ++) . prettyExpr) p ++ ")"
prettyType (Qualified _ t) = prettyType t
prettyType (CheckedType _ t) = prettyType t
prettyType (RefinementApp n args) = unwords (n:map arg args) where
  arg (TypeArgument t) = "(" ++ prettyType t ++ ")"
  arg (ValueArgument e) = "(" ++ prettyExpr e ++ ")"
prettyType (Named n) = n
prettyType (Variable n) = reverse (takeWhile (/= ':') (reverse n))
prettyType (Applied n t) = n ++ " (" ++ prettyType t ++ ")"
prettyType (Application n ts) = n ++ concatMap (\t -> " (" ++ prettyType t ++ ")") ts
prettyType (IndexedRecord fields (RecordIndexConstraints guards)) =
  prettyType (Record fields) ++ " with index constraints " ++ intercalate ", " (map indexGuardText guards)
prettyType (RecordShape fields) | Just values <- positionalItems [(recordFieldLabel field,recordFieldType field) | field <- fields] =
  "(" ++ intercalate ", " (map prettyType values) ++ ")"
prettyType (RecordShape fields) = "record{" ++ intercalate ", "
  [recordFieldLabel field ++ " :: " ++ prettyType (recordFieldType field) | field <- fields] ++ "}"
prettyType (Arrow a b) = atom a ++ " -> " ++ prettyType b where
  atom t@(Arrow _ _) = "(" ++ prettyType t ++ ")"
  atom t = prettyType t
prettyExpr :: Expr -> String
prettyExpr (Located _ e) = prettyExpr e
prettyExpr (TypeBound b t) = prettyType t ++ "." ++ b
prettyExpr (Var n) = n
prettyExpr (DecimalNumber c e) = prettyScalar (SDecimal c e)
prettyExpr (Number n) = show n
prettyExpr (StringLit s) = show s
prettyExpr value | Just (expression,_) <- selectionValidation value = prettyExpr expression
prettyExpr (Apply f x) = prettyExpr f ++ " (" ++ prettyExpr x ++ ")"
prettyExpr (Compose f g) = "(" ++ prettyExpr f ++ " . " ++ prettyExpr g ++ ")"

prettyExpr (ScalarLit s) = prettyScalar s
prettyExpr (ConstructLit name fields) = unwords (name : map ((\value -> "(" ++ prettyExpr value ++ ")")) fields)
prettyExpr (AllPayloadsExpr value predicates) = "allPayloads (" ++ prettyExpr value ++ ") [" ++ intercalate ", " [binder ++ " -> " ++ prettyExpr body | (binder,body) <- predicates] ++ "]"
prettyExpr (AllElementsExpr value binder predicate) = "allElements (" ++ prettyExpr value ++ ") (" ++ binder ++ " -> " ++ prettyExpr predicate ++ ")"
prettyExpr (MatchExpr value [MatchBranch tag [name] body]) | tag == letTag =
  "let " ++ name ++ " = " ++ prettyExpr value ++ " in " ++ prettyExpr body ++ " end let"
prettyExpr (MatchExpr value branches) = "first matching case of " ++ prettyExpr value ++ ": " ++ concat
  ["when " ++ unwords (tag:names) ++ " then " ++ prettyExpr body ++ " " | MatchBranch tag names body <- branches] ++ "end case"
prettyExpr (ListLit xs) = "[" ++ intercalate ", " (map prettyExpr xs) ++ "]"
prettyExpr (RecordLit fields) | Just values <- positionalItems fields = "(" ++ intercalate ", " (map prettyExpr values) ++ ")"
prettyExpr (RecordLit fields) = "record{" ++ intercalate ", "
  [label ++ " = " ++ prettyExpr value | (label,value) <- fields] ++ "}"
prettyExpr (Binary op a b) = "(" ++ prettyExpr a ++ " " ++ op ++ " " ++ prettyExpr b ++ ")"
prettyExpr (Unary op a) = op ++ "(" ++ prettyExpr a ++ ")"
prettyExpr (Annotate a t) = "(" ++ prettyExpr a ++ " :: " ++ prettyType t ++ ")"
prettyExpr (BoolLit b) = if b then "true" else "false"

-- | Arrows associate to the right: a -> b -> c has two scalar inputs.
functionType :: Type -> ([Type], Type)
functionType (Arrow a b) = let (args,result) = functionType b in (a:args,result)
functionType t = ([],t)

-- | Compatibility projection for single-conclusion clients. The assertion tree is
-- authoritative for compound laws; it preserves shared guards and their scope.
firstConclusion :: Assertion -> (Expr, Expr, [Expr])
firstConclusion (AssertEqual a b) = (a,b,[])
firstConclusion (AssertImplies g body) = let (a,b,gs) = firstConclusion body in (a,b,g:gs)
firstConclusion (AssertAll (a:_)) = firstConclusion a
firstConclusion (AssertAll []) = (BoolLit True,BoolLit True,[])
firstConclusion (AssertQuantified _ _ body) = firstConclusion body
firstConclusion (AssertNot body) = firstConclusion body

assertionInputs :: Assertion -> [Input]
assertionInputs (AssertQuantified _ input body) = input : assertionInputs body
assertionInputs (AssertNot body) = assertionInputs body
assertionInputs (AssertImplies _ body) = assertionInputs body
assertionInputs (AssertAll bodies) = concatMap assertionInputs bodies
assertionInputs _ = []

-- | Typed operations retain operand types and adapter conversions after specialization.
data TypedExpr = TypedExpr { expressionType :: Type, expression :: Expr, operands :: [TypedExpr], requiredConversion :: Maybe Type, typedCases :: [TypedCase] } deriving (Eq, Show, Generic)
instance ToJSON MatchBranch
instance ToJSON TypedCase
instance ToJSON TypedExpr
literalExpr :: Literal -> Expr
literalExpr (DecimalLiteral c e) = DecimalNumber c e
literalExpr (IntLiteral n) = Number n
literalExpr (TextLiteral s) = StringLit s
literalExpr (BoolLiteral b) = BoolLit b
literalExpr (ScalarLiteral s) = ScalarLit s
literalExpr (ConstructorLiteral name fields) = ConstructLit name (map literalExpr fields)
literalExpr (ListLiteral xs) = ListLit (map literalExpr xs)
literalExpr (RecordLiteral fields) = RecordLit [(label,literalExpr value) | (label,value) <- fields]
literalExpr (SetLiteral builder items) = Apply (Var builder) (ListLit (map literalExpr items))

-- Documentary example labels retain literal notation before name resolution.
-- Checked builders are an elaboration detail, not part of a table row label.
prettyLiteral :: Literal -> String
prettyLiteral literal = case literal of
  SetLiteral _ items -> "#S{" ++ intercalate ", " (map prettyLiteral items) ++ "}"
  ListLiteral items -> "[" ++ intercalate ", " (map prettyLiteral items) ++ "]"
  RecordLiteral fields | Just values <- positionalItems fields -> "(" ++ intercalate ", " (map prettyLiteral values) ++ ")"
  RecordLiteral fields -> "record{" ++ intercalate ", " [label ++ " = " ++ prettyLiteral value | (label,value) <- fields] ++ "}"
  ConstructorLiteral name fields -> unwords (name : map argument fields)
  _ -> prettyExpr (literalExpr literal)
  where
    argument value@(ConstructorLiteral _ (_:_)) = "(" ++ prettyLiteral value ++ ")"
    argument value = prettyLiteral value

containsSetLiteral :: Literal -> Bool
containsSetLiteral literal = case literal of
  SetLiteral _ _ -> True
  ListLiteral items -> any containsSetLiteral items
  ConstructorLiteral _ fields -> any containsSetLiteral fields
  RecordLiteral fields -> any (containsSetLiteral . snd) fields
  _ -> False

finiteScalar :: Type -> Bool
finiteScalar (Named n) = n `elem` ["Bool","Unit","Null","Undefined"]
finiteScalar (Applied n t) = n `elem` ["Nullable", "Optional"] && finiteScalar t
finiteScalar _ = False

replaceExprVars :: [(String, Expr)] -> Expr -> Expr
replaceExprVars = substituteExpr [] replaceTypeValueVars

-- | Traverse expressions and dependent annotations in one simultaneous
-- substitution. Processing their types in a second pass would substitute
-- dependencies introduced by the first pass a second time. Extra names are
-- dependencies introduced by the caller's type-variable substitutions.
substituteExpr :: [String] -> ([(String,Expr)] -> Type -> Type)
  -> [(String,Expr)] -> Expr -> Expr
substituteExpr extra onType env expression = case expression of
  Located range e -> Located range (go e)
  ConstructLit name fields -> ConstructLit name (map go fields)
  RecordLit fields -> RecordLit [(label,go value) | (label,value) <- fields]
  AllPayloadsExpr value predicates -> AllPayloadsExpr (go value)
    [bound binder body | (binder,body) <- predicates]
  AllElementsExpr value binder predicate ->
    let (name,body) = bound binder predicate
    in AllElementsExpr (go value) name body
  MatchExpr value branches -> MatchExpr (go value)
    [let active = filter ((`notElem` names) . fst) env
         forbidden = extra ++ concatMap (exprVars . snd) active
         used = names ++ exprVars body ++ forbidden ++ map fst env
         renamed = [(n, head ["_match_" ++ n ++ "_" ++ show i | i <- [0::Int ..],
                      ("_match_" ++ n ++ "_" ++ show i) `notElem` used]) | n <- names, n `elem` forbidden]
         names' = [maybe n id (lookup n renamed) | n <- names]
         body' = replaceExprVars [(n, Var fresh) | (n,fresh) <- renamed] body
     in MatchBranch tag names' (substituteExpr extra onType active body')
    | MatchBranch tag names body <- branches]
  ListLit xs -> ListLit (map go xs)
  Var n -> maybe (Var n) id (lookup n env)
  Apply f x -> Apply (go f) (go x)
  Compose f g -> Compose (go f) (go g)
  Binary op a b -> Binary op (go a) (go b)
  Unary op a -> Unary op (go a)
  Annotate a t -> Annotate (go a) (onType env t)
  TypeBound name t -> TypeBound name (onType env t)
  e -> e
  where
    go = substituteExpr extra onType env
    bound binder body =
      let active = filter ((/= binder) . fst) env
          forbidden = extra ++ concatMap (exprVars . snd) active
          used = exprVars body ++ forbidden ++ map fst env ++ [binder]
          fresh = head [binder ++ replicate i '_' | i <- [1..], binder ++ replicate i '_' `notElem` used]
          name = if binder `elem` forbidden then fresh else binder
          renamed = if name == binder then body else replaceExprVars [(binder,Var name)] body
      in (name,substituteExpr extra onType active renamed)

bridgeType :: TypedExpr -> Type
bridgeType e = maybe (expressionType e) id (requiredConversion e)

baseType :: Type -> Type
baseType (Refined _ t _) = baseType t
baseType (Qualified _ t) = baseType t
baseType (CheckedType _ t) = baseType t
baseType (Arrow a b) = Arrow (baseType a) (baseType b)
baseType (Applied n t) = Applied n (baseType t)
baseType (Application n ts) = Application n (map baseType ts)
-- Field restrictions form part of a structural product's identity and
-- constructor contract. Erasing an enclosing refinement must retain them.
baseType t@(RecordShape _) = t
baseType t = t

-- | Predicates are expressions over values; aliases never introduce storage wrappers.
typePredicates :: Expr -> Type -> [Expr]
typePredicates value (Refined n t p) = typePredicates value t ++ maybe [] (pure . replaceExprVars [(n,value)]) p
typePredicates value (Qualified _ t) = typePredicates value t
typePredicates value (CheckedType ps t) = ps ++ typePredicates value t
typePredicates value (Applied n t) | n `elem` ["Nullable","Optional"] =
  [Binary "||" (Unary "!" (Apply (Var "prelude.isPresent") value)) p | p <- typePredicates (Apply (Var "prelude.presentValue") value) t]
typePredicates value (Applied "List" inner) =
  let probe = "lawspecElement"
      free = exprVars value ++ concatMap exprVars (typePredicates (Var probe) inner)
      binder = head [probe ++ replicate n '_' | n <- [0..], probe ++ replicate n '_' `notElem` free]
      predicates = typePredicates (Var binder) inner
  in if null predicates then [] else
    [AllElementsExpr value binder (foldr (Binary "&&") (BoolLit True) predicates)]
typePredicates value (Applied "Maybe" inner) =
  sumPredicates value [("Maybe::Nothing",Nothing),("Maybe::Just",Just inner)]
typePredicates value (Application "Either" [left,right]) =
  sumPredicates value [("Either::Left",Just left),("Either::Right",Just right)]
typePredicates _ _ = []

-- | Sum payload constraints elaborate to ordinary exhaustive, lazy matches. The
-- fresh local cannot capture a dependency on a surrounding refinement binder.
sumPredicates :: Expr -> [(String,Maybe Type)] -> [Expr]
sumPredicates value variants = constructorPayloadPredicates value
  [(tag, maybe [] (pure . (,) "value") payload) | (tag,payload) <- variants]

-- | Compose ordered field constraints into an ordinary exhaustive match. Earlier
-- fields are in scope for later predicates; sibling constructors have separate
-- scopes. Declaration admission must reject duplicate or forward field names.
-- Fresh match binders must avoid free outer dependencies as well as field names.
constructorPredicates :: Expr -> [(String,[(String,Type)])] -> [Expr]
constructorPredicates = constructorPredicatesWith True

-- | A refinement supplied as a type argument keeps its caller's value scope.
-- Its free names must never be rebound to similarly named constructor fields.
constructorPayloadPredicates :: Expr -> [(String,[(String,Type)])] -> [Expr]
constructorPayloadPredicates = constructorPredicatesWith False

constructorPredicatesWith :: Bool -> Expr -> [(String,[(String,Type)])] -> [Expr]
constructorPredicatesWith dependentFields value variants =
  let probe = "lawspecElement"
      free = exprVars value ++ concat
        [name : concatMap exprVars (typePredicates (Var probe) ty)
        | (_,fields) <- variants, (name,ty) <- fields]
      fresh = filter (`notElem` free) [probe ++ replicate n '_' | n <- [0..]]
      branch (tag,fields) =
        let names = take (length fields) fresh
            predicates = concat
              [map (replaceExprVars (if dependentFields then
                  zip (map fst (take index fields)) (map Var names) else []))
                (typePredicates (Var binder) ty)
              | (index,((_,ty),binder)) <- zip [0..] (zip fields names)]
        in (MatchBranch tag names (foldr (Binary "&&") (BoolLit True) predicates),
            null predicates)
      branches = map branch variants
  in if all snd branches then [] else [MatchExpr value (map fst branches)]

typeConstraints :: Type -> [Constraint]
typeConstraints (Qualified cs t) = cs ++ typeConstraints t
typeConstraints (CheckedType _ t) = typeConstraints t
typeConstraints (Refined _ t _) = typeConstraints t
typeConstraints (Applied _ t) = typeConstraints t
typeConstraints (Application _ ts) = concatMap typeConstraints ts
typeConstraints (RecordShape fields) = concatMap (typeConstraints . recordFieldType) fields
typeConstraints (Arrow a b) = typeConstraints a ++ typeConstraints b
typeConstraints _ = []

mapType :: (Type -> Type) -> (Expr -> Expr) -> Type -> Type
mapType f g = walk where
  walk (Arrow a b) = f (Arrow (walk a) (walk b))
  walk (Applied n t) = f (Applied n (walk t))
  walk (Application n ts) = f (Application n (map walk ts))
  walk record@(RecordShape fields) = f (withRecordFields record [field{recordFieldType=walk (recordFieldType field)} | field <- fields])
  walk (Refined n t p) = f (Refined n (walk t) (g <$> p))
  walk (CheckedType ps t) = f (CheckedType (map g ps) (walk t))
  walk (Qualified cs t) = f (Qualified [Capability n (walk a) | Capability n a <- cs] (walk t))
  walk (RefinementApp n args) = f (RefinementApp n [case a of TypeArgument t -> TypeArgument (walk t); ValueArgument e -> ValueArgument (g e) | a <- args])
  walk t = f t

mapExprTypes :: (Type -> Type) -> Expr -> Expr
mapExprTypes f e = case e of
  Located range a -> Located range (go a)
  Annotate a t -> Annotate (go a) (f t)
  TypeBound b t -> TypeBound b (f t)
  ConstructLit name fields -> ConstructLit name (map go fields)
  RecordLit fields -> RecordLit [(label,go value) | (label,value) <- fields]
  AllPayloadsExpr value predicates -> AllPayloadsExpr (go value) [(binder,go body) | (binder,body) <- predicates]
  AllElementsExpr value binder predicate -> AllElementsExpr (go value) binder (go predicate)
  MatchExpr value branches -> MatchExpr (go value) [MatchBranch tag names (go body) | MatchBranch tag names body <- branches]
  ListLit xs -> ListLit (map go xs)
  Apply a b -> Apply (go a) (go b)
  Compose a b -> Compose (go a) (go b)
  Binary op a b -> Binary op (go a) (go b)
  Unary op a -> Unary op (go a)
  _ -> e
  where go = mapExprTypes f

exprVars :: Expr -> [String]
exprVars (Located _ e) = exprVars e
exprVars (Var n) = [n]
exprVars (ConstructLit _ fields) = concatMap exprVars fields
exprVars (RecordLit fields) = concatMap (exprVars . snd) fields
exprVars (AllPayloadsExpr value predicates) = exprVars value ++ concat [filter (/= binder) (exprVars body) | (binder,body) <- predicates]
exprVars (AllElementsExpr value binder predicate) = exprVars value ++ filter (/= binder) (exprVars predicate)
exprVars (MatchExpr value branches) = exprVars value ++ concat
  [[n | n <- exprVars body, n `notElem` names] | MatchBranch _ names body <- branches]
exprVars (ListLit xs) = concatMap exprVars xs
exprVars (Apply a b) = exprVars a ++ exprVars b
exprVars (Compose a b) = exprVars a ++ exprVars b
exprVars (Binary _ a b) = exprVars a ++ exprVars b
exprVars (Unary _ a) = exprVars a
exprVars (Annotate a ty) = exprVars a ++ typeValueVars ty
exprVars (TypeBound _ ty) = typeValueVars ty
exprVars _ = []

-- | Free value dependencies of a type, including annotations inside predicates.
-- Type variables belong to a separate namespace and are deliberately absent.
typeValueVars :: Type -> [String]
typeValueVars ty = case ty of
  Arrow a b -> typeValueVars a ++ typeValueVars b
  Applied _ a -> typeValueVars a
  Application _ arguments -> concatMap typeValueVars arguments
  Refined binder inner predicate -> typeValueVars inner ++
    filter (/= binder) (maybe [] exprVars predicate)
  CheckedType predicates inner -> concatMap exprVars predicates ++ typeValueVars inner
  Qualified constraints inner -> concat [typeValueVars t | Capability _ t <- constraints] ++ typeValueVars inner
  RefinementApp _ arguments -> concat [case argument of
    TypeArgument t -> typeValueVars t
    ValueArgument e -> exprVars e | argument <- arguments]
  RecordShape fields -> fieldsFree [] fields
  _ -> []
  where
    fieldsFree _ [] = []
    fieldsFree bound (field:rest) =
      let scope = recordFieldBinding field : bound
      in filter (`notElem` scope) (typeValueVars (recordFieldType field)) ++ fieldsFree scope rest

-- | Substitute value dependencies without capturing a refinement or field
-- binder. Public field labels and declaration order never change.
replaceTypeValueVars :: [(String,Expr)] -> Type -> Type
replaceTypeValueVars env ty = case ty of
  Arrow a b -> Arrow (go a) (go b)
  Applied name a -> Applied name (go a)
  Application name arguments -> Application name (map go arguments)
  record@(RecordShape fields) -> withRecordFields record (scopeRecordFields [] env replaceTypeValueVars fields)
  Refined binder inner predicate -> case predicate of
    Nothing -> Refined binder (go inner) Nothing
    Just body -> let (name,body') = replaceBoundExpr env binder body
                 in Refined name (go inner) (Just body')
  CheckedType predicates inner -> CheckedType (map (replaceExprVars env) predicates) (go inner)
  Qualified constraints inner -> Qualified [Capability name (go t) | Capability name t <- constraints] (go inner)
  RefinementApp name arguments -> RefinementApp name [case argument of
    TypeArgument t -> TypeArgument (go t)
    ValueArgument e -> ValueArgument (replaceExprVars env e) | argument <- arguments]
  _ -> ty
  where go = replaceTypeValueVars env

-- | Shared left-to-right field scope for value and type substitution. The
-- extra names are free dependencies introduced by replacement types. The
-- transformation receives only substitutions still active at this field.
scopeRecordFields :: [String] -> [(String,Expr)]
  -> ([(String,Expr)] -> Type -> Type) -> [RecordField] -> [RecordField]
scopeRecordFields extra env transform fields = walk used env [] fields
  where
    used = extra ++ map fst env ++ concatMap (exprVars . snd) env ++
      concat [[recordFieldLabel field,recordFieldBinding field] ++ typeValueVars (recordFieldType field) | field <- fields]
    walk _ _ _ [] = []
    walk taken active renamed (field:rest) =
      let binder = recordFieldBinding field
          active' = filter ((/= binder) . fst) active
          forbidden = extra ++ concatMap (exprVars . snd) active'
          fresh = head ["_record_" ++ binder ++ "_" ++ show i | i <- [0 :: Int ..],
            ("_record_" ++ binder ++ "_" ++ show i) `notElem` taken]
          name = if binder `elem` forbidden then fresh else binder
          renamed' = (binder,Var name) : filter ((/= binder) . fst) renamed
          ty' = transform active' (replaceTypeValueVars renamed' (recordFieldType field))
      in field{recordFieldBinding=name,recordFieldType=ty'} :
        walk (name:taken) active' renamed' rest

-- | Source wrappers survive renaming and substitution. Consumers that only inspect
-- syntax may discard wrappers explicitly; elaboration retains their real ranges.
unlocated :: Expr -> Expr
unlocated (Located _ e) = unlocated e
unlocated e = e
stripLocations :: Expr -> Expr
stripLocations e = case unlocated e of
  ConstructLit name fields -> ConstructLit name (map go fields)
  RecordLit fields -> RecordLit [(label,go value) | (label,value) <- fields]
  AllPayloadsExpr value predicates -> AllPayloadsExpr (go value) [(binder,go body) | (binder,body) <- predicates]
  AllElementsExpr value binder predicate -> AllElementsExpr (go value) binder (go predicate)
  MatchExpr value branches -> MatchExpr (go value) [MatchBranch tag names (go body) | MatchBranch tag names body <- branches]
  ListLit xs -> ListLit (map go xs)
  Apply a b -> Apply (go a) (go b)
  Compose a b -> Compose (go a) (go b)
  Binary op a b -> Binary op (go a) (go b)
  Unary op a -> Unary op (go a)
  Annotate a t -> Annotate (go a) t
  a -> a
  where go = stripLocations

-- | Each payload callback has its own lexical scope, including when two callbacks
-- use the same source spelling for their binders.
replaceBoundExpr :: [(String,Expr)] -> String -> Expr -> (String,Expr)
replaceBoundExpr env binder predicate =
  let active = filter ((/= binder) . fst) env
      forbidden = concatMap (exprVars . snd) active
      used = exprVars predicate ++ forbidden ++ map fst env ++ [binder]
      fresh = head [binder ++ replicate i '_' | i <- [1..], binder ++ replicate i '_' `notElem` used]
      name = if binder `elem` forbidden then fresh else binder
      body = if name == binder then predicate else replaceExprVars [(binder,Var name)] predicate
  in (name,replaceExprVars active body)

-- | Type parameters throughout types and their expression annotations.
typeVariableNames :: Type -> [String]
typeVariableNames ty = nub $ case ty of
  Variable name -> [name]
  Arrow a b -> typeVariableNames a ++ typeVariableNames b
  Applied _ a -> typeVariableNames a
  Application _ arguments -> concatMap typeVariableNames arguments
  RecordShape fields -> concatMap (typeVariableNames . recordFieldType) fields
  Refined _ inner predicate -> typeVariableNames inner ++ maybe [] expressionVariables predicate
  Qualified constraints inner -> typeVariableNames inner ++ concat [typeVariableNames t | Capability _ t <- constraints]
  CheckedType predicates inner -> typeVariableNames inner ++ concatMap expressionVariables predicates
  RefinementApp _ arguments -> concat [case argument of
    TypeArgument t -> typeVariableNames t
    ValueArgument e -> expressionVariables e | argument <- arguments]
  _ -> []
  where
    expressionVariables expression = case expression of
      Located _ e -> expressionVariables e
      Annotate e t -> expressionVariables e ++ typeVariableNames t
      TypeBound _ t -> typeVariableNames t
      Apply a b -> expressionVariables a ++ expressionVariables b
      Compose a b -> expressionVariables a ++ expressionVariables b
      Binary _ a b -> expressionVariables a ++ expressionVariables b
      Unary _ a -> expressionVariables a
      ListLit values -> concatMap expressionVariables values
      RecordLit fields -> concatMap (expressionVariables . snd) fields
      ConstructLit _ values -> concatMap expressionVariables values
      MatchExpr value branches -> expressionVariables value ++ concat [expressionVariables body | MatchBranch _ _ body <- branches]
      AllElementsExpr value _ predicate -> expressionVariables value ++ expressionVariables predicate
      AllPayloadsExpr value predicates -> expressionVariables value ++ concatMap (expressionVariables . snd) predicates
      _ -> []

