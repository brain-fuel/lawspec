{-# LANGUAGE PatternSynonyms #-}
-- Authoritative typed terms shared by evaluators and backends. This module has
-- no dependency on the surface syntax, inference, or a testing framework.
module LawSpec.Core where

import LawSpec.Core.Policy (StagePolicy)
import LawSpec.Core.Machine (Machine, Supervisor)
import GHC.Generics (Generic)
import LawSpec.IndexTerm (FamilyIndex(..))
import LawSpec.Common
import LawSpec.Scalar (Scalar)

newtype Id = Id { idText :: String } deriving (Eq, Ord, Show, Generic)
data Kind = ValueKind | TypeKind | KindArrow Kind Kind deriving (Eq, Show, Generic)
data Type = Constructor String [Argument] | TypeVariable Id | Arrow Type Type deriving (Eq, Ord, Show, Generic)
data Argument = TypeArgument Type | IndexArgument Index deriving (Eq, Ord, Show, Generic)
data Index = Natural Integer | IndexVariable Id deriving (Eq, Ord, Show, Generic)
scalarType :: String -> Type
scalarType n = Constructor n []
functionType :: Type -> ([Type], Type)
functionType (Arrow a b) = let (as,r) = functionType b in (a:as,r)
functionType t = ([],t)

data Binder = Binder { binderId :: Id, binderName :: String, binderType :: Type } deriving (Eq, Show, Generic)
-- An async declaration is an adapter whose result arrives later, as each
-- target's task; Declaration builds a synchronous one.
-- declarationUses is its ability row: the abilities it needs a handler for,
-- declared on an adapter and inferred for a definition. A native adapter
-- receives one handler per ability, in this order, before its arguments.
data Declaration = MkDeclaration { declarationId :: Id, declarationName :: String, declarationType :: Type, declarationOrigin :: Origin, declarationAsync :: Bool, declarationUses :: [AbilityRef] } deriving (Eq, Show, Generic)
pattern Declaration :: Id -> String -> Type -> Origin -> Declaration
pattern Declaration identity name ty origin <- MkDeclaration identity name ty origin _ _
  where Declaration identity name ty origin = MkDeclaration identity name ty origin False []
{-# COMPLETE Declaration #-}
-- A definition supplies a checked body rather than a user-owned adapter.
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
-- Products are single-constructor declarations; sums retain the identity of
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
-- A GADT constructor's equations fix declaration parameters to types over its
-- existentials: a value of T args uses the constructor only where each
-- equation matches its argument, which also determines the existentials.
data DataConstructor = DataConstructor
  { constructorId :: Id, constructorName :: String
  , constructorFields :: [Binder], constructorPredicates :: [Expr]
  , constructorOrigin :: Origin
  , constructorEquations :: [(Id, Type)]
  , constructorExistentials :: [Id]
  } deriving (Eq, Show, Generic)
-- Synthetic nodes explicitly have no source span; elaboration never fabricates
-- expression ranges from the containing law's location.
data Origin = SourceSpan Span | GeneratedFrom Id deriving (Eq, Show, Generic)
data Expr = Expr { expressionType :: Type, expressionNode :: Node, expressionOrigin :: Origin } deriving (Eq, Show, Generic)
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
  -- An ability operation: the handler its ability has where it runs answers
  -- it (evidence passing; see docs/explanation/abilities.md).
  | Perform Operation [Expr]
  -- The body, with one ability handled here: so far, catching a Fail E
  -- ability's failure as Left (prelude.attempt), giving Either E A.
  | Handle Handling Expr
  -- In a law: how many times the recording handler of the operation's
  -- ability has been called for it, with these arguments when given.
  | Calls Operation (Maybe [Expr])
  deriving (Eq, Show, Generic)

-- An ability at type arguments: Gateway, or Fail SignupError.
data AbilityRef = AbilityRef { abilityRefId :: Id, abilityRefArguments :: [Type] }
  deriving (Eq, Ord, Show, Generic)
data Operation = Operation { operationAbility :: AbilityRef, operationName :: String }
  deriving (Eq, Ord, Show, Generic)
data Handling = CatchFailure AbilityRef deriving (Eq, Show, Generic)

-- ability Name params is op :: T ... end. Operation types range over the
-- ability's parameters; an operation's other type variables (raise's result)
-- are instantiated where it is used.
data Ability = Ability
  { abilityId :: Id, abilityName :: String, abilityParameters :: [Id]
  , abilityOperations :: [(String, Type)], abilityOrigin :: Origin
  } deriving (Eq, Show, Generic)
-- A spec handler: a checked definition per operation (its clause), taking
-- the handler's state first when it has one and then returning Pair result
-- state; handlerState is the state's type and starting value.
data Handler = Handler
  { handlerId :: Id, handlerName :: String, handlerAbility :: AbilityRef
  , handlerClauses :: [(String, Id)], handlerState :: Maybe (Type, Expr)
  , handlerOrigin :: Origin
  } deriving (Eq, Show, Generic)
-- Which handler a law runs under for one ability.
data HandlerRef = ProductionHandler | SpecHandler Id | RecordingHandler HandlerRef
  deriving (Eq, Ord, Show, Generic)

-- The built-in Fail E ability: raise :: E -> a aborts to the nearest handler.
failAbilityId :: Id
failAbilityId = Id "lawspec::ability::Fail"
failAbility :: Ability
failAbility = Ability failAbilityId "Fail" [Id "Fail::e"]
  [("raise", Arrow (TypeVariable (Id "Fail::e")) (TypeVariable (Id "Fail::raise::a")))]
  (GeneratedFrom failAbilityId)

-- A stable key for an ability instance, the same on every target: its
-- identity, then its type arguments' keys in parentheses.
abilityKey :: AbilityRef -> String
abilityKey (AbilityRef identity arguments) = idText identity ++ concatMap (\t -> "(" ++ typeKey t ++ ")") arguments
  where
    typeKey (Constructor n []) = n
    typeKey (Constructor n args) = n ++ "(" ++ concatMap argumentKey args ++ ")"
    typeKey (TypeVariable v) = idText v
    typeKey (Arrow a b) = typeKey a ++ "->" ++ typeKey b
    argumentKey (TypeArgument t) = typeKey t ++ ";"
    argumentKey (IndexArgument (Natural n)) = show n ++ ";"
    argumentKey (IndexArgument (IndexVariable v)) = idText v ++ ";"

-- An operation's parameter and result types at its ability's arguments.
operationSignature :: Ability -> AbilityRef -> String -> Maybe ([Type], Type)
operationSignature ability (AbilityRef _ arguments) name = do
  ty <- lookup name (abilityOperations ability)
  let table = zip (abilityParameters ability) arguments
      go t = case t of
        TypeVariable v -> maybe t id (lookup v table)
        Arrow a b -> Arrow (go a) (go b)
        Constructor n args -> Constructor n [case a of TypeArgument x -> TypeArgument (go x); _ -> a | a <- args]
  pure (functionType (go ty))

-- The identity an evaluator or emitter calls an operation by.
operationId :: Operation -> Id
operationId (Operation ability name) = Id (abilityKey ability ++ "::" ++ name)

-- Whether an ability is the built-in Fail.
isFail :: AbilityRef -> Bool
isFail = (== failAbilityId) . abilityRefId
data MatchCase = MatchCase
  { caseConstructor :: Id, caseBinders :: [Binder], caseBody :: Expr
  } deriving (Eq, Show, Generic)

data BinaryOp = Add | Subtract | Multiply | Divide | Quotient | Remainder | Power
  | Equal | NotEqual | Less | LessEqual | Greater | GreaterEqual deriving (Eq, Show, Generic)
data UnaryOp = Negate | Not deriving (Eq, Show, Generic)
data LogicalOp = And | Or deriving (Eq, Show, Generic)
data Conversion = Explicit | CheckedArgument deriving (Eq, Show, Generic)
-- Evidence fixes the arithmetic domain before code generation. Backends must
-- neither choose a promotion nor infer a capability from surface syntax.
data Evidence = Numeric Type | Structural Type deriving (Eq, Show, Generic)
data Builtin = Length | IsPresent | PresentValue | RealPart | ImaginaryPart
  | IsNaN | IsInfinite | IsFinite | IsNegativeZero | RoundHalfEven | Checked | Compare | Select
  -- A branch the indices rule out: the totality audit proves it is never
  -- reached; reaching it anyway fails.
  | Unreachable
  -- concurrently (C a b ...) is C a b ...; matched at once, as an all
  -- group's steps are, its fields are evaluated at the same time.
  | Concurrently deriving (Eq, Show, Generic)
data Proposition = Equation Evidence Expr Expr | Implication Expr Proposition | Conjunction [Proposition] deriving (Eq, Show, Generic)
data Quantifier = Quantifier { quantifiedBinder :: Binder, quantifiedPredicates :: [Expr], quantifiedBounds :: [(BinaryOp,Expr)] } deriving (Eq, Show, Generic)
data Example = Example { exampleName :: String, exampleBindings :: [(Id,Expr)], exampleExpectations :: [Proposition] } deriving (Eq, Show, Generic)
-- A definition's runtime postconditions are claims the prover could not
-- establish because they involve non-linear index arithmetic; each result is
-- checked against them instead.
data Contract = Contract { contractDeclaration :: Id, contractArguments :: [Binder], contractResult :: Binder, contractPreconditions :: [Expr], contractPostconditions :: [Expr], contractRuntimePostconditions :: [Expr] } deriving (Eq, Show, Generic)
data Property = Property
  { propertyId :: Id, propertyName :: String, propertyLocation :: Location
  , propertyInputs :: [Quantifier], propertyBody :: Proposition
  , propertyExamples :: [Example], propertyGeneration :: Generation
  , propertyDescription :: String, propertyRationale :: String
  , propertyReferences :: [String], propertyTrace :: [String]
  -- The handler the law runs under for each ability it uses.
  , propertyHandlers :: [(AbilityRef, HandlerRef)]
  } deriving (Eq, Show, Generic)
-- unitMachines are the unit's stateful models, which each target's model
-- runtime runs against its adapters.
data Unit = MkUnit { unitId :: Id, unitDeclarations :: [Declaration], unitContracts :: [Contract], unitProperties :: [Property], unitDefinitions :: [Definition], unitMachines :: [Machine Id]
  -- The unit's protocols, from which each target generates typed channel ends.
  , unitSessions :: [Session]
  -- The unit's supervisors, which each target generates beside its actors.
  , unitSupervisors :: [Supervisor]
  -- The unit's mailboxes (mailbox jobs of Job): typed queues with many
  -- senders and one receiver, generated on each target.
  , unitMailboxes :: [Mailbox]
  -- The unit's abilities, and its spec handlers for them.
  , unitAbilities :: [Ability], unitHandlers :: [Handler] } deriving (Eq, Show, Generic)

data Mailbox = Mailbox { mailboxName :: String, mailboxType :: Type } deriving (Eq, Show, Generic)
pattern Unit :: Id -> [Declaration] -> [Contract] -> [Property] -> [Definition] -> [Machine Id] -> Unit
pattern Unit identity declarations contracts properties definitions machines <- MkUnit identity declarations contracts properties definitions machines _ _ _ _ _
  where Unit identity declarations contracts properties definitions machines = MkUnit identity declarations contracts properties definitions machines [] [] [] [] []
{-# COMPLETE Unit #-}

-- A protocol: what its first end sends (True) and receives (False), in
-- order; the second end does the reverse. A step's type naming another
-- protocol (a Constructor with no arguments whose name is a session) sends
-- that protocol's first end, unused.
data Session = Session { sessionId :: Id, sessionName :: String, sessionSteps :: [(Bool, Type)] }
  deriving (Eq, Show, Generic)
data Program = Program
  { programMachineBits :: Int, programDataDeclarations :: [DataDeclaration]
  , programUnits :: [Unit]
  } deriving (Eq, Show, Generic)

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
isComparison :: BinaryOp -> Bool
isComparison op = op `elem` [Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual]
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
  Perform _ es -> es
  Handle _ a -> [a]
  Calls _ es -> maybe [] id es
  _ -> []

-- Rebuild an expression with f applied to each child, in children's order.
mapChildren :: (Expr -> Expr) -> Expr -> Expr
mapChildren f e = e { expressionNode = case expressionNode e of
  Construct n args -> Construct n (map f args)
  Match value cases -> Match (f value) [c { caseBody = f (caseBody c) } | c <- cases]
  AllElements value binder body -> AllElements (f value) binder (f body)
  AllPayloads value predicates -> AllPayloads (f value) [(b, f x) | (b, x) <- predicates]
  ExternalCall n args -> ExternalCall n (map f args)
  Binary op evidence a b -> Binary op evidence (f a) (f b)
  Unary op a -> Unary op (f a)
  ShortCircuit op a b -> ShortCircuit op (f a) (f b)
  If c a b -> If (f c) (f a) (f b)
  Convert conversion ty a -> Convert conversion ty (f a)
  Helper name args -> Helper name (map f args)
  Perform op args -> Perform op (map f args)
  Handle handling body -> Handle handling (f body)
  Calls op args -> Calls op (map f <$> args)
  other@(Constant _) -> other
  other@(Local _) -> other }

-- The operations an expression performs or counts.
performed :: Expr -> [Operation]
performed e = case expressionNode e of
  Perform op args -> op : concatMap performed args
  Calls op args -> op : concatMap performed (maybe [] id args)
  _ -> concatMap performed (children e)

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
isPure :: Expr -> Bool
isPure e = case expressionNode e of
  ExternalCall _ _ -> False
  Perform _ _ -> False
  Calls _ _ -> False
  _ -> all isPure (children e)

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

-- Example bindings are closed data, never computations or adapter invocations.
isConcrete :: Expr -> Bool
isConcrete Expr{expressionNode = Constant _} = True
isConcrete Expr{expressionNode = Construct _ fields} = all isConcrete fields
isConcrete _ = False

-- Root expressions, without repeated descendants, for backend capability and
-- dependency checks. Include fixtures and generator bounds as well as laws.
propositionExpressions :: Proposition -> [Expr]
propositionExpressions (Equation _ a b) = [a,b]
propositionExpressions (Implication guard body) = guard : propositionExpressions body
propositionExpressions (Conjunction bodies) = concatMap propositionExpressions bodies

propertyExpressions :: Property -> [Expr]
propertyExpressions property =
  propositionExpressions (propertyBody property) ++
  concat [quantifiedPredicates q ++ map snd (quantifiedBounds q) | q <- propertyInputs property] ++
  concat [map snd (exampleBindings example) ++ concatMap propositionExpressions (exampleExpectations example)
    | example <- propertyExamples property]

contractExpressions :: Contract -> [Expr]
contractExpressions contract = contractPreconditions contract ++ contractPostconditions contract

-- An all group whose steps run at the same time: match concurrently (C a b
-- ...) with | C x y ... -> body. Backends evaluate the fields side by side,
-- bind them in declaration order, then evaluate the body.
concurrentGroup :: Expr -> Maybe ([Expr], [Binder], Expr)
concurrentGroup Expr{expressionNode = Match Expr{expressionNode = Helper Concurrently [Expr{expressionNode = Construct tag fields}]} [MatchCase tag' binders body]}
  | tag == tag', length binders == length fields = Just (fields, binders, body)
concurrentGroup _ = Nothing
