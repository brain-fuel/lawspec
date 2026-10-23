-- | Typed actors for Java and Kotlin implementation code (see LawSpec.Actors).
--
-- Every actor becomes a class lawspec.actors.<Handle> (AccountActor): Java
-- source for Java projects, Kotlin source for Kotlin projects, since each
-- calls the user's adapters natively (a Kotlin adapter object, possibly with
-- suspend handlers). start(...) makes the state with the start adapter and
-- runs it in a LawSpecRuntime.Actor; each handler is a method that sends its
-- message and returns the reply, tell<Handler> sends it without waiting, and
-- stop() refuses further messages.
module LawSpec.Actors.Jvm (emit, Wire(..), actorWire, replyOf, adapterCall, adapterFunction, isUnit, childClass, strategyName, strategyText, lifetimeName, seconds, capital) where

import Control.Monad (foldM)
import Data.Char (toUpper)
import Data.List (intercalate, isInfixOf, stripPrefix)
import qualified LawSpec.Code.Doc as D
import LawSpec.JavaData (javaCodecDocWithContext)
import LawSpec.KotlinData (kotlinCodecDocIn)
import qualified LawSpec.KotlinLayout as K
import LawSpec.JvmNames (javadoc)
import LawSpec.MachineSpec (describe)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.Backend (adapterName, unitName)
import LawSpec.JavaData (javaDataType, identifier)
import LawSpec.KotlinData (kotlinDataType)
import LawSpec.Actors.Types (Actor(..), Handler(..), Supervision(..), Child(..))
import LawSpec.Core.Machine (SupervisionStrategy(..), Lifetime(..))

-- | Actors become a typed class, or Java and Kotlin's idiom for one, generated
-- from the declaration. ref:DEC-actors-otp-supervision
emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [Actor] -> [Supervision] -> Either String [Artifact]
emit target _ bits datas actors supervisions = (++) <$> mapM artifact actors <*> mapM supervisorArtifact supervisions
  where
    kotlin = target == "kotlin"
    directory = if kotlin then "src/main/kotlin/lawspec/actors/" else "src/main/java/lawspec/actors/"
    extension = if kotlin then ".kt" else ".java"
    artifact a = do
      identifier (actorClass a)
      mapM_ (reserved a) (actorHandlers a)
      source <- (if kotlin then kotlinSource else javaSource) datas (either (const Nothing) Just (actorWire bits datas a)) a
      pure (Artifact (directory ++ actorClass a ++ extension) source "generated" "source")
    supervisorArtifact s = do
      identifier (supervisionClass s)
      mapM_ (\(_, name, _) -> identifier name) (supervisionChildren s)
      pure (Artifact (directory ++ supervisionClass s ++ extension)
        ((if kotlin then kotlinSupervisor else javaSupervisor) s) "generated" "source")
    reserved a h
      | handlerName h `elem` ["start", "stop", "crash", "monitor", "link", "serve", "connect"] || ("tell" ++ capital (handlerName h)) `elem` map handlerName (actorHandlers a) =
          Left ("actor " ++ actorName a ++ ": handler " ++ handlerName h ++ " clashes with a method of " ++ actorClass a ++ "; rename it")
      | otherwise = pure ()

-- | The class holding a unit's adapters: example.actors has example.Actors.
adapterClass :: C.Unit -> String
adapterClass u = intercalate "." (init parts ++ [concatMap capital (split '_' (last parts))])
  where parts = split '.' (unitName u)

-- | An adapter's qualified function name.
adapterFunction :: Actor -> C.Declaration -> String
adapterFunction a d = adapterClass (actorUnit a) ++ "." ++ adapterName (actorUnit a) (C.declarationId d)

adapterCall :: Actor -> C.Declaration -> [String] -> String
adapterCall a d args = adapterClass (actorUnit a) ++ "." ++ adapterName (actorUnit a) (C.declarationId d) ++
  "(" ++ intercalate ", " args ++ ")"

isUnit :: C.Type -> Bool
isUnit t = t == C.Constructor "Unit" []

-- | An actor's messages for the network: the data types its descriptors use,
-- and each handler's argument and reply descriptors. An actor whose types
-- have no descriptor stays local.
data Wire = Wire { wireTypes :: String, wireHandlers :: [(Handler, [String], String)], wireBits :: Int }

