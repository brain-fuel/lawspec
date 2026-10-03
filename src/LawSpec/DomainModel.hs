-- Domain modeling declarations elaborate before inference, like indexed
-- families. A wrapper is a nominal single-field type whose constructor is a
-- checked contract, so an invalid value cannot be constructed. A workflow is a
-- typed pipeline of adapter steps between distinct state types, with a law that
-- the workflow equals the railway composition of its steps.
module LawSpec.DomainModel
  ( Wrapper(..), Workflow(..), WorkflowStage(..), StageKind(..)
  , wrapperValueName, elaborateDomain
  ) where

import LawSpec.Scalar (isExact)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Char (toUpper)
import Data.List (nub)
import LawSpec.Model
import LawSpec.Railway (railwayLaw)

data Wrapper = Wrapper
  { wrapperName :: String
  , wrapperParameters :: [String]
  , wrapperBase :: Type
  , wrapperPredicate :: Maybe Expr
  , wrapperSpan :: Span
  } deriving (Eq, Show)

-- A workflow stage. Each names a function: a step declared here or one
-- declared elsewhere, a mapping, an error mapping, a recovery, a fallback, a
-- side step, or a predicate with the function that builds its failure.
data StageKind
  = DeclaredStep String Type
  | StepStage String
  | MapStage String
  | MapErrorStage String
  | OrElseStage String
  | FallbackStage String
  | TapStage String
  | EnsureStage String String
  deriving (Eq, Show)

data WorkflowStage = WorkflowStage { stageKind :: StageKind, stageSpan :: Span } deriving (Eq, Show)

data Workflow = Workflow
  { workflowName :: String
  , workflowType :: Type
  , workflowStages :: [WorkflowStage]
  , workflowSpan :: Span
  } deriving (Eq, Show)

-- The unwrapping definition for a wrapper, such as valueOfUnitQuantity.
wrapperValueName :: String -> String
wrapperValueName name = "valueOf" ++ name

-- Failures carry the declaration's source location when one is known.
elaborateDomain :: [Wrapper] -> [Workflow] -> Unit -> Either (Maybe Location, String) Unit
elaborateDomain [] [] u = pure u
elaborateDomain wrappers workflows u = either (Left . (,) Nothing) Right (checkWrappers wrappers u) >> do
  let unwrap = map wrapperDefinition wrappers
      at w = either (Left . (,) (Just (spanStart (workflowSpan w)))) Right
      spanStart (Span start _) = start
  declared <- foldl (\acc w -> acc >>= at w . declareSteps w) (pure (functions u)) workflows
  let signature d = (functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d)))
      env = map signature unwrap ++ declared
      definitionNames = map functionName (unwrap ++ functionDefinitions u)
      taken = map fst env ++ concatMap (map fst . functionArguments) (functionDefinitions u)
  elaborated <- forM workflows (\w -> at w (elaborateWorkflow env definitionNames taken w))
  let workflowDefinitions = [d | Elaborated d _ _ <- elaborated]
  pure u
    { dataTypes = map wrapperDeclaration wrappers ++ [t | Elaborated _ _ (Just t) <- elaborated] ++ dataTypes u
    , functions = map signature (unwrap ++ workflowDefinitions) ++ declared
    , functionDefinitions = unwrap ++ workflowDefinitions ++ functionDefinitions u
    , orchestrations = map functionName workflowDefinitions ++ orchestrations u
    , declarationSpans = [(functionName d, functionSpan d) | d <- unwrap ++ workflowDefinitions] ++
        [(name, range) | w <- workflows, WorkflowStage (DeclaredStep name _) range <- workflowStages w] ++ declarationSpans u
    , laws = laws u ++ concat [ls | Elaborated _ ls _ <- elaborated]
    }

