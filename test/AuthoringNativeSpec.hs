-- | Native authoring advice (LawSpec.Authoring.Native) over the Haskell
-- fact extractors: hand-written expectations for each language and
-- invariants over the repository's native sources, and the review rules over
-- every program target's generated interface (the cases
-- npm/test/authoring-advice.test.mjs ran against the Tree-sitter analysis).
-- ref:DEC-authoring-advisories
module AuthoringNativeSpec (spec) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as B
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Text.Encoding.Error (lenientDecode)
import LawSpec.Api (dispatch)
import LawSpec.Authoring.Extract (extract, languageOf)
import LawSpec.Authoring.Native
import LawSpec.Authoring.Syntax
import LawSpec.Targets (artifactTargets, programTargets)
import System.Process (readProcess)
import Test.Hspec

model :: Text
model =
  "unit advice.model\n\
  \type Point is a record {x :: Int32 y :: Int32} end type\n\
  \echo :: Point -> Point\n\
  \law identity is definition: for all (p :: Point) => echo p = p end for all end definition end law\n\
  \end unit"

-- | A compiler request for the model.
request :: Text -> [(Key, Value)] -> Value
request method fields =
  object
    ( [ "schemaVersion" .= (5 :: Int),
        "method" .= method,
        "languageProfile" .= ("1.0-rc.2" :: Text),
        "sources" .= [object ["path" .= ("model.lawspec" :: Text), "content" .= model]]
      ]
        ++ fields
    )

answer :: Value -> Value
answer value = fromMaybe Null (decode (dispatch (encode value)))

inspect :: String -> [(Key, Value)] -> Value
inspect target fields = answer (request "inspect" (("target" .= target) : fields))

-- | A competing local model in each target's syntax.
clones :: [(String, (FilePath, Text))]
clones =
  [ ("java", ("Point.java", "record Point(int x, int y) {}")),
    ("python", ("model.py", "class Point:\n    pass\n")),
    ("javascript", ("model.mjs", "class Point {}")),
    ("typescript", ("model.ts", "interface Point { x: number; y: number; }")),
    ("go", ("model.go", "package model\ntype Point struct { X int32; Y int32 }\n")),
    ("haskell", ("Model.hs", "module Model where\ndata Point = Point Int Int")),
    ("kotlin", ("Model.kt", "data class Point(val x: Int, val y: Int)")),
    ("rust", ("model.rs", "struct Point { x: i32, y: i32 }")),
    ("erlang", ("model.erl", "-module(model).\n-record(point, {x, y}).")),
    ("elixir", ("model.ex", "defmodule LawSpec.Data.Point do\n defstruct [:x, :y]\nend")),
    ("gleam", ("model.gleam", "pub type Point { Point(x: Int, y: Int) }")),
    ("fsharp", ("Model.fs", "module Model\ntype Point = { X: int; Y: int }")),
    ("csharp", ("Model.cs", "public record Point(int X, int Y);")),
    ("scala", ("Model.scala", "case class Point(x: Int, y: Int)")),
    ("groovy", ("Model.groovy", "class Point { int x; int y }")),
    ("clojure", ("model.clj", "(ns model)\n(defrecord Point [x y])")),
    ("swift", ("Model.swift", "struct Point { var x: Int; var y: Int }")),
    ("prolog", ("model.pl", "point(point{x:1,y:2})."))
  ]

