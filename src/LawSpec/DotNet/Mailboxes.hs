-- | Typed mailboxes for F# implementation code (see LawSpec.Mailboxes): every
-- `mailbox jobs of Job` becomes LawSpec.Mailboxes.JobsMailbox over the
-- runtime's mailbox of portable values, converting at the boundary. Send
-- never waits; one receiver takes messages in the order they arrived; Close
-- refuses later sends. A mailbox whose type has a wire form can be served on
-- a node, and JobsMailbox.Connect sends to one on another node, waiting until
-- it has the message. ref:DEC-actors-otp-supervision ref:DEC-distribution-canonical-wire
module LawSpec.DotNet.Mailboxes (emitMailboxes) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..))
import LawSpec.MachineSpec (describe)
import LawSpec.Mailboxes (mailboxClassName)
import LawSpec.DotNet.Code (stringLiteral, Lang(..))
import LawSpec.DotNet.Names
import qualified LawSpec.DotNet.Data as Data
import Control.Monad (forM)

emitMailboxes :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitMailboxes layout bits datas units
  | null boxes = pure []
  | otherwise = do
      names <- dataNames datas
      classes <- forM boxes $ \b -> do
        native <- Data.nativeType FSharp bits names [] (C.mailboxType b)
        codec <- Data.codec FSharp bits names [] (C.mailboxType b)
        let cls = mailboxClassName (C.mailboxName b)
            wire = either (const Nothing) Just $ do
              (d, table) <- describe bits datas [] (C.mailboxType b)
              pure (concatMap ((++ " ") . snd) (reverse table) ++ d)
            member doc text = D.text ("/// " ++ doc) <> D.hardline <> D.text text
            network = case wire of
              Nothing -> []
              Just w ->
                [ member "The mailbox's wire form." ("static member Descriptor = " ++ stringLiteral FSharp w)
                , member "A mailbox served at name on a node: other nodes send to its Address."
                    ("static member Serve(node: Node, name: string) : " ++ cls ++ " = new " ++ cls ++ "(Mailbox.Serve(node, name, " ++ cls ++ ".Descriptor))")
                , member "Sends to the mailbox at address on another node; each send waits up to timeout (5s by default) for it to arrive."
                    ("static member Connect(node: Node, address: string, ?timeout: TimeSpan) : " ++ cls ++ "Sender =") <> D.nest 4 (D.hardline <>
                      D.text ("let milliseconds = match timeout with Some t -> int t.TotalMilliseconds | None -> 5000") <> D.hardline <>
                      D.text (cls ++ "Sender(MailboxSender(node, address, " ++ cls ++ ".Descriptor, milliseconds))"))
                , member "The served mailbox's address." "member _.Address : string = mailbox.Address" ]
            sender = case wire of
              Nothing -> []
              Just _ ->
                [ D.text ("/// Sends to mailbox " ++ C.mailboxName b ++ " on another node.") <> D.hardline <>
                  D.text "[<Sealed>]" <> D.hardline <>
                  D.text ("type " ++ cls ++ "Sender internal (sender: MailboxSender) =") <> D.nest 4 (D.hardline <>
                    member "Sends value, waiting until the mailbox has it." ("member _.Send(value: " ++ native ++ ") : unit = sender.Send(" ++ codec ++ ".FromNative value)")) ]
        pure (sender ++ [D.text ("/// Mailbox " ++ C.mailboxName b ++ ": messages from any number of senders, taken by one receiver.") <> D.hardline <>
          D.text "[<Sealed>]" <> D.hardline <>
          D.text ("type " ++ cls ++ " internal (mailbox: Mailbox) =") <> D.nest 4 (D.hardline <> D.joinWith (D.hardline <> D.hardline) (
            [ member "A mailbox in this process." ("new() = new " ++ cls ++ "(new Mailbox())")
            , member "Queues value without waiting." ("member _.Send(value: " ++ native ++ ") : unit = mailbox.Send(" ++ codec ++ ".FromNative value)")
            , member "The next message, waiting for one; fails once closed and empty." ("member _.Receive() : " ++ native ++ " = " ++ codec ++ ".ToNative (mailbox.Receive())")
            , member "The next message within timeout, if one comes." ("member _.ReceiveWithin(timeout: TimeSpan) : " ++ native ++ " option =") <> D.nest 4 (D.hardline <>
                D.text "match mailbox.ReceiveWithin(System.Numerics.BigInteger(timeout.Ticks / 10L)) with" <> D.hardline <>
                D.text ("| Value.Data(\"Maybe::Just\", [ value ]) -> Some(" ++ codec ++ ".ToNative value)") <> D.hardline <>
                D.text "| _ -> None")
            , member "The next message within timeout; fails when none comes." ("member this.Receive(timeout: TimeSpan) : " ++ native ++ " =") <> D.nest 4 (D.hardline <>
                D.text "match this.ReceiveWithin timeout with" <> D.hardline <>
                D.text "| Some value -> value" <> D.hardline <>
                D.text ("| None -> Fail.raiseWith \"Mailbox\" \"timeout\""))
            , member "Refuses later sends; messages already sent can still be received." "member _.Close() : unit = mailbox.Close()"
            , member "Stops the mailbox: later sends and receives fail." "member _.Stop() : unit = mailbox.Stop()"
            , D.text "interface IDisposable with" <> D.nest 4 (D.hardline <> D.text "member _.Dispose() = mailbox.Stop()") ] ++ network))])
      let doc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "/// Typed mailboxes: send never waits, one receiver takes messages in order." <> D.hardline <>
            D.text "namespace LawSpec.Mailboxes" <> D.hardline <> D.hardline <>
            D.text "open System" <> D.hardline <> D.text "open LawSpec.Runtime" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (concat classes) <> D.hardline
      pure [Artifact "src/LawSpec/Mailboxes.fs" (D.render layout doc) "generated" "source"]
  where
    boxes = concatMap C.unitMailboxes units
