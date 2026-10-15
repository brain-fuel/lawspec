-- | Source products become the same checked Core products as explicit IR,
-- retaining constructor contracts, nominal boundaries and strict evaluation.
-- ref:DEC-typed-core-boundary ref:DEC-readable-notation
module SourceRecordElaborationSpec (test_recordElaborationUsesCheckedCore) where
import Control.Monad (forM_)
import Control.Exception (evaluate)
import Data.IORef
import Data.Either (isLeft,isRight)
import Data.List (nub)
import qualified Data.Map.Strict as M
import Test.Hspec
import System.IO.Unsafe (unsafePerformIO)
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.Core.Eval (evaluateValue,evaluateValueProposition)
import LawSpec.Core.Definitions (prepareDefinitions)
import SourceRecordFixtures (sourceRecordProgram)
import LawSpec.Capabilities (satisfiedWithData)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import LawSpec.Elaboration (coreTypeWithRecords,elaborateResolvedWithRecords,elaborateResolvedWithData)
import LawSpec.Scalar (Scalar(..))

integer=S.Named "Integer"
field name=S.RecordField name name
record fields=S.Record [field name ty |(name,ty)<-fields]
positive=S.Refined "n" (S.Named "BigUInt") (Just (S.Binary ">" (S.Var "n") (S.Number 0)))
origin=C.GeneratedFrom (C.Id "source.records")
resolve name=C.Id ("source.records::"++name)
lower=elaborateResolvedWithRecords True [] [] 64 (C.Id "source.records::value") resolve []
get label value=S.Apply (S.Var (S.fieldAccessPrefix++label)) value
put label value replacement=S.Apply (S.Apply (S.Var (S.fieldUpdatePrefix++label)) value) replacement
program expression=do
 (body,declarations)<-lower expression
 let declaration=C.Declaration (C.Id "source.records::value") "value" (C.expressionType body) origin
     definition=C.Definition declaration [] body
 pure (C.Program 64 declarations [C.Unit (C.Id "source.records") [declaration] [] [] [definition] []])
admitted expression=case program expression of
 Left message->Left message
 Right candidate->either (Left . show) Right (normalizeProgramRecords candidate >>= \normalized->validateProgram normalized >> pure normalized)
value expression=do
 (body,declarations)<-lower expression
 registry<-makeRegistry declarations
 evaluateValue registry 64 (\_ _->Left "unexpected native dependency") [] body

