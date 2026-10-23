-- | Law explanations (LawSpec.Explain): the compiler words one typed law in
-- the eng, math and dev registers without changing its obligation. Synthetic
-- wire values exercise each presentation rule directly; compiled laws check
-- the registers end to end through the API. ref:DEC-explain-registers
module ExplainSpec (test_explanationsWordOneTypedLawInEachRegister) where

import Data.Aeson
import Data.Aeson.Types (Pair)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Explain

s :: Text -> Value
s = String

get :: Text -> Value -> Value
get key (Object o) = fromMaybe Null (KM.lookup (K.fromText key) o)
get _ _ = Null

items :: Value -> [Value]
items (Array xs) = toList xs
items _ = []

firstOf :: [a] -> a
firstOf (x : _) = x
firstOf [] = error "expected at least one item"

str :: Value -> Text
str (String t) = t
str _ = ""

-- * Wire terms

ty :: Text -> [Value] -> Value
ty name arguments = object ["kind" .= s "constructor", "name" .= name, "arguments" .= [object ["kind" .= s "type", "type" .= a] | a <- arguments]]

integer, bool :: Value
integer = ty "Integer" []
bool = ty "Bool" []

node :: Text -> [Pair] -> Value
node k fields = object (("kind" .= k) : fields)

expr :: Value -> Text -> Value -> Value
expr n text t = object ["node" .= n, "text" .= text, "type" .= t]

term :: Value -> Value
term n = expr n "original checked term" integer

local :: Text -> Text -> Value
local i text = expr (node "local" ["id" .= i]) text integer

number :: Int -> Value
number n = expr (node "constant" ["value" .= object ["type" .= s "Integer", "value" .= T.pack (show n)]]) (T.pack (show n)) integer

unitValue :: Value
unitValue = expr (node "constant" ["value" .= object ["type" .= s "Unit"]]) "unitValue" integer

binder :: Text -> Text -> Value
binder i name = object ["id" .= i, "name" .= name, "type" .= integer]

letIn :: Value -> Value -> Value -> Value
letIn b value body = term (node "let" ["binder" .= b, "value" .= value, "body" .= body])

binary :: Text -> Value -> Value -> Value
binary operator left right = term (node "binary" ["operator" .= operator, "left" .= left, "right" .= right])

construct :: Text -> [Value] -> Value
construct constructor arguments = term (node "construct" ["constructor" .= constructor, "arguments" .= arguments])

record :: Text -> [Text] -> Value
record i labels = object
  [ "id" .= i, "name" .= i, "parameters" .= ([] :: [Value])
  , "structure" .= object ["kind" .= s "record", "fields" .= [object ["name" .= l, "predicates" .= ([] :: [Value])] | l <- labels]]
  , "constructors" .= [object ["id" .= (i <> "::Record"), "name" .= s "Record", "fields" .= [binder (i <> "::" <> l) l | l <- labels]]] ]

functions :: [Text] -> Value
functions names = toJSON [object ["id" .= s "domain", "declarations" .= [object ["id" .= ("domain::" <> n), "name" .= n] | n <- names]]]

call :: Text -> [Value] -> Value
call name arguments = term (node "call" ["declaration" .= ("domain::" <> name), "arguments" .= arguments])

-- * Synthetic laws

baseLaw :: [Pair] -> Value
baseLaw fields = object (
  [ "id" .= s "shop::law::identity", "owner" .= s "shop", "name" .= s "identity"
  , "inputs" .= [object ["id" .= s "amount", "name" .= s "amount", "type" .= integer, "predicates" .= ([] :: [Value])]]
  , "assertion" .= object ["kind" .= s "equal", "left" .= object ["text" .= s "refund amount"], "right" .= object ["text" .= s "Approved"]]
  , "location" .= object ["file" .= s "shop.lawspec", "line" .= (1 :: Int), "column" .= (1 :: Int)]
  , "trace" .= ([] :: [Value]), "examples" .= ([] :: [Value])
  , "description" .= s "A captured amount may be refunded.", "rationale" .= s "" ] `override` fields)
  where override base extra = [(k, v) | (k, v) <- base, k `notElem` map fst extra] ++ extra

explainWith :: View -> [Pair] -> Value -> Value
explainWith view result law = either (error . ("explain: " ++)) id
  (explainResult (ExplainOptions view Nothing Nothing) (object (("laws" .= [law]) : result)))

textOf :: View -> [Pair] -> Value -> Text
textOf view result law = str (get "text" (explainWith view result law))

section :: Text -> View -> [Pair] -> Value -> [Text]
section kind' view result law = concat [map str (items (get "lines" sec))
  | e <- items (get "explanations" (explainWith view result law)), sec <- items (get "sections" e), str (get "kind" sec) == kind']

-- | The dev rendering of one checked term, read back from a configured
-- witness, which shows the term unbracketed.
render :: [Pair] -> Value -> Text
render result t = renderIn result [] t

renderIn :: [Pair] -> [(Text, Text)] -> Value -> Text
renderIn result inputs t =
  let law = baseLaw [ "inputs" .= [object ["id" .= i, "name" .= n, "type" .= integer, "predicates" .= ([] :: [Value])] | (i, n) <- inputs]
                    , "harness" .= object ["witnesses" .= [object ["path" .= [s "x"], "expression" .= t]]] ]
      prefix = "Configured witness (not completed evidence): definition.x = "
  in case section "strategies" Dev result law of
       [line] -> fromMaybe line (T.stripPrefix prefix line)
       other -> error ("unexpected strategies " ++ show other)

-- | The dev rendering of a type, read back from the law's inputs.
typeText :: [Pair] -> Value -> Text
typeText result t = case section "inputs" Dev result (baseLaw ["inputs" .= [object ["id" .= s "x", "name" .= s "x", "type" .= t, "predicates" .= ([] :: [Value])]]]) of
  [line] -> fromMaybe line (T.stripPrefix "Inputs: x of type " line)
  other -> error ("unexpected inputs " ++ show other)

-- * Compiled laws through the API

request :: [Pair] -> Value
request fields = fromMaybe (error "invalid API response") (decode (dispatch (encode (object
  (["schemaVersion" .= (5 :: Int), "languageProfile" .= s "1.0-rc.2", "method" .= s "explain"] ++ fields)))))

