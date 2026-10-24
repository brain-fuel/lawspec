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
import qualified LawSpec.DotNet.Layout as L
import Control.Monad (forM)

emitMailboxes :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitMailboxes _ bits datas units
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
            -- A codec's conversion of a value.
            convert member x
              | take 1 codec == "(" = L.App ("Codec." ++ member) [L.A codec, x]
              | otherwise = L.App (codec ++ "." ++ (if member == "toNative" then "ToNative" else "FromNative")) [x]
            member doc ls = L.pad 4 ("/// " ++ doc) : ls
            function declaration result body = L.function 4 declaration [] result body
            network = case wire of
              Nothing -> []
              Just w ->
                [ member "The mailbox's wire form." (L.binding 4 "static member Descriptor" (L.A (stringLiteral FSharp w)))
                , member "A mailbox served at name on a node: other nodes send to its Address."
                    (function "static member Serve(node: Node, name: string)" (Just cls)
                      (L.Method ("new " ++ cls) [L.Method "Mailbox.Serve" [L.A "node", L.A "name", L.A (cls ++ ".Descriptor")]]))
                , member "Sends to the mailbox at address on another node; each send waits up to timeout for it to arrive."
                    (function "static member Connect(node: Node, address: string, timeout: TimeSpan)" (Just (cls ++ "Sender"))
                      (L.Method (cls ++ "Sender") [L.Method "MailboxSender" [L.A "node", L.A "address", L.A (cls ++ ".Descriptor"), L.App "int" [L.A "timeout.TotalMilliseconds"]]]))
                , member "Sends to the mailbox at address on another node, waiting up to 5 seconds for each send to arrive."
                    (function "static member Connect(node: Node, address: string)" (Just (cls ++ "Sender"))
                      (L.Method (cls ++ ".Connect") [L.A "node", L.A "address", L.App "TimeSpan.FromSeconds" [L.A "5.0"]]))
                , member "The served mailbox's address." (L.binding 4 "member _.Address: string" (L.A "mailbox.Address")) ]
            sender = case wire of
              Nothing -> []
              Just _ ->
                [ [ "/// Sends to mailbox " ++ C.mailboxName b ++ " on another node.", "[<Sealed>]"
                  , "type " ++ cls ++ "Sender internal (sender: MailboxSender) =" ] ++
                  member "Sends value, waiting until the mailbox has it."
                    (function ("member _.Send(value: " ++ native ++ ")") (Just "unit") (L.Method "sender.Send" [convert "fromNative" (L.A "value")])) ]
        pure (sender ++ [[ "/// Mailbox " ++ C.mailboxName b ++ ": messages from any number of senders, taken by one receiver.", "[<Sealed>]"
          , "type " ++ cls ++ " internal (mailbox: Mailbox) =" ] ++ L.separatedBy [""] (
            [ member "A mailbox in this process." [L.pad 4 ("new() = new " ++ cls ++ "(new Mailbox())")]
            , member "Queues value without waiting." (function ("member _.Send(value: " ++ native ++ ")") (Just "unit")
                (L.Method "mailbox.Send" [convert "fromNative" (L.A "value")]))
            , member "The next message, waiting for one; fails once closed and empty." (function "member _.Receive()" (Just native)
                (convert "toNative" (L.A "(mailbox.Receive())")))
            , member "The next message within timeout, if one comes." (function "member _.ReceiveWithin(timeout: TimeSpan)" (Just (native ++ " option"))
                (L.Match (L.A "mailbox.ReceiveWithin(System.Numerics.BigInteger(timeout.Ticks / 10L))")
                  [("Value.Data(\"Maybe::Present\", [ value ])", L.App "Some" [convert "toNative" (L.A "value")]), ("_", L.A "None")]))
            , member "The next message within timeout; fails when none comes." (function "member this.Receive(timeout: TimeSpan)" (Just native)
                (L.Match (L.A "this.ReceiveWithin timeout") [("Some value", L.A "value"), ("None", L.A "Fail.raiseWith \"Mailbox\" \"timeout\"")]))
            , member "Refuses later sends; messages already sent can still be received." [L.pad 4 "member _.Close() : unit = mailbox.Close()"]
            , member "Stops the mailbox: later sends and receives fail." [L.pad 4 "member _.Stop() : unit = mailbox.Stop()"]
            , [L.pad 4 "interface IDisposable with", L.pad 8 "member _.Dispose() = mailbox.Stop()"] ] ++ network)])
      let text = unlines ([ "// Generated by LawSpec. Do not edit."
            , "/// Typed mailboxes: send never waits, one receiver takes messages in order."
            , "namespace LawSpec.Mailboxes", "", "open System", "open LawSpec.Runtime", "" ] ++ L.separatedBy [""] (concat classes))
      pure [Artifact "src/LawSpec/Mailboxes.fs" text "generated" "source"]
  where
    boxes = concatMap C.unitMailboxes units
