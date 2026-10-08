-- | Native mailbox APIs keep unit namespaces and validate the same logical
-- payload for local queues and canonical remote delivery. Clock callbacks
-- use the caller's checked ability context, outside the queue process.
-- ref:DEC-idiomatic-generated-types ref:DEC-distribution-canonical-wire
module LawSpec.BeamMailboxes (emit) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamAbilities as Abilities
import qualified LawSpec.BeamEffects as Effects
import LawSpec.Common (Artifact(..))
import LawSpec.MachineSpec (describe)
import Control.Monad (forM, unless)
import Data.List (nub)

data NativeType = NativeType D.Doc D.Doc D.Doc [D.Doc]
data Function = Function String [(String,NativeType)] NativeType [D.Doc]

emit :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target layout bits declarations units = do
  names <- E.dataNames declarations
  let boxes = [(u,b) | u <- units, b <- C.unitMailboxes u]
      modules = [moduleName u b | (u,b) <- boxes]
  unless (length modules == length (nub modules) && all (\n -> not (null n) && length n <= 230) modules)
    (Left "BEAM mailbox module names collide after snake_case conversion or exceed the Erlang limit")
  concat <$> forM boxes (\(unit,box) -> do
    let ty = C.mailboxType box
        maybeTy = C.Constructor "Maybe" [C.TypeArgument ty]
        native t = NativeType <$> E.nativeType bits names [] t <*> X.nativeType bits names [] t <*>
          G.nativeType False names [] t <*> pure (G.imports False [t])
        className = E.pascal (C.mailboxName box) ++ "Mailbox"
        own = NativeType (E.call "t" []) (X.call "t" []) (D.text className) []
        sender = NativeType (E.call "sender" []) (X.call "sender" []) (D.text (className ++ "Sender")) []
        result = NativeType (E.atom (if target == "gleam" then "nil" else "ok")) (X.atom "ok") (D.text "Nil") []
        variable = D.text . ("_Ls" ++) . E.pascal
        boxVar = variable "mailbox"
        schema = D.text "_LsSchema"
        fresh = D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []]
        runtime = E.remote "lawspec_beam_mailbox"
        bridge direction ref value = E.remote "lawspec_beam_schema" direction [value,ref,schema]
        unitValue = E.atom (if target == "gleam" then "nil" else "ok")
        callback = NativeType (D.text "fun((t()) -> term())") (D.text "(t() -> term())")
          (D.text ("fn(" ++ className ++ ") -> result")) []
        generic = NativeType (E.call "term" []) (X.call "term" []) (D.text "result") []
    value <- native ty
    optional <- native maybeTy
    integer <- native (C.Constructor "Integer" [])
    text <- native (C.Constructor "Text" [])
    reference <- E.typeReference ty
    maybeReference <- E.typeReference maybeTy
    clockFunctions <- concat <$> forM [C.abilityInstance a | a <- Effects.abilities units,
      C.abilityKey (C.abilityInstance a) == "lawspec.time::ability::Clock"] (\clock -> do
        handler <- NativeType <$> Abilities.nativeType "erlang" units clock <*> Abilities.nativeType "elixir" units clock <*>
          Abilities.nativeType "gleam" units clock <*> Abilities.gleamImports units [clock]
        body <- Abilities.publicBody units [(clock,variable "clock")]
          (bridge "to_native" maybeReference (runtime "receive_with_clock" [boxVar,variable "microseconds",schema]))
        pure [Function "receive_with_clock" [("mailbox",own),("microseconds",integer),("clock",handler)] optional [body]])
    let wire = case describe bits declarations [] ty of
          Left _ -> Nothing
          Right (descriptor,table) -> Just (unwords (map snd (reverse table) ++ [descriptor]))
        local =
          [Function "open" [] own [runtime "open" []],
           Function "with_mailbox" [("body",callback)] generic [runtime "with_mailbox" [variable "body"]],
           Function "send" [("mailbox",own),("value",value)] result
             [fresh,runtime "send" [boxVar,bridge "from_native" reference (variable "value")],unitValue],
           Function "receive_value" [("mailbox",own)] value
             [fresh,bridge "to_native" reference (runtime "receive_value" [boxVar])],
           Function "receive_within" [("mailbox",own),("microseconds",integer)] optional
             [fresh,bridge "to_native" maybeReference (runtime "receive_within" [boxVar,variable "microseconds"])],
           Function "close" [("mailbox",own)] result [runtime "close" [boxVar],unitValue],
           Function "stop" [("mailbox",own)] result [runtime "stop" [boxVar],unitValue]]
        remote = case wire of
          Nothing -> []
          Just descriptor ->
            [Function "serve" [("node",nodeType),("name",text)] own
              [runtime "serve" [variable "node",variable "name",E.binary descriptor]],
             Function "address" [("mailbox",own)] text [runtime "address" [boxVar]],
             Function "connect" [("node",nodeType),("address",text),("timeout_milliseconds",integer)] sender
              [runtime "connect" [variable "node",variable "address",E.binary descriptor,variable "timeout_milliseconds"]],
             Function "send_remote" [("sender",sender),("value",value)] result
              [fresh,runtime "send_remote" [variable "sender",bridge "from_native" reference (variable "value")],unitValue]]
    pure (render target layout unit box className (wire /= Nothing) (local ++ clockFunctions ++ remote)))