checkWrappers :: [Wrapper] -> Unit -> Either String ()
checkWrappers wrappers u = do
  let wrapperNames = map wrapperName wrappers
      existing = map dataTypeName (dataTypes u)
  forM_ wrapperNames $ \name -> when (name `elem` existing)
    (Left ("duplicate data type: " ++ name))
  unless (length (nub wrapperNames) == length wrapperNames)
    (Left "duplicate wrapper declaration")
  forM_ wrappers $ \w ->
    unless (length (nub (wrapperParameters w)) == length (wrapperParameters w))
      (Left (wrapperName w ++ ": duplicate type parameter"))

applied :: String -> [Type] -> Type
applied n [] = Named n
applied n [a] = Applied n a
applied n args = Application n args

wrapperType :: Wrapper -> Type
wrapperType w = applied (wrapperName w) (map Variable (wrapperParameters w))

-- The constructor shares the wrapper's name and stores one field, value. A
-- predicate becomes a constructor field refinement, checked at construction.
wrapperDeclaration :: Wrapper -> DataTypeDeclaration
wrapperDeclaration w = DataTypeDeclaration (wrapperName w) (wrapperParameters w)
  [ConstructorDeclaration (wrapperName w) [("value", field)] (wrapperSpan w) []] (wrapperSpan w) Nothing
  where field = maybe (wrapperBase w) (Refined "value" (wrapperBase w) . Just) (wrapperPredicate w)

-- Over an exact number, its result carries the wrapper's constraint, so the
-- totality audit knows an unwrapped value satisfies it.
wrapperDefinition :: Wrapper -> FunctionDefinition
wrapperDefinition w = FunctionDefinition (wrapperValueName (wrapperName w))
  [("wrapped", wrapperType w)] result []
  (MatchExpr (Var "wrapped") [MatchBranch (wrapperName w) ["value"] (Var "value")])
  (wrapperSpan w)
  where
    result = case (wrapperBase w, wrapperPredicate w) of
      (Named base, Just predicate) | isExact base -> Refined "value" (Named base) (Just predicate)
      _ -> wrapperBase w

-- Steps are ordinary adapter declarations. Restating an existing declaration
-- with the same type shares it between workflows; a different type is an error.
declareSteps :: Workflow -> [(String, Type)] -> Either String [(String, Type)]
declareSteps w known = do
  let declared = [(name, ty) | WorkflowStage (DeclaredStep name ty) _ <- workflowStages w]
  when (null (workflowStages w)) (Left (workflowName w ++ ": a workflow needs at least one stage"))
  when (workflowName w `elem` map fst declared)
    (Left (workflowName w ++ ": workflow and step names must be distinct"))
  foldl (\acc (name, ty) -> acc >>= \current -> case lookup name current of
      Nothing -> pure (current ++ [(name, ty)])
      Just previous | previous == ty -> pure current
                    | otherwise -> Left (name ++ ": declared with two different types"))
    (pure known) declared

-- How the workflow reports failure: no failure at all, its own declared error
-- type, or a generated sum with one constructor per failing stage.
data Failure = Total | Declared Type | Generated String
  deriving (Eq)

-- An elaborated workflow: its definition, its laws, and a generated error
-- type when it has one.
data Elaborated = Elaborated FunctionDefinition [Law] (Maybe DataTypeDeclaration)

