-- Typed channel ends for implementation code: each protocol's steps as
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
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..))
import LawSpec.WebTypes (webDataTypeDocWith, webTypeReferenceDoc, requiresSchema)
import LawSpec.MachineSpec (describe)

-- One end's steps, already flipped for the second end.
data End = End { endLabel :: String, endSteps :: [(Bool, C.Type)], endClasses :: [String] }

-- The session library for the given target, for every unit's protocols.
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
        _ -> D.render (D.Pretty 80) <$> webDataTypeDocWith declarations [] ty
  -- A protocol can also run between nodes (listen and dial) when every
  -- step's type has a wire descriptor; a step sending another protocol's
  -- end carries the address of a relay, so that protocol must run between
  -- nodes too.
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
          "new ls.EndPart(() => " ++ startName ++ ", () => " ++ q ++ "._wire())"
        _ -> if requiresSchema declarations ty then either (const "null") (D.render (D.Pretty 1000)) (webTypeReferenceDoc ty) else "null"
  protocols <- forM sessions $ \(unit, session) -> protocol ts native (fmap (map (\(s, d, t) -> (s, d, reference t))) (lookup (C.sessionName session) wires)) unit session
  let body = concat protocols
      usesSchema = any (any (\(_, _, t) -> requiresSchema declarations t) . snd) wires
      helpers = if null wires then [] else
        [ ""
        , "// Values crossing the network are logical; ends use native ones."
        , "const _TYPES = ls.valuesFrom(" ++ show (unwords (map snd (reverse types) ++ ["(unit)"])) ++ ")[0];"
        , "const _SCHEMA" ++ (if ts then ": any" else "") ++ " = " ++ (if usesSchema then "data.makeSchema()" else "null") ++ ";"
        , "const _d = (text" ++ (if ts then ": string" else "") ++ ")" ++ (if ts then ": any" else "") ++ " => ls.readDescriptor(text)[0];" ]
      dataImport = [importLine "data" "lawspec_data" | "data." `isInfixOf` body || usesSchema] ++
        [importLine "schema" "lawspec_schema" | "schema." `isInfixOf` body]
      header =
        [ "// Generated by LawSpec; do not edit. Typed channel ends for the protocols"
        , "// of the spec, for implementation code. For each protocol P, P.open() gives"
        , "// a fresh channel's two ends: P.First follows the protocol's steps, P.Second"
        , "// does the reverse. Each class is an end before one step: send(value) returns"
        , "// the end for the next step, and receive() resolves to [value, next end]."
        , "// Each end is used once; using it again throws. spawn, par and the channel"
        , "// itself are in lawspec_runtime."
        , importLine "ls" "lawspec_runtime" ] ++ dataImport ++ helpers
  pure [Artifact ("src/lawspec_sessions." ++ (if ts then "ts" else "mjs")) (unlines header ++ body) "generated" "source"]
  where
    ts = target == "typescript"
    importLine name file = "import * as " ++ name ++ " from './" ++ file ++ (if ts then ".js" else ".mjs") ++ "';"
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

-- A session's two ends.
ends :: C.Session -> (End, End)
ends session = (end "first" steps, end "second" [(not sends, ty) | (sends, ty) <- steps])
  where
    steps = C.sessionSteps session
    end label ss = End label ss (classNames ss)

-- The class of an end before its first step.
startClass :: End -> String
startClass e = case endClasses e of
  c : _ -> c
  [] -> "Done"

-- Verb + type, numbered by step when a name repeats; then Done.
classNames :: [(Bool, C.Type)] -> [String]
classNames steps = zipWith number [1 :: Int ..] bases ++ ["Done"]
  where
    bases = [(if sends then "Send" else "Receive") ++ typeName ty | (sends, ty) <- steps]
    number k base
      | length (filter (== base) bases) > 1 = base ++ "Step" ++ show k
      | otherwise = base

-- A type's name in a class name: its constructors' last segments, joined.
typeName :: C.Type -> String
typeName ty = case ty of
  C.Constructor name arguments -> identifierPart (lastSegment name) ++ concat [typeName a | C.TypeArgument a <- arguments]
  C.TypeVariable _ -> "Value"
  C.Arrow a b -> typeName a ++ "To" ++ typeName b
  where
    identifierPart s = case filter (\c -> isAlphaNum c && (isAsciiLower c || isAsciiUpper c || isDigit c)) s of
      c : cs -> toUpper c : cs
      [] -> "Value"

-- A type as the spec writes it, for comments.
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