moduleName :: C.Unit -> C.Mailbox -> String
moduleName unit box = "lawspec_mailbox_" ++ E.moduleName (C.unitId unit) ++ "_" ++ E.snake (C.mailboxName box)
nodeType :: NativeType
nodeType = NativeType (E.call "pid" []) (X.call "pid" []) (D.text "network.Node")
  [D.text "import lawspec/network"]

render :: String -> D.Layout -> C.Unit -> C.Mailbox -> String -> Bool -> [Function] -> [Artifact]
render target layout unit box typeName wired functions =
  Artifact ("src/" ++ name ++ ".erl") (D.render layout erlang) "generated" "source" : case target of
    "elixir" -> [Artifact ("lib/" ++ path ++ ".ex") (D.render layout elixir) "generated" "source"]
    "gleam" -> [Artifact ("src/" ++ path ++ ".gleam") (D.render layout gleam) "generated" "source"]
    _ -> []
  where
    name = moduleName unit box
    path = "lawspec/mailboxes/" ++ E.gleamPath (C.unitId unit) ++ "/" ++ E.snake (C.mailboxName box)
    exModule = "LawSpec.Mailboxes." ++ drop 7 (E.nativeModule "elixir" unit) ++ "." ++ typeName
    erlType (NativeType e _ _ _) = e
    exType (NativeType _ x _ _) = x
    gleamType (NativeType _ _ g _) = g
    imports (NativeType _ _ _ i) = i
    erlang = E.moduleDoc name [(n,length ps) | Function n ps _ _ <- functions]
      ([D.text ("-export_type([t/0" ++ (if wired then ", sender/0" else "") ++ "])."),
        D.text "-opaque t() :: lawspec_beam_mailbox:mailbox()."] ++
       [D.text "-opaque sender() :: lawspec_beam_mailbox:sender()." | wired] ++
       concat [[D.text "-spec " <> E.call n (map (erlType . snd) ps) <> D.text " -> " <> erlType result <> D.text ".",
         E.function n [D.text ("_Ls" ++ E.pascal p) | (p,_) <- ps] body] | Function n ps result body <- functions])
    elixir = X.moduleDoc exModule False
      ([D.text "@opaque t :: :lawspec_beam_mailbox.mailbox()"] ++
       [D.text "@opaque sender :: :lawspec_beam_mailbox.sender()" | wired] ++
       concat [[D.text "@spec " <> X.call n (map (exType . snd) ps) <> D.text " :: " <> exType result,
         X.function n (map (D.text . fst) ps) [X.remote (":" ++ name) n (map (D.text . fst) ps)]]
         | Function n ps result _ <- functions])
    gleam = G.fileDoc False
      (nub (concat [concatMap (imports . snd) ps ++ imports result | Function _ ps result _ <- functions]) ++
       [D.text ("pub type " ++ typeName)] ++ [D.text ("pub type " ++ typeName ++ "Sender") | wired] ++
       [G.external name n n [D.text (p ++ ": ") <> gleamType ty | (p,ty) <- ps] (gleamType result)
         | Function n ps result _ <- functions])
