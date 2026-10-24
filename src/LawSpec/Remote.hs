-- | Remote evaluation. Every checked definition whose types have wire
-- descriptors can be evaluated by another node, by its content hash: the
-- semantic hash of the definition and everything it reaches (see
-- LawSpec.Dependencies), so two nodes agree on a hash exactly when they hold
-- definitions that behave the same, whatever they are called. Each target generates a small module, lawspec_remote,
-- mapping each hash to its definition and descriptors, with serve(node) and
-- evaluate(node, address, name, args...).
module LawSpec.Remote (Remote(..), remoteManifest, remoteArtifacts) where

import Control.Monad (foldM)
import Data.List (intercalate, stripPrefix)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import qualified LawSpec.Dependencies as D
import LawSpec.MachineSpec (describe)
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.Code.Haskell as H
import LawSpec.HaskellData (sortedImports)
import LawSpec.Code.Literal (literalFor)
import LawSpec.SourceLink (goGeneratedMarker)
import LawSpec.JvmNames (jvmString)
import LawSpec.PythonTypes (pythonLayout)
import qualified LawSpec.PythonExpr as E
import qualified LawSpec.Code.ECMAScript as J
import qualified LawSpec.RustLayout as RL

-- | A definition other nodes may evaluate, named by its content hash, so a node
-- never runs a different version of the code it was asked for.
-- ref:DEC-distribution-canonical-wire
data Remote = Remote
  { remoteId :: C.Id
  -- The definition's qualified name, such as example.actors::modelDeposit.
  , remoteName :: String
  , remoteDigest :: String
  , remoteArguments :: [String]
  , remoteResult :: String
  }

-- | A content hash names its algorithm and encoding, so nodes never compare
-- hashes of two kinds: blake3-semantic-1: then the definition's semantic
-- hash in hexadecimal. ref:DEC-remote-semantic-identity
contentName :: String -> String
contentName h = "blake3-semantic-1:" ++ h

