-- | The capability laws tested on sample functions, besides being proved
-- over unknown ones. Each sample set puts concrete types in place of the
-- laws' unknown types and functions of LawSpec.Instances' samples unit in
-- place of their unknown functions, as citing a law does
-- (LawSpec.Core.SmtRestate). Every law is then run by the reference
-- evaluator on every small input, two ways: with the evaluator's own
-- operations, and with each operation replaced by its instance definition
-- as the solver sees it (LawSpec.Core.SmtInstances). The second is what the
-- proofs are about, so a wrong instance definition is caught on concrete
-- values as well as by the solver. These are tests, and are reported as
-- tests: they hold on the samples, which the proof does not need.
-- ref:DEC-capability-laws
module LawSpec.CapabilitySamples
  ( SampleSet(..), SampleView(..), SampleOutcome(..), SampleResult(..)
  , sampleSets, sampleCapabilityLaws, sampleCapabilityLawsWith
  ) where

import Control.Monad (foldM)
import Control.Monad.State.Strict (State, get, put, runState)
import Data.List (find, isSuffixOf)
import Data.Tuple (swap)
import qualified Data.Map.Strict as M
import LawSpec.CapabilityLaws (capabilityLawsSourcesProgram)
import LawSpec.Common (Quantification(..))
import LawSpec.Core
import LawSpec.Core.Definitions (prepareHookedDefinitions)
import LawSpec.Core.Eval (evaluateValue, evaluateValueProposition)
import LawSpec.Core.SmtInstances (Instance(..), instanceArguments, instanceKey, instanceOf)
import LawSpec.Core.SmtRestate (Restatement(..), inlineDefinitions, mapProposition, restatedAt)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Value (Value(..), listValue)
import LawSpec.Instances (instanceLawsUnit, instanceSamplesSource, instanceSamplesUnit)
import LawSpec.Scalar (Scalar(..))

-- | Types for the laws' unknown types and sample functions for their
-- unknown functions, by name.
data SampleSet = SampleSet
  { sampleSetName :: String
  , sampleTypes :: [(String, Type)]
  , sampleFunctions :: [(String, String)] }

-- | How the law's operations are run: by the reference evaluator's own
-- operations, or through their instance definitions.
data SampleView = EvaluatorOperations | InstanceDefinitions deriving (Eq, Show)

data SampleOutcome
  = SampleHolds Int
  | SampleFails [(String, Value)] String
  deriving (Eq, Show)

data SampleResult = SampleResult
  { sampledLaw :: String, sampledSet :: String, sampledView :: SampleView, sampledOutcome :: SampleOutcome }
  deriving (Eq, Show)

-- | Three sets: integers throughout; integers again with a function that
-- sends every element to one value and predicates that keep everything or
-- nothing; and text elements mapped to integers, then to Booleans, then
-- back to text.
sampleSets :: [SampleSet]
sampleSets =
  [ SampleSet "integers"
      (handles integer integer integer integer text)
      [ ("first", "increment"), ("second", "double"), ("third", "opposite")
      , ("accepts", "isEven"), ("alsoAccepts", "isPositive"), ("acceptsMapped", "isPositive")
      , ("combineLeft", "shiftIn"), ("combineRight", "takeFrom"), ("partial", "halve") ]
  , SampleSet "a constant map and predicates that keep everything or nothing"
      (handles integer integer integer integer text)
      [ ("first", "zero"), ("second", "increment"), ("third", "double")
      , ("accepts", "always"), ("alsoAccepts", "never"), ("acceptsMapped", "isEven")
      , ("combineLeft", "shiftIn"), ("combineRight", "takeFrom"), ("partial", "halve") ]
  , SampleSet "text"
      (handles text integer bool text bool)
      [ ("first", "textLength"), ("second", "isEven"), ("third", "describe")
      , ("accepts", "isEmpty"), ("alsoAccepts", "isShort"), ("acceptsMapped", "isPositive")
      , ("combineLeft", "appendTo"), ("combineRight", "prependTo"), ("partial", "measure") ] ]
  where
    integer = scalarType "Integer"
    text = scalarType "Text"
    bool = scalarType "Bool"
    handles element mapped further folded failure =
      [("Element", element), ("Mapped", mapped), ("Further", further), ("Folded", folded), ("Failure", failure)]

-- | Every capability law at every sample set, both ways.
sampleCapabilityLaws :: Either String [SampleResult]
sampleCapabilityLaws = sampleCapabilityLawsWith instanceOf

