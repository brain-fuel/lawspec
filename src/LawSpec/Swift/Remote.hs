-- | Remote evaluation on Swift (see LawSpec.Remote): LawSpec.RemoteDefinitions
-- serves the program's checked definitions on a node, by content hash, and
-- evaluates one on another node, each through its checked entry.
-- ref:DEC-distribution-canonical-wire
module LawSpec.Swift.Remote (emitRemote) where

import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.Remote (Remote(..), remoteManifest)
import LawSpec.Testing (Plan, plannedUnit, plannedUnits)
import qualified LawSpec.Code.Doc as D
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Entries (Entry(..), entries)

emitRemote :: Plan -> [Artifact]
emitRemote plan
  | null callable = []
  | otherwise = [Artifact "src/LawSpec/LawSpecRemoteDefinitions.swift" (D.render swiftLayout (D.joinWith D.hardline doc) ++ "\n") "generated" "source"]
  where
    units = map plannedUnit (plannedUnits plan)
    (forms, remotes) = remoteManifest plan
    prefix = concatMap (++ " ") forms
    callable = [(r, entryOwner e ++ "." ++ entryName e) | r <- remotes, Just e <- [lookup (remoteId r) (entries units)]]
    doc = map D.text
      [ "// " ++ generatedHeader Nothing
      , ""
      , "import LawSpecRuntime"
      , ""
      , "extension LawSpec {"
      , "  /// Checked definitions other nodes can evaluate, by content hash: serve lets"
      , "  /// them run on a node, and evaluate runs one on the node at an address."
      , "  /// Values are portable values, as the runtime's checks use them."
      , "  public enum RemoteDefinitions {"
      , "    /// Each definition's qualified name, content hash and wire forms."
      , "    static let signatures: [(String, String, [String], String)] = [" ] ++
      map D.text (lines' signatures) ++
      [ D.text "    ]"
      , D.text ""
      , D.text "    /// How each definition runs: its checked entry."
      , D.text "    static let invokers: [String: @Sendable ([Value]) throws -> Value] = [" ] ++
      [ D.nest 6 (D.text "      " <> D.text (stringLiteral (remoteName r) ++ ": ") <> renderExpr (Lambda [("arguments", tValues)] tValue
          (Call e ([Raw "LawSpec.Program.schema", Raw "SymbolContext()"] ++ [Pure "Runtime.item" [IntLit (toInteger i), Var "arguments"] | i <- [0 .. length (remoteArguments r) - 1]])))
          <> D.text ",")
      | (r, e) <- callable ] ++
      map D.text
      [ "    ]"
      , ""
      , "    /// The content hash of the definition with this qualified name."
      , "    public static func digest(_ name: String) throws -> String {"
      , "      guard let (_, hash, _, _) = signatures.first(where: { $0.0 == name }) else {"
      , "        throw Fail.with(\"Remote\", \"unknown definition \" + name)"
      , "      }"
      , "      return hash"
      , "    }"
      , ""
      , "    /// Lets other nodes evaluate these definitions on node; the address they are served at."
      , "    @discardableResult"
      , "    public static func serve(_ node: Node) throws -> String {"
      , "      try Remote.serve("
      , "        node, \"definitions\", \"eval\","
      , "        signatures.map { name, hash, arguments, result in"
      , "          (hash, RemoteEntry(arguments, result, invokers[name]))"
      , "        })"
      , "    }"
      , ""
      , "    /// Evaluates the named definition on the node at address, by its content"
      , "    /// hash; fails when that node does not answer within timeout."
      , "    public static func evaluate("
      , "      _ node: Node, _ address: String, _ name: String, _ arguments: [Value],"
      , "      timeout: Duration = .seconds(5)"
      , "    ) throws -> Value {"
      , "      guard let (_, hash, types, result) = signatures.first(where: { $0.0 == name }) else {"
      , "        throw Fail.with(\"Remote\", \"unknown definition \" + name)"
      , "      }"
      , "      let client = try Remote.connect("
      , "        node, address + \"/definitions\", \"eval\", [(hash, RemoteEntry(types, result, nil))],"
      , "        Timeouts.milliseconds(timeout))"
      , "      return try Remote.call(client, hash, arguments)"
      , "    }"
      , "  }"
      , "}" ]
    -- Each signature: its name, content hash and wire forms, one a line
    -- when they do not fit on one.
    signatures = D.render swiftLayout (D.nest 6 (mconcat [ D.hardline <> renderExpr (TupleOf [Str (remoteName r), Str (remoteDigest r),
        ListOf (Ty "") (map (Str . (prefix ++)) (remoteArguments r)), Str (prefix ++ remoteResult r)]) <> D.text ","
      | (r, _) <- callable ]))
    lines' text = drop 1 (lines text)
