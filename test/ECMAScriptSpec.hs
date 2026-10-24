-- | LawSpec prints JavaScript and TypeScript as Prettier 3.9.10 does
-- (DEC-web-prettier-printer). Each expectation here is Prettier's own output
-- for the same code; acceptance checks every generated module against the
-- pinned Prettier itself.
module ECMAScriptSpec (test_javascriptIsLaidOutAsPrettierLaysItOut) where

import Test.Hspec
import LawSpec.Code.ECMAScript

test_javascriptIsLaidOutAsPrettierLaysItOut :: Spec
test_javascriptIsLaidOutAsPrettierLaysItOut = describe "Prettier's layout" $ do
  it "keeps a test call's name on its line and hugs a call's last callback" $
    printModule JavaScript
      [ ExprStmt (call "test" [str "a test whose name is long enough to pass the eighty column limit", arrowBlock []
          [ExprStmt (call "ls.check" [str "example.slug::|normalizers agree| example — slug.lawspec:15",
             arrow [] (call "ls.validate" [call "impl.normalize" [call "ls.convert" [ident "x", str "Text", ident "MACHINE_BITS"]], str "Text", ident "MACHINE_BITS"]),
             arrow [] (str "Hello,-World!"), str "Text", str "Text"])]]) ]
      `shouldBe` unlines
      [ "test(\"a test whose name is long enough to pass the eighty column limit\", () => {"
      , "  ls.check("
      , "    \"example.slug::|normalizers agree| example — slug.lawspec:15\","
      , "    () =>"
      , "      ls.validate("
      , "        impl.normalize(ls.convert(x, \"Text\", MACHINE_BITS)),"
      , "        \"Text\","
      , "        MACHINE_BITS,"
      , "      ),"
      , "    () => \"Hello,-World!\","
      , "    \"Text\","
      , "    \"Text\","
      , "  );"
      , "});" ]
  it "breaks a member chain one call per line and unquotes identifier keys" $
    printModule JavaScript
      [ ExprStmt (method (method (call "fc.tuple" [call "fc.bigInt" [], call "fc.integer" [Object [Prop (KString "min") (num (-20)), Prop (KName "max") (num 20)]]])
          "map" [arrow [param "v"] (new' "ls.Decimal" [index (ident "v") (num 0), index (ident "v") (num 1)])]) "filter" [arrow [param "v"] (BoolLit True)]) ]
      `shouldBe` unlines
      [ "fc.tuple(fc.bigInt(), fc.integer({ min: -20, max: 20 }))"
      , "  .map((v) => new ls.Decimal(v[0], v[1]))"
      , "  .filter((v) => true);" ]
  it "breaks an assignment's ternary after the operator and types a function's parameters" $
    printModule TypeScript
      [ constDecl "value" (Conditional (binary "===" (ident "a") (ident "b")) (str (replicate 30 'x')) (str (replicate 60 'x')))
      , FunctionDecl True False "feeModel" [] [typedParam "symbols" (TRef "Map" [TKeyword "string", TKeyword "symbol"]), typedParam "value" (TRef "data.Money" [])]
          (Just (TRef "data.Money" [])) [ret (ident "value")]
      , TypeAlias True "Payment" [] (TUnion [TRef "PaymentApproved" [], TRef "PaymentDeclined" [], TRef "PaymentPendingWithAVeryLongNameIndeed" []]) ]
      `shouldBe` unlines
      [ "const value ="
      , "  a === b"
      , "    ? \"" ++ replicate 30 'x' ++ "\""
      , "    : \"" ++ replicate 60 'x' ++ "\";"
      , "export function feeModel("
      , "  symbols: Map<string, symbol>,"
      , "  value: data.Money,"
      , "): data.Money {"
      , "  return value;"
      , "}"
      , "export type Payment ="
      , "  PaymentApproved | PaymentDeclined | PaymentPendingWithAVeryLongNameIndeed;" ]
  it "writes text as a string literal, choosing the quote that needs fewer escapes" $ do
    javascriptLiteral "Hello, World!" `shouldBe` "\"Hello, World!\""
    javascriptLiteral "say \"hi\"" `shouldBe` "'say \"hi\"'"
    javascriptLiteral "line\nbreak \\ end" `shouldBe` "\"line\\nbreak \\\\ end\""
  it "rebalances a right-nested logical chain and leaves a for update unparenthesised" $
    printModule JavaScript
      [ constDecl "ok" (and' (call "ls.binary" [str "<", ident "lower", ident "limit"])
          (and' (call "ls.binary" [str ">", ident "upper", ident "lower"]) (call "ls.binary" [str "<=", ident "upper", ident "limit"])))
      , For (Just ("let", PIdent "cell", Nothing, Just (ident "members"))) (Just (binary "!==" (ident "cell") Null))
          (Just (Assign "=" (ident "cell") (member (ident "cell") "t"))) [] ]
      `shouldBe` unlines
      [ "const ok ="
      , "  ls.binary(\"<\", lower, limit) &&"
      , "  ls.binary(\">\", upper, lower) &&"
      , "  ls.binary(\"<=\", upper, limit);"
      , "for (let cell = members; cell !== null; cell = cell.t) {}" ]
  it "breaks a defaulted parameter onto its own line and a cast's tuple type" $
    printModule TypeScript
      [ FunctionDecl True False "start" []
          [(typedParam "options" (TObject [("supervisor", True, TRef "ls.Supervisor" []), ("lifetime", True, TKeyword "string")])) { paramDefault = Just (Object []) }]
          (Just (TRef "AccountActor" []))
          [ret (As (call "ls.receiveNowOn" [This, ident "ReceiveInt32Step2"]) (TTuple [TKeyword "number", TRef "ReceiveInt32Step2WithALongName" []]))] ]
      `shouldBe` unlines
      [ "export function start("
      , "  options: { supervisor?: ls.Supervisor; lifetime?: string } = {},"
      , "): AccountActor {"
      , "  return ls.receiveNowOn(this, ReceiveInt32Step2) as ["
      , "    number,"
      , "    ReceiveInt32Step2WithALongName,"
      , "  ];"
      , "}" ]
