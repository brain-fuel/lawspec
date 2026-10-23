-- | Typed channel ends for Swift implementation code (see LawSpec.Sessions).
--
-- Every protocol P becomes an enum LawSpec.Sessions.P: P.channel() makes a
-- channel and returns its two start ends, P.listen and P.dial give them over
-- a network (when every step has a wire form), and the nested enums P.First
-- (the end that follows the steps) and P.Second (sends and receives
-- swapped) hold a class per position, named for the step it takes next
-- (ReceiveInt32, SendInt64; the step number is appended when a name repeats)
-- and Done. send returns the next end; receive returns the value and the
-- next end, as a tuple. Each end is single use: the runtime refuses a spent
-- one. ref:DEC-sessions-by-construction ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Sessions (emitSessions, wireOf) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.MachineSpec (describe)
import LawSpec.Swift.Code (stringLiteral)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Data as Data
import Control.Monad (forM)
import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate)

data Step = Step { stepNumber :: Int, stepSends :: Bool, stepType :: C.Type }

-- | A type's wire descriptor text, with the data types it uses written
-- first; Nothing when it has none.
wireOf :: Int -> [C.DataDeclaration] -> C.Type -> Maybe String
wireOf bits datas ty = either (const Nothing) Just $ do
  (d, table) <- describe bits datas [] ty
  pure (concatMap ((++ " ") . snd) (reverse table) ++ d)

