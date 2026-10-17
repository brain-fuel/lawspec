-- | Source data declarations are resolved once, before core validation. Target
-- emitters only see qualified identities and specialized core field types.
module LawSpec.Data (elaborateDataDeclarations, elaborateDataDeclarationsWithProfile, elaborateDataDeclarationsWithContext, dataDeclarationHeaders, qualifyDataNames, inlineFieldDefinitions, fieldDefinitionChecks, fieldDefinitionDependencies, migrationConstructorSources) where

import Control.Monad (forM, unless)
import Data.List (nub)
import LawSpec.Elaboration (coreTypeWithSourceRecords, elaborateResolvedWithSourceRecords)
import qualified LawSpec.SourceContext as Source
import qualified LawSpec.SourceRecords as SourceRecords
import qualified LawSpec.Inference as Infer
import LawSpec.Refinement (substituteType)
import Control.Monad.State.Strict (execStateT,evalStateT,runStateT)
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Scalar (primitive)
import LawSpec.IndexTerm (FamilyIndex(..))

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
elaborateDataDeclarations :: [S.Unit] -> Either [Diagnostic] [C.DataDeclaration]
elaborateDataDeclarations = elaborateDataDeclarationsWithProfile 64

-- | Data declarations are resolved once, to qualified identities, so emitters
-- never resolve a type name again. ref:DEC-typed-core-boundary
elaborateDataDeclarationsWithProfile :: Int -> [S.Unit] -> Either [Diagnostic] [C.DataDeclaration]
elaborateDataDeclarationsWithProfile bits units = fst <$> elaborateDataDeclarationsWithContext bits units

-- Source signatures survive nominal-field erasure until inference has finished.
-- Headers supply identities and field positions while structural descriptors
-- are built; they are never admitted or returned as executable declarations.
-- Every field/equation is completed before constructor admission checks run.
elaborateDataDeclarationsWithContext :: Int -> [S.Unit] -> Either [Diagnostic] ([C.DataDeclaration],Source.SourceContext)
elaborateDataDeclarationsWithContext bits units = do
  (headers,context) <- dataDeclarationHeaders units
  completed <- forM headers $ \header -> do
    constructors <- forM (C.dataConstructors header) $ \constructor -> case M.lookup (C.constructorId constructor) (Source.constructorSources context) of
      Nothing -> pure (constructor,[])
      Just source -> contextualOrigin (C.constructorOrigin constructor) $ do
        fields <- mapM (coreTypeWithSourceRecords context headers bits) (Source.sourceFields source)
        equations <- mapM (\(name,ty) -> do
          (value,records) <- coreTypeWithSourceRecords context headers bits ty
          pure ((name,value),records)) (Source.sourceEquations source)
        pure (constructor {C.constructorFields=zipWith (\field (ty,_) -> field{C.binderType=ty}) (C.constructorFields constructor) fields,
          C.constructorEquations=map fst equations},concatMap snd fields ++ concatMap snd equations)
    pure (header{C.dataConstructors=map fst constructors},concatMap snd constructors)
  let nominalShapes=map fst completed
      payloadRecords=concatMap snd completed
      shapes=if null payloadRecords then nominalShapes else nominalShapes ++ payloadRecords
  declarationsWithRecords <- forM (zip [(u,d) | u <- units, d <- S.dataTypes u] nominalShapes) $ \((u,source),shape) ->
    contextual (S.dataTypeSpan source) $ do
      let typeVariables = M.fromList (zip (S.dataTypeParameters source) (map C.idText (C.dataParameters shape)))
          substitute = S.mapType (\ty -> case ty of
            S.Variable name -> S.Variable (M.findWithDefault name name typeVariables)
            other -> other) (S.mapExprTypes substitute)
      constructors <- forM (zip (S.dataTypeConstructors source) (C.dataConstructors shape)) $ \(original,constructor) -> do
        let fields = case M.lookup (C.constructorId constructor) (Source.constructorSources context) of
              Just retained -> zip (map fst (S.dataConstructorFields original)) (Source.sourceFields retained)
              Nothing -> [(name,substitute ty) | (name,ty) <- S.dataConstructorFields original]
            identities = zip (map fst fields) (map C.binderId (C.constructorFields constructor))
            resolve name = M.findWithDefault (C.Id (S.unitName u ++ "::" ++ name)) name (M.fromList identities)
        predicates <- fmap concat $ forM (zip [1..] fields) $ \(count,(name,ty)) -> do
          unless (all (checkCapability (coreTypeWithSourceRecords context shapes bits) shapes bits []) (S.typeConstraints ty))
            (Left ("unsatisfied constructor field capability: " ++ name))
          let scope = [(n,rigid (S.baseType t)) | (n,t) <- take count fields]
          mapM (elaborateResolvedWithSourceRecords context False shapes [] bits (C.constructorId constructor) resolve scope)
            (map (S.mapExprTypes rigid) (S.typePredicates (S.Var name) ty))
        pure (constructor{C.constructorPredicates=map fst predicates},concatMap snd predicates)
      pure (shape{C.dataConstructors=map fst constructors},concatMap snd constructors)
  let declarations=map fst declarationsWithRecords
      records=payloadRecords ++ concatMap snd declarationsWithRecords
      result=if null records then declarations else declarations ++ records
  -- Intrinsic predicates may project a canonical product through the generic
  -- storage of a nominal constructor. Reconcile those checked representations
  -- before admission; normalization still audits every constructor occurrence
  -- before interning its descriptor.
  normalized <- normalizeProgramRecords (C.Program bits result [])
  let admitted=C.programDataDeclarations normalized
  _ <- constructorProofContracts bits admitted
  pure (admitted,context)
  where
    -- Nominal parameters are fixed while an invariant is checked. A GADT
    -- branch may refine them locally, just as in structural record predicates.
    rigid=S.mapType (\ty->case ty of S.Variable name->S.Named ('@':name); other->other) (S.mapExprTypes rigid)
    contextualOrigin origin = case origin of
      C.SourceSpan range -> contextual range
      _ -> either (Left . pure . (\message -> Diagnostic "data-type" message Nothing)) Right
    contextual range = either (Left . pure . (\message -> Diagnostic "data-type" message (Just (spanStart range)))) Right

