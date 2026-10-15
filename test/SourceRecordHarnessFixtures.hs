-- | Structural products introduced by the harness reach the ordinary checked
-- program, including bounded strategies and constructive witnesses.
-- ref:DEC-typed-core-boundary ref:REQ-harness ref:DEC-total-definitions
module SourceRecordHarnessFixtures where

import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Frontend as Frontend
import SourceRecordUnitFixtures (base,integer,boolean,get,claim)

range = S.Span (S.Location "record-unit.harness.lawspec" 7 3) (S.Location "record-unit.harness.lawspec" 7 50)
record fields = S.Record [S.RecordField label label ty | (label,ty) <- fields]
requested = record [("requested",integer)]
selected = record [("selected",integer)]
number label value = S.RecordLit [(label,value)]
plan = S.HarnessPlan "record.unit.testing" [] Nothing Nothing Nothing 1 0 [] [] [] Nothing [] Nothing [] [] []
harness = S.HarnessDeclaration "record.unit.testing" "record.unit" [] range
valueInput = S.Input "value" "_value" integer []
flagInput = S.Input "flag" "_flag" boolean []
answerInput = S.Input "answer" "_answer" integer []
recordInput = S.Input "answer" "_recordAnswer" requested []
reflexive = claim "observations" [valueInput] (S.AssertEqual (S.Var "_value") (S.Var "_value"))
witnessLaw = claim "constructive" [flagInput] (S.AssertQuantified S.ForSome answerInput
  (S.AssertEqual (S.Var "_answer") (wanted (S.Var "_flag"))))
wanted flag = foldl S.Apply (S.Var "prelude.select") [flag,S.Number 7,S.Number 8]
recordLaw = claim "scoped" [] (S.AssertQuantified S.ForSome recordInput
  (S.AssertEqual (get "requested" (S.Var "_recordAnswer")) (S.Number 7)))
dependentLaw = claim "dependent" [] (S.AssertQuantified S.ForSome answerInput
  (S.AssertEqual (S.Var "_answer") (S.Number 7)))
observations = plan
  { S.planDraws = [("value","selectedValues",integer,S.GenBind "payload" selected
      (S.GenOneOf [number "selected" (S.Number 6),number "selected" (S.Number 7)])
      (S.GenOneOf [get "selected" (S.Var "payload")]))]
  , S.planDrawLocations = [("value",range)]
  , S.planCover = [(0,"nonnegative",get "ready" (S.RecordLit [("ready",S.Binary ">=" (S.Var "value") (S.Number 0))]))]
  , S.planClassify = [(get "ready" (S.RecordLit [("ready",S.BoolLit True)]),"selected")]
  , S.planLabels = [get "label" (S.RecordLit [("label",S.StringLit "selected record")])]
  , S.planTarget = Just (get "score" (S.RecordLit [("score",S.Var "value")])) }
constructive = plan { S.planResolvedWitnesses =
  [S.HarnessWitness ["flag","answer"] answerInput [flagInput]
    (get "witness" (number "witness" (wanted (S.Var "_flag")))) range] }
scoped = plan {S.planDraws=[("answer","requests",requested,S.GenOneOf
  [number "requested" (S.Number 6),number "requested" (S.Number 7)])],S.planDrawLocations=[("answer",range)]}
dependent = plan {S.planDraws=[("answer","dependentValues",integer,
  S.GenBind "payload" selected (S.GenOneOf [number "selected" (S.Number 7)])
    (S.GenOneOf [get "selected" (S.Var "payload")]))],S.planDrawLocations=[("answer",range)]}
source = base
  { S.unitHarness = Just harness {S.harnessItems=[S.HarnessBenchmark "record projection"
      (get "benchmark" (number "benchmark" (S.Number 9))) range]}
  , S.lawHarness = [("observations",observations),("constructive",constructive),("scoped",scoped),("dependent",dependent)] }
sourceRecordHarnessProgram :: Int -> Either [S.Diagnostic] C.Program
sourceRecordHarnessProgram bits = Frontend.elaborate bits [source] [reflexive,witnessLaw,recordLaw,dependentLaw]
