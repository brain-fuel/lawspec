-- Typed channel ends for implementation code: each protocol's steps as
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
import Data.List (intercalate, stripPrefix)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.JavaData (javaDataType, identifier, javaCodecDocWithContext)
import LawSpec.MachineSpec (describe)
import LawSpec.Scalar (isInteger)

-- The session library for the given target, for every unit's protocols.
emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target _ bits datas units = mapM artifact sessions
  where
    sessions = concatMap C.unitSessions units
    artifact s = do
      identifier (C.sessionName s)
      network <- either (const (pure [])) pure (networkSource target bits datas sessions s)
      source <- protocolSource datas sessions network s
      pure (Artifact ("src/main/java/lawspec/sessions/" ++ C.sessionName s ++ ".java") source "generated" "source")

-- A step as one end sees it: its number, whether this end sends, its type.
data Step = Step { stepNumber :: Int, stepSends :: Bool, stepType :: C.Type }

-- The steps of a session's first end (True) or second end (False).
endSteps :: Bool -> C.Session -> [Step]
endSteps first session =
  [Step k (if first then sends else not sends) t | (k, (sends, t)) <- zip [1 ..] (C.sessionSteps session)]

-- The class names of an end's positions: one per step, then Done.
classNames :: [C.DataDeclaration] -> [C.Session] -> C.Session -> [Step] -> [String]
classNames datas sessions session ends = [base s ++ suffix s | s <- ends] ++ ["Done"]
  where
    bases = map base ends
    base s = (if stepSends s then "Send" else "Receive") ++ typeName datas sessions (stepType s)
    suffix s
      | length (filter (== base s) bases) > 1 || base s == C.sessionName session = "Step" ++ show (stepNumber s)
      | otherwise = ""

-- The protocol a step's type names, if it is a delegated end.
sessionOf :: [C.Session] -> C.Type -> Maybe C.Session
sessionOf sessions (C.Constructor n []) = case [s | s <- sessions, C.idText (C.sessionId s) == n] of
  s : _ -> Just s
  [] -> Nothing
sessionOf _ _ = Nothing

-- The class a protocol's first end starts as.
firstStart :: [C.DataDeclaration] -> [C.Session] -> C.Session -> String
firstStart datas sessions s = C.sessionName s ++ ".First." ++ startClass datas sessions s True

-- The class an end of a session starts as (Done when it has no steps).
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

-- listen and dial: a protocol's ends over a network, when its steps have
-- wire descriptors and delegate no ends. Scalar steps convert through the
-- runtime; a data step through the Java codec (Java projects only, since
-- Kotlin's codecs are Kotlin objects).
networkSource :: String -> Int -> [C.DataDeclaration] -> [C.Session] -> C.Session -> Either String [String]
networkSource target bits datas sessions session = do
  let steps = C.sessionSteps session
  if any (\(_, t) -> sessionOf sessions t /= Nothing) steps then Left "delegates" else pure ()
  (table, ds) <- foldM (\(t, acc) (_, ty) -> (\(d, t') -> (t', acc ++ [d])) <$> describe bits datas t ty) ([], []) steps
  conversions <- mapM conversion (zip [0 :: Int ..] (map snd steps))
  let codecs = [c | (Just c, _) <- conversions]
      stepList first = "java.util.List.of(" ++ intercalate ", "
        ["new LawSpecRuntime.Step(" ++ (if (if first then sends else not sends) then "true" else "false") ++ ", LawSpecRuntime.descriptor(" ++ show d ++ "))"
        | ((sends, _), d) <- zip steps ds] ++ ")"
      first = startClass datas sessions session True
      second = startClass datas sessions session False
  pure $
    [ "" ] ++
    [ l | not (null codecs), l <- ["  private static final lawspec.runtime.LawSpecSchema _schema =", "      lawspec.runtime.LawSpecDataSchema.create();", ""] ] ++
    [ "  private static final LawSpecRuntime.Values TYPES = LawSpecRuntime.valuesOf(" ++ show (unwords (map snd (reverse table))) ++ ");"
    , ""
    , "  private static java.util.List<LawSpecRuntime.Conversion> conversions() {"
    , "    var symbols = new java.util.HashMap<String, Object>();" ] ++
    [ "    var codec" ++ show i ++ " = " ++ c ++ ";" | (i, (Just c, _)) <- zip [0 :: Int ..] conversions ] ++
    [ "    return java.util.List.of(" ++ intercalate ", " (map snd conversions) ++ ");"
    , "  }"
    , ""
    , "  /** The first end of a channel named name on node, which another node dials at {node address}/name. */"
    , "  public static First." ++ first ++ " listen(LawSpecRuntime.Node node, String name) {"
    , "    return new First." ++ first ++ "(new LawSpecRuntime.NativeChannel(node.listen(name, " ++ stepList True ++ ", TYPES), conversions()));"
    , "  }"
    , ""
    , "  /** The second end of the channel listening at address on another node. */"
    , "  public static Second." ++ second ++ " dial(LawSpecRuntime.Node node, String address) {"
    , "    return new Second." ++ second ++ "(new LawSpecRuntime.NativeChannel(node.dial(address, " ++ stepList False ++ ", TYPES), conversions()));"
    , "  }" ]
  where
    conversion (i, ty) = case ty of
      C.Constructor n [] | isInteger n || n `elem` ["Bool", "Text"] ->
        pure (Nothing, "LawSpecRuntime.scalarConversion(" ++ show n ++ ", " ++ show bits ++ ")")
      _ | target == "java" -> do
        c <- D.render (D.Pretty 1000) <$> javaCodecDocWithContext (D.text "symbols") datas bits ty
        pure (Just c, "LawSpecRuntime.conversion(codec" ++ show i ++ "::encode, codec" ++ show i ++ "::decode)")
      _ -> Left "a Kotlin protocol's data steps have no Java codec"

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

-- java.lang names read better unqualified.
shorten :: String -> String
shorten [] = []
shorten s@(c : rest) = case stripPrefix "java.lang." s of
  Just after -> shorten after
  Nothing -> c : shorten rest

unboxed :: [(String, String)]
unboxed = [ ("Byte", "byte"), ("Short", "short"), ("Integer", "int"), ("Long", "long")
          , ("Float", "float"), ("Double", "double"), ("Character", "char"), ("Boolean", "boolean") ]
