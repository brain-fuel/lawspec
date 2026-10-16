-- | The checked surface pipeline: parse, resolve imports, infer, lower
-- refinements and expand each law into the inputs, assertion and domain the
-- testing plan needs. It stops at the surface; LawSpec.Frontend turns its
-- result into typed Core, so the eight emitters never see source syntax.
-- ref:DEC-typed-core-boundary
module LawSpec.Compile (compile, prettyExpanded, metadataText, normal, compileWithProfile, typedExpression, validType, compileWithSettings, compileWithImports, compileCanonical, compileCanonicalWithImports, compileCanonicalWithReferenceUnits, compileWithSourceSyntax, compileWithMigrationCapture, validateDefinitionTypes, validateDefinitionTotality) where

import LawSpec.Core.Total (deferProgramPostconditions)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords,normalizeExpressionRecords)
import LawSpec.Model
import LawSpec.SourceSyntax (SourceSyntax(..),SyntaxNode(..),SyntaxReference(..))
import LawSpec.MigrationTemplates (SourceTemplates(..),DefinitionTemplate)
import LawSpec.Data (qualifyDataNames, elaborateDataDeclarationsWithContext, dataDeclarationHeaders, inlineFieldDefinitions, fieldDefinitionChecks, fieldDefinitionDependencies, migrationConstructorSources)
import LawSpec.Capabilities (satisfiedWithContext)
import qualified LawSpec.SourceContext as Source
import LawSpec.Inference
import LawSpec.DefinitionTotality (auditTemplatesWithContext, auditTemplatesWithDeferrals)
import qualified LawSpec.SourceRecords as SourceRecords
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.SpecializeDefinitions (specializeDefinitionsWithContext)
import qualified LawSpec.Elaboration as Elaboration
import qualified LawSpec.Core as Core
import qualified LawSpec.Core.Eval as CoreEval
import LawSpec.Core.Definitions (prepareDefinitions)
import qualified LawSpec.Core.Types as CoreTypes
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Scalar
import LawSpec.Parser
import LawSpec.Imports (resolveImportsByProfile,resolveImportsByProfileWithBindings)
import LawSpec.Documentary (resolveDocumentaryReferences)
import LawSpec.Abilities (elaborateAbilities)
import LawSpec.Harness (elaborateHarness)
import LawSpec.HarnessWitness (prepareHarnessWitnesses)
import LawSpec.Collections (collectionsUnit, usedCollections, usedCollectionsCanonical, collectionsSource)
import LawSpec.Time (timeUnit, timeAlias, timeTypes, usesTime, timeSource)
import LawSpec.Matchers (matchersUnit, matchersAlias, matchersTypes, usesMatchers, matchersSource, regexTypeName)
import LawSpec.Regex (parseRegex)
import LawSpec.Resources (resourcesUnit, resourcesAlias, resourcesTypes, usesResources, resourcesSource)
import LawSpec.Resilience (resilienceUnit, resilienceAlias, resilienceTypes, usesResilience, resilienceSource)
import LawSpec.Network (networkUnit, networkSource)
import LawSpec.Builtins (builtinUnits, builtinSource, importsBuiltin, usesClock, clockSource)
import LawSpec.Refinement
import LawSpec.Prelude
import LawSpec.PreludeNames (preludeDiscoveryText,preludeDependencyText)
import Control.Monad.State.Strict
import Control.Monad (unless, when, zipWithM_, forM, forM_, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate, uncons)
import Data.Char (isLower)
import Data.List (isSuffixOf, isPrefixOf, isInfixOf, stripPrefix)
import qualified Data.Set as Set
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Digest (digestHex, digestString)
import qualified LawSpec.Memo as Memo
import LawSpec.Persist ()


rename :: String -> Type -> Type
rename p = mapType change (mapExprTypes (rename p)) where
  change (Variable n) = Variable (p ++ ":" ++ n)
  change t = t
renameConstraint :: String -> Constraint -> Constraint
renameConstraint p (Capability n t) = Capability n (rename p t)
subst :: M.Map String Expr -> Expr -> Expr
subst replacements = replaceExprVars (M.toList replacements)
argumentChecks :: Type -> [Expr]
argumentChecks (CheckedType ps t) = ps ++ argumentChecks t
argumentChecks (Refined _ t _) = argumentChecks t
argumentChecks (Qualified _ t) = argumentChecks t
argumentChecks (Applied _ t) = argumentChecks t
argumentChecks (Application _ ts) = concatMap argumentChecks ts
argumentChecks _ = []
closedCheck :: [String] -> Expr -> Bool
closedCheck definitions (Located _ e) = closedCheck definitions e
closedCheck definitions (ConstructLit _ fields) = all (closedCheck definitions) fields
closedCheck definitions (RecordLit fields) = all (closedCheck definitions . snd) fields
closedCheck definitions (AllPayloadsExpr value predicates) = closedCheck definitions value && all
  (\(binder,body) -> closedCheck definitions (replaceExprVars [(binder,BoolLit False)] body)) predicates
closedCheck definitions (AllElementsExpr value binder predicate) = closedCheck definitions value &&
  closedCheck definitions (replaceExprVars [(binder,BoolLit False)] predicate)
closedCheck definitions (MatchExpr value branches) = closedCheck definitions value && all
  (\(MatchBranch _ names body) -> closedCheck definitions (replaceExprVars [(n, BoolLit False) | n <- names] body)) branches
closedCheck definitions (ListLit xs) = all (closedCheck definitions) xs
closedCheck definitions (Var n) = take 8 n == "prelude." || n `elem` definitions
closedCheck definitions (TypeBound _ (Named n)) = maybe False (const True) (integerBounds 64 n)
closedCheck definitions (TypeBound _ _) = False
closedCheck definitions (Apply a b) = closedCheck definitions a && closedCheck definitions b
closedCheck definitions (Compose a b) = closedCheck definitions a && closedCheck definitions b
closedCheck definitions (Binary _ a b) = closedCheck definitions a && closedCheck definitions b
closedCheck definitions (Unary _ a) = closedCheck definitions a
closedCheck definitions (Annotate a _) = closedCheck definitions a
closedCheck _ _ = True

type Table = M.Map (String,String) Law

-- Built-in laws keep their versioned source grammar. Canonical callers name
-- their existing mathematical laws with ordinary phrase delimiters; local
-- and explicitly imported names are resolved before this prelude fallback.
preludeLawName :: String -> String
preludeLawName name = unphrase (maybe name id (stripPrefix "prelude." name))
  where
    unphrase ('"':'|':rest) | "|" `isSuffixOf` rest = unescape (init rest)
    unphrase n = n
    unescape ('\\':c:rest) = c : unescape rest
    unescape (c:rest) = c : unescape rest
    unescape [] = []

expand :: [String] -> Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Assertion, [String], [Expr])
expand = expandScoped False

-- Canonical quantifiers keep lexical scope throughout expansion. Only a
-- leading universal prefix becomes generated inputs; sibling quantifiers
-- and binders in implications/negations stay in the typed proposition.
expandCanonical :: [String] -> Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Assertion, [String], [Expr])
expandCanonical definitions table unit env stack law args = do
  (_,body,trace,checks) <- expandScoped True definitions table unit env stack law args
  let outer inputs (AssertQuantified ForEvery input rest)
        | inputName input `notElem` map inputName inputs = outer (inputs ++ [input]) rest
      outer inputs body = (inputs,body)
      (inputs,assertion) = outer [] body
  pure (inputs,assertion,trace,checks)

