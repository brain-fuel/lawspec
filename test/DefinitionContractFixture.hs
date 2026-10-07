module DefinitionContractFixture (validUnits, invalidUnits, fixtureUnits) where

import LawSpec.Core
import LawSpec.Common (Source(..), defaultGeneration)
import LawSpec.Frontend (compileCore)
import System.Environment (lookupEnv)
import Data.List (sortOn)
import LawSpec.Core.Validate (operationEvidence)
import LawSpec.Scalar (Scalar(..))

origin = GeneratedFrom (Id "contract-fixture")
int = scalarType "Int8"
integer = scalarType "Integer"
local n t = Expr t (Local (Id n)) origin
number n = Expr integer (Constant (SInteger "Integer" n)) origin
op operation a b =
  let evidence = either error id (operationEvidence operation (expressionType a) (expressionType b))
      ty = if isComparison operation then scalarType "Bool" else case evidence of Numeric t -> t; Structural t -> t
  in Expr ty (Binary operation evidence a b) origin
make name body = Definition (Declaration (Id name) name (Arrow int (expressionType body)) origin)
  [Binder (Id "bodyArgument") "value" int] body
boundary d pre post = Contract (declarationId (definitionDeclaration d))
  [Binder (Id "contractArgument") "input" int]
  (Binder (Id "contractResult") "output" (expressionType (definitionBody d))) pre post []
x = local "bodyArgument" int
arg = local "contractArgument" int

validUnits :: [Unit]
validUnits = fst fixture
invalidUnits :: [[Unit]]
invalidUnits = snd fixture

fixture :: ([Unit], [[Unit]])
fixture =
  let next = make "next" (op Add x (number 1))
      reciprocal = make "reciprocal" (op Divide (number 1) x)
      ordered = make "ordered" x
      narrow = make "narrow" (Expr int (Convert Explicit int (op Add x (number 1))) origin)
      caller = make "caller" (Expr integer (ExternalCall (Id "next") [x]) origin)
      definitions = [next,reciprocal,ordered,narrow,caller]
      positive = op Greater arg (number 0)
      nonzero = op NotEqual arg (number 0)
      nextBoundary = boundary next [positive]
        [op Greater (local "contractResult" integer) (number 1)]
      contracts = [nextBoundary,boundary reciprocal [nonzero] [],
        boundary ordered [nonzero,op Greater (op Divide (number 1) arg) (number 0)] [],
        boundary narrow [op Less arg (number 127)] [],boundary caller [positive] []]
      unit cs = Unit (Id "fixture") (map definitionDeclaration definitions) cs [] definitions []
      wrong = nextBoundary{contractPostconditions=[op Less (local "contractResult" integer) (number 0)]}
  in ([unit contracts], [[unit (contracts ++ [nextBoundary])], [unit (wrong : drop 1 contracts)]])

-- | Preserve the first five logical slots used by the native harnesses; any
-- helper instances discovered through source specialization follow them.
fixtureUnits :: Int -> IO [Unit]
fixtureUnits bits = do
  mode <- lookupEnv "LAWSPEC_CONTRACT_SOURCE"
  units <- if mode /= Just "1" then pure validUnits else do
    source <- readFile "test/fixtures/definition_contracts.lawspec"
    program <- either (fail . show) pure
      (compileCore bits defaultGeneration [Source "definition_contracts.lawspec" source])
    let order d = maybe 5 id (lookup (declarationName (definitionDeclaration d))
          (zip ["next","reciprocal","ordered","narrow","caller"] [0::Int ..]))
    pure [unit{unitDefinitions=sortOn order (unitDefinitions unit)} | unit <- programUnits program]
  source <- readFile "test/fixtures/list_contracts.lawspec"
  program <- either (fail . show) pure
    (compileCore bits defaultGeneration [Source "list_contracts.lawspec" source])
  let extras = programUnits program
      extend unit = let base = addListPredicates unit in base
        { unitDefinitions = unitDefinitions base ++ concatMap unitDefinitions extras
        , unitDeclarations = unitDeclarations base ++ concatMap unitDeclarations extras
        , unitContracts = unitContracts base ++ concatMap unitContracts extras
        }
  pure (map extend units)

-- | Core-only operations stay executable before their surface syntax is enabled.
addListPredicates :: Unit -> Unit
addListPredicates unit = unit
  { unitDefinitions = unitDefinitions unit ++ definitions
  , unitDeclarations = unitDeclarations unit ++ map definitionDeclaration definitions
  }
  where
    boolean = scalarType "Bool"
    list element = Constructor "List" [TypeArgument element]
    allOf source binder predicate = Expr boolean (AllElements source binder predicate) origin
    element = Binder (Id "listElement") "element" int
    item = local "listElement" int
    positive = Expr boolean (ShortCircuit And (op NotEqual item (number 0))
      (op Greater (op Divide (number 1) item) (number 0))) origin
    row = Binder (Id "listRow") "row" (list int)
    rowValue = local "listRow" (list int)
    lengthRow = Expr integer (Helper Length [rowValue]) origin
    makeList name ty body = Definition
      (Declaration (Id name) name (Arrow ty boolean) origin)
      [Binder (Id "listInput") "input" ty] body
    definitions =
      [makeList "allpositive" (list int)
        (allOf (local "listInput" (list int)) element positive),
       makeList "nestedabove" (list (list int))
        (allOf (local "listInput" (list (list int))) row
          (allOf rowValue element (op Greater item lengthRow)))]
