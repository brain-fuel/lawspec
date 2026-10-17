-- | The only bridge from checked surface syntax to the typed core. Targets never
-- receive TypedExpr's source tree or perform contextual literal inference.
module LawSpec.Frontend (compileCore, compileCoreCanonical, elaborate, elaborateCanonical, elaborateWithSourceDeclarations, elaborateWithSourceDeclarationsWithScopes, elaborateWithFormalValues, sourcePropertyId, elaborateExpression) where
import qualified LawSpec.Model as S
import qualified LawSpec.Compile as S
import qualified LawSpec.SourceContext as Source
import LawSpec.Inference (monoEnvironment)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.EqSet as EqSet
import LawSpec.Common
import LawSpec.Data (elaborateDataDeclarationsWithContext)
import LawSpec.Elaboration (elaborateExpression, binaryOp, abilityReferenceWithSourceRecords, unitOperationsWithSourceRecords, performOperations, collectSourceRecords, collectType, collectExpression, collectEquation, collectAbilityReference)
import LawSpec.Core.Validate (validateProgramWithScopes)
import LawSpec.Core.CapabilityScope (CapabilityScopes,noCapabilities)
import LawSpec.Elaboration (elaborateDefinitionUnitWithScopes,elaborateContractWithScopes,withCapabilities)
import LawSpec.Core.Definitions (prepareDefinitions,prepareDefinitionsWithScopes)
import LawSpec.Core.Types (makeRegistry)
import qualified LawSpec.Core.Eval as CoreEval
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Release (checkResourceReleases)
import LawSpec.Core.Total (deferProgramPostconditionsWithScopes)
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import Control.Monad (forM, unless)
import Control.Monad.Trans.Class (lift)
import qualified Data.Set as Set
import qualified Data.Map.Strict as M
import Data.List (nub, nubBy, stripPrefix, intercalate)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import LawSpec.Persist ()
import LawSpec.Resources (builtinResourceKind)
import LawSpec.Scalar (Scalar(..))

-- | Hosts that hold only sources get typed Core in one call; everything after
-- this point works on Core alone. ref:DEC-typed-core-boundary
compileCore :: Int -> Generation -> [Source] -> Either [Diagnostic] C.Program
compileCore bits settings sources = do
  (units,properties) <- S.compileWithSettings bits settings sources
  -- Callers that read a whole program (tools, tests, emitters) see field
  -- nodes as the matches they stand for, as the testing plan does.
  C.lowerProgramFields <$> elaborate bits units properties

compileCoreCanonical :: Int -> Generation -> [Source] -> Either [Diagnostic] C.Program
compileCoreCanonical bits settings sources = do
  (units,properties) <- S.compileCanonicalWithImports (\_ _ -> Nothing) bits settings sources
  C.lowerProgramFields <$> elaborateCanonical bits units properties

-- Source names differ across profiles; nominal identities and checked bodies
-- remain stable. All consumers receive the same canonical typed metadata.
elaborateCanonical :: Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborateCanonical bits units properties = canonicalNames <$> elaborate bits units properties

canonicalNames :: C.Program -> C.Program
canonicalNames program = program{C.programDataDeclarations=map name (C.programDataDeclarations program)}
  where
    name declaration
      | C.dataId declaration == EqSet.eqSetTypeId = declaration{C.dataName="Set"}
      | C.dataId declaration == C.Id "lawspec.collections::type::Set" = declaration{C.dataName="SortedSet"}
      | otherwise = declaration

-- A surface constant may use a checked collection builder. Evaluate it through
-- the ordinary definition invoker, then retain concrete Core input values.
-- Final validation still checks every materialized example and its domain.
materializeExampleBindingsWithScopes :: CapabilityScopes -> C.Program -> Either [Diagnostic] C.Program
materializeExampleBindingsWithScopes scopes program
  | not (any hasCalls [value | unit <- C.programUnits program, property <- C.unitProperties unit,
      example <- C.propertyExamples property, (_,value) <- C.exampleBindings example]) = Right program
  | otherwise = do
      let definitions = program{C.programUnits = [unit{C.unitProperties =
            if M.null scopes then [property{C.propertyExamples=[]} | property <- C.unitProperties unit] else []} | unit <- C.programUnits program]}
          owners=Set.fromList [C.declarationId declaration | unit<-C.programUnits definitions,declaration<-C.unitDeclarations unit]
      invoke <- if M.null scopes then prepareDefinitions definitions else
        prepareDefinitionsWithScopes (M.restrictKeys scopes owners) definitions
      registry <- either (\message -> Left [Diagnostic "core" message Nothing]) Right
        (makeRegistry (C.programDataDeclarations program))
      units <- forM (C.programUnits program) $ \unit -> do
        properties <- forM (C.unitProperties unit) $ \property -> do
          examples <- forM (C.propertyExamples property) $ \example -> do
            bindings <- forM (C.exampleBindings example) $ \(identity,expression) ->
              if not (hasCalls expression) then pure (identity,expression) else do
                let checked = either (\message -> Left [Diagnostic "example-constant"
                      (C.propertyName property ++ ": " ++ C.exampleName example ++ ": " ++ message)
                      (Just (C.propertyLocation property))]) Right
                value <- checked (CoreEval.evaluateValue registry (C.programMachineBits program) invoke [] expression)
                constant <- checked (valueTerm (C.expressionOrigin expression) value)
                pure (identity,constant)
            pure example{C.exampleBindings=bindings}
          pure property{C.propertyExamples=examples}
        pure unit{C.unitProperties=properties}
      pure program{C.programUnits=units}
  where
    hasCalls expression = case C.expressionNode expression of
      C.ExternalCall _ _ -> True
      _ -> any hasCalls (C.children expression)
    valueTerm origin value = case value of
      CoreValue.ScalarValue scalar -> Right (C.Expr (CoreValue.valueType value) (C.Constant scalar) origin)
      CoreValue.DataValue ty tag values -> (\fields -> C.Expr ty (C.Construct tag fields) origin) <$> mapM (valueTerm origin) values
      CoreValue.PresenceValue ty _ -> (\scalar -> C.Expr ty (C.Constant scalar) origin) <$> CoreValue.toScalarValue value