expandScoped :: Bool -> [String] -> Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Assertion, [String], [Expr])
expandScoped scoped definitions table unit env stack law args = do
  let key = unit ++ "::" ++ lawName law
  when (key `elem` stack) (throwC ("recursive law expansion: " ++ intercalate " -> " (reverse (key:stack))))
  unless (length args == length (parameters law)) (throwC ("wrong argument count for law " ++ lawName law))
  p <- fresh
  let rt = rename p
  zipWithM_ (\(_,t) arg -> checkExpr env (rt t) arg) (parameters law) args
  modify (\s -> s{obligations=map (renameConstraint p) (requirements law) ++ obligations s})
  let replacements = M.fromList (zip (map fst (parameters law)) args)
      bind e m qs = foldM (\(bs,scope,replacements',checks) (n,t) -> do
          when (n `elem` map inputName bs) (throwC "duplicate quantified input")
          i <- ("_input"++) <$> fresh
          let renamed = rt t
              predicates = map (normal . subst (M.insert n (Var i) replacements')) (typePredicates (Var n) renamed)
          t' <- resolve renamed
          let scope' = M.insert i (Monomorphic t') scope
          mapM_ (checkPredicate definitions scope') predicates
          -- A concrete refinement argument must inhabit its declared parameter
          -- type even when the resulting quantified domain is not executable.
          bits <- gets machineBits
          forM_ (map (normal . subst replacements') (argumentChecks renamed)) $ \check ->
            when (closedCheck [] check) $ do
              dataTypes <- gets dataDeclarations
              sourceTypes <- gets sourceContext
              (term,registry) <- lift (evaluationTerm sourceTypes dataTypes [] bits (Core.Id key) Core.Id (environmentTypes scope') check)
              value <- lift (CoreEval.evaluateValuePure registry bits [] term)
              unless (value == CoreValue.ScalarValue (SBool True)) (throwC "refinement value argument violates its declared parameter type")
          mapM_ (\(Capability c ty) -> resolve ty >>= require c) (typeConstraints renamed)
          pure (bs ++ [Input n i t' predicates],scope',M.insert n (Var i) replacements',
            checks ++ filter (closedCheck definitions) (map (normal . subst replacements') (argumentChecks renamed)))) ([],e,m,[]) qs
      walk mode e m (Forall qs d) = do
        (bs,e',m',checks) <- bind e m qs
        (rest,body,tr,more) <- walk mode e' m' d
        if mode then pure ([],foldr (AssertQuantified ForEvery) body (bs ++ rest),tr,checks ++ more)
          else pure (bs ++ rest,body,tr,checks ++ more)
      walk _ e m (Exists qs d) = do
        (bs,e',m',checks) <- bind e m qs
        (_,body,tr,more) <- walk True e' m' d
        pure ([],foldr (AssertQuantified ForSome) body bs,tr,checks ++ more)
      walk _ e m (Not d) = do
        (_,body,tr,checks) <- walk True e m d
        pure ([],AssertNot body,tr,checks)
      walk mode e m (Equal a b) = do
        let left = normal (subst m (mapExprTypes rt a)); right = normal (subst m (mapExprTypes rt b))
        (l,r) <- jointStructuralContext e left right
        lt <- infer e l >>= resolve
        rt' <- infer e r >>= resolve
        case (lt,rt') of
          (Named ('@':_),Named b) | isNumeric b -> require "Integer" lt
          (Named a,Named ('@':_)) | isNumeric a -> require "Integer" rt'
          (Named a,Named b) | isNumeric a && isNumeric b -> do
            if contextualNumber l then checkExpr e rt' l else if contextualNumber r then checkExpr e lt r else lift (promote "==" a b) >> pure ()
          _ | isLiteral l -> checkExpr e rt' l
            | isLiteral r -> checkExpr e lt r
            | otherwise -> unify lt rt'
        modify (\s -> s{obligations=Capability "Eq" (if isLiteral l then rt' else lt):obligations s})
        pure ([],AssertEqual l r,[],[])
      walk mode e m (Holds a) = walk mode e m (Equal a (BoolLit True))
      walk mode e m (Implies condition consequence) = do
        let guard = normal (subst m (mapExprTypes rt condition))
        infer e guard >>= unify (Named "Bool")
        (bs,body,tr,checks) <- walk mode e m consequence
        pure (bs,AssertImplies guard body,tr,checks)
      walk mode e m (And a b) = do
        (as,a',at,ac) <- walk mode e m a
        (bs,b',bt,bc) <- walk mode e m b
        pure (as++bs,AssertAll [a',b'],at++bt,ac++bc)
      walk mode e m (Invoke n as) = do
        (u,called) <- case M.lookup (unit,n) table of
          Just v -> pure (unit,v)
          Nothing -> maybe (throwC ("unknown law: " ++ n)) (pure . (,) "prelude") (M.lookup ("prelude",preludeLawName n) table)
        expandScoped mode definitions table u e (key:stack) called (map (subst m . mapExprTypes rt) as)
  (bs,body,tr,checks) <- walk scoped env replacements (definition law)
  pure (bs,body,(lawName law ++ concatMap ((" "++) . prettyExpr) args):tr,checks)

unique :: String -> [String] -> Either String ()
unique kind xs = unless (length xs == length (nub xs)) (Left ("duplicate " ++ kind))
-- | Only these shapes can cross an adapter boundary as portable values, so a
-- law over anything else is refused before any target is asked to emit it.
validType :: Type -> Bool
validType (Named n) = maybe False (const True) (primitive n)
validType (Applied n t) = n `elem` ["Nullable","Optional","List","Maybe"] && scalar t
validType (Application "Either" [a,b]) = scalar a && scalar b
validType (Record fields) = all (validType . recordFieldType) fields
validType (Variable _) = True
validType (Arrow a b) = validType a && validType b
validType (Refined _ t _) = validType t
validType (Qualified _ t) = validType t
validType (CheckedType _ t) = validType t
validType _ = False
scalar :: Type -> Bool
scalar (Arrow _ _) = False
scalar t = validType t
validateUnit :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
validateUnit sourceTypes dataTypes bits u = either (Left . pure . (\m -> Diagnostic "declaration" m Nothing)) Right $ do
  let checkTypes = typeCheck sourceTypes dataTypes bits
  unique "constructor" [dataConstructorName c | d <- LawSpec.Model.dataTypes u, c <- dataTypeConstructors d]
  unique "function" (map fst (functions u)); unique "law" (map lawName (laws u))
  forM_ (functions u) $ \(n,t) -> do
    unless (take 2 n == "\"|" || maybe False (isLower . fst) (uncons n)) (Left "function names must start with a lowercase letter")
    let (args,result) = functionType t
    -- An ability operation may take no values (now :: Instant).
    if n `elem` operationNames u
      -- (A parameterized ability's parameters are instantiated at each use.)
      then unless (all (concreteValue checkTypes . mapType (\x -> case x of
          Variable v | "ability:" `isPrefixOf` v -> Named "Int32"
          _ -> x) id) (result:args))
        (Left (n ++ ": an ability operation takes and gives concrete values"))
      else unless (not (null args) && all (if n `elem` map functionName (functionDefinitions u) then valueType checkTypes else concreteValue checkTypes) (result:args))
        (Left (n ++ ": functions require one or more concrete value inputs and a value result"))
  forM_ (laws u) $ \l -> do
    mapM_ (metadataText (map fst (parameters l ++ functions u))) [description l, rationale l]
    forM_ (examples l) $ \ex ->
      -- A table's row, or an example in a description, may check only the law.
      when (null (expectations ex) && not (any (`isPrefixOf` exampleName ex) ["row ", "table ", "description"]))
        (Left ("example " ++ exampleName ex ++ " requires at least one expect assertion; add expect <expression> = <literal>"))
    unique "parameter" (map fst (parameters l)); unique "example" (map exampleName (examples l))
    forM_ (parameters l) $ \(_,t) -> do
      let (args,result) = functionType t
      unless (all (valueType checkTypes) (result:args)) (Left "law parameters must be values or curried functions between value types")
    unless (all (\(Capability _ t) -> valueType checkTypes t) (requirements l)) (Left "capability requires a value type")
    unless (all (validTypeWithData checkTypes . snd) (parameters l) && all (\(Capability _ t) -> validTypeWithData checkTypes t) (requirements l)) (Left "unsupported type")

-- A Regex is made from a literal in the portable dialect (LawSpec.Regex),
-- checked here, and laws do not quantify over Regex: LawSpec never makes one
-- up.
checkRegexes :: Unit -> Either [Diagnostic] ()
checkRegexes u = do
  let constructor = regexTypeName ++ "::Regex"
      problem at message = Left [Diagnostic "regex" message at]
      check at e = case e of
        Located (Span start _) inner -> check (Just start) inner
        ConstructLit name fields | name == constructor -> case map unlocated fields of
          [StringLit pattern] -> either (\m -> problem at ("regex \"" ++ pattern ++ "\" is not portable: " ++ m)) (const (pure ())) (parseRegex pattern)
          _ -> problem at "a Regex is made from a literal, such as regex \"[a-z]+\""
        _ -> mapM_ (check at) (subexpressions e)
      definitionExprs d = case d of
        Forall _ body -> definitionExprs body
        Exists _ body -> definitionExprs body
        Not body -> definitionExprs body
        Equal a b -> [a, b]
        Holds a -> [a]
        Implies a body -> a : definitionExprs body
        And a b -> definitionExprs a ++ definitionExprs b
        Invoke _ args -> args
      quantified d = case d of
        Forall qs body -> qs ++ quantified body
        Exists qs body -> qs ++ quantified body
        Not body -> quantified body
        Implies _ body -> quantified body
        And a b -> quantified a ++ quantified b
        _ -> []
      mentionsRegex t = regexTypeName `isInfixOf` show t
  when (unitName u /= matchersUnit) $ do
    forM_ (laws u) $ \l -> do
      mapM_ (check (Just (location l))) (definitionExprs (definition l) ++ [actual x | ex <- examples l, x <- expectations ex])
      forM_ (quantified (definition l)) $ \(n, t) -> when (mentionsRegex t)
        (problem (Just (location l)) ("law " ++ lawName l ++ " quantifies over " ++ n ++ ", a Regex; LawSpec does not generate regexes, so write one with regex \"...\""))
    forM_ (functionDefinitions u) $ \d -> check (Just (spanStart (functionSpan d))) (functionBody d)
  where
    subexpressions e = case e of
      Located _ a -> [a]
      Apply a b -> [a, b]
      Compose a b -> [a, b]
      ListLit xs -> xs
      ConstructLit _ fields -> fields
      RecordLit fields -> map snd fields
      MatchExpr v branches -> v : [b | MatchBranch _ _ b <- branches]
      AllElementsExpr v _ p -> [v, p]
      AllPayloadsExpr v ps -> v : map snd ps
      Binary _ a b -> [a, b]
      Unary _ a -> [a]
      Annotate a _ -> [a]
      _ -> []

-- | The 64-bit profile is the default machine, so callers that state nothing get
-- the profile every target documents. ref:DEC-explicit-machine-profile
compile :: [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compile = compileWithProfile 64

-- | Machine-sized integers have no meaning until a profile is chosen, so the
-- profile is an argument of compilation rather than a property of the host.
-- ref:DEC-explicit-machine-profile
compileWithProfile :: Int -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithProfile bits = compileWithSettings bits defaultGeneration

-- | Generation settings change the expanded domains (exhaustive limits, size
-- budgets), so they are fixed before expansion rather than at emission.
-- ref:DEC-planned-generation
compileWithSettings :: Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithSettings = compileWithImports (\_ _ -> Nothing)

-- | visible importer imported explains why a unit may not import another
-- (package boundaries), or is Nothing when it may.
compileWithImports :: (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithImports = compileWithParser False (\_ name -> name)
compileCanonical :: [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileCanonical = compileCanonicalWithImports (\_ _ -> Nothing) 64 defaultGeneration
compileCanonicalWithImports :: (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileCanonicalWithImports = compileCanonicalWithReferenceUnits (\_ name -> name)
-- | Documentary unit paths follow package version selection independently of
-- executable imports. The default entry point leaves unit paths unchanged.
compileCanonicalWithReferenceUnits :: (String -> String -> String) -> (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileCanonicalWithReferenceUnits = compileWithParser True
compileWithParser :: Bool -> (String -> String -> String) -> (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithParser canonical referenceUnit visible bits settings sources = do
  (units,properties,_,_) <- compileWithParserInventory False canonical referenceUnit visible bits settings sources
  pure (units,properties)

compileWithSourceSyntax :: Bool -> (String -> String -> String) -> (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded],[SourceSyntax])
compileWithSourceSyntax canonical referenceUnit visible bits settings sources = do
  (units,properties,syntax,_) <- compileWithMigrationCapture canonical referenceUnit visible bits settings sources
  pure (units,properties,syntax)

compileWithMigrationCapture :: Bool -> (String -> String -> String) -> (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded],[SourceSyntax],Maybe SourceTemplates)
compileWithMigrationCapture = compileWithParserInventory True

compileWithParserInventory :: Bool -> Bool -> (String -> String -> String) -> (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded],[SourceSyntax],Maybe SourceTemplates)
compileWithParserInventory capture canonical referenceUnit visible bits settings sources = do
  unless (all (>0) [cases settings,maxAttempts settings,maxShrinks settings,exhaustiveLimit settings]) (Left [Diagnostic "generation" "generation limits must be positive integers" Nothing])
  unless (bits `elem` [32,64]) (Left [Diagnostic "machineBits" "machineBits must be 32 or 64" Nothing])
  -- Reserved Core identities belong to compiler-provided versioned sources.
  -- A user unit must not manufacture one when its built-in is not injected.
  when canonical $ forM_ sources $ \source -> case sourceUnit source of
    Right name | name `elem` ("prelude" : collectionsUnit : timeUnit : resilienceUnit : matchersUnit : resourcesUnit : networkUnit : builtinUnits) ->
      Left [Diagnostic "reserved-unit" ("the unit " ++ name ++ " is reserved for compiler-provided definitions") Nothing]
    _ -> pure ()
  -- Programs that use a collection get the built-in collections unit.
  -- Programs that use durations get the built-in time unit.
  -- Programs whose workflows use stateful policies get the resilience unit.
  -- Programs that import a built-in unit with abilities get it
  -- (LawSpec.Builtins); importing lawspec.time adds its clock. Their
  -- handlers with state use collections too.
  let discovery = if canonical then preludeDiscoveryText else id
      userTexts = [discovery text | Source _ text <- sources]
      providerUses uses text = uses text || (canonical && uses (preludeDependencyText text))
      clock = any usesClock [text | Source _ text <- sources]
      time = clock || any (providerUses usesTime) [text | Source _ text <- sources]
      resilience = any usesResilience [text | Source _ text <- sources]
      -- Programs that use matchers over lists, or regexes, get the matchers unit.
      matchers = any (providerUses usesMatchers) [text | Source _ text <- sources]
      -- Programs that name a built-in resource get the resources unit.
      resources = any usesResources [text | Source _ text <- sources]
      -- Built-in resources acquire and release through lawspec.host's
      -- abilities, so a program that names one gets that unit too.
      abilityUnits = [Source ("<" ++ unit ++ ">") (builtinSource unit) | unit <- builtinUnits
                     , any (importsBuiltin unit) [text | Source _ text <- sources] || (unit == "lawspec.host" && resources)] ++
        -- lawspec.network: the secure network handler's module (LawSpec.Network).
        [Source ("<" ++ networkUnit ++ ">") networkSource | any (importsBuiltin networkUnit) [text | Source _ text <- sources]]
      versionedCollectionSources = [text | Source _ text <- abilityUnits] ++ [clockSource | clock]
      collections = if canonical then usedCollectionsCanonical userTexts versionedCollectionSources
        else usedCollections ([text | Source _ text <- sources] ++ versionedCollectionSources)
      builtins = preludeSource : [Source "<lawspec.collections>" (collectionsSource collections) | not (null collections)] ++
        [Source "<lawspec.time>" (timeSource ++ (if clock then clockSource else "")) | time] ++ [Source "<lawspec.resilience>" resilienceSource | resilience] ++
        [Source "<lawspec.matchers>" matchersSource | matchers] ++
        [Source "<lawspec.resources>" resourcesSource | resources] ++
        abilityUnits
      implicit = [(timeUnit, timeAlias, timeTypes, providerUses usesTime) | time] ++
        [(resilienceUnit, resilienceAlias, resilienceTypes, usesResilience) | resilience] ++
        [(matchersUnit, matchersAlias, matchersTypes, providerUses usesMatchers) | matchers] ++
        [(resourcesUnit, resourcesAlias, resourcesTypes, usesResources) | resources] ++
        -- A unit that names a built-in resource imports lawspec.host, whose
        -- default handlers its resources run under.
        [("lawspec.host", "lawspecHost", [], \text -> usesResources text && not (importsBuiltin "lawspec.host" text)) | resources]
  (parsedUnits,sourceSyntax) <- if capture
    then parseSourcesWithBuiltinsAndSyntax canonical collections implicit builtins sources
    else (\units -> (units,[])) <$> parseSourcesWithBuiltins canonical collections implicit builtins sources
  unless (length parsedUnits == length (nub (map (unitName . fst) parsedUnits))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  documented <- resolveDocumentaryReferences referenceUnit visible parsedUnits
  let canonicalUnits = Set.fromList [name | source <- sources, Right name <- [sourceUnit source]]
  let sourceProfile name = canonical && name `Set.member` canonicalUnits
  (imported',sourceBindings) <- if capture then resolveImportsByProfileWithBindings sourceProfile visible documented
    else (\units -> (units,[])) <$> resolveImportsByProfile sourceProfile visible documented
  -- Abilities, handlers and rows, once each unit has what it imports.
  abled <- either (\(at, message) -> Left [Diagnostic "ability" message at]) Right (mapM elaborateAbilities imported')
  -- The harness, once every law has its final name.
  parsed <- either (\(at, message) -> Left [Diagnostic "harness" message at]) Right (mapM elaborateHarness abled)
  let imported = M.fromList [(unitName u ++ "::type::" ++ dataTypeName d, d{dataTypeConstructors=
        [c{dataConstructorName=unitName u ++ "::type::" ++ dataTypeName d ++ "::" ++ dataConstructorName c}
        | c <- dataTypeConstructors d]}) | u <- parsed, d <- dataTypes u]
  lowered <- either (Left . pure . (\m -> Diagnostic "refinement" m Nothing)) Right (mapM (lowerUnitWith imported) parsed)
  let beforeExpansion = map qualifyDataNames lowered
  (headers0,headerContext)<-dataDeclarationHeaders beforeExpansion
  -- Header slots are for type inference, not index or constructor proofs.
  let headers=[header{Core.dataIndex=Nothing} | header<-headers0]
  forM_ beforeExpansion $ \unit -> forM_ (fieldDefinitionChecks unit unit) $ \check -> do
    let rigid=mapType (\ty->case ty of Variable name->Named ('@':name); other->other) (mapExprTypes rigid)
        scope=M.union (monoEnvironment [(name,rigid (baseType ty)) | (name,ty)<-functionArguments check]) (definitionEnvironment unit)
    either (\reason->Left [Diagnostic "definition" ("field restriction: "++reason) (Just (spanStart (functionSpan check)))]) (const (Right ()))
      (typedExpressionWithSchemesContext headerContext headers bits scope (Annotate (mapExprTypes rigid (functionBody check)) (Named "Bool")))
  let us=map (inlineFieldDefinitions headerContext headers bits) beforeExpansion
  mapM_ checkRegexes us
  (nominalTypes,sourceTypes) <- elaborateDataDeclarationsWithContext bits us
  declaredRecords <- either (Left . pure . (\message -> Diagnostic "data-type" message Nothing)) Right
    (SourceRecords.recordDeclarationsWithContext sourceTypes nominalTypes bits (concatMap SourceRecords.unitTypeReferences us))
  let occurrences = if null declaredRecords then nominalTypes else nominalTypes ++ declaredRecords
  normalizedDeclarations <- normalizeProgramRecords (Core.Program bits occurrences [])
  let dataTypes=Core.programDataDeclarations normalizedDeclarations
  _ <- constructorProofContracts bits dataTypes
  let checkTypes = typeCheck sourceTypes dataTypes bits
  _ <- either (Left . pure . (\m -> Diagnostic "data-type" m Nothing)) Right (CoreTypes.makeRegistry dataTypes)
  unless (length us == length (nub (map unitName us))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  -- Each unit is validated, and each law expanded, under a key of exactly
  -- its inputs: a law's expansion depends on the law, the laws it invokes,
  -- its unit's signatures (not its definitions' bodies) and the data types,
  -- so editing a body or another unit's laws reuses it.
  let dataDigest = digestHex (digestString (show (dataTypes,sourceTypes)))
      key parts = digestHex (digestString parts)
  mapM_ (\u -> Memo.memoized validationTable (key (show ("unit", bits, dataDigest, u))) (validateUnit sourceTypes dataTypes bits u)) us
  checkedTemplates <- forM (zip beforeExpansion us) $ \(original,u) -> do
    let checks=fieldDefinitionChecks original u
        dependencies=fieldDefinitionDependencies original checks
        validationUnit=u{functionDefinitions=functionDefinitions u ++ checks}
        templateKey=key (show (bits,dataDigest,u,checks))
        fieldDiagnostics result=either (Left . map renderFieldDiagnostic) Right result
        renderFieldDiagnostic diagnostic=diagnostic{message=foldl label (message diagnostic) checks}
        label text check=case stripPrefix (functionName check ++ ": ") text of
          Just rest->"field restriction: " ++ rest
          Nothing->text
    templates <- fieldDiagnostics $ Memo.memoized definitionTemplatesTable templateKey
      (inferDefinitionTemplates sourceTypes dataTypes bits validationUnit)
    Memo.memoized validationTable (key (show ("totality-field-expansion",bits,dataDigest,u,checks,dependencies))) $ fieldDiagnostics $ do
      deferred<-auditTemplatesWithDeferrals sourceTypes dataTypes bits validationUnit
        (filter (\(definition,_,_,_)->functionName definition `notElem` orchestrations u) templates)
      forM_ dependencies $ \(name,range) ->
        when (any ((== Core.Id (unitName u ++ "::" ++ name)) . fst) deferred)
          (Left [Diagnostic "field-predicate" ("field predicate expansion cannot erase runtime postcondition enforcement for " ++ name) (Just (spanStart range))])
    let originalNames=map functionName (functionDefinitions u)
    pure (unitName u,filter (\(definition,_,_,_)->functionName definition `elem` originalNames) templates)
  let table = M.fromList [((unitName u,lawName l),l) | u <- us, l <- laws u]
      signatures u = [ (functionName d, functionArguments d, functionResult d, functionRequirements d) | d <- functionDefinitions u ]
      expansionKey u l = key (show (canonical, bits, settings, dataDigest, unitName u, functions u, signatures u, l, invokedLaws table l))
      typedChecked environment expression = do
        (tree, requirements) <- typedExpressionWithSchemesContext sourceTypes dataTypes bits environment expression
        forM_ requirements $ \requirement -> unless (satisfiedWithContext sourceTypes dataTypes bits [] requirement)
          (Left ("unsatisfied capability: " ++ show requirement))
        pure tree
  allExpanded <- forM [(u,l) | u <- us,l <- laws u] $ \(u,l) -> Memo.memoized expansionTable (expansionKey u l) $
    either (Left . pure . (\m -> Diagnostic "semantic" m (Just (location l)))) Right $ evalStateT (do
      let symbolic = not (null (parameters l))
          rigid (Variable n) = Named ("@" ++ n)
          rigid (Arrow a b) = Arrow (rigid a) (rigid b)
          rigid (Applied n t) = Applied n (rigid t)
          rigid (Application n ts) = Application n (map rigid ts)
          rigid t = if baseType t /= t then rigid (baseType t) else t
          -- A law's resources are values its body may use, like inputs it
          -- does not quantify over.
          env = M.union (monoEnvironment ([(n,rigid t) | (n,t) <- parameters l] ++ lawResources l)) (definitionEnvironment u)
      (bs0,body0,tr,argumentChecks0) <- (if canonical then expandCanonical else expand)
        (map functionName (functionDefinitions u)) table (unitName u) env [] l (map (Var . fst) (parameters l))
      bs <- mapM (\i -> do ps <- mapM resolveExpr (inputRefinements i); pure i{inputRefinements=ps}) bs0
      body <- resolveAssertion body0
      forM_ (assertionInputs body) $ \input -> do
        unless (valueType checkTypes (inputType input) || (symbolic && valueType checkTypes (abstractType (inputType input))))
          (throwC ("unsupported quantified type: " ++ show (inputType input)))
        when (not symbolic && not (concreteValue checkTypes (inputType input)))
          (throwC "executable logical binders must have a concrete value type")
      argumentChecks <- mapM resolveExpr argumentChecks0
      checkedInputs <- forM bs $ \v -> do
        t <- resolve (inputType v)
        unless (valueType checkTypes t || (symbolic && valueType checkTypes (abstractType t))) (throwC ("unsupported quantified type: " ++ show t))
        when (not symbolic && not (concreteValue checkTypes t)) (throwC "executable inputs must have a concrete value type")
        pure v{inputType=t}
      -- One recording holds one value, so a law that quantifies cannot
      -- compare with one; its examples can.
      when (not (null checkedInputs) && any (elem "prelude.recorded" . exprVars) (assertionExpressions body))
        (throwC "a recorded value is compared in an example, or in a law without `for all`: every input would need its own recording")
      os <- gets obligations >>= mapM (\(Capability c t) -> Capability c <$> resolve t)
      let allowed = [Capability c (rigid t) | Capability c t <- requirements l]
      forM_ os $ \c -> unless (satisfiedWithContext sourceTypes dataTypes bits allowed c) (throwC ("unsatisfied capability: " ++ show c))
      unless symbolic $ do
        lift (unique "expanded input name" (map inputName checkedInputs))
      -- Canonical tables retain all columns until reuse has expanded the law.
      -- Its authoritative inputs may belong to an imported requirement.
      let tableInputs ex
            | canonical && any (`isPrefixOf` exampleName ex) ["row ","table "] =
                ex { bindings = [(n,v) | (n,v) <- bindings ex, n `elem` map inputName checkedInputs] }
            | otherwise = ex
          sourceExamples = map tableInputs (examples l)
      forM_ sourceExamples $ \ex -> withContext ("example " ++ exampleName ex ++ ": ") $ do
        lift (unique "example binding" (map fst (bindings ex)))
        unless (M.keys (M.fromList (bindings ex)) == M.keys (M.fromList [(inputName v,()) | v <- checkedInputs])) (throwC ("example " ++ exampleName ex ++ " must bind exactly: " ++ intercalate ", " (map inputName checkedInputs)))
        forM_ (bindings ex) $ \(n,v) -> do
          case lookup n [(inputName inp,inputType inp) | inp <- checkedInputs] of
            Just expected -> checkExpr env expected (literalExpr v)
            Nothing -> throwC "unknown example input"
        let exampleEnv = M.union (monoEnvironment [(inputName inp,inputType inp) | inp <- checkedInputs]) env
        forM_ (expectations ex) $ \check -> do
          actualType <- infer exampleEnv (actual check) >>= resolve
          checkExpr env actualType (literalExpr (expected check))
      let (a,b,gs) = firstConclusion body
      let lawEnvironment = M.union (monoEnvironment [(inputId inp,inputType inp) | inp <- checkedInputs ++ assertionInputs body]) env
          expressionEnvironment = M.union (monoEnvironment [(inputName inp,inputType inp) | inp <- checkedInputs]) lawEnvironment
          lawEnv = environmentTypes lawEnvironment
      ir <- if symbolic then pure [] else lift ((++) <$> mapM (typedChecked lawEnvironment) (concatMap inputRefinements checkedInputs ++ assertionExpressions body) <*> mapM (typedChecked expressionEnvironment) [actual c | ex <- sourceExamples, c <- expectations ex])
      normalized <- if symbolic then pure sourceExamples else forM sourceExamples $ \ex -> do
        bs' <- forM (bindings ex) $ \(n,v) -> do
          t <- maybe (throwC "unknown example input") pure (lookup n [(inputName inp,inputType inp) | inp <- checkedInputs])
          value <- lift (normalizeLiteralWithContext sourceTypes dataTypes bits t v)
          pure (n,value)
        checks' <- forM (expectations ex) $ \c -> do
          t <- infer expressionEnvironment (actual c) >>= resolve
          value <- lift (normalizeLiteralWithContext sourceTypes dataTypes bits t (expected c))
          pure c{expected=value}
        pure ex{bindings=bs',expectations=checks'}
      let resolvedInputs = [inp{inputRefinements=map (mapExprTypes resolveKnown) (inputRefinements inp)} | inp <- checkedInputs]
          resolveKnown t = t
      pure (Expanded (unitName u) (lawName l) resolvedInputs a b gs body tr l{examples=normalized} ir (if take 9 (lawName l) == "contract " then "contract" else "law") settings (map (planDomain [(inputId i,inputType i) | i <- resolvedInputs]) resolvedInputs) argumentChecks (if canonical then UniversalDomain else NonemptyDomain))
      ) (withSourceContext sourceTypes (withDataDeclarations dataTypes (initialState bits)))
  mapM_ (validateContracts sourceTypes dataTypes bits) us
  witnessed <- prepareHarnessWitnesses (filter ((/= "prelude") . unitName) us)
    (filter (null . parameters . original) allExpanded)
  (specialized, properties) <- specializeDefinitionsWithContext sourceTypes dataTypes bits (satisfiedWithContext sourceTypes dataTypes bits [])
    witnessed (filter (null . parameters . original) allExpanded)
  collectedUnits <- either (Left . pure . (\message -> Diagnostic "definition" message Nothing)) Right
    (mapM (Elaboration.elaborateDefinitionUnitWithSourceRecords sourceTypes dataTypes bits) specialized)
  propertyRecords <- either (Left . pure . (\message -> Diagnostic "data-type" message Nothing)) Right
    (SourceRecords.recordDeclarationsWithContext sourceTypes dataTypes bits
      (concatMap (concatMap SourceRecords.typedTypeReferences . typedExpressions) properties))
  let collectedRecords = concatMap snd collectedUnits ++ propertyRecords
      closedDataTypes = if null collectedRecords then dataTypes else dataTypes ++ collectedRecords
  normalizedProgram <- normalizeProgramRecords (Core.Program bits closedDataTypes (map fst collectedUnits))
  closedProgram <- deferProgramPostconditions normalizedProgram
  invoke <- prepareDefinitions closedProgram
  registry <- either (Left . pure . (\m -> Diagnostic "data-type" m Nothing)) Right (CoreTypes.makeRegistry (Core.programDataDeclarations closedProgram))
  forM_ properties $ \property -> do
    u <- maybe (Left [Diagnostic "semantic" "missing property owner" Nothing]) Right
      (lookup (owner property) [(unitName u,u) | u <- specialized])
    either (Left . pure . (\message -> Diagnostic "semantic" message (Just (location (original property))))) Right $
      evalStateT (do
        let identify name = Core.Id (unitName u ++ "::" ++ name)
        forM_ (refinementArgumentChecks property) $ \check -> do
          (term,known) <- lift (evaluationTerm sourceTypes closedDataTypes (map (identify . fst) (functions u))
            bits (Core.Id (name property)) identify (functions u) check)
          value <- lift (CoreEval.evaluateValue known bits invoke [] term)
          unless (value == CoreValue.ScalarValue (SBool True)) (throwC "refinement value argument violates its declared parameter type")
        mapM_ (validateExampleDomains bits u invoke (inputs property)) (examples (original property)))
        (withSourceContext sourceTypes (withDataDeclarations closedDataTypes (initialState bits)))
  -- Ability inference stores only nonempty rows. A known source definition
  -- absent from that sparse table is pure; an unknown declaration is not.
  let sourceRows = [(unitName u,[(functionName d,maybe [] id (lookup (functionName d) (abilityRows u)))
                        | d <- functionDefinitions u]) | u <- us]
      annotate syntax = let (bindings,references)=maybe ([],[]) id (lookup (syntaxUnit syntax) sourceBindings)
        in syntax{syntaxNodes=map (node (syntaxUnit syntax)) (syntaxNodes syntax),syntaxBindings=bindings,
          syntaxReferences=[reference | reference <- references,let Span start end=referenceSpan reference,
            file start==syntaxPath syntax,file end==syntaxPath syntax]}
      node owner item
        | syntaxKind item == "declaration.definition", Just name <- syntaxName item,
          Just used <- lookup owner sourceRows >>= lookup name = item{syntaxUses=Just (map prettyType used)}
        | otherwise = item
  pure (specialized, properties,
    [annotate syntax | syntax <- sourceSyntax,syntaxPath syntax `elem` [path | Source path _ <- sources]],
    if capture then Just (SourceTemplates bits us checkedTemplates allExpanded dataTypes
      [(identity,Source.sourceFields constructor,Source.sourceEquations constructor) |
        (identity,constructor)<-migrationConstructorSources us dataTypes]) else Nothing)

-- | The laws a law invokes, transitively: every law whose name ends one of the
-- names it invokes, a superset of the ones expansion resolves.
invokedLaws :: M.Map (String,String) Law -> Law -> [Law]
invokedLaws table root = go Set.empty (invoked (definition root))
  where
    go _ [] = []
    go seen (n : rest)
      | Set.member n seen = go seen rest
      | otherwise =
          let found = [ l | ((owner, name), l) <- M.toList table,
                name `isSuffixOf` n || (owner == "prelude" && name == preludeLawName n) ]
          in found ++ go (Set.insert n seen) (concatMap (invoked . definition) found ++ rest)
    invoked d = case d of
      Forall _ body -> invoked body
      Exists _ body -> invoked body
      Not body -> invoked body
      Implies _ body -> invoked body
      And a b -> invoked a ++ invoked b
      Invoke n _ -> [n]
      _ -> []

expansionTable :: Memo.Table (Either [Diagnostic] Expanded)
expansionTable = unsafePerformIO (Memo.newPersistentTable "expand" 4096 (const 1))
{-# NOINLINE expansionTable #-}

validationTable :: Memo.Table (Either [Diagnostic] ())
validationTable = unsafePerformIO (Memo.newPersistentTable "validate" 4096 (const 1))
{-# NOINLINE validationTable #-}

definitionTemplatesTable :: Memo.Table (Either [Diagnostic] [DefinitionTemplate])
definitionTemplatesTable = unsafePerformIO (Memo.newPersistentTable "definition-templates" (32*1024) weight)
  where
    weight (Left _) = 1
    weight (Right values) = 1 + sum [sum (map nodes (body:pre ++ post)) | (_,body,pre,post)<-values]
    nodes value = 1 + sum (map nodes (operands value)) + sum [nodes body | TypedCase _ _ body<-typedCases value]
{-# NOINLINE definitionTemplatesTable #-}

-- | Diagnostics and evidence quote a law as the quantified statement that is
-- actually tested, so a reader sees what a failure refers to.
prettyExpanded :: Expanded -> String
prettyExpanded e | propertyKind e == "contract" = description (original e)
prettyExpanded e = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ (if null (inputRefinements i) then "" else " where " ++ intercalate " && " (map showExpr (inputRefinements i))) ++ ")" | i <- inputs e] ++ " . " ++ showAssertion (assertion e)
  where names = M.fromList [(inputId i,Var (inputName i)) | i <- inputs e ++ assertionInputs (assertion e)]
        showExpr = prettyExpr . subst names
        showAssertion (AssertEqual a b) = showExpr a ++ " = " ++ showExpr b
        showAssertion (AssertImplies g a) = showExpr g ++ " implies " ++ showAssertion a
        showAssertion (AssertAll as) = intercalate " and " ["(" ++ showAssertion a ++ ")" | a <- as]
        showAssertion (AssertNot body) = "not (" ++ showAssertion body ++ ")"
        showAssertion (AssertQuantified kind input body) =
          (if kind == ForEvery then "for all " else "there exists ") ++ "(" ++ inputName input ++ " :: " ++
          prettyType (inputType input) ++ (if null (inputRefinements input) then "" else " where " ++
            intercalate " and " (map showExpr (inputRefinements input))) ++ ") " ++
          (if kind == ForEvery then "=> " else "such that ") ++ showAssertion body ++ " end"

-- | Braced references are checked against the law's lexical function environment.
metadataText :: [String] -> String -> Either String String
metadataText known = go
  where
    go [] = Right []
    go ('{':'{':rest) = ('{':) <$> go rest
    go ('}':'}':rest) = ('}':) <$> go rest
    go ('{':rest) = case break (== '}') rest of
      (n,'}':tail') | n `elem` known -> (n ++) <$> go tail'
      _ -> Left "unknown or unclosed metadata reference"
    go ('}':_) = Left "unmatched metadata brace; use }} for a literal brace"
    go (c:rest) = (c:) <$> go rest

assertionExpressions :: Assertion -> [Expr]
assertionExpressions (AssertEqual a b) = [a,b]
assertionExpressions (AssertImplies g body) = g:assertionExpressions body
assertionExpressions (AssertAll as) = concatMap assertionExpressions as
assertionExpressions (AssertNot body) = assertionExpressions body
assertionExpressions (AssertQuantified _ input body) = inputRefinements input ++ assertionExpressions body
normalizeLiteralWithContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Type -> Literal -> Either String Literal
normalizeLiteralWithContext sourceTypes dataTypes bits t (ConstructorLiteral name fields) = do
  parameters <- evalStateT (constructorParameters t name) (withSourceContext sourceTypes (withDataDeclarations dataTypes (initialState bits)))
  unless (length parameters == length fields) (Left ("wrong constructor arity: " ++ name))
  ConstructorLiteral name <$> sequence [normalizeLiteralWithContext sourceTypes dataTypes bits parameter field | (parameter, field) <- zip parameters fields]
normalizeLiteralWithContext sourceTypes dataTypes bits (Applied "List" element) (ListLiteral xs) = ListLiteral <$> mapM (normalizeLiteralWithContext sourceTypes dataTypes bits element) xs
normalizeLiteralWithContext _ _ _ _ (ListLiteral _) = Left "list literal requires a List type"
normalizeLiteralWithContext sourceTypes dataTypes bits ty (SetLiteral builder items) = case baseType ty of
  Applied "lawspec.collections::type::EqSet" element ->
    SetLiteral builder <$> mapM (normalizeLiteralWithContext sourceTypes dataTypes bits element) items
  _ -> Left "a set literal requires the canonical Set type"
normalizeLiteralWithContext sourceTypes dataTypes bits t (RecordLiteral fields) = case baseType t of
  Record expected -> do
    let labels=map fst fields
        declared=map recordFieldLabel expected
    unless (length labels == length (nub labels)) (Left "duplicate record literal field")
    unless (length labels == length declared && all (`elem` declared) labels)
      (Left "a record literal must supply exactly its declared fields")
    RecordLiteral <$> forM fields (\(label,value) -> do
      ty <- maybe (Left ("unknown record literal field: " ++ label)) Right
        (lookup label [(recordFieldLabel field,recordFieldType field) | field <- expected])
      (,) label <$> normalizeLiteralWithContext sourceTypes dataTypes bits (baseType ty) value)
  _ -> Left "record literal requires a structural record type"
normalizeLiteralWithContext _ _ bits t v = do
  value <- case v of
    DecimalLiteral c e -> Right (SDecimal c e)
    IntLiteral n -> Right (SInteger "BigInt" n)
    TextLiteral text -> Right (textScalar text)
    BoolLiteral value -> Right (SBool value)
    ScalarLiteral scalar -> Right scalar
  ScalarLiteral <$> normalize t value
  where
    normalize (Named n) s = convertScalar bits n s
    normalize (Applied n _) (SAbsent a) | (n,a) `elem` [("Nullable","Null"),("Optional","Undefined")] = Right (SPresent n Nothing)
    normalize (Applied n _) (SPresent m Nothing) | n == m = Right (SPresent n Nothing)
    normalize (Applied n inner) (SPresent m (Just x)) | n == m = SPresent n . Just <$> normalize inner x
    normalize _ _ = Left "invalid contextual literal"

checkPredicate :: [String] -> Env -> Expr -> C ()
checkPredicate definitions env e = do
  let names = exprVars e
  forM_ names $ \n -> when (take 8 n /= "prelude." && n `notElem` definitions && maybe False (isFunction . schemeType) (M.lookup n env)) (throwC "adapter calls are forbidden in refinement predicates")
  checkExpr env (Named "Bool") e
  where isFunction (Arrow _ _) = True
        isFunction _ = False

validateContracts :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
validateContracts sourceTypes dataTypes bits u = either (Left . pure . (\m -> Diagnostic "contract" m Nothing)) Right $ forM_ (contracts u) $ \c -> evalStateT (do
  _ <- foldM (\env (n,t) -> do
    let env' = M.insert n (Monomorphic (baseType t)) env
    mapM_ (checkPredicate (map functionName (functionDefinitions u)) env') (typePredicates (Var n) t)
    mapM_ (\(Capability k ty) -> require k ty) (typeConstraints t)
    pure env') (definitionEnvironment u) (contractArguments c)
  let env = M.union (monoEnvironment [(n,baseType t) | (n,t) <- contractArguments c ++ [contractResult c]]) (definitionEnvironment u)
  mapM_ (checkPredicate (map functionName (functionDefinitions u)) env) (contractPostconditions c)
  mapM_ (\(Capability k ty) -> require k ty) (typeConstraints (snd (contractResult c)))
  os <- gets obligations >>= mapM (\(Capability name ty) -> Capability name <$> resolve ty)
  forM_ os $ \o -> unless (satisfiedWithContext sourceTypes dataTypes bits [] o) (throwC ("unsatisfied contract capability: " ++ show o))
  ) (withSourceContext sourceTypes (withDataDeclarations dataTypes (initialState bits)))

validateExampleDomains :: Int -> Unit -> (Core.Id -> [CoreValue.Value] -> Either String CoreValue.Value) -> [Input] -> Example -> C ()
validateExampleDomains bits unit invoke ins ex = withContext ("example " ++ exampleName ex ++ ": ") $ do
  dataTypes <- gets dataDeclarations
  sourceTypes <- gets sourceContext
  registry <- lift (CoreTypes.makeRegistry dataTypes)
  let origin = Core.Id ("example::" ++ exampleName ex)
      identify name = Core.Id (unitName unit ++ "::" ++ name)
      resolve name = if name `elem` map inputId ins then Core.Id name else identify name
      env = functions unit ++ [(inputId input,inputType input) | input <- ins]
      lower = evaluationTerm sourceTypes dataTypes (map (identify . fst) (functions unit)) bits origin resolve env
  values <- forM ins $ \input -> do
    literal <- maybe (throwC "missing example input") pure (lookup (inputName input) (bindings ex))
    (term,known) <- lift (lower (Annotate (literalExpr literal) (inputType input)))
    value <- lift (CoreEval.evaluateValue known bits invoke [] term)
    pure (Core.Id (inputId input), value)
  forM_ (concatMap inputRefinements ins) $ \predicate -> do
    (term,known) <- lift (lower predicate)
    value <- lift (CoreEval.evaluateValue known bits invoke values term)
    unless (value == CoreValue.ScalarValue (SBool True))
      (throwC ("example violates refinement: " ++ prettyExpr predicate))

-- A standalone validation term may introduce products that are absent from
-- implementation signatures. Audit its occurrence stream before using a shared
-- lookup registry; final program elaboration retains its own source occurrences.
evaluationTerm sourceTypes declarations functions bits origin resolve env source = do
  (term,records) <- Elaboration.elaborateResolvedWithSourceRecords sourceTypes False declarations functions bits origin resolve env source
  let known = if null records then declarations else declarations ++ records
  (normalized,complete) <- either (Left . unlines . map message) Right (normalizeExpressionRecords bits known term)
  _ <- either (Left . unlines . map message) Right (constructorProofContracts bits complete)
  registry <- CoreTypes.makeRegistry complete
  pure (normalized,registry)

resolveExpr :: Expr -> C Expr
resolveExpr (Located range e) = Located range <$> resolveExpr e
resolveExpr (ConstructLit name fields) = ConstructLit name <$> mapM resolveExpr fields
resolveExpr (RecordLit fields) = RecordLit <$> mapM (\(label,value) -> (,) label <$> resolveExpr value) fields
resolveExpr (AllPayloadsExpr value predicates) = AllPayloadsExpr <$> resolveExpr value <*> mapM (\(binder,body) -> (,) binder <$> resolveExpr body) predicates
resolveExpr (AllElementsExpr value binder predicate) = AllElementsExpr <$> resolveExpr value <*> pure binder <*> resolveExpr predicate
resolveExpr (MatchExpr value branches) = MatchExpr <$> resolveExpr value <*> mapM
  (\(MatchBranch tag names body) -> MatchBranch tag names <$> resolveExpr body) branches
resolveExpr (ListLit xs) = ListLit <$> mapM resolveExpr xs
resolveExpr (TypeBound b t) = TypeBound b <$> resolve t
resolveExpr (Annotate e t) = Annotate <$> resolveExpr e <*> resolve t
resolveExpr (Apply a b) = Apply <$> resolveExpr a <*> resolveExpr b
resolveExpr (Compose a b) = Compose <$> resolveExpr a <*> resolveExpr b
resolveExpr (Binary op a b) = Binary op <$> resolveExpr a <*> resolveExpr b
resolveExpr (Unary op a) = Unary op <$> resolveExpr a
resolveExpr e = pure e
resolveAssertion :: Assertion -> C Assertion
resolveAssertion (AssertEqual a b) = AssertEqual <$> resolveExpr a <*> resolveExpr b
resolveAssertion (AssertImplies a b) = AssertImplies <$> resolveExpr a <*> resolveAssertion b
resolveAssertion (AssertAll xs) = AssertAll <$> mapM resolveAssertion xs
resolveAssertion (AssertNot body) = AssertNot <$> resolveAssertion body
resolveAssertion (AssertQuantified kind input body) = do
  ty <- resolve (inputType input)
  predicates <- mapM resolveExpr (inputRefinements input)
  AssertQuantified kind (input { inputType = ty, inputRefinements = predicates }) <$> resolveAssertion body


abstractType :: Type -> Type
abstractType = mapType (\t -> case t of Named n@('@':_) -> Variable n; _ -> t) id

-- | Whether a type is valid given the data types: the registry is built once
-- for every type a caller checks with the same function, which matters for a
-- program of thousands of types.
typeCheck :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Type -> Bool
typeCheck sourceTypes declarations bits = case CoreTypes.makeRegistry declarations of
  Left _ -> const False
  Right registry -> \t -> either (const False) (const True) $ do
    (ty,records) <- Elaboration.coreTypeWithSourceRecords sourceTypes declarations bits t
    if null records then CoreTypes.checkType registry ty else do
      extended <- CoreTypes.makeRegistry (declarations ++ records)
      CoreTypes.checkType extended ty

validTypeWithData :: (Type -> Bool) -> Type -> Bool
validTypeWithData check t = check t

valueType :: (Type -> Bool) -> Type -> Bool
valueType _ (Arrow _ _) = False
valueType check t = validTypeWithData check t

concreteValue :: (Type -> Bool) -> Type -> Bool
concreteValue check t = valueType check t && concrete (baseType t)
  where
    concrete (Variable _) = False
    concrete (Named ('@':_)) = False
    concrete (Applied _ a) = concrete a
    concrete (Application _ args) = all concrete args
    concrete (Record fields) = all (concrete . recordFieldType) fields
    concrete (Arrow a b) = concrete a && concrete b
    concrete _ = True

-- | This is the type/capability audit, not the totality proof. Concrete bodies
-- still pass Core.Total; generic bodies must pass termination/definedness and
-- closed-call specialization before the frontend can enable them for execution.
validateDefinitionTypes :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
validateDefinitionTypes declarations bits unit = () <$ inferDefinitionTemplates Source.emptyContext declarations bits unit

-- | A checked definition is executed by every target's tests, so it must be
-- proved total before emission; orchestrations call adapters and are exempt.
-- ref:DEC-total-definitions
validateDefinitionTotality :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
-- An orchestration's body is type-checked like any definition, but calls
-- adapters, so only the others are proved total.
validateDefinitionTotality = validateDefinitionTotalityWithContext Source.emptyContext

validateDefinitionTotalityWithContext sourceTypes declarations bits unit =
  inferDefinitionTemplates sourceTypes declarations bits unit >>= auditDefinitionTemplates sourceTypes declarations bits unit

auditDefinitionTemplates sourceTypes declarations bits unit = auditTemplatesWithContext sourceTypes declarations bits unit
  . filter (\(d, _, _, _) -> functionName d `notElem` orchestrations unit)

inferDefinitionTemplates :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] [(FunctionDefinition, TypedExpr, [TypedExpr], [TypedExpr])]
inferDefinitionTemplates sourceTypes declarations bits unit = do
  unless (bits `elem` [32,64]) (Left [Diagnostic "machineBits" "machineBits must be 32 or 64" Nothing])
  mapM validate (functionDefinitions unit)
  where
    checkTypes = typeCheck sourceTypes declarations bits
    signature d = foldr Arrow (functionResult d) (map snd (functionArguments d))
    globals = M.union
      (M.fromList [(functionName d, Universal (variables (signature d))
        (functionRequirements d) (signature d)) | d <- functionDefinitions unit])
      (monoEnvironment (functions unit))
    rigid = mapType (\ty -> case ty of Variable name -> Named ("@" ++ name); _ -> ty)
      (mapExprTypes rigid)
    validate d = either (Left . pure . (\message -> Diagnostic "definition"
      (functionName d ++ ": " ++ message) (Just (spanStart (functionSpan d))))) Right $ do
      let parameters = functionArguments d
          bound = variables (signature d)
          declared = functionRequirements d
          allowed = [Capability name (rigid ty) | Capability name ty <- declared]
          locals = monoEnvironment [(name, rigid ty) | (name,ty) <- parameters]
          -- Signatures are mandatory, so recursion may be polymorphic: a GADT
          -- evaluator calls itself at other type arguments. Locals have normal
          -- lexical precedence.
          environment = M.union locals globals
      unique "definition argument" (map fst parameters)
      unless (all (valueType checkTypes) (functionResult d : map snd parameters))
        (Left "definition parameters and result require value types")
      forM_ declared $ \(Capability name ty) -> do
        unless (name `elem` ["Eq","Integer","Ordered","Bounded","Keyed"])
          (Left ("unknown capability: " ++ name))
        unless (valueType checkTypes ty && all (`elem` bound) (variables ty))
          (Left "capability mentions an invalid or unbound type")
        when (null (variables ty) && not (satisfiedWithContext sourceTypes declarations bits [] (Capability name ty)))
          (Left ("unsatisfied definition capability: " ++ show (Capability name ty)))
      unless (all (`elem` bound) (concatMap variables (annotations (functionBody d))))
        (Left "body annotation mentions an unbound type variable")
      (body, obligations) <- typedExpressionWithSchemesContext sourceTypes declarations bits environment
        (Annotate (normal (mapExprTypes rigid (functionBody d))) (rigid (baseType (functionResult d))))
      contract <- definitionContractFor d
      let predicate scope expression = do
            (tree, constraints) <- typedExpressionWithSchemesContext sourceTypes declarations bits scope
              (Annotate (normal (mapExprTypes rigid expression)) (Named "Bool"))
            pure (tree,constraints)
          globalScope = globals
      (_, preconditions, preObligations) <- foldM (\(scope,trees,constraints) (name,ty) -> do
        let next = M.insert name (Monomorphic (rigid (baseType ty))) scope
        predicates <- mapM (predicate next) (typePredicates (Var name) ty)
        pure (next,trees ++ map fst predicates,constraints ++ concatMap snd predicates))
        (globalScope,[],[]) parameters
      let (resultName,resultType) = contractResult contract
          resultScope = M.insert resultName (Monomorphic (rigid (baseType resultType))) environment
      postconditions <- mapM (predicate resultScope) (contractPostconditions contract)
      let domainObligations = [Capability name (rigid ty) |
            value <- functionResult d : map snd parameters,
            Capability name ty <- typeConstraints value]
      forM_ (obligations ++ preObligations ++ concatMap snd postconditions ++ domainObligations) $ \obligation ->
        unless (satisfiedWithContext sourceTypes declarations bits allowed obligation)
          (Left ("unsatisfied definition capability: " ++ show obligation))
      pure (d, body, preconditions, map fst postconditions)
    variables ty = nub $ case baseType ty of
      Variable name -> [name]
      Arrow a b -> variables a ++ variables b
      Applied _ a -> variables a
      Application _ arguments -> concatMap variables arguments
      Record fields -> concatMap (variables . recordFieldType) fields
      _ -> []
    annotations expression = case expression of
      Located _ body -> annotations body
      Annotate body ty -> ty : annotations body
      TypeBound _ ty -> [ty]
      Apply f x -> annotations f ++ annotations x
      Compose f g -> annotations f ++ annotations g
      Binary _ a b -> annotations a ++ annotations b
      Unary _ body -> annotations body
      ConstructLit _ fields -> concatMap annotations fields
      RecordLit fields -> concatMap (annotations . snd) fields
      ListLit fields -> concatMap annotations fields
      AllPayloadsExpr value predicates -> annotations value ++ concatMap (annotations . snd) predicates
      AllElementsExpr value _ predicate -> annotations value ++ annotations predicate
      MatchExpr value branches -> annotations value ++ concat
        [annotations body | MatchBranch _ _ body <- branches]
      _ -> []
