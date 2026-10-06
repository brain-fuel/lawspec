-- Public binding configuration is resolved before entering target emission.
module LawSpec.NativeRequest
  ( NativeRequest(..), NetworkBinding(..), networkArtifacts, FunctionBinding(..), NativeCall(..), GoImport(..), BindingPlan(..), HandlerBinding(..), FailureMapping(..)
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
import LawSpec.AbilityNames (interfaceName)
import LawSpec.Common (Artifact(..))

-- The crate is needed only by Rust test linkage, not by the semantic Core.
data NativeRequest = NativeRequest
  { requestBindings :: Bindings, requestFunctions :: [FunctionBinding]
  , requestRustCrate :: Maybe String, requestGoImports :: [GoImport]
  -- The production handler of each ability, by "<unit>::<Ability>".
  , requestHandlers :: [HandlerBinding]
  -- Native exceptions that become failures, by failure constructor.
  , requestFailures :: [FailureMapping]
  -- The node identity and trusted peers of the secure network handler.
  , requestNetwork :: Maybe NetworkBinding
  } deriving (Eq, Show)
-- network: {"identity": "<file>", "trusted": "<file>"}: the file holding a
-- node's ML-DSA-65 identity seed (64 hexadecimal digits), and the file
-- listing the SHA3-256 fingerprints of the only peers to talk to, one per
-- line; both relative to the project. Without it a node makes a fresh
-- identity and talks to any peer. No setting turns security off.
data NetworkBinding = NetworkBinding { networkIdentity :: Maybe FilePath, networkTrusted :: Maybe FilePath }
  deriving (Eq, Show)
-- failures: [{"native": [...], "failure": "<unit>::<Type>::<Constructor>"}]:
-- an adapter that fails with the type turns the native exception (a class,
-- an error type, or a panic payload type) into that constructor, which has
-- no fields or one Text field, given the exception's message.
data FailureMapping = FailureMapping { mappedNative :: NativeRef, mappedFailure :: String } deriving (Eq, Show)
-- handlers: [{"ability": "payments::Gateway", "native": [...]}]: a native
-- constructor (a class, or a function of no arguments; an IO action in
-- Haskell) that makes the production handler.
data HandlerBinding = HandlerBinding { boundAbility :: String, boundNative :: NativeRef } deriving (Eq, Show)
data GoImport = GoImport { goImportAlias :: String, goImportPath :: String } deriving (Eq, Show)
data FunctionBinding = FunctionBinding
  { functionDeclaration :: C.Id, functionNative :: NativeCall } deriving (Eq, Show)
-- How a bound adapter calls native code: a static function, a method of its
-- handle argument (`method`), or a native constructor (`constructor`), for a
-- model's start.
data NativeCall = StaticCall NativeRef | MethodCall String | ConstructorCall NativeRef
  deriving (Eq, Show)
data BindingPlan = BindingPlan
  { bindingRepresentations :: ResolvedBindings
  -- Static function bindings, and the method and constructor bindings of
  -- handles (never StaticCall).
  , bindingFunctions :: [(C.Declaration, NativeRef)]
  , bindingCalls :: [(C.Declaration, NativeCall)]
  , bindingRustCrate :: Maybe String, bindingGoImports :: [GoImport]
  -- Each bound ability's production handler, by the ability instance's key.
  , bindingHandlers :: [(C.Id, NativeRef)]
  -- The native exceptions that become failures.
  , bindingFailures :: [C.FailureBinding]
  } deriving (Eq, Show)
emptyNativeRequest :: NativeRequest
emptyNativeRequest = NativeRequest emptyBindings [] Nothing [] [] [] Nothing
emptyBindingPlan :: BindingPlan
emptyBindingPlan = BindingPlan (ResolvedBindings [] []) [] [] Nothing [] [] []
-- Whether anything besides handlers and failures is bound: they only change
-- how the tests make production handlers and catch native failures.
hasBindings :: BindingPlan -> Bool
hasBindings plan = plan { bindingHandlers = [], bindingFailures = [] } /= emptyBindingPlan

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
  handlers <- mapM handler requestHandlers
  unless (length handlers == length (nub (map fst handlers))) (Left "duplicate native handler binding")
  failures <- mapM failureMapping requestFailures
  unless (length failures == length (nub (map C.failureNative failures))) (Left "duplicate native failure mapping")
  pure (BindingPlan representations [(d, ref) | (d, StaticCall ref) <- functions]
    [(d, call) | (d, call) <- functions, not (isStatic call)] requestRustCrate requestGoImports handlers failures)
  where
    definitions = [C.declarationId (C.definitionDeclaration d) |
      u <- C.programUnits program, d <- C.unitDefinitions u]
    declarations = [d | u <- C.programUnits program, d <- C.unitDeclarations u,
      C.declarationId d `notElem` definitions]
    handles = [C.idText (C.dataId d) | d <- C.programDataDeclarations program, C.dataHandle d]
    -- An ability by <unit>::<Name>, and a parameterized one's instance by
    -- <unit>::<Name><Types> (Store Int32 is StoreInt32); the unit is the
    -- one that declares it.
    abilities = nub [ (owner ++ "::" ++ name, C.Id (C.abilityKey (C.abilityInstance a)))
                    | u <- C.programUnits program, a <- C.unitAbilities u, C.abilityOwner a == C.unitId u
                    , let owner = C.idText (C.unitId u)
                    , name <- [interfaceName a] ++ [C.abilityName a | null (C.abilityArguments a)] ]
    failureMapping FailureMapping{..} = do
      validReference mappedNative
      let (unit, rest) = breakOn mappedFailure
          (typeName, constructor) = breakOn rest
          identity = unit ++ "::type::" ++ typeName ++ "::" ++ constructor
          context = "failure mapping " ++ mappedFailure
      unless (not (null unit) && not (null typeName) && not (null constructor))
        (Left (context ++ ": write <unit>::<Type>::<Constructor>"))
      (declaration, found) <- maybe (Left (context ++ ": there is no such constructor")) Right $ case
        [(d, c) | d <- C.programDataDeclarations program, c <- C.dataConstructors d, C.idText (C.constructorId c) == identity] of
          x : _ -> Just x
          [] -> Nothing
      message <- case map C.binderType (C.constructorFields found) of
        [] -> pure False
        [C.Constructor "Text" []] -> pure True
        _ -> Left (context ++ ": the constructor must have no fields, or one Text field for the message")
      pure (C.FailureBinding (referenceParts mappedNative) (C.constructorId found) (C.Constructor (C.idText (C.dataId declaration)) []) message)
    breakOn text = case text of
      ':' : ':' : rest -> ("", rest)
      c : rest -> let (a, b) = breakOn rest in (c : a, b)
      [] -> ("", "")
    handler HandlerBinding{..} = do
      identity <- maybe (Left ("unknown ability in a handler binding: " ++ boundAbility ++ " (write <unit>::<Ability>)")) Right
        (lookup boundAbility abilities)
      validReference boundNative
      pure (identity, boundNative)
    isHandle ty = case ty of
      C.Constructor name [] -> name `elem` handles
      _ -> False
    resolve FunctionBinding{..} = do
      declaration <- maybe (Left ("unknown adapter binding: " ++ C.idText functionDeclaration)) Right
        (find ((== functionDeclaration) . C.declarationId) declarations)
      let (arguments, result) = C.functionType (C.declarationType declaration)
          context = C.idText functionDeclaration
      case functionNative of
        StaticCall ref -> validReference ref
        ConstructorCall ref -> do
          validReference ref
          unless (isHandle result) (Left (context ++ ": a constructor binding must return a handle"))
        MethodCall name -> do
          validIdentifier name
          unless (any isHandle arguments)
            (Left (context ++ ": a method binding needs a handle argument to call it on"))
      -- An async adapter binds a native function or method returning the
      -- target's asynchronous type; its bridge stays asynchronous and
      -- converts the result once it completes. A constructor is called at
      -- once, and its bridge returns a completed task.
      pure (declaration,functionNative)

isStatic :: NativeCall -> Bool
isStatic (StaticCall _) = True
isStatic _ = False

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
  parseJSON = strict "native type" ["type","native","constructors","codec","arguments"] $ \o ->
    TypeBinding <$> (C.Id <$> o .: "type") <*> o .: "native" <*> o .:? "constructors" .!= [] <*> o .:? "codec" <*> o .:? "arguments"
instance FromJSON GeneratorBinding where
  parseJSON = strict "native generator" ["type","factory","stub"] $ \o ->
    GeneratorBinding <$> (C.Id <$> o .: "type") <*> o .: "factory" <*> o .:? "stub" .!= False
instance FromJSON FunctionBinding where
  parseJSON = strict "native function" ["declaration","native","method","constructor"] $ \o -> do
    declaration <- C.Id <$> o .: "declaration"
    native <- o .:? "native"
    method <- o .:? "method"
    constructor <- o .:? "constructor"
    call <- case (native, method, constructor) of
      (Just ref, Nothing, Nothing) -> pure (StaticCall ref)
      (Nothing, Just name, Nothing) -> pure (MethodCall name)
      (Nothing, Nothing, Just ref) -> pure (ConstructorCall ref)
      _ -> fail "native function: give exactly one of native, method or constructor"
    pure (FunctionBinding declaration call)
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
instance FromJSON HandlerBinding where
  parseJSON = strict "native handler" ["ability","native"] $ \o ->
    HandlerBinding <$> o .: "ability" <*> o .: "native"
instance FromJSON FailureMapping where
  parseJSON = strict "native failure" ["native","failure"] $ \o ->
    FailureMapping <$> o .: "native" <*> o .: "failure"
instance FromJSON NativeRequest where
  parseJSON = strict "nativeBindings" ["types","generators","functions","rustCrate","goImports","handlers","failures","network"] $ \o -> do
    types <- o .:? "types" .!= []
    generators <- o .:? "generators" .!= []
    NativeRequest (Bindings types generators) <$> o .:? "functions" .!= [] <*> o .:? "rustCrate" <*> o .:? "goImports" .!= []
      <*> o .:? "handlers" .!= [] <*> o .:? "failures" .!= [] <*> o .:? "network"
instance FromJSON NetworkBinding where
  parseJSON = strict "network" ["identity","trusted"] $ \o ->
    NetworkBinding <$> o .:? "identity" <*> o .:? "trusted"

-- lawspec-network.conf, which every runtime reads when it makes a node
-- (looking in the working directory and the directories above it): a line
-- `identity <file>` and a line `trusted <file>`, relative to the project.
networkArtifacts :: NativeRequest -> [Artifact]
networkArtifacts request = case requestNetwork request of
  Nothing -> []
  Just binding ->
    [ Artifact "lawspec-network.conf" (unlines (
        "# Generated by LawSpec from lawspec.json (network). Do not edit." :
        ["identity " ++ f | Just f <- [networkIdentity binding]] ++
        ["trusted " ++ f | Just f <- [networkTrusted binding]])) "generated" "source" ]
