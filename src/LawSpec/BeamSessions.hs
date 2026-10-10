-- | Each protocol step has an opaque native type. A step returns the next
-- type, and the shared runtime rejects reuse or delegation of a spent end.
-- ref:DEC-sessions-by-construction ref:DEC-idiomatic-generated-types
module LawSpec.BeamSessions (emit) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import LawSpec.Common (Artifact(..))
import LawSpec.MachineSpec (describe)
import Control.Monad (forM, unless)
import Data.List (nub)

data NativeType = NativeType D.Doc D.Doc D.Doc [D.Doc]
data Function = Function String [(String,NativeType)] NativeType [D.Doc]

emit :: String -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target layout bits declarations units = do
  names <- E.dataNames declarations
  let protocols = [(u,s) | u <- units, s <- C.unitSessions u]
      modules = [moduleName u s | (u,s) <- protocols]
      paths = [modulePath u s | (u,s) <- protocols]
      typeNames = [globalType u s side i | (u,s) <- protocols, side <- ["first","second"], i <- [0..length (C.sessionSteps s)]]
      lookupProtocol ty = case ty of
        C.Constructor key [] -> lookup (C.Id key) [(C.sessionId s,(u,s)) | (u,s) <- protocols]
        _ -> Nothing
      directWire ty = case lookupProtocol ty of
        Just _ -> True
        Nothing -> case describe bits declarations [] ty of Right _ -> True; Left _ -> False
      candidates = [C.sessionId s | (_,s) <- protocols, not (null (C.sessionSteps s)), all (directWire . snd) (C.sessionSteps s)]
      settleWire allowed = let next = [C.sessionId s | (_,s) <- protocols, C.sessionId s `elem` allowed,
                                all (\(_,ty) -> maybe True ((`elem` allowed) . C.sessionId . snd) (lookupProtocol ty)) (C.sessionSteps s)]
                           in if next == allowed then allowed else settleWire next
      wired = settleWire candidates
      part ty = case lookupProtocol ty of
        Just (_,s) -> pure (E.tuple [E.atom "session", E.binary (C.idText (C.sessionId s))])
        Nothing -> pure (E.tuple [E.atom "value",case describe bits declarations [] ty of
          Left _ -> E.atom "none"
          Right (descriptor,table) -> E.binary (unwords (map snd (reverse table) ++ [descriptor]))])
  unless (length modules == length (nub modules) && all ((<= 230) . length) modules &&
    (target == "erlang" || length paths == length (nub paths)) && length typeNames == length (nub typeNames))
    (Left "BEAM session module names collide after snake_case conversion or exceed the Erlang limit")
  catalogue <- forM protocols $ \(_,s) -> do
    steps <- forM (C.sessionSteps s) $ \(sends,ty) -> do
      p <- part ty
      pure (E.tuple [E.atom (if sends then "send" else "receive"),p])
    pure (E.binary (C.idText (C.sessionId s)),E.array steps)
  artifacts <- concat <$> forM protocols (\(unit,session) -> do
    let steps = C.sessionSteps session
        name = moduleName unit session
        variable = D.text . ("_Ls" ++) . E.pascal
        runtime = E.remote "lawspec_beam_session"
        schema = D.text "_LsSchema"
        fresh = D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [E.call "make_ref" []]
        native ty = NativeType <$> E.nativeType bits names [] ty <*> X.nativeType bits names [] ty <*>
          G.nativeType False names [] ty <*> pure (G.imports False [ty])
        result = NativeType (E.atom (if target == "gleam" then "nil" else "ok")) (X.atom "ok") (D.text "Nil") []
        generic = NativeType (E.call "term" []) (X.call "term" []) (D.text "result") []
        task = NativeType (E.remote "lawspec_beam_session_task" "task" [])
          (X.remote "LawSpec.Sessions" "task" []) (D.text "sessions.Task(result)")
          [D.text "import lawspec/sessions"]
        own side i = NativeType (E.call (stepName side i) []) (X.call (stepName side i) [])
          (D.text (E.pascal side ++ show i)) []
        start side = own side (0::Int)
        pair = tupleType [start "first",start "second"]
        typedEnd u s = if C.sessionId session == C.sessionId s then start "first" else
          NativeType (E.remote (moduleName u s) "first_0" []) (X.remote (elixirModule u s) "first_0" [])
            (D.text ("session_types." ++ globalType u s "first" 0)) [D.text "import lawspec/session_types"]
        spec = E.record [(E.atom "id",E.binary (C.idText (C.sessionId session))),
          (E.atom "protocols",E.record catalogue)]
        helpers =
          [Function "open" [] pair [runtime "open" [E.call "spec" []]],
           Function "with_pair" [("body",callbackType [start "first",start "second"] generic)] generic
             [runtime "with_pair" [E.call "spec" [],variable "body"]]] ++
          [Function ("spawn_" ++ side) [("channel_end",start side),("body",callbackType [start side] generic)] task
            [E.remote "lawspec_beam_session_task" "start" [variable "channel_end",variable "body"]] | side <- ["first","second"], not (null steps)]
    text <- native (C.Constructor "Text" [])
    let node = NativeType (E.remote "lawspec_network" "node_handle" []) (X.remote "LawSpec.Network" "node_handle" []) (D.text "network.Node") [D.text "import lawspec/network"]
        network = if C.sessionId session `notElem` wired then [] else
          [Function "listen" [("node",node),("name",text)] (start "first")
            [runtime "listen" [variable "node",variable "name",E.call "spec" []]],
           Function "dial" [("node",node),("address",text)] (start "second")
            [runtime "dial" [variable "node",variable "address",E.call "spec" []]],
           Function "address" [("channel_end",start "first")] text [runtime "address" [variable "channel_end"]]]
    methods <- concat <$> forM ["first","second"] (\side -> concat <$> forM (zip [0::Int ..] steps) (\(i,(firstSends,ty)) -> do
      let sending = if side == "first" then firstSends else not firstSends
          action = if sending then "send" else "receive"
          method = side ++ "_" ++ action ++ "_" ++ show i
          before = own side i; after = own side (i+1)
          endVar = variable "channel_end"
          valueVar = variable "value"
          nextVar = variable "next"
      (valueType,sendBody,receiveBody) <- case lookupProtocol ty of
        Just (u,s) -> pure (typedEnd u s,
          [runtime "send_end" [endVar,valueVar]], [runtime "receive_end" [endVar]])
        Nothing -> do
          valueType <- native ty
          ref <- E.typeReference ty
          pure (valueType,
            [fresh,runtime "send" [endVar,E.remote "lawspec_beam_schema" "from_native" [valueVar,ref,schema]]],
            [fresh,E.tuple [valueVar,nextVar] <> D.text " = " <> runtime "receive_value" [endVar],
             E.tuple [E.remote "lawspec_beam_schema" "to_native" [valueVar,ref,schema],nextVar]])
      pure [if sending then Function method [("channel_end",before),("value",valueType)] after sendBody
            else Function method [("channel_end",before)] (tupleType [valueType,after]) receiveBody,
        Function (side ++ "_abandon_" ++ show i) [("channel_end",before)] result
          [runtime "abandon" [endVar],E.atom (if target == "gleam" then "nil" else "ok")]]))
    let types = [stepName side i | side <- ["first","second"], i <- [0..length steps]]
        functions = helpers ++ network ++ methods
        erlang = E.moduleDoc name (("spec",0) : [(n,length ps) | Function n ps _ _ <- functions])
          ([D.text "-export_type(" <> E.array [D.text (t ++ "/0") | t <- types] <> D.text ")."] ++
           [D.text ("-opaque " ++ t ++ "() :: lawspec_beam_session:session().") | t <- types] ++
           [E.function "spec" [] [spec]] ++
           concat [[D.text "-spec " <> E.call n (map (erlType . snd) ps) <> D.text " -> " <> erlType r <> D.text ".",
             E.function n [variable p | (p,_) <- ps] body] | Function n ps r body <- functions])
        elixir = X.moduleDoc (elixirModule unit session) False
          ([D.text ("@opaque " ++ t ++ " :: :lawspec_beam_session.session()") | t <- types] ++
           concat [[D.text "@spec " <> X.call n (map (exType . snd) ps) <> D.text " :: " <> exType r,
             X.function n (map (D.text . fst) ps) [X.remote (":" ++ name) n (map (D.text . fst) ps)]]
             | Function n ps r _ <- functions])
        gleam = G.fileDoc False
          (nub (D.text "import lawspec/session_types" : concat [concatMap (imports . snd) ps ++ imports r | Function _ ps r _ <- functions]) ++
           [D.text ("pub type " ++ E.pascal side ++ show i ++ " = session_types." ++ globalType unit session side i)
             | side <- ["first","second"], i <- [0..length steps]] ++
           [G.external name n n [D.text (p ++ ": ") <> gleamType t | (p,t) <- ps] (gleamType r)
             | Function n ps r _ <- functions])
    pure (Artifact ("src/" ++ name ++ ".erl") (D.render layout erlang) "generated" "source" : case target of
      "elixir" -> [Artifact ("lib/" ++ modulePath unit session ++ ".ex") (D.render layout elixir) "generated" "source"]
      "gleam" -> [Artifact ("src/" ++ modulePath unit session ++ ".gleam") (D.render layout gleam) "generated" "source"]
      _ -> []))
  pure (artifacts ++ [Artifact "src/lawspec/session_types.gleam"
    (D.render layout (G.fileDoc False [D.text ("pub type " ++ n) | n <- typeNames])) "generated" "source"
      | target == "gleam", not (null protocols)])