-- | Nominal identities and retained source shapes for the typing stage only.
-- Anonymous slots remain placeholders; these headers are never executable
-- declarations or evidence that any constructor restriction was admitted.
dataDeclarationHeaders :: [S.Unit] -> Either [Diagnostic] ([C.DataDeclaration],Source.SourceContext)
dataDeclarationHeaders units = do
  headers<-concat <$> mapM unit units
  let context=Source.SourceContext (M.fromList (concat
        [constructorSourceEntries False pair | pair<-zip [(owner,declaration) | owner<-units,declaration<-S.dataTypes owner] headers]))
  pure (headers,context)
  where
    unit u = mapM (declaration u) (S.dataTypes u)
    declaration u d = contextual (S.dataTypeSpan d) $ do
      let name = S.dataTypeName d
          identity = typeIdentity u name
          parameter n = C.Id (C.idText identity ++ "::" ++ n)
          parameters = M.fromList [(n, parameter n) | n <- S.dataTypeParameters d]
          localTypes = M.fromList [(S.dataTypeName t, typeIdentity u (S.dataTypeName t)) | t <- S.dataTypes u]
          typeName n = maybe n C.idText (M.lookup n localTypes)
          coreWith variables t = case S.baseType t of
            S.Named n -> Right (C.Constructor (typeName n) [])
            S.Variable n -> Right (C.TypeVariable (M.findWithDefault (parameter ("unbound::" ++ n)) n variables))
            S.Applied n a -> C.Constructor (typeName n) . pure . C.TypeArgument <$> coreWith variables a
            S.Application n as -> C.Constructor (typeName n) <$> mapM (fmap C.TypeArgument . coreWith variables) as
            S.Arrow a b -> C.Arrow <$> coreWith variables a <*> coreWith variables b
            S.Qualified [] a -> coreWith variables a
            -- A temporary header preserves nominal identities and field
            -- positions. The completion pass replaces this slot with the
            -- actual structural type before mandatory constructor validation.
            S.RecordShape _ -> Right (C.scalarType "Unit")
            _ -> Left "unresolved constructor field type"
          sourceVariables = S.typeVariableNames
      unless (primitive name == Nothing && name `notElem` ["Type", "Nullable", "Optional", "List", "Maybe", "Either"])
        (Left ("reserved data type name: " ++ name))
      unless (name `notElem` map S.refinementName (S.refinements u))
        (Left ("data type and refinement share a name: " ++ name))
      constructors <- forM (S.dataTypeConstructors d) $ \constructor -> do
        let tag = C.Id (C.idText identity ++ "::" ++ S.dataConstructorName constructor)
            -- Type variables that are not parameters belong to the constructor.
            existentials = nub [v | (_, ty) <- S.dataConstructorFields constructor ++ S.dataConstructorEquations constructor
                                  , v <- sourceVariables ty, v `notElem` S.dataTypeParameters d]
            existential v = C.Id (C.idText tag ++ "::exists::" ++ v)
            variables = M.union parameters (M.fromList [(v, existential v) | v <- existentials])
        fields <- forM (S.dataConstructorFields constructor) $ \(field, ty) ->
          C.Binder (C.Id (C.idText tag ++ "::" ++ field)) field <$> coreWith variables ty
        equations <- forM (S.dataConstructorEquations constructor) $ \(refined, ty) -> do
          identity' <- maybe (Left (S.dataConstructorName constructor ++ ": " ++ refined ++ " is not a type parameter of " ++ name))
            Right (M.lookup refined parameters)
          (,) identity' <$> coreWith variables ty
        pure (C.DataConstructor tag (S.dataConstructorName constructor) fields [] (C.SourceSpan (S.dataConstructorSpan constructor))
          equations (map existential existentials))
      -- Index tables are keyed by source constructor name until here.
      let index = fmap (\i -> i { familyIndexConstructors =
            [(C.idText identity ++ "::" ++ tag, c) | (tag, c) <- familyIndexConstructors i] }) (S.dataTypeIndex d)
      pure (C.MkDataDeclaration identity name (map parameter (S.dataTypeParameters d)) constructors (C.SourceSpan (S.dataTypeSpan d)) index
        (name `elem` S.handles u) Nothing Nothing)
    typeIdentity u name = C.Id (S.unitName u ++ "::type::" ++ name)
    contextual range = either (Left . pure . (\message -> Diagnostic "data-type" message (Just (spanStart range)))) Right