-- | The data types the descriptors use, and each definition that can be
-- evaluated remotely. Orchestrations (which call adapters) and definitions
-- over types without descriptors are left out.
remoteManifest :: Plan -> ([String], [Remote])
remoteManifest plan = (map snd (reverse table), reverse remotes)
  where
    units = map plannedUnit (plannedUnits plan)
    graph = D.dependencyGraph (planDataDeclarations plan) units
    bits = planMachineBits plan
    datas = planDataDeclarations plan
    (table, remotes) = foldl add ([], []) [d | u <- units, d <- C.unitDefinitions u, not (C.definitionOrchestrates d)]
    add (t, acc) d =
      let declaration = C.definitionDeclaration d
          identity = C.declarationId declaration
          (args, result) = C.functionType (C.declarationType declaration)
          described = do
            (ds, t') <- foldM (\(xs, tt) ty -> (\(x, tt') -> (xs ++ [x], tt')) <$> describe bits datas tt ty) ([], t) args
            (r, t'') <- describe bits datas t' result
            pure (ds, r, t'')
      in case (described, D.contentHash graph (D.DeclarationNode identity)) of
        (Right (ds, r, t'), Just h) -> (t', Remote identity (C.idText identity) (contentName h) ds r : acc)
        _ -> (t, acc)

-- | The target's lawspec_remote module, given how the target calls each
-- checked definition on logical values.
remoteArtifacts :: String -> [(C.Id, String)] -> Plan -> [Artifact]
remoteArtifacts target calls plan = case (target, remotes) of
  (_, []) -> []
  ("python", _) -> [Artifact "src/lawspec_remote.py" python "generated" "source"]
  ("go", _) ->
    [ Artifact (intercalate "/" parts ++ "/lawspec_remote.go") (go (last parts) mine) "generated" "source"
    | u <- map plannedUnit (plannedUnits plan)
    , let unit = C.idText (C.unitId u)
          parts = splitDots unit
          mine = [r | r <- remotes, takeWhile (/= ':') (remoteName r) == unit, Just _ <- [callable r]]
    , not (null mine) ]
  (t, _) | t `elem` ["java", "kotlin", "scala"] -> [Artifact "src/main/java/lawspec/remote/LawSpecRemote.java" java "generated" "source"]
  ("rust", _) -> [Artifact "src/lawspec_remote.rs" rust "generated" "source"]
  ("javascript", _) -> [Artifact "src/lawspec_remote.mjs" (web False) "generated" "source"]
  ("typescript", _) -> [Artifact "src/lawspec_remote.ts" (web True) "generated" "source"]
  ("haskell", _) -> [Artifact "src/LawSpecRemote.hs" haskell "generated" "source"]
  _ -> []
  where
    splitDots s = case break (== '.') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitDots rest
    go package mine = unlines $
      [ "// " ++ goGeneratedMarker
      , ""
      , "package " ++ package
      , ""
      , "import \"time\""
      , ""
      , "// Checked definitions that other nodes can evaluate, by content hash."
      , "// LawSpecServeDefinitions lets other nodes evaluate them on a node;"
      , "// LawSpecEvaluateRemote evaluates one on the node at an address. Values"
      , "// are logical values, as the runtime's checks use them."
      , ""
      , "var lawSpecRemoteTypes = LawSpecTypes(" ++ goQuote (unwords forms) ++ ")"
      , ""
      , "// lawSpecRemoteDefinitions maps a qualified name to its content hash and"
      , "// how to evaluate it."
      , "var lawSpecRemoteDefinitions = map[string]struct {"
      , "\tdigest     string"
      , "\tdefinition LawSpecRemoteDefinition"
      , "}{" ] ++
      concat
      [ [ "\t" ++ goQuote (remoteName r) ++ ": {"
        , "\t\t" ++ goQuote (remoteDigest r) ++ ","
        , "\t\tLawSpecRemoteDefinition{"
        , "\t\t\tfunc(a []LawSpecValue) LawSpecValue {"
        , "\t\t\t\treturn " ++ call ++ "(map[string]*LawSpecSymbol{}" ++ concat [", a[" ++ show i ++ "]" | i <- [0 .. length (remoteArguments r) - 1]] ++ ")"
        , "\t\t\t},"
        , "\t\t\t[]any{" ++ intercalate ", " ["LawSpecDescriptor(" ++ goQuote d ++ ")" | d <- remoteArguments r] ++ "},"
        , "\t\t\tLawSpecDescriptor(" ++ goQuote (remoteResult r) ++ "),"
        , "\t\t},"
        , "\t}," ]
      | r <- mine, Just call <- [callable r] ] ++
      [ "}"
      , ""
      , "// LawSpecServeDefinitions lets other nodes evaluate these definitions on"
      , "// node, and returns the address they are served at."
      , "func LawSpecServeDefinitions(node *LawSpecNode) (string, error) {"
      , "\ttable := map[string]LawSpecRemoteDefinition{}"
      , "\tfor _, entry := range lawSpecRemoteDefinitions {"
      , "\t\ttable[entry.digest] = entry.definition"
      , "\t}"
      , "\treturn node.ServeDefinitions(table, lawSpecRemoteTypes, \"definitions\")"
      , "}"
      , ""
      , "// LawSpecDefinitionDigest is the content hash of the definition with this"
      , "// qualified name."
      , "func LawSpecDefinitionDigest(name string) string {"
      , "\treturn lawSpecRemoteDefinitions[name].digest"
      , "}"
      , ""
      , "// LawSpecEvaluateRemote evaluates the named definition on the node at"
      , "// address, by its content hash; it fails with LawSpecUnreachable when that"
      , "// node does not answer within the timeout."
      , "func LawSpecEvaluateRemote(node *LawSpecNode, address, name string, timeout time.Duration, args ...LawSpecValue) (LawSpecValue, error) {"
      , "\tentry := lawSpecRemoteDefinitions[name]"
      , "\td := entry.definition"
      , "\treturn node.Evaluate(address, entry.digest, args, d.Arguments, d.Result, lawSpecRemoteTypes, timeout, \"definitions\")"
      , "}" ]
    (forms, remotes) = remoteManifest plan
    callable r = lookup (remoteId r) calls
    quote s = show s
    goQuote = literalFor "go"
    -- Laid out as ruff lays it out (DEC-readable-output-default).
    python = Doc.render pythonLayout (Doc.joinWith Doc.hardline (map Doc.text
      [ "# Generated by LawSpec. Do not edit."
      , "\"\"\"Checked definitions that other nodes can evaluate, by content hash."
      , ""
      , "serve(node) lets other nodes evaluate them on this node; evaluate(node,"
      , "address, name, *args) evaluates one on the node at address. Values are"
      , "logical values, as the runtime's checks use them."
      , "\"\"\""
      , ""
      , "import lawspec_runtime as ls"
      , "import lawspec_definition_bodies as _definitions"
      , "" ] ++
      (if null forms then [Doc.text "TYPES = ls.Values({})"]
       else [ Doc.text ("FORMS = " ++ pyQuote (unwords forms))
            , Doc.text "TYPES = ls.Values({str(form[1]): form for form in ls.read_descriptor(FORMS)})" ]) ++
      map Doc.text
      [ ""
      , ""
      , "def _d(text):"
      , "    return ls.read_descriptor(text)[0]"
      , "" ] ++
      [ Doc.text ""
      , Doc.text "# name: (content hash, function, argument descriptors, result descriptor)"
      , Doc.text "DEFINITIONS = " <> Doc.delimitTrailing 4 "{" "}"
          [ Doc.text (pyQuote (remoteName r) ++ ": ") <> Doc.delimitTrailing 4 "(" ")"
              [ Doc.text (pyQuote (remoteDigest r))
              , E.lambdaExpression [Doc.text "*args"] (E.call call [Doc.text "{}", Doc.text "*args"])
              , Doc.delimitTrailing 4 "[" "]" [descriptor d | d <- remoteArguments r]
              , descriptor (remoteResult r) ]
          | r <- remotes, Just call <- [callable r] ] ] ++
      map Doc.text
      [ ""
      , ""
      , "def serve(node):"
      , "    \"\"\"Lets other nodes evaluate these definitions on node.\"\"\""
      , "    table = {h: (f, a, r) for h, f, a, r in DEFINITIONS.values()}"
      , "    return node.serve_definitions(table, TYPES)"
      , ""
      , ""
      , "def digest(name):"
      , "    \"\"\"The content hash of the definition with this qualified name.\"\"\""
      , "    return DEFINITIONS[name][0]"
      , ""
      , ""
      , "def evaluate(node, address, name, *args, timeout=5.0):"
      , "    \"\"\"Evaluates the named definition on the node at address, by its"
      , "    content hash; raises Unreachable when that node does not answer.\"\"\""
      , "    h, _, a, r = DEFINITIONS[name]"
      , "    return node.evaluate(address, h, list(args), a, r, TYPES, timeout=timeout)" ])) ++ "\n"
    pyQuote = literalFor "python"
    descriptor d = E.call "_d" [E.quoted d]
    jdescriptor d = jcall "LawSpecRuntime.descriptor" [Doc.text (literalFor "java" d)]
    jcall n args = Doc.group (Doc.text (n ++ "(") <> Doc.nest 4 (Doc.softbreak <> Doc.commaSep args) <> Doc.text ")")
    -- Java: Allman braces with Google's other rules (LawSpec's Java profile).
    jquote = literalFor "java"
    jdoc = lines . Doc.render (Doc.Pretty 100)
    java = unlines $
      [ "// Generated by LawSpec. Do not edit."
      , ""
      , "package lawspec.remote;"
      , ""
      , "import java.util.List;"
      , "import java.util.Map;"
      , "import lawspec.runtime.LawSpecDefinitionBodies;"
      , "import lawspec.runtime.LawSpecRuntime;"
      , ""
      , "/**"
      , " * Checked definitions that other nodes can evaluate, by content hash. serve(node) lets other"
      , " * nodes evaluate them on this node; evaluate(node, address, name, args) evaluates one on the node"
      , " * at address. Values are logical values, as the runtime's checks use them."
      , " */"
      , "public final class LawSpecRemote"
      , "{"
      , "  private LawSpecRemote() {}"
      , "" ] ++
      jdoc (Doc.text "  " <> Doc.nest 2 (Doc.group (Doc.text "public static final LawSpecRuntime.Values TYPES =" <>
        Doc.nest 4 (Doc.softline <> Doc.text "LawSpecRuntime.valuesOf(" <> Doc.nest 4 (Doc.softbreak <> jvmString "java" (unwords forms)) <> Doc.text ");")))) ++
      [ ""
      , "  private record Entry(String digest, LawSpecRuntime.Definition definition) {}"
      , ""
      , "  private static final Map<String, Entry> DEFINITIONS = new java.util.HashMap<>();"
      , ""
      , "  static"
      , "  {" ] ++
      concat
      [ map ("    " ++) (lines (Doc.render (Doc.Pretty 96) (jcall "DEFINITIONS.put" [Doc.text (jquote (remoteName r)),
          jcall "new Entry" [Doc.text (jquote (remoteDigest r)), jcall "new LawSpecRuntime.Definition"
            [ Doc.group (Doc.text "args ->" <> Doc.nest 4 (Doc.softline <> jcall (unqualifiedCall call)
                (Doc.text "new java.util.HashMap<String, Object>()" : [Doc.text ("args.get(" ++ show i ++ ")") | i <- [0 .. length (remoteArguments r) - 1]])))
            , jcall "List.of" (map jdescriptor (remoteArguments r))
            , jdescriptor (remoteResult r) ]]] <> Doc.text ";")))
      | r <- remotes, Just call <- [callable r] ] ++
      [ "  }"
      , ""
      , "  /** Lets other nodes evaluate these definitions on node. */"
      , "  public static String serve(LawSpecRuntime.Node node)"
      , "  {"
      , "    var table = new java.util.HashMap<String, LawSpecRuntime.Definition>();"
      , "    for (var entry : DEFINITIONS.values())"
      , "    {"
      , "      table.put(entry.digest(), entry.definition());"
      , "    }"
      , "    return node.serveDefinitions(table, TYPES);"
      , "  }"
      , ""
      , "  /** The content hash of the definition with this qualified name. */"
      , "  public static String digest(String name)"
      , "  {"
      , "    return DEFINITIONS.get(name).digest();"
      , "  }"
      , ""
      , "  /**"
      , "   * Evaluates the named definition on the node at address, by its content hash; throws Unreachable"
      , "   * when that node does not answer within 5 seconds."
      , "   */"
      , "  public static LawSpecRuntime.Value evaluate("
      , "      LawSpecRuntime.Node node, String address, String name, LawSpecRuntime.Value... args)"
      , "  {"
      , "    return evaluate(node, address, name, List.of(args), 5.0);"
      , "  }"
      , ""
      , "  public static LawSpecRuntime.Value evaluate("
      , "      LawSpecRuntime.Node node,"
      , "      String address,"
      , "      String name,"
      , "      List<LawSpecRuntime.Value> args,"
      , "      double timeout)"
      , "  {"
      , "    var entry = DEFINITIONS.get(name);"
      , "    if (entry == null)"
      , "    {"
      , "      throw new IllegalArgumentException(\"no remote definition \" + name);"
      , "    }"
      , "    var definition = entry.definition();"
      , "    return node.evaluate("
      , "        address, entry.digest(), args, definition.arguments(), definition.result(), TYPES, timeout);"
      , "  }"
      , "}" ]
    -- Rust: the table and three functions; serving and evaluating are
    -- the runtime's (ls::serve_remote, ls::evaluate_remote).
    rust = Doc.render (Doc.styleLayout (Doc.styleFor "rust")) (Doc.joinWith Doc.hardline (map Doc.text
      [ "// Generated by LawSpec. Do not edit."
      , "//! Checked definitions that other nodes can evaluate, by content hash."
      , "//!"
      , "//! serve(node) lets other nodes evaluate them on this node; evaluate(node,"
      , "//! address, name, args) evaluates one on the node at address. Values are"
      , "//! logical values (ls::Value), as the runtime's checks use them."
      , "use crate::lawspec_runtime as ls;"
      , "" ]) <> Doc.hardline <>
      Doc.joinWith (Doc.hardline <> Doc.hardline)
      [ RL.function "fn wire_types" [] "ls::Values" (RL.expr (RL.call "ls::values_table" [RL.Laid (Doc.text (literalFor "rust" (unwords forms)))]))
      , Doc.text "/// (qualified name, content hash, function, argument descriptors, result descriptor)" <> Doc.hardline <>
        RL.stmt (RL.Let' "pub const DEFINITIONS: &ls::RemoteDefinitions" (RL.prefix "&" (RL.Macro "" "[" "]"
          [ RL.Macro "" "(" ")" [ RL.atom (literalFor "rust" (remoteName r)), RL.atom (literalFor "rust" (remoteDigest r))
                               , RL.cast (RL.atom call) "ls::ModelCallback"
                               , RL.prefix "&" (RL.Macro "" "[" "]" (map (RL.atom . literalFor "rust") (remoteArguments r)))
                               , RL.atom (literalFor "rust" (remoteResult r)) ]
          | r <- remotes, Just call <- [callable r] ])))
      , Doc.text "/// Lets other nodes evaluate these definitions on node." <> Doc.hardline <>
        RL.function "pub fn serve" ["node: &ls::net::Node"] "ls::Result<String>"
          (RL.expr (RL.call "ls::serve_remote" [RL.atom "node", RL.atom "DEFINITIONS", RL.call "wire_types" []]))
      , Doc.text "/// The content hash of the definition with this qualified name." <> Doc.hardline <>
        RL.function "pub fn digest" ["name: &str"] "Option<&'static str>"
          (RL.expr (RL.call "ls::remote_digest" [RL.atom "DEFINITIONS", RL.atom "name"]))
      , Doc.text "/// Evaluates the named definition on the node at address, by its content" <> Doc.hardline <>
        Doc.text "/// hash; fails as unreachable when that node does not answer in time." <> Doc.hardline <>
        RL.function "pub fn evaluate" ["node: &ls::net::Node", "address: &str", "name: &str", "args: &[ls::Value]"] "ls::Result<ls::Value>"
          (RL.expr (RL.call "ls::evaluate_remote" (map RL.atom ["node", "address", "DEFINITIONS", "&wire_types()", "name", "args"]))) ] <> Doc.hardline)
    web ts = J.printModule (if ts then J.TypeScript else J.JavaScript)
      [ J.Comment [ "// Generated by LawSpec. Do not edit."
                  , "// Checked definitions that other nodes can evaluate, by content hash."
                  , "// serve(node) lets other nodes evaluate them on this node;"
                  , "// evaluate(node, address, name, ...args) evaluates one on the node at"
                  , "// address. Values are logical values, as the runtime's checks use them"
                  , "// (integers are bigints)." ]
      , J.ImportDecl False (J.ImportNamespace "ls") ("./lawspec_runtime." ++ ext)
      , J.ImportDecl False (J.ImportNamespace "_definitions") ("./lawspec_definition_bodies." ++ ext)
      , J.Blank
      , J.constDecl "TYPES" (J.index (J.call "ls.valuesFrom" [J.Str (unwords (forms ++ ["(unit)"]))]) (J.num 0))
      , J.constDecl "d" (J.Arrow False [typedP "text" (J.TKeyword "string")] (typed' (J.TKeyword "any"))
          (J.ExpressionBody (J.index (J.call "ls.readDescriptor" [J.Ident "text"]) (J.num 0))))
      , J.Blank
      , J.Comment ["/** name: [content hash, function, argument descriptors, result descriptor] */"]
      , J.VarDecl "export const" (J.PIdent "DEFINITIONS") (typed' (J.TRef "Record" [J.TKeyword "string",
          J.TTuple [J.TKeyword "string", J.TFunction [restAny] (J.TKeyword "any"), J.TArray (J.TKeyword "any"), J.TKeyword "any"]]))
          (Just (J.Object [ J.Prop (J.KString (remoteName r)) (J.Array [J.Str (remoteDigest r), wrap call,
                              J.Array [J.call "d" [J.Str x] | x <- remoteArguments r], J.call "d" [J.Str (remoteResult r)]])
                          | r <- remotes, Just call <- [callable r] ]))
      , J.Blank
      , J.Comment ["/** Lets other nodes evaluate these definitions on node. */"]
      , J.FunctionDecl True False "serve" [] [typedP "node" (J.TRef "ls.Node" [])] (typed' (J.TKeyword "string"))
          [ J.VarDecl "const" (J.PIdent "table") (typed' (J.TRef "Record" [J.TKeyword "string", J.TTuple [J.TKeyword "any", J.TArray (J.TKeyword "any"), J.TKeyword "any"]])) (Just (J.Object []))
          , J.ForOf "const" (J.PArray (map J.PIdent ["h", "f", "a", "r"])) (J.call "Object.values" [J.Ident "DEFINITIONS"])
              [J.ExprStmt (J.Assign "=" (J.index (J.Ident "table") (J.Ident "h")) (J.Array (map J.Ident ["f", "a", "r"])))]
          , J.ret (J.method (J.Ident "node") "serveDefinitions" [J.Ident "table", J.Ident "TYPES"]) ]
      , J.Blank
      , J.Comment ["/** The content hash of the definition with this qualified name. */"]
      , J.FunctionDecl True False "digest" [] [typedP "name" (J.TKeyword "string")] (typed' (J.TKeyword "string"))
          [J.ret (J.index (J.index (J.Ident "DEFINITIONS") (J.Ident "name")) (J.num 0))]
      , J.Blank
      , J.Comment ["/**", " * Evaluates the named definition on the node at address, by its content", " * hash; rejects with ls.Unreachable when that node does not answer.", " */"]
      , J.FunctionDecl True False "evaluate" []
          [typedP "node" (J.TRef "ls.Node" []), typedP "address" (J.TKeyword "string"), typedP "name" (J.TKeyword "string"), restAny]
          (typed' (J.TRef "Promise" [J.TKeyword "any"]))
          [ J.VarDecl "const" (J.PArray (map J.PIdent ["h", "", "a", "r"])) Nothing (Just (J.index (J.Ident "DEFINITIONS") (J.Ident "name")))
          , J.ret (J.method (J.Ident "node") "evaluate" (map J.Ident ["address", "h", "args", "a", "r", "TYPES"])) ] ]
      where
        ext = if ts then "js" else "mjs"
        typed' t = if ts then Just t else Nothing
        typedP n t = (J.param n) { J.paramType = typed' t }
        restAny = (typedP "args" (J.TArray (J.TKeyword "any"))) { J.paramRest = True }
        wrap call = let (asynchronous, f) = stripAwait call
                        callee = if ts then J.As (J.Ident f) (J.TKeyword "any") else J.Ident f
                    in J.Arrow asynchronous [restAny] Nothing (J.ExpressionBody (J.Call callee [] [J.new' "Map" [], J.Spread (J.Ident "args")] False))
        stripAwait c = if take 6 c == "await " then (True, drop 6 c) else (False, c)
    haskell = haskellRemote forms [(r, call) | r <- remotes, Just call <- [callable r]]

-- | The Haskell module LawSpecRemote: definitions, serve, digest and
-- evaluate, over logical values (LS.Scalar).
haskellRemote :: [String] -> [(Remote, String)] -> String
haskellRemote forms entries = Doc.render (H.layout False) $ Doc.joinWith Doc.hardline (map Doc.text
  [ "-- Generated by LawSpec. Do not edit."
  , "-- Checked definitions that other nodes can evaluate, by content hash:"
  , "-- serve lets other nodes evaluate them on a node; evaluate evaluates one,"
  , "-- by its qualified name, on the node at an address. Values are logical"
  , "-- values (LS.Scalar), as the runtime's checks use them."
  , "module LawSpecRemote (definitions, types, serve, digest, evaluate) where"
  , "" ] ++
  map Doc.text (sortedImports ([("Prelude", Just "P", Nothing), ("Control.Exception", Just "E", Nothing), ("LawSpecRuntime", Just "LS", Nothing)] ++
    [("LawSpecDefinitionBodies", Just "Definitions", Nothing) | not (null entries)]))) <> Doc.hardline <>
  mconcat [Doc.hardline <> d <> Doc.hardline | d <-
    [ Doc.joinWith Doc.hardline
        [ H.comment ["The data types the descriptors use."]
        , H.signature "types" ["LS.DataTable"]
        , H.declaration "types" (H.var ("[(LS.descriptorName n, f) | f@(LS.DescList (LS.DescAtom \"data\" : n : _)) <- LS.readDescriptor " ++
            H.renderString (unwords forms) ++ "]")) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["A descriptor, from its text."]
        , H.signature "d" ["P.String", "LS.Descriptor"]
        , H.declaration "d text" (H.Case (H.call "LS.readDescriptor" [H.var "text"])
            [("form : _", H.var "form"), ("[]", H.call "P.error" [H.string "empty descriptor"])]) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["A definition's function, run with a symbol context of its own."]
        , H.signature "call" ["(LS.SymbolContext -> [LS.Scalar] -> P.Either P.String LS.Scalar)", "[LS.Scalar]", "P.IO LS.Scalar"]
        , H.declaration "call f args" (H.Do
            [ H.Bind "symbols" (H.var "LS.newSymbolContext")
            , H.Run (H.call "P.either" [H.operator "P.." [H.var "E.throwIO", H.var "E.ErrorCall"], H.var "P.pure", H.call "f" [H.var "symbols", H.var "args"]]) ]) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["Each definition by qualified name: its content hash, function,", "argument descriptors and result descriptor."]
        , H.signature "definitions" ["[(P.String, (P.String, [LS.Scalar] -> P.IO LS.Scalar, [LS.Descriptor], LS.Descriptor))]"]
        , H.declaration "definitions" (H.List
            [ H.Tuple [H.string (remoteName r), H.Tuple [H.string (remoteDigest r), H.call "call" [H.call "LS.uncurried" [H.var f]],
                H.List [H.call "d" [H.string x] | x <- remoteArguments r], H.call "d" [H.string (remoteResult r)]]]
            | (r, f) <- entries ]) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["Lets other nodes evaluate these definitions on a node."]
        , H.signature "serve" ["LS.Node", "P.IO P.String"]
        , H.declaration "serve node" (H.call "LS.serveDefinitions" [H.var "node", H.var "types", H.var "[(h, f, a, r) | (_, (h, f, a, r)) <- definitions]"]) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["The content hash of the definition with this qualified name."]
        , H.signature "digest" ["P.String", "P.Maybe P.String"]
        , H.declaration "digest name" (H.operator "P.<$>" [H.lambda ["(h, _, _, _)"] (H.var "h"), H.call "P.lookup" [H.var "name", H.var "definitions"]]) ]
    , Doc.joinWith Doc.hardline
        [ H.comment ["Evaluates the named definition on the node at an address, by its", "content hash, waiting up to 5 seconds (LS.Unreachable after that)."]
        , H.signature "evaluate" ["LS.Node", "P.String", "P.String", "[LS.Scalar]", "P.IO LS.Scalar"]
        , H.declaration "evaluate node address name args" (H.Case (H.call "P.lookup" [H.var "name", H.var "definitions"])
            [ ("P.Just (h, _, a, r)", H.call "LS.evaluateRemote" (map H.var ["node", "address", "h", "args", "a", "r", "types"] ++ [H.integer 5]))
            , ("P.Nothing", H.call "E.throwIO" [H.call "E.ErrorCall" [H.operator "P.++" [H.string "no definition ", H.var "name"]]]) ]) ] ] ]

-- | A checked definition's call, LawSpecDefinitionBodies imported.
unqualifiedCall :: String -> String
unqualifiedCall call = maybe call ("LawSpecDefinitionBodies." ++) (stripPrefix "lawspec.runtime.LawSpecDefinitionBodies." call)
