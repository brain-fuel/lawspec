-- | Typed channel ends for implementation code: each protocol's steps as
-- types of this target (see LawSpec.Sessions).
--
-- Both JVM targets get the same Java sources (a Kotlin project compiles
-- src/main/java too): per protocol P, a class lawspec.sessions.P whose nested
-- First and Second classes hold one final class per position of that end,
-- named after the step it takes next (ReceiveInt32, SendInt64; the step
-- number is appended when a name repeats on the end), and Done. P.open()
-- returns both ends of a fresh channel; send returns the next end, receive a
-- LawSpecRuntime.Received of the value and the next end. Each end is single
-- use (LawSpecRuntime.claimEnd).
module LawSpec.Sessions.Jvm (emit) where

import Control.Monad (foldM)
import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, isInfixOf, stripPrefix)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.JavaData (javaDataType, identifier, javaCodecDocWithContext)
import LawSpec.KotlinData (kotlinCodecDocWithContext, kotlinDataType)
import LawSpec.MachineSpec (describe)
import LawSpec.Scalar (isInteger)

-- | The session library for the given target, for every unit's protocols.
emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target _ bits datas units = concat <$> mapM artifact sessions
  where
    sessions = concatMap C.unitSessions units
    -- Protocols that can run between nodes: every value step has a wire
    -- descriptor and a conversion, and every protocol whose end a step sends
    -- can too (and has steps, so its end has a channel to send).
    described = [s | s <- sessions, Right _ <- [networkParts target bits datas sessions s]]
    settle ws = let kept = [s | s <- ws, all (\(_, t) -> maybe True (\q -> C.sessionName q `elem` map C.sessionName ws && not (null (C.sessionSteps q))) (sessionOf sessions t)) (C.sessionSteps s)]
                in if length kept == length ws then ws else settle kept
    wired = map C.sessionName (settle described)
    artifact s = do
      identifier (C.sessionName s)
      (network, kotlin) <- if C.sessionName s `elem` wired
        then networkSource target bits datas sessions s
        else pure ([], Nothing)
      source <- protocolSource datas sessions network s
      pure ([Artifact ("src/main/java/lawspec/sessions/" ++ C.sessionName s ++ ".java") source "generated" "source"] ++
            [Artifact ("src/main/kotlin/lawspec/sessions/" ++ C.sessionName s ++ "Conversions.kt") k "generated" "source" | Just k <- [kotlin]])

-- | A step as one end sees it: its number, whether this end sends, its type.
data Step = Step { stepNumber :: Int, stepSends :: Bool, stepType :: C.Type }

-- | The steps of a session's first end (True) or second end (False).
endSteps :: Bool -> C.Session -> [Step]
endSteps first session =
  [Step k (if first then sends else not sends) t | (k, (sends, t)) <- zip [1 ..] (C.sessionSteps session)]

-- | The class names of an end's positions: one per step, then Done.
classNames :: [C.DataDeclaration] -> [C.Session] -> C.Session -> [Step] -> [String]
classNames datas sessions session ends = [base s ++ suffix s | s <- ends] ++ ["Done"]
  where
    bases = map base ends
    base s = (if stepSends s then "Send" else "Receive") ++ typeName datas sessions (stepType s)
    suffix s
      | length (filter (== base s) bases) > 1 || base s == C.sessionName session = "Step" ++ show (stepNumber s)
      | otherwise = ""

-- | The protocol a step's type names, if it is a delegated end.
sessionOf :: [C.Session] -> C.Type -> Maybe C.Session
sessionOf sessions (C.Constructor n []) = case [s | s <- sessions, C.idText (C.sessionId s) == n] of
  s : _ -> Just s
  [] -> Nothing
sessionOf _ _ = Nothing

-- | The class a protocol's first end starts as.
firstStart :: [C.DataDeclaration] -> [C.Session] -> C.Session -> String
firstStart datas sessions s = C.sessionName s ++ ".First." ++ startClass datas sessions s True

-- | The class an end of a session starts as (Done when it has no steps).
startClass :: [C.DataDeclaration] -> [C.Session] -> C.Session -> Bool -> String
startClass datas sessions s first = case classNames datas sessions s (endSteps first s) of
  cls : _ -> cls
  [] -> "Done"

typeName :: [C.DataDeclaration] -> [C.Session] -> C.Type -> String
typeName datas sessions t = case sessionOf sessions t of
  Just other -> C.sessionName other
  Nothing -> case t of
    C.Constructor n args -> capital (filter isAlphaNum (shortName datas n)) ++ concat [typeName datas sessions a | C.TypeArgument a <- args]
    C.TypeVariable _ -> "Value"
    C.Arrow _ _ -> "Function"