-- A protocol's namespace (TypeScript) or frozen object (JavaScript).
protocol :: Bool -> (C.Type -> Either String String) -> Maybe [(Bool, String, String)] -> String -> C.Session -> Either String String
protocol ts native wire unit session = do
  let (first, second) = ends session
      summary = intercalate ", " (map stepText (C.sessionSteps session))
  firstClasses <- endCode first
  secondClasses <- endCode second
  let startOf e = endLabelCap e ++ "." ++ startClass e
      doc =
        [ "", "/**"
        , " * Protocol " ++ name ++ " of unit " ++ unit ++ (if null summary then " (no steps)." else ": " ++ summary ++ ".")
        , " * " ++ name ++ ".First follows these steps; " ++ name ++ ".Second does the reverse."
        , " */" ]
  pure $ unlines $ if ts
    then doc ++ ["export namespace " ++ name ++ " {"] ++
      namespace first firstClasses ++ [""] ++ namespace second secondClasses ++
      [ ""
      , "  /** A fresh channel's two ends, [first, second], each before its first step. */"
      , "  export function open(): [" ++ startOf first ++ ", " ++ startOf second ++ "] {"
      , "    return ls.openSession(" ++ startOf first ++ ", " ++ startOf second ++ ") as [" ++ startOf first ++ ", " ++ startOf second ++ "];"
      , "  }" ] ++ concat
      [ [ ""
        , "  /** Each step's wire descriptor and conversion, from the first end. */"
        , "  export function _wire(): [any[], any[]] {"
        , "    return [" ++ steps False ws ++ ", " ++ refs ws ++ "];"
        , "  }"
        , ""
        , "  /**"
        , "   * The first end of a channel named name on node, which another node dials at"
        , "   * <node address>/name. An end sent over it to another node is relayed by this node."
        , "   */"
        , "  export function listen(node: ls.Node, name: string): " ++ startOf first ++ " {"
        , "    const [steps, parts] = _wire();"
        , "    return new " ++ startOf first ++ "(new ls.NativeChannel(node.listen(name, steps, _TYPES), parts, _SCHEMA), 0);"
        , "  }"
        , ""
        , "  /** The second end of the channel listening at address on another node. */"
        , "  export function dial(node: ls.Node, address: string): " ++ startOf second ++ " {"
        , "    const [steps, parts] = _wire();"
        , "    return new " ++ startOf second ++ "(new ls.NativeChannel(node.dial(address, steps.map(([s, d]: any) => [!s, d]), _TYPES), parts, _SCHEMA), 1);"
        , "  }" ]
      | Just ws <- [wire] ] ++
      [ "}" ]
    else "" : drop 1 (lines (concat (firstClasses ++ secondClasses))) ++ doc ++
      [ "export const " ++ name ++ " = Object.freeze({"
      , "  /**"
      , "   * A fresh channel's two ends, [first, second], each before its first step."
      , "   * @returns {[" ++ name ++ "." ++ startOf first ++ ", " ++ name ++ "." ++ startOf second ++ "]}"
      , "   */"
      , "  open: () => ls.openSession(" ++ jsClass first (startClass first) ++ ", " ++ jsClass second (startClass second) ++ "),"
      ] ++ concat
      [ [ "  /** Each step's wire descriptor and conversion, from the first end. */"
        , "  _wire: () => [" ++ steps False ws ++ ", " ++ refs ws ++ "],"
        , "  /**"
        , "   * The first end of a channel named name on node, which another node dials at"
        , "   * <node address>/name. An end sent over it to another node is relayed by this node."
        , "   */"
        , "  listen: (node, name) => {"
        , "    const [steps, parts] = " ++ name ++ "._wire();"
        , "    return new " ++ jsClass first (startClass first) ++ "(new ls.NativeChannel(node.listen(name, steps, _TYPES), parts, _SCHEMA), 0);"
        , "  },"
        , "  /** The second end of the channel listening at address on another node. */"
        , "  dial: (node, address) => {"
        , "    const [steps, parts] = " ++ name ++ "._wire();"
        , "    return new " ++ jsClass second (startClass second) ++ "(new ls.NativeChannel(node.dial(address, steps.map(([s, d]) => [!s, d]), _TYPES), parts, _SCHEMA), 1);"
        , "  }," ]
      | Just ws <- [wire] ] ++
      [ "  /** The first end: " ++ summaryOf first ++ ". */"
      , "  First: Object.freeze({" ++ intercalate ", " [c ++ ": " ++ jsClass first c | c <- endClasses first] ++ "}),"
      , "  /** The second end: " ++ summaryOf second ++ ". */"
      , "  Second: Object.freeze({" ++ intercalate ", " [c ++ ": " ++ jsClass second c | c <- endClasses second] ++ "}),"
      , "});" ]
  where
    steps flipped ws = "[" ++ intercalate ", " ["[" ++ (if s /= flipped then "true" else "false") ++ ", _d(" ++ show d ++ ")]" | (s, d, _) <- ws] ++ "]"
    refs ws = "[" ++ intercalate ", " [r | (_, _, r) <- ws] ++ "]"
    name = C.sessionName session
    endLabelCap e = case endLabel e of c : cs -> toUpper c : cs; [] -> []
    summaryOf e = if null (endSteps e) then "no steps" else intercalate ", " (map stepText (endSteps e))
    jsClass e c = name ++ endLabelCap e ++ c
    -- How code names an end's class: within the TypeScript namespace, the
    -- bare class; in JavaScript comments, P.First.Class.
    classRef e c = if ts then c else name ++ "." ++ endLabelCap e ++ "." ++ c
    namespace e classes =
      [ "  /** " ++ name ++ "'s " ++ endLabel e ++ " end: " ++ summaryOf e ++ ". */"
      , "  export namespace " ++ endLabelCap e ++ " {" ] ++
      map (\l -> if null l then l else "    " ++ l) (drop 1 (lines (concat classes))) ++ ["  }"]
    endCode e = forM (zip3 [1 :: Int ..] (endClasses e) (map Just (endSteps e) ++ [Nothing])) $ \(k, cls, step) ->
      let next = endClasses e !! k
          declared = if ts then "export class " ++ cls else "class " ++ jsClass e cls
          nextRef = classRef e next
          nextValue = if ts then next else jsClass e next
          position = name ++ "'s " ++ endLabel e ++ " end"
      in case step of
        Nothing -> pure $ unlines
          [ "", "/** " ++ position ++ " after its last step: there is nothing left to do. */"
          , declared ++ " extends ls.SessionEnd {}" ]
        Just (True, ty) -> do
          value <- native ty
          pure $ unlines $
            [ "", "/** " ++ position ++ " before step " ++ show k ++ ": sends " ++ specType ty ++ ". */"
            , declared ++ " extends ls.SessionEnd {"
            , "  /**"
            , "   * Sends " ++ (if delegation ty then specType ty ++ "'s first end and returns" else specType ty ++ " and returns") ++ " this end before its next step."
            ] ++ ["   * The end sent must be unused; it moves to the receiver." | delegation ty] ++
            (if ts then [] else ["   * @param {" ++ value ++ "} value", "   * @returns {" ++ nextRef ++ "}"]) ++
            [ "   */"
            , if ts then "  send(value: " ++ value ++ "): " ++ next ++ " {" else "  send(value) {"
            , "    return ls.sendOn(this, value, " ++ nextValue ++ ");"
            , "  }"
            , "}" ]
        Just (False, ty) -> do
          value <- native ty
          let pair = "[" ++ value ++ ", " ++ nextRef ++ "]"
          pure $ unlines $
            [ "", "/** " ++ position ++ " before step " ++ show k ++ ": receives " ++ specType ty ++ ". */"
            , declared ++ " extends ls.SessionEnd {"
            , "  /**"
            , "   * Waits for the " ++ specType ty ++ " the other end sends; resolves to it and this end"
            , "   * before its next step."
            ] ++ (if ts then [] else ["   * @returns {Promise<" ++ pair ++ ">}"]) ++
            [ "   */"
            , if ts then "  receive(): Promise<" ++ pair ++ "> {" else "  receive() {"
            , "    return ls.receiveOn(this, " ++ nextValue ++ ")" ++ (if ts then " as Promise<" ++ pair ++ ">" else "") ++ ";"
            , "  }"
            , ""
            , "  /**"
            , "   * Takes the " ++ specType ty ++ " the other end has already sent, without waiting (for"
            , "   * synchronous code in one process); throws if it has not been sent yet."
            ] ++ (if ts then [] else ["   * @returns {" ++ pair ++ "}"]) ++
            [ "   */"
            , if ts then "  receiveNow(): " ++ pair ++ " {" else "  receiveNow() {"
            , "    return ls.receiveNowOn(this, " ++ nextValue ++ ")" ++ (if ts then " as " ++ pair else "") ++ ";"
            , "  }"
            , "}" ]
    delegation ty = case ty of
      C.Constructor n [] -> "::session::" `isInfixOf` n
      _ -> False