constructorSourceEntries :: Bool -> ((S.Unit,S.DataTypeDeclaration),C.DataDeclaration) -> [(C.Id,Source.SourceConstructor)]
constructorSourceEntries includeOrdinary ((u,source),header) =
  [(C.constructorId constructor,Source.SourceConstructor
      (map (rewrite . snd) (S.dataConstructorFields original))
      [(parameterName, rewrite ty) | (name,ty) <- S.dataConstructorEquations original,
         Just parameterName <- [lookup name parameters]])
  | (original,constructor) <- zip (S.dataTypeConstructors source) (C.dataConstructors header)
  , includeOrdinary || any (containsRecord . snd) (S.dataConstructorFields original ++ S.dataConstructorEquations original)
  , let parameters=zip (S.dataTypeParameters source) (C.dataParameters header)
        existentialNames=nub [name | (_,ty) <- S.dataConstructorFields original ++ S.dataConstructorEquations original,
          name <- S.typeVariableNames ty,name `notElem` S.dataTypeParameters source]
        variables=parameters ++ zip existentialNames (C.constructorExistentials constructor)
        typeNames=[(S.dataTypeName declaration,S.unitName u ++ "::type::" ++ S.dataTypeName declaration) | declaration <- S.dataTypes u]
        rename name=maybe name id (lookup name typeNames)
        rewrite=S.mapType change (S.mapExprTypes rewrite)
        change ty=case ty of
          S.Variable name -> S.Variable (maybe name C.idText (lookup name variables))
          S.Named name -> S.Named (rename name)
          S.Applied name argument -> S.Applied (rename name) argument
          S.Application name arguments -> S.Application (rename name) arguments
          other -> other]
  where
    containsRecord ty = case S.baseType ty of
      S.RecordShape _ -> True
      S.Applied _ a -> containsRecord a
      S.Application _ values -> any containsRecord values
      S.Arrow a b -> containsRecord a || containsRecord b
      _ -> False

-- | Complete source field restrictions for comparison only. Normal inference
-- keeps its established sparse structural context; capturing ordinary fields
-- must not change how their definitions are checked or instantiated.
migrationConstructorSources :: [S.Unit] -> [C.DataDeclaration] -> [(C.Id,Source.SourceConstructor)]
migrationConstructorSources units declarations = concat
  [constructorSourceEntries True ((unit,source),header) | unit<-units,source<-S.dataTypes unit,
    Just header<-[M.lookup (C.Id (S.unitName unit ++ "::type::" ++ S.dataTypeName source)) known]]
  where known=M.fromList [(C.dataId declaration,declaration) | declaration<-declarations]

