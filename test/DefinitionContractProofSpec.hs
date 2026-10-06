module DefinitionContractProofSpec (spec) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import qualified Data.Map.Strict as M
import LawSpec.Core
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Value (Value(..), listValue, validateValue)
import qualified LawSpec.Core.Types as Types
import qualified LawSpec.Core.Schema as Schema
import qualified LawSpec.Core.Eval as Eval
import LawSpec.Testing (planTesting, Plan(..))
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Core.Validate (operationEvidence, validateProgram)
import qualified DefinitionContractFixture as Fixture
import qualified LawSpec.Model as S
import LawSpec.Parser (parseSource)
import LawSpec.Elaboration (elaborateDefinitionUnit)
import LawSpec.Frontend (elaborate, compileCore)
import LawSpec.Common (Source(..), Location(..), defaultGeneration)
import qualified LawSpec.Core.Totality as T
import LawSpec.Scalar (Scalar(..))

origin :: Origin
origin = GeneratedFrom (Id "contract-proof")
int, integer, boolean :: Type
int = scalarType "Int8"
integer = scalarType "Integer"
boolean = scalarType "Bool"
value :: String -> Type -> Expr
value name ty = Expr ty (Local (Id name)) origin
number :: Integer -> Expr
number n = Expr integer (Constant (SInteger "Integer" n)) origin
operation :: BinaryOp -> Expr -> Expr -> Expr
operation op a b =
  let evidence = either error id (operationEvidence op (expressionType a) (expressionType b))
      ty = if isComparison op then boolean else case evidence of Numeric t -> t; Structural t -> t
  in Expr ty (Binary op evidence a b) origin
definition :: String -> Expr -> Definition
definition name body = Definition (Declaration (Id name) name (Arrow int (expressionType body)) origin)
  [Binder (Id "x") "x" int] body
contract :: String -> Type -> [Expr] -> [Expr] -> Contract
contract name ty pre post = Contract (Id name) [Binder (Id "argument") "argument" int]
  (Binder (Id "result") "result" ty) pre post []

