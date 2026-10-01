-- Backend-neutral runtime descriptions derived from checked Core declarations.
-- Type arguments remain structural, including recursive applications. Parameter
-- positions are local to each declaration; source binder names never leak into
-- a runtime's substitution algorithm.
module LawSpec.Core.Schema
  ( TypeRef(..), FieldSchema(..), ConstructorSchema(..), DataSchema(..)
  , ConstructorContractSchema(..), typeReference, dataSchemas, dataSchemasWithContracts, witnessFieldName
  ) where

import qualified LawSpec.Core as C
import LawSpec.IndexTerm (FamilyIndex(..), constructorIndexTexts)

data TypeRef = Parameter Int | Named String [TypeRef] deriving (Eq, Show)
data FieldSchema = FieldSchema
  { fieldName :: String, fieldType :: TypeRef } deriving (Eq, Show)
-- An indexed family's constructor also carries its index terms and guards
-- (constructorIndexTexts), which validation checks on every value. A GADT
-- constructor's refinements fix parameters to patterns; its existentials are
-- the parameters numbered after the declaration's own, bound by matching the
-- refinements against a type's arguments.
data ConstructorSchema = ConstructorSchema
  { constructorTag :: String, fields :: [FieldSchema], constructorIndex :: [String]
  , constructorRefinements :: [(Int, TypeRef)]
  , constructorExistentials :: Int
  -- Existentials only a value determines (parameter numbers): each value
  -- carries their types as trailing Text witness fields.
  , constructorWitnesses :: [Int]
  } deriving (Eq, Show)
data DataSchema = DataSchema
  { typeName :: String, parameterCount :: Int
  , constructors :: [ConstructorSchema]
  } deriving (Eq, Show)

-- Keep executable predicates separate from runtime shape metadata. Emitters
-- must explicitly consume both; legacy shape-only consumers reject contracts.
data ConstructorContractSchema = ConstructorContractSchema
  { contractTag :: String, contractParameters :: [C.Id]
  , contractFields :: [C.Binder], contractPredicates :: [C.Expr]
  } deriving (Eq, Show)

typeReference :: [C.Id] -> C.Type -> Either String TypeRef
typeReference parameters ty = case ty of
  C.TypeVariable variable -> case lookup variable (zip parameters [0..]) of
    Just index -> Right (Parameter index)
    Nothing -> Left ("unbound schema parameter: " ++ C.idText variable)
  C.Constructor name arguments -> Named name <$> mapM argument arguments
  C.Arrow _ _ -> Left ("no schema representation for " ++ show ty)
  where
    argument (C.TypeArgument value) = typeReference parameters value
    argument (C.IndexArgument _) = Left "indexed data schema is not supported"

dataSchemas :: [C.DataDeclaration] -> Either String [DataSchema]
dataSchemas declarations = do
  (schemas,contracts) <- dataSchemasWithContracts declarations
  if null contracts then pure schemas else
    Left "constructor field contracts require runtime schema predicate support"

dataSchemasWithContracts :: [C.DataDeclaration]
  -> Either String ([DataSchema],[ConstructorContractSchema])
dataSchemasWithContracts declarations = do
  schemas <- mapM definition declarations
  let contracts = [ConstructorContractSchema (C.idText (C.constructorId constructor))
        (C.dataParameters declaration) (C.constructorFields constructor) (C.constructorPredicates constructor)
        | declaration <- declarations, constructor <- C.dataConstructors declaration,
          not (null (C.constructorPredicates constructor))]
  pure (schemas,contracts)
  where
    definition declaration = DataSchema (C.idText (C.dataId declaration))
      (length (C.dataParameters declaration)) <$>
      mapM (indexed declaration <$>) (map (constructor (C.dataParameters declaration)) (C.dataConstructors declaration))
    indexed declaration schema = case C.dataIndex declaration >>= lookup (constructorTag schema) . familyIndexConstructors of
      Just index -> schema { constructorIndex = constructorIndexTexts index }
      Nothing -> schema
    constructor parameters value = do
      let scope = parameters ++ C.constructorExistentials value
      fields' <- mapM (field scope) (C.constructorFields value)
      refinements <- mapM (\(parameter, ty) -> case lookup parameter (zip parameters [0..]) of
          Just index -> (,) index <$> typeReference scope ty
          Nothing -> Left ("refinement of an unknown parameter: " ++ C.idText parameter))
        (C.constructorEquations value)
      let mentioned = concatMap (typeVariablesOf . snd) (C.constructorEquations value)
          witnesses = [index | (index, e) <- zip [length parameters ..] (C.constructorExistentials value), e `notElem` mentioned]
          witnessFields = [FieldSchema (witnessFieldName (length witnesses) k) (Named "Text" []) | k <- [0 .. length witnesses - 1]]
      pure (ConstructorSchema (C.idText (C.constructorId value)) (fields' ++ witnessFields) [] refinements
        (length (C.constructorExistentials value)) witnesses)
    field parameters binder = FieldSchema (C.binderName binder) <$>
      typeReference parameters (C.binderType binder)

typeVariablesOf :: C.Type -> [C.Id]
typeVariablesOf ty = case ty of
  C.TypeVariable v -> [v]
  C.Constructor _ arguments -> concat [typeVariablesOf t | C.TypeArgument t <- arguments]
  C.Arrow a b -> typeVariablesOf a ++ typeVariablesOf b

-- A value's witness fields, after its declared ones: witness, or witness0..
witnessFieldName :: Int -> Int -> String
witnessFieldName 1 _ = "witness"
witnessFieldName _ k = "witness" ++ show k
