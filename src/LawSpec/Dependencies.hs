-- The dependency graph of a Core program, for incremental compilation.
--
-- Nodes are data types and declarations; a declaration's node also holds its
-- contract and, for a checked definition, its body. Edges are references: the
-- types a type's fields, equations and predicates name, and the types,
-- constructors and calls in a declaration's signature, contract and body.
--
-- Each node gets a Merkle digest: the digest of its own content together with
-- the digests of everything it references. Recursive types and mutually
-- recursive definitions form strongly connected groups, which are digested
-- as one. So a node's digest changes exactly when something it can reach
-- changes, and a law's work can be keyed by what the law reaches rather than
-- by the whole program.
module LawSpec.Dependencies
  ( Graph, Ref(..), dependencyGraph, references, closure, nodeDigest
  , lawReferences, unitReferences, reachableData, reachableDefinitions, keyOf
  ) where

import qualified Data.Graph as G
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Digest

data Ref = TypeNode Id | DeclarationNode Id deriving (Eq, Ord, Show)

data Graph = Graph
  { graphEdges :: M.Map Ref [Ref]
  , graphDigests :: M.Map Ref Digest
  , graphData :: M.Map Id DataDeclaration
  , graphDefinitions :: M.Map Id Definition
  , graphOwners :: M.Map Id Id
  -- Each spec handler's clause definitions: a law run under a handler
  -- reaches them.
  , graphHandlers :: M.Map Id [Id]
  }

dependencyGraph :: [DataDeclaration] -> [Unit] -> Graph
dependencyGraph dataDeclarations units = Graph edges digests dataTable definitionTable owners handlerTable
  where
    handlerTable = M.fromList [(handlerId h, map snd (handlerClauses h)) | u <- units, h <- unitHandlers u]
    dataTable = M.fromList [(dataId d, d) | d <- dataDeclarations]
    definitionTable = M.fromList [(declarationId (definitionDeclaration d), d) | u <- units, d <- unitDefinitions u]
    contractTable = M.fromList [(contractDeclaration c, c) | u <- units, c <- unitContracts u]
    declarationTable = M.fromList ([(declarationId d, d) | u <- units, d <- unitDeclarations u] ++
      [(declarationId (definitionDeclaration d), definitionDeclaration d) | d <- M.elems definitionTable])
    owners = M.fromList [(constructorId c, dataId d) | d <- dataDeclarations, c <- dataConstructors d]
    known node = case node of
      TypeNode i -> M.member i dataTable
      DeclarationNode i -> M.member i declarationTable
    -- Each node's own content and direct references.
    nodes = [ (TypeNode i, show d, dataReferences owners d) | (i, d) <- M.toList dataTable ] ++
      [ (DeclarationNode i, show (d, M.lookup i contractTable, M.lookup i definitionTable)
        , declarationReferences owners d (M.lookup i contractTable) (M.lookup i definitionTable))
      | (i, d) <- M.toList declarationTable ]
    edges = M.fromList [ (node, S.toList (S.fromList (filter known refs))) | (node, _, refs) <- nodes ]
    contents = M.fromList [ (node, content) | (node, content, _) <- nodes ]
    -- Dependencies come before their dependents.
    groups = G.stronglyConnComp [ (node, node, M.findWithDefault [] node edges) | (node, _, _) <- nodes ]
    digests = foldl addGroup M.empty groups
    addGroup done group =
      let members = sort (G.flattenSCC group)
          inside = S.fromList members
          outside = S.toList (S.fromList [ dep | m <- members, dep <- M.findWithDefault [] m edges, not (S.member dep inside) ])
          groupDigest = digestString (show ( [ (m, M.findWithDefault "" m contents) | m <- members ]
                                           , [ (dep, M.lookup dep done) | dep <- outside ] ))
      in foldr (\m -> M.insert m groupDigest) done members

nodeDigest :: Graph -> Ref -> Maybe Digest
nodeDigest graph node = M.lookup node (graphDigests graph)

-- The known nodes among some references, without repeats.
references :: Graph -> [Ref] -> [Ref]
references graph = filter (`M.member` graphEdges graph) . S.toList . S.fromList

-- Everything reachable from some nodes, the nodes included.
closure :: Graph -> [Ref] -> S.Set Ref
closure graph = go S.empty
  where
    go seen [] = seen
    go seen (n : rest)
      | S.member n seen = go seen rest
      | otherwise = go (S.insert n seen) (M.findWithDefault [] n (graphEdges graph) ++ rest)

reachableData :: Graph -> S.Set Ref -> [DataDeclaration]
reachableData graph reached = mapMaybe (\i -> M.lookup i (graphData graph)) [ i | TypeNode i <- S.toList reached ]

reachableDefinitions :: Graph -> S.Set Ref -> [Definition]
reachableDefinitions graph reached = mapMaybe (\i -> M.lookup i (graphDefinitions graph)) [ i | DeclarationNode i <- S.toList reached ]