-- | Resolve local type and constructor names before generic law expansion. The
-- qualified identities survive imported/reused law bodies without re-resolution.
qualifyDataNames :: S.Unit -> S.Unit
qualifyDataNames unit = unit
  { S.dataTypes = [d{S.dataTypeConstructors=
      [c{S.dataConstructorFields=map pair (S.dataConstructorFields c)} | c <- S.dataTypeConstructors d]}
      | d <- S.dataTypes unit]
  , S.functions = map pair (S.functions unit)
  , S.functionDefinitions = [d
      {S.functionArguments = map pair (S.functionArguments d)
      , S.functionResult = ty (S.functionResult d)
      , S.functionRequirements = map constraint (S.functionRequirements d)
      , S.functionBody = expr (S.functionBody d)} | d <- S.functionDefinitions unit]
  , S.laws = map law (S.laws unit)
  -- Protocol steps and mailboxes name data types too.
  , S.protocols = [p {S.protocolSteps = map step (S.protocolSteps p)} | p <- S.protocols unit]
  , S.mailboxes = [(n, ty t, at) | (n, t, at) <- S.mailboxes unit]
  -- So do ability instances, handler states and operation types.
  , S.abilities = [a {S.abilityOperations = map pair (S.abilityOperations a), S.abilityLaws = map law (S.abilityLaws a)
                     , S.abilityFailures = map pair (S.abilityFailures a), S.abilityResource = ty <$> S.abilityResource a} | a <- S.abilities unit]
  , S.handlerDeclarations = [h {S.handlerAbility = ty (S.handlerAbility h), S.handlerAlso = map ty (S.handlerAlso h),
      S.handlerState = (\(n, t, e) -> (n, ty t, expr e)) <$> S.handlerState h} | h <- S.handlerDeclarations unit]
  , S.declaredUses = [(n, map ty ts) | (n, ts) <- S.declaredUses unit]
  , S.abilityRows = [(n, map ty ts) | (n, ts) <- S.abilityRows unit]
  , S.lawAssignments = [(n, [(ty t, c) | (t, c) <- a]) | (n, a) <- S.lawAssignments unit]
  , S.resourceDeclarations = [r {S.resourceType = ty (S.resourceType r), S.resourceAcquire = expr (S.resourceAcquire r),
      S.resourceRelease = fmap expr (S.resourceRelease r), S.resourceReset = fmap (fmap expr) (S.resourceReset r)}
      | r <- S.resourceDeclarations unit]
  -- A harness's strategies and expressions name data types and constructors.
  , S.lawHarness = [(n, harnessPlan plan) | (n, plan) <- S.lawHarness unit]
  , S.unitHarness = (\h -> h {S.harnessItems = map harnessItem (S.harnessItems h)}) <$> S.unitHarness unit
  , S.contracts = [c {S.contractArguments = map pair (S.contractArguments c),
      S.contractResult = pair (S.contractResult c),
      S.contractPreconditions = map expr (S.contractPreconditions c),
      S.contractPostconditions = map expr (S.contractPostconditions c)} | c <- S.contracts unit]
  }
  where
    types = [(S.dataTypeName d, S.unitName unit ++ "::type::" ++ S.dataTypeName d) | d <- S.dataTypes unit]
    constructors = [(S.dataConstructorName c, qualified ++ "::" ++ S.dataConstructorName c)
      | d <- S.dataTypes unit, Just qualified <- [lookup (S.dataTypeName d) types], c <- S.dataTypeConstructors d]
    qualify table name = maybe name id (lookup name table)
    ty = S.mapType change expr
    change (S.Named name) = S.Named (qualify types name)
    change (S.Applied name a) = S.Applied (qualify types name) a
    change (S.Application name args) = S.Application (qualify types name) args
    change t = t
    pair (name,t) = (name,ty t)
    step (S.Send t) = S.Send (ty t)
    step (S.Receive t) = S.Receive (ty t)
    constraint (S.Capability name t) = S.Capability name (ty t)
    expr e = case e of
      S.Located range value -> S.Located range (expr value)
      S.ConstructLit name fields -> S.ConstructLit (qualify constructors name) (map expr fields)
      S.RecordLit fields -> S.RecordLit [(label,expr value) | (label,value) <- fields]
      S.AllPayloadsExpr value predicates -> S.AllPayloadsExpr (expr value) [(binder,expr body) | (binder,body) <- predicates]
      S.AllElementsExpr value binder predicate -> S.AllElementsExpr (expr value) binder (expr predicate)
      S.MatchExpr value branches -> S.MatchExpr (expr value)
        [S.MatchBranch (qualify constructors tag) names (expr body) | S.MatchBranch tag names body <- branches]
      S.ListLit xs -> S.ListLit (map expr xs)
      S.Apply a b -> S.Apply (expr a) (expr b)
      S.Compose a b -> S.Compose (expr a) (expr b)
      S.Binary op a b -> S.Binary op (expr a) (expr b)
      S.Unary op a -> S.Unary op (expr a)
      S.Annotate a t -> S.Annotate (expr a) (ty t)
      S.TypeBound bound t -> S.TypeBound bound (ty t)
      _ -> e
    harnessPlan plan = plan
      { S.planCover = [(p, label, expr e) | (p, label, e) <- S.planCover plan]
      , S.planClassify = [(expr e, label) | (e, label) <- S.planClassify plan]
      , S.planLabels = map expr (S.planLabels plan)
      , S.planTarget = expr <$> S.planTarget plan
      , S.planWitnesses = [(path, expr e, [(n,expr value) | (n,value) <- names], range) | (path,e,names,range) <- S.planWitnesses plan]
      , S.planDraws = [(i, n, ty t, gen g) | (i, n, t, g) <- S.planDraws plan] }
    gen g = case g of
      S.GenAny t -> S.GenAny (ty <$> t)
      S.GenNamed n -> S.GenNamed n
      S.GenOneOf values -> S.GenOneOf (map expr values)
      S.GenFrequency alternatives -> S.GenFrequency [(w, gen a) | (w, a) <- alternatives]
      S.GenSuchThat inner p n -> S.GenSuchThat (gen inner) (expr p) n
      S.GenBind x t from body -> S.GenBind x (ty t) (gen from) (gen body)
    harnessItem item = case item of
      S.HarnessBenchmark n e range -> S.HarnessBenchmark n (expr e) range
      S.HarnessStrategy st -> S.HarnessStrategy st { S.strategyType = ty (S.strategyType st), S.strategyBody = gen (S.strategyBody st) }
      other -> other
    literal (S.ConstructorLiteral tag fields) = S.ConstructorLiteral (qualify constructors tag) (map literal fields)
    literal (S.ListLiteral xs) = S.ListLiteral (map literal xs)
    literal (S.SetLiteral builder xs) = S.SetLiteral builder (map literal xs)
    literal (S.RecordLiteral fields) = S.RecordLiteral [(label,literal value) | (label,value) <- fields]
    literal other = other
    definition d = case d of
      S.Forall binders body -> S.Forall (map pair binders) (definition body)
      S.Exists binders body -> S.Exists (map pair binders) (definition body)
      S.Not body -> S.Not (definition body)
      S.Equal a b -> S.Equal (expr a) (expr b)
      S.Holds value -> S.Holds (expr value)
      S.Implies guard body -> S.Implies (expr guard) (definition body)
      S.And a b -> S.And (definition a) (definition b)
      S.Invoke name args -> S.Invoke name (map expr args)
    law l = l {S.parameters = map pair (S.parameters l), S.requirements = map constraint (S.requirements l),
      S.lawResources = map pair (S.lawResources l),
      S.definition = definition (S.definition l), S.examples =
        [e {S.bindings = [(name,literal value) | (name,value) <- S.bindings e],
            S.expectations = [S.Expectation (expr (S.actual x)) (literal (S.expected x)) | x <- S.expectations e]}
          | e <- S.examples l]}

