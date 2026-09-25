module LawSpec.Model where

import Data.Aeson hiding (Number)
import LawSpec.Scalar
import GHC.Generics (Generic)

data Type = Named String | Variable String | Arrow Type Type | Applied String Type | Refined String Type (Maybe Expr) | RefinementApp String [RefinementArgument] | Qualified [Constraint] Type | CheckedType [Expr] Type deriving (Eq, Show, Generic)
data Expr = Var String | Apply Expr Expr | Compose Expr Expr | Number Integer | DecimalNumber Integer Integer | StringLit String | BoolLit Bool | ScalarLit Scalar | Binary String Expr Expr | Unary String Expr | Annotate Expr Type | TypeBound String Type deriving (Eq, Show, Generic)
data Definition = Forall [(String, Type)] Definition | Equal Expr Expr | Holds Expr | Implies Expr Definition | And Definition Definition | Invoke String [Expr] deriving (Eq, Show, Generic)
data Constraint = Capability String Type deriving (Eq, Show, Generic)
data RefinementArgument = TypeArgument Type | ValueArgument Expr deriving (Eq, Show, Generic)
data Refinement = Refinement { refinementName :: String, refinementParameters :: [(String,Type)], refinementRequirements :: [Constraint], refinementBody :: Type } deriving (Eq, Show, Generic)
data Contract = Contract { contractName :: String, contractArguments :: [(String,Type)], contractResult :: (String,Type), contractPreconditions :: [Expr], contractPostconditions :: [Expr] } deriving (Eq, Show, Generic)
data Generation = Generation { cases :: Int, maxAttempts :: Int, maxShrinks :: Int, exhaustiveLimit :: Int } deriving (Eq, Show, Generic)
data DomainPlan = DomainPlan { domainInput :: Input, domainBounds :: [(String,Expr)] } deriving (Eq, Show, Generic)
defaultGeneration :: Generation
defaultGeneration = Generation 100 10000 1000 4096
instance ToJSON Constraint
instance ToJSON RefinementArgument
instance ToJSON Refinement
instance ToJSON Contract
instance ToJSON Generation
instance FromJSON Generation where
  parseJSON = withObject "generation" $ \o -> Generation <$> o .:? "cases" .!= 100 <*> o .:? "maxAttempts" .!= 10000 <*> o .:? "maxShrinks" .!= 1000 <*> o .:? "exhaustiveLimit" .!= 4096
instance ToJSON DomainPlan

data Literal = IntLiteral Integer | DecimalLiteral Integer Integer | TextLiteral String | BoolLiteral Bool | ScalarLiteral Scalar deriving (Eq, Show)
instance ToJSON Literal where
  toJSON (DecimalLiteral c e) = toJSON (SDecimal c e)
  toJSON (IntLiteral n) = toJSON (SInteger "BigInt" n)
  toJSON (TextLiteral s) = toJSON (textScalar s)
  toJSON (BoolLiteral b) = toJSON (SBool b)
  toJSON (ScalarLiteral s) = toJSON s

data Expectation = Expectation { actual :: Expr, expected :: Literal } deriving (Eq, Show, Generic)
instance ToJSON Expectation

data Example = Example { exampleName :: String, bindings :: [(String, Literal)], expectations :: [Expectation] } deriving (Eq, Show, Generic)
data Location = Location { file :: String, line :: Int, column :: Int } deriving (Eq, Show, Generic)
data Law = Law { lawName :: String, parameters :: [(String, Type)], requirements :: [Constraint], definition :: Definition, description :: String, rationale :: String, examples :: [Example], references :: [String], location :: Location } deriving (Eq, Show, Generic)
data Unit = Unit { unitName :: String, functions :: [(String, Type)], laws :: [Law], refinements :: [Refinement], contracts :: [Contract] } deriving (Eq, Show, Generic)
data Diagnostic = Diagnostic { code :: String, message :: String, at :: Maybe Location } deriving (Eq, Show, Generic)
data Input = Input { inputName :: String, inputId :: String, inputType :: Type, inputRefinements :: [Expr] } deriving (Eq, Show, Generic)
data Assertion = AssertEqual Expr Expr | AssertImplies Expr Assertion | AssertAll [Assertion] deriving (Eq, Show, Generic)
instance ToJSON Assertion

data Expanded = Expanded { owner :: String, name :: String, inputs :: [Input], left :: Expr, right :: Expr, guards :: [Expr], assertion :: Assertion, trace :: [String], original :: Law, typedExpressions :: [TypedExpr], propertyKind :: String, generation :: Generation, generationPlan :: [DomainPlan] } deriving (Eq, Show, Generic)
data Source = Source { path :: String, content :: String } deriving (Eq, Show, Generic)
data Artifact = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String } deriving (Eq, Show, Generic)
instance ToJSON Type
instance ToJSON Expr where
  toJSON (DecimalNumber c e) = object ["tag" .= ("DecimalNumber" :: String), "contents" .= [show c,show e]]
  toJSON (Number n) = object ["tag" .= ("Number" :: String), "contents" .= show n]
  toJSON e = genericToJSON defaultOptions e
