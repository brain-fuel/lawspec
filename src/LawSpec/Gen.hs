-- Public API code is assembled from declarations and legal layout boundaries.
-- No formatter or source rewriting is needed by the native or WASM compiler.
module LawSpec.Gen (generate, generateInto, apiSources) where

import LawSpec.Code.Doc
import LawSpec.Scalar
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

methods :: [(String, String)]
methods = [("check", "CheckRequest"), ("expand", "CheckRequest"), ("planGeneration", "GenerationRequest")]

generate :: IO ()
generate = generateInto "npm" (Pretty 80)

generateInto :: FilePath -> Layout -> IO ()
generateInto directory layout = do
  createDirectoryIfMissing True directory
  mapM_ (\(name, content) -> writeFile (directory </> name) content) (apiSources layout)

apiSources :: Layout -> [(FilePath, String)]
apiSources layout = [("api.mjs", output api), ("index.d.ts", output declarations)]
  where
    output body = render layout (text "// Generated from LawSpec.Gen. Do not edit." <> hardline <> body <> hardline)

-- Blocks always expand in readable mode; optional breaks collapse in compact
-- mode. Tokens that need a separator keep one explicitly in either layout.
braces :: Doc -> Doc
braces body = text "{" <> nest 2 (softbreak <> body) <> softbreak <> text "}"

field :: (String, Doc) -> Doc
field (name, ty) = group (text (name ++ ": ") <> ty)

record :: [(String, Doc)] -> Doc
record fields = group (braces (joinWith softline [field entry <> text ";" | entry <- fields]))

interface :: String -> [(String, Doc)] -> Doc
interface name fields = text ("export interface " ++ name ++ " ") <>
  braces (joinWith softbreak [field entry <> text ";" | entry <- fields])

union :: [Doc] -> Doc
union = group . joinWith (text " |" <> softline)

alias :: String -> [Doc] -> Doc
alias name alternatives = group (text ("export type " ++ name ++ " =") <>
  nest 4 (softline <> union alternatives) <> text ";")

quoted :: String -> Doc
quoted name = text ("'" ++ name ++ "'")

array :: Doc -> Doc
array ty = ty <> text "[]"

fields :: [(String, String)] -> [(String, Doc)]
fields = map (\(name, ty) -> (name, text ty))

variant :: String -> [(String, String)] -> Doc
variant tag rest = record (("kind", quoted tag) : fields rest)

object :: [Doc] -> Doc
object entries = braces (joinWith (text "," <> softline) entries <> whenBroken (text ","))

api :: Doc
api = text "import {loadCore} from './launcher.mjs';" <> softbreak <> softbreak <>
  text "export async function createCompiler() " <> braces
    (text "const call = await loadCore();" <> softbreak <>
     text "return " <> object [method name | (name, _) <- methods] <> text ";")
  where
    method name = group (text (name ++ ": (input) =>") <>
      nest 4 (softline <> text "call" <>
        delimit 4 "(" ")" [group (object [text "schemaVersion: input.nativeBindings === undefined ? 3 : 4", text "...input", text "method: " <> quoted name])]))

