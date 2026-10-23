-- | Native ability interfaces and the checked bridges between native handlers
-- and logical evidence. The shared Erlang bodies serve all three languages.
-- ref:DEC-typed-core-boundary ref:DEC-idiomatic-generated-types
module LawSpec.BeamAbilities
  ( emit, nativeType, gleamImports, productionName, productionAbilities
  , interfaceModule, interfacePath, interfaceName, operationName
  , productionStub, productionExports, publicBody
  , hasDefault, defaultUnit
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamEffects as F
import qualified LawSpec.AbilityNames as N
import LawSpec.Common (Artifact(..))
import LawSpec.Typed.Beam (BeamTyped(..), Crossing(..))
import LawSpec.Typed.Plan (isTypedHandler)
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)
import Data.Char (toUpper)
import LawSpec.Naming (typeWords)
import qualified LawSpec.BeamNames as Names

interfaceName :: C.Ability -> String
interfaceName = E.pascal . N.interfaceName

productionName :: C.Ability -> String
productionName = E.snake . N.productionName

productionAbilities :: C.Unit -> [C.Ability]
productionAbilities unit = [a | a <- N.ownAbilities unit,
  not (C.isFail (C.abilityInstance a)), C.abilityNative a == Nothing || hasDefault a]

-- Defaults are compiler-owned factories even when a program binds its
-- production choice elsewhere. A bound factory may wrap the default.
defaultUnit :: C.Unit -> Bool
defaultUnit = (`elem` defaultUnits) . C.idText . C.unitId

defaultUnits :: [String]
defaultUnits = ["lawspec.time", "lawspec.randomness", "lawspec.host", "lawspec.logging", "lawspec.concurrent", "lawspec.crypto"]

hasDefault :: C.Ability -> Bool
hasDefault = (`elem` defaultUnits) . C.idText . C.abilityOwner

defaultEntry :: C.Ability -> String
defaultEntry a = "default_" ++ E.moduleName (C.abilityOwner a) ++ "_" ++ productionName a

isSignature :: C.Ability -> Bool
isSignature = (== "lawspec.crypto::ability::Signature") . C.abilityKey . C.abilityInstance

-- An ability made with a resource (ability A with T) has a native handler
-- factory of one argument: the case's T, shared by every such handler.
productionExports :: C.Ability -> [(String,Int)]
productionExports a = [(productionName a,maybe 0 (const 1) (C.abilityResource a))] ++ [("slh_dsa_signature_handler",0) | isSignature a]

-- | Each operation that fails with E, with E.
failingOperations :: C.Ability -> [(String,C.Type,C.Type)]
failingOperations a = [(op,ty,failure) | (op,ty) <- C.abilityOperations a,
  Just (C.AbilityRef _ [failure]) <- [lookup op (C.abilityFailures a)]]

-- | The form of an operation that gives its failure as a value.
tryName :: C.Ability -> String -> String
tryName a op = E.snake (interfaceName a) ++ "_try_" ++ E.snake op

operationName :: String -> String -> String
operationName "gleam" = E.gleamName . E.snake
operationName _ = E.snake

publicName :: String -> String -> String
publicName target = E.nativeName target . E.snake

builderName :: String -> C.Ability -> String
builderName target = publicName target . interfaceName

interfacePath :: C.Id -> String
interfacePath owner = "lawspec/abilities/" ++ E.gleamPath owner

interfaceModule :: String -> C.Ability -> String
interfaceModule "gleam" a = map (\c -> if c == '/' then '@' else c) (interfacePath (C.abilityOwner a))
interfaceModule "elixir" a = "LawSpec.Abilities." ++ intercalate "."
  (map E.pascal (split (C.idText (C.abilityOwner a)))) ++ "." ++ interfaceName a
  where split s = case break (== '.') s of (x,[]) -> [x]; (x,_:xs) -> x : split xs
interfaceModule _ a = "lawspec_abilities_" ++ E.moduleName (C.abilityOwner a)

alias :: C.Ability -> String
alias a = "abilities_" ++ E.moduleName (C.abilityOwner a)

nativeType :: String -> [C.Unit] -> C.AbilityRef -> Either String D.Doc
nativeType target units ability = do
  a <- maybe (Left ("unknown BEAM ability " ++ C.abilityKey ability)) Right (N.abilityOf units ability)
  pure $ case target of
    "gleam" -> D.text (alias a ++ "." ++ interfaceName a)
    "elixir" -> X.remote (interfaceModule target a) "t" []
    _ -> E.remote (interfaceModule target a) (E.snake (interfaceName a)) []

gleamImports :: [C.Unit] -> [C.AbilityRef] -> Either String [D.Doc]
gleamImports units refs = nub <$> mapM imported refs
  where imported ref = do
          a <- maybe (Left ("unknown BEAM ability " ++ C.abilityKey ref)) Right (N.abilityOf units ref)
          pure (D.text ("import " ++ interfacePath (C.abilityOwner a) ++ " as " ++ alias a))

-- Public native definitions reuse the context of generated interfaces. The
-- interfaces supplied by the caller override those abilities in that context.
publicBody :: [C.Unit] -> [(C.AbilityRef,D.Doc)] -> D.Doc -> Either String D.Doc
publicBody _ [] body = pure body
publicBody units supplied body = do
  parts <- mapM (\(a,v) -> F.interfaceParts units a v) supplied
  handlers <- forM supplied $ \(a,v) -> do
    h <- F.fromNative units a (D.text "BaseSchema") (D.text "Symbols") v
    pure (E.binary (C.abilityKey a),h)
  pure (E.remote "lawspec_beam_effects" "with_native_context"
    [E.array [E.remote "erlang" "element" [D.text "1",p] | p <- parts],
     E.lambda [D.text "FreshSymbols"] (E.remote "lawspec_data" "schema" [D.text "FreshSymbols"]),
     E.lambda [D.text "BaseSchema",D.text "Symbols"] (E.sequenceDoc
       [D.text "Schema = " <> E.remote "lawspec_beam_effects" "install" [D.text "BaseSchema",E.record handlers],body])])