actorWire :: Int -> [C.DataDeclaration] -> Actor -> Either String Wire
actorWire bits datas a = do
  (table, hs) <- foldM handler ([], []) (actorHandlers a)
  pure (Wire (unwords (map snd (reverse table))) (reverse hs) bits)
  where
    handler (table, acc) h = do
      (args, table') <- foldM (\(xs, t) (_, ty) -> (\(x, t') -> (xs ++ [x], t')) <$> describe bits datas t ty) ([], table) (handlerArguments h)
      (reply, table'') <- describe bits datas table' (maybe (C.Constructor "Unit" []) id (handlerReply h))
      pure (table'', (h, args, reply) : acc)

replyOf :: Handler -> C.Type
replyOf h = maybe (C.Constructor "Unit" []) id (handlerReply h)

javaSource :: [C.DataDeclaration] -> Maybe Wire -> Actor -> Either String String
javaSource datas wire a = do
  own <- boxed (actorState a)
  let startArgs = [(p, t) | (p, t) <- actorStartArguments a]
  startParams <- sequence [(\n -> n ++ " " ++ p) <$> native t | (p, t) <- startArgs, not (isUnit t)]
  methods <- mapM (handler own) (actorHandlers a)
  remote <- maybe (pure []) (javaRemote own) wire
  let startValues = [if isUnit t then "LawSpecRuntime.absent(\"Unit\")" else p | (p, t) <- startArgs]
      initial = awaited (actorStart a) (adapterCall a (actorStart a) startValues)
      restart = case actorRestart a of
        Just d -> "s -> " ++ awaited d (adapterCall a d ["s"])
        Nothing -> "s -> " ++ initial
      startNames = [p | (p, t) <- startArgs, not (isUnit t)]
  pure $ unlines $
    [ "// Generated by LawSpec from actor " ++ actorName a ++ ". Do not edit."
    , "package lawspec.actors;"
    , ""
    , "import lawspec.runtime.LawSpecRuntime;"
    , ""
    , "/**"
    , " * Actor " ++ actorName a ++ ": owns its state and handles one message at a time, in the order they"
    , " * arrive. Each handler method sends a message and returns the reply; tell methods send it"
    , " * without waiting. A handler that throws crashes the actor: the caller gets"
    , " * LawSpecRuntime.ActorCrashed, and a supervised actor restarts (from its restart adapter, or its"
    , " * start) while any other stops."
    , " */"
    , "public final class " ++ cls
    , "{"
    , "  private final LawSpecRuntime.Actor<" ++ own ++ "> actor;"
    , ""
    , "  private " ++ cls ++ "(LawSpecRuntime.Actor<" ++ own ++ "> actor)"
    , "  {"
    , "    this.actor = actor;"
    , "  }"
    , ""
    , "  /** Makes the actor's state with " ++ C.declarationName (actorStart a) ++ " and starts the actor. */"
    , "  public static " ++ cls ++ " start(" ++ intercalate ", " startParams ++ ")"
    , "  {"
    , "    return start(" ++ intercalate ", " (startNames ++ ["null", "LawSpecRuntime.Supervisor.PERMANENT"]) ++ ");"
    , "  }"
    , ""
    , "  /**"
    , "   * Makes the actor's state with " ++ C.declarationName (actorStart a) ++ " and starts the actor, under supervisor"
    , "   * (when not null) with the given lifetime."
    , "   */"
    , "  public static " ++ cls ++ " start(" ++ intercalate ", " (startParams ++ ["LawSpecRuntime.Supervisor supervisor", "String lifetime"]) ++ ")"
    , "  {"
    , "    var actor = new LawSpecRuntime.Actor<" ++ own ++ ">(" ++ initial ++ ", " ++ restart ++ ");"
    , "    if (supervisor != null)"
    , "    {"
    , "      supervisor.supervise(actor, lifetime);"
    , "    }"
    , "    return new " ++ cls ++ "(actor);"
    , "  }"
    ] ++ concatMap ("" :) methods ++
    [ ""
    , "  /** Crashes the actor as a failing handler would, after the messages already sent: for testing how it restarts. */"
    , "  public void crash()"
    , "  {"
    , "    actor.crash();"
    , "  }"
    , ""
    , "  /** notify gets Exit(\"crashed\", cause) after each crash, and Exit(\"stopped\", null) once it stops. */"
    , "  public void monitor(java.util.function.Consumer<LawSpecRuntime.Exit> notify)"
    , "  {"
    , "    actor.monitor(notify);"
    , "  }"
    , ""
    , "  /** When either actor crashes, the other crashes too. */"
    , "  public void link(" ++ cls ++ " other)"
    , "  {"
    , "    actor.link(other.actor);"
    , "  }"
    , ""
    , "  /** Refuses further messages; those already sent are still handled. */"
    , "  public void stop()"
    , "  {"
    , "    actor.stop();"
    , "  }"
    ] ++ remote ++ [ "}" ]
  where
    cls = actorClass a
    codec bits ty = D.render (D.Pretty 1000) <$> javaCodecDocWithContext (D.text "symbols") datas bits ty
    javaRemote own w = do
      served <- mapM (\(h, ds, r) -> do
        argCodecs <- mapM (codec (wireBits w) . snd) (handlerArguments h)
        replyCodec <- codec (wireBits w) (replyOf h)
        let call = awaited (handlerDeclaration h) (adapterCall a (handlerDeclaration h)
              ("s" : [c ++ ".decode(args.get(" ++ show i ++ "))" | (i, c) <- zip [0 :: Int ..] argCodecs]))
            body = case handlerReply h of
              Just _ -> [ "          var next = " ++ call ++ ";"
                        , "          return new LawSpecRuntime.Next<LawSpecRuntime.Value, " ++ own ++ ">(" ++ replyCodec ++ ".encode(next.first()), next.second());" ]
              Nothing -> [ "          return new LawSpecRuntime.Next<LawSpecRuntime.Value, " ++ own ++ ">(LawSpecRuntime.absent(\"Unit\"), " ++ call ++ ");" ]
        pure $
          [ "    handlers.put("
          , "        " ++ show (handlerName h) ++ ","
          , "        new LawSpecRuntime.Served<" ++ own ++ ">("
          , "            (s, args) -> {"
          , "              var symbols = new java.util.HashMap<String, Object>();" ] ++
          map ("  " ++) body ++
          [ "            },"
          , "            java.util.List.of(" ++ intercalate ", " ["LawSpecRuntime.descriptor(" ++ show d ++ ")" | d <- ds] ++ "),"
          , "            LawSpecRuntime.descriptor(" ++ show r ++ ")));" ]) (wireHandlers w)
      methods <- mapM (\(h, _, _) -> do
        params <- sequence [(\n -> n ++ " " ++ p) <$> native t | (p, t) <- handlerArguments h]
        argCodecs <- mapM (codec (wireBits w) . snd) (handlerArguments h)
        replyCodec <- codec (wireBits w) (replyOf h)
        result <- maybe (pure "void") native (handlerReply h)
        let call = "remote.call(" ++ show (handlerName h) ++ ", java.util.List.of(" ++
              intercalate ", " [c ++ ".encode(" ++ p ++ ")" | (c, (p, _)) <- zip argCodecs (handlerArguments h)] ++ "))"
        pure
          [ ""
          , "    /** Sends " ++ handlerName h ++ " to the actor and waits for the reply. */"
          , "    public " ++ result ++ " " ++ handlerName h ++ "(" ++ intercalate ", " params ++ ")"
          , "    {"
          , "      var symbols = new java.util.HashMap<String, Object>();"
          , "      " ++ (if handlerReply h == Nothing then call ++ ";" else "return " ++ replyCodec ++ ".decode(" ++ call ++ ");")
          , "    }" ]) (wireHandlers w)
      pure $
        [ ""
        , "  private static final lawspec.runtime.LawSpecSchema SCHEMA ="
        , "      lawspec.runtime.LawSpecDataSchema.create();"
        , ""
        , "  private static final LawSpecRuntime.Values TYPES = LawSpecRuntime.valuesOf(" ++ show (wireTypes w) ++ ");"
        , ""
        , "  /** Lets other nodes call this actor at {node address}/name; returns that address. */"
        , "  public String serve(LawSpecRuntime.Node node, String name)"
        , "  {"
        , "    var handlers = new java.util.HashMap<String, LawSpecRuntime.Served<" ++ own ++ ">>();" ] ++
        concat served ++
        [ "    return node.serve(name, actor, handlers, TYPES);"
        , "  }"
        , ""
        , "  /** The actor served at address on another node; each call waits up to 5 seconds. */"
        , "  public static Remote connect(LawSpecRuntime.Node node, String address)"
        , "  {"
        , "    return connect(node, address, 5.0);"
        , "  }"
        , ""
        , "  /** The actor served at address on another node; a call not answered within timeout seconds throws Unreachable. */"
        , "  public static Remote connect(LawSpecRuntime.Node node, String address, double timeout)"
        , "  {"
        , "    var signatures = new java.util.HashMap<String, LawSpecRuntime.Signature>();" ] ++
        [ "    signatures.put(" ++ show (handlerName h) ++ ", new LawSpecRuntime.Signature(java.util.List.of(" ++
            intercalate ", " ["LawSpecRuntime.descriptor(" ++ show d ++ ")" | d <- ds] ++ "), LawSpecRuntime.descriptor(" ++ show r ++ ")));"
        | (h, ds, r) <- wireHandlers w ] ++
        [ "    return new Remote(node.remoteActor(address, signatures, TYPES, timeout));"
        , "  }"
        , ""
        , "  /** Actor " ++ actorName a ++ " on another node: each method sends its message and waits for the reply. */"
        , "  public static final class Remote"
        , "  {"
        , "    private final LawSpecRuntime.RemoteActor remote;"
        , ""
        , "    private Remote(LawSpecRuntime.RemoteActor remote)"
        , "    {"
        , "      this.remote = remote;"
        , "    }" ] ++ concat methods ++
        [ "  }" ]
    boxed t = shorten <$> javaDataType datas t
    native t = (\b -> maybe b id (lookup b unboxed)) <$> boxed t
    awaited d call = if C.declarationAsync d then call ++ ".join()" else call
    handler own h = do
      params <- sequence [(\n -> n ++ " " ++ p) <$> native t | (p, t) <- handlerArguments h]
      reply <- traverse boxed (handlerReply h)
      result <- maybe (pure "void") native (handlerReply h)
      let call = awaited (handlerDeclaration h) (adapterCall a (handlerDeclaration h) ("s" : map fst (handlerArguments h)))
          replyType = maybe "Object" id reply
          step = case reply of
            Just _ -> "s -> {\n      var next = " ++ call ++ ";\n      return new LawSpecRuntime.Next<" ++ replyType ++ ", " ++ own ++
              ">(next.first(), next.second());\n    }"
            Nothing -> "s -> new LawSpecRuntime.Next<Object, " ++ own ++ ">(null, " ++ call ++ ")"
          name = handlerName h
      pure
        [ "  /** Sends " ++ name ++ " and waits for the reply. */"
        , "  public " ++ result ++ " " ++ name ++ "(" ++ intercalate ", " params ++ ")"
        , "  {"
        , "    " ++ (if reply == Nothing then "" else "return ") ++ "actor.<" ++ replyType ++ ">call(" ++ step ++ ");"
        , "  }"
        , ""
        , "  /** Sends " ++ name ++ " without waiting for the reply. */"
        , "  public void tell" ++ capital name ++ "(" ++ intercalate ", " params ++ ")"
        , "  {"
        , "    actor.cast(" ++ step ++ ");"
        , "  }" ]

kotlinSource :: [C.DataDeclaration] -> Maybe Wire -> Actor -> Either String String
kotlinSource datas wire a = do
  own <- kotlinDataType datas (actorState a)
  let startArgs = actorStartArguments a
  startParams <- sequence [(\n -> p ++ ": " ++ n) <$> kotlinDataType datas t | (p, t) <- startArgs, not (isUnit t)]
  methods <- mapM (handler own) (actorHandlers a)
  remote <- maybe (pure ([], [])) (kotlinRemote own) wire
  let startValues = [if isUnit t then D.text "kotlin.Unit" else D.text p | (p, t) <- startArgs]
      initial = awaited (actorStart a) (adapterCallDoc (actorStart a) startValues)
      restart = case actorRestart a of
        Just d -> (["s"], awaited d (adapterCallDoc d [D.text "s"]))
        Nothing -> (["_"], initial)
      startDoc = kdoc 92 ("Makes the actor's state with " ++ C.declarationName (actorStart a) ++
          " and starts the actor, under supervisor (when given) with the given lifetime.") <> D.hardline <>
        D.text "@JvmStatic" <> D.hardline <> D.text "@JvmOverloads" <> D.hardline <>
        K.callWith (D.text "fun start") (map D.text (startParams ++ ["supervisor: LawSpecRuntime.Supervisor? = null", "lifetime: String = LawSpecRuntime.Supervisor.PERMANENT"])) <>
        D.text (": " ++ cls ++ " ") <> K.block
          [ K.bind "actor" (K.trailing (K.call ("LawSpecRuntime.Actor<" ++ own ++ ">") [initial]) (fst restart) [snd restart])
          , D.text "supervisor?.supervise(actor, lifetime)"
          , D.text ("return " ++ cls ++ "(actor)") ]
      members = D.joinWith (D.hardline <> D.hardline) $
        [ D.text "companion object " <> K.block [D.joinWith (D.hardline <> D.hardline) (fst remote ++ [startDoc])] ] ++
        methods ++
        [ kdoc 96 "Crashes the actor as a failing handler would, after the messages already sent: for testing how it restarts." <> D.hardline <>
          D.text "fun crash() = actor.crash()"
        , kdoc 96 "notify gets Exit(\"crashed\", cause) after each crash, and Exit(\"stopped\", null) once it stops." <> D.hardline <>
          D.text "fun monitor(notify: (LawSpecRuntime.Exit) -> kotlin.Unit) = actor.monitor { notify(it) }"
        , kdoc 96 "When either actor crashes, the other crashes too." <> D.hardline <>
          D.text ("fun link(other: " ++ cls ++ ") = actor.link(other.actor)")
        , kdoc 96 "Refuses further messages; those already sent are still handled." <> D.hardline <>
          D.text "fun stop() = actor.stop()" ] ++ snd remote
      body = D.render K.kotlinStyle members
      imports = [ "lawspec.runtime." ++ c | c <- ["LawSpecDataCodecs", "LawSpecDataSchema", "LawSpecKotlinCodecs", "LawSpecRuntime"], (c ++ ".") `isInfixOf` body || (c ++ "(") `isInfixOf` body || (c ++ "<") `isInfixOf` body ]
  pure $ D.render K.kotlinStyle $
    D.text ("// Generated by LawSpec from actor " ++ actorName a ++ ". Do not edit.") <> D.hardline <>
    D.text "package lawspec.actors" <> D.hardline <> D.hardline <>
    D.joinWith D.hardline [D.text ("import " ++ i) | i <- imports] <> D.hardline <> D.hardline <>
    kdoc 100 ("Actor " ++ actorName a ++ ": owns its state and handles one message at a time, in the order they arrive. " ++
      "Each handler method sends a message and returns the reply; tell methods send it without waiting. " ++
      "A handler that throws crashes the actor: the caller gets LawSpecRuntime.ActorCrashed, and a supervised actor restarts " ++
      "(from its restart adapter, or its start) while any other stops.") <> D.hardline <>
    D.group (D.text ("class " ++ cls) <> D.softline <> D.text ("private constructor(private val actor: LawSpecRuntime.Actor<" ++ own ++ ">)")) <>
    D.text " " <> D.block 4 members <> D.hardline
  where
    cls = actorClass a
    kdoc = javadoc
    awaited d call = if C.declarationAsync d then K.trailing (D.text "kotlinx.coroutines.runBlocking") [] [call] else call
    adapterCallDoc d args = K.call (adapterClass (actorUnit a) ++ "." ++ adapterName (actorUnit a) (C.declarationId d)) args
    codec ty = kotlinCodecDocIn ("SCHEMA", "MACHINE_BITS") (D.text "symbols") datas ty
    descriptor d = K.call "LawSpecRuntime.descriptor" [K.kotlinString d]
    -- The companion's members, and the class's.
    kotlinRemote own w = do
      served <- mapM (\(h, ds, r) -> do
        argCodecs <- mapM (codec . snd) (handlerArguments h)
        replyCodec <- codec (replyOf h)
        let call = awaited (handlerDeclaration h) (adapterCallDoc (handlerDeclaration h)
              (D.text "s" : [K.chain c [("decode", [D.text ("args[" ++ show i ++ "]")])] | (i, c) <- zip [0 :: Int ..] argCodecs]))
            next = "LawSpecRuntime.Next<LawSpecRuntime.Value, " ++ own ++ ">"
            result = case handlerReply h of
              Just _ -> [ K.bind "next" call
                        , K.call next [K.chain replyCodec [("encode", [D.text "next.first"])], D.text "next.second"] ]
              Nothing -> [ K.call next [D.text "LawSpecRuntime.absent(\"Unit\")", call] ]
        pure $ D.group (D.text ("handlers[" ++ show (handlerName h) ++ "] =") <> D.nest 4 (D.softline <>
          K.call ("LawSpecRuntime.Served<" ++ own ++ ">")
            [ K.lambda ["s", "args"] (D.text "val symbols = mutableMapOf<String, Any>()" : result)
            , K.call "listOf" (map descriptor ds)
            , descriptor r ]))) (wireHandlers w)
      methods <- mapM (\(h, _, _) -> do
        params <- sequence [(\n -> p ++ ": " ++ n) <$> kotlinDataType datas t | (p, t) <- handlerArguments h]
        argCodecs <- mapM (codec . snd) (handlerArguments h)
        replyCodec <- codec (replyOf h)
        reply <- traverse (kotlinDataType datas) (handlerReply h)
        let call = K.call "remote.call" [K.kotlinString (handlerName h),
              K.call "listOf" [K.chain c [("encode", [D.text p])] | (c, (p, _)) <- zip argCodecs (handlerArguments h)]]
        pure (kdoc 92 ("Sends " ++ handlerName h ++ " to the actor and waits for the reply.") <> D.hardline <>
          K.callWith (D.text ("fun " ++ handlerName h)) (map D.text params) <> D.text (": " ++ maybe "kotlin.Unit" id reply ++ " ") <>
          K.block [ D.text "val symbols = mutableMapOf<String, Any>()"
                  , if handlerReply h == Nothing then call else D.text "return " <> K.chain replyCodec [("decode", [call])] ])) (wireHandlers w)
      let companion =
            [ D.text "private val SCHEMA = LawSpecDataSchema.create()"
            , D.text ("private const val MACHINE_BITS = " ++ show (wireBits w))
            , K.bind "TYPES" (K.call "LawSpecRuntime.valuesOf" [K.kotlinString (wireTypes w)])
            , kdoc 92 "The actor served at address on another node; a call not answered within timeout seconds throws Unreachable." <> D.hardline <>
              D.text "@JvmStatic" <> D.hardline <> D.text "@JvmOverloads" <> D.hardline <>
              K.callWith (D.text "fun connect") (map D.text ["node: LawSpecRuntime.Node", "address: String", "timeout: Double = 5.0"]) <>
              D.text ": Remote " <> K.block
                ([ D.text "val signatures = HashMap<String, LawSpecRuntime.Signature>()" ] ++
                 [ D.group (D.text ("signatures[" ++ show (handlerName h) ++ "] =") <> D.nest 4 (D.softline <>
                     K.call "LawSpecRuntime.Signature" [K.call "listOf" (map descriptor ds), descriptor r]))
                 | (h, ds, r) <- wireHandlers w ] ++
                 [ D.text "return Remote(node.remoteActor(address, signatures, TYPES, timeout))" ]) ]
          members =
            [ kdoc 96 "Lets other nodes call this actor at {node address}/name; returns that address." <> D.hardline <>
              D.text "fun serve(node: LawSpecRuntime.Node, name: String): String " <> K.block
                ([ D.text ("val handlers = HashMap<String, LawSpecRuntime.Served<" ++ own ++ ">>()") ] ++ served ++
                 [ D.text "return node.serve(name, actor, handlers, TYPES)" ])
            , kdoc 96 ("Actor " ++ actorName a ++ " on another node: each method sends its message and waits for the reply.") <> D.hardline <>
              D.text "class Remote internal constructor(private val remote: LawSpecRuntime.RemoteActor) " <>
              K.block [D.joinWith (D.hardline <> D.hardline) methods] ]
      pure (companion, members)
    handler own h = do
      params <- sequence [(\n -> p ++ ": " ++ n) <$> kotlinDataType datas t | (p, t) <- handlerArguments h]
      reply <- traverse (kotlinDataType datas) (handlerReply h)
      let call = awaited (handlerDeclaration h) (adapterCallDoc (handlerDeclaration h) (D.text "s" : map (D.text . fst) (handlerArguments h)))
          replyType = maybe "kotlin.Unit" id reply
          next = "LawSpecRuntime.Next<" ++ replyType ++ ", " ++ own ++ ">"
          step = case reply of
            Just _ -> K.lambda ["s"] [K.bind "next" call, K.call next [D.text "next.first", D.text "next.second"]]
            Nothing -> K.lambda ["s"] [K.call next [D.text "kotlin.Unit", call]]
          name = handlerName h
          signature n = K.callWith (D.text ("fun " ++ n)) (map D.text params)
      pure $ D.joinWith (D.hardline <> D.hardline)
        [ kdoc 96 ("Sends " ++ name ++ " and waits for the reply.") <> D.hardline <>
          K.equalsBody (signature name <> D.text (": " ++ replyType)) (D.text ("actor.call<" ++ replyType ++ "> ") <> step)
        , kdoc 96 ("Sends " ++ name ++ " without waiting for the reply.") <> D.hardline <>
          signature ("tell" ++ capital name) <> D.text " " <> K.block [D.text "actor.cast " <> step] ]

-- | A supervisor's class: start() makes the runtime supervisor and starts
-- each child under it, in order; each child is a field.
javaSupervisor :: Supervision -> String
javaSupervisor s = unlines $
  [ "// Generated by LawSpec from supervisor " ++ supervisionName s ++ ". Do not edit."
  , "package lawspec.actors;"
  , ""
  , "import lawspec.runtime.LawSpecRuntime;"
  , ""
  , "/** Supervisor " ++ supervisionName s ++ ": " ++ strategyText s ++ ", at most " ++ show (supervisionRestarts s) ++
      " restarts in " ++ seconds s ++ "s. */"
  , "public final class " ++ cls
  , "{"
  , "  private final LawSpecRuntime.Supervisor supervisor;" ] ++
  [ "  public final " ++ childClass c ++ " " ++ name ++ ";" | (_, name, c) <- supervisionChildren s ] ++
  [ ""
  , "  private " ++ cls ++ "(" ++ intercalate ", " ("LawSpecRuntime.Supervisor supervisor" : [childClass c ++ " " ++ name | (_, name, c) <- supervisionChildren s]) ++ ")"
  , "  {"
  , "    this.supervisor = supervisor;" ] ++
  [ "    this." ++ name ++ " = " ++ name ++ ";" | (_, name, _) <- supervisionChildren s ] ++
  [ "  }"
  , ""
  , "  /** Starts the supervisor and its children. */"
  , "  public static " ++ cls ++ " start()"
  , "  {"
  , "    return start(null, LawSpecRuntime.Supervisor.PERMANENT);"
  , "  }"
  , ""
  , "  /** Starts the supervisor and its children, under parent (when not null) with the given lifetime. */"
  , "  public static " ++ cls ++ " start(LawSpecRuntime.Supervisor parent, String lifetime)"
  , "  {"
  , "    var own = new LawSpecRuntime.Supervisor(" ++ show (strategyName s) ++ ", " ++ show (supervisionRestarts s) ++ ", " ++ seconds s ++ ");" ] ++
  [ "    var " ++ name ++ " = " ++ childClass c ++ ".start(own, " ++ show (lifetimeName l) ++ ");" | (l, name, c) <- supervisionChildren s ] ++
  [ "    if (parent != null)"
  , "    {"
  , "      parent.supervise(own, lifetime);"
  , "    }"
  , "    return new " ++ cls ++ "(" ++ intercalate ", " ("own" : [name | (_, name, _) <- supervisionChildren s]) ++ ");"
  , "  }"
  , ""
  , "  /** notify gets Exit(\"crashed\", cause) when it passes its restart limit, and Exit(\"stopped\", null) once stopped. */"
  , "  public void monitor(java.util.function.Consumer<LawSpecRuntime.Exit> notify)"
  , "  {"
  , "    supervisor.monitor(notify);"
  , "  }"
  , ""
  , "  /** Stops every child, last started first, without restarting them. */"
  , "  public void stop()"
  , "  {"
  , "    supervisor.stop();"
  , "  }"
  , "}" ]
  where cls = supervisionClass s

kotlinSupervisor :: Supervision -> String
kotlinSupervisor s = D.render K.kotlinStyle $
  D.text ("// Generated by LawSpec from supervisor " ++ supervisionName s ++ ". Do not edit.") <> D.hardline <>
  D.text "package lawspec.actors" <> D.hardline <> D.hardline <>
  D.text "import lawspec.runtime.LawSpecRuntime" <> D.hardline <> D.hardline <>
  javadoc 100 ("Supervisor " ++ supervisionName s ++ ": " ++ strategyText s ++ ", at most " ++ show (supervisionRestarts s) ++
    " restarts in " ++ seconds s ++ "s.") <> D.hardline <>
  D.group (D.text ("class " ++ cls) <> D.softline <> K.callWith (D.text "private constructor")
    (D.text "private val supervisor: LawSpecRuntime.Supervisor" : [D.text ("val " ++ name ++ ": " ++ childClass c) | (_, name, c) <- supervisionChildren s])) <>
  D.text " " <> D.block 4 (D.joinWith (D.hardline <> D.hardline)
    [ D.text "companion object " <> K.block
        [ javadoc 92 "Starts the supervisor and its children, under parent (when given) with the given lifetime." <> D.hardline <>
          D.text "@JvmStatic" <> D.hardline <> D.text "@JvmOverloads" <> D.hardline <>
          K.callWith (D.text "fun start") (map D.text ["parent: LawSpecRuntime.Supervisor? = null", "lifetime: String = LawSpecRuntime.Supervisor.PERMANENT"]) <>
          D.text (": " ++ cls ++ " ") <> K.block
            ([ K.bind "own" (K.call "LawSpecRuntime.Supervisor" [K.kotlinString (strategyName s), D.text (show (supervisionRestarts s)), D.text (seconds s)]) ] ++
             [ K.bind name (K.call (childClass c ++ ".start") [D.text "own", K.kotlinString (lifetimeName l)]) | (l, name, c) <- supervisionChildren s ] ++
             [ D.text "parent?.supervise(own, lifetime)"
             , D.text "return " <> K.call cls (map D.text ("own" : [name | (_, name, _) <- supervisionChildren s])) ]) ]
    , javadoc 96 "notify gets Exit(\"crashed\", cause) when it passes its restart limit, and Exit(\"stopped\", null) once stopped." <> D.hardline <>
      D.text "fun monitor(notify: (LawSpecRuntime.Exit) -> kotlin.Unit) = supervisor.monitor { notify(it) }"
    , javadoc 96 "Stops every child, last started first, without restarting them." <> D.hardline <>
      D.text "fun stop() = supervisor.stop()" ]) <> D.hardline
  where cls = supervisionClass s

childClass :: Child -> String
childClass c = case c of
  ActorChild a -> actorClass a
  SupervisorChild n -> n

strategyName :: Supervision -> String
strategyName s = case supervisionStrategy s of
  OneForOne -> "one_for_one"
  OneForAll -> "one_for_all"
  RestForOne -> "rest_for_one"

strategyText :: Supervision -> String
strategyText s = case supervisionStrategy s of
  OneForOne -> "one for one"
  OneForAll -> "one for all"
  RestForOne -> "rest for one"

lifetimeName :: Lifetime -> String
lifetimeName l = case l of
  Permanent -> "permanent"
  Transient -> "transient"
  Temporary -> "temporary"

-- | The period in seconds, as a decimal literal.
seconds :: Supervision -> String
seconds s = let (whole, micros) = supervisionPeriod s `divMod` 1000000
                pad m = replicate (6 - length m) '0' ++ m
            in show whole ++ "." ++ (case reverse (dropWhile (== '0') (reverse (pad (show micros)))) of
                                      "" -> "0"
                                      digits -> digits)

capital :: String -> String
capital (c : rest) = toUpper c : rest
capital [] = []

split :: Char -> String -> [String]
split c s = case break (== c) s of
  (a, _ : rest) -> a : split c rest
  (a, []) -> [a]

-- | java.lang names read better unqualified.
shorten :: String -> String
shorten [] = []
shorten s@(c : rest) = case stripPrefix "java.lang." s of
  Just after -> shorten after
  Nothing -> c : shorten rest

unboxed :: [(String, String)]
unboxed = [ ("Byte", "byte"), ("Short", "short"), ("Integer", "int"), ("Long", "long")
          , ("Float", "float"), ("Double", "double"), ("Character", "char"), ("Boolean", "boolean") ]