-- | A conversion between the generated model and the local one.
conversions :: [(String, Text)]
conversions =
  [ ("java", "class Convert { Point convert(Point p) { return p; } }"),
    ("python", "def convert(p: Point) -> Point:\n    return p\n"),
    ("javascript", "function convert(p) { return new Point(p.x,p.y); }"),
    ("typescript", "function convert(p: Point): Point { return p; }"),
    ("go", "func Convert(p Point) Point { return p }"),
    ("haskell", "convert p = Point 1 2"),
    ("kotlin", "fun convert(p: Point): Point = p"),
    ("rust", "fn convert(p: Point) -> Point { p }"),
    ("erlang", "convert(P) -> #point{x=P#point.x,y=P#point.y}."),
    ("elixir", "defmodule Convert do\n def convert(p), do: %LawSpec.Data.Point{x: p.x, y: p.y}\nend"),
    ("gleam", "pub fn convert(p: Point) -> Point { p }"),
    ("fsharp", "let convert (p: Point): Point = p"),
    ("csharp", "class Convert { Point convert(Point p) { return p; } }"),
    ("scala", "def convert(p: Point): Point = p"),
    ("groovy", "class Convert { Point convert(Point p) { return p } }"),
    ("clojure", "(defn convert [p] (Point. (:x p) (:y p)))"),
    ("swift", "func convert(_ p: Point) -> Point { return p }"),
    ("prolog", "convert(point{x:X,y:Y},value('advice.model::type::Point',[X,Y])).")
  ]

-- | authoring.mjs settleAdvice's ok, without exceptions.
ok :: ([Finding], [Check]) -> Bool
ok (_, checks) = all ((`elem` ["complete", "not-applicable"]) . checkStatus) checks

-- | Unresolved findings make a report not ok too.
settledOk :: ([Finding], [Check]) -> Bool
settledOk report@(findings, _) = null findings && ok report

rules :: ([Finding], [Check]) -> [Text]
rules = map findingRule . fst

run :: String -> Value -> [(FilePath, Text)] -> ([Finding], [Check])
run target result sources = analyze target (inspectionOf result) [] (Just [Just (Source p c) | (p, c) <- sources])

files :: Value -> [Value]
files (Object o) = maybe [] toList' (KM.lookup "files" o)
  where
    toList' (Array items) = toList items
    toList' _ = []
files _ = []

text :: Key -> Value -> Text
text key (Object o) = case KM.lookup key o of
  Just (String t) -> t
  _ -> ""
text _ _ = ""

withFiles :: [Value] -> Value -> Value
withFiles planned (Object o) = Object (KM.insert "files" (toJSON planned) o)
withFiles _ other = other

nativeExtension :: FilePath -> Bool
nativeExtension path = any (`isSuffixOf'` path) [".java", ".py", ".mjs", ".js", ".ts", ".go", ".rs", ".hs", ".kt", ".erl", ".ex", ".gleam", ".fs", ".cs", ".scala", ".groovy", ".clj", ".swift", ".pl"]
  where
    isSuffixOf' suffix whole = reverse suffix `isPrefixOf` reverse whole