-- Full program admission is intentionally separate from evaluating a typed
-- term: it is admission that must reject a violated constructor restriction.
test_recordElaborationUsesCheckedCore=describe "source record elaboration" $ do
 it "collects and evaluates a closed anonymous product" $ do
  let expression=S.RecordLit [("ready",S.BoolLit True),("count",S.Number 7)]
  admitted expression `shouldSatisfy` isRight
  value (get "count" expression) `shouldBe` Right (ScalarValue (SInteger "Integer" 7))
 it "constructs empty products without treating them as Unit" $ do
  let expression=S.RecordLit []
  admitted expression `shouldSatisfy` isRight
  case coreTypeWithRecords [] 64 (S.Record []) of
   Left message->expectationFailure message
   Right (ty,declarations)->do
    ty `shouldNotBe` C.scalarType "Unit"
    length declarations `shouldBe` 1
 it "uses label-directed contextual scalar types" $ do
  let shape=record [("count",S.Named "UInt8"),("ready",S.Named "Bool")]
      expression=S.Annotate (S.RecordLit [("ready",S.BoolLit True),("count",S.Number 255)]) shape
  admitted expression `shouldSatisfy` isRight
  value (get "count" expression) `shouldBe` Right (ScalarValue (SInteger "UInt8" 255))
 it "preserves positive and zero-inclusive record identities" $ do
  let positiveShape=record [("count",positive)]
      wholeShape=record [("count",S.Named "BigUInt")]
  case (coreTypeWithRecords [] 64 positiveShape,coreTypeWithRecords [] 64 wholeShape) of
   (Right (a,_),Right (b,_))->a `shouldNotBe` b
   other->expectationFailure (show other)
 it "enforces positive field restrictions during mandatory definition admission" $ do
  let expression n=S.Annotate (S.RecordLit [("count",S.Number n)]) (record [("count",positive)])
  admitted (expression 1) `shouldSatisfy` isRight
  admitted (expression 0) `shouldSatisfy` isLeft
 it "enforces dependent field restrictions on the complete stored product" $ do
  let shape=record [("width",integer),("height",S.Refined "v" integer (Just (S.Binary ">" (S.Var "v") (S.Var "width"))))]
      expression n=S.Annotate (S.RecordLit [("height",S.Number n),("width",S.Number 3)]) shape
  admitted (expression 4) `shouldSatisfy` isRight
  admitted (expression 2) `shouldSatisfy` isLeft
 it "collects nested record-only literal types before lowering projections" $ do
  let expression=S.RecordLit [("inner",S.RecordLit [("count",S.Number 9)])]
  admitted expression `shouldSatisfy` isRight
  value (get "count" (get "inner" expression)) `shouldBe` Right (ScalarValue (SInteger "Integer" 9))
 it "uses checked record updates and retains dependent constructor contracts" $ do
  let shape=record [("width",integer),("height",S.Refined "v" integer (Just (S.Binary ">" (S.Var "v") (S.Var "width"))))]
      expression=S.Annotate (S.RecordLit [("width",S.Number 3),("height",S.Number 4)]) shape
  admitted (put "height" expression (S.Number 5)) `shouldSatisfy` isRight
  admitted (put "height" expression (S.Number 2)) `shouldSatisfy` isLeft
 it "normalizes generic source records to direct concrete identities" $ do
  let generic=record [("value",S.Variable "a"),("ready",S.Variable "b")]
      concrete=record [("ready",S.Named "Bool"),("value",integer)]
      replace=S.mapType (\ty->case ty of S.Variable "a"->integer;S.Variable "b"->S.Named "Bool";other->other) id
  fmap fst (coreTypeWithRecords [] 64 (replace generic)) `shouldBe` fmap fst (coreTypeWithRecords [] 64 concrete)
 it "retains each occurrence before checking duplicate restriction orders" $ do
  let fields=[field "denominator" (S.Refined "n" integer (Just (S.Binary "!=" (S.Var "n") (S.Number 0)))),
        field "numerator" (S.Refined "v" integer (Just (S.Binary ">" (S.Binary "/" (S.Var "v") (S.Var "denominator")) (S.Number 0))))]
      a=S.Record fields
      b=S.Record (reverse fields)
  case (coreTypeWithRecords [] 64 a,coreTypeWithRecords [] 64 b) of
   (Right (ta,da),Right (tb,db))->do
    ta `shouldBe` tb
    length (da++db) `shouldBe` 2
    let candidate=C.Program 64 (da++db) []
    validateProgram candidate `shouldSatisfy` isLeft
   -- A forward field reference may be diagnosed while elaborating the
   -- source context, before constructor admission can inspect its order.
   (_,Left _)->pure ()
   other->expectationFailure (show other)
 it "rejects unknown forward dependencies in source field restrictions" $ do
  let shape=record [("height",S.Refined "v" integer (Just (S.Binary ">" (S.Var "v") (S.Var "width")))),("width",integer)]
  coreTypeWithRecords [] 64 shape `shouldSatisfy` isLeft
 it "emits admitted source expressions through every target" $ do
  let expression=S.RecordLit [("inner",S.RecordLit [("count",S.Number 9)]),("ready",S.BoolLit True)]
  case admitted expression >>= either (Left . show) Right . planTesting of
   Left message->expectationFailure message
   Right plan->forM_ targets $ \target->emitPlan target plan `shouldSatisfy` isRight

 it "executes ten source-expression laws and emits every target at both widths" $
  forM_ [32,64] $ \bits->do
   let source=sourceRecordProgram bits
   validateProgram source `shouldBe` Right ()
   case (makeRegistry (C.programDataDeclarations source),prepareDefinitions source,planTesting source) of
    (Right registry,Right invoke,Right plan)->do
     let laws=concatMap C.unitProperties (C.programUnits source)
     length laws `shouldBe` 10
     mapM_ (\law->evaluateValueProposition registry bits invoke [] (C.propertyBody law) `shouldBe` Right True) laws
     forM_ targets $ \target->emitPlan target plan `shouldSatisfy` isRight
    other->expectationFailure "source expression fixture did not admit"
 it "audits undefined unselected literal fields before projecting a defined field" $ do
  let expression=get "count" (S.RecordLit [("unused",S.Binary "/" (S.Number 1) (S.Number 0)),("count",S.Number 3)])
  admitted expression `shouldSatisfy` isLeft
 it "evaluates each field once in source order independently of canonical layout" $ do
  calls<-newIORef ([] :: [Integer])
  let mark n=S.Apply (S.Var "mark") (S.Number n)
      expression=S.RecordLit [("z",mark 2),("a",mark 1)]
      invoke _ [ScalarValue (SInteger _ n)]=unsafePerformIO $ do
        modifyIORef' calls (++[n])
        pure (Right (ScalarValue (SInteger "Integer" n)))
      invoke _ _=Left "invalid trace invocation"
  case elaborateResolvedWithRecords False [] [resolve "mark"] 64 (resolve "order") resolve
    [("mark",S.Arrow integer integer)] expression of
   Left message->expectationFailure message
   Right (body,declarations)->case makeRegistry declarations of
    Left message->expectationFailure message
    Right registry->do
     let actual=evaluateValue registry 64 invoke [] body
     _<-evaluate (length (show actual))
     case actual of
      Right (DataValue _ _ values)->values `shouldBe` [ScalarValue (SInteger "Integer" 1),ScalarValue (SInteger "Integer" 2)]
      other->expectationFailure (show other)
     readIORef calls `shouldReturn` [2,1]
 it "does not expose synthetic Record constructors in the ordinary namespace" $ do
  let tag=C.Id "Named::Record"
      named=C.DataDeclaration (C.Id "Named") "Named" [] [C.DataConstructor tag "Record"
        [C.Binder (C.Id "Named::value") "value" (C.scalarType "Integer")] [] origin [] []] origin Nothing
  case coreTypeWithRecords [named] 64 (record [("value",integer)]) of
   Left message->expectationFailure message
   Right (_,records)->case elaborateResolvedWithRecords False (named:records) [] 64 (resolve "named") resolve []
     (S.ConstructLit "Record" [S.Number 1]) of
    Left message->expectationFailure message
    Right (body,_)->C.expressionType body `shouldBe` C.scalarType "Named"
 it "checks stored field capability requirements without adding them to value identity" $ do
  let qualified=S.Qualified [S.Capability "Eq" integer] integer
      invalid=S.Qualified [S.Capability "Integer" (S.Named "Bool")] integer
  fmap fst (coreTypeWithRecords [] 64 (record [("value",qualified)]))
    `shouldBe` fmap fst (coreTypeWithRecords [] 64 (record [("value",integer)]))
  coreTypeWithRecords [] 64 (record [("value",invalid)]) `shouldSatisfy` isLeft
 it "derives Eq for structural fields without requiring Keyed" $ do
  let floating=record [("value",S.Named "Float64")]
  satisfiedWithData [] 64 [] (S.Capability "Eq" floating) `shouldBe` True
  satisfiedWithData [] 64 [] (S.Capability "Keyed" floating) `shouldBe` False
  satisfiedWithData [] 64 [] (S.Capability "Eq" (record [("function",S.Arrow integer integer)])) `shouldBe` False
 it "does not specialize an enclosing type parameter while typing a restriction" $ do
  let annotation=S.Annotate (S.Var "value") (S.Variable "a")
      shape=record [("value",S.Refined "value" integer
        (Just (S.Binary "==" annotation (S.Var "value"))))]
  coreTypeWithRecords [] 64 shape `shouldSatisfy` isLeft
 it "retains generic fields alongside typed concrete restrictions" $ do
  let shape=record [("value",S.Variable "a"),("count",positive)]
  case coreTypeWithRecords [] 64 shape of
   Left message->expectationFailure message
   Right (C.Constructor _ [C.TypeArgument (C.TypeVariable parameter)],[declaration])->do
    parameter `shouldBe` C.Id "a"
    length (C.dataParameters declaration) `shouldBe` 1
    validateProgram (C.Program 64 [declaration] []) `shouldBe` Right ()
   other->expectationFailure (show other)
 it "reports an unresolved generic equality requirement without inventing evidence" $ do
  let shape=record [("value",S.Refined "v" (S.Variable "a")
        (Just (S.Binary "==" (S.Var "v") (S.Var "v"))))]
  coreTypeWithRecords [] 64 shape `shouldSatisfy` isLeft
 it "audits a reordered occurrence even when its descriptor is already registered" $ do
  let denominator=field "denominator" integer
      guard=field "guard" (S.Refined "b" (S.Named "Bool")
        (Just (S.Binary "!=" (S.Var "denominator") (S.Number 0))))
      amount=field "amount" (S.Refined "n" integer
        (Just (S.Binary ">" (S.Binary "/" (S.Var "n") (S.Var "denominator")) (S.Number 0))))
      good=S.Record [denominator,guard,amount]
      bad=S.Record [denominator,amount,guard]
      expression=S.Annotate (S.RecordLit [("denominator",S.Number 1),("guard",S.BoolLit True),("amount",S.Number 1)]) bad
  case coreTypeWithRecords [] 64 good of
   Left message->expectationFailure message
   Right (_,declarations)->elaborateResolvedWithData declarations [] 64 (resolve "ordered") resolve [] expression `shouldSatisfy` isLeft
 it "collects structural types introduced inside field restrictions" $ do
  let projected=get "mirror" (S.RecordLit [("mirror",S.Var "n")])
      shape=record [("count",S.Refined "n" integer (Just (S.Binary ">" projected (S.Number 0))))]
  case coreTypeWithRecords [] 64 shape of
   Left message->expectationFailure message
   Right (_,declarations)->do
    length (nub (map C.dataId declarations)) `shouldBe` 2
    validateProgram (C.Program 64 declarations []) `shouldBe` Right ()
  admitted (S.Annotate (S.RecordLit [("count",S.Number 1)]) shape) `shouldSatisfy` isRight
  admitted (S.Annotate (S.RecordLit [("count",S.Number 0)]) shape) `shouldSatisfy` isLeft
 it "proves positive construction from a projected strict record literal" $ do
  let selected=get "number" (S.RecordLit [("number",S.Number 1)])
      expression=S.Annotate (S.RecordLit [("count",selected)]) (record [("count",positive)])
  admitted expression `shouldSatisfy` isRight
