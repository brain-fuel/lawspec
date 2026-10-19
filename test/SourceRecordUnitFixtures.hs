-- | Whole-unit structural inputs exercise the actual frontend and admission.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module SourceRecordUnitFixtures where
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Parser (parseSource)
import qualified LawSpec.Frontend as Frontend

base = either (error . show) id (parseSource (S.Source "record-unit.lawspec" "unit record.unit\n\nend unit\n"))
integer = S.Named "Integer"
boolean = S.Named "Bool"
shape = S.Record [S.RecordField "count" "count" integer]
positive = S.Record [S.RecordField "count" "count" (S.Refined "n" integer
  (Just (S.Binary ">" (S.Var "n") (S.Number 0))))]
get field value = S.Apply (S.Var (S.fieldAccessPrefix ++ field)) value
literal n = S.RecordLit [("count",S.Number n)]
range = S.Span (S.Location "record-unit.lawspec" 1 1) (S.Location "record-unit.lawspec" 1 1)
definition name arguments result body = S.FunctionDefinition name arguments result [] body range
source = base
  { S.functions = [("count",S.Arrow shape integer),("create",shape),("run",integer)]
  , S.functionDefinitions =
      [ definition "count" [("item",shape)] integer (get "count" (S.Var "item"))
      , definition "create" [] shape (literal 7)
      , definition "run" [] integer (S.Apply (S.Var "count") (S.Var "create")) ] }
claim name inputs assertion = S.Expanded "record.unit" name inputs (S.BoolLit True) (S.BoolLit True) [] assertion [] law []
  "law" S.defaultGeneration [] [] S.UniversalDomain
  where
    law=S.Law name [] [] (S.Holds (S.BoolLit True)) "" "" [] [] (S.spanStart range) [] S.emptyLawMetadata
sourceRecordUnitProgram :: Int -> Either [S.Diagnostic] C.Program
sourceRecordUnitProgram bits = Frontend.elaborate bits [source]
  [ claim "uses records" [] (S.AssertEqual (S.Var "run") (S.Number 7))
  , claim "literal argument" [] (S.AssertEqual (S.Apply (S.Var "count") (literal 9)) (S.Number 9))
  , claim "field order" [] (S.AssertEqual
      (S.RecordLit [("inner",literal 4),("ready",S.BoolLit True)])
      (S.RecordLit [("ready",S.BoolLit True),("inner",literal 4)]))
  , claim "empty product" [] (S.AssertEqual (S.RecordLit []) (S.RecordLit [])) ]
