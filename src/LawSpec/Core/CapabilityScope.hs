-- | Lexical typing assumptions for a polymorphic declaration or law. These
-- authorize operations, not equality/order laws, witnesses or generators.
-- Ordinary executable Core is checked with the empty context. Symbolic
-- comparison keeps the admitted source schemes separately anchored.
module LawSpec.Core.CapabilityScope
  ( Capabilities(..), noCapabilities, CapabilityScopes, scopedRegistry ) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core (Id)
import qualified LawSpec.Core.Types as Types

data Capabilities = Capabilities
  { equalityVariables :: S.Set Id, keyedVariables :: S.Set Id }
  deriving (Eq,Show)

noCapabilities :: Capabilities
noCapabilities=Capabilities S.empty S.empty

type CapabilityScopes=M.Map Id Capabilities

scopedRegistry :: CapabilityScopes -> Id -> Types.TypeRegistry -> Types.TypeRegistry
scopedRegistry scopes owner registry =
  let Capabilities equality keyed=M.findWithDefault noCapabilities owner scopes
  in Types.assumingCapabilities equality keyed registry
