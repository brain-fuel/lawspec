{-# OPTIONS_GHC -Wno-orphans #-}
-- | Binary encodings of the surface values the front end persists in its
-- on-disk cache; see LawSpec.CorePersist.
module LawSpec.Persist () where

import Data.Binary (Binary)
import LawSpec.CorePersist ()
import qualified LawSpec.Model as S

instance Binary S.Assertion
instance Binary S.Constraint
instance Binary S.ConstructorDeclaration
instance Binary S.Contract
instance Binary S.DataTypeDeclaration
instance Binary S.Definition
instance Binary S.DomainPlan
instance Binary S.Example
instance Binary S.Expanded
instance Binary S.Expectation
instance Binary S.Expr
instance Binary S.FunctionDefinition
instance Binary S.Import
instance Binary S.Input
instance Binary S.Law
instance Binary S.Literal
instance Binary S.MatchBranch
instance Binary S.Refinement
instance Binary S.RefinementArgument
instance Binary S.Type
instance Binary S.TypedCase
instance Binary S.TypedExpr
instance Binary S.Unit
instance Binary S.Protocol
instance Binary S.Step
instance Binary S.AbilityDeclaration
instance Binary S.HandlerDeclaration
instance Binary S.HandlerClause
instance Binary S.HandlerUse
instance Binary S.ResourceDeclaration
instance Binary S.HandlerChoice
instance Binary S.HarnessDeclaration
instance Binary S.HarnessItem
instance Binary S.ShareScope
instance Binary S.StrategyDeclaration
instance Binary S.Gen
instance Binary S.HarnessSetting
instance Binary S.HarnessPlan
