-- | Typed channel ends for implementation code: each protocol's steps as
-- types of this target (see LawSpec.Sessions).
--
-- A protocol P becomes P.First and P.Second, one class per end and step:
-- the class of an end before step k has only that step's method, send or
-- receive, which returns the end's class before step k+1 (Done after the
-- last step). A class is named for its step, Verb + type (ReceiveInt32);
-- when a name repeats on an end, every occurrence ends in its step number
-- (ReceiveInt32Step1, ReceiveInt32Step2). P.open() gives a fresh channel's
-- two start ends. TypeScript types each method, so steps out of order do not
-- compile; in both languages an end used twice throws. The channel, spawn
-- and par are in lawspec_runtime.
module LawSpec.Sessions.Web (emit) where

import Control.Monad (foldM, forM, when)
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, toUpper)
import Data.List (intercalate, isInfixOf, nub, stripPrefix)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.WebTypes (webDataTypeOfWith, webTypeReference, requiresSchema)
import qualified LawSpec.Code.ECMAScript as E
import LawSpec.MachineSpec (describe)

-- | One end's steps, already flipped for the second end.
data End = End { endLabel :: String, endSteps :: [(Bool, C.Type)], endClasses :: [String] }

-- | The session library for the given target, for every unit's protocols.
emit :: String -> Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit target _ bits declarations units = do
  let sessions = [(C.idText (C.unitId u), s) | u <- units, s <- C.unitSessions u]
      names = map (C.sessionName . snd) sessions
  when (length names /= length (nub names))
    (Left "two protocols share a name; the web session library needs distinct protocol names")
  mapM_ (checkName . C.sessionName . snd) sessions
  -- A delegated end is its protocol's first start class.
  let start session = "First." ++ startClass (fst (ends session))
      delegated name = case [s | (_, s) <- sessions, sessionTail (C.idText (C.sessionId s)) == Just name || C.sessionName s == name] of
        s : _ -> Just (C.sessionName s ++ "." ++ start s)
        [] -> Nothing
      native ty = case ty of
        C.Constructor name [] | Just other <- sessionTail name ->
          maybe (Left ("unknown protocol " ++ other)) Right (delegated other)
        _ -> E.printType <$> webDataTypeOfWith declarations [] ty
  -- A protocol can also run between nodes (listen and dial) when every
  -- step's type has a wire descriptor; a step sending another protocol's
  -- end carries the address the receiver takes the end over from (or a
  -- relay's, for a local end), so that protocol must run between nodes too.
  let wired (table, acc) s = case foldM step (table, []) (C.sessionSteps s) of
        Right (table', ds) -> (table', acc ++ [(C.sessionName s, ds)])
        _ -> (table, acc)
      step (t, ds) (sends, ty)
        | delegatedStep ty = Right (t, ds ++ [(sends, "(end)", ty)])
        | otherwise = (\(d, t') -> (t', ds ++ [(sends, d, ty)])) <$> describe bits declarations t ty
      (types, described) = foldl wired ([], []) (map snd sessions)
      protocolOf ty = case ty of
        C.Constructor n [] | Just other <- sessionTail n ->
          case [s | (_, s) <- sessions, sessionTail (C.idText (C.sessionId s)) == Just other || C.sessionName s == other] of
            s : _ -> Just (C.sessionName s)
            [] -> Just other
        _ -> Nothing
      settle ws = let kept = [w | w@(_, ss) <- ws, all (\(_, _, t) -> maybe True (`elem` map fst ws) (protocolOf t)) ss]
                  in if length kept == length ws then ws else settle kept
      wires = settle described
      reference ty = case protocolOf ty of
        Just q | Just startName <- delegated q ->
          E.new' "ls.EndPart" [E.arrow [] (E.Ident startName), E.arrow [] (E.call (q ++ "._wire") [])]
        _ -> if requiresSchema declarations ty then either (const E.Null) id (webTypeReference ty) else E.Null
  protocols <- forM sessions $ \(unit, session) -> protocol ts native (fmap (map (\(s', d, t) -> (s', d, reference t))) (lookup (C.sessionName session) wires)) unit session
  let body = concat protocols
      bodyText = E.printModule dialect body
      usesSchema = any (any (\(_, _, t) -> requiresSchema declarations t) . snd) wires
      typed t = if ts then Just t else Nothing
      helpers = if null wires then [] else
        [ E.Blank
        , E.Comment ["// Values crossing the network are logical; ends use native ones."]
        , E.constDecl "_TYPES" (E.index (E.call "ls.valuesFrom" [E.Str (unwords (map snd (reverse types) ++ ["(unit)"]))]) (E.num 0))
        , E.VarDecl "const" (E.PIdent "_SCHEMA") (typed (E.TKeyword "any")) (Just (if usesSchema then E.call "data.makeSchema" [] else E.Null))
        , E.constDecl "_d" (E.Arrow False [(E.param "text") { E.paramType = typed (E.TKeyword "string") }] (typed (E.TKeyword "any"))
            (E.ExpressionBody (E.index (E.call "ls.readDescriptor" [E.Ident "text"]) (E.num 0)))) ]
      dataImport = [importLine "data" "lawspec_data" | "data." `isInfixOf` bodyText || usesSchema] ++
        [importLine "schema" "lawspec_schema" | "schema." `isInfixOf` bodyText]
      header =
        [ E.Comment
          [ "// Generated by LawSpec. Do not edit."
          , "// Typed channel ends for the protocols of the spec, for implementation"
          , "// code. For each protocol P, P.open() gives a fresh channel's two ends:"
          , "// P.First follows the protocol's steps, P.Second does the reverse. Each"
          , "// class is an end before one step: send(value) returns the end for the next"
          , "// step, and receive() resolves to [value, next end]. Each end is used once;"
          , "// using it again throws. spawn, par and the channel itself are in"
          , "// lawspec_runtime." ]
        , importLine "ls" "lawspec_runtime" ] ++ dataImport ++ helpers
  pure [Artifact ("src/lawspec_sessions." ++ (if ts then "ts" else "mjs")) (E.printModule dialect (header ++ body)) "generated" "source"]
  where
    ts = target == "typescript"
    dialect = if ts then E.TypeScript else E.JavaScript
    importLine name file = E.ImportDecl False (E.ImportNamespace name) ("./" ++ file ++ (if ts then ".js" else ".mjs"))
    delegatedStep ty = case ty of
      C.Constructor n [] -> "::session::" `isInfixOf` n
      _ -> False
    sessionTail name = case breakOn "::session::" name of
      Just (_, rest) -> Just rest
      Nothing -> Nothing
    checkName name
      | name `elem` ["First", "Second", "Done", "ls", "data"] =
          Left ("protocol " ++ name ++ " clashes with a name of the web session library")
      | otherwise = pure ()

breakOn :: String -> String -> Maybe (String, String)
breakOn needle = go ""
  where
    go before rest = case stripPrefix needle rest of
      Just after -> Just (reverse before, after)
      Nothing -> case rest of
        c : cs -> go (c : before) cs
        [] -> Nothing

-- | A session's two ends.
ends :: C.Session -> (End, End)
ends session = (end "first" steps, end "second" [(not sends, ty) | (sends, ty) <- steps])
  where
    steps = C.sessionSteps session
    end label ss = End label ss (classNames ss)

-- | The class of an end before its first step.
startClass :: End -> String
startClass e = case endClasses e of
  c : _ -> c
  [] -> "Done"

-- | Verb + type, numbered by step when a name repeats; then Done.
classNames :: [(Bool, C.Type)] -> [String]
classNames steps = zipWith number [1 :: Int ..] bases ++ ["Done"]
  where
    bases = [(if sends then "Send" else "Receive") ++ typeName ty | (sends, ty) <- steps]
    number k base
      | length (filter (== base) bases) > 1 = base ++ "Step" ++ show k
      | otherwise = base

-- | A type's name in a class name: its constructors' last segments, joined.
typeName :: C.Type -> String
typeName ty = case ty of
  C.Constructor name arguments -> identifierPart (lastSegment name) ++ concat [typeName a | C.TypeArgument a <- arguments]
  C.TypeVariable _ -> "Value"
  C.Arrow a b -> typeName a ++ "To" ++ typeName b
  where
    identifierPart s = case filter (\c -> isAlphaNum c && (isAsciiLower c || isAsciiUpper c || isDigit c)) s of
      c : cs -> toUpper c : cs
      [] -> "Value"

-- | A type as the spec writes it, for comments.
specType :: C.Type -> String
specType ty = case ty of
  C.Constructor name [] -> lastSegment name
  C.Constructor name arguments -> lastSegment name ++ concat [" " ++ atom a | C.TypeArgument a <- arguments]
  C.TypeVariable variable -> C.idText variable
  C.Arrow a b -> atom a ++ " -> " ++ specType b
  where
    atom a@(C.Constructor _ (_ : _)) = "(" ++ specType a ++ ")"
    atom a@(C.Arrow _ _) = "(" ++ specType a ++ ")"
    atom a = specType a

lastSegment :: String -> String
lastSegment name = case breakOn "::" name of
  Just (_, rest) -> lastSegment rest
  Nothing -> name

stepText :: (Bool, C.Type) -> String
stepText (sends, ty) = (if sends then "send " else "receive ") ++ specType ty

-- | A protocol's namespace (TypeScript) or frozen object (JavaScript).
protocol :: Bool -> (C.Type -> Either String String) -> Maybe [(Bool, String, E.Expr)] -> String -> C.Session -> Either String [E.Stmt]
protocol ts native wire unit session = do
  let (first, second) = ends session
      summary = intercalate ", " (map stepText (C.sessionSteps session))
  firstClasses <- endCode first
  secondClasses <- endCode second
  let startOf e = endLabelCap e ++ "." ++ startClass e
      doc = E.Comment
        [ "/**"
        , " * Protocol " ++ name ++ " of unit " ++ unit ++ (if null summary then " (no steps)." else ": " ++ summary ++ ".")
        , " * " ++ name ++ ".First follows these steps; " ++ name ++ ".Second does the reverse."
        , " */" ]
      anyT = E.TKeyword "any"
      startPair = E.TTuple [E.TRef (startOf first) [], E.TRef (startOf second) []]
      nodeParams last' = [(E.param "node") { E.paramType = typed (E.TRef "ls.Node" []) }, (E.param last') { E.paramType = typed (E.TKeyword "string") }]
      typed t = if ts then Just t else Nothing
      listenBody wireCall cls = [ E.VarDecl "const" (E.PArray [E.PIdent "steps", E.PIdent "parts"]) Nothing (Just wireCall)
                                , E.ret (E.New (E.Ident cls) [] [E.new' "ls.NativeChannel" [E.method (E.Ident "node") "listen" [E.Ident "name", E.Ident "steps", E.Ident "_TYPES"], E.Ident "parts", E.Ident "_SCHEMA"], E.num 0]) ]
      dialBody wireCall cls = [ E.VarDecl "const" (E.PArray [E.PIdent "steps", E.PIdent "parts"]) Nothing (Just wireCall)
                              , E.ret (E.New (E.Ident cls) [] [E.new' "ls.NativeChannel" [E.method (E.Ident "node") "dial" [E.Ident "address",
                                  E.method (E.Ident "steps") "map" [E.Arrow False [E.Param (E.PArray [E.PIdent "s", E.PIdent "d"]) (typed anyT) Nothing False] Nothing
                                    (E.ExpressionBody (E.Array [E.notE (E.Ident "s"), E.Ident "d"]))], E.Ident "_TYPES"], E.Ident "parts", E.Ident "_SCHEMA"], E.num 1]) ]
      wireValue ws = E.Array [steps False ws, E.Array [r | (_, _, r) <- ws]]
      listenDoc = [ "/**"
                  , " * The first end of a channel named name on node, which another node dials"
                  , " * at <node address>/name. An end sent over it to another node moves there"
                  , " * (a local end stays and is relayed by this node)."
                  , " */" ]
  pure $ if ts
    then [ E.Blank, doc, E.Namespace True name (
      namespace first firstClasses ++ [E.Blank] ++ namespace second secondClasses ++
      [ E.Blank
      , E.Comment ["/** A fresh channel's two ends, [first, second], each before its first step. */"]
      , E.FunctionDecl True False "open" [] [] (Just startPair)
          [E.ret (E.As (E.call "ls.openSession" [E.Ident (startOf first), E.Ident (startOf second)]) startPair)] ] ++ concat
      [ [ E.Blank
        , E.Comment ["/** Each step's wire descriptor and conversion, from the first end. */"]
        , E.FunctionDecl True False "_wire" [] [] (Just (E.TTuple [E.TArray anyT, E.TArray anyT])) [E.ret (wireValue ws)]
        , E.Blank
        , E.Comment listenDoc
        , E.FunctionDecl True False "listen" [] (nodeParams "name") (Just (E.TRef (startOf first) [])) (listenBody (E.call "_wire" []) (startOf first))
        , E.Blank
        , E.Comment ["/** The second end of the channel listening at address on another node. */"]
        , E.FunctionDecl True False "dial" [] (nodeParams "address") (Just (E.TRef (startOf second) [])) (dialBody (E.call "_wire" []) (startOf second)) ]
      | Just ws <- [wire] ]) ]
    else concat [E.Blank : c | c <- firstClasses ++ secondClasses] ++
      [ E.Blank, doc
      , E.VarDecl "export const" (E.PIdent name) Nothing (Just (E.call "Object.freeze" [E.Object (
          [ E.CommentedProp [ "/**", " * A fresh channel's two ends, [first, second], each before its first step."
                            , " * @returns {[" ++ name ++ "." ++ startOf first ++ ", " ++ name ++ "." ++ startOf second ++ "]}", " */"]
              (E.Prop (E.KName "open") (E.arrow [] (E.call "ls.openSession" [E.Ident (jsClass first (startClass first)), E.Ident (jsClass second (startClass second))]))) ] ++ concat
          [ [ E.CommentedProp ["/** Each step's wire descriptor and conversion, from the first end. */"]
                (E.Prop (E.KName "_wire") (E.arrow [] (wireValue ws)))
            , E.CommentedProp listenDoc (E.Prop (E.KName "listen") (E.arrowBlock (nodeParams "name") (listenBody (E.call (name ++ "._wire") []) (jsClass first (startClass first)))))
            , E.CommentedProp ["/** The second end of the channel listening at address on another node. */"]
                (E.Prop (E.KName "dial") (E.arrowBlock (nodeParams "address") (dialBody (E.call (name ++ "._wire") []) (jsClass second (startClass second))))) ]
          | Just ws <- [wire] ] ++
          [ E.CommentedProp ["/** The first end: " ++ summaryOf first ++ ". */"]
              (E.Prop (E.KName "First") (E.call "Object.freeze" [E.Object [E.Prop (E.KName c) (E.Ident (jsClass first c)) | c <- endClasses first]]))
          , E.CommentedProp ["/** The second end: " ++ summaryOf second ++ ". */"]
              (E.Prop (E.KName "Second") (E.call "Object.freeze" [E.Object [E.Prop (E.KName c) (E.Ident (jsClass second c)) | c <- endClasses second]])) ])])) ]
  where
    steps flipped ws = E.Array [E.Array [E.BoolLit (s' /= flipped), E.call "_d" [E.Str d]] | (s', d, _) <- ws]
    name = C.sessionName session
    endLabelCap e = case endLabel e of c : cs -> toUpper c : cs; [] -> []
    summaryOf e = if null (endSteps e) then "no steps" else intercalate ", " (map stepText (endSteps e))
    jsClass e c = name ++ endLabelCap e ++ c
    -- How code names an end's class: within the TypeScript namespace, the
    -- bare class; in JavaScript comments, P.First.Class.
    classRef e c = if ts then c else name ++ "." ++ endLabelCap e ++ "." ++ c
    namespace e classes =
      [ E.Comment ["/** " ++ name ++ "'s " ++ endLabel e ++ " end: " ++ summaryOf e ++ ". */"]
      , E.Namespace True (endLabelCap e) (concat [E.Blank : c | c <- classes]) ]
    endCode e = forM (zip3 [1 :: Int ..] (endClasses e) (map Just (endSteps e) ++ [Nothing])) $ \(k, cls, step) ->
      let next = endClasses e !! k
          className' = if ts then cls else jsClass e cls
          declared members = (if ts then E.ClassDecl True else E.ClassDecl False) className' [] (Just (E.Ident "ls" `E.member` "SessionEnd")) [] members
          nextRef = classRef e next
          nextValue = E.Ident (if ts then next else jsClass e next)
          position = name ++ "'s " ++ endLabel e ++ " end"
      in case step of
        Nothing -> pure
          [ E.Comment ["/** " ++ position ++ " after its last step: there is nothing left to do. */"]
          , declared [] ]
        Just (True, ty) -> do
          value <- native ty
          pure
            [ E.Comment ["/** " ++ position ++ " before step " ++ show k ++ ": sends " ++ specType ty ++ ". */"]
            , declared
              [ E.MemberComment (["/**", " * Sends " ++ (if delegation ty then specType ty ++ "'s first end and returns" else specType ty ++ " and returns") ++ " this end before its next step."] ++
                  [" * The end sent must be unused; it moves to the receiver." | delegation ty] ++
                  (if ts then [] else [" * @param {" ++ value ++ "} value", " * @returns {" ++ nextRef ++ "}"]) ++ [" */"])
              , E.Method False False "method" "send" [(E.param "value") { E.paramType = if ts then Just (E.TRaw value) else Nothing }]
                  (if ts then Just (E.TRef next []) else Nothing) [E.ret (E.call "ls.sendOn" [E.This, E.Ident "value", nextValue])] ] ]
        Just (False, ty) -> do
          value <- native ty
          let pair = "[" ++ value ++ ", " ++ nextRef ++ "]"
              pairT = E.TRaw pair
          pure
            [ E.Comment ["/** " ++ position ++ " before step " ++ show k ++ ": receives " ++ specType ty ++ ". */"]
            , declared
              [ E.MemberComment (["/**", " * Waits for the " ++ specType ty ++ " the other end sends; resolves to it and this end", " * before its next step."] ++
                  (if ts then [] else [" * @returns {Promise<" ++ pair ++ ">}"]) ++ [" */"])
              , E.Method False False "method" "receive" [] (if ts then Just (E.TRef "Promise" [pairT]) else Nothing)
                  [E.ret ((if ts then (`E.As` E.TRef "Promise" [pairT]) else id) (E.call "ls.receiveOn" [E.This, nextValue]))]
              , E.MemberBlank
              , E.MemberComment (["/**", " * Takes the " ++ specType ty ++ " the other end has already sent, without waiting (for",
                  " * synchronous code in one process); throws if it has not been sent yet."] ++
                  (if ts then [] else [" * @returns {" ++ pair ++ "}"]) ++ [" */"])
              , E.Method False False "method" "receiveNow" [] (if ts then Just pairT else Nothing)
                  [E.ret ((if ts then (`E.As` pairT) else id) (E.call "ls.receiveNowOn" [E.This, nextValue]))] ] ]
    delegation ty = case ty of
      C.Constructor n [] -> "::session::" `isInfixOf` n
      _ -> False
