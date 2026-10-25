-- | The layout engine all generated code is printed through.
module DocumentSpec (test_layoutEngineKeepsGeneratedCodeReadableAndUnchanged) where

import Test.Hspec
import Control.Monad (forM_)
import Data.List (isInfixOf)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlan, emitPlanWithFormat, emitPlanWithLayout, emitPlanWithOptions, targets)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import qualified LawSpec.KotlinLayout as Kotlin
import qualified LawSpec.ScalaLayout as Scala
import qualified LawSpec.ElixirCode as Elixir
import qualified LawSpec.Swift.Code as Swift
import qualified LawSpec.JavaExpr as Java
import LawSpec.JvmNames (jvmString)
import LawSpec.Core (scalarType)
import LawSpec.Scalar (primitives, primitiveName)
import qualified LawSpec.PortableGenerator as Generator
import qualified LawSpec.PortableTestHelpers as Helpers

-- | Generated code is read and diffed by people, so layout may break and indent
-- lines but must never change a token, a literal or the meaning of the code.
-- ref:DEC-readable-output-default ref:REQ-readable-layout
test_layoutEngineKeepsGeneratedCodeReadableAndUnchanged :: Spec
test_layoutEngineKeepsGeneratedCodeReadableAndUnchanged = describe "generated code layout" $ do
  it "bounds unbroken Java labels and escaped payloads without embedding displayed octal escapes" $ do
    let payload = concat (replicate 50 "unbroken\\181\\000 text") ++ replicate 120 '\x1'
        readable = D.render (D.Pretty 100) (D.text "{" <> D.nest 12
          (D.hardline <> jvmString "java" payload <> D.text ";") <> D.hardline <> D.text "}")
    maximum (map length (lines readable)) `shouldSatisfy` (<= 100)
    readable `shouldSatisfy` (not . isInfixOf "\\\\181")
    readable `shouldSatisfy` (not . isInfixOf "\\\\000")
  it "wraps qualified Java class literals at deep indentation without changing their tokens" $ do
    let names = ["lawspec.abilities.lawspec.Crypto.KeyExchange", "lawspec.abilities.lawspec.Crypto.Signature"]
    forM_ names $ \name -> do
      D.render D.Compact (Java.classLiteral name) `shouldBe` name ++ ".class"
      forM_ [48,56,64,100 - length (name ++ ".class")] $ \indent -> do
        let doc = D.text "{" <> D.nest indent (D.hardline <> Java.classLiteral name <> D.text ",") <> D.hardline <> D.text "}"
            readable = D.render (D.Pretty 100) doc
        filter ((> 100) . length) (lines readable) `shouldBe` []
        filter (`notElem` (" \n" :: String)) readable `shouldBe` "{" ++ name ++ ".class,}"
  it "uses explicit layout delimiters for compact Haskell case and let expressions" $ do
    let value = H.LetIn [("first", H.integer 1), ("second", H.integer 2)]
          (H.Case (H.var "first") [("0", H.integer 0), ("_", H.var "second")])
        doc = H.expression value
    D.render D.Compact doc `shouldBe` "let { first = 1; second = 2 } in case first of { 0 -> 0; _ -> second }"
    D.render (D.Pretty 80) doc `shouldSatisfy` (not . isInfixOf "of {")
  it "leaves blank lines empty while preserving following indentation" $
    D.render (D.Pretty 80) (D.block 2 (D.text "a" <> D.hardline <> D.hardline <> D.text "b"))
      `shouldBe` "{\n  a\n\n  b\n}"
  it "wraps argument groups at legal breaks" $
    D.render (D.Pretty 8) (D.delimit 2 "(" ")" [D.text "alpha", D.text "beta"])
      `shouldBe` "(\n  alpha,\n  beta\n)"
  it "includes suffixes in group fitting" $
    D.render (D.Pretty 8) (D.group (D.text "abc" <> D.softline <> D.text "def") <> D.text "xyz")
      `shouldBe` "abc\ndefxyz"
  it "keeps mandatory indentation in compact mode" $
    D.render D.Compact (D.text "if True:" <> D.nest 2 (D.hardline <> D.text "pass"))
      `shouldBe` "if True:\n  pass"
  it "does not alter literal payloads" $
    D.render D.Compact (D.text "\"a  b\\n\\t\"\t") `shouldBe` "\"a  b\\n\\t\"\t"
  it "preserves required token separators" $
    D.render D.Compact (D.text "return" <> D.softline <> D.text "value") `shouldBe` "return value"
  it "does not expand empty delimiters" $
    D.render (D.Pretty 1) (D.delimit 4 "(" ")" []) `shouldBe` "()"
  it "flattens optional breaks outside groups in compact mode" $
    D.render D.Compact (D.text "a" <> D.softbreak <> D.text "b") `shouldBe` "ab"
  it "limits nested documents independently of the page width" $ do
    let doc = D.text "prefix " <> D.firstLineWidth 8
          (D.delimitTrailing 2 "f(" ")" [D.text "alpha", D.text "beta"]) <> D.text "; suffix"
    D.render (D.Pretty 80) doc `shouldBe` "prefix f(\n  alpha,\n  beta,\n); suffix"
    D.render D.Compact doc `shouldBe` "prefix f(alpha, beta); suffix"
  it "includes local width limits when fitting enclosing groups" $ do
    let doc = D.group (D.text "x" <> D.softline <>
          D.firstLineWidth 4 (D.delimitTrailing 2 "[" "]" [D.text "a", D.text "b"]))
    D.render (D.Pretty 80) doc `shouldBe` "x\n[\n  a,\n  b,\n]"
  it "releases a first-line limit after wrapping" $ do
    let doc = D.firstLineWidth 4 (D.delimitTrailing 2 "(" ")"
          [D.delimitTrailing 2 "f(" ")" [D.text "abcdef", D.text "ghijkl"]])
    D.render (D.Pretty 80) doc `shouldBe` "(\n  f(abcdef, ghijkl),\n)"
  it "wraps qualified-call arguments before moving a member name" $ do
    let first = D.group (D.text "LongName.f(" <> D.nest 2 (D.softbreak <> D.text "x") <> D.text ")")
        second = D.text "LongName" <> D.nest 2 (D.hardline <> D.text ".f(x)")
        doc = D.prefixChoice "LongName.f(" first second
    D.render (D.Pretty 12) doc `shouldBe` "LongName.f(\n  x)"
    D.render (D.Pretty 10) doc `shouldBe` "LongName\n  .f(x)"
    D.render D.Compact doc `shouldBe` "LongName.f(x)"
  it "includes trailing punctuation when selecting an opaque quoted token" $ do
    let quoted = D.prefixChoice "abcdef" (D.text "abcdef")
          (D.text "abc" <> D.hardline <> D.text "def")
    D.render (D.Pretty 6) (quoted <> D.text ",") `shouldBe` "abc\ndef,"
    D.render (D.Pretty 7) (quoted <> D.text ",") `shouldBe` "abcdef,"
    D.render D.Compact (quoted <> D.text ",") `shouldBe` "abcdef,"
  it "wraps overlong comment tokens without losing characters" $ do
    D.render (D.Pretty 10) (D.lineComment 10 "// " "abcdefghijk")
      `shouldBe` "// abcdefg\n// hijk\n"
  it "packs numeric array tokens greedily without changing compact payloads" $ do
    let doc = D.text "[" <> D.nest 2 (D.hardline <>
          D.flow (map D.text ["111,", "222,", "333,", "444"])) <> D.hardline <> D.text "]"
    D.render (D.Pretty 12) doc `shouldBe` "[\n  111, 222,\n  333, 444\n]"
    D.render D.Compact doc `shouldBe` "[\n  111, 222, 333, 444\n]"
  it "keeps block arguments expanded while fitting their nested groups" $ do
    let argument = D.multiline (D.text "value -> " <> D.block 2
          (D.group (D.text "return" <> D.softline <> D.text "value;")))
        doc = D.group (D.text "call(" <> D.nest 4 (D.softbreak <> argument) <> D.text ")")
    D.render (D.Pretty 80) doc `shouldBe` "call(\n    value -> {\n      return value;\n    })"
    D.render D.Compact doc `shouldBe` "call(value -> {\n      return value;\n    })"
  it "measures UTF-8 literal tokens without changing their contents" $ do
    let doc = D.delimitTrailing 2 "[" "]" [D.utf8Text "🙂", D.text "x"]
    D.render (D.Pretty 8) doc `shouldBe` "[\n  🙂,\n  x,\n]"
    D.render D.Compact doc `shouldBe` "[🙂, x]"
  it "hangs an assignment only when its right-hand side fits the new line" $ do
    let doc = D.block 4 (D.hang 4 (D.text "let answer =")
          (D.delimitTrailing 4 "operation(" ")" [D.text "first", D.text "second"]) <> D.text ";")
    D.render (D.Pretty 40) doc `shouldBe` "{\n    let answer =\n        operation(first, second);\n}"
    D.render (D.Pretty 32) doc `shouldBe` "{\n    let answer = operation(\n        first,\n        second,\n    );\n}"
  it "preserves explicitly expanded arguments inside hanging assignments" $ do
    let value = D.text "f(" <> D.nest 2 (D.softbreak <> D.text "a," <>
          D.softline <> D.text "b,") <> D.softbreak <> D.text ")"
        doc = D.hang 4 (D.text "let value =") value
    D.render (D.Pretty 80) doc `shouldBe` "let value = f(\n  a,\n  b,\n)"
    D.render D.Compact doc `shouldBe` "let value = f(a, b,)"
  it "adds trailing commas only to wrapped lists" $ do
    let doc = D.delimitTrailing 2 "[" "]" [D.text "alpha", D.text "beta"]
    D.render (D.Pretty 8) doc `shouldBe` "[\n  alpha,\n  beta,\n]"
    D.render D.Compact doc `shouldBe` "[alpha, beta]"
  it "keeps mandatory block indentation inside compact hanging assignments" $ do
    let doc = D.block 8 (D.hang 4 (D.text "let value =")
          (D.block 4 (D.text "return value;")) <> D.text ";")
    D.render D.Compact doc `shouldBe` "{\n        let value = {\n            return value;\n        };\n}"
    D.render D.CompactTabs doc `shouldBe` "{\n\tlet value = {\n\t    return value;\n\t};\n}"
  it "renders nested blocks with target indentation" $
    D.render (D.Pretty 80) (D.block 2 (D.block 2 (D.text "x")))
      `shouldBe` "{\n  {\n    x\n  }\n}"
  it "supports Go tabs without modifying literal tabs" $
    D.render (D.PrettyTabs 80) (D.block 8 (D.text "x\ty")) `shouldBe` "{\n\tx\ty\n}"
  it "keeps Go tabs when compacting optional breaks" $
    D.render D.CompactTabs (D.block 8 (D.text "return " <>
      D.delimitTrailing 8 "f(" ")" [D.text "alpha", D.text "beta"]))
      `shouldBe` "{\n\treturn f(alpha, beta)\n}"
  it "wraps comments without dropping their required line markers" $
    D.render D.Compact (D.lineComment 12 "// " "alpha beta x")
      `shouldBe` "// alpha\n// beta x\n"
  it "breaks deeply nested Swift closure parameter types without changing their signature" $ do
    let closure = Swift.closureDoc [("symbols", Swift.Ty "SymbolContext")] Swift.ClosureThrows
          (Swift.Ty "Value") (D.text "return value")
        nested = D.nest 76 (D.hardline <> closure)
        readable = D.render (D.Pretty 100) nested
    readable `shouldSatisfy` isInfixOf "symbols:\n"
    all ((<= 100) . length) (lines readable) `shouldBe` True
    D.render D.Compact closure `shouldSatisfy` isInfixOf "(symbols: SymbolContext) throws -> Value in"
  it "measures Elixir function heads before their do keyword" $ do
    let name = replicate 83 'f'
        doc = D.nest 2 (D.hardline <> Elixir.function name [D.text "value"] [D.text "value"])
    D.render (D.Pretty 98) doc `shouldSatisfy` isInfixOf ("def " ++ name ++ "(value) do\n")
  it "keeps Elixir map, callback and union type structure through attribute layout" $ do
    let scalar = Elixir.TypeCall "integer" []
        alternatives = Elixir.TypeUnion [Elixir.TypeAtom (Elixir.atom "absent"),
          Elixir.TypeContainer "{" [Elixir.TypeAtom (Elixir.atom "present"),
            Elixir.TypeCall "LawSpec.Data.ALongReplyType.reply" [scalar]] "}"]
        callback = Elixir.TypeFunction [scalar] alternatives
        body = Elixir.TypeContainer "%__MODULE__{" [Elixir.TypeMapField (Elixir.atom "read_current_reply") callback] "}"
        doc = Elixir.typeAttribute "type" (Elixir.TypeAtom (D.text "t")) body
        rendered = D.render (D.Pretty 98) doc
    rendered `shouldSatisfy` isInfixOf ":read_current_reply => (integer() ->\n"
    rendered `shouldSatisfy` isInfixOf "| {:present, LawSpec.Data.ALongReplyType.reply(integer())})"
    D.render D.Compact (Elixir.typeDoc body) `shouldBe`
      "%__MODULE__{:read_current_reply => (integer() -> :absent | {:present, LawSpec.Data.ALongReplyType.reply(integer())})}"
  it "keeps Kotlin receiver arguments structured without interpreting literals" $ do
    let payload = Kotlin.kotlinString "a(\"b\", [c]).value"
        receiver = Kotlin.callReceiver "Codecs.recordCodec"
          [D.multiline (Kotlin.call "nested" [D.text "SCHEMA", payload]), D.text "MACHINE_BITS"]
        doc = Kotlin.chain receiver [("decode", [D.text "value"])]
        result = D.render (D.Pretty 44) doc
    result `shouldSatisfy` isInfixOf (D.render D.Compact payload)
    result `shouldSatisfy` isInfixOf "nested("
    result `shouldSatisfy` isInfixOf ".decode(value)"
    D.render D.Compact doc `shouldBe`
      "Codecs.recordCodec(nested(SCHEMA, \"a(\\\"b\\\", [c]).value\"), MACHINE_BITS).decode(value)"
  it "breaks a long Scala nullary result signature before its colon" $ do
    let resultType = D.text "scala.util.Either[_root_.lawspec.data.Refusal, scala.Long]"
        doc = Scala.equalsBody (Scala.signature (D.text "override def current") [] resultType) (D.text "result")
    D.render (D.Pretty 80) doc `shouldBe`
      "override def current()\n    : scala.util.Either[_root_.lawspec.data.Refusal, scala.Long] = result"
    D.render D.Compact doc `shouldBe`
      "override def current(): scala.util.Either[_root_.lawspec.data.Refusal, scala.Long] = result"
  it "keeps Scala receiver arguments structured through multiline chains" $ do
    let literal = Scala.scalaString "commas, brackets [)] and quotes \"stay\""
        argument = D.block 2 (D.text "val value = " <> literal <> D.hardline <> D.text "value")
        receiver = Scala.typedReceiver "Codecs" "scalar" [D.text "List[String]"] [argument]
        doc = Scala.chain receiver [("encode",[literal])]
        readable = D.render (D.Pretty 80) doc
    readable `shouldSatisfy` isInfixOf "Codecs\n  .scalar[List[String]]("
    readable `shouldSatisfy` isInfixOf (D.render D.Compact literal)
    D.render D.Compact doc `shouldSatisfy` isInfixOf ").encode("
  it "retains a receiver call before a trailing filter without reading its source" $ do
    let receiver = Scala.callReceiver "LawSpecTesting.inputs"
          [D.block 2 (D.text "value"),D.text "another"]
        doc = Scala.trailingChain receiver [] "filter" ["input"] [D.text "input.nonEmpty"]
    D.render (D.Pretty 80) doc `shouldSatisfy` isInfixOf "LawSpecTesting\n  .inputs("
  it "selects compact layouts without losing Go indentation" $ do
    D.selectLayout True (D.PrettyTabs 100) `shouldBe` D.CompactTabs
    D.selectLayout True (D.Pretty 80) `shouldBe` D.Compact
    D.selectLayout False (D.PrettyTabs 100) `shouldBe` D.PrettyTabs 100
  forM_ [False, True] $ \minify ->
    it ("preserves Rust text fixtures when relocating module paths: " ++ show minify) $ do
      let source = Source "layout" ("unit layout\n\necho :: Text -> Text\n" ++
            "law \"|identity| is definition: for all (x :: Text) => echo x = x end for all end definition\n" ++
            "example \"|path| : x = \"../src/literal\" expect echo x = \"../src/literal\" end example end" ++ " law\n\n\nend unit\n")
      case compileCore 64 defaultGeneration [source] >>= planTesting >>= 
          emitPlanWithOptions minify "rust" (Just "library") (Just "checks") of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right files -> do
          let content = concatMap artifactContent (filter ((== "checks/layout_lawspec.rs") . artifactPath) files)
          content `shouldSatisfy` isInfixOf "#[path = \"../library/lawspec_runtime.rs\"]"
          content `shouldSatisfy` isInfixOf "Value::Text(\"../src/literal\".to_owned())"
          content `shouldNotSatisfy` isInfixOf "../library/literal"
  forM_ targets $ \target -> it ("threads generated document layout independently of placement for " ++ target) $ do
    source <- readFile "examples/specs/total_functions.lawspec"
    let adapter = Source "format_adapter" ("unit format_adapter\n\n" ++
          "type Box (a :: Type) is a record{  value :: a} end type\n" ++
          "echo :: Box (List Int8) -> Box (List Int8)\n" ++ "\n\nend unit\n")
    case compileCore 64 defaultGeneration [Source "total_functions" source, adapter] >>= planTesting of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        emitPlanWithFormat False target plan `shouldBe` emitPlan target plan
        case (emitPlanWithFormat False target plan, emitPlanWithFormat True target plan) of
          (Right readable, Right compact) -> do
            let identity artifact = (artifactPath artifact, ownership artifact, artifactPlacement artifact)
                adapters = filter ((== "user") . ownership)
            emitPlanWithOptions True target Nothing Nothing plan `shouldBe` Right compact
            map identity compact `shouldBe` map identity readable
            adapters readable `shouldSatisfy` (not . null)
            map adapterReference (adapters compact) `shouldBe`
              map (Just . artifactContent) (adapters readable)
            sum (map (length . artifactContent) compact) `shouldSatisfy`
              (< sum (map (length . artifactContent) readable))
            emitPlanWithOptions False target (Just "sources") (Just "sources") plan
              `shouldBe` emitPlanWithLayout target (Just "sources") (Just "sources") plan
            if target == "gleam" then do
              emitPlanWithOptions True target (Just "src") (Just "test") plan `shouldBe` Right compact
              emitPlanWithOptions True target (Just "sources") (Just "sources") plan `shouldBe`
                Left [Diagnostic "layout" "Gleam uses src and test directories because paths determine module identities; choose the project output root instead" Nothing]
              else case emitPlanWithOptions True target (Just "sources") (Just "sources") plan of
                Left diagnostics -> expectationFailure (show diagnostics)
                Right moved -> do
                  length moved `shouldBe` length compact
                  map ownership moved `shouldBe` map ownership compact
                  -- .NET and Swift keep their runtime projects or targets at lawspec/, beside the
                  -- source and test projects that reference them, and
                  -- Clojure its Java model at java/, which lawspec.build compiles.
                  -- Prolog's launcher and selection manifest stay at the root;
                  -- their imports/entries carry the configured module paths.
                  if target == "prolog" then
                    map artifactPath (filter ((== "root") . artifactPlacement) moved)
                      `shouldMatchList` ["lawspec_test.py","lawspec-prolog-tests.json"]
                    else pure ()
                  all (\file -> take 8 (artifactPath file) == "sources/" ||
                    target `elem` ["fsharp", "csharp", "swift"] && take 8 (artifactPath file) == "lawspec/" ||
                    target == "clojure" && take 5 (artifactPath file) == "java/" ||
                    target == "prolog" && artifactPath file `elem` ["lawspec_test.py","lawspec-prolog-tests.json"]) moved `shouldBe` True
          other -> expectationFailure (show other)

  forM_ [32,64] $ \bits ->
    it ("lays out Python's helper registries at 80 columns: " ++ show bits) $ do
      let entries = [D.text (show (primitiveName primitive) ++ ": ") <>
            Generator.generatorDoc bits (const False) (const (D.text "unused"))
              (scalarType (primitiveName primitive)) | primitive <- primitives]
          doc = Helpers.dataHelperDoc bits 64 entries <> D.hardline <>
            Helpers.assertionHelperDoc
          readable = D.render (D.Pretty 80) doc
          compact = D.render D.Compact doc
      filter ((> 80) . length) (lines readable) `shouldBe` []
      length compact `shouldSatisfy` (< length readable)

  forM_ ["python", "javascript", "typescript", "rust"] $ \target ->
    it ("wraps property bodies and escaped diagnostic text for " ++ target) $ do
      let label :: String
          label = "a descriptive law with apostrophes ' and quotes \" and backslash \\ and supplementary text 🙂"
          source = "unit layout\n\ninspect :: Int32 -> Int32\n\n" ++
            "law \"|" ++ concatMap (\c -> if c == '\\' then "\\\\" else [c]) label ++ "| is definition : for all (x :: Int32) => " ++
            "x > 0 implies inspect x = x end for all end definition end law\n\nend unit\n"
      case compileCore 64 defaultGeneration [Source "layout" source] >>= planTesting >>= emitPlan target of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right files -> do
          let tests = [artifactContent file | file <- files, artifactPlacement file == "test",
                "Generated by LawSpec" `isInfixOf` artifactContent file]
          tests `shouldSatisfy` (not . null)
          -- ruff, Prettier and rustfmt never split a string literal, so only
          -- lines holding one may pass their 88, 80 and 100 columns.
          filter (\l -> length l > (if target == "rust" then 100 else if target == "python" then 88 else 80) &&
              not (any (`elem` l) (if target == "rust" then "\"" else "\"'" :: String))) (concatMap lines tests) `shouldBe` []
          case target of
            "python" -> concat tests `shouldSatisfy` isInfixOf "    _lawspec_assert(\n"
            "rust" -> concat tests `shouldSatisfy` isInfixOf "    let ctx = &mut ls::Context::testing();"
            _ -> concat tests `shouldSatisfy` isInfixOf "  ls.check(\n"
