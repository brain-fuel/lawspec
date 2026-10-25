-- | The dependency graph of a Core program, for incremental compilation,
-- and the content identity of every node in it.
--
-- Nodes are data types and declarations; a declaration's node also holds its
-- contract and, for a checked definition, its body. Edges are references: the
-- types a type's fields, equations and predicates name, and the types,
-- constructors and calls in a declaration's signature, contract and body.
--
-- Each node, and each handler and ability, has two hashes
-- (LawSpec.Core.Identity): a semantic hash of what it does, with references
-- written as their targets' semantic hashes, and a presentation hash of its
-- names, docs and spans. Recursive types and mutually recursive definitions
-- form strongly connected groups, hashed as one with member positions, as
-- Rune and Unison do. So a node's semantic hash changes exactly when the
-- behaviour of something it can reach changes, and a law's work can be keyed
-- by what the law does rather than by how the program is written.
-- ref:DEC-content-identity
module LawSpec.Dependencies
  ( Graph, Ref(..), dependencyGraph, dependencyGraphWithBits, references, referencesOf, closure, contentHash
  , Identity(..), nodeIdentity, identityOf, semanticKey, fullKey, namedKey, adapterKey
  , lawReferences, unitReferences, reachableData, reachableDefinitions
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Graph as G
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import LawSpec.Blake3 (blake3, hashMany, hexOf)
import LawSpec.Core
import LawSpec.Scalar (integerBounds)
import LawSpec.Core.Identity (Encode, Encoded(..), Reference(..), Resolver(..))
import qualified LawSpec.Core.Identity as Identity

-- | Laws depend on data types and on declarations, the two things an edit can
-- change under them.
data Ref = TypeNode Id | DeclarationNode Id deriving (Eq, Ord, Show)

-- | A node's or a value's identity. The names hash covers the names it and
-- everything it reaches are written with; the presentation hash covers
-- those and the docs and spans too.
data Identity = Identity
  { semanticHash :: !B.ByteString, namesHash :: !B.ByteString, presentationHash :: !B.ByteString }
  deriving (Eq, Show)

-- Every node with an identity: Ref's two kinds, and handlers and abilities.
data Node' = DataNode String | DeclNode Id | HandlerNode Id | AbilityNode Id deriving (Eq, Ord, Show)

-- | The dependency graph with each node's identity.
-- ref:DEC-incremental-compilation
data Graph = Graph
  { graphMachineBits :: Int
  , graphEdges :: M.Map Ref [Ref]
  , graphIdentities :: M.Map Node' Identity
  , graphConstructors :: M.Map Id (String, Int)
  , graphNodes :: M.Map String Node'
  , graphData :: M.Map Id DataDeclaration
  , graphDefinitions :: M.Map Id Definition
  , graphOwners :: M.Map Id Id
  -- Each spec handler's clause definitions: a law run under a handler
  -- reaches them.
  , graphHandlers :: M.Map Id [Id]
  }

-- | Built once per program and shared by planning, emission and discharge.
dependencyGraph :: [DataDeclaration] -> [Unit] -> Graph
dependencyGraph = dependencyGraphWithBits 64

-- | Only machine-sized primitive meanings depend on this profile. Fixed-width
-- and exact types keep the same identity at 32 and 64; the profile propagates
-- through references only when a node actually reaches a machine-sized type.
dependencyGraphWithBits :: Int -> [DataDeclaration] -> [Unit] -> Graph
dependencyGraphWithBits bits dataDeclarations units = Graph bits edges identities constructors nodeNames dataTable definitionTable owners handlerTable
  where
    handlerTable = M.fromList [(handlerId h, map snd (handlerClauses h)) | u <- units, h <- unitHandlers u]
    dataTable = M.fromList [(dataId d, d) | d <- dataDeclarations]
    definitionTable = M.fromList [(declarationId (definitionDeclaration d), d) | u <- units, d <- unitDefinitions u]
    contractTable = M.fromList [(contractDeclaration c, c) | u <- units, c <- unitContracts u]
    declarationTable = M.fromList ([(declarationId d, d) | u <- units, d <- unitDeclarations u] ++
      [(declarationId (definitionDeclaration d), definitionDeclaration d) | d <- M.elems definitionTable])
    handlers = M.fromList (reverse [(handlerId h, h) | u <- units, h <- unitHandlers u])
    abilities = M.fromList (reverse [(abilityId a, a) | u <- units, a <- unitAbilities u])
    owners = M.fromList [(constructorId c, dataId d) | d <- dataDeclarations, c <- dataConstructors d]
    known node = case node of
      TypeNode i -> M.member i dataTable
      DeclarationNode i -> M.member i declarationTable
    -- Planning's edges: each node's direct references.
    planned = [ (TypeNode i, dataReferences owners d) | (i, d) <- M.toList dataTable ] ++
      [ (DeclarationNode i, declarationReferences owners d (M.lookup i contractTable) (M.lookup i definitionTable))
      | (i, d) <- M.toList declarationTable ]
    edges = M.fromList [ (node, S.toList (S.fromList (filter known refs))) | (node, refs) <- planned ]

    -- Identity: every node's content, encoded against the hashes of what it
    -- references.
    constructors = M.fromList [ (constructorId c, (idText (dataId d), i)) | d <- dataDeclarations, (i, c) <- zip [0..] (dataConstructors d) ]
    nodeNames = M.fromList $
      [ (idText i, AbilityNode i) | i <- M.keys abilities ] ++ [ (idText i, HandlerNode i) | i <- M.keys handlers ] ++
      [ (idText i, DataNode (idText i)) | i <- M.keys dataTable ] ++ [ (idText i, DeclNode i) | i <- M.keys declarationTable ]
    encodeNode resolver node = case node of
      DataNode name -> maybe empty (Identity.encode resolver) (M.lookup (Id name) dataTable)
      DeclNode i -> case (M.lookup i declarationTable, M.lookup i contractTable, M.lookup i definitionTable) of
        (Just d, c, Nothing) -> Identity.encodeAdapter resolver (idText i ++ " " ++ show (declarationSource d)) (d, c)
        (Just d, c, f) -> Identity.encode resolver (d, c, f)
        _ -> empty
      HandlerNode i -> maybe empty (Identity.encode resolver) (M.lookup i handlers)
      AbilityNode i -> maybe empty (Identity.encode resolver) (M.lookup i abilities)
    mentions node = case node of
      DataNode name -> maybe [] Identity.references (M.lookup (Id name) dataTable)
      DeclNode i -> Identity.references (M.lookup i declarationTable, M.lookup i contractTable, M.lookup i definitionTable)
      HandlerNode i -> maybe [] Identity.references (M.lookup i handlers)
      AbilityNode i -> maybe [] Identity.references (M.lookup i abilities)
    allNodes = M.elems nodeNames
    identityEdges = M.fromList [ (n, S.toList (S.fromList (mapMaybe (mentioned constructors nodeNames) (mentions n)))) | n <- allNodes ]
    groups = G.stronglyConnComp [ (n, n, M.findWithDefault [] n identityEdges) | n <- allNodes ]
    identities = foldl addGroup M.empty groups
    addGroup done group = case group of
      G.AcyclicSCC n ->
        let e = encodeNode (resolverOver bits constructors nodeNames done M.empty) n
        in combine done [n] [blake3 (semanticBytes e)] [e]
      G.CyclicSCC members ->
        -- Each member roots an ordered graph traversal. First encounters,
        -- in Core field/reference order, assign positions; later references
        -- use those positions. Every member reaches the whole SCC. Thus
        -- this is a finite structural encoding, including every edge, with
        -- no name-based tie-break or permutation search. Symmetric roots
        -- have the same identity, as their rooted structures are identical.
        -- The positional back-reference precedent is CBOR shared values;
        -- the versioned Core encoding remains LawSpec's trust boundary.
        -- ref:DEC-content-identity
        let inside = S.fromList members
            visit seen [] = (seen, [])
            visit seen (n : rest)
              | S.member n seen = visit seen rest
              | otherwise =
                  let children = [ d | name <- mentions n
                                     , Just d <- [mentioned constructors nodeNames name]
                                     , S.member d inside ]
                      (after, ordered) = visit (S.insert n seen) (children ++ rest)
                  in (after, n : ordered)
            rooted member =
              let ordered = snd (visit S.empty [member])
                  positions = M.fromList (zip ordered (map Just [0 ..]))
                  encoded = map (encodeNode (resolverOver bits constructors nodeNames done positions)) ordered
              in blake3 (B.concat (BC.pack ("rooted-group:1:" ++ show (length ordered) ++ ":") :
                                  hashMany (map semanticBytes encoded)))
            -- Presentation keeps the actual names and spans of each member.
            positions = M.fromList (zip members (map Just [0 ..]))
            encoded = map (encodeNode (resolverOver bits constructors nodeNames done positions)) members
        in combine done members (map rooted members) encoded
    -- A group's names and presentation hashes cover its members' and what
    -- the group reaches outside itself.
    combine done members semantic encoded =
      let inside = S.fromList members
          outside = S.toList (S.fromList [ d | m <- members, d <- M.findWithDefault [] m identityEdges, S.notMember d inside ])
          deps = mapMaybe (`M.lookup` done) outside
          names = blake3 (B.concat (BC.pack "names:" : map nameBytes encoded ++ map namesHash deps))
          shown = blake3 (B.concat (BC.pack "presentation:" : names : map docBytes encoded ++ map presentationHash deps))
          member i h = Identity h (position "names" names i) (position "presentation" shown i)
      in foldr (\(i, m, h) -> M.insert m (member i h)) done (zip3 [0 :: Int ..] members semantic)
    position label h i = if i == 0 then h else blake3 (B.concat [BC.pack (label ++ ":"), h, BC.pack (show i)])
    empty = Encoded B.empty B.empty B.empty

-- The node a mention names: a constructor's type, or the node itself.
mentioned :: M.Map Id (String, Int) -> M.Map String Node' -> String -> Maybe Node'
mentioned constructors nodeNames name = case M.lookup (Id name) constructors of
  Just (owner, _) -> M.lookup owner nodeNames
  Nothing -> M.lookup name nodeNames

-- | References resolve to finished nodes' hashes, or to positions inside
-- the group being hashed (Nothing while its order is being decided).
resolverOver :: Int -> M.Map Id (String, Int) -> M.Map String Node' -> M.Map Node' Identity -> M.Map Node' (Maybe Int) -> Resolver
resolverOver bits constructors nodeNames done group = Resolver resolveName resolveTypeName
  where
    node n = case M.lookup n group of
      Just (Just i) -> Just (Member i)
      Just Nothing -> Just Hidden
      Nothing -> Hashed . semanticHash <$> M.lookup n done
    resolveName i = case M.lookup i constructors of
      Just (owner, position) -> (`ConstructorOf` position) <$> resolveTypeName owner
      Nothing -> M.lookup (idText i) nodeNames >>= node
    resolveTypeName name = case M.lookup name nodeNames of
      Just n@(DataNode _) -> node n
      _ | name `elem` ["IntSize", "UIntSize", "UIntPtr"] -> Just (Hashed (blake3
            (Text.encodeUtf8 (Text.pack (show ("lawspec.primitive-profile.v1", name, integerBounds bits name))))))
        | otherwise -> Nothing

-- | A node's identity.
nodeIdentity :: Graph -> Ref -> Maybe Identity
nodeIdentity graph ref = M.lookup (case ref of TypeNode i -> DataNode (idText i); DeclarationNode i -> DeclNode i) (graphIdentities graph)

-- | A value's identity against the graph: a law, a model check, a unit's
-- part. Its references are written as their nodes' semantic hashes, and its
-- names and presentation hashes cover theirs.
identityOf :: Encode a => Graph -> a -> Identity
identityOf graph value = Identity (blake3 (semanticBytes e)) names shown
  where
    e = Identity.encode (resolverOver (graphMachineBits graph) (graphConstructors graph) (graphNodes graph) (graphIdentities graph) M.empty) value
    deps = mapMaybe (\n -> mentioned (graphConstructors graph) (graphNodes graph) n >>= (`M.lookup` graphIdentities graph)) (Identity.references value)
    names = blake3 (B.concat (BC.pack "names:" : nameBytes e : map namesHash deps))
    shown = blake3 (B.concat (BC.pack "presentation:" : names : docBytes e : map presentationHash deps))

-- | A key for work whose result depends only on behaviour, such as a test
-- outcome or a proof: some context (a machine width, settings) and the
-- value's semantic hash.
semanticKey :: Encode a => Graph -> String -> a -> String
semanticKey graph context value = hexOf (blake3 (B.concat [keyContext "semantic" context, semanticHash (identityOf graph value)]))

-- | A key for work whose result shows names but not docs or spans, such as
-- a test that runs native code bound by name.
namedKey :: Encode a => Graph -> String -> a -> String
namedKey graph context value = let i = identityOf graph value
  in hexOf (blake3 (B.concat [keyContext "named" context, semanticHash i, namesHash i]))

-- | Native interfaces retain their public names; checked implementation
-- locals and declaration spellings remain presentation. Keep that boundary
-- narrow: hashing every name reached by an adapter-calling law would make
-- harmless local renames rerun it. Adapter code/configuration is additionally
-- bound by the host's result key.
adapterKey :: Encode a => Graph -> String -> a -> String
adapterKey graph context value = hexOf (blake3 (B.concat
  [BC.pack "adapter:", BC.pack (semanticKey graph context value), Text.encodeUtf8 (Text.pack (show public))]))
  where
    reached = closure graph (referencesOf graph value)
    public = sort
      [(idText (dataId d), dataName d,
        [(idText (constructorId c), constructorName c, map binderName (constructorFields c)) | c <- dataConstructors d])
      | TypeNode identity <- S.toList reached, Just d <- [M.lookup identity (graphData graph)]]

-- | A memo key for work whose result shows names, docs or spans, such as a
-- plan or emitted code: both hashes, so it is exact, yet an edit the value
-- does not reach leaves it unchanged.
fullKey :: Encode a => Graph -> String -> a -> String
fullKey graph context value = let i = identityOf graph value
  in hexOf (blake3 (B.concat [keyContext "full" context, semanticHash i, presentationHash i]))

-- Context is Unicode data too. Char8 would alias U+0100 with U+0000.
keyContext :: String -> String -> B.ByteString
keyContext label context = let bytes = Text.encodeUtf8 (Text.pack context)
  in B.concat [BC.pack (label ++ ":" ++ show (B.length bytes) ++ ":"), bytes]

-- | A declaration's semantic hash in hexadecimal: its remote identity.
-- ref:DEC-remote-semantic-identity
contentHash :: Graph -> Ref -> Maybe String
contentHash graph node = hexOf . semanticHash <$> nodeIdentity graph node

-- | The known nodes among some references, without repeats.
references :: Graph -> [Ref] -> [Ref]
references graph = filter (`M.member` graphEdges graph) . S.toList . S.fromList

-- | Resolve the semantic references of any checked Core value to graph
-- roots, including constructor owners and spec-handler clause definitions.
referencesOf :: Identity.Collect a => Graph -> a -> [Ref]
referencesOf graph value = references graph (concatMap resolve (Identity.references value))
  where
    resolve name = case mentioned (graphConstructors graph) (graphNodes graph) name of
      Just (DataNode name') -> [TypeNode (Id name')]
      Just (DeclNode identity) -> [DeclarationNode identity]
      Just (HandlerNode identity) -> map DeclarationNode (M.findWithDefault [] identity (graphHandlers graph))
      _ -> []

