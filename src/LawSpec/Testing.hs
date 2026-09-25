-- Execution feasibility and deterministic cases are planned after elaboration.
-- This module consumes only typed core, never surface syntax or inference.
module LawSpec.Testing where
import LawSpec.Core
import LawSpec.Common
import LawSpec.Scalar
import LawSpec.Core.Eval (evaluatePure)
import LawSpec.Core.Validate (validateProgram)
import Control.Monad (filterM, unless)

data Plan = Plan { planMachineBits :: Int, plannedUnits :: [PlannedUnit] } deriving (Eq, Show)
data PlannedUnit = PlannedUnit { plannedUnit :: Unit, plannedProperties :: [PlannedProperty] } deriving (Eq, Show)
data PlannedProperty = PlannedProperty
  { plannedProperty :: Property, finiteCases :: Maybe [[Scalar]], boundaryCases :: [[Scalar]]
  , generatorRequirements :: [GeneratorRequirement]
  } deriving (Eq, Show)
data GeneratorRequirement = GeneratorRequirement { generatorBinder :: Binder, generatorPredicates :: [Expr], generatorBoundaries :: [Scalar], generatorBounds :: [(BinaryOp,Expr)], generatorHints :: [Expr] } deriving (Eq, Show)

planTesting :: Program -> Either [Diagnostic] Plan
planTesting program@Program{..} = do
  validateProgram program
  Plan programMachineBits <$> mapM unit programUnits
  where
    unit u = PlannedUnit u <$> mapM property (unitProperties u)
    property p = either (Left . pure . (\m -> Diagnostic "generation" m (Just (propertyLocation p)))) Right $ do
      let qs = propertyInputs p
          settings = propertyGeneration p
          types = map (binderType . quantifiedBinder) qs
      mapM_ supported types
      mapM_ (\e -> if null (freeBinders e) then do
          v <- evaluatePure programMachineBits [] e
          unless (v == SBool True) (Left "refined input domain has no valid tuples")
        else Right ()) (concatMap quantifiedPredicates qs)
      finite <- case mapM (finiteValues programMachineBits (exhaustiveLimit settings)) types of
        Just sets | product (map (toInteger . length) sets) <= toInteger (exhaustiveLimit settings) -> Just <$> filterM (validTuple programMachineBits qs) (sequence sets)
        _ -> Right Nothing
      unless (finite /= Just []) (Left "refined input domain has no valid tuples")
      let bs = map (boundaries programMachineBits) types
          tuples = if null bs then [[]] else [[xs !! (i `mod` length xs) | xs <- bs] | i <- [0..maximum (map length bs)-1]]
      cases <- filterM (validTuple programMachineBits qs) tuples
      pure (PlannedProperty p finite cases [GeneratorRequirement (quantifiedBinder q) (quantifiedPredicates q) b (quantifiedBounds q) (domainHints q) | (q,b) <- zip qs bs])
    supported (Constructor n []) | Just _ <- primitive n = Right ()
    supported (Constructor n [TypeArgument t]) | n `elem` ["Nullable","Optional"] = supported t
    supported t = Left ("no generator for core type " ++ show t)

validTuple :: Int -> [Quantifier] -> [Scalar] -> Either String Bool
validTuple bits qs values
  | length qs /= length values = Left "input tuple arity mismatch"
  | otherwise = walk [] (zip qs values)
  where
    walk _ [] = Right True
    walk prefix ((q,v):rest) = do
      let env = prefix ++ [(binderId (quantifiedBinder q),v)]
      ok <- allM (\p -> (== SBool True) <$> evaluatePure bits env p) (quantifiedPredicates q)
      if ok then walk env rest else Right False
    allM _ [] = Right True
    allM f (x:xs) = do b <- f x; if b then allM f xs else Right False

finiteValues :: Int -> Int -> Type -> Maybe [Scalar]
finiteValues bits limit t = case t of
  Constructor n []
    | Just (lo,hi) <- integerBounds bits n, hi-lo+1 <= fromIntegral limit -> Just [SInteger n x | x <- [lo..hi]]
    | n `elem` ["Bool","Unit","Null","Undefined"] -> Just (scalarBoundaries bits n)
  Constructor n [TypeArgument a] | n `elem` ["Nullable","Optional"] -> do
    xs <- finiteValues bits (limit-1) a
    pure (SPresent n Nothing:map (SPresent n . Just) xs)
  _ -> Nothing
boundaries :: Int -> Type -> [Scalar]
boundaries bits (Constructor "Text" []) = map textScalar ["", " ", "Hello, World!", "λ日本語😀", "a\n\t\"\\$\0z", "e\x0301"] ++ scalarBoundaries bits "Text"
boundaries bits (Constructor n []) = scalarBoundaries bits n
boundaries bits (Constructor n [TypeArgument t]) = SPresent n Nothing:map (SPresent n . Just) (boundaries bits t)
boundaries _ _ = []

-- Safe comparison operands seed sparse domains without eagerly evaluating a
-- partial expression that the predicate would otherwise guard.
domainHints :: Quantifier -> [Expr]
domainHints q = concatMap walk (quantifiedPredicates q) where
  current = binderId (quantifiedBinder q)
  walk Expr{expressionNode=ShortCircuit _ a b} = concatMap walk [a,b]
  walk Expr{expressionNode=Binary op _ a b} | isComparison op =
    [rhs | (lhs,rhs) <- [(a,b),(b,a)], expressionNode lhs == Local current, current `notElem` freeBinders rhs, safe rhs]
  walk _ = []
  safe e = case expressionNode e of
    Constant _ -> True
    Local _ -> True
    Binary op _ a b | op `elem` [Add,Subtract,Multiply,Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual] -> safe a && safe b
    Binary op _ a Expr{expressionNode=Constant b} | op `elem` [Divide,Quotient,Remainder] -> safe a && either (const False) (/=0) (exactValue b)
    Unary _ a -> safe a
    _ -> False
