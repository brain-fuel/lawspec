-- Closed monomorphization after law expansion and template auditing. Target
-- generators continue to receive only concrete, independently validated Core.
module LawSpec.SpecializeDefinitions (specializeDefinitions) where

import Control.Monad.State.Strict
import Control.Monad (forM, forM_, unless, foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.List (sortOn, foldl')
import Data.Char (ord)
import Data.Bits (xor)
import Data.Word (Word64)
import Numeric (showHex)
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

specializeDefinitions :: [Core.DataDeclaration] -> Int -> (Constraint -> Bool)
  -> [Unit] -> [Expanded] -> Either [Diagnostic] ([Unit],[Expanded])
specializeDefinitions declarations bits satisfies units properties = do
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
          rewrittenContracts <- mapM contract [c | c <- contracts originalUnit,
            contractName c `notElem` map functionName definitions]
          drain
          entries <- gets (map snd . M.toAscList . instances)
          let bodies = sortOn functionName [d | Instance _ d _ _ <- entries]
              external = [(name,ty) | (name,ty) <- functions originalUnit,
                name `notElem` map functionName definitions]
              result = originalUnit
                { functions = external ++ [(functionName d, definitionType d) | d <- bodies]
                , functionDefinitions = bodies
                , contracts = rewrittenContracts ++ [c | Instance _ _ (Just c) _ <- entries]
                , declarationSpans = [(name,range) | (name,range) <- declarationSpans originalUnit,
                    name `elem` map fst external] ++ [(functionName d,functionSpan d) | d <- bodies]
                }
          final <- mapM (refresh result) rewritten
          pure (result, final)
        typed scope expression = do
          (tree, constraints) <- lift (typedExpressionWithSchemes declarations bits scope (normal expression))
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
            ((key@(originalName,_),Instance generated definition attached _):_) -> do
              -- Mark before visiting calls, so direct recursion reuses this entry.
              modify (\state -> state{instances=M.insert key (Instance generated definition attached True) (instances state)})
              let locals = Set.fromList (map fst (functionArguments definition))
                  scope = M.union (monoEnvironment (functionArguments definition))
                    (M.insert originalName (Monomorphic (definitionType definition)) environment)
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
          let local = Set.fromList (map inputId (inputs expanded))
              scope = M.union (monoEnvironment [(inputId i,inputType i) | i <- inputs expanded]) environment
              walk (AssertEqual a b) = uncurry AssertEqual <$> equation scope local a b
              walk (AssertImplies guard body) = AssertImplies <$> rewrite scope local guard <*> walk body
              walk (AssertAll bodies) = AssertAll <$> mapM walk bodies
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
          let scope = functions result ++ [(inputId i,inputType i) | i <- inputs expanded]
              examplesScope = scope ++ [(inputName i,inputType i) | i <- inputs expanded]
          trees <- lift $ (++) <$> mapM (typedExpressionWithData declarations bits scope)
            (concatMap inputRefinements (inputs expanded) ++ assertionExpressions (assertion expanded)) <*>
            mapM (typedExpressionWithData declarations bits examplesScope)
              [actual expectation | example <- examples (original expanded), expectation <- expectations example]
          pure expanded{typedExpressions=trees}
    closed ty = null (typeVariables ty) && case baseType ty of
      Named ('@':_) -> False
      Arrow a b -> closed a && closed b
      Applied _ a -> closed a
      Application _ arguments -> all closed arguments
      _ -> True
    match substitutions pattern concrete = case (pattern,concrete) of
      (Variable name,_) -> case M.lookup name substitutions of
        Nothing -> Right (M.insert name concrete substitutions)
        Just ty | ty == concrete -> Right substitutions
                | otherwise -> Left "inconsistent generic definition instance"
      (Arrow a b,Arrow x y) -> match substitutions a x >>= \next -> match next b y
      (Applied name a,Applied other b) | name == other -> match substitutions a b
      (Application name args,Application other values) | name == other && length args == length values ->
        foldM (\next (a,b) -> match next a b) substitutions (zip args values)
      _ | pattern == concrete -> Right substitutions
        | otherwise -> Left "definition instance does not match its signature"
    assertionExpressions (AssertEqual a b) = [a,b]
    assertionExpressions (AssertImplies guard body) = guard : assertionExpressions body
    assertionExpressions (AssertAll bodies) = concatMap assertionExpressions bodies