instance ToJSON Location
instance ToJSON Diagnostic
instance ToJSON Example
instance ToJSON Definition
instance ToJSON Law
instance ToJSON Input
instance ToJSON Expanded
instance ToJSON Artifact where
  toJSON Artifact{..} = object ["path" .= artifactPath, "content" .= artifactContent, "ownership" .= ownership, "placement" .= artifactPlacement]
instance FromJSON Source
instance ToJSON Source

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
prettyType (Arrow a b) = atom a ++ " -> " ++ prettyType b where
  atom t@(Arrow _ _) = "(" ++ prettyType t ++ ")"
  atom t = prettyType t
prettyExpr :: Expr -> String
prettyExpr (TypeBound b t) = prettyType t ++ "." ++ b
prettyExpr (Var n) = n
prettyExpr (DecimalNumber c e) = prettyScalar (SDecimal c e)
prettyExpr (Number n) = show n
prettyExpr (StringLit s) = show s
prettyExpr (Apply f x) = prettyExpr f ++ " (" ++ prettyExpr x ++ ")"
prettyExpr (Compose f g) = "(" ++ prettyExpr f ++ " . " ++ prettyExpr g ++ ")"

prettyExpr (ScalarLit s) = prettyScalar s
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
data TypedExpr = TypedExpr { expressionType :: Type, expression :: Expr, operands :: [TypedExpr], requiredConversion :: Maybe Type } deriving (Eq, Show, Generic)
instance ToJSON TypedExpr
literalExpr :: Literal -> Expr
literalExpr (DecimalLiteral c e) = DecimalNumber c e
literalExpr (IntLiteral n) = Number n
literalExpr (TextLiteral s) = StringLit s
literalExpr (BoolLiteral b) = BoolLit b
literalExpr (ScalarLiteral s) = ScalarLit s

finiteScalar :: Type -> Bool
finiteScalar (Named n) = n `elem` ["Bool","Unit","Null","Undefined"]
finiteScalar (Applied _ t) = finiteScalar t
finiteScalar _ = False

replaceExprVars :: [(String, Expr)] -> Expr -> Expr
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
baseType t = t

-- Predicates are expressions over values; aliases never introduce storage wrappers.
typePredicates :: Expr -> Type -> [Expr]
typePredicates value (Refined n t p) = typePredicates value t ++ maybe [] (pure . replaceExprVars [(n,value)]) p
typePredicates value (Qualified _ t) = typePredicates value t
typePredicates value (CheckedType ps t) = ps ++ typePredicates value t
typePredicates value (Applied n t) | n `elem` ["Nullable","Optional"] =
  [Binary "||" (Unary "!" (Apply (Var "prelude.isPresent") value)) p | p <- typePredicates (Apply (Var "prelude.presentValue") value) t]
typePredicates _ _ = []

typeConstraints :: Type -> [Constraint]
typeConstraints (Qualified cs t) = cs ++ typeConstraints t
typeConstraints (CheckedType _ t) = typeConstraints t
typeConstraints (Refined _ t _) = typeConstraints t
typeConstraints (Applied _ t) = typeConstraints t
typeConstraints (Arrow a b) = typeConstraints a ++ typeConstraints b
typeConstraints _ = []

mapType :: (Type -> Type) -> (Expr -> Expr) -> Type -> Type
mapType f g = walk where
  walk (Arrow a b) = f (Arrow (walk a) (walk b))
  walk (Applied n t) = f (Applied n (walk t))
  walk (Refined n t p) = f (Refined n (walk t) (g <$> p))
  walk (CheckedType ps t) = f (CheckedType (map g ps) (walk t))
  walk (Qualified cs t) = f (Qualified [Capability n (walk a) | Capability n a <- cs] (walk t))
  walk (RefinementApp n args) = f (RefinementApp n [case a of TypeArgument t -> TypeArgument (walk t); ValueArgument e -> ValueArgument (g e) | a <- args])
  walk t = f t

mapExprTypes :: (Type -> Type) -> Expr -> Expr
mapExprTypes f e = case e of
  Annotate a t -> Annotate (go a) (f t)
  TypeBound b t -> TypeBound b (f t)
  Apply a b -> Apply (go a) (go b)
  Compose a b -> Compose (go a) (go b)
  Binary op a b -> Binary op (go a) (go b)
  Unary op a -> Unary op (go a)
  _ -> e
  where go = mapExprTypes f

exprVars :: Expr -> [String]
exprVars (Var n) = [n]
exprVars (Apply a b) = exprVars a ++ exprVars b
exprVars (Compose a b) = exprVars a ++ exprVars b
exprVars (Binary _ a b) = exprVars a ++ exprVars b
exprVars (Unary _ a) = exprVars a
exprVars (Annotate a _) = exprVars a
exprVars _ = []
