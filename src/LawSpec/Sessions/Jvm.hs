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

import qualified LawSpec.JavaLayout as J
import qualified LawSpec.JavaExpr as E
import Control.Monad (foldM)
import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate, isInfixOf, stripPrefix)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.JavaData (javaDataTypeDoc, identifier, javaCodecDocWithContext)
import LawSpec.KotlinData (kotlinCodecDocWithContext, kotlinCodecDocIn, kotlinDataType)
import LawSpec.ScalaData (scalaCodecDocWithContext, scalaCodecDocIn, scalaDataType)
import qualified LawSpec.ScalaLayout as SL
import qualified LawSpec.KotlinLayout as KL
import LawSpec.JvmNames (javadoc)
import LawSpec.MachineSpec (describe)
import LawSpec.Scalar (isInteger, nativeRepresentation)

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
            [Artifact ("src/main/" ++ target ++ "/lawspec/sessions/" ++ C.sessionName s ++ "Conversions." ++ (if target == "scala" then "scala" else "kt")) k "generated" "source" | Just k <- [kotlin]])

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
data Part = Scalar String | Codec D.Doc | EndOf C.Session

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
          _ | target == "java" -> Codec <$> javaCodecDocWithContext (D.text "symbols") datas bits ty
            | target == "scala" -> Codec <$> scalaCodecDocWithContext (D.text "symbols") datas ty
            | otherwise -> Codec <$> kotlinCodecDocWithContext (D.text "symbols") datas ty
        pure (t', acc ++ [(sends, d, p)])

networkSource :: String -> Int -> [C.DataDeclaration] -> [C.Session] -> C.Session -> Either String ([D.Doc], Maybe String)
networkSource target bits datas sessions session = do
  (parts, table) <- networkParts target bits datas sessions session
  let name = C.sessionName session
      codecs = [(i, c, t) | (i, (_, _, Codec c), (_, t)) <- zip3 [0 :: Int ..] parts (C.sessionSteps session)]
      -- Kotlin's and Scala's codecs are their own objects, which the Java
      -- protocol class reaches through a generated conversions object.
      kotlin = target `elem` ["kotlin", "scala"]
      partPiece (i, (_, _, p)) = case p of
        Scalar n -> J.call "LawSpecRuntime.scalarConversion" [D.text (show n), D.text (show bits)]
        Codec _ | kotlin -> J.call (name ++ "Conversions.conversion" ++ show i) []
                | otherwise -> J.call "LawSpecRuntime.conversion"
                    [D.text ("codec" ++ show i ++ "::encode"), D.text ("codec" ++ show i ++ "::decode")]
        EndOf q -> let start = firstStart datas sessions q in
          J.call "new LawSpecRuntime.EndPart"
            [ J.lambdaValue ["channel"] (J.call ("new " ++ start) [D.text "channel"])
            , J.lambdaValue ["end"] (J.method (D.text ("((" ++ start ++ ") end)")) "handOver" [])
            , D.text (C.sessionName q ++ "::wire") ]
      first = startClass datas sessions session True
      second = startClass datas sessions session False
  kotlinFile <- if kotlin && not (null codecs)
    then Just <$> (if target == "scala" then scalaConversions name codecs else kotlinConversions name codecs)
    else pure Nothing
  pure (
    [ J.assigned (D.text "private static final lawspec.runtime.LawSpecSchema SCHEMA")
        (J.call "lawspec.runtime.LawSpecDataSchema.create" []) | not (null codecs), not kotlin ] ++
    [ J.assigned (D.text "private static final LawSpecRuntime.Values TYPES")
        (J.call "LawSpecRuntime.valuesOf" [E.quoted (unwords (map snd (reverse table)))])
    , commented "Each step's descriptor and conversion, from the first end." $
        J.block (J.signature "static " (D.text "LawSpecRuntime.Wire") "wire" []) $
          [J.bind "symbols" (J.call "new java.util.HashMap<String, Object>" [])] ++
          [J.bind ("codec" ++ show i) c | not kotlin, (i, c, _) <- codecs] ++
          [J.returned (J.call "new LawSpecRuntime.Wire"
            [ J.call "java.util.List.of"
                [J.call "new LawSpecRuntime.Step"
                  [D.text (if sends then "true" else "false"), J.call "LawSpecRuntime.descriptor" [E.quoted d]]
                | (sends, d, _) <- parts]
            , J.call "java.util.Arrays.<Object>asList" (map partPiece (zip [0 :: Int ..] parts))
            , D.text "TYPES" ])]
    , commented "The first end of a channel named name on node, which another node dials at {node address}/name. An end sent over it to another node moves there (a local end stays and is relayed by this node)." $
        J.block (J.signature "public static " (D.text ("First." ++ first)) "listen"
          [J.parameter (D.text "LawSpecRuntime.Node") "node", J.parameter (D.text "String") "name"])
          [ J.bind "w" (J.call "wire" [])
          , J.returned (J.call ("new First." ++ first)
              [J.call "new LawSpecRuntime.NativeChannel"
                [J.method (D.text "node") "listen" [D.text "name", J.call "w.steps" [], J.call "w.values" []], J.call "w.parts" []]]) ]
    , commented "The second end of the channel listening at address on another node." $
        J.block (J.signature "public static " (D.text ("Second." ++ second)) "dial"
          [J.parameter (D.text "LawSpecRuntime.Node") "node", J.parameter (D.text "String") "address"])
          [ J.bind "w" (J.call "wire" [])
          , J.bind "steps" (J.call "new java.util.ArrayList<LawSpecRuntime.Step>" [])
          , J.block (D.text "for (var step : w.steps())")
              [J.statement (J.method (D.text "steps") "add"
                [J.call "new LawSpecRuntime.Step" [D.text "!step.sends()", J.call "step.descriptor" []]])]
          , J.returned (J.call ("new Second." ++ second)
              [J.call "new LawSpecRuntime.NativeChannel"
                [J.method (D.text "node") "dial" [D.text "address", D.text "steps", J.call "w.values" []], J.call "w.parts" []]]) ]
    ], kotlinFile)
  where
    scalaConversions name codecs = do
      functions <- mapM (\(i, _, t) -> do
        native <- scalaDataType datas t
        codec <- scalaCodecDocIn ("Schema", "MachineBits") (D.text "symbols") datas t
        pure (D.text ("def conversion" ++ show i ++ "(): LawSpecRuntime.Conversion = ") <> SL.block
          [ D.text "val symbols = LawSpecScala.symbols()"
          , SL.bind "codec" codec
          , SL.call ("LawSpecRuntime.conversion[" ++ native ++ "]")
              [D.text ("(value: " ++ native ++ ") => codec.encode(value)"), D.text "(value: LawSpecRuntime.Value) => codec.decode(value)"] ])) codecs
      let members = [D.text "private val Schema = LawSpecDataSchema.create()", D.text ("private val MachineBits = " ++ show bits)] ++ functions
          code = D.render D.Compact (D.joinWith D.hardline members)
          imports = [ "import lawspec.runtime." ++ c | c <- ["LawSpecDataCodecs", "LawSpecDataSchema", "LawSpecRuntime", "LawSpecScala", "LawSpecScalaCodecs"], (c ++ ".") `isInfixOf` code ]
      pure $ D.render SL.scalaStyle $
        D.text ("// Generated by LawSpec from protocol " ++ name ++ ". Do not edit.") <> D.hardline <>
        D.text "package lawspec.sessions" <> D.hardline <> D.hardline <>
        D.joinWith D.hardline (map D.text imports) <> D.hardline <> D.hardline <>
        SL.comment 80 ("Conversions of protocol " ++ name ++ "'s data steps, for its ends between nodes.") <>
        D.text ("object " ++ name ++ "Conversions ") <> SL.block [D.joinWith (D.hardline <> D.hardline) members] <> D.hardline
    kotlinConversions name codecs = do
      functions <- mapM (\(i, _, t) -> do
        native <- kotlinDataType datas t
        codec <- kotlinCodecDocIn ("SCHEMA", "MACHINE_BITS") (D.text "symbols") datas t
        pure (D.text "@JvmStatic" <> D.hardline <> D.text ("fun conversion" ++ show i ++ "(): LawSpecRuntime.Conversion ") <> KL.block
          [ D.text "val symbols = mutableMapOf<String, Any>()"
          , KL.bind "codec" codec
          , D.text "return " <> KL.call ("LawSpecRuntime.conversion<" ++ native ++ ">") [KL.lambda [] [D.text "codec.encode(it)"], KL.lambda [] [D.text "codec.decode(it)"]] ])) codecs
      let members = [D.text "private val SCHEMA = LawSpecDataSchema.create()" <> D.hardline <> D.text ("private const val MACHINE_BITS = " ++ show bits)] ++ functions
          code = D.render D.Compact (D.joinWith D.hardline members)
          imports = [ "import lawspec.runtime." ++ c | c <- ["LawSpecDataCodecs", "LawSpecDataSchema", "LawSpecKotlinCodecs", "LawSpecRuntime"], (c ++ ".") `isInfixOf` code ]
      pure $ D.render KL.kotlinStyle $
        D.text ("// Generated by LawSpec from protocol " ++ name ++ ". Do not edit.") <> D.hardline <>
        D.text "package lawspec.sessions" <> D.hardline <> D.hardline <>
        D.joinWith D.hardline (map D.text imports) <> D.hardline <> D.hardline <>
        javadoc 100 ("Conversions of protocol " ++ name ++ "'s data steps, for its ends between nodes.") <> D.hardline <>
        D.text ("object " ++ name ++ "Conversions ") <> KL.block [D.joinWith (D.hardline <> D.hardline) members] <> D.hardline

-- | A Java comment and declaration share the enclosing indentation.
commented :: String -> D.Doc -> D.Doc
commented comment declaration = javadoc 84 comment <> D.hardline <> declaration

protocolSource :: [C.DataDeclaration] -> [C.Session] -> [D.Doc] -> C.Session -> Either String String
protocolSource datas sessions network session = do
  firstEnd <- endSource "First" "first" 0 (endSteps True session)
  secondEnd <- endSource "Second" "second" 1 (endSteps False session)
  pure $ D.render (D.Pretty 100) $
    D.text ("// Generated by LawSpec from protocol " ++ name ++ ". Do not edit.") <> D.hardline <> D.hardline <>
    D.text "package lawspec.sessions;" <> D.hardline <> D.hardline <>
    D.text "import java.util.concurrent.atomic.AtomicBoolean;" <> D.hardline <>
    D.text "import lawspec.runtime.LawSpecRuntime;" <> D.hardline <> D.hardline <>
    commented ("Protocol " ++ name ++ ": the typed ends of a channel.\n\n<p>The first end " ++ summary (endSteps True session) ++
      "; the second end does the reverse. Each end class is an end before one step: taking the step returns the next end, and an end can be used only once.")
      (J.block (D.text ("public final class " ++ name)) (separated $
        [ D.text ("private " ++ name ++ "() {}")
        , commented "Both ends of a fresh channel." $
            D.group (D.text "public record " <> J.call "Ends"
              [J.parameter (D.text ("First." ++ start True)) "first", J.parameter (D.text ("Second." ++ start False)) "second"] <> D.text " {}")
        , commented "Opens a fresh in-memory channel and returns its two ends." $
            J.block (J.signature "public static " (D.text "Ends") "open" [])
              [ J.bind "channel" (J.call "LawSpecRuntime.channel" [])
              , J.returned (J.call "new Ends"
                  [J.call ("new First." ++ start True) [D.text "channel"], J.call ("new Second." ++ start False) [D.text "channel"]]) ]
        ] ++ network ++ [firstEnd, secondEnd])) <> D.hardline
  where
    name = C.sessionName session
    start = startClass datas sessions session
    shown = display datas sessions
    separated [] = []
    separated [one] = [one]
    separated (first : rest) = (first <> D.hardline) : separated rest
    summary [] = "takes no steps"
    summary ends = intercalate ", " [(if stepSends s then "sends " else "receives ") ++ article (shown (stepType s)) | s <- ends]
    claim = J.statement (J.call "LawSpecRuntime.claimEnd" [D.text "used"])
    nextEnd cls = J.call ("new " ++ cls) [D.text "channel"]
    emptyConstructor cls = D.text (cls ++ "(LawSpecRuntime.Channel channel) {}")

    endSource className label side ends = do
      let names = classNames datas sessions session ends
      positions <- mapM (position label side names) (zip3 [0 :: Int ..] (map Just ends ++ [Nothing]) names)
      pure $ commented ("The " ++ label ++ " end: it " ++ summary ends ++ ".") $
        J.block (D.text ("public static final class " ++ className)) (separated $
          D.text ("private " ++ className ++ "() {}") : positions)

    position label side names (index, step, cls) = do
      let travels = index == 0 && side == (0 :: Int)
          moved = if not travels then [] else
            [ commented "Hands this end, unused, to a send; this object becomes used." $
                J.block (J.signature "" (D.text cls) "moved" []) [claim, J.returned (nextEnd cls)]
            , commented "This unused end's channel, to send to another node; this object becomes used." $
                J.block (J.signature "" (D.text "LawSpecRuntime.Channel") "handOver" []) [claim, J.returned (D.text "channel")]
            ]
      case step of
        -- A completed end has no live channel. An empty delegated protocol
        -- moves as the same completed object.
        Nothing -> pure $ commented ("The " ++ label ++ " end after its last step: the protocol is done.") $
          J.block (D.text "public static final class Done") (separated $
            [emptyConstructor "Done"] ++
            [J.block (J.signature "" (D.text "Done") "moved" []) [J.returned (D.text "this")] | travels])
        Just s -> do
          let next = names !! (index + 1)
              described = article (shown (stepType s))
          (boxed, parameter, sent) <- valueType (stepType s)
          let action
                | stepSends s = commented ("Sends " ++ described ++ " and returns the next end.") $
                    J.block (J.signature "public " (D.text next) "send" [J.parameter parameter "value"])
                      [claim, J.statement (J.call "channel.send" [D.text (show side), sent]), J.returned (nextEnd next)]
                | otherwise = commented ("Receives " ++ described ++ " (blocking), with the next end; throws PeerFailed if the other end gave up.") $
                    (if generic (stepType s) then D.text "@SuppressWarnings(\"unchecked\")" <> D.hardline else mempty) <>
                    J.block (J.signature "public " (J.applied "LawSpecRuntime.Received" [boxed, D.text next]) "receive" [])
                      [ claim
                      , J.bind "value" (D.group (D.text "(" <> boxed <> D.text ") " <> J.call "channel.receive" [D.text (show side)]))
                      , J.returned (J.call "new LawSpecRuntime.Received<>" [D.text "value", nextEnd next]) ]
              abandon = commented "Gives up the conversation: the other end's receives throw PeerFailed after what was sent." $
                J.block (J.signature "public " (D.text "void") "abandon" [])
                  [claim, J.statement (J.call "channel.abandon" [D.text (show side)])]
              description = "The " ++ label ++ " end before step " ++ show (stepNumber s) ++ ": it " ++
                (if stepSends s then "sends " else "receives ") ++ described ++ "."
          pure $ commented description $ J.block (D.text ("public static final class " ++ cls)) $
            [ D.text "private final LawSpecRuntime.Channel channel;"
            , J.assigned (D.text "private final AtomicBoolean used") (J.call "new AtomicBoolean" [])
            , mempty
            , J.block (D.text cls <> J.call "" [J.parameter (D.text "LawSpecRuntime.Channel") "channel"])
                [J.assigned (D.text "this.channel") (D.text "channel")]
            ] ++ mempty : separated ([action, abandon] ++ moved)

    generic (C.Constructor _ arguments) = any isType arguments
    generic (C.Arrow _ _) = True
    generic _ = False
    isType (C.TypeArgument _) = True
    isType _ = False

    -- Native types and primitive parameters come from checked Core types;
    -- codec and type layout never makes a round trip through Java text.
    valueType ty = case sessionOf sessions ty of
      Just other -> let cls = D.text (firstStart datas sessions other) in
        pure (cls, cls, J.call "value.moved" [])
      Nothing -> do
        boxed <- D.mapText shorten <$> javaDataTypeDoc datas ty
        let parameter = case ty of
              C.Constructor scalar [] | Just native <- nativeRepresentation "java" scalar,
                native `elem` map snd unboxed -> D.text native
              _ -> boxed
        pure (boxed, parameter, D.text "value")

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
