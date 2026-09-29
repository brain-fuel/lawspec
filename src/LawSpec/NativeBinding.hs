-- Resolve external representation choices against checked Core identities.
-- Target syntax and property frameworks do not enter the semantic type system.
module LawSpec.NativeBinding
  ( NativeRef(..), ConstructorStyle(..), FieldBinding(..), ConstructorBinding(..)
  , TypeBinding(..), CodecBinding(..), GeneratorBinding(..), Bindings(..), emptyBindings
  , ResolvedBindings(..), ResolvedTypeBinding(..), ResolvedConstructorBinding(..)
  , ResolvedGeneratorBinding(..), resolveBindings, usesMachineRepresentation, reachableGeneratorTypes
  ) where

import Control.Monad (unless, forM)
import Data.Char (isAscii, isAlpha, isAlphaNum)
import Data.List (nub, find)
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry, substitute)
import qualified Data.Map.Strict as M
import LawSpec.Scalar (primitive)

-- A reference is structured, never a snippet of executable target code.
newtype NativeRef = NativeRef { referenceParts :: [String] } deriving (Eq, Show)
data ConstructorStyle = RecordConstructor | VariantConstructor | UnitConstructor
  deriving (Eq, Show)
data FieldBinding = FieldBinding
  { boundField :: String, nativeField :: String } deriving (Eq, Show)
data ConstructorBinding = ConstructorBinding
  { boundConstructor :: String, nativeConstructor :: NativeRef
  , constructorStyle :: ConstructorStyle, boundFields :: [FieldBinding]
  } deriving (Eq, Show)
data CodecBinding = CodecBinding
  { codecToNative :: NativeRef, codecFromNative :: NativeRef }
  deriving (Eq, Show)
data TypeBinding = TypeBinding
  { boundType :: C.Id, nativeType :: NativeRef
  , boundConstructors :: [ConstructorBinding], boundCodec :: Maybe CodecBinding
  } deriving (Eq, Show)
data GeneratorBinding = GeneratorBinding
  { generatorType :: C.Id, generatorFactory :: NativeRef, generatorStub :: Bool } deriving (Eq, Show)
data Bindings = Bindings
  { typeBindings :: [TypeBinding], generatorBindings :: [GeneratorBinding]
  } deriving (Eq, Show)
emptyBindings :: Bindings
emptyBindings = Bindings [] []

data ResolvedBindings = ResolvedBindings
  { resolvedTypes :: [ResolvedTypeBinding]
  , resolvedGenerators :: [ResolvedGeneratorBinding]
  } deriving (Eq, Show)
data ResolvedTypeBinding = ResolvedTypeBinding
  { resolvedDeclaration :: C.DataDeclaration, resolvedNativeType :: NativeRef
  , resolvedConstructors :: [ResolvedConstructorBinding], resolvedCodec :: Maybe CodecBinding
  } deriving (Eq, Show)
data ResolvedConstructorBinding = ResolvedConstructorBinding
  { resolvedConstructor :: C.DataConstructor
  , resolvedNativeConstructor :: NativeRef, resolvedConstructorStyle :: ConstructorStyle
  , resolvedFields :: [(C.Binder, String)]
  } deriving (Eq, Show)
data ResolvedGeneratorBinding = ResolvedGeneratorBinding
  { resolvedGeneratorType :: C.Id, resolvedGeneratorFactory :: NativeRef
  , generatorParameterCount :: Int, resolvedGeneratorStub :: Bool
  } deriving (Eq, Show)

