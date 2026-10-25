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
import qualified LawSpec.Code.Doc as D
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Names
import LawSpec.Swift.Sessions (wireOf)
import qualified LawSpec.Swift.Data as Data
import Control.Monad (forM)

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
                [ D.text "/// The mailbox's wire form." <> D.hardline <>
                  hangValue "public static let descriptor =" (longStringLiteral w)
                , D.text "/// A mailbox served at name on a node: other nodes send to its address." <> D.hardline <>
                  signature "public static func serve" ["_ node: Node", "_ name: String"] (" throws -> " ++ cls)
                    (callDoc cls [D.text "try Mailbox.serve(node, name, descriptor)"])
                , note "Sends to the mailbox at address on another node; each send waits up to timeout for it to arrive." <>
                  signature "public static func connect" ["_ node: Node", "_ address: String", "timeout: Duration = .seconds(5)"] (" throws -> " ++ cls ++ "Sender")
                    (callDoc (cls ++ "Sender") [callDoc "try MailboxSender" (map D.text ["node", "address", "descriptor", "Timeouts.milliseconds(timeout)"])])
                , lines' [ "/// The served mailbox's address."
                         , "public func address() throws -> String { try mailbox.address() }" ] ]
            sendBody receiver = callDoc ("try " ++ receiver ++ ".send") [codecCall codec "fromNative" [D.text "value"]]
            sender = case wireOf bits datas (C.mailboxType b) of
              Nothing -> []
              Just _ ->
                [ D.text ("/// Sends to mailbox " ++ C.mailboxName b ++ " on another node.") <> D.hardline <>
                  D.text ("public final class " ++ cls ++ "Sender: Sendable") <> blockDoc (
                    lines' [ "let sender: MailboxSender", "", "init(_ sender: MailboxSender) { self.sender = sender }", ""
                           , "/// Sends value, waiting until the mailbox has it." ] <> D.hardline <>
                    signature "public func send" ["_ value: " ++ native] " throws" (sendBody "sender")) ]
            members =
              [ lines' [ "let mailbox: Mailbox", "", "init(_ mailbox: Mailbox) { self.mailbox = mailbox }" ]
              , lines' [ "/// A mailbox in this process.", "public convenience init() { self.init(Mailbox()) }" ]
              , D.text "/// Queues value without waiting." <> D.hardline <>
                signature "public func send" ["_ value: " ++ native] " throws" (sendBody "mailbox")
              , D.text "/// The next message, waiting for one; fails once closed and empty." <> D.hardline <>
                signature "public func receive" [] (" throws -> " ++ native) (codecCall codec "toNative" [D.text "try mailbox.receive()"])
              , D.text "/// The next message within timeout, if one comes." <> D.hardline <>
                signature "public func receiveWithin" ["_ timeout: Duration"] (" throws -> " ++ optional native)
                  (lines' [ "guard let value = try mailbox.receive(within: timeout) else { return nil }" ] <> D.hardline <>
                   hangValue "return" (codecCall codec "toNative" [D.text "value"]))
              , D.text "/// The next message within timeout; fails when none comes." <> D.hardline <>
                signature "public func receive" ["timeout: Duration"] (" throws -> " ++ native)
                  (lines' [ "guard let value = try mailbox.receive(within: timeout) else {"
                          , "  throw Fail.with(\"Mailbox\", \"timeout\")"
                          , "}" ] <> D.hardline <>
                   hangValue "return" (codecCall codec "toNative" [D.text "value"]))
              , lines' [ "/// Refuses later sends; messages already sent can still be received."
                       , "public func close() { mailbox.close() }" ]
              , lines' [ "/// Stops the mailbox: later sends and receives fail."
                       , "public func stop() { mailbox.stop() }" ] ] ++ network
        pure (sender ++
          [ note ("Mailbox " ++ C.mailboxName b ++ ": messages from any number of senders, taken by one receiver.") <>
            D.text ("public final class " ++ cls ++ ": Sendable") <> blockDoc (D.joinWith (D.hardline <> D.hardline) members) ])
      let header = lines'
            [ "// " ++ generatedHeader Nothing
            , ""
            , "import LawSpecRuntime"
            , "" ]
          body = D.text "/// Typed mailboxes: send never waits, one receiver takes messages in order." <> D.hardline <>
            D.text "public enum Mailboxes" <> blockDoc (D.joinWith (D.hardline <> D.hardline) (concat classes))
      pure [Artifact "src/LawSpec/LawSpecMailboxes.swift"
        (D.render swiftLayout (header <> D.hardline <> D.text "extension LawSpec" <> blockDoc body) ++ "\n") "generated" "source"]
  where
    boxes = concatMap C.unitMailboxes units
    lines' = D.joinWith D.hardline . map D.text
    note = D.lineComment 94 "/// "
    optional t = if any (`elem` (" &" :: String)) t then "(" ++ t ++ ")?" else t ++ "?"