elaborateWorkflow :: [(String, Type)] -> [String] -> [String] -> Workflow -> Either String Elaborated
elaborateWorkflow env definitions taken w = do
  let name = workflowName w
      context = "workflow " ++ name
      typeOf f = maybe (Left (context ++ ": unknown function " ++ f)) Right (lookup f env)
      unary f = typeOf f >>= \ty -> case ty of
        Arrow a r | not (isArrow r) -> Right (a, r)
        _ -> Left (context ++ ": " ++ f ++ " must take exactly one input")
      generatedName = capital name ++ "Error"
  (input, result) <- case workflowType w of
    Arrow a r | not (isArrow r) -> Right (a, r)
    _ -> Left (context ++ ": the workflow must take exactly one input")
  (failure, output) <- case result of
    Application "Either" [Variable "_", t] -> Right (Generated generatedName, t)
    Application "Either" [Named e, t] | e == generatedName -> Right (Generated generatedName, t)
    Application "Either" [e, t] -> Right (Declared e, t)
    t -> Right (Total, t)
  let errorType = case failure of
        Generated n -> Just (Named n)
        Declared e -> Just e
        Total -> Nothing
      fresh base = head [candidate | n <- [0 :: Int ..], let candidate = base ++ show n, candidate `notElem` taken]
      subject = fresh "workflowInput"
      left x = ConstructLit "Either::Left" [x]
      right x = ConstructLit "Either::Right" [x]
      -- A literal Right or Left decides the match.
      matchEither m _ _ onRight | ConstructLit "Either::Right" [v] <- m = onRight v
      matchEither m _ onLeft _ | ConstructLit "Either::Left" [e] <- m = onLeft e
      matchEither m tag onLeft onRight =
        let e = fresh ("failure" ++ tag)
            v = fresh ("state" ++ tag)
        in MatchExpr m [MatchBranch "Either::Left" [e] (onLeft (Var e)), MatchBranch "Either::Right" [v] (onRight (Var v))]
      call f x = Apply (Var f) x
      -- A stage's failure, mapped by the mapError stages after it, in the
      -- workflow's error type.
      failed stageName maps errorTy constructors tag call' = do
        mapped <- foldM (\ty g -> do
            (a, r) <- unary g
            unless (a == ty) (Left (context ++ ": mapError " ++ g ++ " expects " ++ prettyType a ++ " but the error is " ++ prettyType ty))
            pure r) errorTy maps
        let mapping m = foldl (\expr (g, i) -> matchEither expr (tag ++ "m" ++ show i) (left . call g) right) m (zip maps [0 :: Int ..])
        case failure of
          Total -> Left (context ++ ": " ++ stageName ++ " can fail, so the workflow must return Either")
          Declared e -> do
            unless (mapped == e) (Left (context ++ ": " ++ stageName ++ " fails with " ++ prettyType mapped ++
              " but the workflow fails with " ++ prettyType e ++ "; map it with mapError"))
            pure (constructors, mapping call')
          Generated _ -> do
            let constructor = capital stageName ++ "Failed"
            constructors' <- case lookup constructor constructors of
              Just ty | ty /= mapped -> Left (context ++ ": " ++ constructor ++ " would hold two error types")
                      | otherwise -> pure constructors
              Nothing -> pure (constructors ++ [(constructor, mapped)])
            pure (constructors', matchEither (mapping call') (tag ++ "i") (left . ConstructLit constructor . pure) right)
      -- Walk the stages, threading the state type, the generated
      -- constructors, and the composition so far (an Either when the
      -- workflow can fail).
      go _ state constructors body [] = pure (state, constructors, body, [], [])
      go index state constructors body (WorkflowStage kind range : rest) = do
        let tag = show index
            (maps, rest') = span isMapError rest
            mapNames = [g | WorkflowStage (MapErrorStage g) _ <- maps]
            located = either (\message -> Left (message ++ " (line " ++ show (lineOf range) ++ ")")) Right
            continue state' constructors' body' marks = do
              (final, cs, b, fallible, recoveries) <- go (index + 1) state' constructors' body' rest'
              let (f, r) = marks
              pure (final, cs, b, f ++ fallible, r ++ recoveries)
        case kind of
          MapErrorStage g -> located (Left (context ++ ": mapError " ++ g ++ " must follow a stage that can fail"))
          _ | not (null mapNames), not (fallibleKind kind) -> located (Left (context ++ ": mapError must follow a stage that can fail"))
          DeclaredStep f _ -> stepStage f tag state constructors body mapNames >>= \(s', cs, b, label) -> continue s' cs b ([label | label /= ""], [])
          StepStage f -> stepStage f tag state constructors body mapNames >>= \(s', cs, b, label) -> continue s' cs b ([label | label /= ""], [])
          MapStage f -> do
            (a, r) <- unary f
            unless (a == state) (located (Left (context ++ ": map " ++ f ++ " expects " ++ prettyType a ++ " but receives " ++ prettyType state)))
            when (isEither r) (located (Left (context ++ ": map " ++ f ++ " can fail; make it a step")))
            continue r constructors (onSuccess body tag (\v -> wrap (call f v))) ([], [])
          TapStage f -> do
            (a, r) <- unary f
            unless (a == state) (located (Left (context ++ ": tap " ++ f ++ " expects " ++ prettyType a ++ " but receives " ++ prettyType state)))
            case r of
              Application "Either" [e, _] -> do
                (cs, failing) <- located (failed f mapNames e constructors tag (call f (Var "__state")))
                let b = bindState body tag (\v -> matchEither (substitute v failing) (tag ++ "t") left (const (right v)))
                continue state cs b ([f], [])
              _ -> do
                -- An infallible side step: checked forces its result.
                let forced v = Apply (Var "prelude.checked") (call f v)
                continue state constructors (onSuccess body tag (\v -> Apply (Apply (Apply (Var "prelude.select") (forced v)) (wrap v)) (wrap v))) ([], [])
          EnsureStage p f -> do
            (a, r) <- unary p
            unless (a == state && r == Named "Bool") (located (Left (context ++ ": ensure " ++ p ++ " must take " ++ prettyType state ++ " to Bool")))
            unless (f `elem` definitions) (located (Left (context ++ ": ensure's else " ++ f ++ " must be a checked definition")))
            (fa, fe) <- unary f
            unless (fa == state) (located (Left (context ++ ": ensure's else " ++ f ++ " expects " ++ prettyType fa ++ " but receives " ++ prettyType state)))
            (cs, failing) <- located (failed p mapNames fe constructors tag (left (call f (Var "__state"))))
            let b = bindState body tag (\v -> Apply (Apply (Apply (Var "prelude.select") (call p v)) (right v)) (substitute v failing))
            continue state cs b ([p], [])
          OrElseStage h -> do
            e <- maybe (located (Left (context ++ ": orElse " ++ h ++ " needs a workflow that can fail"))) Right errorType
            (a, r) <- unary h
            unless (a == e && r == Application "Either" [e, state])
              (located (Left (context ++ ": orElse " ++ h ++ " must take " ++ prettyType e ++ " to " ++ prettyType (Application "Either" [e, state]))))
            continue state constructors (matchEither body tag (call h) right) ([], [h])
          FallbackStage h -> do
            e <- maybe (located (Left (context ++ ": fallback " ++ h ++ " needs a workflow that can fail"))) Right errorType
            (a, r) <- unary h
            unless (a == e && r == state)
              (located (Left (context ++ ": fallback " ++ h ++ " must take " ++ prettyType e ++ " to " ++ prettyType state)))
            continue state constructors (matchEither body tag (right . call h) right) ([], [h])
      fallibleWorkflow = failure /= Total
      wrap v = if fallibleWorkflow then right v else v
      -- Continue on success; a failure passes through unchanged.
      onSuccess body tag k = if fallibleWorkflow then matchEither body tag left k else k body
      bindState body tag k = matchEither body tag left k
      stepStage f tag state constructors body maps = do
        (a, r) <- unary f
        unless (a == state) (Left (context ++ ": step " ++ f ++ " expects " ++ prettyType a ++ " but receives " ++ prettyType state))
        case r of
          Application "Either" [e, next] -> do
            (cs, failing) <- failed f maps e constructors tag (call f (Var "__state"))
            pure (next, cs, bindState body tag (\v -> substitute v failing), f)
          _ -> pure (r, constructors, onSuccess body tag (\v -> wrap (call f v)), "")
  (final, constructors, body, fallibleStages, recoveries) <- go (0 :: Int) input []
    (if failure == Total then Var subject else right (Var subject)) (workflowStages w)
  unless (final == output)
    (Left (context ++ ": the stages produce " ++ prettyType final ++ " but the workflow returns " ++ prettyType output))
  let definition = FunctionDefinition name [(subject, input)] (workflowResult failure output) [] body (workflowSpan w)
      Span start _ = workflowSpan w
      x = Var subject
      lawFor title description proposition =
        Law (name ++ " " ++ title) [] [] (Forall [(subject, input)] proposition) description
          "LawSpec generates the workflow; this law checks every target runs it as specified" [] [] start
      isLeft m = Apply (Var "prelude.isLeft") m
      isRight m = Apply (Var "prelude.isRight") m
      errorOf m = matchEither m "e" (\e -> ConstructLit "Maybe::Just" [e]) (const (ConstructLit "Maybe::Nothing" []))
      composition = lawFor "composes its stages" (name ++ " is the composition of its stages")
        (Equal (call name x) body)
      -- The composition up to and including a stage, as an Either.
      prefixUpTo stageName = prefixBody stageName
      prefixBody stageName = do
        let upTo = takeThrough stageName (workflowStages w)
        (_, _, b, _, _) <- go (0 :: Int) input [] (right x) upTo
        pure b
      laterRecovery stageName = any recovery (dropThrough stageName (workflowStages w))
      shortCircuits = [ lawFor ("stops when " ++ f ++ " fails")
                          ("when " ++ f ++ " fails, " ++ name ++ " fails with its error")
                          <$> ((\p -> Implies (isLeft p) (Equal (errorOf (call name x)) (errorOf p))) <$> prefixUpTo f)
                      | fallibleWorkflow, f <- fallibleStages, not (laterRecovery f) ]
      recoveryLaws = [ lawFor ("recovers with " ++ h) ("after a failure, " ++ h ++ " decides the result")
                         <$> ((\p -> Implies (isLeft p) (Equal (call name x) body)) <$> prefixBefore h)
                     | h <- recoveries ]
      prefixBefore h = do
        let upTo = takeWhile (not . isRecovery h) (workflowStages w)
        (_, _, b, _, _) <- go (0 :: Int) input [] (right x) upTo
        pure b
      success = [ lawFor "succeeds when every stage does" (name ++ " returns the composition of its successes")
                    (Implies (isRight body) (Equal (call name x) body))
                | fallibleWorkflow, null recoveries ]
  laws' <- sequence (shortCircuits ++ recoveryLaws)
  let generated = case failure of
        Generated n -> Just (DataTypeDeclaration n []
          [ConstructorDeclaration c [("error", t)] (workflowSpan w) [] | (c, t) <- constructors] (workflowSpan w) Nothing)
        _ -> Nothing
  when (failure /= Total && null constructors && case failure of Generated _ -> True; _ -> False)
    (Left (context ++ ": no stage can fail, so the workflow returns " ++ prettyType output))
  pure (Elaborated definition (map railwayLaw ([composition] ++ success ++ laws')) generated)
  where
    isArrow (Arrow _ _) = True
    isArrow _ = False
    isEither (Application "Either" [_, _]) = True
    isEither _ = False
    isMapError (WorkflowStage (MapErrorStage _) _) = True
    isMapError _ = False
    fallibleKind k = case k of
      DeclaredStep _ _ -> True
      StepStage _ -> True
      TapStage _ -> True
      EnsureStage _ _ -> True
      _ -> False
    recovery (WorkflowStage k _) = case k of OrElseStage _ -> True; FallbackStage _ -> True; _ -> False
    isRecovery h (WorkflowStage k _) = case k of OrElseStage n -> n == h; FallbackStage n -> n == h; _ -> False
    stageFunction k = case k of
      DeclaredStep f _ -> Just f
      StepStage f -> Just f
      TapStage f -> Just f
      EnsureStage p _ -> Just p
      _ -> Nothing
    takeThrough f stages = let (before, after) = break ((== Just f) . stageFunction . stageKindOf) stages
                           in before ++ take 1 after ++ takeWhile isMapError (drop 1 after)
    dropThrough f stages = drop (length (takeThrough f stages)) stages
    stageKindOf (WorkflowStage k _) = k
    lineOf (Span (Location _ l _) _) = l
    workflowResult Total t = t
    workflowResult (Declared e) t = Application "Either" [e, t]
    workflowResult (Generated n) t = Application "Either" [Named n, t]
    substitute v = replaceExprVars [("__state", v)]

capital :: String -> String
capital (c : rest) = toUpper c : rest
capital [] = []