-- | A field's refinement may call the unit's checked definitions
-- (`label :: (v :: Text where validName v)`). A data type's predicates are
-- checked wherever a value is built, on every target and in the runtime's
-- schemas, with no definitions in scope, so each call is unfolded into the
-- definition's body: its arguments bound first, in order, by let. Recursive
-- definitions are not unfolded, and stay an error.
inlineFieldDefinitions :: Source.SourceContext -> [C.DataDeclaration] -> Int -> S.Unit -> S.Unit
inlineFieldDefinitions context headers bits unit = structured{S.dataTypes=map declaration (S.dataTypes structured)}
  where
    definitions=M.fromList [(S.functionName definition,definition) | definition<-S.functionDefinitions unit]
    globals=Infer.definitionEnvironment unit
    structured=SourceRecords.mapUnitTypeReferences records unit
    records=S.mapType record (S.mapExprTypes records)
    record original@(S.RecordShape fields)=S.withRecordFields original [field{S.recordFieldType=fieldType (fieldScope (take count fields)) (S.recordFieldType field)}
      | (count,field)<-zip [1..] fields]
    record other=other
    fieldScope fields=[(S.recordFieldBinding field,Just (S.recordFieldType field)) | field<-fields]
    declaration value=value{S.dataTypeConstructors=map constructor (S.dataTypeConstructors value)}
    constructor value=value{S.dataConstructorFields=
      [(name,fieldType [(label,Just value) | (label,value)<-take count fields] ty)
      | (count,(name,ty))<-zip [1..] fields]}
      where fields=S.dataConstructorFields value
    fieldType=fieldTypeAt 0 []
    fieldTypeAt depth active scope ty=case ty of
      S.Refined name inner predicate->S.Refined name (fieldTypeAt depth active scope inner)
        (unfold depth active ((name,Just inner):scope) (Just (S.Named "Bool")) <$> predicate)
      S.CheckedType predicates inner->S.CheckedType
        (map (unfold depth active scope (Just (S.Named "Bool"))) predicates) (fieldTypeAt depth active scope inner)
      S.Qualified constraints inner->S.Qualified
        [S.Capability name (fieldTypeAt depth active scope value) | S.Capability name value<-constraints]
        (fieldTypeAt depth active scope inner)
      original@(S.RecordShape fields)->S.withRecordFields original [field{S.recordFieldType=fieldTypeAt depth active
        (fieldScope (take count fields)) (S.recordFieldType field)} | (count,field)<-zip [1..] fields]
      S.Arrow left right->S.Arrow (fieldTypeAt depth active scope left) (fieldTypeAt depth active scope right)
      S.Applied name inner->S.Applied name (fieldTypeAt depth active scope inner)
      S.Application name values->S.Application name (map (fieldTypeAt depth active scope) values)
      other->other
    -- This is the existing typer, with nominal headers only. It chooses the
    -- call's contextual literals, conversions and generic instantiation. The
    -- completed program independently checks all original calls afterwards.
    environment scope=M.union (Infer.monoEnvironment
      [(name,maybe (S.Named "$unknownFieldLocal") (rigid . S.baseType) value) | (name,value)<-scope]) globals
    initial=Infer.withSourceContext context (Infer.withDataDeclarations headers (Infer.initialState bits))
    typed scope expected expression
      | any (\name -> lookup name scope==Just Nothing) (S.exprVars expression)=Left "unresolved local field type"
      | otherwise=fst <$> Infer.typedExpressionWithSchemesContext context headers bits (environment scope)
          (maybe id (\ty value->S.Annotate value (rigid ty)) expected (S.mapExprTypes rigid expression))
    rigid=S.mapType (\ty->case ty of S.Variable name->S.Named ('@':name); other->other) (S.mapExprTypes rigid)
    unrigid=S.mapType (\ty->case ty of S.Named ('@':name)->S.Variable name; other->other) (S.mapExprTypes unrigid)
    peel tree=case (S.unlocated (S.expression tree),S.operands tree) of
      (S.Annotate _ _,[value])->peel value
      _->tree
    typedSpine tree=case (S.unlocated (S.expression (peel tree)),S.operands (peel tree)) of
      (S.Apply _ _,[function,argument])->let (root,args)=typedSpine function in (root,args++[argument])
      _->(peel tree,[])
    effective tree=maybe (S.expressionType tree) id (S.requiredConversion tree)
    callInfo scope expected expression definition=do
      tree<-typed scope expected expression
      let (function,arguments)=typedSpine tree
          signature=foldr S.Arrow (S.functionResult definition) (map snd (S.functionArguments definition))
      state<-execStateT (Infer.unify (S.baseType signature) (S.expressionType function)) initial
      substitutions<-evalStateT (mapM Infer.resolveRetained (Infer.substitutions state)) state
      let parameters=map (unrigid . effective) arguments
          result=dropArguments (length parameters) (S.expressionType function)
          known=nub (concat [S.typeVariableNames value | (_,Just value)<-scope])
          free=concatMap S.typeVariableNames (unrigid result:parameters)
      unless (all (`elem` known) free) (Left "field call requires concrete argument types")
      pure (parameters,unrigid result,M.map unrigid substitutions)
    dropArguments 0 ty=ty
    dropArguments count (S.Arrow _ rest)=dropArguments (count-1) rest
    dropArguments _ ty=ty
    -- Ask the same pattern typer for each branch's local givens. Resolve only
    -- that branch's environment; facts from sibling branches never escape.
    branchScopes scope expected value branches=case runStateT
      (Infer.matchScopesWithResult (environment scope) (rigid <$> expected)
        (S.mapExprTypes rigid value) [S.MatchBranch tag names (S.mapExprTypes rigid body) | S.MatchBranch tag names body<-branches]) initial of
      Left _->replicate (length branches) Nothing
      Right (scopes,state)->zipWith (branchScope state) branches scopes
      where
        branchScope state (S.MatchBranch _ names _) selected=do
          (locals,givens)<-selected
          let resolve ty=evalStateT (Infer.withGivens givens (Infer.resolveRetained (rigid ty))) state
              names'=nub (names++map fst scope)
          values<-mapM (\name->do
            scheme<-M.lookup name locals
            ty<-either (const Nothing) (Just . unrigid) (resolve (Infer.schemeType scheme))
            pure (name,Just ty)) names'
          let annotations ty=either (const ty) unrigid (resolve ty)
          pure (values,S.mapExprTypes annotations)
    callbackFields scope expected expression=case typed scope expected expression of
      Right tree->[[(name,unrigid ty) | (name,ty)<-fields] | S.TypedCase _ fields _<-S.typedCases (peel tree)]
      Left _->[]
    callbackType fields index name=case drop index fields of
      current:_->lookup name current
      []->Nothing
    containsCalls scope expression=any (\name->M.member name definitions && name `notElem` map fst scope) (S.exprVars expression)
    unfold depth active scope expected expression
      | depth>16=expression
      | not (containsCalls scope expression)=expression
      | otherwise=case expression of
        S.Located range value->S.Located range (unfold depth active scope expected value)
        candidate | (S.Var name,args)<-spine candidate [],Just definition<-M.lookup name definitions
          ,name `notElem` map fst scope,name `notElem` active,length args==length (S.functionArguments definition)->
            case callInfo scope expected expression definition of
              Left _->expression
              Right (types,result,substitutions)->
                let parameters=freshParameters depth definition args
                    values=[(original,S.Var fresh) | (fresh,original)<-parameters]
                    replace=substituteType substitutions M.empty
                    parameterTypes=[fieldTypeAt (depth+1) (name:active) scope
                      (S.replaceTypeValueVars values (S.baseType ty)) | ty<-types]
                    resultType=fieldTypeAt (depth+1) (name:active) scope
                      (S.replaceTypeValueVars values (S.baseType result))
                    body=S.replaceExprVars values (S.mapExprTypes replace (S.functionBody definition))
                    bodyScope=[(fresh,Just ty) | ((fresh,_),ty)<-zip parameters parameterTypes]
                    expanded=unfold (depth+1) (name:active) bodyScope (Just resultType) (S.Annotate body resultType)
                    bindings _ []=expanded
                    bindings current (((fresh,_),ty,argument):rest)=
                      S.MatchExpr (unfold depth active current (Just ty) (S.Annotate argument ty))
                        [S.MatchBranch S.letTag [fresh] (bindings ((fresh,Just ty):current) rest)]
                in bindings scope [(parameter,ty,arg) | (parameter,ty,arg)<-zip3 parameters parameterTypes args]
        S.Apply _ _->
          let (root,args)=spine expression []
              inferred=do
                tree<-either (const Nothing) Just (typed scope expected expression)
                let node=peel tree
                    (_,nested)=typedSpine node
                    children=if length (S.operands node)==length args &&
                      maybe False ((== "prelude.") . take 8) (case root of S.Var name->Just name; _->Nothing)
                      then S.operands node else nested
                if length children==length args then Just (map (unrigid . effective) children) else Nothing
              arguments=case inferred of
                Just types->[unfold depth active scope (Just ty) (S.Annotate arg (S.baseType ty)) | (arg,ty)<-zip args types]
                Nothing->map (unfold depth active scope Nothing) args
          in foldl S.Apply (unfold depth active scope Nothing root) arguments
        S.Compose left right->S.Compose (recur left) (recur right)
        S.ListLit values->S.ListLit (map recur values)
        S.ConstructLit name values->S.ConstructLit name (map recur values)
        S.RecordLit fields->S.RecordLit [(label,recur value) | (label,value)<-fields]
        S.MatchExpr value branches->S.MatchExpr (recur value)
          [let (local,change)=maybe ([(name,Nothing) | name<-names]++scope,id) id selected
           in S.MatchBranch tag names (unfold depth active local expected (change body))
          | (S.MatchBranch tag names body,selected)<-zip branches (branchScopes scope expected value branches)]
        S.AllElementsExpr value name predicate->
          let fields=callbackFields scope expected expression
          in S.AllElementsExpr (recur value) name
            (unfold depth active ((name,callbackType fields 0 name):scope) (Just (S.Named "Bool")) predicate)
        S.AllPayloadsExpr value predicates->
          let fields=callbackFields scope expected expression
          in S.AllPayloadsExpr (recur value)
            [(name,unfold depth active ((name,callbackType fields index name):scope) (Just (S.Named "Bool")) body)
            | (index,(name,body))<-zip [0..] predicates]
        S.Binary operator left right->case either (const Nothing) (Just . S.operands . peel) (typed scope expected expression) of
          Just [a,b]->S.Binary operator
            (unfold depth active scope (Just (unrigid (effective a))) (S.Annotate left (S.baseType (unrigid (effective a)))))
            (unfold depth active scope (Just (unrigid (effective b))) (S.Annotate right (S.baseType (unrigid (effective b)))))
          _->S.Binary operator (recur left) (recur right)
        S.Unary operator value->S.Unary operator (recur value)
        S.Annotate value ty->S.Annotate (unfold depth active scope (Just ty) value) (fieldTypeAt depth active scope ty)
        other->other
      where recur=unfold depth active scope Nothing
    spine expression args=case expression of
      S.Apply function argument->spine function (argument:args)
      S.Located _ inner->spine inner args
      other->(other,args)
    freshParameters depth definition args=snd (foldl choose (used,[]) (S.functionArguments definition))
      where
        used=S.exprVars (S.functionBody definition)++concatMap S.exprVars args
        choose (taken,parameters) (name,_)=
          let base="lawspecInline"++show depth++"_"++name
              fresh=head [base++replicate n '_' | n<-[0..],base++replicate n '_' `notElem` taken]
          in (fresh:taken,parameters++[(fresh,name)])