productionStub :: String -> Int -> [(C.Id,String)] -> C.Ability -> Either String [D.Doc]
productionStub target _ _ ability | hasDefault ability = pure (concat
  [defaultFactory target ability name entry | (name,entry) <-
    [(productionName ability,defaultEntry ability)] ++
    [("slh_dsa_signature_handler","default_lawspec_crypto_slh_dsa_signature_handler") | isSignature ability]])
productionStub target bits names ability = do
  fields <- forM (C.abilityOperations ability) $ \(op,ty) -> do
    -- A stub operation's arguments are named for their types, unused.
    let args = [D.text (unused v) | v <- X.variables [unwords (typeWords t) | t <- fst (C.functionType ty)]]
        unused v = if target == "erlang" then "_" ++ concatMap capital (words (map (\c -> if c == '_' then ' ' else c) v)) else "_" ++ v
        capital (c : cs) = toUpper c : cs
        capital [] = []
        message = "Not implemented: " ++ C.abilityKey (C.abilityInstance ability) ++ "." ++ op
    pure $ case target of
      -- A stub's operations are a constructor's arguments, at column 4; a
      -- sole one hugs the call, as gleam format writes it.
      "gleam" | length (C.abilityOperations ability) == 1 -> G.huggedLambda (alias ability ++ "." ++ builderName target ability) 2 args (D.text "panic as " <> G.string message)
      "gleam" -> G.lambda 4 args (D.text "panic as " <> G.string message)
      "elixir" -> D.group (D.text "fn " <> mconcat [D.joinWith (D.text ", ") args <> D.text " " | not (null args)] <> D.text "->" <>
        D.nest 2 (D.softline <> D.text "raise " <> X.string message) <> D.softline <> D.text "end")
      _ -> E.lambda args (E.remote "erlang" "error" [E.tuple [E.atom "not_implemented",E.binary message]])
  _ <- mapM (operationType target bits names . snd) (C.abilityOperations ability)
  resource <- traverse (case target of
    "gleam" -> G.nativeType False names []
    "elixir" -> X.nativeType bits names []
    _ -> E.nativeType bits names []) (C.abilityResource ability)
  let name = productionName ability
      keys = map (operationName target . fst) (C.abilityOperations ability)
      resourceTypes = maybe [] pure resource
  pure $ case target of
    "gleam" -> [G.function name [D.text "_resource: " <> t | t <- resourceTypes] (D.text (alias ability ++ "." ++ interfaceName ability))
      [case fields of
        [hugged] | length (C.abilityOperations ability) == 1 -> hugged
        _ -> G.call (alias ability ++ "." ++ builderName target ability) fields]]
    "elixir" -> [X.typeAttribute "spec" (X.call name resourceTypes) (X.remote (interfaceModule target ability) "t" []),
      X.function name [D.text "_resource" | _ <- resourceTypes] [D.delimit 2 ("%" ++ interfaceModule target ability ++ "{") "}"
        [D.text key <> D.text ": " <> f | (key,f) <- zip keys fields]]]
    _ -> [E.spec name resourceTypes (E.remote (interfaceModule target ability) (E.snake (interfaceName ability)) []),
      E.function name [D.text "_Resource" | _ <- resourceTypes] [E.record (zip (map E.atom keys) fields)]]

defaultFactory :: String -> C.Ability -> String -> String -> [D.Doc]
defaultFactory target ability name entry = case target of
  "gleam" -> [G.external "lawspec_abilities" entry name []
    (D.text (alias ability ++ "." ++ interfaceName ability))]
  "elixir" -> [X.typeAttribute "spec" (X.call name []) (X.remote (interfaceModule target ability) "t" []),
    X.function name [] [X.remote ":lawspec_abilities" entry []]]
  _ -> [E.spec name [] (E.remote (interfaceModule target ability) (E.snake (interfaceName ability)) []),
    E.function name [] [E.remote "lawspec_abilities" entry []]]

operationType :: String -> Int -> [(C.Id,String)] -> C.Type -> Either String D.Doc
operationType target bits names ty = do
  let (arguments,result) = C.functionType ty
      native = case target of "gleam" -> G.nativeType False names []; "elixir" -> X.nativeType bits names []; _ -> E.nativeType bits names []
  args <- mapM native arguments
  out <- native result
  pure $ case target of
    "gleam" -> D.text "fn" <> D.delimit 2 "(" ")" args <> D.text " -> " <> out
    "elixir" -> D.text "(" <> mconcat [D.joinWith (D.text ", ") args <> D.text " " | not (null args)] <> D.text "-> " <> out <> D.text ")"
    _ -> E.funType args out

