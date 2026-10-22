-- | Source grammar inventory for authoring tools. These nodes
-- describe parsed syntax, not a second typed or executable representation.
-- Checked compiler responses add resolved context after validation. The
-- formatter may use the parser's block inventory without typed bindings.
module LawSpec.SourceSyntax (SourceSyntax(..), SyntaxNode(..), SyntaxBinding(..), SyntaxReference(..), MatchWarning(..), sourceSyntax) where

import LawSpec.Common (Span(..), Location(..))
import Data.Aeson (ToJSON(..), object, (.=))
import qualified Data.Set as Set
import Data.List (sortOn)

data SyntaxNode = SyntaxNode
  { syntaxKind :: String, syntaxName :: Maybe String, syntaxSpan :: Span
  -- Checked declaration context, attached by the existing ability inference
  -- after validation. In particular, an unused template can still use effects.
  , syntaxUses :: Maybe [String] }
  deriving (Eq, Show)

data SourceSyntax = SourceSyntax
  { syntaxPath :: FilePath, syntaxUnit :: String, syntaxNodes :: [SyntaxNode]
  , syntaxBindings :: [SyntaxBinding], syntaxReferences :: [SyntaxReference]
  -- Private authoring findings; the public source inventory stays independent
  -- of optional diagnostics. They never become typed or executable terms.
  , syntaxMatchWarnings :: [MatchWarning] }
  deriving (Eq, Show)

-- | Proven structural shadowing from the existing ordered pattern matrix.
-- No finding asserts that every other branch is reachable.
data MatchWarning = MatchWarning
  { matchWarningCode :: String, matchWarningMessage :: String
  , matchWarningSpan :: Span } deriving (Eq, Show)

-- Declaration/import namespace entries from Imports, in that resolver's
-- portable naming convention. These are not lexical locals or typed terms.
data SyntaxBinding = SyntaxBinding
  { bindingNamespace :: String, bindingName :: String, bindingTarget :: String
  , bindingDeclaration :: Maybe String }
  deriving (Eq, Show)

-- A free value occurrence observed by the existing import traversal with its
-- actual lexical scope. Bound parameters, patterns and lets are excluded.
data SyntaxReference = SyntaxReference
  { referenceName :: String, referenceTarget :: String, referenceSpan :: Span
  , referenceDeclaration :: Maybe String }
  deriving (Eq, Show)

-- Nested location wrappers may describe the same syntactic expression. Keep
-- its first record without changing the grammar's order of distinct nodes.
sourceSyntax :: FilePath -> String -> [SyntaxNode] -> SourceSyntax
sourceSyntax path unit nodes = SourceSyntax path unit ordinary [] [] warnings
  where
    captured = unique Set.empty nodes
    ordinary = [node | node <- captured, syntaxKind node `notElem` warningKinds]
    warningKinds = ["match-warning.unreachable", "match-warning.fallback"]
    warnings = sortOn warningPosition
      [MatchWarning code message (syntaxSpan node) | node <- captured,
        Just (code,message) <- [case syntaxKind node of
          "match-warning.unreachable" -> Just ("case-unreachable", "Earlier patterns cover this branch, so it cannot be selected.")
          "match-warning.fallback" -> Just ("case-unnecessary-fallback", "Earlier patterns cover this fallback's inputs, so it cannot be selected.")
          _ -> Nothing]]
    warningPosition warning = case matchWarningSpan warning of
      Span (Location file line column) _ -> (file,line,column,matchWarningCode warning)
    unique _ [] = []
    unique seen (node:rest)
      | key node `Set.member` seen = unique seen rest
      | otherwise = node : unique (Set.insert (key node) seen) rest
    key node = let Span (Location a b c) (Location d e f) = syntaxSpan node
      in (syntaxKind node,syntaxName node,a,b,c,d,e,f)

instance ToJSON MatchWarning where
  toJSON warning = object
    ["code" .= matchWarningCode warning, "message" .= matchWarningMessage warning,
     "severity" .= ("warning" :: String), "at" .= spanStart (matchWarningSpan warning),
     "span" .= object ["start" .= spanStart (matchWarningSpan warning),
                        "end" .= spanEnd (matchWarningSpan warning)]]

instance ToJSON SyntaxNode where
  toJSON node = object
    (["kind" .= syntaxKind node, "span" .= object
       ["start" .= spanStart (syntaxSpan node),"end" .= spanEnd (syntaxSpan node)]] ++
     ["name" .= name | Just name <- [syntaxName node]] ++
     ["uses" .= uses | Just uses <- [syntaxUses node]])

instance ToJSON SourceSyntax where
  toJSON source = object
    [ "version" .= (1 :: Int), "path" .= syntaxPath source
    , "unit" .= syntaxUnit source, "nodes" .= syntaxNodes source
    , "bindings" .= syntaxBindings source,"references" .= syntaxReferences source ]

instance ToJSON SyntaxBinding where
  toJSON binding = object
    (["namespace" .= bindingNamespace binding,"name" .= bindingName binding,"target" .= bindingTarget binding] ++
     ["declaration" .= declaration | Just declaration <- [bindingDeclaration binding]])

instance ToJSON SyntaxReference where
  toJSON reference = object
    (["name" .= referenceName reference,"target" .= referenceTarget reference,
     "span" .= object ["start" .= spanStart (referenceSpan reference),"end" .= spanEnd (referenceSpan reference)]] ++
     ["declaration" .= declaration | Just declaration <- [referenceDeclaration reference]])
