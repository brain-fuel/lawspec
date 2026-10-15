-- Source-expression fixtures shared by compiler, native and WASM checks.
-- They use the explicit structural declaration collector until the parser and
-- whole-unit source pipeline adopt it.
module SourceRecordFixtures (sourceRecordProgram) where
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Elaboration (coreTypeWithRecords,elaborateResolvedWithRecords)
import LawSpec.Scalar (Scalar(..))

sourceRecordProgram :: Int -> C.Program
sourceRecordProgram bits=either (error . show) id $ do
 let unitName="records.sourceExpressions"
     identity name=C.Id (unitName++"::"++name)
     origin=C.GeneratedFrom (identity "fixtures")
     integer=S.Named "Integer"
     field name=S.RecordField name name
     shape fields=S.Record [field name ty |(name,ty)<-fields]
     record=S.RecordLit
     get label value=S.Apply (S.Var (S.fieldAccessPrefix++label)) value
     put label value replacement=S.Apply (S.Apply (S.Var (S.fieldUpdatePrefix++label)) value) replacement
     countShape=shape [("count",integer)]
     positive=S.Refined "n" (S.Named "BigUInt") (Just (S.Binary ">" (S.Var "n") (S.Number 0)))
     dependent=shape [("width",integer),("height",S.Refined "v" integer
       (Just (S.Binary ">" (S.Var "v") (S.Var "width"))))]
     positiveValue=S.Annotate (record [("count",S.Number 1)]) (shape [("count",positive)])
     dependentValue=S.Annotate (record [("height",S.Number 4),("width",S.Number 3)]) dependent
     floats bits'=record [("value",S.ScalarLit (SFloat "Float64" bits'))]
     nan=floats "7ff8000000000001"
     boxType=unitName++"::type::Box"
     boxTag=C.Id (boxType++"::Box")
     box=C.DataDeclaration (C.Id boxType) "Box" [] [C.DataConstructor boxTag "Box"
       [C.Binder (C.Id (boxType++"::amount")) "amount" (C.scalarType "Integer")] [] origin [] []] origin Nothing
     environment=[("doubleCount",S.Arrow countShape countShape)]
     lower projections name env=elaborateResolvedWithRecords projections [box] [identity "doubleCount"] bits (identity name) identity env
 (parameterType,parameterRecords)<-either (Left . pure . diagnostic) Right (coreTypeWithRecords [box] bits countShape)
 let binder=C.Binder (identity "input") "input" parameterType
     declaration=C.Declaration (identity "doubleCount") "doubleCount" (C.Arrow parameterType parameterType) origin
     body=record [("count",S.Binary "+" (get "count" (S.Var "input")) (get "count" (S.Var "input")))]
 (functionBody,bodyRecords)<-either (Left . pure . diagnostic) Right (lower True "doubleCount" [("input",countShape)] body)
 let definition=C.Definition declaration [binder] functionBody
     cases=
       [("fields follow their labels",get "count" (record [("ready",S.BoolLit True),("count",S.Number 7)]),SInteger "Integer" 7)
       ,("nested literal types are collected",get "count" (get "inner" (record [("inner",record [("count",S.Number 9)])])),SInteger "Integer" 9)
       ,("checked calls accept structural inputs",get "count" (S.Apply (S.Var "doubleCount") (record [("count",S.Number 4)])),SInteger "Integer" 8)
       ,("field-order-independent values compare",S.Binary "==" (record [("count",S.Number 3),("ready",S.BoolLit True)])
          (record [("ready",S.BoolLit True),("count",S.Number 3)]),SBool True)
       ,("dependent updates retain constructor contracts",get "height" (put "height" dependentValue (S.Number 5)),SInteger "Integer" 5)
       ,("positive fields retain their domain",S.Binary ">" (get "count" positiveValue) (S.Number 0),SBool True)
       ,("nominal fields retain their identity",get "amount" (get "box" (record [("box",S.ConstructLit (C.idText boxTag) [S.Number 12])])),SInteger "Integer" 12)
       ,("NaN record equality is not reflexive",S.Binary "==" nan nan,SBool False)
       ,("signed zeros retain IEEE equality",S.Binary "==" (floats "8000000000000000") (floats "0000000000000000"),SBool True)
       ,("empty products have one value",S.Binary "==" (record []) (record []),SBool True)]
 entries<-mapM (\(name,expression,expected)->do
   (actual,records)<-either (Left . pure . diagnostic) Right (lower False ("law::"++name) environment expression)
   let wanted=C.Expr (C.expressionType actual) (C.Constant expected) origin
       evidence=if C.expressionType actual==C.scalarType "Integer" then C.Numeric (C.expressionType actual) else C.Structural (C.expressionType actual)
       property=C.Property (identity ("law::"++name)) name (S.Location "source-record-expressions" 1 1) []
         (C.Equation evidence actual wanted) [] S.defaultGeneration "" "" [] [] [] [] C.noHarness S.UniversalDomain S.emptyLawMetadata
   pure (property,records)) cases
 let program=C.Program bits (box:parameterRecords++bodyRecords++concatMap snd entries)
       [C.Unit (C.Id unitName) [declaration] [] (map fst entries) [definition] []]
 normalized<-normalizeProgramRecords program
 validateProgram normalized
 interned<-either (Left . pure . diagnostic) Right (internRecordDeclarations (C.programDataDeclarations normalized))
 pure normalized{C.programDataDeclarations=interned}
 where diagnostic message=S.Diagnostic "source-record-fixture" message Nothing