display :: [C.DataDeclaration] -> [C.Session] -> C.Type -> String
display datas sessions t = case sessionOf sessions t of
  Just other -> C.sessionName other ++ "'s first end"
  Nothing -> case t of
    C.Constructor n [] -> shortName datas n
    C.Constructor n args -> "(" ++ unwords (shortName datas n : [display datas sessions a | C.TypeArgument a <- args]) ++ ")"
    C.TypeVariable _ -> "value"
    C.Arrow _ _ -> "function"

shortName :: [C.DataDeclaration] -> String -> String
shortName datas n = maybe lastSegment id (lookup n [(C.idText (C.dataId d), C.dataName d) | d <- datas])
  where lastSegment = reverse (takeWhile (\c -> c /= ':' && c /= '.') (reverse n))

-- | listen and dial: a protocol's ends over a network. wire() lists each
-- step's descriptor and part from the first end: a scalar converts through
-- the runtime, a data value through its codec (Java's, or for Kotlin a
-- generated Kotlin object, since Kotlin's codecs are Kotlin objects), and a
-- step sending another protocol's end is an EndPart (the end goes by the
-- address the receiver takes it over from, or a relay's for a local end).
data Part = Scalar String | Codec String | EndOf C.Session

networkParts :: String -> Int -> [C.DataDeclaration] -> [C.Session] -> C.Session -> Either String ([(Bool, String, Part)], [(String, String)])
networkParts target bits datas sessions session = do
  (table, parts) <- foldM part ([], []) (C.sessionSteps session)
  pure (parts, table)
  where
    part (t, acc) (sends, ty) = case sessionOf sessions ty of
      Just q -> pure (t, acc ++ [(sends, "(end)", EndOf q)])
      Nothing -> do
        (d, t') <- describe bits datas t ty
        p <- case ty of
          C.Constructor n [] | isInteger n || n `elem` ["Bool", "Text"] -> pure (Scalar n)
          _ | target == "java" -> Codec . D.render (D.Pretty 1000) <$> javaCodecDocWithContext (D.text "symbols") datas bits ty
            | otherwise -> Codec . D.render (D.Pretty 1000) <$> kotlinCodecDocWithContext (D.text "symbols") datas ty
        pure (t', acc ++ [(sends, d, p)])

networkSource :: String -> Int -> [C.DataDeclaration] -> [C.Session] -> C.Session -> Either String ([String], Maybe String)
networkSource target bits datas sessions session = do
  (parts, table) <- networkParts target bits datas sessions session
  let name = C.sessionName session
      codecs = [(i, c, t) | (i, (_, _, Codec c), (_, t)) <- zip3 [0 :: Int ..] parts (C.sessionSteps session)]
      kotlin = target == "kotlin"
      partDoc (i, (_, _, p)) = case p of
        Scalar n -> "LawSpecRuntime.scalarConversion(" ++ show n ++ ", " ++ show bits ++ ")"
        Codec _ | kotlin -> name ++ "Conversions.conversion" ++ show i ++ "()"
                | otherwise -> "LawSpecRuntime.conversion(codec" ++ show i ++ "::encode, codec" ++ show i ++ "::decode)"
        EndOf q -> let start = firstStart datas sessions q in
          "new LawSpecRuntime.EndPart(c -> new " ++ start ++ "(c), e -> ((" ++ start ++ ") e).handOver(), " ++ C.sessionName q ++ "::wire)"
      first = startClass datas sessions session True
      second = startClass datas sessions session False
  kotlinFile <- if kotlin && not (null codecs)
    then Just <$> kotlinConversions name codecs
    else pure Nothing
  pure (
    [ "" ] ++
    [ l | not (null codecs), not kotlin, l <- ["  private static final lawspec.runtime.LawSpecSchema _schema =", "      lawspec.runtime.LawSpecDataSchema.create();", ""] ] ++
    [ "  private static final LawSpecRuntime.Values TYPES = LawSpecRuntime.valuesOf(" ++ show (unwords (map snd (reverse table))) ++ ");"
    , ""
    , "  /** Each step's descriptor and conversion, from the first end. */"
    , "  static LawSpecRuntime.Wire wire() {"
    , "    var symbols = new java.util.HashMap<String, Object>();" ] ++
    [ "    var codec" ++ show i ++ " = " ++ c ++ ";" | not kotlin, (i, c, _) <- codecs ] ++
    [ "    return new LawSpecRuntime.Wire("
    , "        java.util.List.of(" ++ intercalate ", "
        ["new LawSpecRuntime.Step(" ++ (if sends then "true" else "false") ++ ", LawSpecRuntime.descriptor(" ++ show d ++ "))" | (sends, d, _) <- parts] ++ "),"
    , "        java.util.Arrays.<Object>asList(" ++ intercalate ", " (map partDoc (zip [0 ..] parts)) ++ "),"
    , "        TYPES);"
    , "  }"
    , ""
    , "  /**"
    , "   * The first end of a channel named name on node, which another node dials at {node"
    , "   * address}/name. An end sent over it to another node moves there (a local end stays and is"
    , "   * relayed by this node)."
    , "   */"
    , "  public static First." ++ first ++ " listen(LawSpecRuntime.Node node, String name) {"
    , "    var w = wire();"
    , "    return new First." ++ first ++ "(new LawSpecRuntime.NativeChannel(node.listen(name, w.steps(), w.values()), w.parts()));"
    , "  }"
    , ""
    , "  /** The second end of the channel listening at address on another node. */"
    , "  public static Second." ++ second ++ " dial(LawSpecRuntime.Node node, String address) {"
    , "    var w = wire();"
    , "    var steps = new java.util.ArrayList<LawSpecRuntime.Step>();"
    , "    for (var s : w.steps()) steps.add(new LawSpecRuntime.Step(!s.sends(), s.descriptor()));"
    , "    return new Second." ++ second ++ "(new LawSpecRuntime.NativeChannel(node.dial(address, steps, w.values()), w.parts()));"
    , "  }" ], kotlinFile)
  where
    kotlinConversions name codecs = do
      functions <- mapM (\(i, c, t) -> do
        native <- kotlinDataType datas t
        pure [ ""
             , "    @JvmStatic"
             , "    fun conversion" ++ show i ++ "(): LawSpecRuntime.Conversion {"
             , "        val symbols = mutableMapOf<String, Any>()"
             , "        val codec = " ++ c
             , "        return LawSpecRuntime.conversion<" ++ native ++ ">({ codec.encode(it) }, { codec.decode(it) })"
             , "    }" ]) codecs
      let body = unlines (concat functions)
          imports = [ "import lawspec.runtime." ++ x | x <- ["LawSpecDataCodecs", "LawSpecKotlinCodecs"], (x ++ ".") `isInfixOf` body ] ++
                    [ "import lawspec.runtime.LawSpecDataSchema" ]
      pure $ unlines $
        [ "// Generated by LawSpec from protocol " ++ name ++ ". Do not edit."
        , "package lawspec.sessions"
        , ""
        , "import lawspec.runtime.LawSpecRuntime" ] ++ imports ++
        [ ""
        , "/** Conversions of protocol " ++ name ++ "'s data steps, for its ends between nodes. */"
        , "object " ++ name ++ "Conversions {"
        , "    private val schema = LawSpecDataSchema.create()"
        , "    private const val bits = " ++ show bits ] ++ concat functions ++ [ "}" ]

protocolSource :: [C.DataDeclaration] -> [C.Session] -> [String] -> C.Session -> Either String String
protocolSource datas sessions network session = do
  firstEnd <- endSource "First" "first" 0 (endSteps True session)
  secondEnd <- endSource "Second" "second" 1 (endSteps False session)
  pure $ unlines $
    [ "// Generated by LawSpec from protocol " ++ name ++ ". Do not edit."
    , "package lawspec.sessions;"
    , ""
    , "import java.util.concurrent.atomic.AtomicBoolean;"
    , "import lawspec.runtime.LawSpecRuntime;"
    , ""
    , "/**"
    , " * Protocol " ++ name ++ ": the typed ends of a channel."
    , " *"
    , " * <p>The first end " ++ summary (endSteps True session) ++ "; the second end does the reverse."
    , " * Each end class is an end before one step: taking the step returns the next end,"
    , " * and an end can be used only once."
    , " */"
    , "public final class " ++ name ++ " {"
    , "  private " ++ name ++ "() {}"
    , ""
    , "  /** Both ends of a fresh channel. */"
    , "  public record Ends(First." ++ start True ++ " first, Second." ++ start False ++ " second) {}"
    , ""
    , "  /** Opens a fresh in-memory channel and returns its two ends. */"
    , "  public static Ends open() {"
    , "    var channel = LawSpecRuntime.channel();"
    , "    return new Ends(new First." ++ start True ++ "(channel), new Second." ++ start False ++ "(channel));"
    , "  }" ] ++ network ++
    [ "" ] ++ firstEnd ++ [""] ++ secondEnd ++ ["}"]
  where
    name = C.sessionName session
    start = startClass datas sessions session
    shown = display datas sessions

    summary [] = "takes no steps"
    summary ends = intercalate ", " [(if stepSends s then "sends " else "receives ") ++ article (shown (stepType s)) | s <- ends]

    endSource className label side ends = do
      let names = classNames datas sessions session ends
      positions <- mapM (position label side names) (zip3 [0 :: Int ..] (map Just ends ++ [Nothing]) names)
      pure $
        [ "  /** The " ++ label ++ " end: it " ++ summary ends ++ ". */"
        , "  public static final class " ++ className ++ " {"
        , "    private " ++ className ++ "() {}"
        ] ++ concatMap ("" :) positions ++ ["  }"]

    position label side names (index, step, cls) = do
      let -- Only a first end travels over another channel (a delegated end).
          moved = if index /= 0 || side /= (0 :: Int) then [] else
            [ ""
            , "      /** Hands this end, unused, to a send; this object becomes used. */"
            , "      " ++ cls ++ " moved() {"
            , "        LawSpecRuntime.claimEnd(used);"
            , "        return new " ++ cls ++ "(channel);"
            , "      }"
            , ""
            , "      /** This unused end's channel, to send to another node; this object becomes used. */"
            , "      LawSpecRuntime.Channel handOver() {"
            , "        LawSpecRuntime.claimEnd(used);"
            , "        return channel;"
            , "      }" ]
          header doc =
            [ "    /** " ++ doc ++ " */"
            , "    public static final class " ++ cls ++ " {"
            , "      private final LawSpecRuntime.Channel channel;"
            , "      private final AtomicBoolean used = new AtomicBoolean();"
            , ""
            , "      " ++ cls ++ "(LawSpecRuntime.Channel channel) {"
            , "        this.channel = channel;"
            , "      }" ]
      case step of
        -- Nothing is left to use, so Done holds no channel; one that travels
        -- (a protocol with no steps) is handed over as it is.
        Nothing -> pure $
          [ "    /** The " ++ label ++ " end after its last step: the protocol is done. */"
          , "    public static final class Done {"
          , "      Done(LawSpecRuntime.Channel channel) {}" ] ++
          (if null moved then [] else ["", "      Done moved() {", "        return this;", "      }"]) ++
          ["    }"]
        Just s -> do
          let next = names !! (index + 1)
              described = article (shown (stepType s))
          (boxed, parameter, sent) <- valueType (stepType s)
          let body
                | stepSends s =
                    [ ""
                    , "      /** Sends " ++ described ++ " and returns the next end. */"
                    , "      public " ++ next ++ " send(" ++ parameter ++ " value) {"
                    , "        LawSpecRuntime.claimEnd(used);"
                    , "        channel.send(" ++ show side ++ ", " ++ sent ++ ");"
                    , "        return new " ++ next ++ "(channel);"
                    , "      }" ]
                | otherwise =
                    [ ""
                    , "      /** Receives " ++ described ++ " (blocking), with the next end; throws PeerFailed if the other end gave up. */"
                    ] ++ [ "      @SuppressWarnings(\"unchecked\")" | '<' `elem` boxed ] ++
                    [ "      public LawSpecRuntime.Received<" ++ boxed ++ ", " ++ next ++ "> receive() {"
                    , "        LawSpecRuntime.claimEnd(used);"
                    , "        var value = (" ++ boxed ++ ") channel.receive(" ++ show side ++ ");"
                    , "        return new LawSpecRuntime.Received<>(value, new " ++ next ++ "(channel));"
                    , "      }" ]
              doc = "The " ++ label ++ " end before step " ++ show (stepNumber s) ++ ": it " ++
                (if stepSends s then "sends " else "receives ") ++ described ++ "."
              abandon =
                [ ""
                , "      /** Gives up the conversation: the other end's receives throw PeerFailed after what was sent. */"
                , "      public void abandon() {"
                , "        LawSpecRuntime.claimEnd(used);"
                , "        channel.abandon(" ++ show side ++ ");"
                , "      }" ]
          pure (header doc ++ body ++ abandon ++ moved ++ ["    }"])

    -- A step's value as a type argument and as a send parameter, and what a
    -- send puts on the channel. A delegated end is sent unused.
    valueType t = case sessionOf sessions t of
      Just other -> let cls = firstStart datas sessions other in pure (cls, cls, "value.moved()")
      Nothing -> do
        boxed <- shorten <$> javaDataType datas t
        pure (boxed, maybe boxed id (lookup boxed unboxed), "value")

article :: String -> String
article word | '\'' `elem` word = word
article word@(c : _) | toUpper c `elem` ("AEIOU" :: String) = "an " ++ word
article word = "a " ++ word

capital :: String -> String
capital (c : rest) = toUpper c : rest
capital [] = []

-- | java.lang names read better unqualified.
shorten :: String -> String
shorten [] = []
shorten s@(c : rest) = case stripPrefix "java.lang." s of
  Just after -> shorten after
  Nothing -> c : shorten rest

unboxed :: [(String, String)]
unboxed = [ ("Byte", "byte"), ("Short", "short"), ("Integer", "int"), ("Long", "long")
          , ("Float", "float"), ("Double", "double"), ("Character", "char"), ("Boolean", "boolean") ]
