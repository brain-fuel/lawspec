-- | Closed monomorphization after law expansion and template auditing. Target
-- generators continue to receive only concrete, independently validated Core.
module LawSpec.SpecializeDefinitions (specializeDefinitions, specializeDefinitionsWithContext) where

import Control.Monad.State.Strict
import Control.Monad (forM, forM_, unless, when, foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.List (sortOn, foldl')
import Data.Char (ord)
import Data.Bits (xor)
import Data.Word (Word64)
import Numeric (showHex)
import qualified LawSpec.SourceContext as Source
import LawSpec.Model
import qualified LawSpec.Core as Core
import LawSpec.Inference
import LawSpec.Refinement (planDomain, definitionContractFor)

data Instance = Instance String FunctionDefinition (Maybe Contract) Bool
data Work = Work
  { instances :: M.Map (String,String) Instance
  , occupied :: Set.Set String
  }
type Specialize = StateT Work (Either String)

-- | Generic definitions are specialised to the types laws use them at, so every
-- target receives concrete code and needs no generics of its own.
specializeDefinitions :: [Core.DataDeclaration] -> Int -> (Constraint -> Bool)
  -> [Unit] -> [Expanded] -> Either [Diagnostic] ([Unit],[Expanded])
specializeDefinitions = specializeDefinitionsWithContext Source.emptyContext

specializeDefinitionsWithContext :: Source.SourceContext -> [Core.DataDeclaration] -> Int -> (Constraint -> Bool)
  -> [Unit] -> [Expanded] -> Either [Diagnostic] ([Unit],[Expanded])
specializeDefinitionsWithContext sourceTypes declarations bits satisfies units properties = do
  results <- mapM unit units
  pure (map fst results, concatMap snd results)
  where
    unit originalUnit
      | null generic && all (\d -> baseType (definitionType d) == definitionType d) definitions
      , all ((`notElem` map functionName definitions) . contractName) (contracts originalUnit)
      = Right (originalUnit, owned)
      | otherwise = either (Left . pure . (\message -> Diagnostic "specialization"
          (unitName originalUnit ++ ": " ++ message) Nothing)) Right $
          evalStateT process (Work M.empty (Set.fromList (map fst (functions originalUnit))))
      where
        owned = filter ((== unitName originalUnit) . owner) properties
        definitions = functionDefinitions originalUnit
        generic = [functionName d | d <- definitions, not (null (typeVariables (definitionType d)))]
        environment = definitionEnvironment originalUnit
        process = do
          -- Concrete definitions are roots even if no property calls them.
          forM_ definitions $ \d -> unless (functionName d `elem` generic) $
            ensure (functionName d) (baseType (definitionType d)) >> pure ()
          rewritten <- mapM property owned
          rewrittenHarness <- forM (lawHarness originalUnit) $ \(name, plan) -> do
            witnesses <- forM (planResolvedWitnesses plan) $ \witness -> do
              let bindings = [(inputId i,inputType i) | i <- witnessScope witness]
                  scope = M.union (monoEnvironment bindings) environment
                  local = Set.fromList (map fst bindings)
              value <- rewrite scope local (Annotate (witnessExpression witness) (inputType (witnessInput witness)))
              pure witness { witnessExpression = value }
            draws <- forM (planDraws plan) $ \(input,strategy,ty,body) -> do
              ty' <- rewriteStrategyType ty
              body' <- rewriteGen environment Set.empty (baseType ty) body
              pure (input,strategy,ty',body')
            pure (name, plan { planResolvedWitnesses = witnesses,planDraws = draws })
          let declarations = [s | Just h <- [unitHarness originalUnit],HarnessStrategy s <- harnessItems h]
              referenced gen = case gen of
                GenNamed n -> [n]
                GenFrequency alternatives -> concatMap (referenced . snd) alternatives
                GenSuchThat inner _ _ -> referenced inner
                GenBind _ _ from body -> referenced from ++ referenced body
                _ -> []
              reachable seen [] = seen
              reachable seen (n:rest) | n `Set.member` seen = reachable seen rest
                | otherwise = reachable (Set.insert n seen) (rest ++ concat
                    [referenced (strategyBody s) | s <- declarations,strategyName s == n])
              used = reachable Set.empty [strategy | (_,plan) <- lawHarness originalUnit,(_,strategy,_,_) <- planDraws plan]
          rewrittenHarnessUnit <- traverse (\h -> do
            items <- forM (harnessItems h) $ \item -> case item of
              HarnessStrategy s | strategyName s `Set.member` used -> do
                ty <- rewriteStrategyType (strategyType s)
                body <- rewriteGen environment Set.empty (baseType (strategyType s)) (strategyBody s)
                pure (HarnessStrategy s { strategyBody = body,strategyType = ty })
              _ -> pure item
            pure h { harnessItems = items }) (unitHarness originalUnit)
          rewrittenContracts <- mapM contract [c | c <- contracts originalUnit,
            contractName c `notElem` map functionName definitions]
          drain
          entries <- gets (map snd . M.toAscList . instances)
          let bodies = sortOn functionName [d | Instance _ d _ _ <- entries]
              external = [(name,ty) | (name,ty) <- functions originalUnit,
                name `notElem` map functionName definitions]
              result = originalUnit
                { functions = external ++ [(functionName d, definitionType d) | d <- bodies]
                , lawHarness = rewrittenHarness
                , unitHarness = rewrittenHarnessUnit
                , functionDefinitions = bodies
                , contracts = rewrittenContracts ++ [c | Instance _ _ (Just c) _ <- entries]
                , declarationSpans = [(name,range) | (name,range) <- declarationSpans originalUnit,
                    name `elem` map fst external] ++ [(functionName d,functionSpan d) | d <- bodies]
                }
          final <- mapM (refresh result) rewritten
          pure (result, final)
        rewriteStrategyType ty = case ty of
          Refined name base (Just predicate) -> do
            value <- rewrite (M.union (monoEnvironment [(name,base)]) environment) (Set.singleton name)
              (Annotate predicate (Named "Bool"))
            pure (Refined name base (Just value))
          _ -> pure ty
        rewriteGen scope local ty gen = case gen of
          GenOneOf values -> GenOneOf <$> mapM (rewrite scope local . (`Annotate` ty)) values
          GenFrequency alternatives -> GenFrequency <$> mapM (\(weight,inner) -> (,) weight <$> rewriteGen scope local ty inner) alternatives
          GenSuchThat inner predicate limit -> do
            inner' <- rewriteGen scope local ty inner
            predicate' <- rewrite (M.union (monoEnvironment [("it",ty)]) scope) (Set.insert "it" local)
              (Annotate predicate (Named "Bool"))
            pure (GenSuchThat inner' predicate' limit)
          GenBind name valueType from body -> GenBind name valueType
            <$> rewriteGen scope local (baseType valueType) from
            <*> rewriteGen (M.union (monoEnvironment [(name,valueType)]) scope) (Set.insert name local) ty body
          _ -> pure gen
        typed scope expression = do
          (tree, constraints) <- lift (typedExpressionWithSchemesContext sourceTypes declarations bits scope (normal expression))
          forM_ constraints $ \constraint -> unless (satisfies constraint)
            (lift (Left ("unsatisfied specialization capability: " ++ show constraint)))
          pure tree
        rewrite scope local expression = typed scope expression >>= rewriteTree local
        rewriteTree local tree = do
          expression <- case expression tree of
            Located span inner -> Located span <$> rewriteTree local tree{expression=inner, requiredConversion=Nothing}
            Var name | name `elem` generic, name `Set.notMember` local ->
              Var <$> ensure name (expressionType tree)
            AllPayloadsExpr _ _ -> case operands tree of
              [value] -> do
                value' <- rewriteTree local value
                predicates <- mapM (\entry -> case entry of
                  TypedCase _ [(name,_)] predicate -> (,) name <$> rewriteTree (Set.insert name local) predicate
                  _ -> lift (Left "invalid typed payload callback during specialization")) (typedCases tree)
                pure (AllPayloadsExpr value' predicates)
              _ -> lift (Left "invalid typed payload predicate during specialization")
            AllElementsExpr _ _ _ -> case (operands tree,typedCases tree) of
              ([value],[TypedCase _ [(name,_)] predicate]) ->
                AllElementsExpr <$> rewriteTree local value <*> pure name <*>
                  rewriteTree (Set.insert name local) predicate
              _ -> lift (Left "invalid typed List predicate during specialization")
            MatchExpr _ _ -> case operands tree of
              [value] -> do
                value' <- rewriteTree local value
                cases <- forM (typedCases tree) $ \(TypedCase tag fields body) ->
                  MatchBranch tag (map fst fields) <$>
                    rewriteTree (Set.union local (Set.fromList (map fst fields))) body
                pure (MatchExpr value' cases)
              _ -> lift (Left "invalid typed match during specialization")
            other -> do
              values <- mapM (rewriteTree local) (operands tree)
              lift $ case (other,values) of
                (Apply _ _,args) | (Var name,_) <- application other, take 8 name == "prelude." ->
                  Right (foldl Apply (Var name) args)
                (Apply _ _,[f,x]) -> Right (Apply f x)
                (Binary op _ _,[a,b]) -> Right (Binary op a b)
                (Unary op _,[a]) -> Right (Unary op a)
                (Compose _ _,[f,g]) -> Right (Compose f g)
                (Annotate _ (Arrow _ _),[a]) -> Right a
                (Annotate _ ty,[a]) -> Right (Annotate a ty)
                (ConstructLit tag _,fields) -> Right (ConstructLit tag fields)
                (RecordLit original,fields) | length original == length fields -> Right (RecordLit (zip (map fst original) fields))
                (ListLit _,fields) -> Right (ListLit fields)
                (_,[]) -> Right other
                _ -> Left "invalid typed expression during specialization"
          -- Keep inferred contexts concrete when the rewritten expression is
          -- elaborated again (notably empty containers and phantom parameters).
          let target = maybe (expressionType tree) id (requiredConversion tree)
          pure (case target of Arrow _ _ -> expression; _ -> Annotate expression target)
        ensure :: String -> Type -> Specialize String
        ensure name concrete = do
          unless (closed concrete) (lift (Left ("ambiguous definition instance: " ++ name ++ " :: " ++ prettyType concrete)))
          let key = (name,show concrete)
          existing <- gets (M.lookup key . instances)
          case existing of
            Just (Instance generated _ _ _) -> pure generated
            Nothing -> do
              -- Polymorphic recursion may instantiate a definition at new type
              -- arguments; a recursion that keeps growing them never ends,
              -- and soon reaches the size limit. A program may use a generic
              -- definition, such as a collection operation, at hundreds of
              -- types (one per resource of an imported API).
              siblings <- gets (length . filter ((== name) . fst) . M.keys . instances)
              when (siblings >= 8192 || length (show concrete) > 4000)
                (lift (Left ("definition " ++ name ++ " needs unboundedly many instances; " ++
                  "polymorphic recursion must not grow its type arguments")))
              template <- lift $ maybe (Left ("unknown definition: " ++ name)) Right
                (lookup name [(functionName d,d) | d <- definitions])
              substitutions <- lift (match M.empty (baseType (definitionType template)) (baseType concrete))
              let replace = mapType (\ty -> case ty of
                    Variable variable -> M.findWithDefault ty variable substitutions
                    _ -> ty) (mapExprTypes replace)
                  requirements = [Capability capability (replace ty) | Capability capability ty <- functionRequirements template]
              forM_ requirements $ \requirement -> unless (satisfies requirement)
                (lift (Left ("unsatisfied specialization capability: " ++ show requirement)))
              generated <- if name `elem` generic then allocate name concrete else pure name
              let definition = template
                    { functionName = generated
                    , functionArguments = [(n,replace ty) | (n,ty) <- functionArguments template]
                    , functionResult = replace (functionResult template)
                    , functionRequirements = requirements
                    , functionBody = mapExprTypes replace (functionBody template)
                    }
              boundary <- lift $ case [c | c <- contracts originalUnit, contractName c == name] of
                [] -> definitionContractFor definition
                [c] -> pure c{contractArguments=[(n,replace ty) | (n,ty) <- contractArguments c],
                  contractResult=(fst (contractResult c),replace (snd (contractResult c))),
                  contractPreconditions=map (mapExprTypes replace) (contractPreconditions c),
                  contractPostconditions=map (mapExprTypes replace) (contractPostconditions c)}
                _ -> Left ("duplicate definition contract: " ++ name)
              let instantiated = boundary{contractName=generated}
                  attached = if null (contractPreconditions instantiated) && null (contractPostconditions instantiated)
                    then Nothing else Just instantiated
              modify (\state -> state{instances=M.insert key (Instance generated definition attached False) (instances state)})
              pure generated
        allocate :: String -> Type -> Specialize String
        allocate name ty = do
          used <- gets occupied
          let hash = foldl' (\value c -> (value `xor` fromIntegral (ord c)) * 1099511628211)
                (14695981039346656037 :: Word64) (show ty)
              base = "lawspec_" ++ name ++ "_" ++ showHex hash ""
              candidate = head (filter (`Set.notMember` used) [base ++ replicate count '_' | count <- [0..]])
          modify (\state -> state{occupied=Set.insert candidate (occupied state)})
          pure candidate
        drain = do
          pending <- gets (filter (\(_,Instance _ _ _ done) -> not done) . M.toAscList . instances)
          case pending of
            [] -> pure ()
            ((key,Instance generated definition attached _):_) -> do
              -- Mark before visiting calls, so direct recursion reuses this entry.
              modify (\state -> state{instances=M.insert key (Instance generated definition attached True) (instances state)})
              -- The definition stays polymorphic in its own body: a recursive
              -- call at other type arguments specializes another instance.
              let locals = Set.fromList (map fst (functionArguments definition))
                  scope = M.union (monoEnvironment (functionArguments definition)) environment
              body <- rewrite scope locals (Annotate (functionBody definition) (baseType (functionResult definition)))
              boundary <- mapM contract attached
              let lowered = definition{functionBody=body,
                    functionArguments=[(n,baseType ty) | (n,ty) <- functionArguments definition],
                    functionResult=baseType (functionResult definition)}
              modify (\state -> state{instances=M.insert key
                (Instance generated lowered boundary True) (instances state)})
              drain
        equation scope local a b = do
          tree <- typed scope (Binary "==" a b)
          case operands tree of
            [left,right] -> (,) <$> rewriteTree local left <*> rewriteTree local right
            _ -> lift (Left "invalid typed equation during specialization")
        contract original = do
          let arguments = contractArguments original
              result = contractResult original
              scope values = M.union (monoEnvironment [(n,baseType ty) | (n,ty) <- values]) environment
              local values = Set.fromList (map fst values)
          pre <- mapM (rewrite (scope arguments) (local arguments)) (contractPreconditions original)
          post <- mapM (rewrite (scope (arguments ++ [result])) (local (arguments ++ [result])))
            (contractPostconditions original)
          pure original{contractPreconditions=pre,contractPostconditions=post}
        property expanded = do
          let bindings = [(inputId i,inputType i) | i <- inputs expanded ++ assertionInputs (assertion expanded)] ++ lawResources (original expanded)
              local = Set.fromList (map fst bindings)
              scope = M.union (monoEnvironment bindings) environment
              walk (AssertEqual a b) = uncurry AssertEqual <$> equation scope local a b
              walk (AssertImplies guard body) = AssertImplies <$> rewrite scope local guard <*> walk body
              walk (AssertAll bodies) = AssertAll <$> mapM walk bodies
              walk (AssertNot body) = AssertNot <$> walk body
              walk (AssertQuantified kind input body) = do
                predicates <- mapM (rewrite scope local) (inputRefinements input)
                AssertQuantified kind (input { inputRefinements = predicates }) <$> walk body
          body <- walk (assertion expanded)
          argumentChecks <- mapM (rewrite environment Set.empty) (refinementArgumentChecks expanded)
          inputs' <- forM (inputs expanded) $ \input -> do
            predicates <- mapM (rewrite scope local) (inputRefinements input)
            pure input{inputRefinements=predicates}
          examples' <- forM (examples (original expanded)) $ \example -> do
            let exampleScope = M.union (monoEnvironment [(inputName i,inputType i) | i <- inputs expanded]) scope
                exampleLocals = Set.union local (Set.fromList (map inputName (inputs expanded)))
            expectations' <- forM (expectations example) $ \expectation -> do
              (actual',_) <- equation exampleScope exampleLocals (actual expectation) (literalExpr (expected expectation))
              pure expectation{actual=actual'}
            pure example{expectations=expectations'}
          let (a,b,conditions) = firstConclusion body
          pure expanded{assertion=body,left=a,right=b,guards=conditions,inputs=inputs',refinementArgumentChecks=argumentChecks,
            original=(original expanded){examples=examples'}, generationPlan=map
              (planDomain [(inputId i,inputType i) | i <- inputs']) inputs'}
        refresh result expanded = do
          let scope = functions result ++ [(inputId i,inputType i) | i <- inputs expanded ++ assertionInputs (assertion expanded)] ++ lawResources (original expanded)
              examplesScope = scope ++ [(inputName i,inputType i) | i <- inputs expanded]
          trees <- lift $ (++) <$> mapM (typedExpressionWithContext sourceTypes declarations bits scope)
            (concatMap inputRefinements (inputs expanded) ++ assertionExpressions (assertion expanded)) <*>
            mapM (typedExpressionWithContext sourceTypes declarations bits examplesScope)
              [actual expectation | example <- examples (original expanded), expectation <- expectations example]
          pure expanded{typedExpressions=trees}
    closed ty = null (typeVariables ty) && case baseType ty of
      Named ('@':_) -> False
      Arrow a b -> closed a && closed b
      Applied _ a -> closed a
      Application _ arguments -> all closed arguments
      Record fields -> all (closed . recordFieldType) fields
      _ -> True
    match replacements pattern concrete = substitutions <$> execStateT (unify pattern concrete)
      (withSourceContext sourceTypes (withDataDeclarations declarations (initialState bits))){substitutions=replacements}
    assertionExpressions (AssertEqual a b) = [a,b]
    assertionExpressions (AssertImplies guard body) = guard : assertionExpressions body
    assertionExpressions (AssertAll bodies) = concatMap assertionExpressions bodies
    assertionExpressions (AssertNot body) = assertionExpressions body
    assertionExpressions (AssertQuantified _ input body) = inputRefinements input ++ assertionExpressions body
