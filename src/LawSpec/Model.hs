module LawSpec.Model (module LawSpec.Model, module LawSpec.Common) where

import LawSpec.Core.Policy (StagePolicy)
import LawSpec.Core.Machine (Machine, Supervisor)
import LawSpec.Common

import Data.Aeson hiding (Number)
import LawSpec.Scalar
import LawSpec.IndexTerm (FamilyIndex)
import GHC.Generics (Generic)
import Data.List (intercalate)

data Type = Named String | Variable String | Arrow Type Type | Applied String Type | Application String [Type] | Refined String Type (Maybe Expr) | RefinementApp String [RefinementArgument] | Qualified [Constraint] Type | CheckedType [Expr] Type deriving (Eq, Show, Generic)
data Expr = Located Span Expr | Var String | Apply Expr Expr | Compose Expr Expr | Number Integer | DecimalNumber Integer Integer | StringLit String | BoolLit Bool | ScalarLit Scalar | ListLit [Expr] | ConstructLit String [Expr] | MatchExpr Expr [MatchBranch] | AllElementsExpr Expr String Expr | AllPayloadsExpr Expr [(String, Expr)] | Binary String Expr Expr | Unary String Expr | Annotate Expr Type | TypeBound String Type deriving (Eq, Show, Generic)
data MatchBranch = MatchBranch String [String] Expr deriving (Eq, Show, Generic)
data TypedCase = TypedCase String [(String,Type)] TypedExpr deriving (Eq, Show, Generic)
data Definition = Forall [(String, Type)] Definition | Equal Expr Expr | Holds Expr | Implies Expr Definition | And Definition Definition | Invoke String [Expr] deriving (Eq, Show, Generic)
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

data Literal = IntLiteral Integer | DecimalLiteral Integer Integer | TextLiteral String | BoolLiteral Bool | ScalarLiteral Scalar | ListLiteral [Literal] | ConstructorLiteral String [Literal] deriving (Eq, Show, Generic)
instance ToJSON Literal where
  toJSON (DecimalLiteral c e) = toJSON (SDecimal c e)
  toJSON (IntLiteral n) = toJSON (SInteger "BigInt" n)
  toJSON (TextLiteral s) = toJSON (textScalar s)
  toJSON (BoolLiteral b) = toJSON (SBool b)
  toJSON (ScalarLiteral s) = toJSON s
  toJSON (ConstructorLiteral name fields) = object ["constructor" .= name, "fields" .= fields]
  toJSON (ListLiteral xs) = object ["list" .= xs]

data Expectation = Expectation { actual :: Expr, expected :: Literal } deriving (Eq, Show, Generic)
instance ToJSON Expectation

data Example = Example { exampleName :: String, bindings :: [(String, Literal)], expectations :: [Expectation] } deriving (Eq, Show, Generic)
data Law = Law { lawName :: String, parameters :: [(String, Type)], requirements :: [Constraint], definition :: Definition, description :: String, rationale :: String, examples :: [Example], references :: [String], location :: Location } deriving (Eq, Show, Generic)
data DataTypeDeclaration = DataTypeDeclaration
  { dataTypeName :: String, dataTypeParameters :: [String]
  , dataTypeConstructors :: [ConstructorDeclaration], dataTypeSpan :: Span
  , dataTypeIndex :: Maybe FamilyIndex
  } deriving (Eq, Show, Generic)
-- A GADT constructor refines type parameters: `where a = Int32` makes it a
-- value of T Int32 only. Free variables of a refinement or a field that are not
-- parameters are the constructor's existential types.
data ConstructorDeclaration = ConstructorDeclaration
  { dataConstructorName :: String, dataConstructorFields :: [(String,Type)]
  , dataConstructorSpan :: Span
  , dataConstructorEquations :: [(String,Type)]
  } deriving (Eq, Show, Generic)
-- import shop.money [as money] [(Amount, add, `associative`)]: qualified
-- access through the alias, plus unqualified access to the listed names. Law
-- names are listed with their backticks.
data Import = Import
  { importUnit :: String, importAlias :: String
  , importItems :: [String], importSpan :: Span
  } deriving (Eq, Show, Generic)
data FunctionDefinition = FunctionDefinition
  { functionName :: String, functionArguments :: [(String, Type)]
  , functionResult :: Type, functionRequirements :: [Constraint]
  , functionBody :: Expr, functionSpan :: Span
  } deriving (Eq, Show, Generic)
-- asyncFunctions names the adapters declared `async`: their results arrive
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
  -- Stub until resources arrive: each resource the unit declares, and
  -- whether it declares `reset` (only those may be shared by a harness).
  , resourceStubs :: [(String, Bool, Span)] } deriving (Eq, Show, Generic)

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
  , planGroup :: Maybe String }
  deriving (Eq, Show, Generic)

-- ability Name (a :: Type)* is (op :: Type)* [laws law*] end. Operations are
-- written like signatures; the laws are obligations on every handler.
data AbilityDeclaration = AbilityDeclaration
  { abilityName :: String, abilityParameters :: [String]
  , abilityOperations :: [(String, Type)], abilityLaws :: [Law], abilitySpan :: Span }
  deriving (Eq, Show, Generic)

