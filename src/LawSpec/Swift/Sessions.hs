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
import qualified LawSpec.Code.Doc as D
import LawSpec.Swift.Code
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
      let header = lines'
            [ "// " ++ generatedHeader Nothing
            , ""
            , "import LawSpecRuntime"
            , "" ]
          body = lines'
            [ "/// Typed channel ends: for a protocol P, P.channel() makes a channel and"
            , "/// returns its two ends; P.First follows P's steps and P.Second does the"
            , "/// reverse. Each class is one end before one step: send returns the end for"
            , "/// the next step and receive returns the value and that end. After the last"
            , "/// step the end is a Done. An end can be used only once." ] <> D.hardline <>
            D.text "public enum Sessions" <> blockDoc (
              lines' [ "/// Every protocol's steps, as the runtime checks them." ] <> D.hardline <>
              D.text "static let catalogue: [String: [SessionStep]] = " <> brokenList "[" "]" (length sessions > 1) (map protocolEntry sessions) <>
              D.hardline <> D.hardline <>
              lines'
                [ "/// A protocol's spec, with the network deadline of its ends."
                , "static func protocolSpec(_ id: String) -> SessionSpec {"
                , "  SessionSpec(id, catalogue, 5000)"
                , "}" ] <>
              mconcat [D.hardline <> D.hardline <> m | m <- modules])
      pure [Artifact "src/LawSpec/LawSpecSessions.swift"
        (D.render swiftLayout (header <> D.hardline <> D.text "extension LawSpec" <> blockDoc body) ++ "\n") "generated" "source"]
  where
    lines' = D.joinWith D.hardline . map D.text
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
    -- A protocol's start end, named within LawSpec.Sessions (P.First.X),
    -- which every end of every protocol is inside.
    startOf s first = C.sessionName s ++ "." ++ (if first then "First" else "Second") ++ "." ++ concat (take 1 (classNames s (endSteps first s)))
    protocolEntry s = D.text (stringLiteral (C.idText (C.sessionId s)) ++ ": ") <>
      arrayDoc [ callDoc "SessionStep" [D.text (if sends then "true" else "false"),
        case sessionOf ty of
          Just other -> callDoc ".end" [D.text (stringLiteral (C.idText (C.sessionId other)))]
          Nothing -> callDoc ".value" [D.text (maybe "nil" stringLiteral (wireOf bits datas ty))]]
      | (sends, ty) <- C.sessionSteps s ]
    function opening parameters result body = signature opening parameters result (D.joinWith D.hardline body)
    protocolEnum names s = do
      first <- endEnum names s True
      second <- endEnum names s False
      let name = C.sessionName s
          firstStart = startOf s True
          secondStart = startOf s False
      pure $
        lines' ["/// Protocol " ++ name ++ " (" ++ C.idText (C.sessionId s) ++ ")."] <> D.hardline <>
        D.text ("public enum " ++ name) <> blockDoc (D.joinWith (D.hardline <> D.hardline)
          [ lines' ["/// The protocol, as the runtime runs it."] <> D.hardline <>
            hangValue "public static let spec: SessionSpec =" (callDoc "protocolSpec" [D.text (stringLiteral (C.idText (C.sessionId s)))])
          , lines' ["/// A new channel's two ends, in this process."] <> D.hardline <>
            function "public static func channel" [] (" -> " ++ "(" ++ firstStart ++ ", " ++ secondStart ++ ")")
              [ D.text "let (first, second) = LawSpecRuntime.Sessions.openPair(spec)"
              , hangValue "return" (argumentsDoc [D.text (firstStart ++ "(first)"), D.text (secondStart ++ "(second)")]) ]
          , lines' ["/// The first end, listening at name on a node; its address is address."] <> D.hardline <>
            function "public static func listen" ["_ node: Node", "_ name: String"] (" throws -> " ++ firstStart)
              [ callDoc firstStart [D.text "try LawSpecRuntime.Sessions.listen(node, name, spec)"] ]
          , lines' ["/// The second end, dialling a listening first end's address."] <> D.hardline <>
            function "public static func dial" ["_ node: Node", "_ address: String"] (" throws -> " ++ secondStart)
              [ callDoc secondStart [D.text "try LawSpecRuntime.Sessions.dial(node, address, spec)"] ]
          , first
          , second ])
    endEnum names s isFirst = do
      let ends = endSteps isFirst s
          classes = classNames s ends
      steps <- forM (zip3 ends classes (drop 1 classes)) $ \(st, cls, next) -> do
        body <- case sessionOf (stepType st) of
          Just other -> do
            let carried = startOf other True
            pure $ if stepSends st
              then lines' [ "/// Sends an unused first end of " ++ C.sessionName other ++ "; the next end.", "@discardableResult" ] <> D.hardline <>
                   function "public func send" ["_ value: " ++ carried] (" throws -> " ++ next)
                     [ callDoc next [D.text "try LawSpecRuntime.Sessions.sendEnd(end, value.end)"] ]
              else lines' [ "/// Receives a first end of " ++ C.sessionName other ++ "; it and the next end." ] <> D.hardline <>
                   function "public func receive" [] (" throws -> (" ++ carried ++ ", " ++ next ++ ")")
                     [ D.text "let (value, rest) = try LawSpecRuntime.Sessions.receiveEnd(end)"
                     , hangValue "return" (argumentsDoc [D.text (carried ++ "(value)"), D.text (next ++ "(rest)")]) ]
          Nothing -> do
            t <- Data.nativeType bits names [] (stepType st)
            c <- Data.codec bits names [] (stepType st)
            pure $ if stepSends st
              then lines' [ "/// Sends a value; the next end.", "@discardableResult" ] <> D.hardline <>
                   function "public func send" ["_ value: " ++ t] (" throws -> " ++ next)
                     [ callDoc next [callDoc "try LawSpecRuntime.Sessions.send" [D.text "end", codecCall c "fromNative" [D.text "value"]]] ]
              else lines' [ "/// Receives a value; it and the next end." ] <> D.hardline <>
                   function "public func receive" [] (" throws -> (" ++ t ++ ", " ++ next ++ ")")
                     [ D.text "let (value, rest) = try LawSpecRuntime.Sessions.receiveValue(end)"
                     , hangValue "return" (argumentsDoc [codecCall c "toNative" [D.text "value"], D.text (next ++ "(rest)")]) ]
        pure (endClass cls ("step " ++ show (stepNumber st)) body)
      let done = endClass "Done" "after the last step"
            (lines' [ "/// Gives up the end.", "public func close() throws { try LawSpecRuntime.Sessions.abandon(end) }" ])
      pure $
        lines' [ "/// " ++ (if isFirst then "The first end: it follows the steps." else "The second end: it does the reverse.") ] <> D.hardline <>
        D.text ("public enum " ++ (if isFirst then "First" else "Second")) <> blockDoc (D.joinWith (D.hardline <> D.hardline) (steps ++ [done]))
    endClass cls position body =
      lines' [ "/// The end before " ++ position ++ "." ] <> D.hardline <>
      D.text ("public final class " ++ cls ++ ": Sendable") <> blockDoc (
        lines'
          [ "/// The runtime's end."
          , "public let end: SessionEnd"
          , ""
          , "init(_ end: SessionEnd) { self.end = end }"
          , ""
          , "/// The address a network end is reached at."
          , "public var address: String {"
          , "  get throws { try LawSpecRuntime.Sessions.address(end) }"
          , "}"
          , "" ] <> D.hardline <> body)