-- | As 'sampleCapabilityLaws', with the instance definitions found by the
-- given function, so a test can give a wrong one.
sampleCapabilityLawsWith :: (Expr -> Maybe Instance) -> Either String [SampleResult]
sampleCapabilityLawsWith instances = do
  program <- capabilityLawsSourcesProgram [("<lawspec.instances.samples>", instanceSamplesSource)]
  laws <- unitNamed program instanceLawsUnit
  samples <- unitNamed program instanceSamplesUnit
  registry <- makeRegistry (programDataDeclarations program)
  hooked <- either (Left . concatMap show) Right (prepareHookedDefinitions program)
  let bits = programMachineBits program
  sequence
    [ result
    | law <- unitProperties laws
    , set <- sampleSets
    , view <- [EvaluatorOperations, InstanceDefinitions]
    , let result = do
            restated <- restate laws samples set law
            outcome <- run registry bits hooked view restated
            pure (SampleResult (propertyName law) (sampleSetName set) view outcome) ]
  where
    run registry bits hooked view restated =
      let (inputs, claim) = peel (restatedInputs restated) (restatedBody restated)
          (definitions, claim') = case view of
            EvaluatorOperations -> (M.empty, claim)
            InstanceDefinitions -> swap (runState (traverseProposition (rewrite instances) claim) M.empty)
          defined = M.fromList [(name, d) | (name, d) <- M.elems definitions]
          invoke = hooked (\recurse name -> case M.lookup name defined of
            Just d -> Just (\arguments ->
              evaluateValue registry bits recurse (zip (map binderId (definitionArguments d)) arguments) (definitionBody d))
            Nothing -> Nothing)
      in do
        domains <- mapM (domain . binderType . quantifiedBinder) inputs
        foldM (\outcome values -> case outcome of
            SampleHolds n -> do
              let env = zip (map (binderId . quantifiedBinder) inputs) values
                  at = zip (map (binderName . quantifiedBinder) inputs) values
              pure (case evaluateValueProposition registry bits invoke env claim' of
                Right True -> SampleHolds (n + 1)
                Right False -> SampleFails at "the law is false at these values"
                Left message -> SampleFails at ("the law is undefined at these values: " ++ message))
            failed -> pure failed)
          (SampleHolds 0) (cases budget domains)

    -- The law's for-all inputs, wherever they are written.
    peel known claim = case claim of
      Quantified ForEvery q rest -> peel (known ++ [q]) rest
      _ -> (known, claim)

-- | Every choice of a value per input whose lists hold, together, at most
-- the budget's elements.
cases :: Int -> [[(Int, Value)]] -> [[Value]]
cases _ [] = [[]]
cases left (choices : rest) =
  [ value : more | (size, value) <- choices, size <= left, more <- cases (left - size) rest ]

budget :: Int
budget = 4

-- | The values an input ranges over, each with the number of list elements
-- it holds.
domain :: Type -> Either String [(Int, Value)]
domain ty = case ty of
  Constructor "Integer" [] -> Right [(0, ScalarValue (SInteger "Integer" n)) | n <- [-1, 0, 1, 2]]
  Constructor "Text" [] -> Right [(0, ScalarValue (SSequence "Text" (map fromEnum t))) | t <- ["", "a", "bc"]]
  Constructor "Bool" [] -> Right [(0, ScalarValue (SBool b)) | b <- [False, True]]
  Constructor "List" [TypeArgument element] -> do
    elements <- map snd <$> domain element
    let lists n = if n == 0 then [[]] else [x : xs | x <- elements, xs <- lists (n - 1)]
    pure [(n, listValue element xs) | n <- [0 .. budget], xs <- lists n]
  _ -> Left ("no sample values of " ++ show ty)

-- | The law with the set's types and functions in place of its unknown ones.
restate :: Unit -> Unit -> SampleSet -> Property -> Either String Restatement
restate laws samples set law = do
  let named suffix = (instanceLawsUnit ++ "::" ++ suffix)
      table = M.fromList [(named ("type::" ++ handle), t) | (handle, t) <- sampleTypes set]
  chosen <- mapM (\(adapter, sample) -> do
      d <- maybe (Left ("no sample function " ++ sample)) Right
        (find ((("::" ++ sample) `isSuffixOf`) . idText . declarationId . definitionDeclaration) (unitDefinitions samples))
      let binders = [Binder (Id ("lawspec_sample_" ++ adapter ++ "_" ++ show i)) (binderName b) (binderType b)
                    | (i, b) <- zip [0 :: Int ..] (definitionArguments d)]
          call = Expr (expressionType (definitionBody d))
            (ExternalCall (declarationId (definitionDeclaration d)) [Expr (binderType b) (Local (binderId b)) origin | b <- binders]) origin
      pure (Id (named adapter), (binders, call)))
    (sampleFunctions set)
  let inline = inlineDefinitions laws
      quantifiers = [q { quantifiedPredicates = map inline (quantifiedPredicates q) } | q <- propertyParameters law ++ propertyInputs law]
  pure (restatedAt table chosen (map snd chosen) quantifiers (mapProposition id inline (propertyBody law)))
  where
    origin = GeneratedFrom (Id instanceSamplesUnit)

-- | Each operation replaced, innermost first, by a call of its instance
-- definition; equal definitions share one name.
rewrite :: (Expr -> Maybe Instance) -> Expr -> State (M.Map String (Id, Definition)) Expr
rewrite instances e = do
  e' <- traverseChildren (rewrite instances) e
  case instances e' of
    Nothing -> pure e'
    Just found -> do
      known <- get
      let key = instanceKey found
      name <- case M.lookup key known of
        Just (name, _) -> pure name
        Nothing -> do
          let name = Id ("lawspec.instances.sample#" ++ show (M.size known))
          put (M.insert key (name, instanceDefinition found name) known)
          pure name
      pure (Expr (expressionType e') (ExternalCall name (instanceArguments found)) (expressionOrigin e'))

traverseProposition :: (Expr -> State s Expr) -> Proposition -> State s Proposition
traverseProposition f claim = case claim of
  Equation evidence a b -> Equation evidence <$> f a <*> f b
  Implication guard rest -> Implication <$> f guard <*> traverseProposition f rest
  Conjunction claims -> Conjunction <$> mapM (traverseProposition f) claims
  Negation rest -> Negation <$> traverseProposition f rest
  Quantified kind q rest -> Quantified kind q <$> traverseProposition f rest

unitNamed :: Program -> String -> Either String Unit
unitNamed program name = maybe (Left ("no unit " ++ name)) Right
  (find ((== Id name) . unitId) (programUnits program))
