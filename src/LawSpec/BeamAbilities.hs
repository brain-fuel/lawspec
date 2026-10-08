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
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)

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

productionExports :: C.Ability -> [(String,Int)]
productionExports a = [(productionName a,0)] ++ [("slh_dsa_signature_handler",0) | isSignature a]

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
    h <- F.fromNative units a (D.text "_LsBaseSchema") (D.text "_LsSymbols") v
    pure (E.binary (C.abilityKey a),h)
  pure (E.remote "lawspec_beam_effects" "with_native_context"
    [E.array [E.remote "erlang" "element" [D.text "1",p] | p <- parts],
     E.lambda [D.text "_LsFreshSymbols"] (E.remote "lawspec_data" "schema" [D.text "_LsFreshSymbols"]),
     E.lambda [D.text "_LsBaseSchema",D.text "_LsSymbols"] (E.sequenceDoc
       [D.text "_LsSchema = " <> E.remote "lawspec_beam_effects" "install" [D.text "_LsBaseSchema",E.record handlers],body])])

productionStub :: String -> Int -> [(C.Id,String)] -> C.Ability -> Either String [D.Doc]
productionStub target _ _ ability | hasDefault ability = pure (concat
  [defaultFactory target ability name entry | (name,entry) <-
    [(productionName ability,defaultEntry ability)] ++
    [("slh_dsa_signature_handler","default_lawspec_crypto_slh_dsa_signature_handler") | isSignature ability]])