-- handler name for Ability [with state s :: S start e] is clause* end. A
-- clause is `op x y is body end`; in a handler with state, the body may
-- update it with `~s := e;` before giving the result.
data HandlerDeclaration = HandlerDeclaration
  { handlerName :: String, handlerAbility :: Type
  , handlerState :: Maybe (String, Type, Expr)
  , handlerClauses :: [HandlerClause], handlerSpan :: Span }
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

-- The built-in failure ability: `fails with E` is `uses Fail E`.
failAbilityName :: String
failAbilityName = "Fail"

-- An ability's name, without its type arguments.
abilityTypeName :: Type -> String
abilityTypeName t = case t of
  Named n -> n
  Applied n _ -> n
  Application n _ -> n
  _ -> prettyType t

-- The names of a unit's ability operations.
operationNames :: Unit -> [String]
operationNames u = [op | a <- abilities u, (op, _) <- abilityOperations a]

-- A protocol: what one end of a channel sends and receives, in order (see
-- LawSpec.Scenario).
data Step = Send Type | Receive Type
  deriving (Eq, Show, Generic)

data Protocol = Protocol
  { protocolName :: String, protocolSteps :: [Step], protocolSpan :: Span }
  deriving (Eq, Show, Generic)
data Input = Input { inputName :: String, inputId :: String, inputType :: Type, inputRefinements :: [Expr] } deriving (Eq, Show, Generic)
data Assertion = AssertEqual Expr Expr | AssertImplies Expr Assertion | AssertAll [Assertion] deriving (Eq, Show, Generic)
instance ToJSON Assertion

data Expanded = Expanded { owner :: String, name :: String, inputs :: [Input], left :: Expr, right :: Expr, guards :: [Expr], assertion :: Assertion, trace :: [String], original :: Law, typedExpressions :: [TypedExpr], propertyKind :: String, generation :: Generation, generationPlan :: [DomainPlan], refinementArgumentChecks :: [Expr] } deriving (Eq, Show, Generic)
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
prettyExpr (Apply f x) = prettyExpr f ++ " (" ++ prettyExpr x ++ ")"
prettyExpr (Compose f g) = "(" ++ prettyExpr f ++ " . " ++ prettyExpr g ++ ")"

prettyExpr (ScalarLit s) = prettyScalar s
prettyExpr (ConstructLit name fields) = unwords (name : map ((\value -> "(" ++ prettyExpr value ++ ")")) fields)
prettyExpr (AllPayloadsExpr value predicates) = "allPayloads (" ++ prettyExpr value ++ ") [" ++ intercalate ", " [binder ++ " -> " ++ prettyExpr body | (binder,body) <- predicates] ++ "]"
prettyExpr (AllElementsExpr value binder predicate) = "allElements (" ++ prettyExpr value ++ ") (" ++ binder ++ " -> " ++ prettyExpr predicate ++ ")"
prettyExpr (MatchExpr value branches) = "match " ++ prettyExpr value ++ " with " ++ concat
  ["| " ++ unwords (tag:names) ++ " -> " ++ prettyExpr body ++ " " | MatchBranch tag names body <- branches] ++ "end"
prettyExpr (ListLit xs) = "[" ++ intercalate ", " (map prettyExpr xs) ++ "]"
prettyExpr (Binary op a b) = "(" ++ prettyExpr a ++ " " ++ op ++ " " ++ prettyExpr b ++ ")"
prettyExpr (Unary op a) = op ++ "(" ++ prettyExpr a ++ ")"
prettyExpr (Annotate a t) = "(" ++ prettyExpr a ++ " :: " ++ prettyType t ++ ")"
prettyExpr (BoolLit b) = if b then "true" else "false"

-- Arrows associate to the right: a -> b -> c has two scalar inputs.
functionType :: Type -> ([Type], Type)
functionType (Arrow a b) = let (args,result) = functionType b in (a:args,result)
functionType t = ([],t)

-- Compatibility projection for single-conclusion clients. The assertion tree is
-- authoritative for compound laws; it preserves shared guards and their scope.
firstConclusion :: Assertion -> (Expr, Expr, [Expr])
firstConclusion (AssertEqual a b) = (a,b,[])
firstConclusion (AssertImplies g body) = let (a,b,gs) = firstConclusion body in (a,b,g:gs)
firstConclusion (AssertAll (a:_)) = firstConclusion a
firstConclusion (AssertAll []) = (BoolLit True,BoolLit True,[])

-- Typed operations retain operand types and adapter conversions after specialization.
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

finiteScalar :: Type -> Bool
finiteScalar (Named n) = n `elem` ["Bool","Unit","Null","Undefined"]
finiteScalar (Applied n t) = n `elem` ["Nullable", "Optional"] && finiteScalar t
finiteScalar _ = False