declarations :: Doc
declarations = joinWith (softbreak <> softbreak)
  [ alias "Target" (map quoted ["java", "python", "javascript", "typescript", "go", "haskell", "kotlin", "rust"])
  , interface "Source" (fields [("path", "string"), ("content", "string")])
  , interface "Location" (fields [("file", "string"), ("line", "number"), ("column", "number")])
  , interface "Span" (fields [("start", "Location"), ("end", "Location")])
  , interface "Diagnostic" [("code", text "string"), ("message", text "string"), ("at", union [text "Location", text "null"])]
  , interface "Artifact"
      [("path", text "string"), ("content", text "string"),
       ("ownership", union (map quoted ["user", "generated"])),
       ("placement", union (map quoted ["source", "test"])),
       ("adapterReference?", text "string")]
  , alias "Type"
      [variant "constructor" [("name", "string"), ("arguments", "TypeArgument[]")],
       variant "variable" [("id", "string")],
       variant "function" [("parameter", "Type"), ("result", "Type")]]
  , alias "TypeArgument"
      [variant "type" [("type", "Type")], variant "natural" [("value", "string")],
       variant "indexVariable" [("id", "string")]]
  , alias "Origin"
      [variant "source" [("span", "Span")], variant "generated" [("declaration", "string")]]
  , alias "Evidence" [record [("kind", union (map quoted ["numeric", "structural"])), ("type", text "Type")]]
  , interface "Expr" (fields [("type", "Type"), ("origin", "Origin"), ("text", "string"), ("node", "ExprNode")])
  , alias "ExprNode"
      [ variant "constant" [("value", "ScalarValue")]
      , variant "match" [("value", "Expr"), ("cases", "MatchCase[]")]
      , variant "allElements" [("value", "Expr"), ("binder", "Binder"), ("predicate", "Expr")]
      , variant "allPayloads" [("value", "Expr"), ("predicates", "PayloadPredicate[]")]
      , variant "construct" [("constructor", "string"), ("arguments", "Expr[]")]
      , variant "local" [("id", "string")]
      , variant "call" [("declaration", "string"), ("arguments", "Expr[]")]
      , variant "binary" [("operator", "string"), ("evidence", "Evidence"), ("left", "Expr"), ("right", "Expr")]
      , record [("kind", quoted "unary"), ("operator", union (map quoted ["-", "!"])), ("argument", text "Expr")]
      , record [("kind", quoted "shortCircuit"), ("operator", union (map quoted ["&&", "||"])), ("left", text "Expr"), ("right", text "Expr")]
      , record [("kind", quoted "convert"), ("conversion", union (map quoted ["explicit", "checked"])), ("argument", text "Expr")]
      , variant "helper" [("name", "string"), ("arguments", "Expr[]")]
      ]
  , alias "Assertion"
      [variant "equal" [("evidence", "Evidence"), ("left", "Expr"), ("right", "Expr")],
       variant "implies" [("guard", "Expr"), ("body", "Assertion")],
       variant "all" [("items", "Assertion[]")]]
  , interface "Generation" (fields [("cases", "number"), ("maxAttempts", "number"), ("maxShrinks", "number"), ("exhaustiveLimit", "number")])
  , interface "Binder" (fields [("id", "string"), ("name", "string"), ("type", "Type")])
  , interface "Definition" (fields [("owner", "string"), ("id", "string"), ("arguments", "Binder[]"), ("body", "Expr")])
  , interface "Input extends Binder"
      [("predicates", text "Expr[]"), ("bounds", array (record (fields [("operator", "string"), ("value", "Expr")])))]
  , interface "Example"
      [("name", text "string"), ("bindings", text "(Binder & " <> record [("value", text "DataValue")] <> text ")[]"),
       ("expectations", text "Assertion[]")]
  , interface "Law" (fields
      [("id", "string"), ("owner", "string"), ("name", "string"), ("inputs", "Input[]"),
       ("assertion", "Assertion"), ("examples", "Example[]"), ("description", "string"),
       ("rationale", "string"), ("references", "string[]"), ("location", "Location"),
       ("trace", "string[]"), ("generation", "Generation")])
  , interface "Unit"
      [("id", text "string"), ("declarations", text "(Binder & " <> record [("origin", text "Origin")] <> text ")[]")]
  , interface "DataTypeDeclaration"
      (fields [("id", "string"), ("name", "string"), ("parameters", "string[]"), ("origin", "Origin")] ++
       [("constructors", array (record (fields [("id", "string"), ("name", "string"), ("fields", "Binder[]"), ("origin", "Origin")])))] )
  , interface "Contract" (fields
      [("id", "string"), ("name", "string"), ("arguments", "Binder[]"), ("result", "Binder"),
       ("preconditions", "Expr[]"), ("postconditions", "Expr[]")])
  , interface "Refinement"
      [("owner", text "string"), ("name", text "string"),
       ("parameters", array (record [("name", text "string"), ("kind", union (map quoted ["type", "value"])), ("type", text "string")])),
       ("requirements", array (record (fields [("capability", "string"), ("type", "string")]))),
       ("definition", text "string")]
  , alias "NativeReference" [text "string[]"]
  , interface "NativeFieldBinding" (fields [("field", "string"), ("native", "string")])
  , interface "NativeConstructorBinding"
      (fields [("constructor", "string"), ("native", "NativeReference"), ("fields?", "NativeFieldBinding[]")] ++
       [("style", union (map quoted ["record", "variant", "unit"]))])
  , interface "NativeCodecBinding" (fields [("toNative", "NativeReference"), ("fromNative", "NativeReference")])
  , interface "NativeTypeBinding" (fields [("type", "string"), ("native", "NativeReference"), ("constructors?", "NativeConstructorBinding[]"), ("codec?", "NativeCodecBinding")])
  , interface "NativeGeneratorBinding" (fields [("type", "string"), ("factory", "NativeReference"), ("stub?", "boolean")])
  , interface "NativeFunctionBinding" (fields [("declaration", "string"), ("native", "NativeReference")])
  , interface "NativeGoImport" (fields [("alias", "string"), ("path", "string")])
  , interface "NativeBindings" (fields [("types?", "NativeTypeBinding[]"), ("generators?", "NativeGeneratorBinding[]"),
      ("functions?", "NativeFunctionBinding[]"), ("rustCrate?", "string"), ("goImports?", "NativeGoImport[]")])
  , interface "PackageVersion" (fields [("name", "string"), ("version", "string")])
  , interface "Package" (fields [("name", "string"), ("version", "string"), ("dependencies?", "Record<string, string>"), ("sources", "Source[]")])
  , interface "PackageView" (fields [("name", "string"), ("version", "string"), ("dependencies", "Record<string, string>"), ("units", "string[]")])
  , interface "CheckRequest"
      [("sources", text "Source[]"), ("schemaVersion?", union [text "3", text "4"]),
       ("machineBits?", union [text "32", text "64"]), ("generation?", text "Partial<Generation>"), ("nativeBindings?", text "NativeBindings"),
       ("package?", text "PackageVersion"), ("dependencies?", text "Record<string, string>"), ("packages?", text "Package[]")]
  , interface "GenerationRequest extends CheckRequest" (fields [("target", "Target"), ("sourceDir?", "string"), ("testDir?", "string"), ("minify?", "boolean")])
  , interface "Result"
      ([("schemaVersion", union [text "3", text "4"]), ("machineBits?", union [text "32", text "64"])] ++
       fields [("generation?", "Generation"), ("units?", "Unit[]"), ("dataTypes?", "DataTypeDeclaration[]"), ("definitions?", "Definition[]"), ("laws?", "Law[]")] ++
       [("contracts?", array (record (fields [("owner", "string"), ("contract", "Contract")])))] ++
       fields [("refinements?", "Refinement[]"), ("diagnostics", "Diagnostic[]"), ("expansions?", "string[]"), ("files?", "Artifact[]")] ++
       [("packages?", text "PackageView[]"), ("project?", record (fields [("package?", "PackageVersion"), ("dependencies", "Record<string, string>")]))])
  , interface "PayloadPredicate" (fields [("binder", "Binder"), ("predicate", "Expr")])
  , interface "MatchCase" (fields [("constructor", "string"), ("binders", "Binder[]"), ("body", "Expr")])
  , alias "DataValue" [text "ScalarValue", variant "data" [("type", "Type"), ("constructor", "string"), ("fields", "DataValue[]")]]
  , alias "IntegerType" [quoted (primitiveName p) | p <- primitives, family p == IntegerFamily]
  , alias "ScalarValue"
      [ record (fields [("type", "IntegerType"), ("value", "string")])
      , scalar ["Bool"] [("value", "boolean")]
      , scalar ["Decimal"] [("coefficient", "string"), ("exponent", "string")]
      , scalar ["Rational"] [("numerator", "string"), ("denominator", "string")]
      , scalar ["Float32", "Float64"] [("bits", "string")]
      , scalar ["Complex64", "Complex128"] [("real", "ScalarValue"), ("imaginary", "ScalarValue")]
      , scalar ["Char", "CodePoint", "CodeUnit16"] [("value", "number")]
      , scalar ["Text", "CodePointText", "Utf16Text", "Bytes"] [("units", "number[]")]
      , scalar ["Symbol"] [("id", "string"), ("description", "string")]
      , scalar ["Unit", "Null", "Undefined"] []
      , record [("type", union (map quoted ["Nullable", "Optional"])), ("value", union [text "ScalarValue", text "null"])]
      ]
  , text "export interface Compiler " <> braces (joinWith softbreak
      [text (name ++ "(input: " ++ request ++ "): Promise<Result>;") | (name, request) <- methods])
  , text "export function createCompiler(): Promise<Compiler>;"
  ]
  where
    scalar names rest = record (("type", union (map quoted names)) : fields rest)