spec :: Spec
spec = describe "refined definition proof obligations" $ do
  describe "constructor field invariants" $ do
    let tag = Id "Positive"
        field = Id "field"
        argument = Id "input"
        n = T.Literal . SInteger "Integer"
        positive x = T.ExactComparison Greater x (n 0)
        invariant = T.ProofConstructorContract tag [field] [positive (T.Variable field)] []
        function body = T.ProofDefinition (Id "use") "use" Nothing [argument] body []
        check contracts body = T.auditWithConstructorContracts contracts [] [function body]
        reciprocal x = T.Division False Divide (n 1) x
    it "requires constructor arguments to establish their field predicates" $ do
      check [invariant] (T.Construct tag [n 1]) `shouldBe` Right ()
      check [invariant] (T.Construct tag [n 0]) `shouldSatisfy` isLeft
      check [invariant] (T.Construct tag [T.Variable argument]) `shouldSatisfy` isLeft
      check [invariant] (T.Construct tag []) `shouldSatisfy` isLeft
    it "makes a matched constructor invariant available only in that alternative" $ do
      let match other = T.DataMatch (T.Variable argument)
            [(tag,[field],reciprocal (T.Variable field)),
             (Id "Unchecked",[field],other)]
      check [invariant] (match (n 0)) `shouldBe` Right ()
      check [invariant] (match (reciprocal (T.Variable field))) `shouldSatisfy` isLeft
    it "keeps field binders fresh when their names shadow an input" $ do
      let body = T.DataMatch (T.Variable argument)
            [(tag,[argument],reciprocal (T.Variable argument))]
      check [invariant] body `shouldBe` Right ()
      check [invariant] (T.Sequence [body,reciprocal (T.Variable argument)])
        `shouldSatisfy` isLeft
    it "checks known constructions before using their invariants" $ do
      let body value = T.DataMatch (T.Construct tag [n value])
            [(tag,[field],reciprocal (T.Variable field))]
      check [invariant] (body 2) `shouldBe` Right ()
      check [invariant] (body 0) `shouldSatisfy` isLeft
      check [invariant] (T.DataMatch (T.Variable argument) [(tag,[],n 1)])
        `shouldSatisfy` isLeft
    it "audits ordered predicates before trusting them" $ do
      let nonzero = T.ExactComparison NotEqual (T.Variable field) (n 0)
          divided = positive (reciprocal (T.Variable field))
          ordered = T.ProofConstructorContract tag [field] [nonzero,divided] []
      T.auditWithConstructorContracts [ordered] [] [] `shouldBe` Right ()
      T.auditWithConstructorContracts
        [ordered{T.constructorConditions=[divided,nonzero]}] [] [] `shouldSatisfy` isLeft
    it "substitutes dependent fields together and preserves result contracts" $ do
      let second = Id "second"
          dependent = T.ProofConstructorContract tag [field,second]
            [T.ExactComparison Greater (T.Variable second) (T.Variable field)] []
          result = Id "result"
          body = T.DataMatch (T.Variable argument) [(tag,[field],T.Variable field)]
          post = T.ProofContract (Id "use") result [] [positive (T.Variable result)]
      check [dependent] (T.Construct tag [n 2,n 3]) `shouldBe` Right ()
      check [dependent] (T.Construct tag [n 3,n 2]) `shouldSatisfy` isLeft
      T.auditWithConstructorContracts [invariant] [post] [function body] `shouldBe` Right ()
    it "rejects circular constructor invariants instead of assuming their conclusions" $ do
      let self = invariant{T.constructorConditions=
            [T.DataMatch (T.Variable field) [(tag,[argument],positive (T.Variable argument))]]}
          other = Id "Other"
          refers target = T.DataMatch (T.Variable field) [(target,[argument],T.Literal (SBool True))]
          left = invariant{T.constructorConditions=[refers other]}
          right = T.ProofConstructorContract other [field] [refers tag] []
      T.auditWithConstructorContracts [self] [] [] `shouldSatisfy` isLeft
      T.auditWithConstructorContracts [left,right] [] [] `shouldSatisfy` isLeft
    it "rejects malformed or dependency-unaudited constructor contracts" $ do
      let audit cs = T.auditWithConstructorContracts cs [] []
      audit [invariant,invariant] `shouldSatisfy` isLeft
      audit [invariant{T.constructorParameters=[field,field]}] `shouldSatisfy` isLeft
      audit [invariant{T.constructorParameters=[]}] `shouldSatisfy` isLeft
      audit [invariant{T.constructorConditions=[T.Call (Id "predicate") [T.Variable field]]}]
        `shouldSatisfy` isLeft

  describe "typed constructor contracts and reference execution" $ do
    let tag = Id "Positive::Positive"
        ty = scalarType "Positive"
        field = Binder (Id "stored") "value" int
        positive = operation Greater (value "stored" int) (number 0)
        variant predicates = DataConstructor tag "Positive" [field] predicates origin [] []
        datatype predicates = DataDeclaration (Id "Positive") "Positive" [] [variant predicates] origin Nothing
        positiveType = datatype [positive]
        argument = Binder (Id "box") "box" ty
        item = Binder (Id "item") "item" int
        reciprocal = operation Divide (number 1) (value "item" int)
        body = Expr (scalarType "Rational")
          (Match (value "box" ty) [MatchCase tag [item] reciprocal]) origin
        function = Definition
          (Declaration (Id "reciprocal") "reciprocal" (Arrow ty (scalarType "Rational")) origin)
          [argument] body
        program declarations functions = Program 64 declarations
          [Unit (Id "typed-fields") (map definitionDeclaration functions) [] [] functions []]
        boxed n = DataValue ty tag [ScalarValue (SInteger "Int8" n)]
        ready p action = case prepareDefinitions p of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right invoke -> action invoke
    it "proves a field-dependent body and validates definition entry inputs" $ do
      ready (program [positiveType] [function]) $ \invoke -> do
        invoke (Id "reciprocal") [boxed 2] `shouldBe` Right (ScalarValue (SRational 1 2))
        invoke (Id "reciprocal") [boxed 0] `shouldSatisfy` isLeft
        invoke (Id "reciprocal") [boxed (-1)] `shouldSatisfy` isLeft
      validateProgram (program [datatype []] [function]) `shouldSatisfy` isLeft
    it "checks construction in a typed definition rather than trusting its result type" $ do
      let build n = Definition (Declaration (Id "make") "make" ty origin) []
            (Expr ty (Construct tag [Expr int (Constant (SInteger "Int8" n)) origin]) origin)
      validateProgram (program [positiveType] [build 2]) `shouldBe` Right ()
      validateProgram (program [positiveType] [build 0]) `shouldSatisfy` isLeft
      ready (program [positiveType] [build 2]) $ \invoke ->
        invoke (Id "make") [] `shouldBe` Right (boxed 2)
    it "validates predicate types, arithmetic evidence, scope and primitive values" $ do
      let check predicates = validateProgram (program [datatype predicates] [])
          forged = positive{expressionNode=Binary Greater (Structural int) (value "stored" int) (number 0)}
      check [number 1] `shouldSatisfy` isLeft
      check [operation Greater (value "foreign" int) (number 0)] `shouldSatisfy` isLeft
      check [forged] `shouldSatisfy` isLeft
      check [operation Greater (Expr int (Constant (SInteger "Int8" 128)) origin) (number 0)]
        `shouldSatisfy` isLeft
    it "uses primitive field bounds to audit predicate conversions" $ do
      let widened = Expr (scalarType "Int16") (Convert CheckedArgument (scalarType "Int16")
            (value "stored" int)) origin
          predicate = operation Greater widened (number 0)
      validateProgram (program [datatype [predicate]] []) `shouldBe` Right ()
    it "uses the selected machine width in field contract definedness" $ do
      let machine = scalarType "IntSize"
          stored = field{binderType=machine}
          narrowed = Expr (scalarType "Int32")
            (Convert CheckedArgument (scalarType "Int32") (value "stored" machine)) origin
          declaration = positiveType{dataConstructors=
            [(variant [operation Equal narrowed narrowed]){constructorFields=[stored]}]}
          p bits = (program [declaration] []){programMachineBits=bits}
      validateProgram (p 32) `shouldBe` Right ()
      validateProgram (p 64) `shouldSatisfy` isLeft
    it "checks dependent fields together and stops after a failed predicate" $ do
      let second = Binder (Id "second") "second" int
          inverse = operation Greater (operation Divide (number 1) (value "stored" int)) (number 0)
          dependent = operation Greater (value "second" int) (value "stored" int)
          declaration = positiveType{dataConstructors=
            [(variant [positive,inverse,dependent]){constructorFields=[field,second]}]}
          identity = Definition (Declaration (Id "identity") "identity" (Arrow ty ty) origin)
            [argument] (value "box" ty)
          pair a b = DataValue ty tag [ScalarValue (SInteger "Int8" a),ScalarValue (SInteger "Int8" b)]
      ready (program [declaration] [identity]) $ \invoke -> do
        invoke (Id "identity") [pair 1 2] `shouldBe` Right (pair 1 2)
        invoke (Id "identity") [pair 2 1] `shouldSatisfy` isLeft
        invoke (Id "identity") [pair 0 1] `shouldBe` Left "Positive::Positive: field refinement failed"
    it "checks constrained values nested in Lists and presence wrappers" $ do
      let listTy = Constructor "List" [TypeArgument ty]
          optional = Constructor "Optional" [TypeArgument listTy]
          arg = Binder (Id "values") "values" optional
          identity = Definition (Declaration (Id "identity") "identity" (Arrow optional optional) origin)
            [arg] (value "values" optional)
          wrapped xs = PresenceValue optional (Just (listValue ty xs))
      ready (program [positiveType] [identity]) $ \invoke -> do
        invoke (Id "identity") [wrapped [boxed 1]] `shouldBe` Right (wrapped [boxed 1])
        invoke (Id "identity") [wrapped [boxed 0]] `shouldSatisfy` isLeft
        invoke (Id "identity") [PresenceValue optional Nothing] `shouldBe` Right (PresenceValue optional Nothing)
    it "instantiates generic field predicate types at the value boundary" $ do
      let parameter = Id "Box::a"
          list element = Constructor "List" [TypeArgument element]
          genericList = list (TypeVariable parameter)
          listField = Binder (Id "elements") "elements" genericList
          size = Expr integer (Helper Length [value "elements" genericList]) origin
          boxTag = Id "Box::Box"
          declaration = DataDeclaration (Id "Box") "Box" [parameter]
            [DataConstructor boxTag "Box" [listField] [operation Greater size (number 0)] origin [] []] origin Nothing
          instantiated = Constructor "Box" [TypeArgument int]
          input = Binder (Id "input") "input" instantiated
          identity = Definition (Declaration (Id "identity") "identity" (Arrow instantiated instantiated) origin)
            [input] (value "input" instantiated)
          box xs = DataValue instantiated boxTag [listValue int (map (ScalarValue . SInteger "Int8") xs)]
      ready (program [declaration] [identity]) $ \invoke -> do
        invoke (Id "identity") [box [1]] `shouldBe` Right (box [1])
        invoke (Id "identity") [box []] `shouldSatisfy` isLeft
    it "rejects an adapter result with a broken constructor invariant" $ do
      case Types.makeRegistry [positiveType] of
        Left message -> expectationFailure message
        Right registry -> do
          validateValue registry 64 ty (boxed 1) `shouldSatisfy` isLeft
          let call = Expr ty (ExternalCall (Id "adapter") []) origin
          Eval.evaluateValue registry 64 (\_ _ -> Right (boxed 0)) [] call `shouldSatisfy` isLeft
          Eval.evaluateValue registry 64 (\_ _ -> Right (boxed 1)) [] call `shouldBe` Right (boxed 1)
    it "audits constructor cycles before evaluating concrete property values" $ do
      let literal = Expr ty (Construct tag [Expr int (Constant (SInteger "Int8" 1)) origin]) origin
          circular = Expr boolean (Binary Equal (Structural ty) literal literal) origin
          declaration = datatype [circular]
          property = Property (Id "cycle-property") "cycle" (Location "cycle" 1 1) []
            (Equation (Structural ty) literal literal) [] defaultGeneration "" "" [] [] [] [] noHarness
          p = Program 64 [declaration] [Unit (Id "cycle") [] [] [property] [] []]
      validateProgram p `shouldSatisfy` isLeft
    it "preserves declared parameters in generic constructor-predicate matches" $ do
      let source = Source "generic-match.lawspec" $ unlines
            ["unit generic.match",
             "type Present (a :: Type) is Present item :: (m :: Maybe a where",
             "  match m with | Nothing -> false | Just value -> true end) end"]
      mapM_ (\bits -> compileCore bits defaultGeneration [source] `shouldSatisfy` isRight) [32,64]
    it "enables audited constructor contracts on all eight backends" $ do
      Schema.dataSchemas [positiveType] `shouldSatisfy` isLeft
      planTesting (program [positiveType] [function]) `shouldSatisfy` isRight
      mapM_ (\target -> emitPlan target (Plan 64 [positiveType] []) `shouldSatisfy` isRight)
        targets

  it "audits division in every List predicate under its local guard" $ do
    let list = Constructor "List" [TypeArgument int]
        element = Binder (Id "element") "element" int
        item = value "element" int
        nonzero = operation NotEqual item (number 0)
        positive = operation Greater (operation Divide (number 1) item) (number 0)
        body predicate = Expr boolean (AllElements (value "xs" list) element predicate) origin
        function predicate = Definition
          (Declaration (Id "all") "all" (Arrow list boolean) origin)
          [Binder (Id "xs") "xs" list] (body predicate)
        guarded = Expr boolean (ShortCircuit And nonzero positive) origin
    validateDefinitionContracts 64 [] [function guarded] [] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [function positive] [] `shouldSatisfy` isLeft
  it "uses primitive List element bounds to prove checked conversions" $ do
    let list = Constructor "List" [TypeArgument int]
        element = Binder (Id "element") "element" int
        widened = Expr (scalarType "Int16") (Convert CheckedArgument (scalarType "Int16") (value "element" int)) origin
        predicate = operation Equal widened widened
        body = Expr boolean (AllElements (value "xs" list) element predicate) origin
        function = Definition (Declaration (Id "all") "all" (Arrow list boolean) origin)
          [Binder (Id "xs") "xs" list] body
    validateDefinitionContracts 64 [] [function] [] `shouldBe` Right ()
  it "preserves contracts in closed fixture elaboration and final frontend elaboration" $ do
    let source = Source "contracts.lawspec" $ unlines
          ["unit contracts", "definition reciprocal (x :: Int8) :: Rational is 1 / x end",
           "adapter :: Int8 -> Int8"]
        pre = S.Binary "!=" (S.Var "input") (S.Number 0)
        closed = S.Contract "reciprocal" [("input",S.Named "Int8")]
          ("output",S.Named "Rational") [pre] []
        adapter = S.Contract "adapter" [("input",S.Named "Int8")]
          ("output",S.Named "Int8") [] [S.Binary ">" (S.Var "output") (S.Number 0)]
    case parseSource source of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right parsed -> do
        let surface = parsed{S.contracts=[closed,adapter]}
        case (elaborateDefinitionUnit [] 64 surface, elaborate 64 [surface] []) of
          (Right unit,Right program) -> do
            map contractDeclaration (unitContracts unit) `shouldBe` [Id "contracts::reciprocal"]
            let final = concatMap unitContracts (programUnits program)
            take 1 final `shouldBe` unitContracts unit
            length final `shouldBe` 2
            case prepareDefinitions (Program 64 [] [unit]) of
              Left diagnostics -> expectationFailure (show diagnostics)
              Right run -> do
                run (Id "contracts::reciprocal") [ScalarValue (SInteger "Int8" 2)]
                  `shouldBe` Right (ScalarValue (SRational 1 2))
                run (Id "contracts::reciprocal") [ScalarValue (SInteger "Int8" 0)]
                  `shouldBe` Left "contracts::reciprocal: precondition failed"
          other -> expectationFailure (show other)
  it "admits and executes partial bodies only under proved definition contracts" $ do
    mapM_ (\bits -> do
      let program = Program bits [] Fixture.validUnits
      validateProgram program `shouldBe` Right ()
      case prepareDefinitions program of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right run -> do
          run (Id "reciprocal") [ScalarValue (SInteger "Int8" 2)]
            `shouldBe` Right (ScalarValue (SRational 1 2))
          run (Id "reciprocal") [ScalarValue (SInteger "Int8" 0)]
            `shouldBe` Left "reciprocal: precondition failed"
          run (Id "narrow") [ScalarValue (SInteger "Int8" 126)]
            `shouldBe` Right (ScalarValue (SInteger "Int8" 127))
          run (Id "narrow") [ScalarValue (SInteger "Int8" 127)]
            `shouldBe` Left "narrow: precondition failed"
          run (Id "caller") [ScalarValue (SInteger "Int8" 1)]
            `shouldBe` Right (ScalarValue (SInteger "Integer" 2))) [32,64]
  it "plans and emits admitted contracted definitions for every backend" $ do
    mapM_ (\bits -> case planTesting (Program bits [] Fixture.validUnits) of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets) [32,64]
  it "rejects dropped, duplicate and unproved contracts at whole-program admission" $ do
    let dropped = map (\u -> u{unitContracts=[]}) Fixture.validUnits
    mapM_ (\units -> validateProgram (Program 64 [] units) `shouldSatisfy` isLeft)
      (dropped : Fixture.invalidUnits)
  it "rejects unchecked calls to a contracted definition at whole-program admission" $ do
    let units = map (\u -> u{unitContracts=filter ((/= Id "caller") . contractDeclaration)
          (unitContracts u)}) Fixture.validUnits
    validateProgram (Program 64 [] units) `shouldSatisfy` isLeft
  it "keeps adapter contracts outside the closed definition proof audit" $ do
    let adapter = Declaration (Id "adapter") "adapter" (Arrow int int) origin
        c = contract "adapter" int [] [operation Greater (value "result" int) (number 0)]
        program = Program 64 [] [Unit (Id "unit") [adapter] [c] [] [] []]
    validateProgram program `shouldBe` Right ()
    case prepareDefinitions program of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right run -> run (Id "adapter") [ScalarValue (SInteger "Int8" 1)] `shouldSatisfy` isLeft
  it "enforces closed definition preconditions before returning a value" $ do
    let d = definition "identity" (value "x" int)
        c = contract "identity" int [operation Greater (value "argument" int) (number 0)] []
        program = Program 64 [] [Unit (Id "unit") [definitionDeclaration d] [c] [] [d] []]
    case prepareDefinitions program of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right run -> do
        run (Id "identity") [ScalarValue (SInteger "Int8" 1)] `shouldBe` Right (ScalarValue (SInteger "Int8" 1))
        run (Id "identity") [ScalarValue (SInteger "Int8" 0)] `shouldBe` Left "identity: precondition failed"
  it "stops ordered runtime refinements at a false precondition" $ do
    let d = definition "identity" (value "x" int)
        nonzero = operation NotEqual (value "argument" int) (number 0)
        positiveReciprocal = operation Greater (operation Divide (number 1) (value "argument" int)) (number 0)
        c = contract "identity" int [nonzero,positiveReciprocal] []
        program = Program 64 [] [Unit (Id "unit") [definitionDeclaration d] [c] [] [d] []]
    case prepareDefinitions program of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right run -> do
        run (Id "identity") [ScalarValue (SInteger "Int8" 0)] `shouldBe` Left "identity: precondition failed"
        run (Id "identity") [ScalarValue (SInteger "Int8" 2)] `shouldBe` Right (ScalarValue (SInteger "Int8" 2))
  it "binds runtime contracts by identity rather than definition parameter spelling" $ do
    let d = definition "next" (operation Add (value "x" int) (number 1))
        post = operation Equal (value "result" integer) (operation Add (value "argument" int) (number 1))
        c = contract "next" integer [] [post]
        program = Program 64 [] [Unit (Id "unit") [definitionDeclaration d] [c] [] [d] []]
    case prepareDefinitions program of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right run -> run (Id "next") [ScalarValue (SInteger "Int8" 127)] `shouldBe` Right (ScalarValue (SInteger "Integer" 128))
  it "rejects duplicate and unproved definition contracts before closed execution" $ do
    let d = definition "identity" (value "x" int)
        c = contract "identity" int [] []
        wrong = c{contractPostconditions=[operation Less (value "result" int) (number 0)]}
        program cs = Program 64 [] [Unit (Id "unit") [definitionDeclaration d] cs [] [d] []]
    isLeft (prepareDefinitions (program [c,c])) `shouldBe` True
    isLeft (prepareDefinitions (program [wrong])) `shouldBe` True
  it "does not merge sibling field domains when Core reuses a branch-local identity" $ do
    let mixed = Constructor "Mixed" []
        wide = scalarType "Int64"
        schema = DataDeclaration (Id "Mixed") "Mixed" []
          [DataConstructor (Id "Mixed::Small") "Small" [Binder (Id "small") "value" int] [] origin [] [],
           DataConstructor (Id "Mixed::Large") "Large" [Binder (Id "large") "value" wide] [] origin [] []] origin Nothing
        make large = Definition
          (Declaration (Id "mixed") "mixed" (Arrow mixed integer) origin)
          [Binder (Id "input") "input" mixed]
          (Expr integer (Match (value "input" mixed)
            [MatchCase (Id "Mixed::Small") [Binder (Id "field") "field" int]
               (operation Add (value "field" int) (number 129)),
             MatchCase (Id "Mixed::Large") [Binder (Id "field") "field" wide] large]) origin)
        c = Contract (Id "mixed") [Binder (Id "argument") "argument" mixed]
          (Binder (Id "result") "result" integer) []
          [operation Greater (value "result" integer) (number 0)] []
    validateDefinitionContracts 64 [schema] [make (number 1)] [c] `shouldBe` Right ()
    validateDefinitionContracts 64 [schema]
      [make (operation Add (value "field" wide) (number 129))] [c] `shouldSatisfy` isLeft
  it "proves each result branch using only its local field domains" $ do
    let list = Constructor "List" [TypeArgument int]
        make offset = Definition
          (Declaration (Id "first") "first" (Arrow list integer) origin)
          [Binder (Id "xs") "xs" list]
          (Expr integer (Match (value "xs" list)
            [MatchCase (Id "List::Nil") [] (number 1),
             MatchCase (Id "List::Cons") [Binder (Id "head") "head" int, Binder (Id "tail") "tail" list]
               (operation Add (value "head" int) (number offset))]) origin)
        c = Contract (Id "first") [Binder (Id "argument") "argument" list]
          (Binder (Id "result") "result" integer) []
          [operation Greater (value "result" integer) (number 0)] []
    validateDefinitionContracts 64 [] [make 129] [c] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [make 128] [c] `shouldSatisfy` isLeft
  it "uses primitive bounds in result and conversion obligations" $ do
    let promoted = operation Add (value "x" int) (number 1)
        d = definition "next" promoted
        upper = operation LessEqual (value "result" integer) (number 128)
        tooLow = operation LessEqual (value "result" integer) (number 127)
        narrow = definition "narrow" (Expr int (Convert Explicit int promoted) origin)
        pre = operation Less (value "argument" int) (number 127)
    validateDefinitionContracts 64 [] [d] [contract "next" integer [] [upper]] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [d] [contract "next" integer [] [tooLow]] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [narrow] [contract "narrow" int [pre] []] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [narrow] [] `shouldSatisfy` isLeft
  it "uses checked input assumptions to justify a partial body" $ do
    let body = operation Divide (number 1) (value "x" int)
        d = definition "reciprocal" body
        nonzero = operation NotEqual (value "argument" int) (number 0)
        c = contract "reciprocal" (expressionType body) [nonzero] []
    validateDefinitionContracts 64 [] [d] [c] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [d] [] `shouldSatisfy` isLeft
  it "proves promoted affine results and rejects incorrect result claims" $ do
    let d = definition "next" (operation Add (value "x" int) (number 1))
        positive = operation GreaterEqual (value "argument" int) (number 0)
        post = operation Greater (value "result" integer) (number 0)
        wrong = operation Less (value "result" integer) (number 0)
    validateDefinitionContracts 64 [] [d] [contract "next" integer [positive] [post]] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [d] [contract "next" integer [positive] [wrong]] `shouldSatisfy` isLeft
  it "audits preconditions in order before trusting their truth" $ do
    let d = definition "identity" (value "x" int)
        nonzero = operation NotEqual (value "argument" int) (number 0)
        positiveReciprocal = operation Greater (operation Divide (number 1) (value "argument" int)) (number 0)
    validateDefinitionContracts 64 [] [d]
      [contract "identity" int [nonzero,positiveReciprocal] []] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [d]
      [contract "identity" int [positiveReciprocal,nonzero] []] `shouldSatisfy` isLeft
  it "checks callee preconditions at each call site" $ do
    let callee = definition "callee" (value "x" int)
        c = contract "callee" int [operation Greater (value "argument" int) (number 0)] []
        call = Expr int (ExternalCall (Id "callee") [value "x" int]) origin
        guarded = Expr boolean (ShortCircuit And (operation Greater (value "x" int) (number 0))
          (operation Greater call (number 0))) origin
    validateDefinitionContracts 64 [] [callee,definition "guarded" guarded] [c] `shouldBe` Right ()
    validateDefinitionContracts 64 [] [callee,definition "unguarded" call] [c] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [callee,definition "assumed" call]
      [c,contract "assumed" int [operation GreaterEqual (value "argument" int) (number 1)] []] `shouldBe` Right ()
  it "checks postcondition definedness instead of treating proof as evaluation" $ do
    let d = definition "zero" (number 0)
        post = operation Equal (operation Divide (number 1) (value "result" integer)) (number 1)
    validateDefinitionContracts 64 [] [d] [contract "zero" integer [] [post]] `shouldSatisfy` isLeft
  it "validates contract types, identities, scopes, and constants before proof" $ do
    let d = definition "identity" (value "x" int)
        c = contract "identity" int [] []
        malformed = Expr boolean (ShortCircuit Or (Expr boolean (Constant (SBool True)) origin)
          (operation Equal (Expr (scalarType "Rational") (Constant (SRational 1 0)) origin) (number 0))) origin
    validateDefinitionContracts 64 [] [d] [c,c] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [d] [c{contractDeclaration=Id "missing"}] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [d] [c{contractPreconditions=[value "result" boolean]}] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [d] [c{contractPreconditions=[number 1]}] `shouldSatisfy` isLeft
    validateDefinitionContracts 64 [] [d] [c{contractPreconditions=[malformed]}] `shouldSatisfy` isLeft
  it "rejects recursive contract evaluation and dependencies through contracts" $ do
    let d = definition "identity" (Expr boolean (Constant (SBool True)) origin)
        recursive = Expr boolean (ExternalCall (Id "identity") [value "argument" int]) origin
        c = contract "identity" boolean [recursive] []
    validateDefinitionContracts 64 [] [d] [c] `shouldSatisfy` isLeft
    let helper = definition "helper" (Expr boolean (ExternalCall (Id "identity") [value "x" int]) origin)
        throughHelper = Expr boolean (ExternalCall (Id "helper") [value "argument" int]) origin
    validateDefinitionContracts 64 [] [d,helper] [c{contractPreconditions=[throughHelper]}] `shouldSatisfy` isLeft
  it "freshens constructor binders before using outer scalar facts" $ do
    let x = Id "x"
        input = Id "input"
        one = T.Literal (SInteger "Int8" 1)
        zero = T.Literal (SInteger "Int8" 0)
        body = T.DataMatch (T.Variable input)
          [(Id "Box::Box",[x],T.Division False Divide one (T.Variable x))]
        definition = T.ProofDefinition (Id "bad") "bad" Nothing [input,x] body
          [T.ExactComparison NotEqual (T.Variable x) zero]
    T.audit [definition] `shouldSatisfy` isLeft
  it "avoids capture when substituting tagged match predicates" $ do
    let x = Id "x"
        y = Id "y"
        source = Id "source"
        term = T.DataMatch (T.Variable source)
          [(Id "Box::Box",[y],T.ExactComparison Greater (T.Variable y) (T.Variable x))]
        replaced = T.substituteProof (M.singleton x (T.Variable y)) term
    case replaced of
      T.DataMatch _ [(_, [fresh], T.ExactComparison Greater (T.Variable local) (T.Variable outer))] -> do
        fresh `shouldNotBe` y
        local `shouldBe` fresh
        outer `shouldBe` y
      _ -> expectationFailure (show replaced)
  it "does not capture outer facts when introducing a hypothetical List member" $ do
    let xs = Id "xs"
        x = Id "x"
        callee = Id "callee"
        caller = Id "caller"
        positive name = T.ExactComparison Greater (T.Variable name) (T.Literal (SInteger "Integer" 0))
        definitions =
          [T.ProofDefinition callee "callee" Nothing [xs] (T.Literal (SBool True)) [],
           T.ProofDefinition caller "caller" Nothing [xs,x] (T.Call callee [T.Variable xs]) []]
        contracts =
          [T.ProofContract callee (Id "result1") [T.AllElements (T.Variable xs) x (positive x)] [],
           T.ProofContract caller (Id "result2") [positive x] []]
    T.auditWithContracts contracts definitions `shouldSatisfy` isLeft
  it "freshens List pattern binders before using outer scalar facts" $ do
    let xs = Id "xs"
        x = Id "x"
        one = T.Literal (SInteger "Integer" 1)
        body = T.ListMatch (T.Variable xs) one x (Id "rest")
          (T.Division False Divide one (T.Variable x))
        definition = T.ProofDefinition (Id "bad") "bad" Nothing [xs,x] body
          [T.ExactComparison NotEqual (T.Variable x) (T.Literal (SInteger "Integer" 0))]
    T.audit [definition] `shouldSatisfy` isLeft
  it "substitutes List match branches without capturing either pattern binder" $ do
    let term = T.ListMatch (T.Variable (Id "xs")) (T.Variable (Id "free"))
          (Id "head") (Id "tail")
          (T.Sequence [T.Variable (Id "head"),T.Variable (Id "tail"),T.Variable (Id "free")])
        changed = T.substituteProof (M.singleton (Id "free") (T.Variable (Id "head"))) term
    case changed of
      T.ListMatch _ (T.Variable nilFree) first rest (T.Sequence [T.Variable h,T.Variable t,T.Variable free]) -> do
        first `shouldNotBe` Id "head"
        h `shouldBe` first
        t `shouldBe` rest
        nilFree `shouldBe` Id "head"
        free `shouldBe` Id "head"
      other -> expectationFailure (show other)
  it "avoids capture when substituting universal element contracts" $ do
    let term = T.AllElements (T.Variable (Id "xs")) (Id "element")
          (T.ExactComparison Greater (T.Variable (Id "element")) (T.Variable (Id "floor")))
    case T.substituteProof (M.singleton (Id "floor") (T.Variable (Id "element"))) term of
      T.AllElements _ binder (T.ExactComparison Greater (T.Variable bound) (T.Variable free)) -> do
        binder `shouldNotBe` Id "element"
        bound `shouldBe` binder
        free `shouldBe` Id "element"
      other -> expectationFailure (show other)
  it "avoids capturing free variables while substituting contracts" $ do
    let term = T.Match (T.Variable (Id "input"))
          [([Id "bound"], T.ExactArithmetic Add (T.Variable (Id "value")) (T.Variable (Id "bound")))]
    case T.substituteProof (M.singleton (Id "value") (T.Variable (Id "bound"))) term of
      T.Match _ [([renamed],T.ExactArithmetic Add (T.Variable free) (T.Variable local))] -> do
        renamed `shouldNotBe` Id "bound"
        free `shouldBe` Id "bound"
        local `shouldBe` renamed
      other -> expectationFailure (show other)