emit :: String -> D.Layout -> Int -> Maybe BeamTyped -> [C.DataDeclaration] -> [C.Unit] -> Bool -> Either String [Artifact]
emit target layout bits typed declarations units boundSchema = do
  names <- E.dataNames declarations
  native <- concat <$> mapM (unitInterfaces names) units
  pieces <- concat <$> mapM abilityBodies (F.abilities units)
  specs <- concat <$> mapM handlerBodies (F.handlers units)
  boundHelpers <- if target == "gleam" then gleamBoundHelpers else pure []
  let exports = [(name ++ suffix,arity) | a <- F.abilities units,
        Right name <- [F.abilityEntry units (C.abilityInstance a)],
        (suffix,arity) <- [("_parts",1),("_to_native",3),("_from_native",3),("_production",2),("_recording",2)] ++
          [("_production",3) | C.abilityResource a /= Nothing]] ++
        [(name ++ suffix,arity) | h <- F.handlers units, Right name <- [F.handlerEntry units (C.handlerId h)],
          (suffix,arity) <- [("",2),("_native",1)] ++ (if C.handlerState h /= Nothing then [("_state",1),("_set_state",2)] else []) ++
            (if C.handlerState h /= Nothing && typedHandler h then [("_typed_state",1),("_set_typed_state",2)] else [])]
      contextFunction = E.function "with_context" [D.text "_Body"]
        [E.remote "lawspec_beam_effects" "with_native_context" [E.array [],
          E.lambda [symbols] (E.remote "lawspec_data" "schema" [symbols]),
          E.lambda [schema,symbols] (E.apply (D.text "_Body") [E.tuple [E.atom "lawspec_context",schema,symbols]])]]
      defaults = [(defaultEntry a,0) | a <- F.abilities units, hasDefault a] ++
        [("default_lawspec_crypto_slh_dsa_signature_handler",0) | any isSignature (F.abilities units)]
      shared = Artifact "src/lawspec_abilities.erl"
        (D.render layout (E.moduleDoc "lawspec_abilities" (("with_context",1):exports ++ defaults) (contextFunction : pieces ++ specs))) "generated" "source"
  pure (shared : native ++ boundHelpers)
  where
    schema = D.text "Schema"
    symbols = D.text "Symbols"
    handler = D.text "_LsHandler"
    -- A typed spec handler runs typed code: its state stays in its cell's
    -- process. ref:DEC-typed-native-definitions
    typedHandler h = maybe False (\t -> isTypedHandler (beamTypedPlan t) h) typed
    typedStateful h = typedHandler h && C.handlerState h /= Nothing
    unitAtom = E.atom (if target == "gleam" then "nil" else "ok")
    context = E.tuple [E.atom "lawspec_context",schema,symbols]
    contextType "gleam" = D.text "effects.Context"
    contextType "elixir" = D.text ":lawspec_beam_effects.context()"
    contextType _ = D.text "lawspec_beam_effects:context()"
    nativeOwner ability = maybe (Left "missing BEAM ability owner") Right
      (lookup (C.abilityOwner ability) [(C.unitId u,u) | u <- units])
    convert direction s ty value = do
      ref <- E.typeReference ty
      pure (E.remote "lawspec_beam_schema" direction [value,ref,s])
    interfaceNameDoc a = case target of
      "gleam" -> D.text (interfaceName a)
      "elixir" -> X.remote (interfaceModule target a) "t" []
      _ -> E.call (E.snake (interfaceName a)) []
    own u = [a | a <- N.ownAbilities u, not (C.isFail (C.abilityInstance a))]
    unitInterfaces names unit = do
      let as = own unit
          hs = C.unitHandlers unit
          identifiers = map (E.snake . interfaceName) as
          fields a = map (operationName target . fst) (C.abilityOperations a)
          stateful = [h | h <- hs, C.handlerState h /= Nothing]
          tries = [tryName a op | a <- as, (op,_,_) <- failingOperations a]
          publicFunctions = map (handlerPublicName as) hs ++
            concat [[handlerPublicName as h ++ "_state",handlerPublicName as h ++ "_set_state"] | h <- stateful] ++
            concat [[handlerPublicName as h ++ "_typed_state",handlerPublicName as h ++ "_set_typed_state"] | h <- stateful, typedHandler h] ++
            [t | target /= "elixir", t <- tries] ++
            ["recording_" ++ E.snake (interfaceName a) | a <- as] ++
            [n | a <- as, target == "gleam", let raw = E.snake (interfaceName a),
              n <- [builderName target a,"managed_" ++ raw,"parts_" ++ raw] ++ [raw ++ "_" ++ field | field <- fields a]]
      unless (length identifiers == length (nub identifiers)) (Left "BEAM ability names collide after normalization")
      unless (length publicFunctions == length (nub publicFunctions))
        (Left "BEAM handler constructors and operation functions collide after normalization")
      unless (all (\a -> length (interfaceModule target a) <= 255 && length (interfaceName a) <= 255 &&
        all (\(op,ty) -> length (operationName target op) <= 255 && length (fst (C.functionType ty)) <= 253)
          (C.abilityOperations a)) as && all ((<= 255) . length) publicFunctions)
        (Left "BEAM ability names or operation arities exceed the Erlang limits")
      mapM_ (\a -> unless (let fs = fields a in length fs == length (nub fs) && all (`notElem` ["__lawspec_origin__","lawspec_origin"]) fs)
        (Left "BEAM operation names collide after normalization or with handler metadata")) as
      types <- concat <$> mapM (interface names) as
      public <- publicConstructors names unit hs as
      case target of
        "elixir" -> pure (types ++ public)
        "gleam" -> do
          let operationTypes = [ty | a <- as, (_,ty) <- C.abilityOperations a] ++
                [failure | a <- as, (_,_,failure) <- failingOperations a] ++
                [t | h <- stateful, Just (t,_) <- [C.handlerState h]]
          imports <- gleamImports units [ref | h <- hs, ref <- C.handlerAbilities h,
            maybe False ((/= C.unitId unit) . C.abilityOwner) (N.abilityOf units ref)]
          pure [Artifact ("src/" ++ interfacePath (C.unitId unit) ++ ".gleam")
            (D.render (G.layoutFor layout) (G.fileDoc False (D.text "import lawspec/effects" : imports ++
              G.imports False operationTypes ++ map artifactDoc types ++ map artifactDoc public))) "generated" "source"
            | not (null as && null hs)]
        _ -> do
          let exports = [(handlerPublicName as h,1) | h <- hs] ++ [("recording_" ++ E.snake (interfaceName a),2) | a <- as] ++
                concat [[(handlerPublicName as h ++ "_state",1),(handlerPublicName as h ++ "_set_state",2)] | h <- stateful] ++
                concat [[(handlerPublicName as h ++ "_typed_state",1),(handlerPublicName as h ++ "_set_typed_state",2)] | h <- stateful, typedHandler h] ++
                [(tryName a op,1 + length (fst (C.functionType ty))) | a <- as, (op,ty,_) <- failingOperations a]
              typeExports = [D.text "-export_type(" <> E.array [E.atom n <> D.text "/0" | n <- identifiers] <> D.text ")." | not (null as)]
          pure [Artifact ("src/lawspec_abilities_" ++ E.moduleName (C.unitId unit) ++ ".erl")
            (D.render layout (E.moduleDoc ("lawspec_abilities_" ++ E.moduleName (C.unitId unit)) exports
              (typeExports ++ map artifactDoc types ++ map artifactDoc public))) "generated" "source" | not (null as && null hs)]
    artifactDoc = D.text . artifactContent
    fragment doc = Artifact "" (D.render targetLayout doc) "generated" "source"
    targetLayout = case target of
      "gleam" -> G.layoutFor layout
      "elixir" -> X.layoutFor layout
      _ -> layout
    interface names ability = do
      ts <- mapM (operationType target bits names . snd) (C.abilityOperations ability)
      let n = E.snake (interfaceName ability)
          fields = map (operationName target . fst) (C.abilityOperations ability)
          names' = map D.text fields
      case target of
        "erlang" -> do
          tries <- forM (failingOperations ability) $ \(op,ty,failure) -> do
            let (args,result) = C.functionType ty
                values = [D.text ("Value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            inputs <- mapM (E.nativeType bits names []) args
            out <- E.nativeType bits names [] result
            failed <- E.nativeType bits names [] failure
            pure (fragment (E.spec (tryName ability op) (E.call n [] : inputs)
              (D.group (E.tuple [E.atom "ok",out] <> D.softline <> D.text "| " <> E.tuple [E.atom "error",failed])) <> D.hardline <>
              E.function (tryName ability op) (D.text "Handler" : values)
                [E.remote "lawspec_beam_effects" "native_try" [E.lambda []
                  (E.apply (E.remote "maps" "get" [E.atom (operationName target op),D.text "Handler"]) values)]]))
          pure (fragment (D.text "-type " <> E.call n [] <> D.text " :: " <>
            D.delimit 4 "#{" "}" ([E.field ":=" (E.atom key) ty | (key,ty) <- zip fields ts] ++
              [E.atom "__lawspec_origin__" <> D.text " => lawspec_beam_effects:handler_origin()"]) <> D.text ".") : tries)
        "elixir" -> do
          tries <- forM (failingOperations ability) $ \(op,ty,failure) -> do
            let (args,_) = C.functionType ty
                values = [D.text ("value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            inputs <- mapM (X.nativeType bits names []) args
            out <- X.nativeType bits names [] (snd (C.functionType ty))
            failed <- X.nativeType bits names [] failure
            let name = "try_" ++ operationName target op
            pure (X.typeAttribute "spec" (X.call name (D.text "t()" : inputs))
              (X.tuple [X.atom "ok",out] <> D.text " | " <> X.tuple [X.atom "error",failed]) <> D.hardline <>
              X.function name (D.text "handler" : values)
                [X.remote ":lawspec_beam_effects" "native_try" [D.text "fn -> handler." <> D.text (operationName target op) <>
                  D.text "." <> D.delimit 2 "(" ")" values <> D.text " end"]])
          let body = [D.text "@enforce_keys " <> X.array (map X.atom fields),
                D.text "defstruct " <> X.array (map X.atom fields ++ [D.text "__lawspec_origin__: :none"]),
                X.typeAttribute "type" (D.text "t") (D.delimit 2 "%__MODULE__{" "}"
                  ([X.atom key <> D.text " => " <> ty | (key,ty) <- zip fields ts] ++
                    [D.text "__lawspec_origin__: :lawspec_beam_effects.handler_origin()"]))] ++ tries
          pure [Artifact ("lib/" ++ interfacePath (C.abilityOwner ability) ++ "/" ++ n ++ ".ex")
            (D.render (X.layoutFor layout) (X.moduleDoc (interfaceModule target ability) False body)) "generated" "source"]
        _ -> do
          let ty = D.text (interfaceName ability)
              constructor origin = G.call (interfaceName ability) (origin : names')
              arguments = [D.text field <> D.text ": " <> t | (field,t) <- zip fields ts]
              definition = D.text "pub opaque type " <> ty <> D.text " {" <>
                D.nest 2 (D.hardline <> G.call (interfaceName ability) (D.text "lawspec_origin: effects.HandlerOrigin" : arguments)) <>
                D.hardline <> D.text "}"
              builder = G.function (builderName target ability) arguments ty [constructor (G.call "effects.native_origin" [])]
              managed = G.function ("managed_" ++ n) (D.text "origin: effects.HandlerOrigin" : arguments) ty [constructor (D.text "origin")]
              partsType = G.tuple [D.text "effects.HandlerOrigin",G.tuple ts]
              parts = G.function ("parts_" ++ n) [D.text "handler: " <> ty] partsType
                [G.tuple [D.text "handler.lawspec_origin",G.tuple [D.text ("handler." ++ f) | f <- fields]]]
          ops <- forM (zip (C.abilityOperations ability) fields) $ \((_,signature),field) -> do
            let (args,result) = C.functionType signature
            inputs <- mapM (G.nativeType False names []) args
            out <- G.nativeType False names [] result
            let values = [D.text ("value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            pure (G.function (n ++ "_" ++ field) (D.text "handler: " <> ty :
              [v <> D.text ": " <> t | (v,t) <- zip values inputs]) out [G.call ("handler." ++ field) values])
          tries <- forM (failingOperations ability) $ \(op,signature,failure) -> do
            let (args,result) = C.functionType signature
                values = [D.text ("value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            inputs <- mapM (G.nativeType False names []) args
            out <- G.nativeType False names [] result
            failed <- G.nativeType False names [] failure
            pure (G.function (tryName ability op) (D.text "handler: " <> ty : [v <> D.text ": " <> t | (v,t) <- zip values inputs])
              (G.call "Result" [out,failed]) [G.call "effects.attempt" [D.text "fn() { " <> G.call ("handler." ++ operationName target op) values <> D.text " }"]])
          pure (map fragment (definition : builder : managed : parts : ops ++ tries))
    typedStateName public = E.pascal public ++ "TypedState"
    -- A Gleam handler named like its ability's builder (handler counter for
    -- Counter) takes a _handler suffix, so both stay public.
    handlerPublicName as h =
      let base = publicName target (C.handlerName h)
          taken = ["recording_" ++ E.snake (interfaceName a) | a <- as] ++
            [n | a <- as, target == "gleam", let raw = E.snake (interfaceName a),
              n <- [builderName target a,"managed_" ++ raw,"parts_" ++ raw] ++
                [raw ++ "_" ++ field | field <- map (operationName target . fst) (C.abilityOperations a)]]
      in if base `elem` taken then base ++ "_handler" else base
    -- A handler of several abilities gives one native interface for each,
    -- all answered from its one state.
    publicConstructors names unit hs as = do
      specBodies <- forM hs $ \h -> do
        types <- forM (C.handlerAbilities h) $ \ref -> do
          a <- maybe (Left "unknown native spec handler ability") Right (N.abilityOf units ref)
          if C.abilityOwner a == C.unitId unit then pure (interfaceNameDoc a) else nativeType target units ref
        entry <- F.handlerEntry units (C.handlerId h)
        let ty = case types of
              [single] -> single
              _ | target == "gleam" -> G.tuple types
                | otherwise -> E.tuple types
        pure (handlerPublicName as h,entry ++ "_native",[contextType target],ty)
      -- A handler with state reads and replaces it in its native types,
      -- through the interface of its first ability.
      accessors <- fmap concat $ forM [h | h <- hs, C.handlerState h /= Nothing] $ \h -> do
        entry <- F.handlerEntry units (C.handlerId h)
        first <- maybe (Left "unknown native spec handler ability") Right (N.abilityOf units (C.handlerAbility h))
        handle <- if C.abilityOwner first == C.unitId unit then pure (interfaceNameDoc first) else nativeType target units (C.handlerAbility h)
        stateType <- case C.handlerState h of
          Just (t,_) -> case target of
            "gleam" -> G.nativeType False names [] t
            "elixir" -> X.nativeType bits names [] t
            _ -> E.nativeType bits names [] t
          Nothing -> Left "a stateless handler has no state"
        let done = case target of "gleam" -> D.text "Nil"; "elixir" -> D.text ":ok"; _ -> D.text "ok"
            public = handlerPublicName as h
            -- The typed state, which the application keeps without looking
            -- inside: maps for KeyVal, sets for Set.
            typedType = case target of
              "gleam" -> D.text (typedStateName public)
              "elixir" -> D.text "term()"
              _ -> D.text "term()"
        pure ([(public ++ "_state",entry ++ "_state",[handle],stateType),
              (public ++ "_set_state",entry ++ "_set_state",[handle,stateType],done)] ++
              [(public ++ "_typed_state",entry ++ "_typed_state",[handle],typedType) | typedHandler h] ++
              [(public ++ "_set_typed_state",entry ++ "_set_typed_state",[handle,typedType],done) | typedHandler h])
      recordings <- forM as $ \a -> do
        entry <- F.abilityEntry units (C.abilityInstance a)
        pure ("recording_" ++ E.snake (interfaceName a),entry ++ "_recording",[contextType target,interfaceNameDoc a],interfaceNameDoc a)
      let typedStates = [D.text ("/// A typed state of " ++ C.handlerName h ++ ": its KeyVal values are maps, its Set values sets.") <> D.hardline <>
            D.text ("pub type " ++ typedStateName (handlerPublicName as h)) | target == "gleam", h <- hs, typedStateful h]
          bodies = typedStates ++ map publicFunction (specBodies ++ accessors ++ recordings)
      pure $ if target == "elixir" then
        [Artifact ("lib/lawspec/handlers/" ++ E.moduleName (C.unitId unit) ++ ".ex")
          (D.render (X.layoutFor layout) (X.moduleDoc ("LawSpec.Handlers." ++ E.pascal (C.idText (C.unitId unit))) False bodies)) "generated" "source"
          | not (null bodies)] else map fragment bodies
    publicFunction (name,entry,args,result) =
      let values = [D.text ("value" ++ show i) | (i,_) <- zip [0::Int ..] args]
      in case target of
        "gleam" -> G.external "lawspec_abilities" entry name [v <> D.text ": " <> ty | (v,ty) <- zip values args] result
        "elixir" -> X.typeAttribute "spec" (X.call name args) result <> D.hardline <>
          X.function name values [X.remote ":lawspec_abilities" entry values]
        _ -> E.spec name args result <> D.hardline <>
          E.function name [D.text ("Value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            [E.remote "lawspec_abilities" entry [D.text ("Value" ++ show i) | (i,_) <- zip [0::Int ..] args]]
    abilityBodies ability = do
      name <- F.abilityEntry units (C.abilityInstance ability)
      home <- nativeOwner ability
      let operations = C.abilityOperations ability
          operationFields = map (operationName target . fst) operations
          key = E.binary (C.abilityKey (C.abilityInstance ability))
          native = D.text "_LsNative"
          parts = if target == "gleam" then
              E.apply (E.lambda [E.tuple [D.text "_Origin",D.text "_Ops"]]
                (E.tuple [D.text "_Origin",E.remote "erlang" "tuple_to_list" [D.text "_Ops"]]))
                [E.remote (interfaceModule target ability) ("parts_" ++ E.snake (interfaceName ability)) [native]]
            else E.tuple [E.remote "maps" "get" [E.atom "__lawspec_origin__",native,E.atom "none"],
              E.array [E.remote "maps" "get" [E.atom field,native] | field <- operationFields]]
          make = makeInterface ability
      callbacks <- forM operations $ \(op,ty) -> do
        let (args,result) = C.functionType ty
            values' = map D.text (argumentNames "Native" args)
        logical <- sequence [convert "from_native" schema t v | (t,v) <- zip args values']
        output <- convert "to_native" schema result (E.remote "lawspec_beam_effects" "invoke"
          [handler,schema,E.binary op,E.array logical])
        -- An operation that fails with E fails natively with a native E.
        raised <- case lookup op (C.abilityFailures ability) of
          Just failing@(C.AbilityRef _ [failure]) -> do
            back <- convert "to_native" schema failure (D.text "_LsFailure")
            pure (E.remote "lawspec_beam_effects" "native_raise"
              [E.binary (C.abilityKey failing),E.lambda [D.text "_LsFailure"] back,E.lambda [] output])
          _ -> pure output
        pure (E.lambda values' raised)
      logical <- logicalOperations ability schema operations
      -- ability A with T: the native factory is given the case's T.
      made <- case C.abilityResource ability of
        Nothing -> pure []
        Just t -> pure <$> convert "to_native" schema t (D.text "_LsResource")
      production <- case C.abilityNative ability of
        Nothing | hasDefault ability -> pure (E.remote "lawspec_beam_defaults" "handler" [key])
        Nothing -> pure (E.remote "lawspec_abilities" (name ++ "_from_native")
          [schema,symbols,E.remote (E.nativeModule target home) (productionName ability) made])
        Just ref -> do
          made' <- if target == "gleam" then pure (E.remote "erlang" "tuple_to_list"
              [E.remote "lawspec@native_handlers" (name ++ "_make") made])
            else do
              call <- E.nativeCall target ref made
              pure (E.apply (E.lambda [native] (E.array [E.remote "maps" "get" [E.atom field,native] | field <- operationFields])) [call])
          bound <- logicalOperations ability (D.text "_LsNativeSchema") operations
          pure (E.apply (E.lambda [D.text "_LsOperations"] (E.sequenceDoc
            [D.text "_LsNativeSchema = " <> (if boundSchema then E.remote "lawspec_native_bindings" "schema" [schema] else schema),bound])) [made'])
      decoded <- F.fromNative units (C.abilityInstance ability) schema symbols native
      recorded <- F.toNative units (C.abilityInstance ability) schema symbols
        (E.remote "lawspec_beam_effects" "recording" [schema,decoded])
      pure $ [E.function (name ++ "_parts") [native] [parts],
        E.function (name ++ "_to_native") [schema,symbols,handler]
          [D.text "_LsOperations = " <> E.array callbacks,
           make (E.remote "lawspec_beam_effects" "origin" [schema,symbols,key,handler,D.text "_LsOperations"])],
        E.function (name ++ "_from_native") [schema,symbols,native]
          [D.text "{_LsOrigin, _LsOperations} = " <> E.call (name ++ "_parts") [native],
           E.remote "lawspec_beam_effects" "recover_handler" [D.text "_LsOrigin",key,symbols,D.text "_LsOperations",E.lambda [] logical]],
        E.function (name ++ "_production") ([schema,symbols] ++ [D.text "_LsResource" | not (null made)]) [production]] ++
        [E.function (name ++ "_production") [D.text "Schema",D.text "Symbols"]
          [E.remote "erlang" "error" [E.tuple [E.atom "lawspec",E.tuple [E.atom "resource_required",key]]]] | not (null made)] ++
        [
        E.function (name ++ "_recording") [context,native] [recorded]] ++
        [E.function (defaultEntry ability) []
          [D.text "Schema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []],
           D.text "_LsHandler = " <> E.remote "lawspec_beam_defaults" "handler" [key],
           D.text "_LsOperations = " <> E.array callbacks, make (E.atom "none")] | hasDefault ability] ++
        [E.function "default_lawspec_crypto_slh_dsa_signature_handler" []
          [D.text "Schema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []],
           D.text "_LsHandler = " <> E.remote "lawspec_beam_crypto" "slh_dsa_signature_handler" [],
           D.text "_LsOperations = " <> E.array callbacks, make (E.atom "none")] | isSignature ability]
    -- A native interface of an ability, its operations the list
    -- _LsOperations and its origin the given one.
    makeInterface ability origin =
      let operations = C.abilityOperations ability
          operationFields = map (operationName target . fst) operations
          values = [E.remote "lists" "nth" [D.text (show i),D.text "_LsOperations"] | (i,_) <- zip [1::Int ..] operations]
      in case target of
        "gleam" -> E.remote (interfaceModule target ability) ("managed_" ++ E.snake (interfaceName ability)) (origin:values)
        "elixir" -> E.record ((E.atom "__struct__",E.atom ("Elixir." ++ interfaceModule target ability)) :
          (E.atom "__lawspec_origin__",origin) : zip (map E.atom operationFields) values)
        _ -> E.record ((E.atom "__lawspec_origin__",origin) : zip (map E.atom operationFields) values)
    logicalOperations ability nativeSchema operations = do
      clauses <- forM (zip [1::Int ..] operations) $ \(i,(op,ty)) -> do
        let (args,result) = C.functionType ty
            values = map D.text (argumentNames "" args)
        arguments <- sequence [convert "to_native" nativeSchema t v | (t,v) <- zip args values]
        output <- convert "from_native" nativeSchema result (E.apply (E.remote "lists" "nth"
          [D.text (show i),D.text "_LsOperations"]) arguments)
        -- An operation that fails with E: a native handler fails with a
        -- native E, which becomes the Fail E failure.
        checked <- case lookup op (C.abilityFailures ability) of
          Just failing@(C.AbilityRef _ [failure]) -> do
            ref <- E.typeReference failure
            pure (E.remote "lawspec_beam_effects" "native_failures" [E.binary (C.abilityKey failing),
              E.lambda [D.text "_LsNativeFailure"] (E.remote "lawspec_beam_schema" "from_native"
                [D.text "_LsNativeFailure",ref,nativeSchema]),E.lambda [] output,E.array []])
          _ -> pure output
        pure (E.binary op,E.lambda [D.text "_LsCurrentSchema",E.array values] checked)
      pure (E.remote "lawspec_beam_effects" "stateless" [E.record clauses])
    handlerBodies h = case typed of
      Just t | isTypedHandler (beamTypedPlan t) h -> typedHandlerBodies t h
      _ -> dynamicHandlerBodies h
    -- A typed spec handler: its clauses are typed functions, its state a
    -- typed value in a cell, and its native interfaces call them directly,
    -- with native values. Laws reach it through the same handler term.
    -- ref:DEC-typed-native-definitions
    typedHandlerBodies t h = do
      name <- F.handlerEntry units (C.handlerId h)
      answered <- forM (C.handlerAbilities h) $ \ref -> maybe (Left "unknown spec handler ability") Right (N.abilityOf units ref)
      let stateful = C.handlerState h /= Nothing
          clauseOf a (op,ty) = do
            identity <- maybe (Left "missing BEAM spec handler clause") Right (lookup op (C.handlerClauses h))
            f <- maybe (Left ("untyped BEAM clause " ++ C.idText identity)) Right (beamTypedFunction t identity)
            let failure = case lookup op (C.abilityFailures a) of
                  Just failing@(C.AbilityRef _ [ft]) -> Just (failing,ft)
                  _ -> Nothing
            pure (op,ty,f,beamTypedContextual t identity,failure)
          -- A clause on typed arguments, in the caller (stateless) or in the
          -- handler's cell (with state).
          invoke currentSchema (_,_,f,contextual,_) typedArgs =
            let handlerContext = if contextual then [currentSchema,symbols] else []
            in if stateful
              then E.remote "lawspec_beam_fast" (if contextual then "update_tracked" else "update") [handler,E.lambda [D.text "_LsState"]
                (E.caseOf (E.remote "lawspec_typed" f (handlerContext ++ D.text "_LsState" : typedArgs))
                  [(beamTypedPair t (D.text "_LsResult") (D.text "_LsNext"),D.text "{_LsResult, _LsNext}")])]
              else E.remote "lawspec_typed" f (handlerContext ++ (if null typedArgs then [unitAtom] else typedArgs))
          typedArguments crossing args prefix = unzip
            [ (E.assign typed (beamTypedConvert t crossing ty (D.text name)), D.text typed)
            | (ty,name,typed) <- zip3 args (argumentNames prefix args) (argumentNames "Typed" args) ]
      clauses <- forM answered $ \a -> forM (C.abilityOperations a) $ \o -> clauseOf a o
      let lawClause c@(op,ty,_,_,_) =
            let (args,result) = C.functionType ty
                (bindings,typedArgs) = typedArguments FromDynamic args ""
            in (E.binary op,E.lambda ([D.text "_LsCurrentSchema",E.array (map D.text (argumentNames "" args))] ++ [handler | stateful])
                (E.sequenceDoc (bindings ++ [beamTypedConvert t ToDynamic result (invoke (D.text "_LsCurrentSchema") c typedArgs)])))
          operations = E.record (map lawClause (concat clauses))
      body <- case beamTypedStart t (C.handlerId h) of
        Just start | stateful -> pure (E.remote "lawspec_beam_fast" "handler" [schema,E.remote "lawspec_typed" start [schema,symbols],operations])
        _ | stateful -> Left ("typed BEAM handler without a typed start: " ++ C.handlerName h)
        _ -> pure (E.remote "lawspec_beam_effects" "stateless" [operations])
      interfaces <- forM (zip3 [0::Int ..] answered clauses) $ \(k,a,cs) -> do
        callbacks <- forM cs $ \c@(_,ty,_,_,failure) -> do
          let (args,result) = C.functionType ty
              (bindings,typedArgs) = typedArguments FromNative args "Native"
              output = beamTypedConvert t ToNative result (invoke schema c typedArgs)
              raised = case failure of
                Just (failing,ft) -> E.remote "lawspec_beam_effects" "native_raise" [E.binary (C.abilityKey failing),
                  E.lambda [D.text "_LsFailure"] (beamTypedConvert t ToNative ft (beamTypedConvert t FromDynamic ft (D.text "_LsFailure"))),
                  E.lambda [] output]
                Nothing -> output
          pure (E.lambda (map D.text (argumentNames "Native" args)) (E.sequenceDoc (bindings ++ [raised])))
        let origin = E.remote "lawspec_beam_effects" "origin" [schema,symbols,E.binary (C.abilityKey (C.abilityInstance a)),handler,D.text "_LsOperations"]
        pure (E.function (name ++ "_typed_" ++ show k) [schema,symbols,handler]
          [D.text "_LsOperations = " <> E.array callbacks,makeInterface a origin])
      let made = [E.call (name ++ "_typed_" ++ show k) [schema,symbols,handler] | (k,_) <- zip [0::Int ..] answered]
          native = E.function (name ++ "_native") [context]
            [D.text "_LsHandler = " <> E.call name [schema,symbols],case made of [single] -> single; several -> E.tuple several]
      accessors <- case C.handlerState h of
        Nothing -> pure []
        Just (st,_) -> do
          first <- F.abilityEntry units (C.handlerAbility h)
          let origin = D.text "{_LsOrigin, _} = " <> E.call (first ++ "_parts") [D.text "_LsNative"]
              typedHandle = E.remote "lawspec_beam_effects" "typed_handler" [D.text "_LsOrigin"]
          pure [E.function (name ++ "_state") [D.text "_LsNative"] [origin,
                  beamTypedConvert t ToNative st (E.remote "lawspec_beam_fast" "state" [typedHandle])],
                E.function (name ++ "_set_state") [D.text "_LsNative",D.text "_LsState"] [origin,
                  E.remote "lawspec_beam_fast" "set_state" [typedHandle,beamTypedConvert t FromNative st (D.text "_LsState")],unitAtom],
                E.function (name ++ "_typed_state") [D.text "_LsNative"] [origin,E.remote "lawspec_beam_fast" "state" [typedHandle]],
                E.function (name ++ "_set_typed_state") [D.text "_LsNative",D.text "_LsState"] [origin,
                  E.remote "lawspec_beam_fast" "set_state" [typedHandle,D.text "_LsState"],unitAtom]]
      pure ([E.function name [schema,symbols] [body],native] ++ interfaces ++ accessors)
    dynamicHandlerBodies h = do
      name <- F.handlerEntry units (C.handlerId h)
      answered <- forM (C.handlerAbilities h) $ \ref -> maybe (Left "unknown spec handler ability") Right (N.abilityOf units ref)
      clauses <- forM (concatMap C.abilityOperations answered) $ \(op,ty) -> do
        identity <- maybe (Left "missing BEAM spec handler clause") Right (lookup op (C.handlerClauses h))
        entry <- maybe (Left "missing BEAM spec clause definition") Right (lookup identity (F.entries units))
        let args = map D.text (argumentNames "" (fst (C.functionType ty)))
            stateful = C.handlerState h /= Nothing
            parameters = if stateful then D.text "_State" : args else if null args then [E.atom "ls_unit"] else args
            call = E.remote "lawspec_definitions" entry (D.text "_LsCurrentSchema" : symbols : parameters)
            body = if not stateful then call else E.apply (E.lambda
              [E.tuple [E.atom "ls_data",D.text "_",E.array [D.text "_Result",D.text "_NextState"]]]
              (E.tuple [D.text "_Result",D.text "_NextState"])) [call]
        pure (E.binary op,E.lambda ([D.text "_LsCurrentSchema",E.array args] ++ [D.text "_State" | stateful]) body)
      body <- case C.handlerState h of
        Nothing -> pure (E.remote "lawspec_beam_effects" "stateless" [E.record clauses])
        Just (_,initial) -> do
          value <- Expr.renderExpression bits schema symbols (error . ("unbound BEAM handler state: " ++) . C.idText)
            (F.external units symbols) initial
          pure (E.remote "lawspec_beam_effects" "stateful" [schema,value,E.record clauses])
      native <- case C.handlerAbilities h of
        [single] -> F.toNative units single schema symbols (E.call name [schema,symbols])
        several -> do
          interfaces <- mapM (\ref -> F.toNative units ref schema symbols (D.text "_LsShared")) several
          pure (E.sequenceDoc [D.text "_LsShared = " <> E.call name [schema,symbols],E.tuple interfaces])
      accessors <- case C.handlerState h of
        Nothing -> pure []
        Just (t,_) -> do
          first <- F.abilityEntry units (C.handlerAbility h)
          out <- convert "to_native" (D.text "_LsStateSchema") t (D.text "_LsValue")
          back <- convert "from_native" (D.text "_LsStateSchema") t (D.text "_LsValue")
          let origin = D.text "{_LsOrigin, _} = " <> E.call (first ++ "_parts") [D.text "_LsNative"]
              done = E.atom (if target == "gleam" then "nil" else "ok")
          pure [E.function (name ++ "_state") [D.text "_LsNative"] [origin,
                  E.remote "lawspec_beam_effects" "handler_state" [D.text "_LsOrigin",E.lambda [D.text "_LsStateSchema",D.text "_LsValue"] out]],
                E.function (name ++ "_set_state") [D.text "_LsNative",D.text "_LsState"] [origin,
                  E.remote "lawspec_beam_effects" "set_handler_state" [D.text "_LsOrigin",E.lambda [D.text "_LsStateSchema",D.text "_LsValue"] back,D.text "_LsState"],done]]
      pure ([E.function name [schema,symbols] [body],E.function (name ++ "_native") [context] [native]] ++ accessors)
    gleamBoundHelpers = do
      let bound = [a | a <- F.abilities units, C.abilityNative a /= Nothing]
          modules = nub [init ref | a <- bound, Just ref <- [C.abilityNative a]]
          imports = zip modules ["native_" ++ show i | i <- [0::Int ..]]
          canonicalFactory a ref = hasDefault a && not (null ref) &&
            intercalate "/" (init ref) == E.gleamPath (C.abilityOwner a) &&
            last ref `elem` map fst (productionExports a)
      interfaces <- gleamImports units [C.abilityInstance a | a <- bound,
        Just ref <- [C.abilityNative a], canonicalFactory a ref]
      bodies <- forM bound $ \a -> do
        name <- F.abilityEntry units (C.abilityInstance a)
        ref <- maybe (Left "missing bound native handler reference") Right (C.abilityNative a)
        _ <- E.nativeCall target ref []
        owner <- maybe (Left "missing bound native handler module") Right (lookup (init ref) imports)
        let operations = if canonicalFactory a ref then
              D.text "let #(_, operations) = " <> G.call (alias a ++ ".parts_" ++ E.snake (interfaceName a)) [D.text "handler"] <>
                D.hardline <> D.text "operations"
              else G.tuple [D.text ("handler." ++ operationName target op) | (op,_) <- C.abilityOperations a]
        let made = [D.text "resource" | C.abilityResource a /= Nothing]
        pure (D.text "pub fn " <> G.call (name ++ "_make") made <> D.text " {" <>
          D.nest 2 (D.hardline <> D.text "let handler = " <> G.call (owner ++ "." ++ last ref) made <>
            D.hardline <> operations) <>
          D.hardline <> D.text "}")
      pure [Artifact "src/lawspec/native_handlers.gleam"
        (D.render (G.layoutFor layout) (G.fileDoc False ([D.text ("import " ++ intercalate "/" ref ++ " as " ++ name) | (ref,name) <- imports] ++ interfaces ++ bodies)))
        "generated" "source" | not (null bound)]

-- | An operation's arguments, named for their types (Int32, Payment_2),
-- after a prefix (NativeInt32).
argumentNames :: String -> [C.Type] -> [String]
argumentNames prefix types = Names.variables Names.generatedVariables
  [unwords ([prefix | not (null prefix)] ++ typeWords t) | t <- types]