emitSessions :: Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitSessions bits datas units
  | null sessions = pure []
  | otherwise = do
      names <- dataNames datas
      modules <- mapM (protocolEnum names) sessions
      let header =
            [ "// " ++ generatedHeader Nothing
            , ""
            , "import LawSpecRuntime"
            , ""
            , "extension LawSpec {"
            , "  /// Typed channel ends: for a protocol P, P.channel() makes a channel and"
            , "  /// returns its two ends; P.First follows P's steps and P.Second does the"
            , "  /// reverse. Each class is one end before one step: send returns the end for"
            , "  /// the next step and receive returns the value and that end. After the last"
            , "  /// step the end is a Done. An end can be used only once."
            , "  public enum Sessions {"
            , "    /// Every protocol's steps, as the runtime checks them."
            , "    static let catalogue: [String: [SessionStep]] = ["
            ] ++ ["      " ++ protocolEntry s ++ "," | s <- sessions] ++
            [ "    ]"
            , ""
            , "    /// A protocol's spec, with the network deadline of its ends."
            , "    static func protocolSpec(_ id: String) -> SessionSpec { SessionSpec(id, catalogue, 5000) }"
            ]
      pure [Artifact "src/LawSpec/LawSpecSessions.swift"
        (unlines (header ++ concatMap (\m -> "" : map ("    " ++) m) modules ++ ["  }", "}"])) "generated" "source"]
  where
    sessions = concatMap C.unitSessions units
    sessionOf (C.Constructor n []) = case [s | s <- sessions, C.idText (C.sessionId s) == n] of
      s : _ -> Just s
      [] -> Nothing
    sessionOf _ = Nothing
    shortName n = maybe (reverse (takeWhile (\c -> c /= ':' && c /= '.') (reverse n))) id
      (lookup n [(C.idText (C.dataId d), C.dataName d) | d <- datas])
    capital s = case s of c : cs -> toUpper c : cs; [] -> s
    typeName t = case sessionOf t of
      Just other -> C.sessionName other
      Nothing -> case t of
        C.Constructor n args -> capital (filter isAlphaNum (shortName n)) ++ concat [typeName a | C.TypeArgument a <- args]
        C.TypeVariable _ -> "Value"
        C.Arrow _ _ -> "Function"
    endSteps first s = [Step k (if first then sends else not sends) t | (k, (sends, t)) <- zip [1 ..] (C.sessionSteps s)]
    classNames s ends = [base st ++ suffix st | st <- ends] ++ ["Done"]
      where
        bases = map base ends
        base st = (if stepSends st then "Send" else "Receive") ++ typeName (stepType st)
        suffix st
          | length (filter (== base st) bases) > 1 || base st == C.sessionName s = "Step" ++ show (stepNumber st)
          | otherwise = ""
    startOf s first = "LawSpec.Sessions." ++ C.sessionName s ++ "." ++ (if first then "First" else "Second") ++ "." ++ concat (take 1 (classNames s (endSteps first s)))
    protocolEntry s = stringLiteral (C.idText (C.sessionId s)) ++ ": [" ++
      intercalate ", " [ "SessionStep(" ++ (if sends then "true" else "false") ++ ", " ++
        (case sessionOf ty of
          Just other -> ".end(" ++ stringLiteral (C.idText (C.sessionId other)) ++ ")"
          Nothing -> ".value(" ++ maybe "nil" stringLiteral (wireOf bits datas ty) ++ ")") ++ ")"
      | (sends, ty) <- C.sessionSteps s ] ++ "]"
    protocolEnum names s = do
      first <- endEnum names s True
      second <- endEnum names s False
      let name = C.sessionName s
          firstStart = startOf s True
          secondStart = startOf s False
      pure $
        [ "/// Protocol " ++ name ++ " (" ++ C.idText (C.sessionId s) ++ ")."
        , "public enum " ++ name ++ " {"
        , "  /// The protocol, as the runtime runs it."
        , "  public static let spec: SessionSpec = protocolSpec(" ++ stringLiteral (C.idText (C.sessionId s)) ++ ")"
        , ""
        , "  /// A new channel's two ends, in this process."
        , "  public static func channel() -> (" ++ firstStart ++ ", " ++ secondStart ++ ") {"
        , "    let (first, second) = LawSpecRuntime.Sessions.openPair(spec)"
        , "    return (" ++ firstStart ++ "(first), " ++ secondStart ++ "(second))"
        , "  }"
        , ""
        , "  /// The first end, listening at name on a node; its address is address."
        , "  public static func listen(_ node: Node, _ name: String) throws -> " ++ firstStart ++ " {"
        , "    " ++ firstStart ++ "(try LawSpecRuntime.Sessions.listen(node, name, spec))"
        , "  }"
        , ""
        , "  /// The second end, dialling a listening first end's address."
        , "  public static func dial(_ node: Node, _ address: String) throws -> " ++ secondStart ++ " {"
        , "    " ++ secondStart ++ "(try LawSpecRuntime.Sessions.dial(node, address, spec))"
        , "  }"
        , "" ] ++ map ("  " ++) first ++ [""] ++ map ("  " ++) second ++ ["}"]
    endEnum names s isFirst = do
      let ends = endSteps isFirst s
          classes = classNames s ends
      steps <- forM (zip3 ends classes (drop 1 classes)) $ \(st, cls, next) -> do
        body <- case sessionOf (stepType st) of
          Just other -> do
            let carried = startOf other True
            pure $ if stepSends st
              then [ "/// Sends an unused first end of " ++ C.sessionName other ++ "; the next end."
                   , "@discardableResult"
                   , "public func send(_ value: " ++ carried ++ ") throws -> " ++ next ++ " {"
                   , "  " ++ next ++ "(try LawSpecRuntime.Sessions.sendEnd(end, value.end))"
                   , "}" ]
              else [ "/// Receives a first end of " ++ C.sessionName other ++ "; it and the next end."
                   , "public func receive() throws -> (" ++ carried ++ ", " ++ next ++ ") {"
                   , "  let (value, rest) = try LawSpecRuntime.Sessions.receiveEnd(end)"
                   , "  return (" ++ carried ++ "(value), " ++ next ++ "(rest))"
                   , "}" ]
          Nothing -> do
            t <- Data.nativeType bits names [] (stepType st)
            c <- Data.codec bits names [] (stepType st)
            pure $ if stepSends st
              then [ "/// Sends a value; the next end."
                   , "@discardableResult"
                   , "public func send(_ value: " ++ t ++ ") throws -> " ++ next ++ " {"
                   , "  " ++ next ++ "(try LawSpecRuntime.Sessions.send(end, try " ++ c ++ ".fromNative(value)))"
                   , "}" ]
              else [ "/// Receives a value; it and the next end."
                   , "public func receive() throws -> (" ++ t ++ ", " ++ next ++ ") {"
                   , "  let (value, rest) = try LawSpecRuntime.Sessions.receiveValue(end)"
                   , "  return (try " ++ c ++ ".toNative(value), " ++ next ++ "(rest))"
                   , "}" ]
        pure (endClass cls ("step " ++ show (stepNumber st)) body)
      let done = endClass "Done" "after the last step"
            [ "/// Gives up the end.", "public func close() throws { try LawSpecRuntime.Sessions.abandon(end) }" ]
      pure $
        [ "/// " ++ (if isFirst then "The first end: it follows the steps." else "The second end: it does the reverse.")
        , "public enum " ++ (if isFirst then "First" else "Second") ++ " {" ] ++
        map ("  " ++) (intercalate [""] (steps ++ [done])) ++ ["}"]
    endClass cls position body =
      [ "/// The end before " ++ position ++ "."
      , "public final class " ++ cls ++ ": Sendable {"
      , "  /// The runtime's end."
      , "  public let end: SessionEnd"
      , ""
      , "  init(_ end: SessionEnd) { self.end = end }"
      , ""
      , "  /// The address a network end is reached at."
      , "  public var address: String { get throws { try LawSpecRuntime.Sessions.address(end) } }"
      , "" ] ++ map ("  " ++) body ++ ["}"]
