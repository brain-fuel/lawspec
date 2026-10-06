{-# LANGUAGE PatternSynonyms #-}
-- | Authoritative typed terms shared by evaluators and backends. This module has
-- no dependency on the surface syntax, inference, or a testing framework.
module LawSpec.Core where

import LawSpec.Core.Policy (StagePolicy)
import LawSpec.Core.Machine (Machine, Supervisor)
import GHC.Generics (Generic)
import LawSpec.IndexTerm (FamilyIndex(..))
import LawSpec.Common
import LawSpec.Scalar (Scalar)

-- | Core names everything by a resolved identity rather than by its spelling, so
-- two units' declarations of the same name never meet and an emitter never
-- resolves a name again. ref:DEC-typed-core-boundary
newtype Id = Id { idText :: String } deriving (Eq, Ord, Show, Generic)
-- | Type parameters of indexed families take values as well as types, so Core
-- records which a parameter expects. ref:DEC-indexed-families-as-evidence
data Kind = ValueKind | TypeKind | KindArrow Kind Kind deriving (Eq, Show, Generic)
-- | One type language for every target: a constructor applied to type and index
-- arguments, a variable, or a function. Targets map it, they never extend it.
-- ref:DEC-typed-core-boundary
data Type = Constructor String [Argument] | TypeVariable Id | Arrow Type Type deriving (Eq, Ord, Show, Generic)
-- | A type may be indexed by a value as well as a type, as Vec n a is, so an
-- argument is either. ref:DEC-indexed-families-as-evidence
data Argument = TypeArgument Type | IndexArgument Index deriving (Eq, Ord, Show, Generic)
-- | Indices are natural numbers or variables only; richer index arithmetic is
-- elaborated into these before Core. ref:DEC-gadts-and-index-arithmetic
data Index = Natural Integer | IndexVariable Id deriving (Eq, Ord, Show, Generic)
-- | Most types in generated code are primitives with no arguments.
scalarType :: String -> Type
scalarType n = Constructor n []
-- | Core types are curried, while every target declares an adapter with all its
-- arguments at once, so emitters need the arguments and result apart.
functionType :: Type -> ([Type], Type)
functionType (Arrow a b) = let (as,r) = functionType b in (a:as,r)
functionType t = ([],t)

-- | A bound variable keeps both its resolved identity, for evaluation, and its
-- written name, so generated code and messages use what the user wrote.
data Binder = Binder { binderId :: Id, binderName :: String, binderType :: Type } deriving (Eq, Show, Generic)
-- | An async declaration is an adapter whose result arrives later, as each
-- target's task; Declaration builds a synchronous one.
data Declaration = MkDeclaration { declarationId :: Id, declarationName :: String, declarationType :: Type, declarationOrigin :: Origin, declarationAsync :: Bool } deriving (Eq, Show, Generic)
pattern Declaration :: Id -> String -> Type -> Origin -> Declaration
pattern Declaration identity name ty origin <- MkDeclaration identity name ty origin _
  where Declaration identity name ty origin = MkDeclaration identity name ty origin False
{-# COMPLETE Declaration #-}
-- | A definition supplies a checked body rather than a user-owned adapter.
-- Calls retain resolved declaration identities; the total-definition audit
-- determines which declaration bodies may be invoked within this closed set.
-- An orchestration is a definition that may call adapters: a workflow, whose
-- composition LawSpec generates. It is run natively, never evaluated by the
-- compiler. Definition builds an ordinary one.
data Definition = MkDefinition
  { definitionDeclaration :: Declaration, definitionArguments :: [Binder]
  , definitionBody :: Expr, definitionOrchestrates :: Bool
  -- A workflow stage's policies, which the target's workflow runtime applies.
  , definitionPolicy :: Maybe (StagePolicy Id)
  } deriving (Eq, Show, Generic)
pattern Definition :: Declaration -> [Binder] -> Expr -> Definition
pattern Definition declaration arguments body <- MkDefinition declaration arguments body _ _
  where Definition declaration arguments body = MkDefinition declaration arguments body False Nothing
{-# COMPLETE Definition #-}
-- | Products are single-constructor declarations; sums retain the identity of
-- each constructor even when their payloads have identical representations.
data DataDeclaration = MkDataDeclaration
  { dataId :: Id, dataName :: String, dataParameters :: [Id]
  , dataConstructors :: [DataConstructor], dataOrigin :: Origin
  -- An indexed family's erased index table, keyed by constructor identity.
  , dataIndex :: Maybe FamilyIndex
  -- A handle: a type whose values only adapters create. LawSpec passes them
  -- along unopened; it never generates, builds or inspects one, and two are
  -- equal only when they are the same value.
  , dataHandle :: Bool
  -- A bound handle's native type, written for the target being emitted
  -- (set from the target's type binding when it names the type in full).
  , dataNative :: Maybe String
  } deriving (Eq, Show, Generic)
pattern DataDeclaration :: Id -> String -> [Id] -> [DataConstructor] -> Origin -> Maybe FamilyIndex -> DataDeclaration
pattern DataDeclaration identity name parameters constructors origin index <- MkDataDeclaration identity name parameters constructors origin index _ _
  where DataDeclaration identity name parameters constructors origin index = MkDataDeclaration identity name parameters constructors origin index False Nothing
{-# COMPLETE DataDeclaration #-}
-- | A GADT constructor's equations fix declaration parameters to types over its
-- existentials: a value of T args uses the constructor only where each
-- equation matches its argument, which also determines the existentials.
data DataConstructor = DataConstructor
  { constructorId :: Id, constructorName :: String
  , constructorFields :: [Binder], constructorPredicates :: [Expr]
  , constructorOrigin :: Origin
  , constructorEquations :: [(Id, Type)]
  , constructorExistentials :: [Id]
  } deriving (Eq, Show, Generic)
-- | Synthetic nodes explicitly have no source span; elaboration never fabricates
-- expression ranges from the containing law's location.
data Origin = SourceSpan Span | GeneratedFrom Id deriving (Eq, Show, Generic)
-- | Every expression carries its type and origin, so an emitter never infers a
-- type and every diagnostic can point at source. ref:DEC-typed-core-boundary
data Expr = Expr { expressionType :: Type, expressionNode :: Node, expressionOrigin :: Origin } deriving (Eq, Show, Generic)
-- | The closed set of operations a law or definition may perform; each target
-- must implement every one, so the set grows only through the front end.
-- ref:DEC-elaborate-before-core
data Node
  = Constant Scalar
  | Construct Id [Expr]
  | Match Expr [MatchCase]
  | AllElements Expr Binder Expr
  | AllPayloads Expr [(Binder, Expr)]
  | Local Id
  | ExternalCall Id [Expr]
  | Binary BinaryOp Evidence Expr Expr
  | Unary UnaryOp Expr
  | ShortCircuit LogicalOp Expr Expr
  -- if c then a else b: only the branch c selects is evaluated.
  | If Expr Expr Expr
  | Convert Conversion Type Expr
  | Helper Builtin [Expr]
  deriving (Eq, Show, Generic)
-- | A match names the constructor by identity, so sums whose payloads look alike
-- are still told apart.
data MatchCase = MatchCase
  { caseConstructor :: Id, caseBinders :: [Binder], caseBody :: Expr
  } deriving (Eq, Show, Generic)

-- | Arithmetic and comparison are Core operations, not calls to a target's
-- operators, because their meaning must be LawSpec's on every target.
-- ref:DEC-portable-exact-arithmetic
data BinaryOp = Add | Subtract | Multiply | Divide | Quotient | Remainder | Power
  | Equal | NotEqual | Less | LessEqual | Greater | GreaterEqual deriving (Eq, Show, Generic)
-- | As for BinaryOp, negation and not have LawSpec's meaning on every target.
data UnaryOp = Negate | Not deriving (Eq, Show, Generic)
-- | And and or short-circuit, so a guard can protect the operand after it on
-- every target alike.
data LogicalOp = And | Or deriving (Eq, Show, Generic)
-- | A conversion records whether the user wrote it or the compiler inserted it
-- to check an argument, so diagnostics blame the right place.
data Conversion = Explicit | CheckedArgument deriving (Eq, Show, Generic)
-- | Evidence fixes the arithmetic domain before code generation. Backends must
-- neither choose a promotion nor infer a capability from surface syntax.
data Evidence = Numeric Type | Structural Type deriving (Eq, Show, Generic)
-- | Operations every runtime must provide with identical semantics, such as IEEE
-- classification and half-even rounding, rather than leave to each language's
-- library. ref:ieee-754
data Builtin = Length | IsPresent | PresentValue | RealPart | ImaginaryPart
  | IsNaN | IsInfinite | IsFinite | IsNegativeZero | RoundHalfEven | Checked | Compare | Select
  -- A branch the indices rule out: the totality audit proves it is never
  -- reached; reaching it anyway fails.
  | Unreachable
  -- concurrently (C a b ...) is C a b ...; matched at once, as an all
  -- group's steps are, its fields are evaluated at the same time.
  | Concurrently deriving (Eq, Show, Generic)
-- | What a law asserts: equations, implications and conjunctions, each equation
-- with the evidence of how its sides are compared.
data Proposition = Equation Evidence Expr Expr | Implication Expr Proposition | Conjunction [Proposition] deriving (Eq, Show, Generic)
-- | A quantified input carries its refinements and bounds, so generation draws
-- only values inside the domain instead of filtering most away.
-- ref:DEC-shrink-within-domain
data Quantifier = Quantifier { quantifiedBinder :: Binder, quantifiedPredicates :: [Expr], quantifiedBounds :: [(BinaryOp,Expr)] } deriving (Eq, Show, Generic)
-- | Examples pin a law to concrete expected values, so a law that is true of a
-- wrong implementation still fails. ref:DEC-examples-pin-laws
data Example = Example { exampleName :: String, exampleBindings :: [(Id,Expr)], exampleExpectations :: [Proposition] } deriving (Eq, Show, Generic)
-- | A definition's runtime postconditions are claims the prover could not
-- establish because they involve non-linear index arithmetic; each result is
-- checked against them instead.
data Contract = Contract { contractDeclaration :: Id, contractArguments :: [Binder], contractResult :: Binder, contractPreconditions :: [Expr], contractPostconditions :: [Expr], contractRuntimePostconditions :: [Expr] } deriving (Eq, Show, Generic)
-- | A law or contract as the tests need it, with the description, rationale,
-- references and expansion trace emitted into each test's header, so a failing
-- test explains itself.
data Property = Property
  { propertyId :: Id, propertyName :: String, propertyLocation :: Location
  , propertyInputs :: [Quantifier], propertyBody :: Proposition
  , propertyExamples :: [Example], propertyGeneration :: Generation
  , propertyDescription :: String, propertyRationale :: String
  , propertyReferences :: [String], propertyTrace :: [String]
  } deriving (Eq, Show, Generic)
-- | unitMachines are the unit's stateful models, which each target's model
-- runtime runs against its adapters.
data Unit = MkUnit { unitId :: Id, unitDeclarations :: [Declaration], unitContracts :: [Contract], unitProperties :: [Property], unitDefinitions :: [Definition], unitMachines :: [Machine Id]
  -- The unit's protocols, from which each target generates typed channel ends.
  , unitSessions :: [Session]
  -- The unit's supervisors, which each target generates beside its actors.
  , unitSupervisors :: [Supervisor]
  -- The unit's mailboxes (mailbox jobs of Job): typed queues with many
  -- senders and one receiver, generated on each target.
  , unitMailboxes :: [Mailbox] } deriving (Eq, Show, Generic)

-- | A mailbox is a typed queue with many senders and one receiver, generated on
-- each target from this declaration alone. ref:DEC-actors-otp-supervision
data Mailbox = Mailbox { mailboxName :: String, mailboxType :: Type } deriving (Eq, Show, Generic)
pattern Unit :: Id -> [Declaration] -> [Contract] -> [Property] -> [Definition] -> [Machine Id] -> Unit
pattern Unit identity declarations contracts properties definitions machines <- MkUnit identity declarations contracts properties definitions machines _ _ _
  where Unit identity declarations contracts properties definitions machines = MkUnit identity declarations contracts properties definitions machines [] [] []
{-# COMPLETE Unit #-}

-- | A protocol: what its first end sends (True) and receives (False), in
-- order; the second end does the reverse. A step's type naming another
-- protocol (a Constructor with no arguments whose name is a session) sends
-- that protocol's first end, unused.
data Session = Session { sessionId :: Id, sessionName :: String, sessionSteps :: [(Bool, Type)] }
  deriving (Eq, Show, Generic)
-- | The whole input to the backends: the machine profile, every data
-- declaration and every unit, so an emitter needs nothing else.
-- ref:DEC-explicit-machine-profile
data Program = Program
  { programMachineBits :: Int, programDataDeclarations :: [DataDeclaration]
  , programUnits :: [Unit]
  } deriving (Eq, Show, Generic)

-- | Diagnostics and the evidence report show operators as they are written.
binaryName :: BinaryOp -> String
binaryName Add = "+"
binaryName Subtract = "-"
binaryName Multiply = "*"
binaryName Divide = "/"
binaryName Quotient = "quot"
binaryName Remainder = "rem"
binaryName Power = "pow"
binaryName Equal = "=="
binaryName NotEqual = "!="
binaryName Less = "<"
binaryName LessEqual = "<="
binaryName Greater = ">"
binaryName GreaterEqual = ">="
-- | Comparisons yield Bool whatever their operands, so typing treats them apart
-- from arithmetic.
isComparison :: BinaryOp -> Bool
isComparison op = op `elem` [Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual]
-- | One traversal that knows every node, so analyses do not each repeat the
-- list and miss a constructor added later.
children :: Expr -> [Expr]
children Expr{expressionNode=node} = case node of
  Match value cases -> value : map caseBody cases
  AllElements value _ predicate -> [value,predicate]
  AllPayloads value predicates -> value : map snd predicates
  Construct _ es -> es
  ExternalCall _ es -> es
  Binary _ _ a b -> [a,b]
  Unary _ a -> [a]
  ShortCircuit _ a b -> [a,b]
  If c a b -> [c,a,b]
  Convert _ _ a -> [a]
  Helper _ es -> es
  _ -> []

-- | A predicate can be checked on its own only when it depends on nothing but
-- its own inputs.
freeBinders :: Expr -> [Id]
freeBinders e = case expressionNode e of
  AllElements value binder predicate -> freeBinders value ++
    filter (/= binderId binder) (freeBinders predicate)
  AllPayloads value predicates -> freeBinders value ++ concat
    [filter (/= binderId binder) (freeBinders predicate) | (binder,predicate) <- predicates]
  Local n -> [n]
  Match value cases -> freeBinders value ++ concat
    [[n | n <- freeBinders (caseBody branch), n `notElem` map binderId (caseBinders branch)]
      | branch <- cases]
  _ -> concatMap freeBinders (children e)
-- | An expression that calls no adapter can be evaluated by the compiler itself,
-- which is what proving and exhaustive checking need.
isPure :: Expr -> Bool
isPure e = case expressionNode e of
  ExternalCall _ _ -> False
  _ -> all isPure (children e)

-- | Runtimes expose each builtin under one name on every target.
builtinName :: Builtin -> String
builtinName Length = "length"
builtinName IsPresent = "isPresent"
builtinName PresentValue = "presentValue"
builtinName RealPart = "real"
builtinName ImaginaryPart = "imag"
builtinName IsNaN = "isNaN"
builtinName IsInfinite = "isInfinite"
builtinName IsFinite = "isFinite"
builtinName IsNegativeZero = "isNegativeZero"
builtinName RoundHalfEven = "round"
builtinName Checked = "checked"
builtinName Compare = "compare"
builtinName Select = "select"
builtinName Unreachable = "unreachable"
builtinName Concurrently = "concurrently"

-- | Example bindings are closed data, never computations or adapter invocations.
isConcrete :: Expr -> Bool
isConcrete Expr{expressionNode = Constant _} = True
isConcrete Expr{expressionNode = Construct _ fields} = all isConcrete fields
isConcrete _ = False

-- | Root expressions, without repeated descendants, for backend capability and
-- dependency checks. Include fixtures and generator bounds as well as laws.
propositionExpressions :: Proposition -> [Expr]
propositionExpressions (Equation _ a b) = [a,b]
propositionExpressions (Implication guard body) = guard : propositionExpressions body
propositionExpressions (Conjunction bodies) = concatMap propositionExpressions bodies

-- | Dependency analysis needs every expression a law mentions, its inputs'
-- refinements and its examples included. ref:DEC-incremental-compilation
propertyExpressions :: Property -> [Expr]
propertyExpressions property =
  propositionExpressions (propertyBody property) ++
  concat [quantifiedPredicates q ++ map snd (quantifiedBounds q) | q <- propertyInputs property] ++
  concat [map snd (exampleBindings example) ++ concatMap propositionExpressions (exampleExpectations example)
    | example <- propertyExamples property]

-- | As propertyExpressions, for a contract's conditions.
contractExpressions :: Contract -> [Expr]
contractExpressions contract = contractPreconditions contract ++ contractPostconditions contract

-- | An all group whose steps run at the same time: match concurrently (C a b
-- ...) with | C x y ... -> body. Backends evaluate the fields side by side,
-- bind them in declaration order, then evaluate the body.
concurrentGroup :: Expr -> Maybe ([Expr], [Binder], Expr)
concurrentGroup Expr{expressionNode = Match Expr{expressionNode = Helper Concurrently [Expr{expressionNode = Construct tag fields}]} [MatchCase tag' binders body]}
  | tag == tag', length binders == length fields = Just (fields, binders, body)
concurrentGroup _ = Nothing