refundSource :: Text
refundSource = T.unlines
  [ "unit example.refunds", ""
  , "type RefundDecision is one of", "  | Approved", "  | ReviewRequired", "  | Rejected", "end type", ""
  , "type RefundRequest is a record{", "  capturedAmount of type Whole", "  requestedAmount of type Whole", "  flagged of type Bool", "}", "end type", ""
  , "function refund (request of type RefundRequest) -> RefundDecision is"
  , "  first matching case of request:", "    when record{requestedAmount = 0} then Approved"
  , "    when it.requestedAmount > it.capturedAmount then Rejected", "    when it.flagged then ReviewRequired"
  , "    otherwise Approved", "  end case", "end function", ""
  , "law \"|an eligible flagged refund requires review| is", "  definition:"
  , "    for all (request of type RefundRequest) =>"
  , "      request.requestedAmount > 0 and"
  , "      request.requestedAmount <= request.capturedAmount and request.flagged"
  , "      implies refund request must be ReviewRequired", "    end for all", "  end definition", "end law", ""
  , "end unit" ]

refund :: [Pair] -> Value
refund fields = request (["sources" .= [object ["path" .= s "refund.lawspec", "content" .= refundSource]]] ++ fields)

lawSelector :: Text
lawSelector = "example.refunds::\"|an eligible flagged refund requires review|"

