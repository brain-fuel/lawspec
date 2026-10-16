-- | Source grammar inventory for migration and authoring tools. These nodes
-- describe parsed syntax, not a second typed or executable representation.
-- Clients receive them only after the ordinary compiler checks succeed.
module LawSpec.SourceSyntax (SourceSyntax(..), SyntaxNode(..), SyntaxBinding(..), SyntaxReference(..), sourceSyntax) where

import LawSpec.Common (Span(..), Location(..))
import Data.Aeson (ToJSON(..), object, (.=))
import qualified Data.Set as Set

data SyntaxNode = SyntaxNode
  { syntaxKind :: String, syntaxName :: Maybe String, syntaxSpan :: Span
  -- Checked declaration context, attached by the existing ability inference
  -- after validation. In particular, an unused template can still use effects.
  , syntaxUses :: Maybe [String] }
  deriving (Eq, Show)

data SourceSyntax = SourceSyntax
  { syntaxPath :: FilePath, syntaxUnit :: String, syntaxNodes :: [SyntaxNode]
  , syntaxBindings :: [SyntaxBinding], syntaxReferences :: [SyntaxReference] }
  deriving (Eq, Show)

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
sourceSyntax path unit nodes = SourceSyntax path unit (unique Set.empty nodes) [] []
  where
    unique _ [] = []
    unique seen (node:rest)
      | key node `Set.member` seen = unique seen rest
      | otherwise = node : unique (Set.insert (key node) seen) rest
    key node = let Span (Location a b c) (Location d e f) = syntaxSpan node
      in (syntaxKind node,syntaxName node,a,b,c,d,e,f)

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
