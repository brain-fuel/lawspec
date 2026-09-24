module LawSpec.Model where

import Data.Aeson hiding (Number)
import GHC.Generics (Generic)

data Type = Named String | Variable String | Arrow Type Type deriving (Eq, Ord, Show, Generic)
data Expr = Var String | Apply Expr Expr | Compose Expr Expr | Number Integer | StringLit String | BoolLit Bool deriving (Eq, Show, Generic)
data Definition = Forall [(String, Type)] Definition | Equal Expr Expr | Holds Expr | Implies Expr Definition | Invoke String [Expr] deriving (Eq, Show, Generic)
data Literal = IntLiteral Integer | TextLiteral String | BoolLiteral Bool deriving (Eq, Show)
instance ToJSON Literal where
  toJSON (IntLiteral n) = toJSON n
  toJSON (TextLiteral s) = toJSON s
  toJSON (BoolLiteral b) = toJSON b

data Expectation = Expectation { actual :: Expr, expected :: Literal } deriving (Eq, Show, Generic)
instance ToJSON Expectation

data Example = Example { exampleName :: String, bindings :: [(String, Literal)], expectations :: [Expectation] } deriving (Eq, Show, Generic)
data Location = Location { file :: String, line :: Int, column :: Int } deriving (Eq, Show, Generic)
data Law = Law { lawName :: String, parameters :: [(String, Type)], requirements :: [Type], definition :: Definition, description :: String, rationale :: String, examples :: [Example], references :: [String], location :: Location } deriving (Eq, Show, Generic)
data Unit = Unit { unitName :: String, functions :: [(String, Type)], laws :: [Law] } deriving (Eq, Show, Generic)
data Diagnostic = Diagnostic { code :: String, message :: String, at :: Maybe Location } deriving (Eq, Show, Generic)
data Input = Input { inputName :: String, inputId :: String, inputType :: Type } deriving (Eq, Show, Generic)
data Expanded = Expanded { owner :: String, name :: String, inputs :: [Input], left :: Expr, right :: Expr, guards :: [Expr], trace :: [String], original :: Law } deriving (Eq, Show, Generic)
data Source = Source { path :: String, content :: String } deriving (Eq, Show, Generic)
data Artifact = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String } deriving (Eq, Show, Generic)
instance ToJSON Type
instance ToJSON Expr
instance ToJSON Location
instance ToJSON Diagnostic
instance ToJSON Example
instance ToJSON Definition
instance ToJSON Law
instance ToJSON Input
instance ToJSON Expanded
instance ToJSON Artifact where
  toJSON Artifact{..} = object ["path" .= artifactPath, "content" .= artifactContent, "ownership" .= ownership]
instance FromJSON Source
instance ToJSON Source

prettyType :: Type -> String
prettyType (Named n) = n
prettyType (Variable n) = reverse (takeWhile (/= ':') (reverse n))
prettyType (Arrow a b) = atom a ++ " -> " ++ prettyType b where
  atom t@(Arrow _ _) = "(" ++ prettyType t ++ ")"
  atom t = prettyType t
prettyExpr :: Expr -> String
prettyExpr (Var n) = n
prettyExpr (Number n) = show n
prettyExpr (StringLit s) = show s
prettyExpr (Apply f x) = prettyExpr f ++ " (" ++ prettyExpr x ++ ")"
prettyExpr (Compose f g) = "(" ++ prettyExpr f ++ " . " ++ prettyExpr g ++ ")"

prettyExpr (BoolLit b) = if b then "true" else "false"
