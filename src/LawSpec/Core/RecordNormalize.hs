-- | Resolve structural products after type substitution, before validation,
-- evaluation or planning. Nominal identities remain opaque. Every original
-- constructor restriction sequence is audited before equivalent products share
-- a declaration, including sequences that normalize to the same descriptor.
module LawSpec.Core.RecordNormalize (normalizeProgramRecords) where

import Control.Monad (unless, forM)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common (Diagnostic(..))
import LawSpec.Core
import LawSpec.Core.RecordIdentity
import LawSpec.Core.Total (constructorProofContracts)
import qualified LawSpec.Core.Machine as Machine
import qualified LawSpec.Core.Program as Scenario

data Normalizing = Normalizing
  { originals :: M.Map Id DataDeclaration
  , products :: M.Map Id DataDeclaration
  , productOrder :: [Id]
  , typeResults :: M.Map Type Type
  , active :: S.Set Type }
type Normalize = StateT Normalizing (Either String)

normalizeProgramRecords :: Program -> Either [Diagnostic] Program
normalizeProgramRecords program
  | all ((== Nothing) . dataStructural) (programDataDeclarations program) = Right program
  | otherwise = do
      (result,_) <- diagnostic $ runStateT rewrite (Normalizing source M.empty [] M.empty S.empty)
      -- Check all occurrences before interning. A descriptor deliberately
      -- excludes cross-field source order; an unsafe order must still fail.
      _ <- constructorProofContracts (programMachineBits program) (programDataDeclarations result)
      declarations <- diagnostic (internRecordDeclarations (programDataDeclarations result))
      pure result{programDataDeclarations=declarations}
  where
    source = M.fromListWith (\_ first -> first) [(dataId d,d) | d <- programDataDeclarations program]
    diagnostic = either (Left . pure . (\message -> Diagnostic "record-type" message Nothing)) Right
    rewrite = do
      declarations <- mapM dataDeclaration (programDataDeclarations program)
      units <- mapM unit (programUnits program)
      state <- get
      let present = S.fromList (map dataId declarations)
          extra = [d | identity <- reverse (productOrder state),identity `S.notMember` present,
                       Just d <- [M.lookup identity (products state)]]
      pure program{programDataDeclarations=declarations++extra,programUnits=units}

checked :: Either String a -> Normalize a
checked = lift

findData :: Id -> Normalize (Maybe DataDeclaration)
findData identity = gets (\state -> case M.lookup identity (products state) of
  Just d -> Just d
  Nothing -> M.lookup identity (originals state))

remember :: DataDeclaration -> Normalize ()
remember declaration = do
  checked (validateRecordDeclaration declaration)
  known <- gets (M.lookup (dataId declaration) . products)
  case known of
    Just old -> unless (fmap structuralDescriptor (dataStructural old) == fmap structuralDescriptor (dataStructural declaration))
      (checked (Left ("structural record digest collision: " ++ idText (dataId declaration))))
    Nothing -> modify (\state -> state{products=M.insert (dataId declaration) declaration (products state),
      productOrder=dataId declaration:productOrder state})