replaceExprVars :: [(String, Expr)] -> Expr -> Expr
replaceExprVars env (Located range e) = Located range (replaceExprVars env e)
replaceExprVars env (ConstructLit name fields) = ConstructLit name (map (replaceExprVars env) fields)
replaceExprVars env (AllPayloadsExpr value predicates) = AllPayloadsExpr (replaceExprVars env value)
  [replaceBoundExpr env binder body | (binder,body) <- predicates]
replaceExprVars env (AllElementsExpr value binder predicate) =
  let (name,body) = replaceBoundExpr env binder predicate
  in AllElementsExpr (replaceExprVars env value) name body
replaceExprVars env (MatchExpr value branches) = MatchExpr (replaceExprVars env value)
  [let active = filter ((`notElem` names) . fst) env
       forbidden = concatMap (exprVars . snd) active
       used = names ++ exprVars body ++ forbidden ++ map fst env
       renamed = [(n, head ["_match_" ++ n ++ "_" ++ show i | i <- [0::Int ..],
                    ("_match_" ++ n ++ "_" ++ show i) `notElem` used]) | n <- names, n `elem` forbidden]
       names' = [maybe n id (lookup n renamed) | n <- names]
       body' = replaceExprVars [(n, Var fresh) | (n,fresh) <- renamed] body
   in MatchBranch tag names' (replaceExprVars active body')
  | MatchBranch tag names body <- branches]
replaceExprVars env (ListLit xs) = ListLit (map (replaceExprVars env) xs)
replaceExprVars env (Var n) = maybe (Var n) id (lookup n env)
replaceExprVars env (Apply f x) = Apply (replaceExprVars env f) (replaceExprVars env x)
replaceExprVars env (Compose f g) = Compose (replaceExprVars env f) (replaceExprVars env g)
replaceExprVars env (Binary op a b) = Binary op (replaceExprVars env a) (replaceExprVars env b)
replaceExprVars env (Unary op a) = Unary op (replaceExprVars env a)
replaceExprVars env (Annotate a t) = Annotate (replaceExprVars env a) t
replaceExprVars _ e = e

bridgeType :: TypedExpr -> Type
bridgeType e = maybe (expressionType e) id (requiredConversion e)

baseType :: Type -> Type
baseType (Refined _ t _) = baseType t
baseType (Qualified _ t) = baseType t
baseType (CheckedType _ t) = baseType t
baseType (Arrow a b) = Arrow (baseType a) (baseType b)
baseType (Applied n t) = Applied n (baseType t)
baseType (Application n ts) = Application n (map baseType ts)
baseType t = t

-- Predicates are expressions over values; aliases never introduce storage wrappers.
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

-- Sum payload constraints elaborate to ordinary exhaustive, lazy matches. The
-- fresh local cannot capture a dependency on a surrounding refinement binder.
sumPredicates :: Expr -> [(String,Maybe Type)] -> [Expr]
sumPredicates value variants = constructorPayloadPredicates value
  [(tag, maybe [] (pure . (,) "value") payload) | (tag,payload) <- variants]

-- Compose ordered field constraints into an ordinary exhaustive match. Earlier
-- fields are in scope for later predicates; sibling constructors have separate
-- scopes. Declaration admission must reject duplicate or forward field names.
-- Fresh match binders must avoid free outer dependencies as well as field names.
constructorPredicates :: Expr -> [(String,[(String,Type)])] -> [Expr]
constructorPredicates = constructorPredicatesWith True

-- A refinement supplied as a type argument keeps its caller's value scope.
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
typeConstraints (Arrow a b) = typeConstraints a ++ typeConstraints b
typeConstraints _ = []

mapType :: (Type -> Type) -> (Expr -> Expr) -> Type -> Type
mapType f g = walk where
  walk (Arrow a b) = f (Arrow (walk a) (walk b))
  walk (Applied n t) = f (Applied n (walk t))
  walk (Application n ts) = f (Application n (map walk ts))
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
exprVars (AllPayloadsExpr value predicates) = exprVars value ++ concat [filter (/= binder) (exprVars body) | (binder,body) <- predicates]
exprVars (AllElementsExpr value binder predicate) = exprVars value ++ filter (/= binder) (exprVars predicate)
exprVars (MatchExpr value branches) = exprVars value ++ concat
  [[n | n <- exprVars body, n `notElem` names] | MatchBranch _ names body <- branches]
exprVars (ListLit xs) = concatMap exprVars xs
exprVars (Apply a b) = exprVars a ++ exprVars b
exprVars (Compose a b) = exprVars a ++ exprVars b
exprVars (Binary _ a b) = exprVars a ++ exprVars b
exprVars (Unary _ a) = exprVars a
exprVars (Annotate a _) = exprVars a
exprVars _ = []

-- Source wrappers survive renaming and substitution. Consumers that only inspect
-- syntax may discard wrappers explicitly; elaboration retains their real ranges.
unlocated :: Expr -> Expr
unlocated (Located _ e) = unlocated e
unlocated e = e
stripLocations :: Expr -> Expr
stripLocations e = case unlocated e of
  ConstructLit name fields -> ConstructLit name (map go fields)
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

-- Each payload callback has its own lexical scope, including when two callbacks
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