-- | Everything reachable from some nodes, the nodes included.
closure :: Graph -> [Ref] -> S.Set Ref
closure graph = go S.empty
  where
    go seen [] = seen
    go seen (n : rest)
      | S.member n seen = go seen rest
      | otherwise = go (S.insert n seen) (M.findWithDefault [] n (graphEdges graph) ++ rest)

-- | A law is planned only with the data types it reaches, so unrelated edits
-- leave its plan in the cache. ref:DEC-incremental-compilation
reachableData :: Graph -> S.Set Ref -> [DataDeclaration]
reachableData graph reached = mapMaybe (\i -> M.lookup i (graphData graph)) [ i | TypeNode i <- S.toList reached ]

-- | As reachableData, for checked definitions.
reachableDefinitions :: Graph -> S.Set Ref -> [Definition]
reachableDefinitions graph reached = mapMaybe (\i -> M.lookup i (graphDefinitions graph)) [ i | DeclarationNode i <- S.toList reached ]

-- | Everything a law mentions, its inputs, refinements, body and examples, is a
-- dependency.
lawReferences :: Graph -> Property -> [Ref]
lawReferences graph p = references graph $
  concat [ typeRefs (binderType (quantifiedBinder q)) ++ concatMap (exprRefs owners) (quantifiedPredicates q) ++
           concatMap (exprRefs owners . snd) (quantifiedBounds q) | q <- propertyParameters p ++ propertyInputs p ] ++
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

-- | What a unit's declarations, contracts, definitions and laws reference.
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
  Negation body -> propositionRefs owners body
  Quantified _ q body -> typeRefs (binderType (quantifiedBinder q)) ++
    concatMap (exprRefs owners) (quantifiedPredicates q ++ map snd (quantifiedBounds q)) ++ propositionRefs owners body

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
  Project c _ value -> owner c ++ go value
  Update c _ value field -> owner c ++ go value ++ go field
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
  Handle (WithHandler ability _) body -> abilityRefs ability ++ go body
  Let binder value body -> typeRefs (binderType binder) ++ go value ++ go body
  Calls op args -> abilityRefs (operationAbility op) ++ concatMap go (maybe [] id args)
  where
    go = exprRefs owners
    abilityRefs ability = concatMap typeRefs (abilityRefArguments ability)
    owner c = maybe [] (pure . TypeNode) (M.lookup c owners)
