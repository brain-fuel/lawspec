-- Public binding configuration is resolved before entering target emission.
module LawSpec.NativeRequest
  ( NativeRequest(..), FunctionBinding(..), GoImport(..), BindingPlan(..)
  , emptyNativeRequest, emptyBindingPlan, resolveNativeRequest, hasBindings
  ) where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isAscii, isAlpha, isAlphaNum)
import Data.List (find, nub)
import qualified LawSpec.Core as C
import LawSpec.NativeBinding

-- The crate is needed only by Rust test linkage, not by the semantic Core.
data NativeRequest = NativeRequest
  { requestBindings :: Bindings, requestFunctions :: [FunctionBinding]
  , requestRustCrate :: Maybe String, requestGoImports :: [GoImport]
  } deriving (Eq, Show)
data GoImport = GoImport { goImportAlias :: String, goImportPath :: String } deriving (Eq, Show)
data FunctionBinding = FunctionBinding
  { functionDeclaration :: C.Id, functionNative :: NativeRef } deriving (Eq, Show)
data BindingPlan = BindingPlan
  { bindingRepresentations :: ResolvedBindings
  , bindingFunctions :: [(C.Declaration, NativeRef)]
  , bindingRustCrate :: Maybe String, bindingGoImports :: [GoImport]
  } deriving (Eq, Show)
emptyNativeRequest :: NativeRequest
emptyNativeRequest = NativeRequest emptyBindings [] Nothing []
emptyBindingPlan :: BindingPlan
emptyBindingPlan = BindingPlan (ResolvedBindings [] []) [] Nothing []
hasBindings :: BindingPlan -> Bool
hasBindings plan = plan /= emptyBindingPlan

resolveNativeRequest :: C.Program -> NativeRequest -> Either String BindingPlan
resolveNativeRequest program NativeRequest{..} = do
  representations <- resolveBindings (C.programDataDeclarations program) requestBindings
  unless (length requestFunctions == length (nub (map functionDeclaration requestFunctions)))
    (Left "duplicate native function binding")
  functions <- mapM resolve requestFunctions
  mapM_ validIdentifier requestRustCrate
  unless (length requestGoImports == length (nub (map goImportAlias requestGoImports)))
    (Left "duplicate Go import alias")
  unless (length requestGoImports == length (nub (map goImportPath requestGoImports)))
    (Left "duplicate Go import path")
  mapM_ validateGoImport requestGoImports
  pure (BindingPlan representations functions requestRustCrate requestGoImports)
  where
    definitions = [C.declarationId (C.definitionDeclaration d) |
      u <- C.programUnits program, d <- C.unitDefinitions u]
    declarations = [d | u <- C.programUnits program, d <- C.unitDeclarations u,
      C.declarationId d `notElem` definitions]
    resolve FunctionBinding{..} = do
      validReference functionNative
      declaration <- maybe (Left ("unknown adapter binding: " ++ C.idText functionDeclaration)) Right
        (find ((== functionDeclaration) . C.declarationId) declarations)
      -- Native function bridges are synchronous; an async adapter keeps its
      -- scaffolded stub.
      when (C.declarationAsync declaration)
        (Left ("async adapter " ++ C.idText functionDeclaration ++ " cannot bind a native function yet"))
      pure (declaration,functionNative)

strict :: String -> [String] -> (Object -> Parser a) -> Value -> Parser a
strict label keys parse = withObject label $ \object -> do
  let unknown = [K.toString key | key <- KM.keys object, K.toString key `notElem` keys]
  unless (null unknown) (fail (label ++ ": unknown fields " ++ show unknown))
  parse object
validIdentifier :: String -> Either String ()
validIdentifier value = unless valid (Left ("invalid native identifier: " ++ show value))
  where valid = case value of
          c:cs -> isAscii c && (isAlpha c || c == '_') && value /= "_" &&
            all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
          [] -> False
validReference :: NativeRef -> Either String ()
validReference (NativeRef parts) = do
  unless (not (null parts)) (Left "empty native reference")
  mapM_ validIdentifier parts
instance FromJSON NativeRef where
  parseJSON value = do
    ref <- NativeRef <$> parseJSON value
    either fail pure (validReference ref)
    pure ref
instance FromJSON ConstructorStyle where
  parseJSON = withText "constructor style" $ \case
    "record" -> pure RecordConstructor
    "variant" -> pure VariantConstructor
    "unit" -> pure UnitConstructor
    _ -> fail "constructor style must be record, variant, or unit"
instance FromJSON FieldBinding where
  parseJSON = strict "native field" ["field","native"] $ \o ->
    FieldBinding <$> o .: "field" <*> o .: "native"
instance FromJSON ConstructorBinding where
  parseJSON = strict "native constructor" ["constructor","native","style","fields"] $ \o ->
    ConstructorBinding <$> o .: "constructor" <*> o .: "native" <*> o .: "style" <*> o .:? "fields" .!= []
instance FromJSON CodecBinding where
  parseJSON = strict "native codec" ["toNative","fromNative"] $ \o ->
    CodecBinding <$> o .: "toNative" <*> o .: "fromNative"
instance FromJSON TypeBinding where
  parseJSON = strict "native type" ["type","native","constructors","codec"] $ \o ->
    TypeBinding <$> (C.Id <$> o .: "type") <*> o .: "native" <*> o .:? "constructors" .!= [] <*> o .:? "codec"
instance FromJSON GeneratorBinding where
  parseJSON = strict "native generator" ["type","factory","stub"] $ \o ->
    GeneratorBinding <$> (C.Id <$> o .: "type") <*> o .: "factory" <*> o .:? "stub" .!= False
instance FromJSON FunctionBinding where
  parseJSON = strict "native function" ["declaration","native"] $ \o ->
    FunctionBinding <$> (C.Id <$> o .: "declaration") <*> o .: "native"
validateGoImport :: GoImport -> Either String ()
validateGoImport (GoImport alias path) = do
  validIdentifier alias
  let segments value = case break (== '/') value of
        (a,[]) -> [a]
        (a,_:rest) -> a : segments rest
  unless (not (null path) && all (\c -> isAscii c && (isAlphaNum c || c `elem` ("._-/~" :: String))) path &&
    all (\part -> not (null part) && part /= "." && part /= "..") (segments path))
    (Left "Go import path must be a module import path without empty or traversal segments")

instance FromJSON GoImport where
  parseJSON = strict "Go import" ["alias","path"] $ \o -> do
    value <- GoImport <$> o .: "alias" <*> o .: "path"
    either fail pure (validateGoImport value)
    pure value
instance FromJSON NativeRequest where
  parseJSON = strict "nativeBindings" ["types","generators","functions","rustCrate","goImports"] $ \o -> do
    types <- o .:? "types" .!= []
    generators <- o .:? "generators" .!= []
    NativeRequest (Bindings types generators) <$> o .:? "functions" .!= [] <*> o .:? "rustCrate" <*> o .:? "goImports" .!= []