-- | Check calls before expansion erases their signatures and contracts. These
-- validation-only templates use the ordinary definition checker; they are never
-- emitted or included in the public program. Only earlier stored restrictions
-- are assumptions. The predicate currently being checked is not assumed.
fieldDefinitionChecks :: S.Unit -> S.Unit -> [S.FunctionDefinition]
fieldDefinitionChecks original expanded =
  [S.FunctionDefinition ("$lawspecFieldAdmission" ++ show index) arguments (S.Named "Bool")
    (nub (concatMap (S.typeConstraints . snd) arguments)) predicate range
  | (index,(arguments,predicate,range)) <- zip [0::Int ..] checks]
  where
    definitions=M.fromList [(S.functionName d,d) | d<-S.functionDefinitions original]
    checks=nub (concat
      [fieldChecks (S.dataConstructorSpan constructor)
        (S.dataConstructorFields constructor) (S.dataConstructorFields changedConstructor)
      | (declaration,changed)<-zip (S.dataTypes original) (S.dataTypes expanded)
      , (constructor,changedConstructor)<-zip (S.dataTypeConstructors declaration) (S.dataTypeConstructors changed)]
      ++ concat [nested fallback ty changed | (ty,changed)<-zip
        (SourceRecords.unitTypeReferences original) (SourceRecords.unitTypeReferences expanded)])
    fallback=Span (Location "<field restriction>" 1 1) (Location "<field restriction>" 1 1)
    predicateRange fallback predicate=case predicate of
      S.Located range _->range
      S.Apply function _->predicateRange fallback function
      S.Annotate value _->predicateRange fallback value
      _->fallback
    fieldChecks range fields expandedFields =
      [(take (count-1) expandedFields ++ [(name,S.CheckedType (take prior expandedPredicates) (S.baseType expandedType))],predicate,predicateRange range predicate)
      | (count,((name,ty),(_,expandedType)))<-zip [1..] (zip fields expandedFields)
      , let prefix=map fst (take count fields)
            expandedPredicates=S.typePredicates (S.Var name) expandedType
      , (prior,predicate)<-zip [0..] (S.typePredicates (S.Var name) ty)
      , any (\name -> M.member name definitions && name `notElem` prefix) (S.exprVars predicate)]
      ++ concat [nested range ty changed | ((_,ty),(_,changed))<-zip fields expandedFields]
    nested range ty changed = case (ty,changed) of
      (S.Refined _ inner _,S.Refined _ next _) -> nested range inner next
      (S.CheckedType _ inner,S.CheckedType _ next) -> nested range inner next
      (S.Qualified _ inner,S.Qualified _ next) -> nested range inner next
      (S.Applied _ inner,S.Applied _ next) -> nested range inner next
      (S.Application _ values,S.Application _ next) -> concat (zipWith (nested range) values next)
      (S.Arrow a b,S.Arrow c d) -> nested range a c ++ nested range b d
      (S.RecordShape fields,S.RecordShape next) -> fieldChecks range
        [(S.recordFieldBinding field,S.recordFieldType field) | field<-fields]
        [(S.recordFieldBinding field,S.recordFieldType field) | field<-next]
      _ -> []

-- | Expanding a call must not erase deferred result-contract enforcement,
-- including enforcement in dependencies used by the call's own contracts.
fieldDefinitionDependencies :: S.Unit -> [S.FunctionDefinition] -> [(String,Span)]
fieldDefinitionDependencies unit checks=nub
  [(dependency,range) | check<-checks
    , let range=S.functionSpan check
    , dependency<-reachable [] (filter (\name -> M.member name definitions && name `notElem` map fst (S.functionArguments check)) (S.exprVars (S.functionBody check)))]
  where
    definitions=M.fromList [(S.functionName d,d) | d<-S.functionDefinitions unit]
    reachable seen []=seen
    reachable seen (name:rest)
      | name `elem` seen=reachable seen rest
      | otherwise=case M.lookup name definitions of
          Nothing->reachable seen rest
          Just definition->
            let bound=map fst (S.functionArguments definition)
                names=filter (\candidate -> M.member candidate definitions && candidate `notElem` bound)
                  (S.exprVars (S.functionBody definition) ++ concatMap S.typeValueVars
                    (S.functionResult definition : map snd (S.functionArguments definition)))
            in reachable (seen ++ [name]) (names ++ rest)
