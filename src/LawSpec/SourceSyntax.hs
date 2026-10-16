-- | Source grammar inventory for migration and authoring tools. These nodes
-- describe parsed syntax, not a second typed or executable representation.
-- Clients receive them only after the ordinary compiler checks succeed.
module LawSpec.SourceSyntax (SourceSyntax(..), SyntaxNode(..), sourceSyntax) where

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
  { syntaxPath :: FilePath, syntaxUnit :: String, syntaxNodes :: [SyntaxNode] }
  deriving (Eq, Show)

-- Nested location wrappers may describe the same syntactic expression. Keep
-- its first record without changing the grammar's order of distinct nodes.
sourceSyntax :: FilePath -> String -> [SyntaxNode] -> SourceSyntax
sourceSyntax path unit nodes = SourceSyntax path unit (unique Set.empty nodes)
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
    , "unit" .= syntaxUnit source, "nodes" .= syntaxNodes source ]