productionStub target bits names ability = do
  fields <- forM (C.abilityOperations ability) $ \(op,ty) -> do
    let args = [D.text ("_argument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType ty))]
        message = "Not implemented: " ++ C.abilityKey (C.abilityInstance ability) ++ "." ++ op
    pure $ case target of
      "gleam" -> D.text "fn" <> D.delimit 2 "(" ")" args <> D.text " { panic as " <> G.string message <> D.text " }"
      "elixir" -> D.text "fn " <> D.joinWith (D.text ", ") args <> D.text " -> raise " <> X.string message <> D.text " end"
      _ -> E.lambda args (E.remote "erlang" "error" [E.tuple [E.atom "not_implemented",E.binary message]])
  _ <- mapM (operationType target bits names . snd) (C.abilityOperations ability)
  let name = productionName ability
      keys = map (operationName target . fst) (C.abilityOperations ability)
  pure $ case target of
    "gleam" -> [G.function name [] (D.text (alias ability ++ "." ++ interfaceName ability))
      [G.call (alias ability ++ "." ++ builderName target ability) fields]]
    "elixir" -> [D.text "@spec " <> X.call name [] <> D.text " :: " <> X.remote (interfaceModule target ability) "t" [],
      X.function name [] [D.text ("%" ++ interfaceModule target ability ++ "{") <>
        D.joinWith (D.text ", ") [D.text key <> D.text ": " <> f | (key,f) <- zip keys fields] <> D.text "}"]]
    _ -> [D.text "-spec " <> E.call name [] <> D.text " -> " <>
        E.remote (interfaceModule target ability) (E.snake (interfaceName ability)) [] <> D.text ".",
      E.function name [] [E.record (zip (map E.atom keys) fields)]]

defaultFactory :: String -> C.Ability -> String -> String -> [D.Doc]
defaultFactory target ability name entry = case target of
  "gleam" -> [G.external "lawspec_abilities" entry name []
    (D.text (alias ability ++ "." ++ interfaceName ability))]
  "elixir" -> [D.text "@spec " <> X.call name [] <> D.text " :: " <>
    X.remote (interfaceModule target ability) "t" [],
    X.function name [] [X.remote ":lawspec_abilities" entry []]]
  _ -> [D.text "-spec " <> E.call name [] <> D.text " -> " <>
    E.remote (interfaceModule target ability) (E.snake (interfaceName ability)) [] <> D.text ".",
    E.function name [] [E.remote "lawspec_abilities" entry []]]

operationType :: String -> Int -> [(C.Id,String)] -> C.Type -> Either String D.Doc
operationType target bits names ty = do
  let (arguments,result) = C.functionType ty
      native = case target of "gleam" -> G.nativeType False names []; "elixir" -> X.nativeType bits names []; _ -> E.nativeType bits names []
  args <- mapM native arguments
  out <- native result
  pure $ case target of
    "gleam" -> D.text "fn" <> D.delimit 2 "(" ")" args <> D.text " -> " <> out
    "elixir" -> D.text "(" <> D.joinWith (D.text ", ") args <> D.text " -> " <> out <> D.text ")"
    _ -> D.text "fun((" <> D.joinWith (D.text ", ") args <> D.text ") -> " <> out <> D.text ")"

emit :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Bool -> Either String [Artifact]
emit target layout bits declarations units boundSchema = do
  names <- E.dataNames declarations
  native <- concat <$> mapM (unitInterfaces names) units
  pieces <- concat <$> mapM abilityBodies (F.abilities units)
  specs <- concat <$> mapM handlerBodies (F.handlers units)
  boundHelpers <- if target == "gleam" then gleamBoundHelpers else pure []
  let exports = [(name ++ suffix,arity) | a <- F.abilities units,
        Right name <- [F.abilityEntry units (C.abilityInstance a)],
        (suffix,arity) <- [("_parts",1),("_to_native",3),("_from_native",3),("_production",2),("_recording",2)]] ++
        [(name ++ suffix,arity) | h <- F.handlers units, Right name <- [F.handlerEntry units (C.handlerId h)],
          (suffix,arity) <- [("",2),("_native",1)]]
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
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    handler = D.text "_LsHandler"
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
          publicFunctions = map (publicName target . C.handlerName) hs ++
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
      public <- publicConstructors unit hs as
      case target of
        "elixir" -> pure (types ++ public)
        "gleam" -> do
          let operationTypes = [ty | a <- as, (_,ty) <- C.abilityOperations a]
          imports <- gleamImports units [C.handlerAbility h | h <- hs,
            maybe False ((/= C.unitId unit) . C.abilityOwner) (N.abilityOf units (C.handlerAbility h))]
          pure [Artifact ("src/" ++ interfacePath (C.unitId unit) ++ ".gleam")
            (D.render layout (G.fileDoc False (D.text "import lawspec/effects" : imports ++
              G.imports False operationTypes ++ map artifactDoc types ++ map artifactDoc public))) "generated" "source"
            | not (null as && null hs)]
        _ -> do
          let exports = [(publicName target (C.handlerName h),1) | h <- hs] ++ [("recording_" ++ E.snake (interfaceName a),2) | a <- as]
              typeExports = [D.text "-export_type(" <> E.array [E.atom n <> D.text "/0" | n <- identifiers] <> D.text ")." | not (null as)]
          pure [Artifact ("src/lawspec_abilities_" ++ E.moduleName (C.unitId unit) ++ ".erl")
            (D.render layout (E.moduleDoc ("lawspec_abilities_" ++ E.moduleName (C.unitId unit)) exports
              (typeExports ++ map artifactDoc types ++ map artifactDoc public))) "generated" "source" | not (null as && null hs)]
    artifactDoc = D.text . artifactContent
    fragment doc = Artifact "" (D.render layout doc) "generated" "source"
    interface names ability = do
      ts <- mapM (operationType target bits names . snd) (C.abilityOperations ability)
      let n = E.snake (interfaceName ability)
          fields = map (operationName target . fst) (C.abilityOperations ability)
          names' = map D.text fields
      case target of
        "erlang" -> pure [fragment (D.text "-type " <> E.call n [] <> D.text " :: " <>
          D.delimit 4 "#{" "}" ([E.atom key <> D.text " := " <> ty | (key,ty) <- zip fields ts] ++
            [E.atom "__lawspec_origin__" <> D.text " => lawspec_beam_effects:handler_origin()"]) <> D.text ".")]
        "elixir" -> do
          let body = [D.text "@enforce_keys " <> X.array (map X.atom fields),
                D.text "defstruct " <> X.array (map X.atom fields ++ [D.text "__lawspec_origin__: :none"]),
                D.text "@type t :: " <> D.delimit 2 "%__MODULE__{" "}"
                  ([X.atom key <> D.text " => " <> ty | (key,ty) <- zip fields ts] ++
                    [D.text "__lawspec_origin__: :lawspec_beam_effects.handler_origin()"])]
          pure [Artifact ("lib/" ++ interfacePath (C.abilityOwner ability) ++ "/" ++ n ++ ".ex")
            (D.render layout (X.moduleDoc (interfaceModule target ability) False body)) "generated" "source"]
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
          pure (map fragment (definition : builder : managed : parts : ops))
    publicConstructors unit hs as = do
      specBodies <- forM hs $ \h -> do
        a <- maybe (Left "unknown native spec handler ability") Right (N.abilityOf units (C.handlerAbility h))
        entry <- F.handlerEntry units (C.handlerId h)
        ty <- if C.abilityOwner a == C.unitId unit then pure (interfaceNameDoc a) else nativeType target units (C.handlerAbility h)
        pure (publicName target (C.handlerName h),entry ++ "_native",[contextType target],ty)
      recordings <- forM as $ \a -> do
        entry <- F.abilityEntry units (C.abilityInstance a)
        pure ("recording_" ++ E.snake (interfaceName a),entry ++ "_recording",[contextType target,interfaceNameDoc a],interfaceNameDoc a)
      let bodies = map publicFunction (specBodies ++ recordings)
      pure $ if target == "elixir" then
        [Artifact ("lib/lawspec/handlers/" ++ E.moduleName (C.unitId unit) ++ ".ex")
          (D.render layout (X.moduleDoc ("LawSpec.Handlers." ++ E.pascal (C.idText (C.unitId unit))) False bodies)) "generated" "source"
          | not (null bodies)] else map fragment bodies
    publicFunction (name,entry,args,result) =
      let values = [D.text ("value" ++ show i) | (i,_) <- zip [0::Int ..] args]
      in case target of
        "gleam" -> G.external "lawspec_abilities" entry name [v <> D.text ": " <> ty | (v,ty) <- zip values args] result
        "elixir" -> D.text "@spec " <> X.call name args <> D.text " :: " <> result <> D.hardline <>
          X.function name values [X.remote ":lawspec_abilities" entry values]
        _ -> D.text "-spec " <> E.call name args <> D.text " -> " <> result <> D.text "." <> D.hardline <>
          E.function name [D.text ("Value" ++ show i) | (i,_) <- zip [0::Int ..] args]
            [E.remote "lawspec_abilities" entry [D.text ("Value" ++ show i) | (i,_) <- zip [0::Int ..] args]]
    abilityBodies ability = do
      name <- F.abilityEntry units (C.abilityInstance ability)
      home <- nativeOwner ability
      let operations = C.abilityOperations ability
          operationFields = map (operationName target . fst) operations
          values = [E.remote "lists" "nth" [D.text (show i),D.text "_LsOperations"] | (i,_) <- zip [1::Int ..] operations]
          key = E.binary (C.abilityKey (C.abilityInstance ability))
          native = D.text "_LsNative"
          parts = if target == "gleam" then
              E.apply (E.lambda [E.tuple [D.text "_Origin",D.text "_Ops"]]
                (E.tuple [D.text "_Origin",E.remote "erlang" "tuple_to_list" [D.text "_Ops"]]))
                [E.remote (interfaceModule target ability) ("parts_" ++ E.snake (interfaceName ability)) [native]]
            else E.tuple [E.remote "maps" "get" [E.atom "__lawspec_origin__",native,E.atom "none"],
              E.array [E.remote "maps" "get" [E.atom field,native] | field <- operationFields]]
          make origin = case target of
            "gleam" -> E.remote (interfaceModule target ability) ("managed_" ++ E.snake (interfaceName ability)) (origin:values)
            "elixir" -> E.record ((E.atom "__struct__",E.atom ("Elixir." ++ interfaceModule target ability)) :
              (E.atom "__lawspec_origin__",origin) : zip (map E.atom operationFields) values)
            _ -> E.record ((E.atom "__lawspec_origin__",origin) : zip (map E.atom operationFields) values)
      callbacks <- forM operations $ \(op,ty) -> do
        let (args,result) = C.functionType ty
            values' = [D.text ("_Native" ++ show i) | (i,_) <- zip [0::Int ..] args]
        logical <- sequence [convert "from_native" schema t v | (t,v) <- zip args values']
        output <- convert "to_native" schema result (E.remote "lawspec_beam_effects" "invoke"
          [handler,schema,E.binary op,E.array logical])
        pure (E.lambda values' output)
      logical <- logicalOperations schema operations
      production <- case C.abilityNative ability of
        Nothing | hasDefault ability -> pure (E.remote "lawspec_beam_defaults" "handler" [key])
        Nothing -> pure (E.remote "lawspec_abilities" (name ++ "_from_native")
          [schema,symbols,E.remote (E.nativeModule target home) (productionName ability) []])
        Just ref -> do
          made <- if target == "gleam" then pure (E.remote "erlang" "tuple_to_list"
              [E.remote "lawspec@native_handlers" (name ++ "_make") []])
            else do
              call <- E.nativeCall target ref []
              pure (E.apply (E.lambda [native] (E.array [E.remote "maps" "get" [E.atom field,native] | field <- operationFields])) [call])
          bound <- logicalOperations (D.text "_LsNativeSchema") operations
          pure (E.apply (E.lambda [D.text "_LsOperations"] (E.sequenceDoc
            [D.text "_LsNativeSchema = " <> (if boundSchema then E.remote "lawspec_native_bindings" "schema" [schema] else schema),bound])) [made])
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
        E.function (name ++ "_production") [schema,symbols] [production],
        E.function (name ++ "_recording") [context,native] [recorded]] ++
        [E.function (defaultEntry ability) []
          [D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []],
           D.text "_LsHandler = " <> E.remote "lawspec_beam_defaults" "handler" [key],
           D.text "_LsOperations = " <> E.array callbacks, make (E.atom "none")] | hasDefault ability] ++
        [E.function "default_lawspec_crypto_slh_dsa_signature_handler" []
          [D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []],
           D.text "_LsHandler = " <> E.remote "lawspec_beam_crypto" "slh_dsa_signature_handler" [],
           D.text "_LsOperations = " <> E.array callbacks, make (E.atom "none")] | isSignature ability]
    logicalOperations nativeSchema operations = do
      clauses <- forM (zip [1::Int ..] operations) $ \(i,(op,ty)) -> do
        let (args,result) = C.functionType ty
            values = [D.text ("_Logical" ++ show j) | (j,_) <- zip [0::Int ..] args]
        arguments <- sequence [convert "to_native" nativeSchema t v | (t,v) <- zip args values]
        output <- convert "from_native" nativeSchema result (E.apply (E.remote "lists" "nth"
          [D.text (show i),D.text "_LsOperations"]) arguments)
        pure (E.binary op,E.lambda [D.text "_LsCurrentSchema",E.array values] output)
      pure (E.remote "lawspec_beam_effects" "stateless" [E.record clauses])
    handlerBodies h = do
      name <- F.handlerEntry units (C.handlerId h)
      a <- maybe (Left "unknown spec handler ability") Right (N.abilityOf units (C.handlerAbility h))
      clauses <- forM (C.abilityOperations a) $ \(op,ty) -> do
        identity <- maybe (Left "missing BEAM spec handler clause") Right (lookup op (C.handlerClauses h))
        entry <- maybe (Left "missing BEAM spec clause definition") Right (lookup identity (F.entries units))
        let args = [D.text ("_Arg" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType ty))]
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
      native <- F.toNative units (C.handlerAbility h) schema symbols (E.call name [schema,symbols])
      pure [E.function name [schema,symbols] [body],E.function (name ++ "_native") [context] [native]]
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
        pure (D.text "pub fn " <> G.call (name ++ "_make") [] <> D.text " {" <>
          D.nest 2 (D.hardline <> D.text "let handler = " <> G.call (owner ++ "." ++ last ref) [] <>
            D.hardline <> operations) <>
          D.hardline <> D.text "}")
      pure [Artifact "src/lawspec/native_handlers.gleam"
        (D.render layout (G.fileDoc False ([D.text ("import " ++ intercalate "/" ref ++ " as " ++ name) | (ref,name) <- imports] ++ interfaces ++ bodies)))
        "generated" "source" | not (null bound)]