test_explanationsWordOneTypedLawInEachRegister :: Spec
test_explanationsWordOneTypedLawInEachRegister = describe "law explanations (ref:DEC-explain-registers)" $ do
  describe "registers" $ do
    it "words a compiled law in plain English by default" $ do
      let result = refund ["law" .= lawSelector]
      get "diagnostics" result `shouldBe` toJSON ([] :: [Value])
      str (get "text" result) `shouldBe` T.intercalate "\n"
        [ "Law: an eligible flagged refund requires review"
        , "For every request (a RefundRequest):"
        , "  If all of these are true:"
        , "    - the requested amount of this request is greater than 0"
        , "    - the requested amount of this request is at most its captured amount"
        , "    - this request is flagged"
        , "  then the refund for this request must be the refund decision \"review required\"." ]
      map (str . get "view") (items (get "explanations" result)) `shouldBe` ["eng"]
    it "words the same law in mathematical notation" $
      str (get "text" (refund ["law" .= lawSelector, "view" .= s "math"])) `shouldBe` T.intercalate "\n"
        [ "Law: an eligible flagged refund requires review"
        , "∀ request ∈ RefundRequest."
        , "  (request.requestedAmount > 0 ∧ request.requestedAmount ≤ request.capturedAmount ∧ request.flagged) ⇒ refund(request) = ReviewRequired" ]
    it "keeps LawSpec notation, types, identity and source in the dev register" $ do
      let shown = str (get "text" (refund ["law" .= lawSelector, "view" .= s "dev"]))
      T.lines shown `shouldBe`
        [ "example.refunds::law::\"|an eligible flagged refund requires review|"
        , "\"|an eligible flagged refund requires review|"
        , "Inputs: request of type RefundRequest"
        , "request.requestedAmount > 0 and request.requestedAmount <= request.capturedAmount and request.flagged implies refund request = ReviewRequired"
        , "Source: refund.lawspec:25:1"
        , "Examples: 0" ]
    it "structures every view as ordered sections from which the text is derived" $
      mapM_ (\view -> do
        let result = refund ["law" .= lawSelector, "view" .= viewName view]
            explanations = items (get "explanations" result)
            derived = T.intercalate "\n\n" [T.intercalate "\n" (concatMap (map str . items . get "lines") (items (get "sections" e))) | e <- explanations]
        length explanations `shouldBe` 1
        derived `shouldBe` str (get "text" result)
        [k | Object o <- explanations, k <- KM.keys o] `shouldBe` ["law", "name", "sections", "view"]
        str (get "view" (firstOf explanations)) `shouldBe` viewName view) explanationViews
    it "rejects removed and unknown views before compiling, naming the new values" $ do
      let message result = [str (get "message" d) | d <- items (get "diagnostics" result)]
      message (refund ["view" .= s "business"]) `shouldBe` ["explain view \"business\" was renamed to \"eng\"; choose --view eng|math|dev"]
      message (refund ["view" .= s "formal"]) `shouldBe` ["explain view \"formal\" was renamed to \"math\"; choose --view eng|math|dev"]
      message (refund ["view" .= s "developer"]) `shouldBe` ["explain view \"developer\" was renamed to \"dev\"; choose --view eng|math|dev"]
      message (refund ["view" .= s "evidence"]) `shouldBe`
        ["explain view \"evidence\" was removed; run lawspec evidence <unit>::<law> for a law's evidence; choose --view eng|math|dev"]
      message (refund ["view" .= s "other"]) `shouldBe` ["unknown explain view \"other\"; choose --view eng|math|dev"]
      message (refund ["law" .= s "example.refunds::missing"]) `shouldBe` ["No matching law"]
    it "presents host-completed native evidence in dev only, without changing any obligation" $ do
      let row = object ["declaration" .= s "example.refunds::law::\"|an eligible flagged refund requires review|", "stage" .= s "law"
                       , "status" .= s "property-tested", "reason" .= s "recorded"
                       , "nativeEvidence" .= object ["status" .= s "passed", "searchCompleteness" .= s "not-established", "observations" .= ([] :: [Value])]]
          dev = refund ["law" .= lawSelector, "view" .= s "dev", "evidence" .= [row]]
          eng = refund ["law" .= lawSelector, "evidence" .= [row]]
      last (T.lines (str (get "text" dev))) `shouldBe` "Native conformance: passed; search completeness: not-established"
      str (get "text" eng) `shouldBe` str (get "text" (refund ["law" .= lawSelector]))

  describe "eng wording" $ do
    let law assertion = baseLaw ["assertion" .= assertion, "inputs" .= ([] :: [Value]), "description" .= s ""]
        flags = record "flags" ["flagged", "hasItems", "requestedAmount"]
        fieldOf i t = expr (node "field" ["constructor" .= s "flags::Record", "index" .= (i :: Int), "value" .= local "f" "f"]) "f.x" t
        flagged = fieldOf 0 bool
        hasItems = fieldOf 1 bool
        amount = fieldOf 2 integer
        guarded guard = object ["kind" .= s "implies", "guard" .= guard, "body" .= object ["kind" .= s "equal", "left" .= local "f" "f", "right" .= number 1]]
        engStatement assertion = section "statement" Eng ["dataTypes" .= [flags]] (law assertion)
        andAlso a b = expr (node "shortCircuit" ["operator" .= s "&&", "left" .= a, "right" .= b]) "and" bool
        orElse a b = expr (node "shortCircuit" ["operator" .= s "||", "left" .= a, "right" .= b]) "or" bool
        notE a = expr (node "unary" ["operator" .= s "!", "argument" .= a]) "not" bool
    it "reads Boolean fields as properties, keeping a has/is verb and its negation" $ do
      engStatement (guarded flagged) `shouldBe` ["If this f is flagged, then this f must be 1."]
      engStatement (guarded (notE hasItems)) `shouldBe` ["If this f does not have items, then this f must be 1."]
      engStatement (guarded (notE (binary ">" amount (number 0)))) `shouldBe`
        ["If the requested amount of this f is not greater than 0, then this f must be 1."]
    it "lists a conjunction one requirement per line and groups mixed connectives with words" $ do
      engStatement (guarded (andAlso flagged (orElse hasItems (binary "==" amount (number 2))))) `shouldBe`
        [ "If all of these are true:", "  - this f is flagged", "  - either this f has items or the requested amount of this f is 2", "then this f must be 1." ]
    it "states nested quantifiers and negated existence as short obligations" $ do
      let exists = object ["kind" .= s "exists", "binder" .= object ["id" .= s "a", "name" .= s "approval", "type" .= bool]
                          , "predicates" .= ([] :: [Value]), "body" .= object ["kind" .= s "equal", "left" .= local "a" "approval", "right" .= number 1]]
      engStatement (object ["kind" .= s "not", "body" .= exists]) `shouldBe`
        ["There must be no approval (a true or false value) for which:", "  this approval is 1."]

  describe "owner wording decisions (2026-10-23)" $ do
    let decision = object ["id" .= s "shop::type::RefundDecision", "name" .= s "RefundDecision", "parameters" .= ([] :: [Value]), "constructors" .=
          [ object ["id" .= s "shop::type::RefundDecision::PartlyApproved", "name" .= s "PartlyApproved", "fields" .= [binder "amount" "amount"]]
          , object ["id" .= s "shop::type::RefundDecision::Rejected", "name" .= s "Rejected", "fields" .= ([] :: [Value])] ]]
        request' = record "request" ["requestedAmount", "capturedAmount"]
        types = ["dataTypes" .= [decision, request'], "units" .= functions ["refund", "sampleParcel"]]
        subject = local "r" "request"
        fieldOf i = expr (node "field" ["constructor" .= s "request::Record", "index" .= (i :: Int), "value" .= subject]) "r.x" integer
        partly = construct "shop::type::RefundDecision::PartlyApproved" [fieldOf 0]
        rejected = construct "shop::type::RefundDecision::Rejected" []
        law assertion = baseLaw ["assertion" .= assertion, "inputs" .= [object ["id" .= s "r", "name" .= s "request", "type" .= ty "request" [], "predicates" .= ([] :: [Value])]]]
        equal l r = object ["kind" .= s "equal", "left" .= l, "right" .= r]
        statementOf view assertion = section "statement" view types (law assertion)
    it "names a function as \"the <function> for <arguments>\" and a bound input as \"this <input>\"" $ do
      statementOf Eng (equal (call "refund" [subject]) rejected) `shouldBe` ["  The refund for this request must be the refund decision \"rejected\"."]
      statementOf Eng (equal (call "sampleParcel" [unitValue]) (number 1)) `shouldBe` ["  The sample parcel must be 1."]
    it "quotes a union case after its type's words and gives payload fields as owned values" $
      statementOf Eng (equal (call "refund" [subject]) partly) `shouldBe`
        ["  The refund for this request must be the refund decision \"partly approved\", with amount this request's requested amount."]
    it "reads a second field of the same subject as \"its\"" $
      statementOf Eng (object ["kind" .= s "implies", "guard" .= binary "<=" (fieldOf 0) (fieldOf 1), "body" .= equal (call "refund" [subject]) rejected])
        `shouldBe` ["  If the requested amount of this request is at most its captured amount, then the refund for this request must be the refund decision \"rejected\"."]
    it "lists sibling cases in the section data, never in the text" $ do
      let explained = explainWith Eng types (law (equal (call "refund" [subject]) partly))
          statement' = firstOf [sec | e <- items (get "explanations" explained), sec <- items (get "sections" e), str (get "kind" sec) == "statement"]
      get "cases" statement' `shouldBe` toJSON [object ["type" .= s "refund decision", "case" .= s "partly approved", "cases" .= [s "partly approved", s "rejected"]]]
      str (get "text" explained) `shouldSatisfy` (not . T.isInfixOf "\"rejected\"")
      get "cases" (firstOf [sec | e <- items (get "explanations" (explainWith Dev types (law (equal (call "refund" [subject]) partly)))), sec <- items (get "sections" e), str (get "kind" sec) == "statement"])
        `shouldBe` Null
    it "brackets dev terms only where LawSpec precedence needs them" $ do
      let a = local "a" "a"; b = local "b" "b"; c = local "c" "c"
          logical op l r = expr (node "shortCircuit" ["operator" .= s op, "left" .= l, "right" .= r]) "x" bool
          notE x = expr (node "unary" ["operator" .= s "!", "argument" .= x]) "not" bool
      render [] (logical "&&" (logical "||" a b) c) `shouldBe` "(a or b) and c"
      render [] (logical "||" a (logical "&&" b c)) `shouldBe` "a or b and c"
      render [] (logical "&&" a (logical "&&" b c)) `shouldBe` "a and (b and c)"
      render [] (notE (logical "&&" a b)) `shouldBe` "not (a and b)"
      render [] (notE (binary "==" a b)) `shouldBe` "not a = b"
      render [] (binary "*" (binary "+" a b) c) `shouldBe` "(a + b) * c"
      render [] (binary "-" a (binary "-" b c)) `shouldBe` "a - (b - c)"
      render [] (binary "==" (binary "<" a b) c) `shouldBe` "a < b = c"
      render [] (binary "<" (binary "==" a b) c) `shouldBe` "(a = b) < c"
      render ["units" .= functions ["first"]] (binary ">" (call "first" [a]) (number 0)) `shouldBe` "first a > 0"

  describe "math notation" $ do
    let law assertion inputs = baseLaw ["assertion" .= assertion, "inputs" .= inputs]
        input :: Text -> Value -> Value
        input name t = object ["id" .= name, "name" .= name, "type" .= t, "predicates" .= ([] :: [Value])]
    it "quantifies over number sets and brackets connectives beside an implication" $ do
      let guard = expr (node "shortCircuit" ["operator" .= s "||", "left" .= binary "<=" (local "n" "n") (number 0), "right" .= binary "!=" (local "n" "n") (number 3)]) "or" bool
          assertion = object ["kind" .= s "implies", "guard" .= guard, "body" .= object ["kind" .= s "equal", "left" .= local "n" "n", "right" .= local "n" "n"]]
      section "quantifiers" Math [] (law assertion [input "n" integer, input "b" bool, input "w" (ty "BigUInt" [])]) `shouldBe` ["∀ n ∈ ℤ, b ∈ 𝔹, w ∈ ℕ."]
      section "formula" Math [] (law assertion [input "n" integer]) `shouldBe` ["  (n ≤ 0 ∨ n ≠ 3) ⇒ n = n"]

  describe "typed laws in every register" $ do
    let law = baseLaw []
        result = ["evidence" .= [object ["declaration" .= s "shop::law::identity", "status" .= s "not-verified", "reason" .= s "No law verification layers selected."]]]
    it "keeps documentary metadata, references and description out of the proposition" $ do
      let references = toJSON
            [ object ["kind" .= s "law", "target" .= object ["id" .= s "shop::law::identity", "unit" .= s "shop", "name" .= s "identity"]
                     , "selector" .= object ["kind" .= s "named-reference", "name" .= s "\"|policy|"]]
            , object ["kind" .= s "function", "target" .= object ["id" .= s "shop::refund", "unit" .= s "shop", "name" .= s "refund"]]
            , object ["kind" .= s "external", "name" .= s "\"|policy|", "resource" .= s "approved wording"]
            , s "legacy citation"
            , object ["kind" .= s "law", "target" .= object ["id" .= s "prelude::law::left inverse", "unit" .= s "prelude", "name" .= s "left inverse"]] ]
          documented = baseLaw ["metadata" .= object ["id" .= s "REVIEW-001", "owner" .= s "Payments.Review"], "references" .= references]
          expected = [ "Requirement: REVIEW-001", "Owner: Payments.Review", "Reference: ref law shop.identity references.\"|policy|"
                     , "Reference: ref function shop.refund", "Reference: \"|policy|: approved wording", "Reference: legacy citation"
                     , "Reference: ref law prelude.\"|left inverse|" ]
      section "documentary" Eng result documented `shouldBe` expected
      section "documentary" Dev result documented `shouldBe` expected
      section "description" Eng result documented `shouldBe` ["A captured amount may be refunded."]
      textOf Math result documented `shouldBe` textOf Math result law
      section "statement" Eng result documented `shouldBe` section "statement" Eng result law
    it "keeps configured witnesses and searches as dev strategies, never as evidence" $ do
      let configured = baseLaw ["harness" .= object
            [ "witnesses" .= [object ["path" .= [s "amount", s "answer"], "expression" .= object ["text" .= s "amount + 1"]]]
            , "searches" .= [object ["path" .= [s "amount", s "answer"], "strategy" .= s "answers"]] ]]
      section "strategies" Dev result configured `shouldBe`
        [ "Configured witness (not completed evidence): definition.amount.answer = amount + 1"
        , "Configured search (not completed evidence): definition.amount.answer uses answers" ]
      textOf Eng result configured `shouldBe` textOf Eng result law
      textOf Math result configured `shouldBe` textOf Math result law
    it "names builtin types plainly in eng and keeps their checked names in dev" $ do
      let whole = baseLaw ["inputs" .= [object ["id" .= s "amount", "name" .= s "amount", "type" .= ty "BigUInt" [], "predicates" .= ([] :: [Value])]]]
      section "inputs" Eng result whole `shouldBe` ["For every amount (a whole number):"]
      section "inputs" Dev result whole `shouldBe` ["Inputs: amount of type Whole"]
    it "presents composed propositions from the typed logical tree" $ do
      let exists = object ["kind" .= s "exists", "binder" .= object ["id" .= s "a", "name" .= s "approval", "type" .= bool]
                          , "predicates" .= [object ["text" .= s "approval = active"]], "body" .= get "assertion" law]
          disjunction = object ["kind" .= s "not", "body" .= object ["kind" .= s "all", "items" .= [object ["kind" .= s "not", "body" .= exists], object ["kind" .= s "not", "body" .= get "assertion" law]]]]
          implication = object ["kind" .= s "not", "body" .= object ["kind" .= s "all", "items" .= [exists, object ["kind" .= s "not", "body" .= get "assertion" law]]]]
          negated = object ["kind" .= s "not", "body" .= exists]
      section "statement" Dev [] (baseLaw ["assertion" .= disjunction]) `shouldBe`
        ["there exists (approval of type Bool where approval = active) such that", "(refund amount) = (Approved)", "end exists or (refund amount) = (Approved)"]
      section "formula" Math [] (baseLaw ["assertion" .= disjunction]) `shouldBe`
        ["  (∃ approval ∈ 𝔹. (approval = active) ∧ refund amount = Approved) ∨ refund amount = Approved"]
      section "statement" Eng [] (baseLaw ["assertion" .= implication]) `shouldBe`
        [ "  If this is true:", "    There is at least one approval (a true or false value) where approval = active for which:"
        , "      refund amount is Approved", "  then:", "    refund amount must be Approved." ]
      section "statement" Dev [] (baseLaw ["assertion" .= negated]) `shouldBe`
        ["not there exists (approval of type Bool where approval = active) such that", "(refund amount) = (Approved)", "end exists"]
      section "formula" Math [] (baseLaw ["assertion" .= negated]) `shouldBe`
        ["  ¬(∃ approval ∈ 𝔹. (approval = active) ∧ refund amount = Approved)"]

  describe "type presentation" $ do
    let variable :: Text -> Value
        variable i = object ["kind" .= s "variable", "id" .= i]
        rec :: Text -> [(Text, Value)] -> [Value] -> [(Text, [Value])] -> Value
        rec i fields parameters predicates = object
          [ "id" .= i, "name" .= i, "parameters" .= parameters
          , "constructors" .= [object ["id" .= (i <> "::Record"), "name" .= s "Record"
              , "fields" .= [object ["id" .= (i <> "::Record::" <> n), "name" .= n, "type" .= t] | (n, t) <- fields]]]
          , "structure" .= object ["kind" .= s "record", "fields" .= [object ["name" .= n, "predicates" .= fromMaybe [] (lookup n predicates)] | (n, _) <- fields]] ]
    it "substitutes generic structural fields and retains nominal boundaries" $ do
      let inner = rec "inner" [("value", variable "a")] [s "a"] []
          outer = rec "outer" [("items", ty "List" [ty "inner" [variable "b"]]), ("owner", ty "shop::type::Customer" [])] [s "b"] []
          customer = object ["id" .= s "shop::type::Customer", "parameters" .= ([] :: [Value]), "constructors" .= [object ["id" .= s "Customer", "name" .= s "Customer"
                            , "fields" .= [object ["id" .= s "next", "name" .= s "next", "type" .= ty "shop::type::Customer" []]]]]]
          types = ["dataTypes" .= [inner, outer, customer]]
      typeText types (ty "outer" [integer]) `shouldBe` "record{items of type List (record{value of type Integer}), owner of type Customer}"
      typeText types (ty "shop::type::Customer" []) `shouldBe` "Customer"
      typeText types (ty "Either" [integer, ty "Maybe" [ty "BigUInt" []]]) `shouldBe` "Either Integer (Maybe Whole)"
      typeText ["dataTypes" .= [rec "empty" [] [] []]] (ty "empty" []) `shouldBe` "record{}"
    it "words Boolean restrictions with IEEE comparisons and literal contents intact" $ do
      let predicate = object ["text" .= s "original predicate", "node" .= node "shortCircuit" ["operator" .= s "||"
            , "left" .= object ["text" .= s "(NaN == NaN)", "node" .= node "binary" ["operator" .= s "==", "left" .= object ["text" .= s "NaN"], "right" .= object ["text" .= s "NaN"]]]
            , "right" .= object ["text" .= s "original negation", "node" .= node "unary" ["operator" .= s "!"
                , "argument" .= object ["text" .= s "x", "node" .= node "binary" ["operator" .= s "==", "left" .= object ["text" .= s "flags::Record::text", "node" .= node "local" ["id" .= s "flags::Record::text"]]
                                                                              , "right" .= object ["text" .= s "\"a == b && c\""]]]]]]]
      typeText ["dataTypes" .= [rec "flags" [("text", ty "Text" [])] [] [("text", [predicate])]]] (ty "flags" []) `shouldBe`
        "record{text of type (text of type Text where ((NaN = NaN) or not ((text = \"a == b && c\"))))}"
    it "keeps same-spelled nominal types distinct and unknown identities intact" $ do
      let declarations = [object ["id" .= (u <> "::type::Item"), "parameters" .= ([] :: [Value]), "constructors" .= ([] :: [Value])] | u <- ["first", "second" :: Text]]
      typeText ["dataTypes" .= declarations] (ty "first::type::Item" []) `shouldBe` "first.Item"
      typeText ["dataTypes" .= declarations] (ty "second::type::Item" []) `shouldBe` "second.Item"
      typeText [] (ty "lawspec::structural::record::unknown" []) `shouldBe` "lawspec::structural::record::unknown"
    it "keeps dependent labels, every predicate and unfamiliar restrictions" $ do
      let left = object ["text" .= s "private-lower", "node" .= node "local" ["id" .= s "range::Record::lower"]]
          right = object ["text" .= s "private-upper", "node" .= node "local" ["id" .= s "range::Record::upper"]]
          range = rec "range" [("lower", integer), ("upper", integer)] []
            [ ("lower", [object ["text" .= s "externalLowerCheck lower", "node" .= node "future-node" []]])
            , ("upper", [object ["text" .= s "(upper >= lower)", "node" .= node "binary" ["operator" .= s ">=", "left" .= right, "right" .= left]], object ["text" .= s "externalUpperCheck upper"]]) ]
      typeText ["dataTypes" .= [range]] (ty "range" []) `shouldBe`
        "record{lower of type (lower of type Integer where externalLowerCheck lower), upper of type (upper of type Integer where (upper >= lower) and externalUpperCheck upper)}"
    it "removes only generated record views and retains user computations" $ do
      let source = rec "source" [("value", integer)] [] []
          target = rec "target" [("value", integer)] [] []
          input = object ["text" .= s "reading", "node" .= node "local" ["id" .= s "subject"]]
          viewBinder = object ["id" .= s "lawspec::record-view::private", "name" .= s "private", "type" .= integer]
          view origin = object ["text" .= s "original storage view", "origin" .= origin, "node" .= node "match" ["value" .= input
            , "cases" .= [object ["constructor" .= s "source::Record", "binders" .= [viewBinder]
                , "body" .= object ["node" .= node "construct" ["constructor" .= s "target::Record", "arguments" .= [object ["text" .= s "private", "node" .= node "local" ["id" .= s "lawspec::record-view::private"]]]]]]]]]
          generated = object ["kind" .= s "generated", "declaration" .= s "lawspec::source-record"]
          domain e = rec "domain" [("reading", ty "source" [])] [] [("reading", [object ["text" .= s "x", "node" .= node "binary" ["operator" .= s ">"
            , "left" .= object ["text" .= s "x", "node" .= node "field" ["constructor" .= s "target::Record", "index" .= (0 :: Int), "value" .= e]], "right" .= object ["text" .= s "0"]]]])]
          shown e = typeText ["dataTypes" .= [source, target, domain e]] (ty "domain" [])
      shown (view generated) `shouldSatisfy` T.isInfixOf "where (reading.value > 0)"
      shown (view (object ["kind" .= s "source"])) `shouldSatisfy` T.isInfixOf "(original storage view).value"

  describe "checked terms" $ do
    let pair = ["dataTypes" .= [record "pair" ["a", "z"]]]
    it "reconstructs records in evaluation order with every computation once" $
      render ["dataTypes" .= [record "pair" ["a", "z"]], "units" .= functions ["first", "second"]]
        (letIn (binder "one" "_lawspecRecordField0") (call "first" [unitValue])
          (letIn (binder "two" "_lawspecRecordField1") (call "second" [unitValue]) (construct "pair::Record" [local "two" "two", local "one" "one"])))
        `shouldBe` "record{z = first (), a = second ()}"
    it "keeps dependent, reused and unused bindings explicit without capture" $ do
      render pair (letIn (binder "a" "x") (number 1) (letIn (binder "b" "x") (binary "+" (local "a" "x") (number 1)) (construct "pair::Record" [local "a" "a", local "b" "b"])))
        `shouldBe` "let x = 1 in let x1 = x + 1 in record{a = x, z = x1} end let end let"
      render pair (letIn (binder "a" "x") (binary "/" (number 1) (number 0)) (construct "pair::Record" [local "a" "a", local "a" "a"]))
        `shouldBe` "let x = 1 / 0 in record{a = x, z = x} end let"
      render pair (letIn (binder "a" "x") (binary "/" (number 1) (number 0)) (number 2)) `shouldBe` "let x = 1 / 0 in 2 end let"
      render pair (letIn (binder "inner" "x") (number 2) (binary "+" (local "outer" "x") (local "inner" "x"))) `shouldBe` "let x1 = 2 in x + x1 end let"
      render pair (letIn (binder "inner" "\"|amount due|") (number 2) (binary "+" (local "outer" "\"|amount due|") (local "inner" "\"|amount due|")))
        `shouldBe` "let value1 = 2 in \"|amount due| + value1 end let"
    it "keeps strict unselected fields in a projection's subject" $ do
      let box = object ["id" .= s "domain::type::Box", "constructors" .= [object ["id" .= s "Box", "name" .= s "Box", "fields" .= [binder "chosen" "chosen", binder "unused" "unused"]]]]
      render ["dataTypes" .= [box]] (term (node "match" ["value" .= construct "Box" [number 1, binary "/" (number 1) (number 0)]
        , "cases" .= [object ["constructor" .= s "Box", "binders" .= [binder "one" "one", binder "two" "two"], "body" .= local "one" "one"]]]))
        `shouldBe` "Box(chosen = 1, unused = 1 / 0).chosen"
    it "keeps distinct binders and every branch of ordered cases and callbacks" $ do
      let choice = ["dataTypes" .= [object ["id" .= s "domain::type::Choice", "constructors" .= [object ["id" .= n, "name" .= n, "fields" .= [binder "value" "value"]] | n <- [s "Left", s "Right"]]]]]
      render choice (term (node "match" ["value" .= local "subject" "choice", "cases" .=
        [ object ["constructor" .= s "Left", "binders" .= [binder "one" "x"], "body" .= binary "+" (local "outside" "x") (local "one" "x")]
        , object ["constructor" .= s "Right", "binders" .= [binder "two" "x"], "body" .= local "two" "x"] ]]))
        `shouldBe` "first matching case of choice: when domain.Choice.Left x1 then x + x1 when domain.Choice.Right x1 then x1 end case"
      render pair (term (node "match" ["value" .= local "pair" "pair", "cases" .= [object ["constructor" .= s "pair::Record"
        , "binders" .= [binder "one" "a", binder "two" "z"], "body" .= binary "+" (local "one" "a") (local "two" "z")]]]))
        `shouldBe` "first matching case of pair: when record{a = a, z = z} then a + z end case"
      render choice (term (node "allElements" ["value" .= local "items" "items", "binder" .= binder "item" "x", "predicate" .= binary ">" (local "item" "x") (local "outside" "x")]))
        `shouldBe` "every x1 in (items) satisfies (x1 > x)"
      render choice (term (node "allPayloads" ["value" .= local "items" "items", "predicates" .=
        [ object ["binder" .= binder "one" "x", "predicate" .= binary ">" (local "one" "x") (local "outside" "x")]
        , object ["binder" .= binder "two" "x", "predicate" .= local "two" "x"] ]]))
        `shouldBe` "allPayloads (items) [x1 of type Integer => x1 > x; x1 of type Integer => x1]"
    it "resolves global names by identity with qualification and phrase spelling" $ do
      let units = ["units" .= [ object ["id" .= s "first", "declarations" .= [object ["id" .= s "f", "name" .= s "send notice"], object ["id" .= s "single", "name" .= s "check"]]]
                              , object ["id" .= s "second", "declarations" .= [object ["id" .= s "g", "name" .= s "send notice"]]] ]]
      render units (term (node "call" ["declaration" .= s "f", "arguments" .= [unitValue]])) `shouldBe` "first.\"|send notice| ()"
      render units (binary "+" (local "input" "check") (term (node "call" ["declaration" .= s "single", "arguments" .= [unitValue]])))
        `shouldBe` "check + first.check ()"
      renderIn ["units" .= [ object ["id" .= s "owner", "declarations" .= [object ["id" .= s "owner::check", "name" .= s "check"]]]
                           , object ["id" .= s "importer", "declarations" .= [object ["id" .= s "owner::check", "name" .= s "check"]]] ]]
        [("input", "check")] (term (node "call" ["declaration" .= s "owner::check", "arguments" .= ([] :: [Value])])) `shouldBe` "owner.check"
      let alternatives = ["dataTypes" .= [object ["id" .= ("domain::type::" <> n), "constructors" .= [object ["id" .= (n <> "::Yes"), "name" .= s "Yes", "fields" .= ([] :: [Value])]]] | n <- ["One", "Two" :: Text]]]
      render alternatives (construct "One::Yes" []) `shouldBe` "domain.One.Yes"
      render alternatives (construct "Two::Yes" []) `shouldBe` "domain.Two.Yes"
    it "keeps Boolean precedence, literal contents, conversions and effect modes explicit" $ do
      let text = expr (node "constant" ["value" .= object ["type" .= s "Text", "value" .= s "a == b"]]) "\"a == b\"" integer
          perform = term (node "perform" ["ability" .= s "Log", "operation" .= s "write", "arguments" .= [text]])
      render [] (binary "==" (term (node "unary" ["operator" .= s "!", "argument" .= local "enabled" "enabled"])) (local "other" "other")) `shouldBe` "(not enabled) = other"
      render [] (binary "==" text text) `shouldBe` "\"a == b\" = \"a == b\""
      mapM_ (\c -> render [] (term (node "convert" ["conversion" .= c, "argument" .= local "input" "input"])) `shouldBe` (c <> " conversion of (input) to Integer")) ["explicit", "checked"]
      render [] perform `shouldBe` "perform Log.write(\"a == b\")"
      render [] (term (node "handle" ["handling" .= s "catchFailure", "ability" .= s "Fail", "body" .= perform])) `shouldBe` "catch failure of Fail in (perform Log.write(\"a == b\"))"
      render [] (term (node "handle" ["handling" .= s "withHandler", "ability" .= s "Log", "handler" .= s "recording native", "body" .= perform]))
        `shouldBe` "handle (perform Log.write(\"a == b\")) with recording native for Log end handle"
      render [] (term (node "calls" ["ability" .= s "Log", "operation" .= s "write", "arguments" .= Null])) `shouldBe` "calls of Log.write"
      render [] (term (node "calls" ["ability" .= s "Log", "operation" .= s "write", "arguments" .= ([] :: [Value])])) `shouldBe` "calls of Log.write with ()"
      render pair (term (node "update" ["constructor" .= s "pair::Record", "index" .= (1 :: Int), "value" .= term (node "helper" ["name" .= s "prelude.load", "arguments" .= [unitValue]]), "field" .= number 7]))
        `shouldBe` "(prelude.load ()) with z = 7"
      render [] (term (node "if" ["condition" .= local "enabled" "enabled", "then" .= perform, "else" .= number 0])) `shouldBe` "if enabled then perform Log.write(\"a == b\") else 0 end if"
    it "falls back as a whole before renaming any binder" $ do
      let child = expr (node "future-node" []) "x" integer
          opaque = object ["node" .= node "let" ["binder" .= binder "x" "_lawspecTemporary", "value" .= number 1, "body" .= child]
                          , "text" .= s "original let _lawspecTemporary = 1 in opaque(_lawspecTemporary)", "type" .= integer]
      render [] opaque `shouldBe` "original let _lawspecTemporary = 1 in opaque(_lawspecTemporary)"
      render [] (expr (node "call" ["declaration" .= s "unknown", "arguments" .= [local "x" "x"]]) "original unknown call" integer) `shouldBe` "original unknown call"
    it "names abilities by checked source identity and keeps unresolved argument keys" $ do
      let units = [object ["id" .= s "one", "declarations" .= ([] :: [Value]), "abilities" .= [object ["id" .= s "one::ability::Gateway", "name" .= s "Gateway"]]]]
          perform :: Text -> Value
          perform ability = term (node "perform" ["ability" .= ability, "operation" .= s "capture", "arguments" .= [number 1]])
      render ["units" .= units] (perform "one::ability::Gateway") `shouldBe` "perform Gateway.capture(1)"
      render ["units" .= units] (perform "one::ability::Gateway(opaque::type::Payload)") `shouldBe` "perform Gateway(opaque::type::Payload).capture(1)"
      render ["units" .= (units ++ [object ["id" .= s "two", "declarations" .= ([] :: [Value]), "abilities" .= [object ["id" .= s "two::ability::Gateway", "name" .= s "Gateway"]]]])]
        (perform "one::ability::Gateway") `shouldBe` "perform one.Gateway.capture(1)"
    it "names specializations by source once and qualifies independent declarations" $ do
      let use = object ["id" .= s "use", "declarations" .=
            [ object ["id" .= s "use::specialized_1", "name" .= s "generated_1", "source" .= object ["unit" .= s "library", "name" .= s "echo"]]
            , object ["id" .= s "use::specialized_2", "name" .= s "generated_2", "source" .= object ["unit" .= s "library", "name" .= s "echo"]] ]]
          other = object ["id" .= s "other", "declarations" .= [object ["id" .= s "other::echo", "name" .= s "echo", "source" .= object ["unit" .= s "other", "name" .= s "echo"]]]]
          echo i n = term (node "call" ["declaration" .= i, "arguments" .= [number n]])
      render ["units" .= [use]] (echo (s "use::specialized_1") 1) `shouldBe` "echo 1"
      render ["units" .= [use]] (echo (s "use::specialized_2") 2) `shouldBe` "echo 2"
      render ["units" .= [use, other]] (echo (s "use::specialized_1") 1) `shouldBe` "library.echo 1"
    let listType = ty "List" [integer]
        nil = expr (node "construct" ["constructor" .= s "List::Nil", "arguments" .= ([] :: [Value])]) "Nil" listType
        cons h t = expr (node "construct" ["constructor" .= s "List::Cons", "arguments" .= [h, t]]) "Cons" listType
    it "flattens complete lists only, keeping strict items and unknown tails" $ do
      render [] (cons (binary "/" (number 1) (number 0)) (cons (number 2) nil)) `shouldBe` "[1 / 0, 2]"
      render [] (cons (number 1) (expr (node "helper" ["name" .= s "unknownTail", "arguments" .= ([] :: [Value])]) "tail" listType)) `shouldBe` "Cons(head = 1, tail = unknownTail)"
    it "uses set notation only for declarations the compiler names as set constructors" $ do
      let units = ["units" .= [object ["id" .= s "use", "declarations" .=
            [ object ["id" .= s "use::trusted", "name" .= s "mangled", "source" .= object ["unit" .= s "lawspec.collections", "name" .= s "eqSetOf", "canonicalName" .= s "prelude.setOf"]]
            , object ["id" .= s "use::fake", "name" .= s "lawspec_lawspecCollectionsEqSetOf_123"] ]]]]
          setOf i argument = term (node "call" ["declaration" .= s i, "arguments" .= [argument]])
      render units (setOf "use::trusted" (cons (number 1) nil)) `shouldBe` "#S{1}"
      render units (setOf "use::fake" (cons (number 1) nil)) `shouldBe` "lawspec_lawspecCollectionsEqSetOf_123 [1]"
      render units (setOf "use::trusted" (expr (node "helper" ["name" .= s "buildItems", "arguments" .= ([] :: [Value])]) "buildItems" listType)) `shouldBe` "prelude.setOf buildItems"
    it "presents membership with strict values once and keeps dependent bindings" $ do
      let stored = object ["id" .= s "stored", "name" .= s "collection", "type" .= listType]
          value = expr (node "local" ["id" .= s "stored"]) "collection" listType
          differs = expr (node "binary" ["operator" .= s "!=", "left" .= local "needle" "needle", "right" .= local "item" "item"]) "differs" bool
          found = expr (node "unary" ["operator" .= s "!", "argument" .= expr (node "allElements" ["value" .= value, "binder" .= binder "item" "item", "predicate" .= differs]) "every" bool]) "found" bool
          units = ["units" .= functions ["first", "make"]]
      render units (letIn (binder "needle" "needle") (call "first" [unitValue]) (letIn stored (cons (number 1) nil) found)) `shouldBe` "first () in [1]"
      render units (letIn (binder "needle" "needle") (call "first" [unitValue]) (letIn stored (call "make" [local "needle" "needle"]) found))
        `shouldSatisfy` T.isPrefixOf "let needle = first () in let collection = make needle in "
    it "keeps callback scope and polarity of finite existential iteration" $ do
      let bound = binder "inner" "~lawspecAnyItem"
          predicate = expr (node "binary" ["operator" .= s ">", "left" .= local "inner" "inner", "right" .= local "outside" "value"]) "predicate" bool
          inverted = expr (node "unary" ["operator" .= s "!", "argument" .= predicate]) "not predicate" bool
          every = expr (node "allElements" ["value" .= nil, "binder" .= bound, "predicate" .= inverted]) "every" bool
      render [] (expr (node "unary" ["operator" .= s "!", "argument" .= every]) "not every" bool) `shouldBe` "any value1 in ([]) satisfies (value1 > value)"
    it "shows stored set values in set notation without repairing arbitrary storage" $ do
      let setType = ty "lawspec.collections::type::EqSet" [integer]
          constructor = s "lawspec.collections::type::EqSet::EqSetItems"
          types = ["dataTypes" .= [object ["id" .= s "lawspec.collections::type::EqSet", "name" .= s "Set", "parameters" .= ([] :: [Value]), "constructors" .=
            [object ["id" .= constructor, "name" .= s "EqSetItems", "fields" .= [object ["id" .= s "items", "name" .= s "items", "type" .= listType]]]]]]]
          one = object ["type" .= s "Integer", "value" .= s "1"]
          stored = object ["kind" .= s "data", "type" .= setType, "constructor" .= constructor, "fields" .= [object ["kind" .= s "data", "type" .= listType
            , "constructor" .= s "List::Cons", "fields" .= [one, object ["kind" .= s "data", "type" .= listType, "constructor" .= s "List::Nil", "fields" .= ([] :: [Value])]]]]]
          exampleLaw = baseLaw ["examples" .= [object ["name" .= s "stored", "bindings" .= [object ["id" .= s "v", "name" .= s "v", "value" .= stored]], "expectations" .= ([] :: [Value])]]]
      section "examples" Dev types exampleLaw `shouldBe` ["Examples: 1", "example \"|stored|:", "  v = #S{1}", "end example"]
      render types (expr (node "construct" ["constructor" .= constructor, "arguments" .= [cons (number 1) (cons (number 1) nil)]]) "storage" setType)
        `shouldBe` "EqSetItems(items = [1, 1])"

  describe "positions and representations" $ do
    let tupleType = ty "tuple" []
        mocked :: Maybe Value -> Value
        mocked positions = object (
          [ "id" .= s "tuple", "name" .= s "TupleStorage", "parameters" .= ([] :: [Value])
          , "constructors" .= [object ["id" .= s "tuple::Record", "name" .= s "Record", "fields" .=
              [object ["id" .= s "right", "name" .= s "second", "type" .= bool], object ["id" .= s "left", "name" .= s "first", "type" .= integer]]]] ]
          ++ [ "structure" .= object ["kind" .= s "record", "positions" .= p, "fields" .= [object ["name" .= n, "predicates" .= ([] :: [Value])] | n <- [s "first", s "second"]]]
             | Just p <- [positions] ])
        tuple = ["dataTypes" .= [mocked (Just (toJSON [s "first", s "second"]))]]
        effect operation = expr (node "perform" ["ability" .= s "Trace", "operation" .= s operation, "arguments" .= ([] :: [Value])]) ("effect " <> operation) tupleType
    it "obeys explicit tuple positions while keeping computations in actual order" $ do
      typeText tuple tupleType `shouldBe` "(Integer, Bool)"
      let stored = object ["kind" .= s "data", "type" .= tupleType, "constructor" .= s "tuple::Record"
                          , "fields" .= [object ["type" .= s "Bool", "value" .= True], object ["type" .= s "Integer", "value" .= (7 :: Int)]]]
          exampleLaw = baseLaw ["examples" .= [object ["name" .= s "t", "bindings" .= [object ["id" .= s "v", "name" .= s "v", "value" .= stored]], "expectations" .= ([] :: [Value])]]]
      section "examples" Dev tuple exampleLaw `shouldBe` ["Examples: 1", "example \"|t|:", "  v = (7, true)", "end example"]
      render tuple (expr (node "construct" ["constructor" .= s "tuple::Record", "arguments" .= [effect "second", effect "first"]]) "ordered construction" tupleType)
        `shouldSatisfy` T.isInfixOf "let component2 = perform Trace.second() in let component1 = perform Trace.first() in (component1, component2)"
      renderIn tuple [("input", "reading")] (expr (node "field" ["constructor" .= s "tuple::Record", "index" .= (1 :: Int), "value" .= expr (node "local" ["id" .= s "input"]) "input" tupleType]) "projection" tupleType)
        `shouldSatisfy` T.isInfixOf "first matching case of reading: when (component, #any) then component end case"
      let update = render tuple (expr (node "update" ["constructor" .= s "tuple::Record", "index" .= (1 :: Int), "value" .= effect "subject", "field" .= effect "replacement"]) "update" tupleType)
      T.length (fst (T.breakOn "Trace.replacement" update)) < T.length (fst (T.breakOn "Trace.subject" update)) `shouldBe` True
    it "keeps structural and nominal identities when position metadata is invalid or missing" $ do
      mapM_ (\positions -> typeText ["dataTypes" .= [mocked (Just positions)]] tupleType `shouldBe` "record{second of type Bool, first of type Integer}")
        [Null, toJSON ([] :: [Text]), toJSON [s "first", s "first"], toJSON [s "missing", s "second"]]
      typeText ["dataTypes" .= [mocked Nothing]] tupleType `shouldBe` "TupleStorage"
    it "hides only compiler-marked representation calls with matching full signatures" $ do
      content <- readFile "test/fixtures/canonical-container-records.lawspec"
      let expanded = request ["method" .= s "expand", "sources" .= [object ["path" .= s "container.lawspec", "content" .= content]]]
          declarations = concatMap (items . get "declarations") (items (get "units" expanded))
          marked = firstOf [d | d <- declarations, str (get "representation" d) == "structural-record-storage"]
          generated = object ["kind" .= s "generated", "declaration" .= s "example"]
          argument = object ["type" .= get "parameter" (get "type" marked), "origin" .= generated, "text" .= s "readings", "node" .= node "local" ["id" .= s "readings"]]
          storageCall t = object ["type" .= t, "origin" .= generated, "text" .= s "explicit checked storage call"
                                 , "node" .= node "call" ["declaration" .= get "id" marked, "arguments" .= [argument]]]
          base = [(k, v) | Object o <- [expanded], (k, v) <- KM.toList o, k `elem` ["dataTypes", "units"]]
          unmarked = [(k, if k == "units" then stripRepresentation v else v) | (k, v) <- base]
          shown result t = renderIn result [("readings", "readings")] (storageCall t)
      shown base (get "result" (get "type" marked)) `shouldBe` "readings"
      shown unmarked (get "result" (get "type" marked)) `shouldSatisfy` T.isInfixOf "lawspecRecordView"
      shown base bool `shouldSatisfy` T.isInfixOf "lawspecRecordView"
  where
    stripRepresentation units = toJSON [ case unit of
      Object o -> Object (KM.insert "declarations" (toJSON [case d of { Object x -> Object (KM.delete "representation" x); other -> other } | d <- items (get "declarations" unit)]) o)
      other -> other | unit <- items units ]
