-- | Typed actors for Swift implementation code (see LawSpec.Actors). Every
-- actor becomes a class named for its handle type in LawSpec.Actors, and
-- the functions it runs (its start, handlers and restart) a struct of
-- functions, usually the unit's adapters (its adapters property). Each
-- handler is a method that sends its message and waits for the reply, an
-- async overload of it that awaits the reply on a runtime thread, and a
-- tell form that does not wait; an actor whose messages have wire
-- descriptors can be served to and called from other nodes. Supervisors
-- start their children under the runtime's supervision tree; their children
-- are properties. ref:DEC-actors-otp-supervision ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Actors (emitActors) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.Actors.Types
import LawSpec.Core.Machine (SupervisionStrategy(..), Lifetime(..))
import LawSpec.MachineSpec (describe)
import qualified LawSpec.Code.Doc as D
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Data as Data
import LawSpec.Swift.Definitions (nativeSignature)
import Control.Monad (foldM, forM, unless)
import Data.List (intercalate, nubBy)

emitActors :: Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitActors bits datas units
  | null actors && null supervisors = pure []
  | otherwise = do
      names <- dataNames datas
      groups <- mapM (actorGroup names) actors
      supervised <- mapM supervisorClass supervisors
      let header = lines'
            [ "// " ++ generatedHeader Nothing
            , ""
            , "import LawSpecRuntime"
            , "" ]
          body = lines'
            [ "/// Typed actors and supervisors: each actor runs the functions of its"
            , "/// handlers, one message at a time; a handler that throws crashes the"
            , "/// actor, and a supervised one restarts (from its restart function, or"
            , "/// its start) while any other stops." ] <> D.hardline <>
            D.text "public enum Actors" <> blockDoc (D.joinWith (D.hardline <> D.hardline) (concat groups ++ supervised))
      pure [Artifact "src/LawSpec/LawSpecActors.swift"
        (D.render swiftLayout (header <> D.hardline <> D.text "extension LawSpec" <> blockDoc body) ++ "\n") "generated" "source"]
  where
    actors = concatMap actorsOf units
    supervisors = concatMap supervisionsOf units
    lines' = D.joinWith D.hardline . map D.text
    -- A comment wrapped to fit inside the Actors enum.
    note = D.lineComment 94 "/// "
    runtime = "LawSpecRuntime.Actors"
    handlersName a = actorClass a ++ "Handlers"
    field d = escape (camel (C.declarationName d))
    argName (n, _) = escape (camel n)
    declarations a = actorStart a : map handlerDeclaration (actorHandlers a) ++ maybe [] pure (actorRestart a)
    -- A one-statement function: its declaration, then its body.
    function opening parameters result body = signature opening parameters result body

    -- A declaration's adapter signature: its value parameters' types, its
    -- result, its failure and whether it is async.
    adapterSignature names d = do
      (params, r, failure, async) <- nativeSignature bits names units d
      unless (length params == length [p | p <- fst (C.functionType (C.declarationType d)), p /= C.Constructor "Unit" []])
        (Left ("an actor's function cannot use abilities on Swift: " ++ C.idText (C.declarationId d)))
      pure (map snd params, r, failure, async)
    closureType (ts, r, failure, async) =
      "@Sendable (" ++ intercalate ", " ts ++ ")" ++ (if async then " async" else "") ++
      maybe "" (\e -> " throws(" ++ e ++ ")") failure ++ " -> " ++ r
    -- A call of a handlers field, as the actor's worker runs it.
    invoke (_, r, failure, async) callee arguments
      | async = callDoc "try Runtime.awaitBoxed" [callDoc "UncheckedBox" [
          D.text ("{ () async throws -> " ++ r ++ " in") <> D.nest 2 (D.hardline <>
            callDoc (maybe "" (const "try ") failure ++ "await " ++ callee) arguments) <> D.hardline <> D.text "}"]]
      | otherwise = callDoc (maybe "" (const "try ") failure ++ callee) arguments

    actorGroup names a = do
      sigs <- forM (declarations a) $ \d -> (,) d <$> adapterSignature names d
      stateType <- Data.nativeType bits names [] (actorState a)
      let sigOf d = maybe (error "actor declaration") id (lookup (C.declarationId d) [(C.declarationId x, s) | (x, s) <- sigs])
          cls = actorClass a
          startParams = [(argName p, t) | p@(_, t) <- actorStartArguments a, t /= C.Constructor "Unit" []]
      startTypes <- mapM (Data.nativeType bits names [] . snd) startParams
      let startCall = invoke (sigOf (actorStart a)) ("handlers." ++ field (actorStart a)) (map (D.text . fst) startParams)
          closure parameter body = D.text ("{ " ++ parameter ++ " in") <> D.nest 2 (D.hardline <> body) <> D.hardline <> D.text "}"
          restart = case actorRestart a of
            Just d -> closure "state" (invoke (sigOf d) ("handlers." ++ field d) [D.text ("state as! " ++ stateType)])
            Nothing -> closure "_" startCall
          paramDecl = ["_ " ++ n ++ ": " ++ t | ((n, _), t) <- zip startParams startTypes]
          paramArgs = map fst startParams
          record =
            note ("The functions actor " ++ actorName a ++ " runs: usually its unit's adapters.") <>
            D.text ("public struct " ++ handlersName a ++ ": Sendable") <> blockDoc (
              D.joinWith D.hardline (concat [ [ D.text ("/// " ++ C.idText (C.declarationId d)), D.text ("public let " ++ field d ++ ": " ++ closureType s) ] | (d, s) <- sigs ]) <>
              D.hardline <> D.hardline <>
              signature "public init" [field d ++ ": @escaping " ++ closureType s | (d, s) <- sigs] ""
                (D.joinWith D.hardline [ D.text ("self." ++ field d ++ " = " ++ field d) | (d, _) <- sigs ]) <>
              D.hardline <> D.hardline <>
              note ("The handlers of actor " ++ actorName a ++ ", from the adapters.") <>
              hangValue "public static let adapters =" (callDoc (handlersName a)
                [D.text (field d ++ ": " ++ unitQualified (C.unitId (actorUnit a)) ++ "." ++ functionName d) | (d, _) <- sigs]))
      methods <- forM (actorHandlers a) $ \h -> do
        args <- forM (handlerArguments h) $ \p@(_, t) -> (,) (argName p) <$> Data.nativeType bits names [] t
        reply <- traverse (Data.nativeType bits names []) (handlerReply h)
        let d = handlerDeclaration h
            call = invoke (sigOf d) ("handlers." ++ field d) (D.text "current" : map (D.text . fst) args)
            params = ["_ " ++ n ++ ": " ++ t | (n, t) <- args]
            name = escape (camel (handlerName h))
            step = case reply of
              Just _ -> [ hangValue "let pair =" call, D.text "return (pair.first, pair.second)" ]
              Nothing -> [ hangValue "return" (argumentsDoc [D.text "Unit()", call]) ]
            inner = closure "state" (D.joinWith D.hardline (D.text ("let current = state as! " ++ stateType) : step))
            discardable = [ D.text "@discardableResult" | reply /= Nothing ]
        pure $ D.joinWith (D.hardline <> D.hardline)
          [ D.joinWith D.hardline ([ D.text ("/// Sends " ++ handlerName h ++ " and waits for the reply.") ] ++ discardable ++
              [ function ("public func " ++ name) params (" throws" ++ maybe "" (" -> " ++) reply)
                  (D.text "let handlers = self.handlers" <> D.hardline <>
                    (case reply of
                      Just r -> D.text ("return try " ++ runtime ++ ".call(handle) ") <> inner <> D.text (" as! " ++ r)
                      Nothing -> D.text ("_ = try " ++ runtime ++ ".call(handle) ") <> inner)) ])
          , D.joinWith D.hardline (note ("Sends " ++ handlerName h ++ " and awaits the reply, waiting on a runtime thread, not Swift's cooperative pool.") :
              discardable ++
              [ function ("public func " ++ name) params (" async throws" ++ maybe "" (" -> " ++) reply)
                  (D.text "try await LawThread.run " <> closure' (callDoc ("try self." ++ name) (map (D.text . fst) args))) ])
          , D.text ("/// Sends " ++ handlerName h ++ " without waiting.") <> D.hardline <>
            function ("public func tell" ++ pascal (handlerName h)) params " throws"
              (D.text "let handlers = self.handlers" <> D.hardline <> D.text ("try " ++ runtime ++ ".tell(handle) ") <> inner) ]
      remote <- case wires a of
        Nothing -> pure ([], [])
        Just hs -> do
          entries <- forM hs $ \(h, argWires, replyWire) -> do
            argCodecs <- mapM (Data.codec bits names [] . snd) (handlerArguments h)
            args <- forM (handlerArguments h) $ \p@(_, t) -> (,) (argName p) <$> Data.nativeType bits names [] t
            replyType <- traverse (Data.nativeType bits names []) (handlerReply h)
            replyCodec <- traverse (Data.codec bits names []) (handlerReply h)
            let values = [D.text ("try " ++ c ++ ".toNative(arguments[" ++ show i ++ "])") | (i, c) <- zip [0 :: Int ..] argCodecs]
                callSelf = callDoc ("try self." ++ escape (camel (handlerName h))) values
                body = case replyCodec of
                  Just c -> closure "arguments" (callDoc ("try " ++ c ++ ".fromNative") [callSelf])
                  Nothing -> closure "arguments" (callSelf <> D.hardline <> D.text "return Value.unit")
                entry inv = argumentsDoc [D.text (stringLiteral (handlerName h)),
                  callDoc "RemoteEntry" [arrayDoc (map (D.text . stringLiteral) argWires), D.text (stringLiteral replyWire), inv]]
                sent = arrayDoc [D.text ("try " ++ c ++ ".fromNative(" ++ n ++ ")") | (c, (n, _)) <- zip argCodecs args]
                remoteCall = callDoc "try Remote.call" [D.text "client", D.text (stringLiteral (handlerName h)), sent]
                method = D.joinWith D.hardline (
                  [ D.text ("/// Sends " ++ handlerName h ++ " and waits for the reply.") ] ++
                  [ D.text "@discardableResult" | replyType /= Nothing ] ++
                  [ function ("public func " ++ escape (camel (handlerName h))) ["_ " ++ n ++ ": " ++ t | (n, t) <- args]
                      (" throws" ++ maybe "" (" -> " ++) replyType)
                      (case replyCodec of
                        Just c -> callDoc ("try " ++ c ++ ".toNative") [remoteCall]
                        Nothing -> hangValue "_ =" remoteCall) ])
            pure (entry body, entry (D.text "nil"), method)
          let served = D.joinWith (D.hardline <> D.hardline)
                [ lines' [ "/// Lets other nodes call this actor at <node address>/name; that address.", "@discardableResult" ] <> D.hardline <>
                  function "public func serve" ["_ node: Node", "_ name: String"] " throws -> String"
                    (callDoc "try Remote.serve" [D.text "node", D.text "name", D.text "\"call\"", arrayDoc [e | (e, _, _) <- entries]])
                , note "The actor served at address on another node; each call waits up to timeout." <>
                  function "public static func connect" ["_ node: Node", "_ address: String", "timeout: Duration = .seconds(5)"] (" throws -> " ++ cls ++ "Remote")
                    (callDoc (cls ++ "Remote") [callDoc "try Remote.connect" [D.text "node", D.text "address", D.text "\"call\"",
                      arrayDoc [e | (_, e, _) <- entries], D.text "Timeouts.milliseconds(timeout)"]]) ]
              client =
                note ("Actor " ++ actorName a ++ " on another node: each method sends its message and waits for the reply.") <>
                D.text ("public final class " ++ cls ++ "Remote: Sendable") <> blockDoc (D.joinWith (D.hardline <> D.hardline)
                  ([ lines' [ "let client: RemoteClient", "", "init(_ client: RemoteClient) { self.client = client }" ] ] ++ [m | (_, _, m) <- entries]))
          pure ([served], [client])
      let members =
            [ lines'
                [ "/// The runtime handle: stable across supervised restarts."
                , "public let handle: " ++ runtime ++ ".Handle"
                , "let handlers: " ++ handlersName a
                , "" ] <> D.hardline <>
              signature "init" ["_ handle: " ++ runtime ++ ".Handle", "_ handlers: " ++ handlersName a] ""
                (lines' [ "self.handle = handle", "self.handlers = handlers" ])
            , D.text "/// The runtime's spec of this actor, for a supervisor to start." <> D.hardline <>
              function "public static func spec" (("_ handlers: " ++ handlersName a) : paramDecl) (" -> " ++ runtime ++ ".Spec")
                (callDoc (runtime ++ ".actor") [closure' startCall, restart])
            , note ("Makes the actor's state with " ++ C.declarationName (actorStart a) ++ " and starts the actor.") <>
              function "public static func start" (("_ handlers: " ++ handlersName a) : paramDecl) (" throws -> " ++ cls)
                (callDoc cls [callDoc ("try " ++ runtime ++ ".start") [callDoc "spec" (map D.text ("handlers" : paramArgs))], D.text "handlers"])
            , D.text "/// The actor a supervisor started, by its handle." <> D.hardline <>
              function "public static func fromHandle" ["_ handle: " ++ runtime ++ ".Handle", "_ handlers: " ++ handlersName a] (" -> " ++ cls)
                (D.text (cls ++ "(handle, handlers)")) ] ++
            methods ++
            [ note "Crashes the actor as a failing handler would, after the messages already sent." <>
              D.text "public func crash() throws" <> blockDoc (D.text ("try " ++ runtime ++ ".crash(handle)"))
            , D.text "/// Tells inbox about each crash, and once it stops." <> D.hardline <>
              function "public func monitor" ["_ inbox: " ++ runtime ++ ".Inbox"] "" (D.text (runtime ++ ".monitor(handle, inbox)"))
            , D.text "/// When either actor crashes, the other crashes too." <> D.hardline <>
              function "public func link" ["_ other: " ++ runtime ++ ".Handle"] "" (D.text (runtime ++ ".link(handle, other)"))
            , D.text "/// Refuses further messages; those already sent are still handled." <> D.hardline <>
              D.text "public func stop()" <> blockDoc (D.text (runtime ++ ".stop(handle)")) ] ++
            fst remote
          cls' =
            note ("Actor " ++ actorName a ++ ": owns its state and handles one message at a time.") <>
            D.text ("public final class " ++ cls ++ ": Sendable") <> blockDoc (D.joinWith (D.hardline <> D.hardline) members)
      pure ([record, cls'] ++ snd remote)
    -- A closure of no parameters around a body.
    closure' body = D.text "{" <> D.nest 2 (D.hardline <> body) <> D.hardline <> D.text "}"

    -- Each message's argument and reply descriptors, with the data types
    -- they use; Nothing when a type has no descriptor (the actor stays local).
    wires a = either (const Nothing) Just $ do
      (table, hs) <- foldM (\(t, acc) h -> do
          (args, t') <- foldM (\(xs, tt) (_, ty) -> (\(x, tt') -> (xs ++ [x], tt')) <$> describe bits datas tt ty) ([], t) (handlerArguments h)
          (reply, t'') <- describe bits datas t' (maybe (C.Constructor "Unit" []) id (handlerReply h))
          pure (t'', acc ++ [(h, args, reply)])) ([], []) (actorHandlers a)
      let prefix = concatMap ((++ " ") . snd) (reverse table)
      pure [(h, map (prefix ++) args, prefix ++ reply) | (h, args, reply) <- hs]

    -- The actors beneath a supervisor, each once: its start takes their
    -- handlers.
    beneath s = nubBy (\x y -> actorName x == actorName y) (concatMap child (supervisionChildren s))
      where child (_, _, ActorChild a) = [a]
            child (_, _, SupervisorChild cls) = concat [beneath s' | s' <- supervisors, supervisionClass s' == cls]
    handlersParam a = escape (camel (actorName a)) ++ "Handlers"
    supervisorClass s = do
      let cls = supervisionClass s
          params = beneath s
          paramList = ["_ " ++ handlersParam a ++ ": " ++ handlersName a | a <- params]
          args = map handlersParam params
          childClass c = case c of ActorChild a -> actorClass a; SupervisorChild n -> n
          childArgs c = case c of
            ActorChild a -> [handlersParam a]
            SupervisorChild n -> [handlersParam a | s' <- supervisors, supervisionClass s' == n, a <- beneath s']
          childTry c = case c of ActorChild _ -> ""; SupervisorChild _ -> "try "
          strategy = case supervisionStrategy s of OneForOne -> ".oneForOne"; OneForAll -> ".oneForAll"; RestForOne -> ".restForOne"
          lifetime l = case l of Permanent -> ".permanent"; Transient -> ".transient"; Temporary -> ".temporary"
          childSpec (l, n, c) = argumentsDoc [D.text (stringLiteral n), D.text (lifetime l), callDoc (childTry c ++ childClass c ++ ".spec") (map D.text (childArgs c))]
          children = supervisionChildren s
          member n = escape (camel n)
      pure $
        note ("Supervisor " ++ supervisionName s ++ ": its children restart by its strategy, within its restart budget.") <>
        D.text ("public final class " ++ cls ++ ": Sendable") <> blockDoc (D.joinWith (D.hardline <> D.hardline)
          [ D.joinWith D.hardline (D.text ("public let handle: " ++ runtime ++ ".Handle") :
              concat [ [D.text ("/// Child " ++ n ++ "."), D.text ("public let " ++ member n ++ ": " ++ childClass c)] | (_, n, c) <- children ])
          , signature "init" (("_ handle: " ++ runtime ++ ".Handle") : ["_ " ++ member n ++ ": " ++ childClass c | (_, n, c) <- children]) ""
              (D.joinWith D.hardline (D.text "self.handle = handle" : [ D.text ("self." ++ member n ++ " = " ++ member n) | (_, n, _) <- children ]))
          , D.text "/// The runtime's spec of this supervisor and its children." <> D.hardline <>
            function "public static func spec" paramList (" throws -> " ++ runtime ++ ".Spec")
              (callDoc ("try " ++ runtime ++ ".supervisor") [D.text strategy, D.text (show (supervisionRestarts s)), D.text (show (supervisionPeriod s)),
                arrayDoc (map childSpec children)])
          , D.text "/// The supervisor a parent started, by its handle." <> D.hardline <>
            function "public static func fromHandle" (("_ handle: " ++ runtime ++ ".Handle") : paramList) (" throws -> " ++ cls)
              (callDoc cls (D.text "handle" : [ callDoc (childTry c ++ childClass c ++ ".fromHandle")
                  (callDoc ("try " ++ runtime ++ ".child") [D.text "handle", D.text (stringLiteral n)] : map D.text (childArgs c)) | (_, n, c) <- children ]))
          , D.text "/// Starts the supervisor and its children, in order." <> D.hardline <>
            function "public static func start" paramList (" throws -> " ++ cls)
              (callDoc "try fromHandle" (callDoc ("try " ++ runtime ++ ".start") [callDoc "try spec" (map D.text args)] : map D.text args))
          , D.text "/// Tells inbox when it passes its restart limit, and once stopped." <> D.hardline <>
            function "public func monitor" ["_ inbox: " ++ runtime ++ ".Inbox"] "" (D.text (runtime ++ ".monitor(handle, inbox)"))
          , D.text "/// Stops every child, last started first, without restarting them." <> D.hardline <>
            D.text "public func stop()" <> blockDoc (D.text (runtime ++ ".stop(handle)")) ])