-- A memo key: the digest of some content together with the Merkle digests of
-- the nodes it references, so it changes exactly when anything reachable does.
keyOf :: Graph -> String -> [Ref] -> String
keyOf graph content refs = digestHex (digestString (show (content, [ (n, nodeDigest graph n) | n <- references graph refs ])))

lawReferences :: Graph -> Property -> [Ref]
lawReferences graph p = references graph $
  concat [ typeRefs (binderType (quantifiedBinder q)) ++ concatMap (exprRefs owners) (quantifiedPredicates q) ++
           concatMap (exprRefs owners . snd) (quantifiedBounds q) | q <- propertyInputs p ] ++
  propositionRefs owners (propertyBody p) ++
  concat [ concatMap (exprRefs owners . snd) (exampleBindings e) ++ concatMap (propositionRefs owners) (exampleExpectations e)
         | e <- propertyExamples p ] ++
  [ DeclarationNode clause | (_, choice) <- propertyHandlers p, h <- specHandlers choice
  , clause <- M.findWithDefault [] h (graphHandlers graph) ]
  where
    owners = graphOwners graph
    specHandlers choice = case choice of
      SpecHandler h -> [h]
      RecordingHandler inner -> specHandlers inner
      ProductionHandler -> []

-- What a unit's declarations, contracts, definitions and laws reference.
unitReferences :: Graph -> Unit -> [Ref]
unitReferences graph u = references graph $
  [ DeclarationNode (declarationId d) | d <- unitDeclarations u ] ++
  [ DeclarationNode (declarationId (definitionDeclaration d)) | d <- unitDefinitions u ] ++
  [ DeclarationNode (contractDeclaration c) | c <- unitContracts u ] ++
  concatMap (lawReferences graph) (unitProperties u)

dataReferences :: M.Map Id Id -> DataDeclaration -> [Ref]
dataReferences owners d = concat
  [ concatMap (typeRefs . binderType) (constructorFields c) ++ concatMap (exprRefs owners) (constructorPredicates c) ++
    concatMap (typeRefs . snd) (constructorEquations c)
  | c <- dataConstructors d ]

declarationReferences :: M.Map Id Id -> Declaration -> Maybe Contract -> Maybe Definition -> [Ref]
declarationReferences owners d contract definition =
  typeRefs (declarationType d) ++
  maybe [] (\c -> concatMap (typeRefs . binderType) (contractArguments c ++ [contractResult c]) ++
    concatMap (exprRefs owners) (contractPreconditions c ++ contractPostconditions c ++ contractRuntimePostconditions c)) contract ++
  maybe [] (\f -> concatMap (typeRefs . binderType) (definitionArguments f) ++ exprRefs owners (definitionBody f) ++
    -- A stage's policy calls definitions, such as a retry's when predicate.
    [DeclarationNode n | Just policy <- [definitionPolicy f], n <- foldr (:) [] policy]) definition

typeRefs :: Type -> [Ref]
typeRefs ty = case ty of
  Constructor name args -> TypeNode (Id name) : concat [ typeRefs t | TypeArgument t <- args ]
  Arrow a b -> typeRefs a ++ typeRefs b
  TypeVariable _ -> []

propositionRefs :: M.Map Id Id -> Proposition -> [Ref]
propositionRefs owners proposition = case proposition of
  Equation evidence a b -> evidenceRefs evidence ++ exprRefs owners a ++ exprRefs owners b
  Implication guard body -> exprRefs owners guard ++ propositionRefs owners body
  Conjunction parts -> concatMap (propositionRefs owners) parts

evidenceRefs :: Evidence -> [Ref]
evidenceRefs (Numeric t) = typeRefs t
evidenceRefs (Structural t) = typeRefs t

exprRefs :: M.Map Id Id -> Expr -> [Ref]
exprRefs owners e = typeRefs (expressionType e) ++ case expressionNode e of
  Constant _ -> []
  Construct c args -> owner c ++ concatMap go args
  Match scrutinee cases -> go scrutinee ++
    concat [ owner (caseConstructor c) ++ concatMap (typeRefs . binderType) (caseBinders c) ++ go (caseBody c) | c <- cases ]
  AllElements list binder body -> go list ++ typeRefs (binderType binder) ++ go body
  AllPayloads value fields -> go value ++ concat [ typeRefs (binderType b) ++ go x | (b, x) <- fields ]
  Local _ -> []
  ExternalCall callee args -> DeclarationNode callee : concatMap go args
  Binary _ evidence a b -> evidenceRefs evidence ++ go a ++ go b
  Unary _ a -> go a
  ShortCircuit _ a b -> go a ++ go b
  If c a b -> go c ++ go a ++ go b
  Convert _ t a -> typeRefs t ++ go a
  Helper _ args -> concatMap go args
  Perform op args -> abilityRefs (operationAbility op) ++ concatMap go args
  Handle (CatchFailure ability) body -> abilityRefs ability ++ go body
  Calls op args -> abilityRefs (operationAbility op) ++ concatMap go (maybe [] id args)
  where
    go = exprRefs owners
    abilityRefs ability = concatMap typeRefs (abilityRefArguments ability)
    owner c = maybe [] (pure . TypeNode) (M.lookup c owners)