moduleName :: C.Unit -> C.Session -> String
moduleName u s = "lawspec_session_" ++ E.moduleName (C.unitId u) ++ "_" ++ E.snake (C.sessionName s)
modulePath :: C.Unit -> C.Session -> String
modulePath u s = "lawspec/sessions/" ++ E.gleamPath (C.unitId u) ++ "/" ++ E.gleamName (E.snake (C.sessionName s))
elixirModule :: C.Unit -> C.Session -> String
elixirModule u s = "LawSpec.Sessions." ++ drop 7 (E.nativeModule "elixir" u) ++ "." ++ E.pascal (C.sessionName s)
stepName :: String -> Int -> String
stepName side i = side ++ "_" ++ show i
globalType :: C.Unit -> C.Session -> String -> Int -> String
globalType u s side i = E.pascal (moduleName u s) ++ E.pascal side ++ show i
erlType, exType, gleamType :: NativeType -> D.Doc
erlType (NativeType e _ _ _) = e
exType (NativeType _ x _ _) = x
gleamType (NativeType _ _ g _) = g
imports :: NativeType -> [D.Doc]
imports (NativeType _ _ _ i) = i
tupleType :: [NativeType] -> NativeType
tupleType ts = NativeType (E.tuple (map erlType ts)) (X.tuple (map exType ts)) (G.tuple (map gleamType ts)) (concatMap imports ts)
callbackType :: [NativeType] -> NativeType -> NativeType
callbackType ps r = NativeType
  (D.text "fun((" <> D.joinWith (D.text ", ") (map erlType ps) <> D.text ") -> " <> erlType r <> D.text ")")
  (D.text "(" <> D.joinWith (D.text ", ") (map exType ps) <> D.text " -> " <> exType r <> D.text ")")
  (D.text "fn(" <> D.joinWith (D.text ", ") (map gleamType ps) <> D.text ") -> " <> gleamType r)
  (concatMap imports (r:ps))
