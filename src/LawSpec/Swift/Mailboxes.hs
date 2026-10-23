-- | Typed mailboxes for Swift implementation code (see LawSpec.Mailboxes):
-- every `mailbox jobs of Job` becomes LawSpec.Mailboxes.JobsMailbox over the
-- runtime's mailbox of portable values, converting at the boundary. send
-- never waits; one receiver takes messages in the order they arrived; close
-- refuses later sends. A mailbox whose type has a wire form can be served on
-- a node, and JobsMailbox.connect sends to one on another node, waiting
-- until it has the message. ref:DEC-actors-otp-supervision
-- ref:DEC-distribution-canonical-wire
module LawSpec.Swift.Mailboxes (emitMailboxes) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.Mailboxes (mailboxClassName)
import LawSpec.Swift.Code (stringLiteral)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Names
import LawSpec.Swift.Sessions (wireOf)
import qualified LawSpec.Swift.Data as Data
import Control.Monad (forM)
import Data.List (intercalate)

emitMailboxes :: Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitMailboxes bits datas units
  | null boxes = pure []
  | otherwise = do
      names <- dataNames datas
      classes <- forM boxes $ \b -> do
        native <- Data.nativeType bits names [] (C.mailboxType b)
        codec <- Data.codec bits names [] (C.mailboxType b)
        let cls = mailboxClassName (C.mailboxName b)
            network = case wireOf bits datas (C.mailboxType b) of
              Nothing -> []
              Just w ->
                [ [ "/// The mailbox's wire form."
                  , "public static let descriptor = " ++ stringLiteral w ]
                , [ "/// A mailbox served at name on a node: other nodes send to its address."
                  , "public static func serve(_ node: Node, _ name: String) throws -> " ++ cls ++ " {"
                  , "  " ++ cls ++ "(try Mailbox.serve(node, name, descriptor))"
                  , "}" ]
                , [ "/// Sends to the mailbox at address on another node; each send waits up to timeout for it to arrive."
                  , "public static func connect(_ node: Node, _ address: String, timeout: Duration = .seconds(5)) throws -> " ++ cls ++ "Sender {"
                  , "  " ++ cls ++ "Sender(try MailboxSender(node, address, descriptor, Timeouts.milliseconds(timeout)))"
                  , "}" ]
                , [ "/// The served mailbox's address."
                  , "public func address() throws -> String { try mailbox.address() }" ] ]
            sender = case wireOf bits datas (C.mailboxType b) of
              Nothing -> []
              Just _ ->
                [ [ "/// Sends to mailbox " ++ C.mailboxName b ++ " on another node."
                  , "public final class " ++ cls ++ "Sender: Sendable {"
                  , "  let sender: MailboxSender"
                  , ""
                  , "  init(_ sender: MailboxSender) { self.sender = sender }"
                  , ""
                  , "  /// Sends value, waiting until the mailbox has it."
                  , "  public func send(_ value: " ++ native ++ ") throws { try sender.send(try " ++ codec ++ ".fromNative(value)) }"
                  , "}" ] ]
            members =
              [ [ "let mailbox: Mailbox"
                , ""
                , "init(_ mailbox: Mailbox) { self.mailbox = mailbox }" ]
              , [ "/// A mailbox in this process."
                , "public convenience init() { self.init(Mailbox()) }" ]
              , [ "/// Queues value without waiting."
                , "public func send(_ value: " ++ native ++ ") throws { try mailbox.send(try " ++ codec ++ ".fromNative(value)) }" ]
              , [ "/// The next message, waiting for one; fails once closed and empty."
                , "public func receive() throws -> " ++ native ++ " { try " ++ codec ++ ".toNative(try mailbox.receive()) }" ]
              , [ "/// The next message within timeout, if one comes."
                , "public func receiveWithin(_ timeout: Duration) throws -> " ++ optional native ++ " {"
                , "  guard let value = try mailbox.receive(within: timeout) else { return nil }"
                , "  return try " ++ codec ++ ".toNative(value)"
                , "}" ]
              , [ "/// The next message within timeout; fails when none comes."
                , "public func receive(timeout: Duration) throws -> " ++ native ++ " {"
                , "  guard let value = try mailbox.receive(within: timeout) else { throw Fail.with(\"Mailbox\", \"timeout\") }"
                , "  return try " ++ codec ++ ".toNative(value)"
                , "}" ]
              , [ "/// Refuses later sends; messages already sent can still be received."
                , "public func close() { mailbox.close() }" ]
              , [ "/// Stops the mailbox: later sends and receives fail."
                , "public func stop() { mailbox.stop() }" ] ] ++ network
        pure (sender ++
          [ [ "/// Mailbox " ++ C.mailboxName b ++ ": messages from any number of senders, taken by one receiver."
            , "public final class " ++ cls ++ ": Sendable {" ] ++ map indent (intercalate [""] members) ++ ["}"] ])
      let header =
            [ "// " ++ generatedHeader Nothing
            , ""
            , "import LawSpecRuntime"
            , ""
            , "extension LawSpec {"
            , "  /// Typed mailboxes: send never waits, one receiver takes messages in order."
            , "  public enum Mailboxes {" ]
      pure [Artifact "src/LawSpec/LawSpecMailboxes.swift"
        (unlines (header ++ map (\l -> if null l then l else "    " ++ l) (intercalate [""] (concat classes)) ++ ["  }", "}"])) "generated" "source"]
  where
    boxes = concatMap C.unitMailboxes units
    indent l = if null l then l else "  " ++ l
    optional t = if any (`elem` (" &" :: String)) t then "(" ++ t ++ ")?" else t ++ "?"
