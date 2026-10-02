{-# LANGUAGE PatternSynonyms #-}
-- Authoritative typed terms shared by evaluators and backends. This module has
-- no dependency on the surface syntax, inference, or a testing framework.
module LawSpec.Core where

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
data Declaration = MkDeclaration { declarationId :: Id, declarationName :: String, declarationType :: Type, declarationOrigin :: Origin, declarationAsync :: Bool } deriving (Eq, Show, Generic)
pattern Declaration :: Id -> String -> Type -> Origin -> Declaration
pattern Declaration identity name ty origin <- MkDeclaration identity name ty origin _
  where Declaration identity name ty origin = MkDeclaration identity name ty origin False
{-# COMPLETE Declaration #-}
-- A definition supplies a checked body rather than a user-owned adapter.
-- Calls retain resolved declaration identities; the total-definition audit
-- determines which declaration bodies may be invoked within this closed set.
data Definition = Definition
  { definitionDeclaration :: Declaration, definitionArguments :: [Binder]
  , definitionBody :: Expr
  } deriving (Eq, Show, Generic)
-- Products are single-constructor declarations; sums retain the identity of
-- each constructor even when their payloads have identical representations.
data DataDeclaration = DataDeclaration
  { dataId :: Id, dataName :: String, dataParameters :: [Id]
  , dataConstructors :: [DataConstructor], dataOrigin :: Origin
  -- An indexed family's erased index table, keyed by constructor identity.
  , dataIndex :: Maybe FamilyIndex
  } deriving (Eq, Show, Generic)
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
  | Convert Conversion Type Expr
  | Helper Builtin [Expr]
  deriving (Eq, Show, Generic)
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
  | IsNaN | IsInfinite | IsFinite | IsNegativeZero | RoundHalfEven | Checked | Compare deriving (Eq, Show, Generic)
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
  } deriving (Eq, Show, Generic)
data Unit = Unit { unitId :: Id, unitDeclarations :: [Declaration], unitContracts :: [Contract], unitProperties :: [Property], unitDefinitions :: [Definition] } deriving (Eq, Show, Generic)
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
  Convert _ _ a -> [a]
  Helper _ es -> es
  _ -> []

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
