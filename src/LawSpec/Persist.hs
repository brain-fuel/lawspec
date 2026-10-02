{-# OPTIONS_GHC -Wno-orphans #-}
-- Binary encodings of the values the compiler persists in its on-disk cache
-- (LawSpec.Memo). They are derived from the types' structure, so the cache
-- format is tied to the compiler build; LawSpec.Memo salts the cache with the
-- compiler version, and an entry that fails to decode is recomputed.
module LawSpec.Persist () where

import Data.Binary (Binary)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Value (Value)
import LawSpec.IndexTerm
import qualified LawSpec.Model as S
import LawSpec.Scalar (Scalar)

instance Binary Generation
instance Binary Location
instance Binary Diagnostic
instance Binary Artifact
instance Binary Span
instance Binary Scalar
instance Binary Value
instance Binary C.Argument
instance Binary C.BinaryOp
instance Binary C.Binder
instance Binary C.Builtin
instance Binary C.Contract
instance Binary C.Conversion
instance Binary C.DataConstructor
instance Binary C.DataDeclaration
instance Binary C.Declaration
instance Binary C.Definition
instance Binary C.Evidence
instance Binary C.Example
instance Binary C.Expr
instance Binary C.Id
instance Binary C.Index
instance Binary C.Kind
instance Binary C.LogicalOp
instance Binary C.MatchCase
instance Binary C.Node
instance Binary C.Origin
instance Binary C.Program
instance Binary C.Property
instance Binary C.Proposition
instance Binary C.Quantifier
instance Binary C.Type
instance Binary C.UnaryOp
instance Binary C.Unit
instance Binary ConstructorIndex
instance Binary FamilyIndex
instance Binary IndexGuard
instance Binary IndexOperation
instance Binary IndexRelation
instance Binary IndexTerm
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
