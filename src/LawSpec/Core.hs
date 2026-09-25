-- Authoritative typed terms shared by evaluators and backends. This module has
-- no dependency on the surface syntax, inference, or a testing framework.
module LawSpec.Core where

import LawSpec.Common
import LawSpec.Scalar (Scalar)

newtype Id = Id { idText :: String } deriving (Eq, Ord, Show)
data Kind = ValueKind | TypeKind | KindArrow Kind Kind deriving (Eq, Show)
data Type = Constructor String [Argument] | TypeVariable Id | Arrow Type Type deriving (Eq, Show)
data Argument = TypeArgument Type | IndexArgument Index deriving (Eq, Show)
data Index = Natural Integer | IndexVariable Id deriving (Eq, Show)
scalarType :: String -> Type
scalarType n = Constructor n []
functionType :: Type -> ([Type], Type)
functionType (Arrow a b) = let (as,r) = functionType b in (a:as,r)
functionType t = ([],t)

data Binder = Binder { binderId :: Id, binderName :: String, binderType :: Type } deriving (Eq, Show)
data Declaration = Declaration { declarationId :: Id, declarationName :: String, declarationType :: Type, declarationOrigin :: Origin } deriving (Eq, Show)
-- Synthetic nodes explicitly have no source span; elaboration never fabricates
-- expression ranges from the containing law's location.
data Origin = SourceSpan Span | GeneratedFrom Id deriving (Eq, Show)
data Expr = Expr { expressionType :: Type, expressionNode :: Node, expressionOrigin :: Origin } deriving (Eq, Show)
data Node
  = Constant Scalar
  | Local Id
  | ExternalCall Id [Expr]
  | Binary BinaryOp Evidence Expr Expr
  | Unary UnaryOp Expr
  | ShortCircuit LogicalOp Expr Expr
  | Convert Conversion Type Expr
  | Helper Builtin [Expr]
  deriving (Eq, Show)
data BinaryOp = Add | Subtract | Multiply | Divide | Quotient | Remainder
  | Equal | NotEqual | Less | LessEqual | Greater | GreaterEqual deriving (Eq, Show)
data UnaryOp = Negate | Not deriving (Eq, Show)
data LogicalOp = And | Or deriving (Eq, Show)
data Conversion = Explicit | CheckedArgument deriving (Eq, Show)
-- Evidence fixes the arithmetic domain before code generation. Backends must
-- neither choose a promotion nor infer a capability from surface syntax.
data Evidence = Numeric Type | Structural Type deriving (Eq, Show)
data Builtin = Length | IsPresent | PresentValue | RealPart | ImaginaryPart
  | IsNaN | IsInfinite | IsFinite | IsNegativeZero | RoundHalfEven | Checked deriving (Eq, Show)
data Proposition = Equation Evidence Expr Expr | Implication Expr Proposition | Conjunction [Proposition] deriving (Eq, Show)
data Quantifier = Quantifier { quantifiedBinder :: Binder, quantifiedPredicates :: [Expr], quantifiedBounds :: [(BinaryOp,Expr)] } deriving (Eq, Show)
data Example = Example { exampleName :: String, exampleBindings :: [(Id,Expr)], exampleExpectations :: [Proposition] } deriving (Eq, Show)
data Contract = Contract { contractDeclaration :: Id, contractArguments :: [Binder], contractResult :: Binder, contractPreconditions :: [Expr], contractPostconditions :: [Expr] } deriving (Eq, Show)
data Property = Property
  { propertyId :: Id, propertyName :: String, propertyLocation :: Location
  , propertyInputs :: [Quantifier], propertyBody :: Proposition
  , propertyExamples :: [Example], propertyGeneration :: Generation
  , propertyDescription :: String, propertyRationale :: String
  , propertyReferences :: [String], propertyTrace :: [String]
  } deriving (Eq, Show)
data Unit = Unit { unitId :: Id, unitDeclarations :: [Declaration], unitContracts :: [Contract], unitProperties :: [Property] } deriving (Eq, Show)
data Program = Program { programMachineBits :: Int, programUnits :: [Unit] } deriving (Eq, Show)

binaryName :: BinaryOp -> String
binaryName Add = "+"
binaryName Subtract = "-"
binaryName Multiply = "*"
binaryName Divide = "/"
binaryName Quotient = "quot"
binaryName Remainder = "rem"
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
  ExternalCall _ es -> es
  Binary _ _ a b -> [a,b]
  Unary _ a -> [a]
  ShortCircuit _ a b -> [a,b]
  Convert _ _ a -> [a]
  Helper _ es -> es
  _ -> []

freeBinders :: Expr -> [Id]
freeBinders e = case expressionNode e of
  Local n -> [n]
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
