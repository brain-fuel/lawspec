-- | Bounded, read-only authoring suggestions over resolved Core. These are
-- neither semantic diagnostics nor verification evidence. No solver is run.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring (adviceView, preludeView, PreludeEntry (..), PreludeResult (..), PreludeQuery (..), queryPrelude, prelude) where

import Data.Aeson
import Data.Char (toLower)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import LawSpec.Common (Diagnostic (..), Source (..))
import qualified LawSpec.Core as C
import LawSpec.Core.Vacuity (GuardAdvice (..), programGuardAdvice)
import LawSpec.Prelude (preludeSource)
import LawSpec.PreludeNames (preludeDefinitionTarget, publicPreludeNames)
import LawSpec.Scalar (Scalar (..), isNumeric, primitiveName, primitives)
import LawSpec.SourceSyntax (SourceSyntax (..), SyntaxNode (..))

-- | Typed discovery result shared by the JSON and WIT interfaces.
-- ref:DEC-haskell-application-port
data PreludeEntry
  = PreludeOperation String String (Maybe String)
  | PreludeLaw String String
  deriving (Eq, Show)

-- | A catalog retains the authoritative source used by law discovery.
data PreludeResult = PreludeResult
  {preludeEntries :: [PreludeEntry], preludeLawSource :: String}
  deriving (Eq, Show)

-- | Boundary decoding distinguishes absent queries from malformed values.
data PreludeQuery = PreludeAll | PreludeMatching String | PreludeInvalid
  deriving (Eq, Show)

-- | Malformed queries are compiler request diagnostics, not host failures.
queryPrelude :: PreludeQuery -> Either [Diagnostic] PreludeResult
queryPrelude query = case query of
  PreludeAll -> Right (prelude "")
  PreludeMatching text -> Right (prelude text)
  PreludeInvalid -> Left [Diagnostic "request" "prelude query must be a string" Nothing]

instance ToJSON PreludeEntry where
  toJSON entry = case entry of
    PreludeOperation name qualified definition ->
      object
        [ "kind" .= ("operation" :: String),
          "name" .= name,
          "qualifiedName" .= qualified,
          "definition" .= definition
        ]
    PreludeLaw name source ->
      object
        ["kind" .= ("law" :: String), "name" .= name, "source" .= source]

instance ToJSON PreludeResult where
  toJSON (PreludeResult entries source) =
    object
      [ "schemaVersion" .= (5 :: Int),
        "diagnostics" .= ([] :: [Value]),
        "entries" .= entries,
        "lawSource" .= source
      ]

-- | Preserve the existing search domain, including the legacy entry rendering.
-- Only this compatibility search projection uses the JSON view; neither service
-- requests nor service results pass through a JSON dispatcher or decoder.
prelude :: String -> PreludeResult
prelude query = PreludeResult (filter selected (operations ++ laws)) (content preludeSource)
  where
    selected entry = map toLower query `isInfixOf` map toLower (show (toJSON entry))
    operations =
      [ PreludeOperation
          name
          ("prelude." ++ name)
          (fmap (\(owner, definition) -> owner ++ "::" ++ definition) (preludeDefinitionTarget True name))
      | name <- sort (nub (publicPreludeNames ++ [primitiveName p | p <- primitives, isNumeric (primitiveName p)]))
      ]
    laws =
      [ PreludeLaw (drop 4 line) "prelude"
      | line <- lines (content preludeSource),
        "law " `isPrefixOf` line
      ]

preludeView :: String -> Value
preludeView = toJSON . prelude