-- | Every surface construct is lowered here, once, and the result validated
-- before any backend sees it. ref:DEC-elaborate-before-core
elaborate :: Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborate bits units properties = do
  (dataDeclarations,sourceTypes) <- elaborateDataDeclarationsWithContext bits units
  elaborateWithSourceDeclarations False sourceTypes dataDeclarations bits units properties

-- | Migration captures retain complete unused constructor fields. Analyze
-- their input domains through the ordinary lowering and mandatory validator,
-- without rebuilding a sparse declaration context from the executable roots.
elaborateWithSourceDeclarations :: Bool -> Source.SourceContext -> [C.DataDeclaration]
  -> Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborateWithSourceDeclarations=elaborateWithSourceDeclarationsWithScopes M.empty

elaborateWithSourceDeclarationsWithScopes :: CapabilityScopes -> Bool -> Source.SourceContext -> [C.DataDeclaration]
  -> Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborateWithSourceDeclarationsWithScopes=elaborateWithFormalValues M.empty

-- Compiler-owned law-template binders precede sampled inputs in the checked
-- surface copy. Split them while constructing Core, before ordinary admission;
-- no abstract adapter or concrete parameter implementation is introduced.
elaborateWithFormalValues :: M.Map C.Id Int -> CapabilityScopes -> Bool -> Source.SourceContext -> [C.DataDeclaration]
  -> Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborateWithFormalValues formalCounts scopes canonical sourceTypes dataDeclarations bits units properties = do
  contextual Nothing $ unless (M.keysSet formalCounts `Set.isSubsetOf`
    Set.fromList [sourcePropertyId (S.owner law) (S.name law) | law<-properties])
    (Left "formal values name an unknown law template")
  contextual Nothing $ mapM_ (\law -> let count=formalCount law in
    unless (count>=0 && count<=length (S.inputs law)) (Left "invalid law-template formal value count")) properties
  collected <- mapM (unit sourceTypes dataDeclarations) units
  let elaborated = C.Program bits (appendRecords dataDeclarations (concatMap snd collected)) (map fst collected)
  normalized <- normalizeProgramRecords elaborated
  -- Postconditions over non-linear index arithmetic become runtime checks.
  admitted <- deferProgramPostconditionsWithScopes scopes normalized
  core <- materializeExampleBindingsWithScopes scopes admitted
  validateProgramWithScopes scopes core
  checkResourceReleases core
  -- Audit every occurrence before interning: a duplicate descriptor must not
  -- hide an ill-defined source ordering of constructor restrictions.
  interned <- contextual Nothing (internRecordDeclarations (C.programDataDeclarations core))
  pure ((if canonical then canonicalNames else id) core{C.programDataDeclarations=interned})
  where
    formalCount law=M.findWithDefault 0 (sourcePropertyId (S.owner law) (S.name law)) formalCounts
    appendRecords known [] = known
    appendRecords known records = known ++ records
    unit sourceTypes nominalDeclarations u = do
      (closed, owned, ps0, cs, dataDeclarations, occurrences) <- contextual Nothing $ do
        (closed,definitionRecords) <- elaborateDefinitionUnitWithScopes scopes sourceTypes nominalDeclarations bits u
        let knownDefinitions = appendRecords nominalDeclarations definitionRecords
        contracts <- mapM (elaborateContractWithScopes scopes sourceTypes knownDefinitions bits u) (S.contracts u)
        let contractRecords = concatMap snd contracts
            dataDeclarations = appendRecords knownDefinitions contractRecords
            cs = map fst contracts
        -- A law's Core depends on it, its unit's signatures and the data types.
        let dataDigest = digestHex (digestString (show (dataDeclarations,sourceTypes)))
            elaborated p = memoized elaborationTable
              (digestHex (digestString (show (bits, dataDigest, S.unitName u, S.functions u, S.resourceDeclarations u,
                M.findWithDefault noCapabilities (sourcePropertyId (S.unitName u) (S.name p)) scopes, formalCount p, p))))
              (property sourceTypes dataDeclarations u p)
            owned = filter ((== S.unitName u) . S.owner) properties
        ps0 <- mapM elaborated owned
        let propertyRecords = concatMap snd ps0
        pure (closed, owned, map fst ps0, cs, appendRecords dataDeclarations propertyRecords,
          definitionRecords ++ contractRecords ++ propertyRecords)
      -- The harness plane: how each law is tested (LawSpec.Harness).
      harnesses <- mapM (\(sp, cp) -> harnessed sourceTypes dataDeclarations closed u sp cp) (zip owned ps0)
      let harnessRecords = concatMap snd harnesses
          knownHarnesses = appendRecords dataDeclarations harnessRecords
          ps = map fst harnesses
      (settings,benchmarkRecords) <- unitHarnessSettings sourceTypes knownHarnesses closed u
      let knownSettings = appendRecords knownHarnesses benchmarkRecords
      contextual Nothing $ do
        -- Calls to ability operations are Perform; each law gets the handlers
        -- the abilities pass chose for it.
        ((_, operations), operationRecords) <- unitOperationsWithSourceRecords sourceTypes knownSettings bits u
        handled <- forM ps $ \p -> do
          assignments <- forM (maybe [] id (lookup (C.propertyName p) (S.lawAssignments u))) $ \(ability, choice) -> do
            (reference,records) <- abilityReferenceWithSourceRecords sourceTypes (appendRecords knownSettings operationRecords) bits u ability
            pure ((reference,handlerRef u choice),records)
          let assignment = map fst assignments
          -- A resource's operations (a built-in resource's lawspec.host
          -- ones) run under the production handler of their ability.
          let handledProperty = mapProperty (performOperations operations) p
              resourceAbilities = nub [C.operationAbility op | r <- C.propertyResources handledProperty
                , e <- [C.resourceAcquire r, C.resourceRelease r] ++ maybe [] pure (C.resourceReset r), op <- performedIn e]
              withResources = assignment ++ [(a, C.ProductionHandler) | a <- resourceAbilities, a `notElem` map fst assignment]
          pure ((shared settings handledProperty) { C.propertyHandlers = withResources },concatMap snd assignments)
        -- A benchmark's operations are Perform, like a law's.
        let settings' = fmap (\h -> h { C.harnessBenchmarks = [(n, performOperations operations b) | (n, b) <- C.harnessBenchmarks h] }) settings
        pure (closed{C.unitContracts=cs,C.unitProperties=map fst handled,C.unitHarnessSettings=settings'},
          occurrences ++ harnessRecords ++ benchmarkRecords ++ operationRecords ++ concatMap snd handled)
    -- share R per group | unit | run: the key of the scope whose cases share
    -- one R (the harness has checked that R declares reset).
    shared settings p = p { C.propertyResources =
      [ r { C.resourceShared = case lookup (resourceName r) (maybe [] C.harnessShares settings) of
              Just "run" -> Just ("run/" ++ resourceName r)
              Just "unit" -> Just (unitOf p ++ "/" ++ resourceName r)
              Just _ -> Just (unitOf p ++ "/" ++ maybe ("law " ++ C.propertyName p) ("group " ++) (C.harnessGroup (C.propertyHarness p)) ++ "/" ++ resourceName r)
              Nothing -> Nothing }
      | r <- C.propertyResources p ] }
    resourceName r = case C.binderType (C.resourceBinder r) of
      C.Constructor n _ -> baseName n
      _ -> ""
    unitOf p = takeWhile (/= ':') (C.idText (C.propertyId p))
    performedIn e = case C.expressionNode e of
      C.Perform op args -> op : concatMap performedIn args
      _ -> concatMap performedIn (C.children e)
    declarationId u n = C.Id (S.unitName u ++ "::" ++ n)
    property sourceTypes dataDeclarations u p = collectSourceRecords sourceTypes dataDeclarations $
      withCapabilities (M.findWithDefault noCapabilities (sourcePropertyId (S.unitName u) (S.name p)) scopes) $ do
      let pid = sourcePropertyId (S.unitName u) (S.name p)
          original = S.original p
          resourceIds = [(n,C.Id (C.idText pid ++ "::resource::" ++ show index)) | (index,(n,_)) <- zip [0::Int ..] (S.lawResources original)]
          nestedInputs = S.assertionInputs (S.assertion p)
          bindings = [(S.inputId i,C.Id (C.idText pid ++ "::input::" ++ show index)) | (index,i) <- zip [0::Int ..] (S.inputs p)] ++
            [(S.inputId i,C.Id (C.idText pid ++ "::logical::" ++ show index)) | (index,i) <- zip [0::Int ..] nestedInputs] ++ resourceIds
          env = S.functions u ++ [(S.inputId i,S.inputType i) | i <- S.inputs p ++ nestedInputs] ++ S.lawResources original
          resolve n = maybe (declarationId u n) id (lookup n bindings)
          declared = (`Set.member` Set.fromList [declarationId u n | (n,_) <- S.functions u])
          term = collectExpression False declared bits pid resolve (monoEnvironment env)
          equal a b = collectEquation [declarationId u n | (n,_) <- S.functions u] bits pid resolve env a b
          assertion (S.AssertEqual a b) = equal a b
          assertion (S.AssertImplies g body) = C.Implication <$> term g <*> assertion body
          assertion (S.AssertAll bodies) = C.Conjunction <$> mapM assertion bodies
          assertion (S.AssertNot body) = C.Negation <$> assertion body
          assertion (S.AssertQuantified kind i body) = do
            ty <- collectType bits (S.inputType i)
            predicates <- mapM term (S.inputRefinements i)
            let quantifier = C.Quantifier (C.Binder (resolve (S.inputId i)) (S.inputName i) ty) predicates []
            C.Quantified kind quantifier <$> assertion body
      qs <- forM (S.inputs p) $ \i -> do
        t <- collectType bits (S.inputType i)
        preds <- mapM term (S.inputRefinements i)
        let bounds = concat [S.domainBounds plan | plan <- S.generationPlan p, S.inputId (S.domainInput plan) == S.inputId i]
        boundTerms <- mapM (\(op,e) -> (,) <$> lift (binaryOp op) <*> term e) bounds
        pure (C.Quantifier (C.Binder (resolve (S.inputId i)) (S.inputName i) t) preds boundTerms)
      body <- assertion (S.assertion p)
      examples <- forM (S.examples original) $ \e -> do
        let aliases = [(S.inputName i,S.Var (S.inputId i)) | i <- drop (formalCount p) (S.inputs p)]
            replace = S.replaceExprVars aliases
        values <- forM (drop (formalCount p) (S.inputs p)) $ \i -> do
          lit <- lift (maybe (Left ("missing example binding: " ++ S.inputName i)) Right (lookup (S.inputName i) (S.bindings e)))
          value <- term (S.Annotate (S.literalExpr lit) (S.inputType i))
          pure (resolve (S.inputId i),value)
        expects <- forM (S.expectations e) $ \x -> equal (replace (S.actual x)) (S.literalExpr (S.expected x))
        pure (C.Example (S.exampleName e) values expects)
      resources <- forM (zip resourceIds (S.lawResources original)) $ \((n, rid), (_, ty)) -> do
        t <- collectType bits ty
        let binder = C.Binder rid n t
            self = C.Expr t (C.Local rid) (C.GeneratedFrom rid)
            text value = C.Expr (C.scalarType "Text") (C.Constant (SSequence "Text" (map fromEnum value))) (C.GeneratedFrom rid)
            helper result builtin args = C.Expr result (C.Helper builtin args) (C.GeneratedFrom rid)
        case t of
          -- A built-in resource acquires and releases through lawspec.host's
          -- abilities, under their handlers (the default ones, or those
          -- lawspec.json binds).
          C.Constructor typeName [] | Just kind <- builtinResourceKind typeName -> do
            let constructor = C.Id (typeName ++ "::" ++ baseName typeName)
                fieldType = if kind == "freePort" then C.scalarType "Int32" else C.scalarType "Text"
                field = C.Binder (C.Id (C.idText rid ++ "::match::field")) "value" fieldType
                host ability = C.AbilityRef (C.Id ("lawspec.host::ability::" ++ ability)) []
                perform result ability op args = C.Expr result (C.Perform (C.Operation (host ability) op) args) (C.GeneratedFrom rid)
                unit' = C.scalarType "Unit"
                fieldValue = C.Expr fieldType (C.Local (C.binderId field)) (C.GeneratedFrom rid)
                releasing body = C.Expr unit' (C.Match self [C.MatchCase constructor [field] body]) (C.GeneratedFrom rid)
                (acquired, release) = case kind of
                  "temporaryDirectory" -> (perform fieldType "FileSystem" "temporaryDirectory" [text "lawspec-"],
                    releasing (perform unit' "FileSystem" "removePath" [fieldValue]))
                  "temporaryFile" -> (perform fieldType "FileSystem" "temporaryFile" [text "lawspec-"],
                    releasing (perform unit' "FileSystem" "removePath" [fieldValue]))
                  "environment" -> (perform fieldType "Environment" "environmentSnapshot" [],
                    releasing (perform unit' "Environment" "restoreEnvironment" [fieldValue]))
                  _ -> (perform fieldType "Ports" "freePort" [], C.Expr (C.scalarType "Bool") (C.Constant (SBool True)) (C.GeneratedFrom rid))
            pure (C.Resource binder (C.Expr t (C.Construct constructor [acquired]) (C.GeneratedFrom rid)) release Nothing Nothing False)
          _ -> case [r | r <- S.resourceDeclarations u, S.resourceType r == ty] of
            [declaration] -> do
              acquire <- term (S.Annotate (S.resourceAcquire declaration) ty)
              let (parameter, releaseBody) = S.resourceRelease declaration
                  resolveRelease name = if name == parameter then rid else resolve name
              release <- collectExpression False declared bits pid resolveRelease
                (monoEnvironment ((parameter, ty) : S.functions u)) releaseBody
              reset <- forM (S.resourceReset declaration) $ \(resetParameter, resetBody) ->
                collectExpression False declared bits pid
                  (\name -> if name == resetParameter then rid else resolve name) (monoEnvironment ((resetParameter, ty) : S.functions u)) resetBody
              -- A law that releases its own resource is rejected over the
              -- whole program (LawSpec.Release), once definitions are known.
              pure (C.Resource binder acquire release reset Nothing (S.resourceConcurrent declaration))
            [] -> lift (Left (S.name p ++ " takes " ++ n ++ " :: " ++ S.prettyType ty ++ ", but no resource is declared for " ++ S.prettyType ty ++ "; declare resource " ++ S.prettyType ty ++ " is acquire ... release ... end"))
            _ -> lift (Left ("more than one resource is declared for " ++ S.prettyType ty))
      references <- lift (mapM (traverseReference (\target -> case target of
        S.ResolvedReferenceTarget resolved -> pure resolved
        S.ParsedReferenceTarget _ _ -> Left "unresolved documentary reference")) (S.references original))
      pure C.MkProperty
        { C.propertyId=pid, C.propertyName=S.name p, C.propertyLocation=S.location original
        , C.propertyInputs=drop (formalCount p) qs, C.propertyBody=body, C.propertyExamples=examples
        , C.propertyGeneration=S.generation p, C.propertyDescription=S.description original
        , C.propertyRationale=S.rationale original, C.propertyReferences=references
        , C.propertyTrace=S.trace p, C.propertyHandlers=[], C.propertyResources=resources, C.propertyHarness=C.noHarness
        , C.propertyInputDomain=S.inputDomain p, C.propertyMetadata=S.lawMetadata original, C.propertyParameters=take (formalCount p) qs }
    contextual at = either (Left . pure . (\msg -> Diagnostic "elaboration" msg at)) Right
    -- Lexical locals are ordered innermost first, as the resolver's lookup is.
    -- They shadow declarations, even when their spelling names a function.
    lexicalEnvironment u locals = M.union (monoEnvironment (reverse locals)) (monoEnvironment (S.functions u))
    -- A law's harness plan, elaborated over its inputs. Its expressions may
    -- call checked definitions only: calling native code or an ability
    -- operation could change what the law observes.
    harnessed sourceTypes dataDeclarations closed u sp cp = case lookup (S.name sp) (S.lawHarness u) of
      Nothing -> pure (cp { C.propertyHarness = C.noHarness { C.harnessUnit = S.harnessName <$> S.unitHarness u } },[])
      Just plan -> do
        witnesses <- forM (S.planResolvedWitnesses plan) $ \witness ->
          either (\message -> Left [Diagnostic "harness" message (Just (spanStart (S.witnessSourceSpan witness)))]) Right
            (collectSourceRecords sourceTypes dataDeclarations (elaborateWitness closed u sp cp witness))
        let witnessRecords = concatMap snd witnesses
            knownWitnesses = appendRecords dataDeclarations witnessRecords
        draws <- forM (S.planDraws plan) $ \selected@(inputName,_,_,_) ->
          either (\message -> Left [Diagnostic "harness" message (Just
            (maybe (S.location (S.original sp)) spanStart (lookup inputName (S.planDrawLocations plan))))]) Right
            (collectSourceRecords sourceTypes knownWitnesses (elaborateHarnessStrategy closed u sp cp selected))
        let drawRecords = concatMap snd draws
            knownDraws = appendRecords knownWitnesses drawRecords
        (property,records) <- either (\msg -> Left [Diagnostic "harness" msg (Just (S.location (S.original sp)))]) Right $ collectSourceRecords sourceTypes knownDraws $ do
          let pid = C.propertyId cp
              functionIds = [declarationId u n | (n,_) <- S.functions u]
              inputIds = [(S.inputId i, C.binderId (C.quantifiedBinder q)) | (i, q) <- zip (S.inputs sp) (C.propertyInputs cp)] ++
                [(S.inputId i, C.Id (C.idText pid ++ "::logical::" ++ show index))
                | (index,i) <- zip [0::Int ..] (S.assertionInputs (S.assertion sp))]
              aliases = [(S.inputName i, S.Var (S.inputId i)) | i <- S.inputs sp]
              lawEnv = lexicalEnvironment u [(S.inputId i, S.inputType i) | i <- S.inputs sp]
              resolveWith locals n = maybe (maybe (declarationId u n) id (lookup n inputIds)) id (lookup n locals)
              pureOnly what e = lift (checkHarnessExpression closed u (S.harnessName <$> S.unitHarness u) what e)
              lawTerm what ty e = do
                t <- collectExpression False (`Set.member` Set.fromList functionIds) bits pid (resolveWith []) lawEnv
                  (maybe id (flip S.Annotate) ty (S.replaceExprVars aliases e))
                pureOnly what t
          covers <- mapM (\(percent, label, e) -> C.Cover percent label <$> lawTerm ("cover \"" ++ label ++ "\"") (Just (S.Named "Bool")) e) (S.planCover plan)
          classes <- mapM (\(e, label) -> (\t -> (t, label)) <$> lawTerm ("classify as \"" ++ label ++ "\"") (Just (S.Named "Bool")) e) (S.planClassify plan)
          labels <- mapM (lawTerm "label" (Just (S.Named "Text"))) (S.planLabels plan)
          target <- traverse (\e -> do
            t <- lawTerm "target maximize" Nothing e
            case C.expressionType t of
              C.Constructor n [] | n `elem` numericTypes -> pure t
              other -> lift (Left ("target maximize needs a number to maximize, but " ++ S.prettyExpr e ++ " is " ++ show other))) (S.planTarget plan)
          let targets = [identity | ((identity,_,_,_,_),_) <- draws]
          unless (length targets == length (nub targets))
            (lift (Left "two strategies select the same expanded input or search binder"))
          pure cp { C.propertyHarness = C.LawHarness
            { C.harnessUnit = Just (S.planHarness plan), C.harnessTags = S.planTags plan
            , C.harnessSkip = S.planSkip plan, C.harnessKnownFailing = S.planKnownFailing plan
            , C.harnessTimeout = S.planTimeout plan, C.harnessRepeat = S.planRepeat plan
            , C.harnessRetries = S.planRetries plan, C.harnessCover = covers, C.harnessClassify = classes
            , C.harnessLabels = labels, C.harnessTarget = target
            , C.harnessDraws = [(identity,strategy,draw) | ((identity,_,True,strategy,draw),_) <- draws]
            , C.harnessGroup = S.planGroup plan, C.harnessWitnesses = map fst witnesses
            , C.harnessSearches = [(identity,path,strategy,draw) | ((identity,path,False,strategy,draw),_) <- draws] } }
        pure (property,witnessRecords ++ drawRecords ++ records)
    elaborateHarnessStrategy closed u sp cp (inputName,strategy,declared,gen) = do
      let pid = C.propertyId cp
          inputIds = [(S.inputId i,C.binderId (C.quantifiedBinder q)) | (i,q) <- zip (S.inputs sp) (C.propertyInputs cp)] ++
            [(S.inputId i,C.Id (C.idText pid ++ "::logical::" ++ show index)) |
              (index,i) <- zip [0::Int ..] (S.assertionInputs (S.assertion sp))]
      let roots = [([S.inputName i],i,True) | i <- S.inputs sp]
          targets = roots ++ scopedTargets (map S.inputName (S.inputs sp)) (S.assertion sp)
          written = case stripPrefix "definition." inputName of Just path -> path; Nothing -> inputName
          exact = [target | target@(path,_,_) <- targets,intercalate "." path == written]
          root = [target | target@(_,i,True) <- roots,S.inputName i == written]
          short = [target | target@(_,i,_) <- targets,S.inputName i == written]
          matches = if not (null root) then root else if not (null exact) then exact else short
          paths = intercalate ", " ["definition." ++ intercalate "." path | (path,_,_) <- targets]
      (path,i,isRoot) <- lift $ case matches of
        [target] -> pure target
        [] -> Left ("use " ++ strategy ++ " for " ++ inputName ++ ": the law has no input called " ++ inputName ++
          "; available input and search paths are " ++ paths)
        _ -> Left ("ambiguous strategy target " ++ inputName ++ "; use its qualified lexical path: " ++ paths)
      identity <- lift (maybe (Left "a strategy target has no expanded binder identity") Right (lookup (S.inputId i) inputIds))
      let inputType = maybe (C.TypeVariable identity) id (lookup identity
            [(C.binderId (C.quantifiedBinder q),C.binderType (C.quantifiedBinder q)) |
              q <- C.propertyInputs cp ++ scopedQuantifiers (C.propertyBody cp)])
      -- A strategy of a refined type, (n :: T where p), keeps only the
      -- values that satisfy p, as `such that` does.
      let (plain, refined) = case declared of
            S.Refined n t (Just p) -> (t, Just (S.replaceExprVars [(n, S.Var "it")] p))
            _ -> (declared, Nothing)
          gen' = maybe gen (\p -> S.GenSuchThat gen p 100) refined
      declaredType <- collectType bits plain
      unless (declaredType == inputType)
        (lift (Left ("the strategy " ++ strategy ++ " produces values of " ++ S.prettyType declared ++ ", but the input " ++
          inputName ++ " is " ++ S.prettyType (S.inputType i) ++ "; a strategy may only produce values of its type")))
      draw <- elaborateDraw closed u pid strategy (S.inputId i) plain refined gen'
      pure (identity,path,isRoot,strategy,draw)
    scopedTargets path claim = case claim of
      S.AssertQuantified _ input body -> let full = path ++ [S.inputName input]
        in (full,input,False) : scopedTargets full body
      S.AssertNot body -> scopedTargets path body
      S.AssertImplies _ body -> scopedTargets path body
      S.AssertAll bodies -> concat [scopedTargets (path ++ ["branch" ++ show k]) body | (k,body) <- zip [1::Int ..] bodies]
      S.AssertEqual _ _ -> []
    scopedQuantifiers claim = case claim of
      C.Quantified _ q body -> q : scopedQuantifiers body
      C.Negation body -> scopedQuantifiers body
      C.Implication _ body -> scopedQuantifiers body
      C.Conjunction bodies -> concatMap scopedQuantifiers bodies
      _ -> []
    elaborateWitness closed u sp cp witness = do
      let pid = C.propertyId cp
          functionIds = [declarationId u n | (n,_) <- S.functions u]
          ids = [(S.inputId i,C.binderId (C.quantifiedBinder q)) | (i,q) <- zip (S.inputs sp) (C.propertyInputs cp)] ++
            [(S.inputId i,C.Id (C.idText pid ++ "::logical::" ++ show index)) |
              (index,i) <- zip [0::Int ..] (S.assertionInputs (S.assertion sp))]
          resolve n = maybe (declarationId u n) id (lookup n ids)
          scope = [(S.inputId i,S.inputType i) | i <- reverse (S.witnessScope witness)]
          input = S.witnessInput witness
          what = "witness for definition." ++ intercalate "." (S.witnessPath witness)
      value <- collectExpression False (`Set.member` Set.fromList functionIds) bits pid resolve (lexicalEnvironment u scope)
        (S.Annotate (S.witnessExpression witness) (S.inputType input))
      checked <- lift (checkHarnessExpression closed u (S.harnessName <$> S.unitHarness u) what value)
      pure (C.WitnessChoice (resolve (S.inputId input)) (S.witnessPath witness) checked)
    -- A strategy's draw. Its values are typed by the strategy's type; a
    -- bound value, or `it` in such that, is a local of the test.
    -- A refined strategy's any (the strategy's own value, of its declared
    -- type) aims at the refinement, as a law input's generator does: its
    -- quantifier carries the refinement, whose bounds direct generation.
    -- The such that around it still checks every drawn value.
    elaborateDraw closed u pid strategy input declared refinement gen = do
      aim <- refinedAim (-1) declared refinement
      go declared aim (0 :: Int) [] declared gen
      where
        functionIds = [declarationId u n | (n,_) <- S.functions u]
        strategies = [(S.strategyName s, s) | Just h <- [S.unitHarness u], S.HarnessStrategy s <- S.harnessItems h]
        local :: Int -> String -> C.Id
        local k n = C.Id (C.idText pid ++ "::input::" ++ input ++ "_" ++ n ++ show k)
        refinedAim k ty refined = forM refined $ \p -> do
          core <- collectType bits ty
          let binder = C.Binder (local k "it_aim") "it" core
          predicate <- term [("it", (C.binderId binder, ty))] (S.Named "Bool") p
          pure (C.Quantifier binder [predicate] [])
        term locals ty e = do
          t <- collectExpression False (`Set.member` Set.fromList functionIds) bits pid
            (\n -> maybe (declarationId u n) fst (lookup n locals))
            (lexicalEnvironment u [(n, t') | (n, (_, t')) <- locals]) (S.Annotate e ty)
          lift (checkHarnessExpression closed u (S.harnessName <$> S.unitHarness u) ("the strategy " ++ strategy) t)
        go own aim k locals ty g = case g of
          S.GenAny Nothing -> anyOf own aim ty
          S.GenAny (Just other) -> do
            actual <- collectType bits other
            expected <- collectType bits ty
            unless (actual == expected)
              (lift (Left ("the strategy " ++ strategy ++ " draws any " ++ S.prettyType other ++ " where it needs " ++ S.prettyType ty)))
            anyOf own aim ty
          -- A reference keeps its declared type and refinement. Inlining the
          -- surface body earlier lost both, and could capture a caller's bind.
          -- Harness has already checked that this reference graph is acyclic.
          S.GenNamed n -> case lookup n strategies of
            Nothing -> lift (Left ("the strategy " ++ n ++ " is not known here"))
            Just named -> do
              let (plain, refined) = case S.strategyType named of
                    S.Refined x t (Just p) -> (t, Just (S.replaceExprVars [(x, S.Var "it")] p))
                    t -> (t, Nothing)
                  body = maybe (S.strategyBody named) (\p -> S.GenSuchThat (S.strategyBody named) p 100) refined
              actual <- collectType bits plain
              expected <- collectType bits ty
              unless (actual == expected) (lift (Left ("the strategy " ++ n ++ " produces values of " ++
                S.prettyType (S.strategyType named) ++ ", but this draw expects " ++ S.prettyType ty ++
                "; a strategy may only produce values of its type")))
              namedAim <- refinedAim k plain refined
              go plain namedAim (k + 1) [] plain body
          S.GenOneOf values -> C.DrawOneOf <$> collectType bits ty <*> mapM (term locals ty) values
          S.GenFrequency alternatives -> C.DrawFrequency <$> mapM (\(w, a) -> (,) w <$> go own aim k locals ty a) alternatives
          S.GenSuchThat inner p limit -> do
            inner' <- go own aim (k + 1) locals ty inner
            core <- collectType bits ty
            let binder = C.Binder (local k "it") "it" core
            predicate <- term (("it", (C.binderId binder, ty)) : locals) (S.Named "Bool") p
            pure (C.DrawSuchThat inner' binder predicate limit)
          S.GenBind x xty from body -> do
            core <- collectType bits xty
            let binder = C.Binder (local k x) x core
            from' <- go own Nothing (k + 1) locals xty from
            body' <- go own aim (k + 1) ((x, (C.binderId binder, xty)) : locals) ty body
            pure (C.DrawBind binder from' body')
        -- Only a draw of the strategy's own type aims at its refinement.
        anyOf own aim ty = C.DrawAny <$> collectType bits ty <*> pure (if ty == own then aim else Nothing)
    -- Benchmarks, sharing and order: the harness settings beyond laws.
    unitHarnessSettings sourceTypes dataDeclarations _ u = case S.unitHarness u of
      Nothing -> pure (Nothing,[])
      Just h -> do
        let functionIds = [declarationId u n | (n,_) <- S.functions u]
            withAbilities = [n | (n, row) <- S.abilityRows u, not (null row)]
        benchmarks <- forM [(n, e, range) | S.HarnessBenchmark n e range <- S.harnessItems h] $ \(n, e, range) -> do
          let at = Just (spanStart range)
              failing msg = Left [Diagnostic "harness" ("benchmark `" ++ n ++ "`: " ++ msg) at]
          either failing Right $ collectSourceRecords sourceTypes dataDeclarations $ do
            t <- collectExpression False (`Set.member` Set.fromList functionIds) bits (C.Id (S.unitName u ++ "::benchmark::" ++ n))
              (declarationId u) (monoEnvironment (S.functions u)) e
            -- A benchmark that calls what uses abilities runs under their
            -- production handlers (the native ones, or the defaults), each
            -- installed around it; a failure it raises fails the benchmark.
            refs <- mapM (collectAbilityReference bits u)
              (nubBy (\a b -> S.prettyType a == S.prettyType b)
                [ty | x <- S.exprVars e, x `elem` withAbilities, Just row <- [lookup x (S.abilityRows u)], ty <- row])
            let installed = foldr (\ref body -> body { C.expressionNode = C.Handle (C.WithHandler ref C.ProductionHandler) body })
                  t [ref | ref <- nub refs, not (C.isFail ref)]
            pure (n, installed)
        pure (Just (C.UnitHarness (S.harnessName h)
          (not (null [() | S.HarnessOrderRandom _ <- S.harnessItems h]))
          (not (null [() | S.HarnessParallel _ <- S.harnessItems h]))
          [(r, case scope of S.SharePerGroup -> "group"; S.SharePerUnit -> "unit"; S.SharePerRun -> "run") | S.HarnessShare r scope _ <- S.harnessItems h]
          (map fst benchmarks)),concatMap snd benchmarks)
    numericTypes = ["Int8","Int16","Int32","Int64","UInt8","UInt16","UInt32","UInt64","IntSize","UIntSize","Integer","BigInt","BigUInt","Float32","Float64","Decimal","Rational"]

-- A harness expression calls checked definitions only.
checkHarnessExpression :: C.Unit -> S.Unit -> Maybe String -> String -> C.Expr -> Either String C.Expr
checkHarnessExpression closed u harness what e = case forbidden [] e of
  [] -> pure e
  n : _ -> Left (what ++ " in the harness" ++ maybe "" (" " ++) harness ++ " calls " ++ shortName n ++
    ", which is not a checked definition; a harness expression may call only checked definitions, " ++
    "since calling native code or an ability could change what the law observes")
  where
    pureDefinitions = [(C.declarationId (C.definitionDeclaration d),d) | d <- C.unitDefinitions closed,
      not (C.definitionOrchestrates d), null (C.declarationUses (C.definitionDeclaration d))]
    forbidden seen x = case C.expressionNode x of
      C.ExternalCall n args -> concatMap (forbidden seen) args ++ case lookup n pureDefinitions of
        Nothing -> [n]
        Just definition | n `elem` seen -> []
                        | otherwise -> forbidden (n:seen) (C.definitionBody definition)
      C.Perform op args -> C.Id (C.operationName op) : concatMap calls args
      C.Calls op _ -> [C.Id (C.operationName op)]
      C.Handle _ _ -> [C.Id "an ability handler"]
      C.Helper operation _ | operation `elem` [C.Recorded,C.AcquireResource,C.ReleaseResource,C.FreePort] -> [C.Id (C.builtinName operation)]
      _ -> concatMap (forbidden seen) (C.children x)
      where calls = forbidden seen
    shortName (C.Id n) = maybe n id (stripPrefix (S.unitName u ++ "::") n)

handlerRef :: S.Unit -> S.HandlerChoice -> C.HandlerRef
handlerRef u choice = case choice of
  S.ChooseProduction -> C.ProductionHandler
  S.ChooseSpec h -> C.SpecHandler (C.Id (S.unitName u ++ "::handler::" ++ h))
  S.ChooseRecording c -> C.RecordingHandler (handlerRef u c)

-- Every expression of a property.
mapProperty :: (C.Expr -> C.Expr) -> C.Property -> C.Property
mapProperty f p = p
  { C.propertyInputs = [q { C.quantifiedPredicates = map f (C.quantifiedPredicates q)
                          , C.quantifiedBounds = [(op, f e) | (op, e) <- C.quantifiedBounds q] } | q <- C.propertyInputs p]
  , C.propertyBody = proposition (C.propertyBody p)
  , C.propertyResources = [r { C.resourceAcquire = f (C.resourceAcquire r), C.resourceRelease = f (C.resourceRelease r), C.resourceReset = fmap f (C.resourceReset r) } | r <- C.propertyResources p]
  , C.propertyExamples = [e { C.exampleBindings = [(i, f v) | (i, v) <- C.exampleBindings e]
                            , C.exampleExpectations = map proposition (C.exampleExpectations e) } | e <- C.propertyExamples p] }
  where
    proposition = C.mapPropositionExpressions f

-- | The last part of a qualified name: lawspec.resources::type::FreePort gives FreePort.
baseName :: String -> String
baseName name = case break (== ':') name of
  (_, ':' : ':' : rest) -> baseName rest
  (n, _) -> n

-- | Quoted law names may contain separators. Escape them before composing IDs so
-- a display name cannot masquerade as a binder segment in target accessors.
sourcePropertyId :: String -> String -> C.Id
sourcePropertyId owner name=C.Id (owner++"::law::"++C.escapeIdentity name)

elaborationTable :: Table (Either String (C.Property,[C.DataDeclaration]))
elaborationTable = unsafePerformIO (newPersistentTable "elaborate" 4096 (const 1))
{-# NOINLINE elaborationTable #-}
