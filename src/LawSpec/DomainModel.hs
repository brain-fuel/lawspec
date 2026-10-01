-- Domain modeling declarations elaborate before inference, like indexed
-- families. A wrapper is a nominal single-field type whose constructor is a
-- checked contract, so an invalid value cannot be constructed. A workflow is a
-- typed pipeline of adapter steps between distinct state types, with a law that
-- the workflow equals the railway composition of its steps.
module LawSpec.DomainModel
  ( Wrapper(..), Workflow(..), WorkflowStep(..)
  , wrapperValueName, elaborateDomain
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.List (nub)
import LawSpec.Model

data Wrapper = Wrapper
  { wrapperName :: String
  , wrapperParameters :: [String]
  , wrapperBase :: Type
  , wrapperPredicate :: Maybe Expr
  , wrapperSpan :: Span
  } deriving (Eq, Show)

data WorkflowStep = WorkflowStep
  { stepName :: String, stepType :: Type, stepSpan :: Span } deriving (Eq, Show)

data Workflow = Workflow
  { workflowName :: String
  , workflowType :: Type
  , workflowSteps :: [WorkflowStep]
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
  declared <- foldl (\acc w -> acc >>= at w . declareWorkflow w) (pure (functions u)) workflows
  laws' <- forM workflows (\w -> at w (workflowLaw (map fst declared ++ map functionName unwrap) w))
  pure u
    { dataTypes = map wrapperDeclaration wrappers ++ dataTypes u
    , functions = [(functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))) | d <- unwrap] ++ declared
    , functionDefinitions = unwrap ++ functionDefinitions u
    , declarationSpans = [(functionName d, functionSpan d) | d <- unwrap] ++
        [(workflowName w, workflowSpan w) | w <- workflows] ++
        [(stepName s, stepSpan s) | w <- workflows, s <- workflowSteps w] ++ declarationSpans u
    , laws = laws u ++ laws'
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

wrapperDefinition :: Wrapper -> FunctionDefinition
wrapperDefinition w = FunctionDefinition (wrapperValueName (wrapperName w))
  [("wrapped", wrapperType w)] (wrapperBase w) []
  (MatchExpr (Var "wrapped") [MatchBranch (wrapperName w) ["value"] (Var "value")])
  (wrapperSpan w)

-- Steps are ordinary adapter declarations. Restating an existing declaration
-- with the same type shares it between workflows; a different type is an error.
declareWorkflow :: Workflow -> [(String, Type)] -> Either String [(String, Type)]
declareWorkflow w known = do
  let names = workflowName w : map stepName (workflowSteps w)
  when (null (workflowSteps w)) (Left (workflowName w ++ ": a workflow needs at least one step"))
  unless (length (nub names) == length names)
    (Left (workflowName w ++ ": workflow and step names must be distinct"))
  foldl (\acc (name, ty) -> acc >>= \current -> case lookup name current of
      Nothing -> pure (current ++ [(name, ty)])
      Just previous | previous == ty -> pure current
                    | otherwise -> Left (name ++ ": declared with two different types"))
    (pure known) ((workflowName w, workflowType w) : [(stepName s, stepType s) | s <- workflowSteps w])

-- A fallible step returns Either E T. All fallible steps share one error type,
-- and a Left from any step is the workflow's result.
data Stage = Stage { stageName :: String, stageFallible :: Bool }

workflowLaw :: [String] -> Workflow -> Either String Law
workflowLaw taken w = do
  let name = workflowName w
      context = "workflow " ++ name
  (input, result) <- case workflowType w of
    Arrow a r | not (isArrow r) -> Right (a, r)
    _ -> Left (context ++ ": the workflow must take exactly one input")
  (stages, current, failure) <- chainTypes context input (workflowSteps w)
  let expected = maybe current (\e -> Application "Either" [e, current]) failure
  unless (expected == result)
    (Left (context ++ ": the steps produce " ++ prettyType expected ++
      " but the workflow returns " ++ prettyType result))
  let fresh base = head [candidate | n <- [0 :: Int ..], let candidate = base ++ replicate n '_',
                                     candidate `notElem` taken]
      subject = fresh "workflowInput"
      anyFallible = any stageFallible stages
      compose [] value = if anyFallible then ConstructLit "Right" [value] else value
      compose ((index, stage) : rest) value
        | stageFallible stage =
            let failed = fresh ("failure" ++ show index)
                state = fresh ("state" ++ show index)
                call = Apply (Var (stageName stage)) value
            in if null rest
              then call
              else MatchExpr call
                [ MatchBranch "Left" [failed] (ConstructLit "Left" [Var failed])
                , MatchBranch "Right" [state] (compose rest (Var state)) ]
        | otherwise = compose rest (Apply (Var (stageName stage)) value)
      body = compose (zip [1 :: Int ..] stages) (Var subject)
      Span start _ = workflowSpan w
      description = name ++ " is the " ++ (if anyFallible then "railway " else "") ++
        "composition of " ++ unwords (map stageName stages)
  pure (Law (name ++ " composes its steps") [] []
    (Forall [(subject, input)] (Equal (Apply (Var name) (Var subject)) body))
    description "each step moves the domain value to its next state" [] [] start)
  where
    isArrow (Arrow _ _) = True
    isArrow _ = False

chainTypes :: String -> Type -> [WorkflowStep] -> Either String ([Stage], Type, Maybe Type)
chainTypes context start = go start Nothing []
  where
    go current failure stages [] = Right (reverse stages, current, failure)
    go current failure stages (step : rest) = do
      (argument, output) <- case stepType step of
        Arrow a r | not (isArrow r) -> Right (a, r)
        _ -> Left (context ++ ": step " ++ stepName step ++ " must take exactly one input")
      unless (argument == current)
        (Left (context ++ ": step " ++ stepName step ++ " expects " ++ prettyType argument ++
          " but receives " ++ prettyType current))
      case output of
        Application "Either" [e, next] -> do
          forM_ failure $ \previous -> unless (previous == e)
            (Left (context ++ ": step " ++ stepName step ++ " fails with " ++ prettyType e ++
              " but earlier steps fail with " ++ prettyType previous))
          go next (Just e) (Stage (stepName step) True : stages) rest
        _ -> go output failure (Stage (stepName step) False : stages) rest
    isArrow (Arrow _ _) = True
    isArrow _ = False