resolveBindings :: [C.DataDeclaration] -> Bindings -> Either String ResolvedBindings
resolveBindings declarations Bindings{..} = do
  _ <- makeRegistry declarations
  unique "type binding" (map boundType typeBindings)
  unique "native type" (map nativeType typeBindings)
  unique "generator binding" (map generatorType generatorBindings)
  mapM_ (\binding -> unless
    (length (filter ((== generatorFactory binding) . generatorFactory) generatorBindings) == 1)
    (Left "a scaffolded generator factory must belong to exactly one type"))
    (filter generatorStub generatorBindings)
  ResolvedBindings <$> mapM resolveType typeBindings <*> mapM resolveGenerator generatorBindings
  where
    declaration identity = maybe (Left ("unknown bound type: " ++ C.idText identity)) Right
      (find ((== identity) . C.dataId) declarations)
    resolveType TypeBinding{..} = contextual (C.idText boundType) $ do
      value <- declaration boundType
      reference nativeType
      let constructors = C.dataConstructors value
      unless (not (null constructors)) (Left "cannot bind an uninhabited type")
      mappings <- case boundCodec of
        Just CodecBinding{..} -> do
          unless (null boundConstructors) (Left "codec hooks and constructor mappings are mutually exclusive")
          reference codecToNative
          reference codecFromNative
          pure []
        Nothing -> do
          unique "constructor mapping" (map boundConstructor boundConstructors)
          unique "native constructor" (map nativeConstructor boundConstructors)
          exact "constructors" (map C.constructorName constructors) (map boundConstructor boundConstructors)
          -- Normalize to declaration order. Configuration order must not reorder
          -- payloads, constructor contracts, or generic parameter evidence.
          mappings <- forM constructors $ \constructor -> do
            binding <- maybe (Left "missing constructor mapping") Right
              (find ((== C.constructorName constructor) . boundConstructor) boundConstructors)
            resolveConstructor (length constructors) constructor binding
          pure mappings
      pure (ResolvedTypeBinding value nativeType mappings boundCodec)
    resolveConstructor count constructor ConstructorBinding{..} = contextual boundConstructor $ do
      reference nativeConstructor
      let fields = C.constructorFields constructor
      unique "field mapping" (map boundField boundFields)
      unique "native field" (map nativeField boundFields)
      exact "fields" (map C.binderName fields) (map boundField boundFields)
      mapM_ (identifier . nativeField) boundFields
      unless (constructorStyle /= RecordConstructor || count == 1)
        (Left "record representation requires exactly one constructor")
      unless (constructorStyle /= UnitConstructor || null fields)
        (Left "unit constructor cannot have fields")
      mapped <- forM fields $ \field -> do
        name <- maybe (Left "missing field mapping") (Right . nativeField)
          (find ((== C.binderName field) . boundField) boundFields)
        pure (field,name)
      pure (ResolvedConstructorBinding constructor nativeConstructor constructorStyle mapped)
    resolveGenerator GeneratorBinding{..} = contextual (C.idText generatorType) $ do
      reference generatorFactory
      count <- case find ((== generatorType) . C.dataId) declarations of
        Just value -> pure (length (C.dataParameters value))
        Nothing -> case lookup (C.idText generatorType)
            [("List",1),("Maybe",1),("Either",2),("Nullable",1),("Optional",1)] of
          Just arity -> pure arity
          Nothing | Just _ <- primitive (C.idText generatorType) -> pure 0
                  | otherwise -> Left "unknown generator type"
      pure (ResolvedGeneratorBinding generatorType generatorFactory count generatorStub)

contextual :: String -> Either String a -> Either String a
contextual label = either (Left . (("native binding " ++ label ++ ": ") ++)) Right
unique :: (Eq a, Show a) => String -> [a] -> Either String ()
unique label values = unless (length values == length (nub values))
  (Left ("duplicate " ++ label ++ ": " ++ show values))
exact :: String -> [String] -> [String] -> Either String ()
exact label expected actual = unless (all (`elem` actual) expected && all (`elem` expected) actual)
  (Left (label ++ " must map exactly " ++ show expected ++ "; received " ++ show actual))
reference :: NativeRef -> Either String ()
reference (NativeRef parts) = do
  unless (not (null parts)) (Left "empty native reference")
  mapM_ identifier parts
identifier :: String -> Either String ()
identifier name = unless valid (Left ("invalid native identifier: " ++ show name))
  where
    valid = case name of
      c:cs -> (isAscii c && (isAlpha c || c == '_')) &&
        all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs && name /= "_"
      [] -> False

-- Machine-width checks belong at every automatic native bridge, including
-- generator parameter conversion, even when no application adapter is called.
usesMachineRepresentation :: [C.DataDeclaration] -> C.Type -> Bool
usesMachineRepresentation declarations = walk []
  where
    walk seen (C.Constructor name arguments) =
      name `elem` ["IntSize","UIntSize","UIntPtr"] ||
      any (\case C.TypeArgument child -> walk seen child; _ -> False) arguments ||
      (name `notElem` seen && any (walk (name:seen) . C.binderType)
        [field | declaration <- declarations, C.dataId declaration == C.Id name,
         constructor <- C.dataConstructors declaration, field <- C.constructorFields constructor])
    walk seen (C.Arrow a b) = walk seen a || walk seen b
    walk _ _ = False

-- Instantiate only the types reachable by schema generation. A custom factory
-- supplies its complete representation, so only its type-argument strategies
-- are traversed. Regular recursion reaches the same closed type and terminates.
reachableGeneratorTypes :: [C.DataDeclaration] -> ResolvedBindings -> [C.Type] -> Either String [C.Type]
reachableGeneratorTypes declarations bindings roots = walk [] [(ty,[]) | ty <- roots]
  where
    custom name = any ((== C.Id name) . resolvedGeneratorType)
      (resolvedGenerators bindings)
    size (C.Constructor _ args) = 1 + sum [size ty | C.TypeArgument ty <- args]
    size _ = 1 :: Int
    walk seen [] = Right seen
    walk seen ((ty,ancestors):rest)
      | ty `elem` seen = walk seen rest
      | otherwise = case ty of
          C.Constructor name args -> do
            unless (not (any (\case old@(C.Constructor previous _) -> previous == name && size ty > size old; _ -> False) ancestors))
              (Left ("native generator traversal expands a non-regular type: " ++ show ty))
            let arguments = [child | C.TypeArgument child <- args]
                stored = case find ((== C.Id name) . C.dataId) declarations of
                  Just declaration | not (custom name) ->
                    let substitutions = M.fromList (zip (C.dataParameters declaration) arguments)
                    in [substitute substitutions (C.binderType field) |
                      constructor <- C.dataConstructors declaration, field <- C.constructorFields constructor]
                  _ -> []
            walk (seen ++ [ty]) (rest ++ [(child,ty:ancestors) | child <- arguments ++ stored])
          _ -> Left ("native generator requires a concrete input type: " ++ show ty)

