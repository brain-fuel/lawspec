{-# LANGUAGE PatternSynonyms #-}
-- Presentation-only accessors over Core and Testing. No source syntax,
-- substitution, type inference, or refinement expansion belongs here.
module LawSpec.Backend where
import qualified LawSpec.Core as C
import LawSpec.Testing (PlannedProperty(..), GeneratorRequirement(..))
import LawSpec.Common (Generation, Location)
import LawSpec.Scalar (prettyScalar)
import Data.List (intercalate, stripPrefix)

type Type = C.Type
pattern Named :: String -> Type
pattern Named n = C.Constructor n []
pattern Applied :: String -> Type -> Type
pattern Applied n a = C.Constructor n [C.TypeArgument a]
pattern Arrow :: Type -> Type -> Type
pattern Arrow a b = C.Arrow a b

type Expr = C.Expr
type Assertion = C.Proposition
pattern AssertEqual :: Expr -> Expr -> Assertion
pattern AssertEqual a b <- C.Equation _ a b
pattern AssertImplies :: Expr -> Assertion -> Assertion
pattern AssertImplies a b = C.Implication a b
pattern AssertAll :: [Assertion] -> Assertion
pattern AssertAll ps = C.Conjunction ps
{-# COMPLETE AssertEqual, AssertImplies, AssertAll #-}
type Unit = C.Unit
type Input = C.Quantifier
type Expanded = PlannedProperty
type Example = C.Example
type Contract = C.Contract

unitName :: Unit -> String
unitName = C.idText . C.unitId
functions :: Unit -> [(String,Type)]
functions u = [(C.declarationName d,C.declarationType d) | d <- C.unitDeclarations u]
contracts :: Unit -> [Contract]
contracts = C.unitContracts
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
references = C.propertyReferences
location :: C.Property -> Location
location = C.propertyLocation
generation :: Expanded -> Generation
generation = C.propertyGeneration . plannedProperty
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

declarationName :: C.Id -> String
declarationName = lastPart . C.idText where
  lastPart s = case splitOnce "::" s of (_,Just rest) -> lastPart rest; _ -> s
localName :: C.Id -> String
localName i = case splitOnce "::input::" (C.idText i) of
  (_,Just n) -> "_input" ++ n
  _ -> case splitOnce "::contract::" (C.idText i) of
    (_,Just n) -> "_arg" ++ n
    _ -> declarationName i
splitOnce :: String -> String -> (String,Maybe String)
splitOnce needle = go [] where
  go prefix rest | Just after <- stripPrefix needle rest = (reverse prefix,Just after)
  go prefix (c:rest) = go (c:prefix) rest
  go prefix [] = (reverse prefix,Nothing)

generationPlan :: Expanded -> [GeneratorRequirement]
generationPlan = generatorRequirements
domainInput :: GeneratorRequirement -> Input
domainInput g = C.Quantifier (generatorBinder g) (generatorPredicates g) (generatorBounds g)
domainBounds :: GeneratorRequirement -> [(String,Expr)]
domainBounds g = [(C.binaryName op,e) | (op,e) <- generatorBounds g]

prettyType :: Type -> String
prettyType (C.Constructor n args) = unwords (n:map argument args) where
  argument (C.TypeArgument t) = "(" ++ prettyType t ++ ")"
  argument (C.IndexArgument (C.Natural n')) = show n'
  argument (C.IndexArgument (C.IndexVariable i)) = C.idText i
prettyType (C.TypeVariable n) = C.idText n
prettyType (C.Arrow a b) = "(" ++ prettyType a ++ " -> " ++ prettyType b ++ ")"
prettyExpr :: Expr -> String
prettyExpr e = case C.expressionNode e of
  C.Constant s -> prettyScalar s
  C.Local n -> localName n
  C.ExternalCall n args -> unwords (declarationName n:map ((\s -> "(" ++ s ++ ")") . prettyExpr) args)
  C.Binary op _ a b -> "(" ++ prettyExpr a ++ " " ++ C.binaryName op ++ " " ++ prettyExpr b ++ ")"
  C.Unary op a -> show op ++ "(" ++ prettyExpr a ++ ")"
  C.ShortCircuit op a b -> "(" ++ prettyExpr a ++ " " ++ show op ++ " " ++ prettyExpr b ++ ")"
  C.Convert _ t a -> "(" ++ prettyExpr a ++ " :: " ++ prettyType t ++ ")"
  C.Helper b args -> show b ++ "(" ++ intercalate ", " (map prettyExpr args) ++ ")"

prettyExpanded :: Expanded -> String
prettyExpanded e | propertyKind e == "contract" = description (original e)
prettyExpanded e = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ ")" | i <- inputs e] ++ " . " ++ propositionText (assertion e)
propositionText :: Assertion -> String
propositionText (AssertEqual a b) = prettyExpr a ++ " = " ++ prettyExpr b
propositionText (AssertImplies g p) = prettyExpr g ++ " implies " ++ propositionText p
propositionText (AssertAll ps) = intercalate " and " (map propositionText ps)

metadata :: String -> Expanded -> String
metadata prefix e = unlines [prefix ++ " " ++ map safe line | line <- lines text] where
  text = "Law: " ++ owner e ++ "::" ++ name e ++ "\nDescription: " ++ description (original e)
    ++ "\nRationale: " ++ rationale (original e) ++ "\nReferences: " ++ intercalate ", " (references (original e))
    ++ "\nExpansion:\n" ++ unlines (trace e) ++ prettyExpanded e
    ++ concat ["\nExample: " ++ exampleName ex ++ "\n" ++ unlines ["expect " ++ propositionText p | p <- expectations ex] | ex <- examples (original e)]
  safe '\\' = '／'
  safe c | c < ' ' || c == '\x2028' || c == '\x2029' = ' '
         | otherwise = c
