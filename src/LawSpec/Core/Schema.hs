-- Backend-neutral runtime descriptions derived from checked Core declarations.
-- Type arguments remain structural, including recursive applications. Parameter
-- positions are local to each declaration; source binder names never leak into
-- a runtime's substitution algorithm.
module LawSpec.Core.Schema
  ( TypeRef(..), FieldSchema(..), ConstructorSchema(..), DataSchema(..)
  , ConstructorContractSchema(..), typeReference, dataSchemas, dataSchemasWithContracts
  ) where

import qualified LawSpec.Core as C

data TypeRef = Parameter Int | Named String [TypeRef] deriving (Eq, Show)
data FieldSchema = FieldSchema
  { fieldName :: String, fieldType :: TypeRef } deriving (Eq, Show)
data ConstructorSchema = ConstructorSchema
  { constructorTag :: String, fields :: [FieldSchema] } deriving (Eq, Show)
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
      mapM (constructor (C.dataParameters declaration)) (C.dataConstructors declaration)
    constructor parameters value = ConstructorSchema
      (C.idText (C.constructorId value)) <$>
      mapM (field parameters) (C.constructorFields value)
    field parameters binder = FieldSchema (C.binderName binder) <$>
      typeReference parameters (C.binderType binder)