adviceView :: [SourceSyntax] -> C.Program -> Value
adviceView syntax program =
  object
    [ "findings" .= nub (concatMap unitFindings (C.programUnits program)),
      "checks"
        .= ( [ object ["rule" .= (rule :: String), "status" .= ("complete" :: String), "scope" .= (scope :: String)]
             | (rule, scope) <-
                 [ ("prelude-helper", "recursive List length and membership shapes"),
                   ("prelude-law", "unrestricted unary idempotence and left-inverse equations"),
                   ("vacuous-guard", "regex and literal-list guards on a directly quantified input"),
                   ("adapter-guard", "guards that call an adapter on a quantified input"),
                   ("enumerable-digest", "fields shown as digest whose restriction is a regex, a literal list, a length bound or an equation, counted up to 2^64 values")
                 ]
             ]
               ++ missing
           ),
      "meaning" .= ("Structural suggestions only; no semantic equivalence proof or native execution." :: String)
    ]
  where
    known =
      [ source
      | unit <- C.programUnits program,
        definition <- C.unitDefinitions unit,
        let declaration = C.definitionDeclaration definition,
        source <- maybe [(C.idText (C.unitId unit), C.declarationName declaration)] pure (C.declarationSource declaration)
      ]
    missing =
      [ object
          [ "rule" .= ("prelude-helper" :: String),
            "status" .= ("incomplete" :: String),
            "declaration" .= (owner ++ "::" ++ name),
            "reason" .= ("No executable typed Core instance is available for this definition template; generic-template helper analysis is incomplete." :: String)
          ]
      | (owner, name) <-
          nub
            [ (syntaxUnit source, name)
            | source <- syntax,
              node <- syntaxNodes source,
              syntaxKind node == "declaration.definition",
              Just name <- [syntaxName node]
            ],
        (owner, name) `notElem` known
      ]

    unitFindings unit = concatMap definitionFindings (C.unitDefinitions unit) ++ concatMap lawFindings (C.unitProperties unit) ++
      concatMap guardFindings (C.unitProperties unit)
    -- Guards generation cannot be expected to satisfy (LawSpec.Core.Vacuity).
    -- ref:DEC-vacuous-outcome
    guardFindings law =
      [ object
          [ "rule" .= adviceRule advice,
            "declaration" .= C.idText (C.propertyId law),
            "severity" .= ("warning" :: String),
            "suggestion" .= adviceSuggestion advice,
            "message" .= adviceMessage advice,
            "status" .= ("unresolved" :: String)
          ]
      | advice <- programGuardAdvice program law
      ]
    finding rule declaration suggestion =
      object
        [ "rule" .= (rule :: String),
          "declaration" .= C.idText declaration,
          "severity" .= ("warning" :: String),
          "suggestion" .= suggestion,
          "message" .= ("Consider " ++ suggestion ++ "; retain custom logic when its domain meaning differs."),
          "status" .= ("unresolved" :: String)
        ]
    definitionFindings definition
      | Just source <- C.declarationSource declaration,
        source `elem` [provider | name <- publicPreludeNames, Just provider <- [preludeDefinitionTarget True name]] =
          []
      | otherwise =
          [ finding "prelude-helper" authored ("prelude." ++ name)
          | name <- helperShape self (C.definitionArguments definition) (C.definitionBody definition)
          ]
      where
        declaration = C.definitionDeclaration definition
        self = C.declarationId declaration
        authored = maybe self (\(owner, name) -> C.Id (owner ++ "::" ++ name)) (C.declarationSource declaration)
    lawFindings law
      | length (C.propertyTrace law) > 1 = []
      | [input] <- C.propertyInputs law,
        null (C.quantifiedPredicates input),
        null (C.quantifiedBounds input),
        C.Equation _ left right <- C.propertyBody law =
          [ finding "prelude-law" (C.propertyId law) template
          | template <- equationShape (C.binderId (C.quantifiedBinder input)) left right
          ]
      | otherwise = []

local :: C.Id -> C.Expr -> Bool
local identity value = case C.expressionNode value of
  C.Local found -> identity == found
  _ -> False

integer :: Integer -> C.Expr -> Bool
integer expected value = case C.expressionNode value of
  C.Constant (SInteger _ actual) -> actual == expected
  _ -> False

boolean :: Bool -> C.Expr -> Bool
boolean expected value = case C.expressionNode value of
  C.Constant (SBool actual) -> actual == expected
  _ -> False

-- Constructor identities refer to the compiler's built-in List, not spelling
-- in the source namespace. Other recursion shapes are outside this rule.
helperShape :: C.Id -> [C.Binder] -> C.Expr -> [String]
helperShape self arguments body
  | C.Let binder value inner <- C.expressionNode body,
    C.Local original <- C.expressionNode value =
      helperShape self [if C.binderId arg == original then arg {C.binderId = C.binderId binder} else arg | arg <- arguments] inner
  | otherwise = case (arguments, C.expressionNode body) of
      ([xs], C.Match value [empty, cons])
        | local (C.binderId xs) value,
          listCases empty cons,
          integer 0 (C.caseBody empty),
          [_, tailBinder] <- C.caseBinders cons,
          C.Binary C.Add _ one recurse <- C.expressionNode (C.caseBody cons),
          integer 1 one,
          C.ExternalCall called [tailValue] <- C.expressionNode recurse,
          called == self,
          local (C.binderId tailBinder) tailValue,
          C.expressionType body == C.scalarType "Integer" ->
            ["length"]
      ([needle, xs], C.Match value [empty, cons])
        | local (C.binderId xs) value,
          listCases empty cons,
          boolean False (C.caseBody empty),
          [headBinder, tailBinder] <- C.caseBinders cons,
          C.If condition yes no <- C.expressionNode (C.caseBody cons),
          boolean True yes,
          C.Binary C.Equal _ left right <- C.expressionNode condition,
          local (C.binderId needle) left,
          local (C.binderId headBinder) right,
          C.ExternalCall called [first, rest] <- C.expressionNode no,
          called == self,
          local (C.binderId needle) first,
          local (C.binderId tailBinder) rest ->
            ["member"]
      _ -> []
  where
    listCases empty cons = C.caseConstructor empty == C.Id "List::Nil" && C.caseConstructor cons == C.Id "List::Cons"

equationShape :: C.Id -> C.Expr -> C.Expr -> [String]
equationShape input left right = case (C.expressionNode left, C.expressionNode right) of
  (C.ExternalCall outer [inner], C.ExternalCall other [value])
    | C.ExternalCall nested [argument] <- C.expressionNode inner,
      outer == nested,
      outer == other,
      local input argument,
      local input value ->
        ["apply law \"|idempotent| <function>"]
  (C.ExternalCall _ [inner], C.Local result)
    | C.ExternalCall _ [argument] <- C.expressionNode inner,
      result == input,
      local input argument ->
        ["apply law \"|left inverse| <outer> <inner>"]
  _ -> []
