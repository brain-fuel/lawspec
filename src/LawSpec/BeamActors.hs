-- | Typed native actor APIs call the same checked bridges as model tests.
-- Persistent gen_servers own native states; OTP supervisors replace them
-- behind stable handles. No property framework is a production dependency.
-- ref:DEC-actors-otp-supervision ref:DEC-native-bindings-typed-identity
module LawSpec.BeamActors (emit) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import LawSpec.Actors.Types
import LawSpec.Core.Machine (SupervisionStrategy(..), Lifetime(..))
import LawSpec.Common (Artifact(..))
import LawSpec.MachineSpec (describe)
import Control.Monad (foldM, forM, unless)
import Data.List (nub)

data NativeType = NativeType D.Doc D.Doc D.Doc [D.Doc]
data Function = Function String [(String, NativeType)] NativeType [D.Doc]

emit :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target layout bits declarations units = do
  names <- E.dataNames declarations
  let actors = concatMap actorsOf units
      supervisors = concatMap supervisionsOf units
      native = nativeType bits names
      entries = Definitions.entries units
      resultType = unitType target
      variable = D.text . ("_Ls" ++) . E.pascal
      unitValue = E.atom (if target == "gleam" then "nil" else "ok")
      bridge direction ty value = do
        ref <- E.typeReference ty
        pure (E.remote "lawspec_beam_schema" direction [value,ref,D.text "_LsSchema"])
      checked available declaration arguments finish = do
        let (types, _) = C.functionType (C.declarationType declaration)
        name <- maybe (Left "missing checked BEAM actor adapter") Right (lookup (C.declarationId declaration) entries)
        values <- sequence [bridge "from_native" ty value | (ty,value) <- zip types arguments]
        out <- finish (D.text "_LsResult")
        let call = E.remote "lawspec_definitions" name (D.text "_LsSchema" : D.text "_LsSymbols" : values)
            body = E.sequenceDoc [D.text "_LsResult = " <> call,out]
            needed = [(a,v) | (a,v) <- available, a `elem` Effects.uses declaration]
        scoped <- if null needed then pure (E.sequenceDoc
          [D.text "_LsSymbols = make_ref()",D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [D.text "_LsSymbols"],body])
          else Abilities.publicBody units needed body
        pure (E.apply (E.lambda [] scoped) [])
      allHandlers as = nub (concatMap (concatMap Effects.uses . actorDeclarations) as)
      handlerParams as = forM (zip [0::Int ..] (allHandlers as)) $ \(i,a) -> do
        ty <- abilityType units a
        pure (a,("handler" ++ show i,ty))
      signatures parameters = map snd parameters
      supplied parameters = [(a,variable n) | (a,(n,_)) <- parameters]
      validateMethods what raw = do
        let names' = map (E.nativeName target . E.snake) raw
        unless (all (\n -> not (null n) && length n <= 255) names' && length names' == length (nub names'))
          (Left (what ++ " has colliding BEAM API names after snake_case conversion"))
      actorKey a = (C.unitId (actorUnit a),actorName a)
      findSupervisor u cls = maybe (Left ("missing BEAM supervisor " ++ cls)) Right
        (lookup (C.unitId u,cls) [((C.unitId (supervisionUnit s),supervisionClass s),s) | s <- supervisors])
      beneath s = concat <$> mapM (\(_,_,child) -> case child of
        ActorChild a -> pure [a]
        SupervisorChild cls -> findSupervisor (supervisionUnit s) cls >>= beneath) (supervisionChildren s)
      apiFunctions moduleName own resourceName params specBody =
        let args = map (variable . fst) params
            spec = E.call "spec" args
            childSpec = E.record [(E.atom "id",E.atom moduleName),
              (E.atom "start",E.tuple [E.atom moduleName,E.atom "start_link",E.array args]),
              (E.atom "restart",E.atom "permanent"),(E.atom "shutdown",D.text "5000"),
              (E.atom "type",E.atom "worker"),(E.atom "modules",E.array [E.atom "lawspec_beam_actor_tree"])]
        in [Function "spec" params specificationType [specBody],
            Function "start" params own [E.remote "lawspec_beam_actor_tree" "start" [spec]],
            Function resourceName (params ++ [("body",callbackType own)]) genericType
              [E.remote "lawspec_beam_actors" "with_spec" [spec,variable "body"]],
            Function "start_link" params startLinkType [E.remote "lawspec_beam_actors" "start_link" [spec]],
            Function "otp_child_spec" params childSpecType [childSpec],
            Function "from_process" [("process",processType)] own
              [D.text "_LsHandle = " <> E.remote "lawspec_beam_actors" "from_process" [variable "process"],
               metadataPattern moduleName (D.text "_") <> D.text " = " <>
                 E.remote "lawspec_beam_actors" "metadata" [D.text "_LsHandle"],D.text "_LsHandle"],
            Function "stop" [("handle",own)] resultType
              [E.remote "lawspec_beam_actors" "stop" [variable "handle"],unitValue],
            Function "monitor" [("handle",own),("observer",processType)] resultType
              [E.remote "lawspec_beam_actors" "monitor" [variable "handle",variable "observer"],unitValue],
            Function "worker_pid" [("handle",own)] processType
              [E.remote "lawspec_beam_actors" "require_worker_pid" [variable "handle"]]]
  actorArtifacts <- concat <$> forM actors (\a -> do
    let moduleName = actorModule a
        publicType = E.pascal (actorClass a)
        own = ownType publicType
    handleTy <- native (actorHandle a)
    parameters <- handlerParams [a]
    startParams <- forM [(i,t) | (i,(_,t)) <- zip [0::Int ..] (actorStartArguments a), not (isUnit t)] $ \(i,t) ->
      (,) ("argument" ++ show i) <$> native t
    let values = [if isUnit t then unitValue else variable ("argument" ++ show i)
          | (i,(_,t)) <- zip [0::Int ..] (actorStartArguments a)]
        interfaces = supplied parameters
        allParams = signatures parameters ++ startParams
    start <- checked interfaces (actorStart a) values (bridge "to_native" (actorState a))
    restart <- case actorRestart a of
      Nothing -> pure start
      Just declaration -> checked interfaces declaration [D.text "_LsState"] (bridge "to_native" (actorState a))
    let restartArg = D.text (if actorRestart a == Nothing then "_" else "_LsState")
        spec = E.record [(E.atom "kind",E.atom "actor"),(E.atom "start",E.lambda [] start),
          (E.atom "restart",E.lambda [restartArg] restart),
          (E.atom "context",E.remote "lawspec_beam_actors" "context" []),
          (E.atom "metadata",E.record [(E.atom "tag",E.atom moduleName),
            (E.atom "handlers",E.array (map snd interfaces))])]
    methods <- concat <$> forM (actorHandlers a) (\h -> do
      arguments <- sequence [(,) ("argument" ++ show i) <$> native t
        | (i,(_,t)) <- zip [0::Int ..] (handlerArguments h)]
      replyType <- maybe (pure resultType) native (handlerReply h)
      invoke <- checked interfaces (handlerDeclaration h)
        (D.text "_LsState" : map (variable . fst) arguments) (\result -> case handlerReply h of
          Nothing -> E.tuple . (unitValue :) . pure <$> bridge "to_native" (actorState a) result
          Just ty -> do
            reply <- bridge "to_native" ty (D.text "_LsReply")
            next <- bridge "to_native" (actorState a) (D.text "_LsNext")
            pure (E.sequenceDoc [E.tuple [E.atom "ls_data",D.text "_",E.array [D.text "_LsReply",D.text "_LsNext"]] <>
              D.text " = " <> result,E.tuple [reply,next]]))
      let name = E.nativeName target (E.snake (handlerName h))
          prefix = [metadataPattern moduleName (E.array (map snd interfaces)) <> D.text " = " <>
            E.remote "lawspec_beam_actors" "metadata" [variable "handle"]]
          call mode = E.remote "lawspec_beam_actors" mode [variable "handle",E.lambda [D.text "_LsState"] invoke]
      pure [Function name (("handle",own):arguments) replyType (prefix ++ [call "call"]),
        Function (E.nativeName target ("tell_" ++ E.snake (handlerName h))) (("handle",own):arguments) resultType
          (prefix ++ [call "tell",unitValue])])
    (remoteLocal, remoteArtifacts) <- case actorWires bits declarations a of
      Left _ -> pure ([], [])
      Right (forms, handlers) -> do
        text <- native (C.Constructor "Text" [])
        milliseconds <- native (C.Constructor "Integer" [])
        let remoteOwn = ownType (publicType ++ "Remote")
            descriptor d = E.binary (unwords (map snd (reverse forms) ++ [d]))
            wire ds r = E.record [(E.atom "arguments",E.array (map descriptor ds)),(E.atom "result",descriptor r)]
            signatures' = E.record [(E.binary (handlerName h),wire ds r) | (h,ds,r) <- handlers]
            fresh = [D.text "_LsSymbols = make_ref()",
              D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [D.text "_LsSymbols"]]
            remoteModule = moduleName ++ "_remote"
            connect = Function "connect" [("node",nodeType),("address",text)] remoteOwn
              [E.call "connect_with_timeout" [variable "node",variable "address",D.text "5000"]]
            timeout = Function "connect_with_timeout" [("node",nodeType),("address",text),("timeout_milliseconds",milliseconds)] remoteOwn
              [E.remote "lawspec_beam_remote" "connect"
                [variable "node",variable "address",E.binary "call",signatures',variable "timeout_milliseconds"]]
        parts <- forM handlers $ \(h,ds,r) -> do
          let name = E.nativeName target (E.snake (handlerName h))
              types = map snd (handlerArguments h)
              argumentNames = ["argument" ++ show i | (i,_) <- zip [0::Int ..] types]
              args = map variable argumentNames
          parameters' <- sequence [ (,) n <$> native t | (n,t) <- zip argumentNames types]
          replyType <- maybe (pure resultType) native (handlerReply h)
          nativeArgs <- sequence [bridge "to_native" t v | (t,v) <- zip types args]
          logicalArgs <- sequence [bridge "from_native" t v | (t,v) <- zip types args]
          let invoke = E.remote moduleName name (variable "handle":nativeArgs)
              remoteCall = E.remote "lawspec_beam_remote" "call"
                [variable "remote",E.binary (handlerName h),E.array logicalArgs]
          serverResult <- maybe (pure (E.sequenceDoc [invoke,E.atom "ls_unit"]))
            (\t -> bridge "from_native" t invoke) (handlerReply h)
          clientResult <- maybe (pure (E.sequenceDoc [remoteCall,unitValue]))
            (\t -> bridge "to_native" t remoteCall) (handlerReply h)
          pure ((E.binary (handlerName h),E.remote "maps" "put"
              [E.atom "invoke",E.lambda [E.array args] (E.sequenceDoc (fresh ++ [serverResult])),wire ds r]),
            Function name (("remote",remoteOwn):parameters') replyType (fresh ++ [clientResult]))
        let remoteFunctions = [connect,timeout] ++ map snd parts
            serve = Function "serve" [("handle",own),("node",nodeType),("name",text)] text
              [metadataPattern moduleName (D.text "_") <> D.text " = " <>
                 E.remote "lawspec_beam_actors" "metadata" [variable "handle"],
               E.remote "lawspec_beam_remote" "serve" [variable "node",variable "name",E.binary "call",E.record (map fst parts)]]
        validateMethods ("remote actor " ++ actorName a) [n | Function n _ _ _ <- remoteFunctions]
        unless (all (\(Function _ ps _ _) -> length ps <= 253) remoteFunctions)
          (Left "BEAM remote actor function arity exceeds the Erlang limit")
        pure ([serve],render target layout remoteModule (actorPath a ++ "_remote") (actorElixir a ++ ".Remote")
          (publicType ++ "Remote") rawRemoteType Nothing remoteFunctions)
    let functions = apiFunctions moduleName own "with_actor" allParams spec ++ methods ++ remoteLocal ++
          [Function "crash" [("handle",own)] resultType
            [E.remote "lawspec_beam_actors" "crash" [variable "handle"],unitValue],
           Function "handle" [("actor",own)] rawActorType [variable "actor"],
           Function "link" [("handle",own),("other",rawActorType)] resultType
            [E.remote "lawspec_beam_actors" "link" [variable "handle",variable "other"],unitValue]]
    validateMethods ("actor " ++ actorName a) ([n | Function n _ _ _ <- functions] ++ ["child_spec"])
    unless (all (\(Function _ ps _ _) -> length ps <= 253) functions) (Left "BEAM actor function arity exceeds the Erlang limit")
    pure (render target layout moduleName (actorPath a) (actorElixir a) publicType rawActorType (Just handleTy) functions ++ remoteArtifacts))
  supervisorArtifacts <- concat <$> forM supervisors (\s -> do
    actorsHere <- beneath s
    parameters <- handlerParams actorsHere
    let moduleName = supervisorModule s
        publicType = E.pascal (supervisionClass s)
        own = ownType publicType
        interfaces = supplied parameters
        select needed = forM needed $ \ability -> maybe (Left "missing BEAM supervisor ability") Right (lookup ability interfaces)
    children <- forM (supervisionChildren s) $ \(lifetime,name,child) -> do
      (childModule,needs,ty) <- case child of
        ActorChild a -> do
          unless (all (isUnit . snd) (actorStartArguments a)) (Left "a supervised actor must start without arguments")
          pure (actorModule a,allHandlers [a],actorType a)
        SupervisorChild cls -> do
          inner <- findSupervisor (supervisionUnit s) cls
          as <- beneath inner
          pure (supervisorModule inner,allHandlers as,supervisorType inner)
      args <- select needs
      pure (E.tuple [E.atom name,E.atom (lifetimeName lifetime),E.remote childModule "spec" args],
        Function (E.nativeName target (E.snake name)) [("handle",own)] ty
          [E.remote "lawspec_beam_actors" "child" [variable "handle",E.atom name]])
    let specification = E.remote "lawspec_beam_actors" "supervisor"
          [E.atom (strategyName (supervisionStrategy s)),D.text (show (supervisionRestarts s)),
           D.text (show (supervisionPeriod s)),E.array (map fst children)]
        spec = E.remote "maps" "put" [E.atom "metadata",
          E.record [(E.atom "tag",E.atom moduleName),(E.atom "handlers",E.array [])],specification]
        functions = apiFunctions moduleName own "with_supervisor" (signatures parameters) spec ++ map snd children
    validateMethods ("supervisor " ++ supervisionName s) ([n | Function n _ _ _ <- functions] ++ ["child_spec"])
    unless (all (\(Function _ ps _ _) -> length ps <= 253) functions) (Left "BEAM supervisor function arity exceeds the Erlang limit")
    pure (render target layout moduleName (supervisorPath s) (supervisorElixir s) publicType rawSupervisorType Nothing functions))
  let paths = map artifactPath (actorArtifacts ++ supervisorArtifacts)
  unless (length paths == length (nub paths) && all ((<= 230) . length)
    (map actorModule actors ++ map supervisorModule supervisors)) (Left "BEAM actor module names collide or exceed the atom limit")
  -- Resolving children by unit avoids ambiguous short names across imports.
  unless (length (map actorKey actors) == length (nub (map actorKey actors))) (Left "duplicate BEAM actors")
  pure (actorArtifacts ++ supervisorArtifacts)

actorDeclarations :: Actor -> [C.Declaration]
actorDeclarations a = actorStart a : map handlerDeclaration (actorHandlers a) ++ maybe [] pure (actorRestart a)

-- Match the other targets: all of an actor's messages must have wire types.
actorWires :: Int -> [C.DataDeclaration] -> Actor -> Either String ([(String,String)],[(Handler,[String],String)])
actorWires bits declarations actor = foldM add ([],[]) (actorHandlers actor)
  where
    add (table,handlers) h = do
      (args,next) <- foldM (\(xs,t) (_,ty) -> (\(x,t') -> (xs ++ [x],t')) <$> describe bits declarations t ty)
        ([],table) (handlerArguments h)
      (reply,final) <- describe bits declarations next (maybe (C.Constructor "Unit" []) id (handlerReply h))
      pure (final,handlers ++ [(h,args,reply)])

isUnit :: C.Type -> Bool
isUnit ty = ty == C.Constructor "Unit" []

metadataPattern :: String -> D.Doc -> D.Doc
metadataPattern name handlers = D.text "#{tag := " <> E.atom name <> D.text ", handlers := " <> handlers <> D.text "}"

actorModule :: Actor -> String
actorModule a = "lawspec_actor_" ++ E.moduleName (C.unitId (actorUnit a)) ++ "_" ++ E.snake (actorName a)
supervisorModule :: Supervision -> String
supervisorModule s = "lawspec_supervisor_" ++ E.moduleName (C.unitId (supervisionUnit s)) ++ "_" ++ E.snake (supervisionName s)
actorPath :: Actor -> String
actorPath a = "lawspec/actors/" ++ E.gleamPath (C.unitId (actorUnit a)) ++ "/" ++ E.snake (actorClass a)
supervisorPath :: Supervision -> String
supervisorPath s = "lawspec/supervisors/" ++ E.gleamPath (C.unitId (supervisionUnit s)) ++ "/" ++ E.snake (supervisionClass s)
actorElixir :: Actor -> String
actorElixir a = "LawSpec.Actors." ++ drop 7 (E.nativeModule "elixir" (actorUnit a)) ++ "." ++ E.pascal (actorClass a)
supervisorElixir :: Supervision -> String
supervisorElixir s = "LawSpec.Supervisors." ++ drop 7 (E.nativeModule "elixir" (supervisionUnit s)) ++ "." ++ E.pascal (supervisionClass s)

strategyName :: SupervisionStrategy -> String
strategyName OneForOne = "one_for_one"
strategyName OneForAll = "one_for_all"
strategyName RestForOne = "rest_for_one"
lifetimeName :: Lifetime -> String
lifetimeName Permanent = "permanent"
lifetimeName Transient = "transient"
lifetimeName Temporary = "temporary"

nativeType :: Int -> [(C.Id,String)] -> C.Type -> Either String NativeType
nativeType bits names ty = NativeType <$> E.nativeType bits names [] ty <*> X.nativeType bits names [] ty <*>
  G.nativeType False names [] ty <*> pure (G.imports False [ty])
abilityType :: [C.Unit] -> C.AbilityRef -> Either String NativeType
abilityType units a = NativeType <$> Abilities.nativeType "erlang" units a <*> Abilities.nativeType "elixir" units a <*>
  Abilities.nativeType "gleam" units a <*> Abilities.gleamImports units [a]
ownType :: String -> NativeType
ownType name = NativeType (E.call "t" []) (X.call "t" []) (D.text name) []
supervisorType :: Supervision -> NativeType
supervisorType s = NativeType (E.remote (supervisorModule s) "t" []) (X.remote (supervisorElixir s) "t" [])
  (D.text (alias ++ "." ++ E.pascal (supervisionClass s)))
  [D.text ("import " ++ supervisorPath s ++ " as " ++ alias)]
  where alias = "supervisor_" ++ E.moduleName (C.unitId (supervisionUnit s)) ++ "_" ++ E.snake (supervisionName s)
actorType :: Actor -> NativeType
actorType a = NativeType (E.remote (actorModule a) "t" []) (X.remote (actorElixir a) "t" [])
  (D.text (alias ++ "." ++ E.pascal (actorClass a))) [D.text ("import " ++ actorPath a ++ " as " ++ alias)]
  where alias = "actor_" ++ E.moduleName (C.unitId (actorUnit a)) ++ "_" ++ E.snake (actorName a)
unitType :: String -> NativeType
unitType target = NativeType (E.atom (if target == "gleam" then "nil" else "ok")) (X.atom "ok") (D.text "Nil") []
nodeType, rawRemoteType :: NativeType
nodeType = NativeType (E.remote "lawspec_network" "node_handle" []) (X.remote "LawSpec.Network" "node_handle" []) (D.text "network.Node") [D.text "import lawspec/network"]
rawRemoteType = NativeType (E.remote "lawspec_beam_remote" "remote" [])
  (X.remote ":lawspec_beam_remote" "remote" []) mempty []
genericType :: NativeType
genericType = NativeType (E.call "term" []) (X.call "term" []) (D.text "result") []
callbackType :: NativeType -> NativeType
callbackType (NativeType e x g i) = NativeType
  (D.text "fun((" <> e <> D.text ") -> term())")
  (D.text "(" <> x <> D.text " -> term())")
  (D.text "fn(" <> g <> D.text ") -> result") i
processType, rawActorType, rawSupervisorType, specificationType, childSpecType, startLinkType :: NativeType
processType = NativeType (E.call "pid" []) (X.call "pid" []) (D.text "actors.Process") actorImport
rawActorType = NativeType (E.remote "lawspec_beam_actors" "actor" []) (X.remote ":lawspec_beam_actors" "actor" [])
  (D.text "actors.Handle") actorImport
rawSupervisorType = NativeType (E.remote "lawspec_beam_actors" "supervisor" []) (X.remote ":lawspec_beam_actors" "supervisor" [])
  (D.text "actors.Supervisor") actorImport
specificationType = NativeType (E.call "map" []) (X.call "map" []) (D.text "actors.Specification") actorImport
childSpecType = NativeType (E.call "map" []) (X.call "map" []) (D.text "actors.ChildSpec") actorImport
startLinkType = NativeType
  (E.tuple [E.atom "ok",E.call "pid" []] <> D.text " | " <> E.tuple [E.atom "error",E.call "term" []])
  (X.tuple [X.atom "ok",X.call "pid" []] <> D.text " | " <> X.tuple [X.atom "error",X.call "term" []])
  (D.text "Result(actors.Process, dynamic.Dynamic)") (actorImport ++ [D.text "import gleam/dynamic"])
actorImport :: [D.Doc]
actorImport = [D.text "import lawspec/actors"]

render :: String -> D.Layout -> String -> String -> String -> String -> NativeType -> Maybe NativeType -> [Function] -> [Artifact]
render target layout moduleName path elixirModule typeName rawType handleTy functions =
  Artifact ("src/" ++ moduleName ++ ".erl") (D.render layout erlang) "generated" "source" : case target of
    "elixir" -> [Artifact ("lib/" ++ path ++ ".ex") (D.render layout elixir) "generated" "source"]
    "gleam" -> [Artifact ("src/" ++ path ++ ".gleam") (D.render layout gleam) "generated" "source"]
    _ -> []
  where
    public = [f | f@(Function n _ _ _) <- functions, n /= "spec"]
    lifecycle = any (\(Function n _ _ _) -> n == "start") functions
    startParameters = case [ps | Function "start" ps _ _ <- functions] of ps:_ -> ps; [] -> []
    args ps = [D.text ("_Ls" ++ E.pascal n) | (n,_) <- ps]
    erlType (NativeType e _ _ _) = e
    exType (NativeType _ x _ _) = x
    gleamType (NativeType _ _ g _) = g
    imports (NativeType _ _ _ i) = i
    erlang = E.moduleDoc moduleName ([(n,length ps) | Function n ps _ _ <- functions] ++ [("child_spec",1) | lifecycle])
      ([D.text "-export_type([t/0]).",D.text "-opaque t() :: " <>
        maybe (erlType rawType) erlType handleTy <> D.text "."] ++
       concat [ [D.text "-spec " <> E.call n (map (erlType . snd) ps) <> D.text " -> " <> erlType result <> D.text ".",
          E.function n (args ps) body] | Function n ps result body <- functions] ++
       [E.function "child_spec" [E.array (args startParameters)] [E.call "otp_child_spec" (args startParameters)] | lifecycle])
    elixir = X.moduleDoc elixirModule False
      ([D.text "@opaque t :: " <> maybe (exType rawType) exType handleTy] ++
       concat [ [D.text "@spec " <> X.call n (map (exType . snd) ps) <> D.text " :: " <> exType result,
         X.function n (map (D.text . fst) ps)
           [X.remote (":" ++ moduleName) n (map (D.text . fst) ps)]]
         | Function n ps result _ <- public, n /= "otp_child_spec"] ++
       [X.function "child_spec" [X.array (map (D.text . fst) startParameters)]
         [X.remote (":" ++ moduleName) "otp_child_spec" (map (D.text . fst) startParameters)] | lifecycle])
    gleam = G.fileDoc False
      (nub (concat [concatMap (imports . snd) ps ++ imports result | Function _ ps result _ <- public] ++
        maybe [] imports handleTy) ++
       [D.text ("pub type " ++ typeName) <> maybe mempty ((D.text " = " <>) . gleamType) handleTy] ++
       [G.external moduleName n (if n == "otp_child_spec" then "child_spec" else n)
         [D.text (p ++ ": ") <> gleamType t | (p,t) <- ps] (gleamType result) | Function n ps result _ <- public])