spec :: Spec
spec = describe "native authoring advice" $ do
  describe "fact extraction" $ do
    forM_ expectations $ \c ->
      it (caseLabel c) $ do
        forM_ (casePending c) pendingWith
        let facts = extract (casePath c) (caseSource c)
        factsStatus facts `shouldBe` caseStatus c
        when (caseStatus c == "complete") $ do
          [(declarationName d, declarationKind d, declarationLine d, declarationModel d, declarationFields d, sort (nub (declarationIdentifiers d))) | d <- factsDeclarations facts]
            `shouldBe` [(n, k, l, m, f, sort (nub i)) | (n, k, l, m, f, i) <- caseDeclarations c]
          factsImports facts `shouldBe` caseImports c
          factsModules facts `shouldBe` caseModules c
          factsLimits facts `shouldBe` caseLimits c
    it "reads every native source of the repository without failing, consistently and in range" repositorySources
    it "reads unsupported, oversized and unreadable sources as incomplete" $ do
      factsStatus (extract "view.tsx" "const Point = () => <div/>;") `shouldBe` "incomplete"
      factsReason (extract "view.tsx" "") `shouldBe` Just "No bundled parser for tsx"
      factsReason (extract "Notes.lhs" "") `shouldBe` Just "No bundled parser for literate-haskell"
      factsStatus (extract "unknown.xyz" "class Point {}") `shouldBe` "unsupported"
      factsReason (extract "big.mjs" (T.replicate (2 * 1024 * 1024 + 1) "x")) `shouldBe` Just "Native file exceeds the 2 MiB analysis limit"
      factsStatus (extract "broken.mjs" "class {") `shouldBe` "incomplete"
  describe "review rules" $ do
    it "completes the common checks and finds competing, renamed and copied models in every program target" $
      forM_ programTargets $ \target -> do
        let inspected = inspect target []
            (file, content) = fromMaybe ("", "") (lookup target clones)
        settledOk (run target inspected []) `shouldBe` True
        let competing = run target inspected [(file, content)]
        rules competing `shouldSatisfy` elem "native-model"
        let renamed =
              run
                target
                (withFiles [object ["path" .= ("generated/data/" ++ file), "content" .= content, "ownership" .= ("generated" :: Text)]] inspected)
                [("alternative/" ++ file, T.replace "point" "renamed" (T.replace "Point" "Renamed" content))]
        (target, rules renamed) `shouldSatisfy` (elem "native-model" . snd)
        case [f | f <- files inspected, text "ownership" f == "generated", "runtime" `isInfixOf` T.unpack (T.toLower (text "path" f)), nativeExtension (T.unpack (text "path" f))] of
          support : _ -> (target, rules (run target inspected [("copied/" ++ T.unpack (text "path" support), text "content" support)])) `shouldSatisfy` (elem "copied-generated" . snd)
          [] -> expectationFailure ("no runtime support file for " ++ target)
        ok (analyze target (inspectionOf inspected) [] Nothing) `shouldBe` False
    it "accepts the generated adapters, readable and compact, in every program target" $
      forM_ programTargets $ \target -> forM_ [32, 64 :: Int] $ \bits -> do
        let inspected = inspect target ["machineBits" .= bits]
            adapters = [(T.unpack (text "path" f), text "content" f) | f <- files inspected, text "ownership" f == "user"]
        adapters `shouldSatisfy` (not . null)
        (target, bits, run target inspected adapters) `shouldSatisfy` (\(_, _, report) -> settledOk report)
        let compact = answer (request "planGeneration" ["target" .= target, "machineBits" .= bits, "minify" .= True])
            native = [(T.unpack (text "path" f), text "content" f) | f <- files compact, nativeExtension (T.unpack (text "path" f))]
        (target, bits, run target inspected native) `shouldSatisfy` (\(_, _, report) -> settledOk report)
    it "finds adapters and conversions that refer to a competing model" $
      forM_ programTargets $ \target -> do
        let inspected = inspect target []
            (file, clone) = fromMaybe ("", "") (lookup target clones)
            content = clone <> "\n" <> fromMaybe "" (lookup target conversions)
            baseline = withFiles (files inspected ++ [object ["path" .= ("adapter/" ++ file), "content" .= content, "ownership" .= ("user" :: Text)]]) inspected
            report = run target baseline [(file, content)]
        forM_ ["native-model", "adapter-identity", "manual-conversion"] $ \rule ->
          (target, rule, rules report) `shouldSatisfy` (\(_, r, found) -> r `elem` found)
    it "reports unreadable, unsupported and unresolved sources as incomplete" $ do
      let inspected = inspect "javascript" []
      forM_ [("broken.mjs", "class {"), ("unknown.xyz", "class Point {}"), ("view.tsx", "const Point = () => <div/>;"), ("foreign.mjs", "import {Point} from './missing.mjs';")] $ \source ->
        ok (run "javascript" inspected [source]) `shouldBe` False
      forM_ artifactTargets $ \target ->
        map checkStatus (snd (analyze target (inspectionOf (object ["files" .= ([] :: [Value])])) [] Nothing)) `shouldSatisfy` all (== "not-applicable")
    it "scopes native languages to the target and its composite hosts" $ do
      let unrelated = run "java" (inspect "java" []) [("web.mjs", "class Point {}")]
      settledOk unrelated `shouldBe` True
      [checkStatus c | c <- snd unrelated, checkRule c == "native-language"] `shouldBe` ["not-applicable"]
      rules (run "csharp" (inspect "csharp" []) [("Model.fs", "module Model\ntype Point = { X: int; Y: int }")]) `shouldSatisfy` elem "native-model"
    it "keeps checked native bindings out of the competing models" $
      forM_ programTargets $ \target -> do
        let module' = if target `elem` ["haskell", "elixir", "fsharp", "swift"] then "Domain" else "domain" :: Text
            prefix = ["crate" | target == "rust"] ++ [module']
            name = if target `elem` ["erlang", "prolog"] then "point" else "Point" :: Text
            bindings =
              object
                ( ["rustCrate" .= ("trial" :: Text) | target == "rust"]
                    ++ ["goImports" .= [object ["alias" .= ("domain" :: Text), "path" .= ("example.test/domain" :: Text)]] | target == "go"]
                    ++ ["erlangIncludes" .= [object ["path" .= ("domain.hrl" :: Text)]] | target == "erlang"]
                    ++ [ "types"
                           .= [ object
                                  [ "type" .= ("advice.model::type::Point" :: Text),
                                    "native" .= (prefix ++ [name]),
                                    "constructors"
                                      .= [ object
                                             [ "constructor" .= ("Point" :: Text),
                                               "native" .= (if target == "erlang" then [name] else prefix ++ [name]),
                                               "style" .= ("record" :: Text),
                                               "fields" .= [object ["field" .= ("x" :: Text), "native" .= (if target == "go" then "X" else "x" :: Text)], object ["field" .= ("y" :: Text), "native" .= (if target == "go" then "Y" else "y" :: Text)]]
                                             ]
                                         ]
                                  ]
                              ],
                         "functions" .= [object ["declaration" .= ("advice.model::echo" :: Text), "native" .= (prefix ++ [if target == "go" then "Echo" else "echo"])]]
                       ]
                )
            result = inspect target ["nativeBindings" .= bindings]
        unless (target `elem` ["csharp", "clojure"]) $ do
          let (file, original) = fromMaybe ("", "") (lookup target clones)
              renamed =
                T.replace "package model" "package domain"
                  $ T.replace "-module(model)." "-module(domain)."
                  $ T.replace "module Model\n" "module Domain\n"
                  $ T.replace "module Model where" "module Domain where"
                  $ T.replace "LawSpec.Data.Point" "Domain.Point" original
              content
                | target `elem` ["java", "groovy"] = "package domain;\n" <> renamed
                | target `elem` ["kotlin", "scala"] = "package domain\n" <> renamed
                | otherwise = renamed
              extension = reverse (takeWhile (/= '.') (reverse file))
              path = if target == "java" then "domain/Point.java" else T.unpack module' ++ "." ++ extension
              report = analyze target (inspectionOf result) (bindingsOf (object ["nativeBindings" .= bindings])) (Just [Just (Source path content)])
          (target, rules report) `shouldSatisfy` (notElem "native-model" . snd)
          (target, report) `shouldSatisfy` (settledOk . snd)
  describe "import resolution" $ do
    let unresolved target planned (path, content) =
          [ r
          | Check {checkRule = "native-reference", checkReason = Just r} <- snd (analyze target (Inspection [PlannedFile p "" (Just "generated") | p <- planned] [] [] []) [] (Just [Just (Source path content)]))
          ]
    it "resolves members of generated runtime modules" $ do
      unresolved "java" ["src/main/java/lawspec/runtime/LawSpecRuntime.java"] ("src/test/java/example/Gen.java", "package example;\nimport lawspec.runtime.LawSpecRuntime.Value;\nclass Gen {}\n") `shouldBe` []
      unresolved "rust" ["src/lawspec_runtime.rs"] ("tests/gen.rs", "use crate::lawspec_runtime::Decimal;\nuse lawspec_example::lawspec_runtime::Decimal as D;\nfn f() {}\n") `shouldBe` []
    it "resolves packages, Python packages and the Swift App module" $ do
      unresolved "scala" ["src/test/scala/lawspec/LawSpecScalaStrategies.scala"] ("src/test/scala/domain/Gen.scala", "package domain\nimport lawspec._\nobject Gen\n") `shouldBe` []
      unresolved "python" ["lawspec/__init__.py"] ("tests/gen.py", "import lawspec\nimport threading\nfrom hypothesis import given\n") `shouldBe` []
      unresolved "swift" ["src/Payments.swift"] ("tests/Native/Gen.swift", "import Foundation\n@testable import App\n") `shouldBe` []
    it "treats dotless Go import paths as the standard library" $ do
      unresolved "go" [] ("gen_test.go", "package model\n\nimport (\n\t\"math/big\"\n\t\"pgregory.net/rapid\"\n)\n") `shouldBe` []
    it "still reports an import nothing supplies" $ do
      length (unresolved "java" ["src/main/java/lawspec/runtime/LawSpecRuntime.java"] ("src/main/java/example/A.java", "package example;\nimport com.acme.billing.Invoice;\nclass A {}\n")) `shouldBe` 1
      length (unresolved "go" [] ("a.go", "package model\n\nimport \"github.com/acme/billing\"\n")) `shouldBe` 1
  describe "the advise request" $ do
    it "analyzes native sources, settles exceptions and keeps the native member order" $ do
      let response = dispatch (encode (request "advise" ["target" .= ("javascript" :: Text), "nativeSources" .= [object ["path" .= ("clone.mjs" :: Text), "content" .= ("class Point {}" :: Text)]]]))
          bytes = B.toStrict response
      bytes `shouldSatisfy` BS.isInfixOf "{\"rule\":\"native-model\",\"target\":\"javascript\",\"path\":\"clone.mjs\",\"declaration\":\"clone.mjs::Point\",\"line\":1,\"severity\":\"warning\",\"status\":\"unresolved\""
      bytes `shouldSatisfy` BS.isInfixOf "\"ok\":false}"
      bytes `shouldSatisfy` (not . BS.isInfixOf "\"interface\"")
      let excepted = dispatch (encode (request "advise" ["target" .= ("javascript" :: Text), "nativeSources" .= [object ["path" .= ("clone.mjs" :: Text), "content" .= ("class Point {}" :: Text)]], "exceptions" .= [object ["declaration" .= ("clone.mjs::Point" :: Text), "rule" .= ("native-model" :: Text), "reason" .= ("Independent reference model" :: Text)]]]))
      B.toStrict excepted `shouldSatisfy` BS.isInfixOf "\"status\":\"excepted\",\"message\":"
      let blank = dispatch (encode (request "advise" ["exceptions" .= [object ["declaration" .= ("x" :: Text), "rule" .= ("native-model" :: Text), "reason" .= (" " :: Text)]]]))
      B.toStrict blank `shouldSatisfy` BS.isInfixOf "Authoring exceptions require a declaration, rule and nonempty reason"
    it "reports missing native sources as incomplete" $ do
      let response = dispatch (encode (request "advise" ["target" .= ("javascript" :: Text)]))
      B.toStrict response `shouldSatisfy` BS.isInfixOf "\"reason\":\"Native sources were not supplied\""

-- | One hand-written expectation: a source and the facts a reader finds in
-- it. A declaration is (name, kind, line, model, fields, identifiers); the
-- identifiers are the names inside its span, compared as a set.
data Case = Case
  { caseLabel :: String,
    casePath :: FilePath,
    caseSource :: Text,
    caseStatus :: Text,
    caseDeclarations :: [(Text, Text, Int, Bool, [Text], [Text])],
    caseImports :: [Text],
    caseModules :: [Text],
    caseLimits :: [Text],
    casePending :: Maybe String
  }

complete :: String -> FilePath -> Text -> [(Text, Text, Int, Bool, [Text], [Text])] -> [Text] -> [Text] -> [Text] -> Case
complete label path source declarations imports modules limits =
  Case label path source "complete" declarations imports modules limits Nothing

incomplete :: String -> FilePath -> Text -> Case
incomplete label path source = Case label path source "incomplete" [] [] [] [] Nothing

-- | An expectation the extractor does not meet yet: the correct facts stay,
-- and the case waits for the reason.
deferred :: String -> Case -> Case
deferred reason c = c {casePending = Just reason}

expectations :: [Case]
expectations =
  [ complete
      "java: a record and a class with a method"
      "Shapes.java"
      "package demo.model;\n\nimport java.util.List;\n\npublic record Point(int x, int y) {}\n\nclass Account {\n    void deposit(long amount) {}\n}\n"
      [ ("Account", "class_declaration", 7, True, [], ["Account", "deposit", "amount"]),
        ("deposit", "method_declaration", 8, False, [], ["deposit", "amount"]),
        ("Point", "record_declaration", 5, True, [], ["Point", "x", "y"])
      ]
      ["java.util.List"]
      ["demo.model"]
      [],
    incomplete "java: an unclosed class body" "Broken.java" "class Point {\n",
    complete
      "python: a class and a function"
      "model.py"
      "import os\nfrom typing import List\n\nclass Point:\n    x = 0\n\ndef move(p):\n    return p\n"
      [ ("move", "function_definition", 7, False, [], ["move", "p"]),
        ("Point", "class_definition", 4, True, [], ["Point", "x"])
      ]
      ["typing", "os"]
      []
      [],
    incomplete "python: an unclosed bracket" "broken.py" "def f(:\n  x = (1\n",
    complete
      "javascript: an import and a class"
      "model.mjs"
      "import { helper } from \"./util.mjs\";\n\nexport class Point {\n  constructor(x) { this.x = x; }\n}\n"
      [("Point", "class_declaration", 3, True, [], ["Point", "constructor", "x"])]
      ["./util.mjs"]
      []
      [],
    incomplete "javascript: an unclosed class" "broken.js" "class Point {\n",
    complete
      "typescript: an interface and a type alias"
      "model.ts"
      "interface Point { x: number; y: number }\n\nexport type Id = string;\n"
      [ ("Id", "type_alias_declaration", 3, True, [], ["Id"]),
        ("Point", "interface_declaration", 1, True, [], ["Point", "x", "y"])
      ]
      []
      []
      [],
    incomplete "typescript: an unclosed interface" "broken.ts" "interface Point { x: number;\n",
    complete
      "go: a package, a struct and a function"
      "model.go"
      "package model\n\ntype Point struct{ X int32 }\n\nfunc Show(p Point) string { return p.String() }\n"
      [ ("Show", "function_declaration", 5, False, [], ["Show", "p", "Point", "string", "String"]),
        ("Point", "type_spec", 3, True, [], ["Point", "X", "int32"])
      ]
      []
      ["model"]
      [],
    complete
      "go: an import"
      "imports.go"
      "package model\n\nimport \"fmt\"\n"
      []
      ["fmt"]
      ["model"]
      [],
    complete
      "go: a grouped import with an alias"
      "grouped.go"
      "package model\n\nimport (\n\t\"fmt\"\n\tstr \"strings\"\n)\n"
      []
      ["strings", "fmt"]
      ["model"]
      [],
    complete
      "go: an import without a path"
      "pathless.go"
      "package model\n\nimport fmt\n"
      []
      []
      ["model"]
      ["Unresolved import syntax at line 3"],
    incomplete "go: an unclosed block" "broken.go" "package model\nfunc F() {\n",
    complete
      "haskell: a module with a data type and a function"
      "Model.hs"
      "module Model where\n\nimport Data.List (sort)\n\ndata Point = Point Int Int\n\nnorm :: Point -> Int\nnorm (Point a b) = a + b\n"
      [ ("norm", "function", 8, False, [], ["norm", "Point", "a", "b"]),
        -- The grammar reads the arrow of a signature's type as a function.
        ("Point", "function", 7, False, [], ["Point", "Int"]),
        ("Point", "data_type", 5, True, [], ["Point", "Int"])
      ]
      ["Data.List"]
      ["Model"]
      [],
    incomplete "haskell: an unclosed parenthesis" "Broken.hs" "module Broken where\nf = (1 +\n",
    complete
      "kotlin: a data class and a function"
      "Model.kt"
      "package demo\n\nimport kotlin.math.abs\n\ndata class Point(val x: Int, val y: Int)\n\nfun norm(p: Point): Int = abs(p.x)\n"
      [ ("norm", "function_declaration", 7, False, [], ["norm", "p", "Point", "Int", "abs", "x"]),
        ("Point", "class_declaration", 5, True, [], ["Point", "x", "Int", "y"])
      ]
      ["kotlin.math.abs"]
      -- A package header is not a module fact.
      []
      [],
    incomplete "kotlin: an unclosed class body" "Broken.kt" "class Point {\n",
    complete
      "rust: a use, a struct and a function"
      "model.rs"
      "use std::fmt;\n\nstruct Point { x: i32, y: i32 }\n\nfn norm(p: &Point) -> i32 { p.x }\n"
      [ ("norm", "function_item", 5, False, [], ["norm", "p", "Point", "x"]),
        ("Point", "struct_item", 3, True, [], ["Point", "x", "y"])
      ]
      ["std::fmt"]
      []
      [],
    incomplete "rust: an unclosed struct" "broken.rs" "struct Point { x: i32,\n",
    complete
      "erlang: a module, an import, a record and a function"
      "model.erl"
      "-module(model).\n-export([norm/1]).\n-import(lists, [sum/1]).\n-record(point, {x, y}).\n\nnorm(P) -> P.\n"
      [ ("norm", "fun_decl", 6, False, [], ["norm"]),
        ("point", "record_decl", 4, True, [], ["point", "x", "y"])
      ]
      ["lists"]
      ["model"]
      [],
    incomplete "erlang: an unclosed tuple" "broken.erl" "-module(broken).\nf() -> {1,\n",
    complete
      "elixir: a module with an import and a struct"
      "point.ex"
      "defmodule Demo.Point do\n  import Enum\n  defstruct [:x, :y]\nend\n"
      [("Demo.Point", "call", 1, True, [], ["defmodule", "Demo.Point", "import", "Enum", "defstruct", ":x", ":y"])]
      ["Enum"]
      []
      [],
    incomplete "elixir: an unclosed list" "broken.ex" "defmodule Broken do\n  @x [1,\nend\n",
    complete
      "gleam: an import, a type and a function"
      "model.gleam"
      "import gleam/list\n\npub type Point {\n  Point(x: Int, y: Int)\n}\n\npub fn norm(p: Point) -> Int {\n  p.x\n}\n"
      [ ("norm", "function", 7, False, [], ["norm", "p", "Point", "Int"]),
        ("Point", "type_definition", 3, True, [], ["Point", "Int"])
      ]
      ["gleam/list"]
      []
      [],
    incomplete "gleam: an unclosed block" "broken.gleam" "pub fn f() {\n",
    complete
      "fsharp: a module, an open, a record and a function"
      "Model.fs"
      "module Model\n\nopen System\n\ntype Point = { X: int; Y: int }\n\nlet norm (p: Point) = p.X\n"
      [ ("norm", "function_or_value_defn", 7, False, [], ["norm", "p", "Point", "X"]),
        ("Point", "type_definition", 5, True, [], ["Point", "X", "Y", "int"])
      ]
      -- An open declaration is not an import.
      []
      ["Model"]
      [],
    incomplete "fsharp: an unclosed record" "Broken.fs" "type Point = { X: int;\n",
    complete
      "csharp: a namespace, a using, a record and a class"
      "Model.cs"
      "namespace Demo;\n\nusing System;\n\npublic record Point(int X, int Y);\n\nclass Util { int Norm(Point p) { return p.X; } }\n"
      [ ("Util", "class_declaration", 7, True, [], ["Util", "Norm", "Point", "p", "X"]),
        ("Norm", "method_declaration", 7, False, [], ["Norm", "Point", "p", "X"]),
        ("Point", "record_declaration", 5, True, [], ["Point", "X", "Y"])
      ]
      -- Using directives are not imports.
      []
      ["Demo"]
      [],
    incomplete "csharp: an unclosed class" "Broken.cs" "class Point {\n",
    complete
      "scala: a package, an import, a case class and a method"
      "Model.scala"
      "package demo\n\nimport scala.math.abs\n\ncase class Point(x: Int, y: Int)\n\ndef norm(p: Point): Int = abs(p.x)\n"
      [ ("norm", "function_definition", 7, False, [], ["norm", "p", "Point", "Int", "abs", "x"]),
        ("Point", "class_definition", 5, True, [], ["Point", "x", "Int", "y"])
      ]
      ["scala"]
      ["demo"]
      [],
    incomplete "scala: an unclosed class body" "Broken.scala" "class Point {\n",
    complete
      "groovy: a package, an import and a class"
      "Model.groovy"
      "package demo\n\nimport java.util.List\n\nclass Point { int x; int y }\n"
      [("Point", "class_declaration", 5, True, [], ["Point", "int", "x", "y"])]
      ["java.util.List"]
      ["demo"]
      [],
    incomplete "groovy: an unclosed class" "Broken.groovy" "class Point {\n",
    complete
      "clojure: a namespace, a record and a function"
      "core.clj"
      "(ns demo.core)\n\n(defrecord Point [x y])\n\n(defn norm [p] (:x p))\n"
      [ ("norm", "list_lit", 5, False, [], ["defn", "norm", "p", "x"]),
        ("Point", "list_lit", 3, True, [], ["defrecord", "Point", "x", "y"])
      ]
      []
      ["demo.core"]
      [],
    incomplete "clojure: an unclosed list" "broken.clj" "(defn f [x]\n",
    complete
      "swift: an import, a struct and a function"
      "Model.swift"
      "import Foundation\n\nstruct Point { var x: Int; var y: Int }\n\nfunc norm(_ p: Point) -> Int { return p.x }\n"
      [ ("norm", "function_declaration", 5, False, [], ["norm", "_", "p", "Point", "Int", "x"]),
        ("Point", "class_declaration", 3, True, [], ["Point", "x", "Int", "y"])
      ]
      ["Foundation"]
      []
      [],
    incomplete "swift: an unclosed struct" "Broken.swift" "struct Point {\n",
    complete
      "prolog: a use_module and a dict"
      "model.pl"
      ":- use_module(library(lists)).\n\npoint(p{x:1, y:2}).\n"
      [ ("point", "clause", 3, False, [], ["point", "p", "x", "y"]),
        ("p", "dict", 3, True, ["x", "y"], ["p", "x", "y"])
      ]
      ["library(lists)"]
      []
      [],
    incomplete "prolog: an unclosed argument list" "broken.pl" "point(1,\n"
  ]

-- | Every native source of acceptance/ and examples/ tracked by git: the
-- extractor finishes, repeats itself, names only what the file contains and
-- places each declaration inside the file.
repositorySources :: Expectation
repositorySources = do
  listing <- readProcess "git" ["ls-files", "acceptance", "examples"] ""
  let paths = [p | p <- lines listing, Just _ <- [languageOf p]]
  paths `shouldSatisfy` (not . null)
  found <- fmap concat $ forM paths $ \path -> do
    content <- T.decodeUtf8With lenientDecode <$> BS.readFile path
    let lineCount = length (T.lines content)
        facts = extract path content
        problem message = [path ++ ": " ++ message]
    first <- try (evaluate (length (show facts))) :: IO (Either SomeException Int)
    case first of
      Left failure -> pure (problem ("exception " ++ show failure))
      Right _ ->
        pure $
          concat
            [ problem "a second extraction differs" | extract path content /= facts
            ]
            ++ concat
              [ problem ("declaration " ++ show (declarationName d) ++ " is not in the file")
              | d <- factsDeclarations facts,
                not (declarationName d `T.isInfixOf` content)
              ]
            ++ concat
              [ problem ("module " ++ show m ++ " is not in the file")
              | m <- factsModules facts,
                not (m `T.isInfixOf` content)
              ]
            ++ concat
              [ problem ("declaration " ++ show (declarationName d) ++ " at line " ++ show (declarationLine d) ++ " of " ++ show lineCount)
              | d <- factsDeclarations facts,
                declarationLine d < 1 || declarationLine d > max 1 lineCount
              ]
  take 20 found `shouldBe` []
