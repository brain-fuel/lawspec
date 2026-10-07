-- | The only bridge from checked surface syntax to the typed core. Targets never
-- receive TypedExpr's source tree or perform contextual literal inference.
module LawSpec.Frontend (compileCore, elaborate, elaborateExpression) where
import qualified LawSpec.Model as S
import qualified LawSpec.Compile as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Data (elaborateDataDeclarationsWithProfile)
import LawSpec.Elaboration (coreType, elaborateExpression, elaborateResolvedWithData, equationWithData, binaryOp, elaborateDefinitionUnit, elaborateContract, abilityReference, unitOperations, performOperations)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Release (checkResourceReleases)
import LawSpec.Core.Total (deferProgramPostconditions)
import Control.Monad (forM, unless)
import Data.List (nub, nubBy, stripPrefix)
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
  elaborate bits units properties

-- | Every surface construct is lowered here, once, and the result validated
-- before any backend sees it. ref:DEC-elaborate-before-core
elaborate :: Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborate bits units properties = do
  dataDeclarations <- elaborateDataDeclarationsWithProfile bits units
  elaborated <- C.Program bits dataDeclarations <$> mapM (unit dataDeclarations) units
  -- Postconditions over non-linear index arithmetic become runtime checks.
  core <- deferProgramPostconditions elaborated
  validateProgram core
  checkResourceReleases core
  pure core
  where
    unit dataDeclarations u = do
      (closed, owned, ps0, cs) <- contextual Nothing $ do
        closed <- elaborateDefinitionUnit dataDeclarations bits u
        cs <- mapM (elaborateContract dataDeclarations bits u) (S.contracts u)
        -- A law's Core depends on it, its unit's signatures and the data types.
        let dataDigest = digestHex (digestString (show dataDeclarations))
            elaborated p = memoized elaborationTable
              (digestHex (digestString (show (bits, dataDigest, S.unitName u, S.functions u, S.resourceDeclarations u, p))))
              (property dataDeclarations u p)
            owned = filter ((== S.unitName u) . S.owner) properties
        ps0 <- mapM elaborated owned
        pure (closed, owned, ps0, cs)
      -- The harness plane: how each law is tested (LawSpec.Harness).
      ps <- mapM (\(sp, cp) -> harnessed dataDeclarations closed u sp cp) (zip owned ps0)
      settings <- unitHarnessSettings dataDeclarations closed u
      contextual Nothing $ do
        -- Calls to ability operations are Perform; each law gets the handlers
        -- the abilities pass chose for it.
        (_, operations) <- unitOperations u
        handled <- forM ps $ \p -> do
          assignment <- forM (maybe [] id (lookup (C.propertyName p) (S.lawAssignments u))) $ \(ability, choice) ->
            (,) <$> abilityReference u ability <*> pure (handlerRef u choice)
          -- A resource's operations (a built-in resource's lawspec.host
          -- ones) run under the production handler of their ability.
          let resourceAbilities = nub [C.operationAbility op | r <- C.propertyResources p
                , e <- [C.resourceAcquire r, C.resourceRelease r] ++ maybe [] pure (C.resourceReset r), op <- performedIn e]
              withResources = assignment ++ [(a, C.ProductionHandler) | a <- resourceAbilities, a `notElem` map fst assignment]
          pure (shared settings (mapProperty (performOperations operations) p)) { C.propertyHandlers = withResources }
        -- A benchmark's operations are Perform, like a law's.
        let settings' = fmap (\h -> h { C.harnessBenchmarks = [(n, performOperations operations b) | (n, b) <- C.harnessBenchmarks h] }) settings
        pure closed{C.unitContracts=cs,C.unitProperties=handled,C.unitHarnessSettings=settings'}
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
    property dataDeclarations u p = do
      let pid = C.Id (S.unitName u ++ "::law::" ++ escapeIdentity (S.name p))
          original = S.original p
          resourceIds = [(n,C.Id (C.idText pid ++ "::resource::" ++ show index)) | (index,(n,_)) <- zip [0::Int ..] (S.lawResources original)]
          bindings = [(S.inputId i,C.Id (C.idText pid ++ "::input::" ++ show index)) | (index,i) <- zip [0::Int ..] (S.inputs p)] ++ resourceIds
          env = S.functions u ++ [(S.inputId i,S.inputType i) | i <- S.inputs p] ++ S.lawResources original
          resolve n = maybe (declarationId u n) id (lookup n bindings)
          term = elaborateResolvedWithData dataDeclarations [declarationId u n | (n,_) <- S.functions u] bits pid resolve env
          equal a b = equationWithData dataDeclarations [declarationId u n | (n,_) <- S.functions u] bits pid resolve env a b
          assertion (S.AssertEqual a b) = equal a b
          assertion (S.AssertImplies g body) = C.Implication <$> term g <*> assertion body
          assertion (S.AssertAll bodies) = C.Conjunction <$> mapM assertion bodies
      qs <- forM (S.inputs p) $ \i -> do
        t <- coreType (S.inputType i)
        preds <- mapM term (S.inputRefinements i)
        let bounds = concat [S.domainBounds plan | plan <- S.generationPlan p, S.inputId (S.domainInput plan) == S.inputId i]
        boundTerms <- mapM (\(op,e) -> (,) <$> binaryOp op <*> term e) bounds
        pure (C.Quantifier (C.Binder (resolve (S.inputId i)) (S.inputName i) t) preds boundTerms)
      body <- assertion (S.assertion p)
      examples <- forM (S.examples original) $ \e -> do
        let aliases = [(S.inputName i,S.Var (S.inputId i)) | i <- S.inputs p]
            replace = S.replaceExprVars aliases
        values <- forM (S.inputs p) $ \i -> do
          lit <- maybe (Left ("missing example binding: " ++ S.inputName i)) Right (lookup (S.inputName i) (S.bindings e))
          value <- term (S.Annotate (S.literalExpr lit) (S.inputType i))
          pure (resolve (S.inputId i),value)
        expects <- forM (S.expectations e) $ \x -> equal (replace (S.actual x)) (S.literalExpr (S.expected x))
        pure (C.Example (S.exampleName e) values expects)
      resources <- forM (zip resourceIds (S.lawResources original)) $ \((n, rid), (_, ty)) -> do
        t <- coreType ty
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
              release <- elaborateResolvedWithData dataDeclarations [declarationId u n' | (n',_) <- S.functions u] bits pid resolveRelease
                ((parameter, ty) : S.functions u) releaseBody
              reset <- forM (S.resourceReset declaration) $ \(resetParameter, resetBody) ->
                elaborateResolvedWithData dataDeclarations [declarationId u n' | (n',_) <- S.functions u] bits pid
                  (\name -> if name == resetParameter then rid else resolve name) ((resetParameter, ty) : S.functions u) resetBody
              -- A law that releases its own resource is rejected over the
              -- whole program (LawSpec.Release), once definitions are known.
              pure (C.Resource binder acquire release reset Nothing (S.resourceConcurrent declaration))
            [] -> Left (S.name p ++ " takes " ++ n ++ " :: " ++ S.prettyType ty ++ ", but no resource is declared for " ++ S.prettyType ty ++ "; declare resource " ++ S.prettyType ty ++ " is acquire ... release ... end")
            _ -> Left ("more than one resource is declared for " ++ S.prettyType ty)
      pure C.Property
        { C.propertyId=pid, C.propertyName=S.name p, C.propertyLocation=S.location original
        , C.propertyInputs=qs, C.propertyBody=body, C.propertyExamples=examples
        , C.propertyGeneration=S.generation p, C.propertyDescription=S.description original
        , C.propertyRationale=S.rationale original, C.propertyReferences=S.references original
        , C.propertyTrace=S.trace p, C.propertyHandlers=[], C.propertyResources=resources, C.propertyHarness=C.noHarness }
    contextual at = either (Left . pure . (\msg -> Diagnostic "elaboration" msg at)) Right
    -- A law's harness plan, elaborated over its inputs. Its expressions may
    -- call checked definitions only: calling native code or an ability
    -- operation could change what the law observes.
    harnessed dataDeclarations closed u sp cp = case lookup (S.name sp) (S.lawHarness u) of
      Nothing -> pure cp { C.propertyHarness = C.noHarness { C.harnessUnit = S.harnessName <$> S.unitHarness u } }
      Just plan -> either (\msg -> Left [Diagnostic "harness" msg (Just (S.location (S.original sp)))]) Right $ do
        let pid = C.propertyId cp
            functionIds = [declarationId u n | (n,_) <- S.functions u]
            inputIds = [(S.inputId i, C.binderId (C.quantifiedBinder q)) | (i, q) <- zip (S.inputs sp) (C.propertyInputs cp)]
            aliases = [(S.inputName i, S.Var (S.inputId i)) | i <- S.inputs sp]
            lawEnv = S.functions u ++ [(S.inputId i, S.inputType i) | i <- S.inputs sp]
            resolveWith locals n = maybe (maybe (declarationId u n) id (lookup n inputIds)) id (lookup n locals)
            pureOnly what e = checkHarnessExpression closed u (S.harnessName <$> S.unitHarness u) what e
            lawTerm what ty e = do
              t <- elaborateResolvedWithData dataDeclarations functionIds bits pid (resolveWith []) lawEnv
                (maybe id (flip S.Annotate) ty (S.replaceExprVars aliases e))
              pureOnly what t
        covers <- mapM (\(percent, label, e) -> C.Cover percent label <$> lawTerm ("cover \"" ++ label ++ "\"") (Just (S.Named "Bool")) e) (S.planCover plan)
        classes <- mapM (\(e, label) -> (\t -> (t, label)) <$> lawTerm ("classify as \"" ++ label ++ "\"") (Just (S.Named "Bool")) e) (S.planClassify plan)
        labels <- mapM (lawTerm "label" (Just (S.Named "Text"))) (S.planLabels plan)
        target <- traverse (\e -> do
          t <- lawTerm "target maximize" Nothing e
          case C.expressionType t of
            C.Constructor n [] | n `elem` numericTypes -> pure t
            other -> Left ("target maximize needs a number to maximize, but " ++ S.prettyExpr e ++ " is " ++ show other)) (S.planTarget plan)
        draws <- forM (S.planDraws plan) $ \(inputName, strategy, declared, gen) -> do
          (i, q) <- maybe (Left ("use " ++ strategy ++ " for " ++ inputName ++ ": the law has no input called " ++ inputName)) Right
            (lookup inputName [(S.inputName i, (i, q)) | (i, q) <- zip (S.inputs sp) (C.propertyInputs cp)])
          -- A strategy of a refined type, (n :: T where p), keeps only the
          -- values that satisfy p, as `such that` does.
          let (plain, refined) = case declared of
                S.Refined n t (Just p) -> (t, Just (S.replaceExprVars [(n, S.Var "it")] p))
                _ -> (declared, Nothing)
              gen' = maybe gen (\p -> S.GenSuchThat gen p 100) refined
          declaredType <- coreType plain
          let inputType = C.binderType (C.quantifiedBinder q)
          unless (declaredType == inputType)
            (Left ("the strategy " ++ strategy ++ " produces values of " ++ S.prettyType declared ++ ", but the input " ++
              inputName ++ " is " ++ S.prettyType (S.inputType i) ++ "; a strategy may only produce values of its type"))
          draw <- elaborateDraw dataDeclarations closed u pid strategy (S.inputId i) plain refined gen'
          pure (C.binderId (C.quantifiedBinder q), strategy, draw)
        pure cp { C.propertyHarness = C.LawHarness
          { C.harnessUnit = Just (S.planHarness plan), C.harnessTags = S.planTags plan
          , C.harnessSkip = S.planSkip plan, C.harnessKnownFailing = S.planKnownFailing plan
          , C.harnessTimeout = S.planTimeout plan, C.harnessRepeat = S.planRepeat plan
          , C.harnessRetries = S.planRetries plan, C.harnessCover = covers, C.harnessClassify = classes
          , C.harnessLabels = labels, C.harnessTarget = target, C.harnessDraws = draws
          , C.harnessGroup = S.planGroup plan } }
    -- A strategy's draw. Its values are typed by the strategy's type; a
    -- bound value, or `it` in such that, is a local of the test.
    -- A refined strategy's any (the strategy's own value, of its declared
    -- type) aims at the refinement, as a law input's generator does: its
    -- quantifier carries the refinement, whose bounds direct generation.
    -- The such that around it still checks every drawn value.
    elaborateDraw dataDeclarations closed u pid strategy input declared refinement gen = do
      aim <- forM refinement $ \p -> do
        core <- coreType declared
        let binder = C.Binder (local (-1) "it") "it" core
        predicate <- term [("it", (C.binderId binder, declared))] (S.Named "Bool") p
        pure (C.Quantifier binder [predicate] [])
      go aim (0 :: Int) [] declared gen
      where
        functionIds = [declarationId u n | (n,_) <- S.functions u]
        local k n = C.Id (C.idText pid ++ "::input::" ++ input ++ "_" ++ n ++ show k)
        term locals ty e = do
          t <- elaborateResolvedWithData dataDeclarations functionIds bits pid
            (\n -> maybe (declarationId u n) fst (lookup n locals))
            ([(n, t') | (n, (_, t')) <- locals] ++ S.functions u) (S.Annotate e ty)
          checkHarnessExpression closed u (S.harnessName <$> S.unitHarness u) ("the strategy " ++ strategy) t
        go aim k locals ty g = case g of
          S.GenAny Nothing -> anyOf aim ty
          S.GenAny (Just other) -> do
            unless (S.baseType other == S.baseType ty || coreType other == coreType ty)
              (Left ("the strategy " ++ strategy ++ " draws any " ++ S.prettyType other ++ " where it needs " ++ S.prettyType ty))
            anyOf aim ty
          S.GenNamed n -> Left ("the strategy " ++ n ++ " is not known here")
          S.GenOneOf values -> C.DrawOneOf <$> coreType ty <*> mapM (term locals ty) values
          S.GenFrequency alternatives -> C.DrawFrequency <$> mapM (\(w, a) -> (,) w <$> go aim k locals ty a) alternatives
          S.GenSuchThat inner p limit -> do
            inner' <- go aim (k + 1) locals ty inner
            core <- coreType ty
            let binder = C.Binder (local k "it") "it" core
            predicate <- term (("it", (C.binderId binder, ty)) : locals) (S.Named "Bool") p
            pure (C.DrawSuchThat inner' binder predicate limit)
          S.GenBind x xty from body -> do
            core <- coreType xty
            let binder = C.Binder (local k x) x core
            from' <- go Nothing (k + 1) locals xty from
            body' <- go aim (k + 1) ((x, (C.binderId binder, xty)) : locals) ty body
            pure (C.DrawBind binder from' body')
        -- Only a draw of the strategy's own type aims at its refinement.
        anyOf aim ty = C.DrawAny <$> coreType ty <*> pure (if ty == declared then aim else Nothing)
    -- Benchmarks, sharing and order: the harness settings beyond laws.
    unitHarnessSettings dataDeclarations _ u = case S.unitHarness u of
      Nothing -> pure Nothing
      Just h -> do
        let functionIds = [declarationId u n | (n,_) <- S.functions u]
            withAbilities = [n | (n, row) <- S.abilityRows u, not (null row)]
        benchmarks <- forM [(n, e, range) | S.HarnessBenchmark n e range <- S.harnessItems h] $ \(n, e, range) -> do
          let at = Just (spanStart range)
              failing msg = Left [Diagnostic "harness" ("benchmark `" ++ n ++ "`: " ++ msg) at]
          t <- either failing Right
            (elaborateResolvedWithData dataDeclarations functionIds bits (C.Id (S.unitName u ++ "::benchmark::" ++ n))
              (declarationId u) (S.functions u) e)
          -- A benchmark that calls what uses abilities runs under their
          -- production handlers (the native ones, or the defaults), each
          -- installed around it; a failure it raises fails the benchmark.
          refs <- either failing Right (mapM (abilityReference u)
            (nubBy (\a b -> S.prettyType a == S.prettyType b)
              [ty | x <- S.exprVars e, x `elem` withAbilities, Just row <- [lookup x (S.abilityRows u)], ty <- row]))
          let installed = foldr (\ref body -> body { C.expressionNode = C.Handle (C.WithHandler ref C.ProductionHandler) body })
                t [ref | ref <- nub refs, not (C.isFail ref)]
          pure (n, installed)
        pure (Just (C.UnitHarness (S.harnessName h)
          (not (null [() | S.HarnessOrderRandom _ <- S.harnessItems h]))
          (not (null [() | S.HarnessParallel _ <- S.harnessItems h]))
          [(r, case scope of S.SharePerGroup -> "group"; S.SharePerUnit -> "unit"; S.SharePerRun -> "run") | S.HarnessShare r scope _ <- S.harnessItems h]
          benchmarks))
    numericTypes = ["Int8","Int16","Int32","Int64","UInt8","UInt16","UInt32","UInt64","IntSize","UIntSize","Integer","BigInt","BigUInt","Float32","Float64","Decimal","Rational"]

-- A harness expression calls checked definitions only.
checkHarnessExpression :: C.Unit -> S.Unit -> Maybe String -> String -> C.Expr -> Either String C.Expr
checkHarnessExpression closed u harness what e = case [n | n <- calls e, n `notElem` pureDefinitions] of
  [] -> pure e
  n : _ -> Left (what ++ " in the harness" ++ maybe "" (" " ++) harness ++ " calls " ++ shortName n ++
    ", which is not a checked definition; a harness expression may call only checked definitions, " ++
    "since calling native code or an ability could change what the law observes")
  where
    pureDefinitions = [C.declarationId (C.definitionDeclaration d) | d <- C.unitDefinitions closed, not (C.definitionOrchestrates d)]
      ++ [C.Id n | n <- prelude]
    prelude = []
    calls x = case C.expressionNode x of
      C.ExternalCall n args -> n : concatMap calls args
      C.Perform op args -> C.Id (C.operationName op) : concatMap calls args
      C.Calls op _ -> [C.Id (C.operationName op)]
      _ -> concatMap calls (C.children x)
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
    proposition (C.Equation ev a b) = C.Equation ev (f a) (f b)
    proposition (C.Implication g body) = C.Implication (f g) (proposition body)
    proposition (C.Conjunction ps) = C.Conjunction (map proposition ps)

-- | The last part of a qualified name: lawspec.resources::type::FreePort gives FreePort.
baseName :: String -> String
baseName name = case break (== ':') name of
  (_, ':' : ':' : rest) -> baseName rest
  (n, _) -> n

-- | Quoted law names may contain separators. Escape them before composing IDs so
-- a display name cannot masquerade as a binder segment in target accessors.
escapeIdentity :: String -> String
escapeIdentity = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])

elaborationTable :: Table (Either String C.Property)
elaborationTable = unsafePerformIO (newPersistentTable "elaborate" 4096 (const 1))
{-# NOINLINE elaborationTable #-}