ty :: Type -> Normalize Type
ty value = do
  cached <- gets (M.lookup value . typeResults)
  case cached of
    Just result -> pure result
    Nothing -> do
      result <- case value of
        TypeVariable _ -> pure value
        Arrow a b -> Arrow <$> ty a <*> ty b
        Constructor name arguments -> do
          arguments' <- mapM argument arguments
          declaration <- findData (Id name)
          case declaration of
            Just d | dataStructural d /= Nothing -> do
              let actual = [a | TypeArgument a <- arguments']
              unless (length actual == length arguments')
                (checked (Left "structural record arguments must have kind Type"))
              (made,remaining) <- record d actual
              pure (Constructor (idText (dataId made)) (map TypeArgument remaining))
            _ -> pure (Constructor name arguments')
      modify (\state -> state{typeResults=M.insert result result (M.insert value result (typeResults state))})
      pure result
  where
    argument (TypeArgument value') = TypeArgument <$> ty value'
    argument other = pure other

record :: DataDeclaration -> [Type] -> Normalize (DataDeclaration,[Type])
record original arguments = do
  let key=Constructor (idText (dataId original)) (map TypeArgument arguments)
  recursive <- gets (S.member key . active)
  unless (not recursive) (checked (Left "recursive structural record descriptor without a nominal boundary"))
  modify (\state -> state{active=S.insert key (active state)})
  (instanceDeclaration,remaining) <- checked (instantiateRecordDeclaration original arguments (dataOrigin original))
  constructor <- case dataConstructors instanceDeclaration of
    [c] -> pure c
    _ -> checked (Left "a structural record requires one constructor")
  fields <- mapM (ty . binderType) (constructorFields constructor)
  predicates <- mapM expression (constructorPredicates constructor)
  (rebuilt,parameters) <- checked (rebuildRecordDeclaration instanceDeclaration (dataParameters instanceDeclaration)
    fields predicates (dataOrigin original))
  let made=rebuilt{dataConstructors=[c{constructorOrigin=constructorOrigin originalConstructor}
        | c <- dataConstructors rebuilt,originalConstructor <- take 1 (dataConstructors original)]}
  let bindings=M.fromList (zip (dataParameters instanceDeclaration) remaining)
  actual <- mapM (\parameter -> maybe (checked (Left "lost structural record parameter during normalization")) pure
    (M.lookup parameter bindings)) parameters
  remember made
  modify (\state -> state{active=S.delete key (active state)})
  pure (made,actual)

dataDeclaration :: DataDeclaration -> Normalize DataDeclaration
dataDeclaration declaration
  | dataStructural declaration /= Nothing = do
      -- Do not use the type memo here: each original sequence needs its audit.
      fst <$> record declaration (map TypeVariable (dataParameters declaration))
  | otherwise = do
      constructors <- forM (dataConstructors declaration) $ \constructor -> do
        fields <- mapM binder (constructorFields constructor)
        predicates <- mapM expression (constructorPredicates constructor)
        equations <- mapM (\(parameter,value) -> (,) parameter <$> ty value) (constructorEquations constructor)
        pure constructor{constructorFields=fields,constructorPredicates=predicates,constructorEquations=equations}
      pure declaration{dataConstructors=constructors}

binder :: Binder -> Normalize Binder
binder value = do
  wanted <- ty (binderType value)
  pure value{binderType=wanted}

ability :: AbilityRef -> Normalize AbilityRef
ability (AbilityRef identity arguments) = AbilityRef identity <$> mapM ty arguments

operation :: Operation -> Normalize Operation
operation (Operation ref name) = flip Operation name <$> ability ref

evidence :: Evidence -> Normalize Evidence
evidence (Numeric value) = Numeric <$> ty value
evidence (Structural value) = Structural <$> ty value

constructorAt :: Type -> Type -> Id -> Normalize Id
constructorAt before after identity = case (before,after) of
  (Constructor old _,Constructor new _) -> do
    original <- findData (Id old)
    case original of
      Just d | dataStructural d /= Nothing,
        identity `elem` map constructorId (dataConstructors d) -> do
          resolved <- findData (Id new)
          case resolved of
            Just made | [c] <- dataConstructors made -> pure (constructorId c)
            _ -> checked (Left "missing normalized structural record constructor")
      _ -> pure identity
  _ -> pure identity

expression :: Expr -> Normalize Expr
expression original = do
  children' <- traverseChildren expression original
  result <- ty (expressionType original)
  node <- case expressionNode children' of
    Construct identity values -> Construct <$> constructorAt (expressionType original) result identity <*> pure values
    Binary op ev a b -> Binary op <$> evidence ev <*> pure a <*> pure b
    Let bound value body -> Let <$> binder bound <*> pure value <*> pure body
    Match value branches -> do
      let before=case expressionNode original of Match subject _ -> expressionType subject; _ -> expressionType value
      branches' <- forM branches $ \branch -> do
        identity <- constructorAt before (expressionType value) (caseConstructor branch)
        binders <- mapM binder (caseBinders branch)
        pure branch{caseConstructor=identity,caseBinders=binders}
      pure (Match value branches')
    Project identity index value -> do
      let before=case expressionNode original of Project _ _ subject -> expressionType subject; _ -> expressionType value
      Project <$> constructorAt before (expressionType value) identity <*> pure index <*> pure value
    Update identity index value field -> do
      let before=case expressionNode original of Update _ _ subject _ -> expressionType subject; _ -> expressionType value
      Update <$> constructorAt before (expressionType value) identity <*> pure index <*> pure value <*> pure field
    AllElements value bound predicate -> AllElements value <$> binder bound <*> pure predicate
    AllPayloads value predicates -> AllPayloads value <$> mapM (\(bound,predicate) -> (,) <$> binder bound <*> pure predicate) predicates
    Convert conversion target value -> Convert conversion <$> ty target <*> pure value
    Perform op values -> Perform <$> operation op <*> pure values
    Calls op values -> Calls <$> operation op <*> pure values
    Handle handling value -> do
      handling' <- case handling of
        CatchFailure ref -> CatchFailure <$> ability ref
        WithHandler ref handler -> flip WithHandler handler <$> ability ref
      pure (Handle handling' value)
    other -> pure other
  pure children'{expressionType=result,expressionNode=node}

quantifier :: Quantifier -> Normalize Quantifier
quantifier q = Quantifier <$> binder (quantifiedBinder q) <*> mapM expression (quantifiedPredicates q)
  <*> mapM (\(op,value) -> (,) op <$> expression value) (quantifiedBounds q)

proposition :: Proposition -> Normalize Proposition
proposition value = case value of
  Equation ev a b -> Equation <$> evidence ev <*> expression a <*> expression b
  Implication condition body -> Implication <$> expression condition <*> proposition body
  Conjunction bodies -> Conjunction <$> mapM proposition bodies
  Quantified kind bound body -> Quantified kind <$> quantifier bound <*> proposition body
  Negation body -> Negation <$> proposition body

draw :: Draw -> Normalize Draw
draw value = case value of
  DrawAny wanted aim -> DrawAny <$> ty wanted <*> traverse quantifier aim
  DrawOneOf wanted values -> DrawOneOf <$> ty wanted <*> mapM expression values
  DrawFrequency choices -> DrawFrequency <$> mapM (\(weight,choice) -> (,) weight <$> draw choice) choices
  DrawSuchThat choice bound predicate limit -> DrawSuchThat <$> draw choice <*> binder bound <*> expression predicate <*> pure limit
  DrawBind bound first rest -> DrawBind <$> binder bound <*> draw first <*> draw rest

harness :: LawHarness -> Normalize LawHarness
harness h = do
  covers <- mapM (\c -> (\value -> c{coverWhen=value}) <$> expression (coverWhen c)) (harnessCover h)
  classifications <- mapM (\(value,label) -> (\result -> (result,label)) <$> expression value) (harnessClassify h)
  labels <- mapM expression (harnessLabels h)
  target <- traverse expression (harnessTarget h)
  draws <- mapM (\(identity,name,choice) -> (\result -> (identity,name,result)) <$> draw choice) (harnessDraws h)
  witnesses <- mapM (\w -> (\value -> w{witnessValue=value}) <$> expression (witnessValue w)) (harnessWitnesses h)
  searches <- mapM (\(identity,path,name,choice) -> (\result -> (identity,path,name,result)) <$> draw choice) (harnessSearches h)
  pure h{harnessCover=covers,harnessClassify=classifications,harnessLabels=labels,harnessTarget=target,
    harnessDraws=draws,harnessWitnesses=witnesses,harnessSearches=searches}

property :: Property -> Normalize Property
property p = do
  inputs <- mapM quantifier (propertyInputs p)
  body <- proposition (propertyBody p)
  examples <- forM (propertyExamples p) $ \example -> Example (exampleName example)
    <$> mapM (\(identity,value) -> (,) identity <$> expression value) (exampleBindings example)
    <*> mapM proposition (exampleExpectations example)
  handlers <- mapM (\(ref,handler) -> (\result -> (result,handler)) <$> ability ref) (propertyHandlers p)
  resources <- forM (propertyResources p) $ \r -> do
    bound <- binder (resourceBinder r)
    acquire <- expression (resourceAcquire r)
    release <- expression (resourceRelease r)
    reset <- traverse expression (resourceReset r)
    pure r{resourceBinder=bound,resourceAcquire=acquire,resourceRelease=release,resourceReset=reset}
  selected <- harness (propertyHarness p)
  pure p{propertyInputs=inputs,propertyBody=body,propertyExamples=examples,propertyHandlers=handlers,
    propertyResources=resources,propertyHarness=selected}

declaration :: Declaration -> Normalize Declaration
declaration d = do
  wanted <- ty (declarationType d)
  uses <- mapM ability (declarationUses d)
  pure d{declarationType=wanted,declarationUses=uses}

definition :: Definition -> Normalize Definition
definition d = do
  signature <- declaration (definitionDeclaration d)
  arguments <- mapM binder (definitionArguments d)
  body <- expression (definitionBody d)
  pure d{definitionDeclaration=signature,definitionArguments=arguments,definitionBody=body}

contract :: Contract -> Normalize Contract
contract c = Contract (contractDeclaration c) <$> mapM binder (contractArguments c) <*> binder (contractResult c)
  <*> mapM expression (contractPreconditions c) <*> mapM expression (contractPostconditions c)
  <*> mapM expression (contractRuntimePostconditions c)

unit :: Unit -> Normalize Unit
unit u = do
  signatures <- mapM declaration (unitDeclarations u)
  contracts <- mapM contract (unitContracts u)
  properties <- mapM property (unitProperties u)
  definitions <- mapM definition (unitDefinitions u)
  sessions <- forM (unitSessions u) $ \s -> do
    steps <- mapM (\(sending,value) -> (,) sending <$> ty value) (sessionSteps s)
    pure s{sessionSteps=steps}
  mailboxes <- mapM (\m -> (\value -> m{mailboxType=value}) <$> ty (mailboxType m)) (unitMailboxes u)
  abilities <- forM (unitAbilities u) $ \a -> do
    operations <- mapM (\(name,value) -> (,) name <$> ty value) (abilityOperations a)
    arguments <- mapM ty (abilityArguments a)
    failures <- mapM (\(name,ref) -> (,) name <$> ability ref) (abilityFailures a)
    resource <- traverse ty (abilityResource a)
    pure a{abilityOperations=operations,abilityArguments=arguments,abilityFailures=failures,abilityResource=resource}
  handlers <- forM (unitHandlers u) $ \h -> do
    ref <- ability (handlerAbility h)
    also <- mapM ability (handlerAlso h)
    state <- traverse (\(wanted,value) -> (,) <$> ty wanted <*> expression value) (handlerState h)
    pure h{handlerAbility=ref,handlerAlso=also,handlerState=state}
  failures <- forM (unitFailureBindings u) $ \f -> do
    wanted <- ty (failureType f)
    constructor <- constructorAt (failureType f) wanted (failureConstructor f)
    pure f{failureType=wanted,failureConstructor=constructor}
  settings <- traverse (\h -> (\benchmarks -> h{harnessBenchmarks=benchmarks}) <$>
    mapM (\(name,value) -> (,) name <$> expression value) (harnessBenchmarks h)) (unitHarnessSettings u)
  machines <- mapM machine (unitMachines u)
  pure u{unitDeclarations=signatures,unitContracts=contracts,unitProperties=properties,unitDefinitions=definitions,
    unitSessions=sessions,unitMailboxes=mailboxes,unitAbilities=abilities,unitHandlers=handlers,
    unitFailureBindings=failures,unitHarnessSettings=settings,unitMachines=machines}

-- Model and scenario command references are nominal function identities. Their
-- signatures above carry the types. Only closed structural state names and
-- payload-free constructor constants require retargeting here; wire descriptors
-- are derived later from the normalized signatures, sessions and mailboxes.
machine :: Machine.Machine Id -> Normalize (Machine.Machine Id)
machine m = do
  known <- findData (Id (Machine.machineState m))
  state <- case known of
    Just d | dataStructural d /= Nothing,null (dataParameters d) -> do
      value <- ty (scalarType (idText (dataId d)))
      case value of Constructor name [] -> pure name; _ -> checked (Left "invalid structural model state")
    _ -> pure (Machine.machineState m)
  scenarios <- mapM scenario (Machine.machineScenarios m)
  pure m{Machine.machineState=state,Machine.machineScenarios=scenarios}

scenario :: Scenario.Program -> Normalize Scenario.Program
scenario p = do
  acts <- mapM act (Scenario.programActs p)
  pure p{Scenario.programActs=acts}
  where
    act value = case value of
      Scenario.Invoke name bound values -> Scenario.Invoke name bound <$> mapM operand values
      Scenario.Deliver channel value' -> Scenario.Deliver channel <$> operand value'
      Scenario.Accept channel name handler -> Scenario.Accept channel name <$> traverse (mapM act) handler
      Scenario.Fork branches -> Scenario.Fork <$> mapM (mapM act) branches
      Scenario.Assert name value' -> Scenario.Assert name <$> constant value'
    operand (Scenario.Variable name) = pure (Scenario.Variable name)
    operand (Scenario.Literal value) = Scenario.Literal <$> constant value
    constant value@(Scenario.TagConst tag) = do
      sources <- gets originals
      case [d | d <- M.elems sources,dataStructural d /= Nothing,null (dataParameters d),
                c <- dataConstructors d,null (constructorFields c),constructorId c == Id tag] of
        d:_ -> do
          target <- ty (scalarType (idText (dataId d)))
          Scenario.TagConst . idText <$> constructorAt (scalarType (idText (dataId d))) target (Id tag)
        [] -> pure value
    constant value = pure value
