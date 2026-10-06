{-# OPTIONS_GHC -Wno-orphans #-}
-- | Binary encodings of the Core values the compiler persists in its on-disk
-- cache (LawSpec.Memo). They are derived from the types' structure, so the
-- cache format is tied to the compiler build; the CLI keeps one cache folder
-- per build, LawSpec.Memo salts entries with the compiler version, and an
-- entry that fails to decode is recomputed. Surface types are in
-- LawSpec.Persist, so Core and the backends never depend on syntax.
module LawSpec.CorePersist () where

import Data.Binary (Binary)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Value (Value)
import LawSpec.Core.Policy (StagePolicy, Retry, Strategy, Jitter, Limit, Breaker, Bulkhead, Hedge)
import LawSpec.Core.Machine (Machine, MachineStart, Command, Invariant, Need, Shift, Supervisor, SupervisionStrategy, Lifetime, Consistency)
import LawSpec.Core.Program (Program, Act, Operand, Constant)
import LawSpec.IndexTerm
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
instance Binary name => Binary (StagePolicy name)
instance Binary name => Binary (Retry name)
instance Binary name => Binary (Strategy name)
instance Binary Jitter
instance Binary name => Binary (Limit name)
instance Binary name => Binary (Breaker name)
instance Binary name => Binary (Bulkhead name)
instance Binary Hedge
instance Binary name => Binary (Machine name)
instance Binary name => Binary (MachineStart name)
instance Binary name => Binary (Command name)
instance Binary Supervisor
instance Binary SupervisionStrategy
instance Binary Lifetime
instance Binary Consistency
instance Binary name => Binary (Invariant name)
instance Binary Program
instance Binary Act
instance Binary Operand
instance Binary Constant
instance Binary Need
instance Binary Shift
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
instance Binary C.Session
instance Binary C.Mailbox
instance Binary ConstructorIndex
instance Binary FamilyIndex
instance Binary IndexGuard
instance Binary IndexOperation
instance Binary IndexRelation
instance Binary IndexTerm
