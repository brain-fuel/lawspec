module LawSpec.Compile (compile, prettyExpanded, metadataText, normal, compileWithProfile, typedExpression, validType, compileWithSettings, compileWithImports, validateDefinitionTypes, validateDefinitionTotality) where

import LawSpec.Core.Total (deferProgramPostconditions)
import LawSpec.Model
import LawSpec.Data (qualifyDataNames, elaborateDataDeclarationsWithProfile)
import LawSpec.Capabilities (satisfiedWithData)
import LawSpec.Inference
import LawSpec.DefinitionTotality (auditTemplates)
import LawSpec.SpecializeDefinitions (specializeDefinitions)
import qualified LawSpec.Elaboration as Elaboration
import qualified LawSpec.Core as Core
import qualified LawSpec.Core.Eval as CoreEval
import LawSpec.Core.Definitions (prepareDefinitions)
import qualified LawSpec.Core.Types as CoreTypes
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Scalar
import LawSpec.Parser
import LawSpec.Imports (resolveImports)
import LawSpec.Abilities (elaborateAbilities)
import LawSpec.Collections (usedCollections, collectionsSource)
import LawSpec.Time (timeUnit, timeAlias, timeTypes, usesTime, timeSource)
import LawSpec.Matchers (matchersUnit, matchersAlias, matchersTypes, usesMatchers, matchersSource, regexTypeName)
import LawSpec.Regex (parseRegex)
import LawSpec.Resources (resourcesUnit, resourcesAlias, resourcesTypes, usesResources, resourcesSource)
import LawSpec.Resilience (resilienceUnit, resilienceAlias, resilienceTypes, usesResilience, resilienceSource)
import LawSpec.Refinement
import LawSpec.Prelude
import Control.Monad.State.Strict
import Control.Monad (unless, when, zipWithM_, forM, forM_, foldM)
import qualified Data.Map.Strict as M
import Data.List (nub, intercalate, uncons)
import Data.Char (isLower)
import Data.List (isSuffixOf, isPrefixOf, isInfixOf)
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
subst m (Located range e) = Located range (subst m e)
subst m (ConstructLit name fields) = ConstructLit name (map (subst m) fields)
subst m e@(AllPayloadsExpr _ _) = replaceExprVars (M.toList m) e
subst m e@(AllElementsExpr _ _ _) = replaceExprVars (M.toList m) e
subst m e@(MatchExpr _ _) = replaceExprVars (M.toList m) e
subst m (ListLit xs) = ListLit (map (subst m) xs)
subst m (Var n) = M.findWithDefault (Var n) n m
subst m (Apply f x) = Apply (subst m f) (subst m x)
subst m (Compose f g) = Compose (subst m f) (subst m g)
subst m (Binary op a b) = Binary op (subst m a) (subst m b)
subst m (Unary op a) = Unary op (subst m a)
subst m (Annotate a t) = Annotate (subst m a) t
subst _ e = e
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
expand :: [String] -> Table -> String -> Env -> [String] -> Law -> [Expr] -> C ([Input], Assertion, [String], [Expr])
expand definitions table unit env stack law args = do
  let key = unit ++ "::" ++ lawName law
  when (key `elem` stack) (throwC ("recursive law expansion: " ++ intercalate " -> " (reverse (key:stack))))
  unless (length args == length (parameters law)) (throwC ("wrong argument count for law " ++ lawName law))
  p <- fresh
  let rt = rename p
  zipWithM_ (\(_,t) arg -> checkExpr env (rt t) arg) (parameters law) args
  modify (\s -> s{obligations=map (renameConstraint p) (requirements law) ++ obligations s})
  let replacements = M.fromList (zip (map fst (parameters law)) args)
      walk e m (Forall qs d) = do
        (bs,e',m',checks) <- foldM (\(bs,scope,replacements',checks) (n,t) -> do
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
              registry <- lift (CoreTypes.makeRegistry dataTypes)
              term <- lift (Elaboration.elaborateResolvedWithData dataTypes [] bits (Core.Id key) Core.Id (environmentTypes scope') check)
              value <- lift (CoreEval.evaluateValuePure registry bits [] term)
              unless (value == CoreValue.ScalarValue (SBool True)) (throwC "refinement value argument violates its declared parameter type")
          mapM_ (\(Capability c ty) -> resolve ty >>= require c) (typeConstraints renamed)
          pure (bs ++ [Input n i t' predicates],scope',M.insert n (Var i) replacements',
            checks ++ filter (closedCheck definitions) (map (normal . subst replacements') (argumentChecks renamed)))) ([],e,m,[]) qs
        (rest,body,tr,more) <- walk e' m' d
        pure (bs++rest,body,tr,checks++more)
      walk e m (Equal a b) = do
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
      walk e m (Holds a) = walk e m (Equal a (BoolLit True))
      walk e m (Implies condition consequence) = do
        let guard = normal (subst m (mapExprTypes rt condition))
        infer e guard >>= unify (Named "Bool")
        (bs,body,tr,checks) <- walk e m consequence
        pure (bs,AssertImplies guard body,tr,checks)
      walk e m (And a b) = do
        (as,a',at,ac) <- walk e m a
        (bs,b',bt,bc) <- walk e m b
        pure (as++bs,AssertAll [a',b'],at++bt,ac++bc)
      walk e m (Invoke n as) = do
        (u,called) <- case M.lookup (unit,n) table of
          Just v -> pure (unit,v)
          Nothing -> maybe (throwC ("unknown law: " ++ n)) (pure . (,) "prelude") (M.lookup ("prelude",n) table)
        expand definitions table u e (key:stack) called (map (subst m) as)
  (bs,body,tr,checks) <- walk env replacements (definition law)
  pure (bs,body,(lawName law ++ concatMap ((" "++) . prettyExpr) args):tr,checks)

unique :: String -> [String] -> Either String ()
unique kind xs = unless (length xs == length (nub xs)) (Left ("duplicate " ++ kind))
validType :: Type -> Bool
validType (Named n) = maybe False (const True) (primitive n)
validType (Applied n t) = n `elem` ["Nullable","Optional","List","Maybe"] && scalar t
validType (Application "Either" [a,b]) = scalar a && scalar b
validType (Variable _) = True
validType (Arrow a b) = validType a && validType b
validType (Refined _ t _) = validType t
validType (Qualified _ t) = validType t
validType (CheckedType _ t) = validType t
validType _ = False
scalar :: Type -> Bool
scalar (Arrow _ _) = False
scalar t = validType t
validateUnit :: [Core.DataDeclaration] -> Unit -> Either [Diagnostic] ()
validateUnit dataTypes u = either (Left . pure . (\m -> Diagnostic "declaration" m Nothing)) Right $ do
  unique "constructor" [dataConstructorName c | d <- LawSpec.Model.dataTypes u, c <- dataTypeConstructors d]
  unique "function" (map fst (functions u)); unique "law" (map lawName (laws u))
  forM_ (functions u) $ \(n,t) -> do
    unless (maybe False (isLower . fst) (uncons n)) (Left "function names must start with a lowercase letter")
    let (args,result) = functionType t
    -- An ability operation may take no values (now :: Instant).
    if n `elem` operationNames u
      -- (A parameterized ability's parameters are instantiated at each use.)
      then unless (all (concreteValue dataTypes . mapType (\x -> case x of
          Variable v | "ability:" `isPrefixOf` v -> Named "Int32"
          _ -> x) id) (result:args))
        (Left (n ++ ": an ability operation takes and gives concrete values"))
      else unless (not (null args) && all (if n `elem` map functionName (functionDefinitions u) then valueType dataTypes else concreteValue dataTypes) (result:args))
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
      unless (all (valueType dataTypes) (result:args)) (Left "law parameters must be values or curried functions between value types")
    unless (all (\(Capability _ t) -> valueType dataTypes t) (requirements l)) (Left "capability requires a value type")
    unless (all (validTypeWithData dataTypes . snd) (parameters l) && all (\(Capability _ t) -> validTypeWithData dataTypes t) (requirements l)) (Left "unsupported type")

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
        Equal a b -> [a, b]
        Holds a -> [a]
        Implies a body -> a : definitionExprs body
        And a b -> definitionExprs a ++ definitionExprs b
        Invoke _ args -> args
      quantified d = case d of
        Forall qs body -> qs ++ quantified body
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
      MatchExpr v branches -> v : [b | MatchBranch _ _ b <- branches]
      AllElementsExpr v _ p -> [v, p]
      AllPayloadsExpr v ps -> v : map snd ps
      Binary _ a b -> [a, b]
      Unary _ a -> [a]
      Annotate a _ -> [a]
      _ -> []

compile :: [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compile = compileWithProfile 64

compileWithProfile :: Int -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithProfile bits = compileWithSettings bits defaultGeneration

compileWithSettings :: Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithSettings = compileWithImports (\_ _ -> Nothing)

-- visible importer imported explains why a unit may not import another
-- (package boundaries), or is Nothing when it may.
compileWithImports :: (String -> String -> Maybe String) -> Int -> Generation -> [Source] -> Either [Diagnostic] ([Unit],[Expanded])
compileWithImports visible bits settings sources = do
  unless (all (>0) [cases settings,maxAttempts settings,maxShrinks settings,exhaustiveLimit settings]) (Left [Diagnostic "generation" "generation limits must be positive integers" Nothing])
  unless (bits `elem` [32,64]) (Left [Diagnostic "machineBits" "machineBits must be 32 or 64" Nothing])
  -- Programs that use a collection get the built-in collections unit.
  -- Programs that use durations get the built-in time unit.
  let collections = usedCollections [text | Source _ text <- sources]
      -- Programs whose workflows use stateful policies get the resilience unit.
      time = any usesTime [text | Source _ text <- sources]
      resilience = any usesResilience [text | Source _ text <- sources]
      -- Programs that use matchers over lists, or regexes, get the matchers unit.
      matchers = any usesMatchers [text | Source _ text <- sources]
      -- Programs that name a built-in resource get the resources unit.
      resources = any usesResources [text | Source _ text <- sources]
      builtins = preludeSource : [Source "<lawspec.collections>" (collectionsSource collections) | not (null collections)] ++
        [Source "<lawspec.time>" timeSource | time] ++ [Source "<lawspec.resilience>" resilienceSource | resilience] ++
        [Source "<lawspec.matchers>" matchersSource | matchers] ++
        [Source "<lawspec.resources>" resourcesSource | resources]
      implicit = [(timeUnit, timeAlias, timeTypes, usesTime) | time] ++
        [(resilienceUnit, resilienceAlias, resilienceTypes, usesResilience) | resilience] ++
        [(matchersUnit, matchersAlias, matchersTypes, usesMatchers) | matchers] ++
        [(resourcesUnit, resourcesAlias, resourcesTypes, usesResources) | resources]
  parsedUnits <- parseSourcesWith collections implicit (builtins ++ sources)
  unless (length parsedUnits == length (nub (map (unitName . fst) parsedUnits))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  imported' <- resolveImports visible parsedUnits
  -- Abilities, handlers and rows, once each unit has what it imports.
  parsed <- either (\(at, message) -> Left [Diagnostic "ability" message at]) Right (mapM elaborateAbilities imported')
  let imported = M.fromList [(unitName u ++ "::type::" ++ dataTypeName d, d{dataTypeConstructors=
        [c{dataConstructorName=unitName u ++ "::type::" ++ dataTypeName d ++ "::" ++ dataConstructorName c}
        | c <- dataTypeConstructors d]}) | u <- parsed, d <- dataTypes u]
  lowered <- either (Left . pure . (\m -> Diagnostic "refinement" m Nothing)) Right (mapM (lowerUnitWith imported) parsed)
  let us = map qualifyDataNames lowered
  mapM_ checkRegexes us
  dataTypes <- elaborateDataDeclarationsWithProfile bits us
  _ <- either (Left . pure . (\m -> Diagnostic "data-type" m Nothing)) Right (CoreTypes.makeRegistry dataTypes)
  unless (length us == length (nub (map unitName us))) (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  -- Each unit is validated, and each law expanded, under a key of exactly
  -- its inputs: a law's expansion depends on the law, the laws it invokes,
  -- its unit's signatures (not its definitions' bodies) and the data types,
  -- so editing a body or another unit's laws reuses it.
  let dataDigest = digestHex (digestString (show dataTypes))
      key parts = digestHex (digestString parts)
  mapM_ (\u -> Memo.memoized validationTable (key (show ("unit", bits, dataDigest, u))) (validateUnit dataTypes u)) us
  mapM_ (\u -> Memo.memoized validationTable (key (show ("totality", bits, dataDigest, u))) (validateDefinitionTotality dataTypes bits u)) us
  let table = M.fromList [((unitName u,lawName l),l) | u <- us, l <- laws u]
      signatures u = [ (functionName d, functionArguments d, functionResult d, functionRequirements d) | d <- functionDefinitions u ]
      expansionKey u l = key (show (bits, settings, dataDigest, unitName u, functions u, signatures u, l, invokedLaws table l))
      typedChecked environment expression = do
        (tree, requirements) <- typedExpressionWithSchemes dataTypes bits environment expression
        forM_ requirements $ \requirement -> unless (satisfiedWithData dataTypes bits [] requirement)
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
      (bs0,body0,tr,argumentChecks0) <- expand (map functionName (functionDefinitions u)) table (unitName u) env [] l (map (Var . fst) (parameters l))
      bs <- mapM (\i -> do ps <- mapM resolveExpr (inputRefinements i); pure i{inputRefinements=ps}) bs0
      body <- resolveAssertion body0
      argumentChecks <- mapM resolveExpr argumentChecks0
      checkedInputs <- forM bs $ \v -> do
        t <- resolve (inputType v)
        unless (valueType dataTypes t || (symbolic && valueType dataTypes (abstractType t))) (throwC ("unsupported quantified type: " ++ show t))
        when (not symbolic && not (concreteValue dataTypes t)) (throwC "executable inputs must have a concrete value type")
        pure v{inputType=t}
      -- One recording holds one value, so a law that quantifies cannot
      -- compare with one; its examples can.
      when (not (null checkedInputs) && any (elem "prelude.recorded" . exprVars) (assertionExpressions body))
        (throwC "a recorded value is compared in an example, or in a law without `for all`: every input would need its own recording")
      os <- gets obligations >>= mapM (\(Capability c t) -> Capability c <$> resolve t)
      let allowed = [Capability c (rigid t) | Capability c t <- requirements l]
      forM_ os $ \c -> unless (satisfiedWithData dataTypes bits allowed c) (throwC ("unsatisfied capability: " ++ show c))
      unless symbolic $ do
        lift (unique "expanded input name" (map inputName checkedInputs))
      forM_ (examples l) $ \ex -> withContext ("example " ++ exampleName ex ++ ": ") $ do
        lift (unique "example binding" (map fst (bindings ex)))
        unless (M.keys (M.fromList (bindings ex)) == M.keys (M.fromList [(inputName v,()) | v <- checkedInputs])) (throwC ("example " ++ exampleName ex ++ " must bind exactly: " ++ intercalate ", " (map inputName checkedInputs)))
        forM_ (bindings ex) $ \(n,v) -> do
          case lookup n [(inputName inp,inputType inp) | inp <- checkedInputs] of
            Just expected -> checkExpr M.empty expected (literalExpr v)
            Nothing -> throwC "unknown example input"
        let exampleEnv = M.union (monoEnvironment [(inputName inp,inputType inp) | inp <- checkedInputs]) env
        forM_ (expectations ex) $ \check -> do
          actualType <- infer exampleEnv (actual check) >>= resolve
          checkExpr M.empty actualType (literalExpr (expected check))
      let (a,b,gs) = firstConclusion body
      let lawEnvironment = M.union (monoEnvironment [(inputId inp,inputType inp) | inp <- checkedInputs]) env
          expressionEnvironment = M.union (monoEnvironment [(inputName inp,inputType inp) | inp <- checkedInputs]) lawEnvironment
          lawEnv = environmentTypes lawEnvironment
      ir <- if symbolic then pure [] else lift ((++) <$> mapM (typedChecked lawEnvironment) (concatMap inputRefinements checkedInputs ++ assertionExpressions body) <*> mapM (typedChecked expressionEnvironment) [actual c | ex <- examples l, c <- expectations ex])
      normalized <- if symbolic then pure (examples l) else forM (examples l) $ \ex -> do
        bs' <- forM (bindings ex) $ \(n,v) -> do
          t <- maybe (throwC "unknown example input") pure (lookup n [(inputName inp,inputType inp) | inp <- checkedInputs])
          value <- lift (normalizeLiteralWithData dataTypes bits t v)
          pure (n,value)
        checks' <- forM (expectations ex) $ \c -> do
          t <- infer expressionEnvironment (actual c) >>= resolve
          value <- lift (normalizeLiteralWithData dataTypes bits t (expected c))
          pure c{expected=value}
        pure ex{bindings=bs',expectations=checks'}
      let resolvedInputs = [inp{inputRefinements=map (mapExprTypes resolveKnown) (inputRefinements inp)} | inp <- checkedInputs]
          resolveKnown t = t
      pure (Expanded (unitName u) (lawName l) resolvedInputs a b gs body tr l{examples=normalized} ir (if take 9 (lawName l) == "contract " then "contract" else "law") settings (map (planDomain [(inputId i,inputType i) | i <- resolvedInputs]) resolvedInputs) argumentChecks)
      ) ((initialState bits){dataDeclarations=dataTypes})
  mapM_ (validateContracts dataTypes bits) us
  (specialized, properties) <- specializeDefinitions dataTypes bits (satisfiedWithData dataTypes bits [])
    (filter ((/= "prelude") . unitName) us) (filter (null . parameters . original) allExpanded)
  closedUnits <- either (Left . pure . (\message -> Diagnostic "definition" message Nothing)) Right
    (mapM (Elaboration.elaborateDefinitionUnit dataTypes bits) specialized)
  closedProgram <- deferProgramPostconditions (Core.Program bits dataTypes closedUnits)
  invoke <- prepareDefinitions closedProgram
  registry <- either (Left . pure . (\m -> Diagnostic "data-type" m Nothing)) Right (CoreTypes.makeRegistry dataTypes)
  forM_ properties $ \property -> do
    u <- maybe (Left [Diagnostic "semantic" "missing property owner" Nothing]) Right
      (lookup (owner property) [(unitName u,u) | u <- specialized])
    either (Left . pure . (\message -> Diagnostic "semantic" message (Just (location (original property))))) Right $
      evalStateT (do
        let identify name = Core.Id (unitName u ++ "::" ++ name)
        forM_ (refinementArgumentChecks property) $ \check -> do
          term <- lift (Elaboration.elaborateResolvedWithData dataTypes (map (identify . fst) (functions u))
            bits (Core.Id (name property)) identify (functions u) check)
          value <- lift (CoreEval.evaluateValue registry bits invoke [] term)
          unless (value == CoreValue.ScalarValue (SBool True)) (throwC "refinement value argument violates its declared parameter type")
        mapM_ (validateExampleDomains bits u invoke (inputs property)) (examples (original property)))
        ((initialState bits){dataDeclarations=dataTypes})
  pure (specialized, properties)

-- The laws a law invokes, transitively: every law whose name ends one of the
-- names it invokes, a superset of the ones expansion resolves.
invokedLaws :: M.Map (String,String) Law -> Law -> [Law]
invokedLaws table root = go Set.empty (invoked (definition root))
  where
    go _ [] = []
    go seen (n : rest)
      | Set.member n seen = go seen rest
      | otherwise =
          let found = [ l | ((_, name), l) <- M.toList table, name `isSuffixOf` n ]
          in found ++ go (Set.insert n seen) (concatMap (invoked . definition) found ++ rest)
    invoked d = case d of
      Forall _ body -> invoked body
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

prettyExpanded :: Expanded -> String
prettyExpanded e | propertyKind e == "contract" = description (original e)
prettyExpanded e = "for all " ++ intercalate " " ["(" ++ inputName i ++ " :: " ++ prettyType (inputType i) ++ (if null (inputRefinements i) then "" else " where " ++ intercalate " && " (map showExpr (inputRefinements i))) ++ ")" | i <- inputs e] ++ " . " ++ showAssertion (assertion e)
  where names = M.fromList [(inputId i,Var (inputName i)) | i <- inputs e]
        showExpr = prettyExpr . subst names
        showAssertion (AssertEqual a b) = showExpr a ++ " = " ++ showExpr b
        showAssertion (AssertImplies g a) = showExpr g ++ " implies " ++ showAssertion a
        showAssertion (AssertAll as) = intercalate " and " ["(" ++ showAssertion a ++ ")" | a <- as]

-- Braced references are checked against the law's lexical function environment.
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
normalizeLiteralWithData :: [Core.DataDeclaration] -> Int -> Type -> Literal -> Either String Literal
normalizeLiteralWithData dataTypes bits t (ConstructorLiteral name fields) = do
  parameters <- evalStateT (constructorParameters t name) ((initialState bits){dataDeclarations=dataTypes})
  unless (length parameters == length fields) (Left ("wrong constructor arity: " ++ name))
  ConstructorLiteral name <$> sequence [normalizeLiteralWithData dataTypes bits parameter field | (parameter, field) <- zip parameters fields]
normalizeLiteralWithData dataTypes bits (Applied "List" element) (ListLiteral xs) = ListLiteral <$> mapM (normalizeLiteralWithData dataTypes bits element) xs
normalizeLiteralWithData _ _ _ (ListLiteral _) = Left "list literal requires a List type"
normalizeLiteralWithData _ bits t v = do
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

validateContracts :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
validateContracts dataTypes bits u = either (Left . pure . (\m -> Diagnostic "contract" m Nothing)) Right $ forM_ (contracts u) $ \c -> evalStateT (do
  _ <- foldM (\env (n,t) -> do
    let env' = M.insert n (Monomorphic (baseType t)) env
    mapM_ (checkPredicate (map functionName (functionDefinitions u)) env') (typePredicates (Var n) t)
    mapM_ (\(Capability k ty) -> require k ty) (typeConstraints t)
    pure env') (definitionEnvironment u) (contractArguments c)
  let env = M.union (monoEnvironment [(n,baseType t) | (n,t) <- contractArguments c ++ [contractResult c]]) (definitionEnvironment u)
  mapM_ (checkPredicate (map functionName (functionDefinitions u)) env) (contractPostconditions c)
  mapM_ (\(Capability k ty) -> require k ty) (typeConstraints (snd (contractResult c)))
  os <- gets obligations >>= mapM (\(Capability name ty) -> Capability name <$> resolve ty)
  forM_ os $ \o -> unless (satisfiedWithData dataTypes bits [] o) (throwC ("unsatisfied contract capability: " ++ show o))
  ) ((initialState bits){dataDeclarations=dataTypes})

validateExampleDomains :: Int -> Unit -> (Core.Id -> [CoreValue.Value] -> Either String CoreValue.Value) -> [Input] -> Example -> C ()
validateExampleDomains bits unit invoke ins ex = withContext ("example " ++ exampleName ex ++ ": ") $ do
  dataTypes <- gets dataDeclarations
  registry <- lift (CoreTypes.makeRegistry dataTypes)
  let origin = Core.Id ("example::" ++ exampleName ex)
      identify name = Core.Id (unitName unit ++ "::" ++ name)
      resolve name = if name `elem` map inputId ins then Core.Id name else identify name
      env = functions unit ++ [(inputId input,inputType input) | input <- ins]
      lower = Elaboration.elaborateResolvedWithData dataTypes (map (identify . fst) (functions unit)) bits origin resolve env
  values <- forM ins $ \input -> do
    literal <- maybe (throwC "missing example input") pure (lookup (inputName input) (bindings ex))
    term <- lift (lower (Annotate (literalExpr literal) (inputType input)))
    value <- lift (CoreEval.evaluateValuePure registry bits [] term)
    pure (Core.Id (inputId input), value)
  forM_ (concatMap inputRefinements ins) $ \predicate -> do
    term <- lift (lower predicate)
    value <- lift (CoreEval.evaluateValue registry bits invoke values term)
    unless (value == CoreValue.ScalarValue (SBool True))
      (throwC ("example violates refinement: " ++ prettyExpr predicate))

resolveExpr :: Expr -> C Expr
resolveExpr (Located range e) = Located range <$> resolveExpr e
resolveExpr (ConstructLit name fields) = ConstructLit name <$> mapM resolveExpr fields
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


abstractType :: Type -> Type
abstractType = mapType (\t -> case t of Named n@('@':_) -> Variable n; _ -> t) id

validTypeWithData :: [Core.DataDeclaration] -> Type -> Bool
validTypeWithData declarations t = either (const False) (const True) $ do
  registry <- CoreTypes.makeRegistry declarations
  ty <- Elaboration.coreType t
  CoreTypes.checkType registry ty

valueType :: [Core.DataDeclaration] -> Type -> Bool
valueType _ (Arrow _ _) = False
valueType declarations t = validTypeWithData declarations t

concreteValue :: [Core.DataDeclaration] -> Type -> Bool
concreteValue declarations t = valueType declarations t && concrete (baseType t)
  where
    concrete (Variable _) = False
    concrete (Named ('@':_)) = False
    concrete (Applied _ a) = concrete a
    concrete (Application _ args) = all concrete args
    concrete (Arrow a b) = concrete a && concrete b
    concrete _ = True

-- This is the type/capability audit, not the totality proof. Concrete bodies
-- still pass Core.Total; generic bodies must pass termination/definedness and
-- closed-call specialization before the frontend can enable them for execution.
validateDefinitionTypes :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
validateDefinitionTypes declarations bits unit = () <$ inferDefinitionTemplates declarations bits unit

validateDefinitionTotality :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] ()
-- An orchestration's body is type-checked like any definition, but calls
-- adapters, so only the others are proved total.
validateDefinitionTotality declarations bits unit =
  inferDefinitionTemplates declarations bits unit >>= auditTemplates declarations bits unit
    . filter (\(d, _, _, _) -> functionName d `notElem` orchestrations unit)

inferDefinitionTemplates :: [Core.DataDeclaration] -> Int -> Unit -> Either [Diagnostic] [(FunctionDefinition, TypedExpr, [TypedExpr], [TypedExpr])]
inferDefinitionTemplates declarations bits unit = do
  unless (bits `elem` [32,64]) (Left [Diagnostic "machineBits" "machineBits must be 32 or 64" Nothing])
  mapM validate (functionDefinitions unit)
  where
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
      unless (all (valueType declarations) (functionResult d : map snd parameters))
        (Left "definition parameters and result require value types")
      forM_ declared $ \(Capability name ty) -> do
        unless (name `elem` ["Eq","Integer","Ordered","Bounded","Keyed"])
          (Left ("unknown capability: " ++ name))
        unless (valueType declarations ty && all (`elem` bound) (variables ty))
          (Left "capability mentions an invalid or unbound type")
        when (null (variables ty) && not (satisfiedWithData declarations bits [] (Capability name ty)))
          (Left ("unsatisfied definition capability: " ++ show (Capability name ty)))
      unless (all (`elem` bound) (concatMap variables (annotations (functionBody d))))
        (Left "body annotation mentions an unbound type variable")
      (body, obligations) <- typedExpressionWithSchemes declarations bits environment
        (Annotate (normal (mapExprTypes rigid (functionBody d))) (rigid (baseType (functionResult d))))
      contract <- definitionContractFor d
      let predicate scope expression = do
            (tree, constraints) <- typedExpressionWithSchemes declarations bits scope
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
        unless (satisfiedWithData declarations bits allowed obligation)
          (Left ("unsatisfied definition capability: " ++ show obligation))
      pure (d, body, preconditions, map fst postconditions)
    variables ty = nub $ case baseType ty of
      Variable name -> [name]
      Arrow a b -> variables a ++ variables b
      Applied _ a -> variables a
      Application _ arguments -> concatMap variables arguments
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
      ListLit fields -> concatMap annotations fields
      AllPayloadsExpr value predicates -> annotations value ++ concatMap (annotations . snd) predicates
      AllElementsExpr value _ predicate -> annotations value ++ annotations predicate
      MatchExpr value branches -> annotations value ++ concat
        [annotations body | MatchBranch _ _ body <- branches]
      _ -> []
