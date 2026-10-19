-- | The complete closing vocabulary of the canonical language. Labels denote
-- constructs, never user-defined names; all consumers share this catalogue.
module LawSpec.Blocks (BlockKind(..), blockLabel, blockKind, blockKinds) where

data BlockKind
  = UnitBlock | FunctionBlock | ProcedureBlock | TypeBlock
  | RefinementBlock | WrapperBlock | LawBlock
  | DefinitionBlock | DescriptionBlock | RationaleBlock | ReferencesBlock
  | ExampleBlock | TableBlock | ForAllBlock | ExistsBlock | GivenBlock
  | CaseBlock | IfBlock | LetBlock | MappingBlock | WorkflowBlock | AllBlock
  | ProtocolBlock | ScenarioBlock | ParBlock | RecoveryBlock
  | ModelBlock | ActorBlock | SupervisorBlock | AbilityBlock | LawsBlock
  | HandlerBlock | HandlersBlock | OperationBlock | HandleBlock
  | ResourceBlock | AcquireBlock | ReleaseBlock | ResetBlock
  | HarnessBlock | ForLawBlock | ForLawsBlock | StrategyBlock | BindBlock
  | BenchmarkBlock
  deriving (Eq, Ord, Show, Enum, Bounded)

blockKinds :: [BlockKind]
blockKinds = [minBound .. maxBound]

blockLabel :: BlockKind -> String
blockLabel kind = case kind of
  UnitBlock -> "unit"
  FunctionBlock -> "function"
  ProcedureBlock -> "procedure"
  TypeBlock -> "type"
  RefinementBlock -> "refinement"
  WrapperBlock -> "wrapper"
  LawBlock -> "law"
  DefinitionBlock -> "definition"
  DescriptionBlock -> "description"
  RationaleBlock -> "rationale"
  ReferencesBlock -> "references"
  ExampleBlock -> "example"
  TableBlock -> "table"
  ForAllBlock -> "for all"
  ExistsBlock -> "exists"
  GivenBlock -> "given"
  CaseBlock -> "case"
  IfBlock -> "if"
  LetBlock -> "let"
  MappingBlock -> "mapping"
  WorkflowBlock -> "workflow"
  AllBlock -> "all"
  ProtocolBlock -> "protocol"
  ScenarioBlock -> "scenario"
  ParBlock -> "par"
  RecoveryBlock -> "or else"
  ModelBlock -> "model"
  ActorBlock -> "actor"
  SupervisorBlock -> "supervisor"
  AbilityBlock -> "ability"
  LawsBlock -> "laws"
  HandlerBlock -> "handler"
  HandlersBlock -> "handlers"
  OperationBlock -> "operation"
  HandleBlock -> "handle"
  ResourceBlock -> "resource"
  AcquireBlock -> "acquire"
  ReleaseBlock -> "release"
  ResetBlock -> "reset"
  HarnessBlock -> "harness"
  ForLawBlock -> "for law"
  ForLawsBlock -> "for laws"
  StrategyBlock -> "strategy"
  BindBlock -> "bind"
  BenchmarkBlock -> "benchmark"

blockKind :: String -> Maybe BlockKind
blockKind label = lookup label [(blockLabel kind,kind) | kind <- blockKinds]
