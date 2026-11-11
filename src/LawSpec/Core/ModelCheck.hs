-- | Explicit-state LTL model checking with fairness, in-house and pure, so the
-- native and WASM compilers share it (owner decision 12). A formula is
-- translated to a generalized Büchi automaton by the on-the-fly tableau of
-- Gerth, Peled, Vardi and Wolper ("Simple on-the-fly automatic verification
-- of linear temporal logic", 1995).
--
-- The system's reachable graph is explored once, breadth first, and each
-- state is numbered by its key in an exact visited set. No hash compaction
-- is used, so no state is lost to a collision, as it could be with SPIN's
-- bitstate hashing or TLC's fingerprints. One graph serves every law about
-- the same model. The product with a law's automaton is a graph of numbers.
-- Its strongly connected components are searched for an accepting, fair
-- cycle, and strong fairness refines a component as Lichtenstein and Pnueli
-- do. Fairness is per step: a command with its arguments, as TLA+'s
-- WF_vars(A(x)) for each x. A run that ends stays in its last state.
--
-- Two optional reductions shrink the graph. A symmetry explores one state of
-- each orbit, and a persistent set explores some of a state's steps.
-- LawSpec.ModelReduction says when each is sound and checks it.
-- ref:DEC-model-checking ref:DEC-model-checker-reductions
module LawSpec.Core.ModelCheck
  ( Formula(..), System(..), Fairness(..), Outcome(..), negation, search
  , Graph(..), Reduction(..), noReduction, explore, searchGraph, formulaAtoms
  , Verdict(..), judge
  ) where

import Data.Array (Array, listArray, (!))
import qualified Data.Graph as G
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Sequence as Q
import qualified Data.Set as S

-- | LTL in negation normal form over named state predicates.
data Formula
  = FTrue | FFalse | FAtom String | FNotAtom String
  | FAnd Formula Formula | FOr Formula Formula
  | FUntil Formula Formula | FRelease Formula Formula | FNext Formula
  deriving (Eq, Ord, Show)

negation :: Formula -> Formula
negation f = case f of
  FTrue -> FFalse
  FFalse -> FTrue
  FAtom a -> FNotAtom a
  FNotAtom a -> FAtom a
  FAnd a b -> FOr (negation a) (negation b)
  FOr a b -> FAnd (negation a) (negation b)
  FUntil a b -> FRelease (negation a) (negation b)
  FRelease a b -> FUntil (negation a) (negation b)
  FNext a -> FNext (negation a)

-- | The state predicates a formula reads.
formulaAtoms :: Formula -> [String]
formulaAtoms f = nub $ case f of
  FAtom a -> [a]
  FNotAtom a -> [a]
  FAnd a b -> formulaAtoms a ++ formulaAtoms b
  FOr a b -> formulaAtoms a ++ formulaAtoms b
  FUntil a b -> formulaAtoms a ++ formulaAtoms b
  FRelease a b -> formulaAtoms a ++ formulaAtoms b
  FNext a -> formulaAtoms a
  _ -> []

-- | A system: its first states, each state's steps (a command, how to show
-- the step with its arguments, and the next state), and its predicates.
-- A key identifies a state exactly.
data System k s = System
  { systemInitial :: [s]
  , systemSteps :: s -> Either String [(String, String, s)]
  , systemHolds :: String -> s -> Either String Bool
  , systemKey :: s -> k }

-- | Weak fairness for a command: each of its steps (the command with some
-- arguments) that stays enabled is taken. Strong fairness: each one enabled
-- again and again is taken.
data Fairness = Weak String | Strong String deriving (Eq, Show)

-- | Every reachable product state explored with no accepting fair cycle; a
-- lasso (the steps to the cycle, and the cycle); or a search that stopped
-- at its bound.
data Outcome = NoRun Int | Lasso [String] [String] | Bounded Int String deriving (Eq, Show)

-- | Reductions of the explored graph. represent gives a state's
-- representative under a symmetry. check is run on each explored state and
-- its steps, and is Left when a reduction's condition fails there.
-- persistent gives a subset of a state's steps that is enough to explore,
-- or Nothing to explore them all.
data Reduction s = Reduction
  { reductionRepresent :: Maybe (s -> s)
  , reductionCheck :: Maybe (s -> [(String, String, s)] -> Either String ())
  , reductionPersistent :: Maybe (s -> [(String, String, s)] -> Maybe [(String, String, s)]) }

noReduction :: Reduction s
noReduction = Reduction Nothing Nothing Nothing

-- | A system's reachable graph. States are numbered from 0 in the order
-- they were found. Each state has its explored steps (label, target) and
-- the labels it enables. A label is a (command, shown) pair.
data Graph s = Graph
  { graphStates :: Array Int s
  , graphCount :: Int
  , graphInitial :: [Int]
  , graphMoves :: Array Int [(Int, Int)]
  , graphEnabled :: Array Int IS.IntSet
  , graphLabels :: Array Int (String, String)
  -- How many states had their steps cut to a persistent subset.
  , graphReduced :: Int }

-- | Explore at most limit states of a system, breadth first. A cycle of
-- states whose steps were all cut is avoided as SPIN's breadth-first
-- partial-order reduction does: a state whose persistent steps reach a
-- state already found takes all its steps.
explore :: Ord k => Int -> System k s -> Reduction s -> Either Outcome (Graph s)
explore limit system reduction
  | length numbered > limit = Left (Bounded limit "the reachable-state search stops there")
  | otherwise = go (Q.fromList numbered) (M.fromList [(systemKey system s, i) | (i, s) <- numbered]) (IM.fromList numbered) IM.empty IM.empty M.empty 0
  where
    represent = fromMaybe id (reductionRepresent reduction)
    numbered = zip [0 ..] (firstOnly (map represent (systemInitial system)))
    firstOnly = go' S.empty
      where
        go' _ [] = []
        go' seen (x : xs) | systemKey system x `S.member` seen = go' seen xs
                          | otherwise = x : go' (S.insert (systemKey system x) seen) xs
    go queue seen states moves enabled labels reduced = case Q.viewl queue of
      Q.EmptyL ->
        let n = M.size seen
            arr m = listArray (0, n - 1) [IM.findWithDefault mempty i m | i <- [0 .. n - 1]]
        in Right (Graph (listArray (0, n - 1) (IM.elems states)) n (map fst numbered) (arr moves) (arr enabled)
             (listArray (0, M.size labels - 1) (map fst (sortOn snd (M.toList labels)))) reduced)
      (i, s) Q.:< rest -> case systemSteps system s of
        Left why -> Left (Bounded (M.size seen) why)
        Right steps -> do
          either (Left . Bounded (M.size seen)) Right (maybe (Right ()) (\check -> check s steps) (reductionCheck reduction))
          let labels' = foldl' (\m (c, shown, _) -> if M.member (c, shown) m then m else M.insert (c, shown) (M.size m) m) labels steps
              label c shown = labels' M.! (c, shown)
              -- A persistent subset whose steps all reach new states.
              (taken, cut) = case reductionPersistent reduction >>= \p -> p s steps of
                Just subset | length subset < length steps
                            , all (\(_, _, t) -> systemKey system (represent t) `M.notMember` seen) subset -> (subset, True)
                _ -> (steps, False)
              -- Each target's key is computed once, and looked up once.
              (seen', fresh, edges) = foldl' (\(m, acc, es) (c, shown, t0) ->
                let t = represent t0
                    k = systemKey system t
                    l = label c shown
                in case M.lookup k m of
                     Just j -> (m, acc, (l, j) : es)
                     Nothing -> let j = M.size m in (M.insert k j m, acc Q.|> (j, t), (l, j) : es)) (seen, Q.empty, []) taken
          if M.size seen' > limit then Left (Bounded limit "the reachable-state search stops there") else
            go (rest Q.>< fresh) seen' (foldl' (\m (j, t) -> IM.insert j t m) states fresh) (IM.insert i (reverse edges) moves)
              (IM.insert i (IS.fromList [label c shown | (c, shown, _) <- steps]) enabled) labels' (if cut then reduced + 1 else reduced)

-- The tableau: each node's literals (state predicates it requires), its
-- obligations, and its successors' obligations.
data Node = Node { nodeIncoming :: S.Set Int, nodeOld :: S.Set Formula, nodeNext :: S.Set Formula }

tableau :: Formula -> ([(Int, Node)], [Int])
tableau formula = (M.toList finished, initials)
  where
    finished = go [(0, S.singleton (-1), [formula], S.empty, S.empty)] 1 M.empty
    initials = [i | (i, n) <- M.toList finished, (-1) `S.member` nodeIncoming n]
    -- (id, incoming, new, old, next)
    go [] _ done = done
    go ((ident, incoming, new, old, next) : pending) fresh done = case new of
      [] -> case [i | (i, n) <- M.toList done, nodeOld n == old, nodeNext n == next] of
        i : _ -> go pending fresh (M.adjust (\n -> n { nodeIncoming = S.union incoming (nodeIncoming n) }) i done)
        [] -> let done' = M.insert ident (Node incoming old next) done
              in go ((fresh, S.singleton ident, S.toList next, S.empty, S.empty) : pending) (fresh + 1) done'
      f : rest
        | f `S.member` old -> go ((ident, incoming, rest, old, next) : pending) fresh done
        | otherwise -> case f of
            FFalse -> go pending fresh done
            FTrue -> continue rest
            FAtom a | FNotAtom a `S.member` old -> go pending fresh done
                    | otherwise -> continue rest
            FNotAtom a | FAtom a `S.member` old -> go pending fresh done
                       | otherwise -> continue rest
            FAnd a b -> continue (a : b : rest)
            FNext a -> go ((ident, incoming, rest, S.insert f old, S.insert a next) : pending) fresh done
            FOr a b -> split [a] [] [b] []
            -- a U b = b or (a and next (a U b))
            FUntil a b -> split [a] [f] [b] []
            -- a R b = (a and b) or (b and next (a R b))
            FRelease a b -> split [a, b] [] [b] [f]
        where
          continue more = go ((ident, incoming, more, S.insert f old, next) : pending) fresh done
          split new1 next1 new2 next2 =
            go ((ident, incoming, new1 ++ rest, S.insert f old, S.union next (S.fromList next1))
               : (fresh, incoming, new2 ++ rest, S.insert f old, S.union next (S.fromList next2)) : pending) (fresh + 1) done

-- | Accepting sets: for each until a U b in the closure, the nodes where it
-- is not owed or b holds.
acceptance :: Formula -> [(Int, Node)] -> [S.Set Int]
acceptance formula nodes =
  [ S.fromList [i | (i, n) <- nodes, not (u `S.member` nodeOld n) || b `S.member` nodeOld n]
  | u@(FUntil _ b) <- S.toList (closure formula) ]
  where
    closure f = S.insert f $ case f of
      FAnd a b -> S.union (closure a) (closure b)
      FOr a b -> S.union (closure a) (closure b)
      FUntil a b -> S.union (closure a) (closure b)
      FRelease a b -> S.union (closure a) (closure b)
      FNext a -> closure a
      _ -> S.empty

-- | Whether the system has a run satisfying the formula under the fairness
-- assumptions, exploring at most limit states.
search :: Ord k => Int -> System k s -> [Fairness] -> Formula -> Either String Outcome
search limit system fairness formula = case explore limit system noReduction of
  Left outcome -> Right outcome
  Right graph -> searchGraph graph (systemHolds system) fairness formula

-- The product of a graph and a law's automaton: vertex v is a (state, node)
-- pair, with its steps (label, vertex). Label -1 is a run that ends,
-- staying in its last state. The labels each vertex enables, whatever the
-- automaton allows: fairness is about the system's steps.
data Product = Product
  { productNodes :: Array Int Int
  , productStarts :: [Int]
  , productEdges :: Array Int [(Int, Int)]
  , productEnabled :: Int -> IS.IntSet }

-- | A run of the explored graph satisfying the formula under the fairness
-- assumptions, if any.
searchGraph :: Graph s -> (String -> s -> Either String Bool) -> [Fairness] -> Formula -> Either String Outcome
searchGraph graph holds fairness formula = either (Right . Bounded (graphCount graph)) Right $ do
  let (nodes, initials) = tableau formula
      accepting = acceptance formula nodes
      n = graphCount graph
      -- Each atom's truth at every state, computed once and only when read.
      tables = M.fromList [ (a, listArray (0, n - 1) [holds a (graphStates graph ! i) | i <- [0 .. n - 1]] :: Array Int (Either String Bool))
                          | a <- formulaAtoms formula ]
      truth a i = maybe (Left ("no predicate " ++ a)) (! i) (M.lookup a tables)
      literals = M.fromList [ (i, [(a, True) | FAtom a <- S.toList (nodeOld nd)] ++ [(a, False) | FNotAtom a <- S.toList (nodeOld nd)]) | (i, nd) <- nodes ]
      fits s q = and <$> mapM (\(a, want) -> (== want) <$> truth a s) (literals M.! q)
      successors = M.fromListWith (flip (++)) [ (from, [i]) | (i, nd) <- nodes, from <- S.toList (nodeIncoming nd), from >= 0 ]
      next q = M.findWithDefault [] q successors
      moves s = case graphMoves graph ! s of
        [] -> [(-1, s)]
        ms -> ms
  starts <- fmap concat $ mapM (\s -> do
      ok <- mapM (fits s) initials
      pure [(s, q) | (q, True) <- zip initials ok]) (graphInitial graph)
  -- Breadth first over pairs, numbered as found.
  let build queue seen edges = case Q.viewl queue of
        Q.EmptyL -> Right (seen, edges)
        ((v, (s, q)) Q.:< rest) -> do
          targets <- fmap concat $ mapM (\(l, t) -> do
            ok <- mapM (fits t) (next q)
            pure [(l, (t, q')) | (q', True) <- zip (next q) ok]) (moves s)
          let (seen', fresh) = foldl' (\(m, acc) (_, p) -> if M.member p m then (m, acc)
                else (M.insert p (M.size m) m, acc Q.|> (M.size m, p))) (seen, Q.empty) targets
          build (rest Q.>< fresh) seen' (IM.insert v [(l, seen' M.! p) | (l, p) <- targets] edges)
      startPairs = nub starts
  (seen, edges) <- build (Q.fromList (zip [0 ..] startPairs)) (M.fromList (zip startPairs [0 ..])) IM.empty
  let size = M.size seen
      pairs = listArray (0, size - 1) (map fst (sortOn snd (M.toList seen))) :: Array Int (Int, Int)
      product' = Product (fmap snd pairs) [0 .. length startPairs - 1]
        (listArray (0, size - 1) [IM.findWithDefault [] v edges | v <- [0 .. size - 1]])
        (\v -> graphEnabled graph ! fst (pairs ! v))
      labelCommand l = if l < 0 then "" else fst (graphLabels graph ! l)
      shown l = if l < 0 then "stays" else snd (graphLabels graph ! l)
      fair = listToMaybe [ found | component <- components product' (IS.fromList [0 .. size - 1])
                                 , Just found <- [fairComponent product' accepting labelCommand fairness component] ]
  pure $ case fair of
    Nothing -> NoRun n
    Just component ->
      -- The shortest way into the cycle, then the cycle from there.
      let prefix = fromMaybe [] (pathTo (productEdges product') (productStarts product') (`IS.member` component))
          entry = case reverse prefix of
            (v, _) : _ -> v
            [] -> case [v | v <- productStarts product', v `IS.member` component] of
              v : _ -> v
              [] -> IS.findMin component
      in Lasso (map (shown . snd) prefix) (map shown (cycleThrough product' accepting labelCommand fairness component entry))

-- | The strongly connected components of the product restricted to keep.
components :: Product -> IS.IntSet -> [IS.IntSet]
components product' keep =
  let vertices = IS.toList keep
      index = IM.fromList (zip vertices [0 ..])
      back = listArray (0, length vertices - 1) vertices :: Array Int Int
      graph = G.buildG (0, length vertices - 1)
        [ (index IM.! v, j) | v <- vertices, (_, t) <- productEdges product' ! v, Just j <- [IM.lookup t index] ]
  in [IS.fromList (map (back !) (flatten tree [])) | tree <- G.scc graph]
  where
    -- Accumulated, so a deep search tree flattens in linear time.
    flatten (G.Node a ts) rest = a : foldr flatten rest ts

-- | The steps inside a set of vertices: (from, label, to).
inside :: Product -> IS.IntSet -> [(Int, Int, Int)]
inside product' component = [ (v, l, t) | v <- IS.toList component, (l, t) <- productEdges product' ! v, t `IS.member` component ]

-- | The labels of each fair command enabled somewhere in the component.
fairLabels :: Product -> (Int -> String) -> [Fairness] -> IS.IntSet -> ([Int], [Int])
fairLabels product' labelCommand fairness component =
  ( [l | l <- enabled, labelCommand l `elem` [c | Weak c <- fairness]]
  , [l | l <- enabled, labelCommand l `elem` [c | Strong c <- fairness]] )
  where enabled = IS.toList (IS.unions [productEnabled product' v | v <- IS.toList component])

-- | The part of a component holding an accepting, fair cycle, if any. Strong
-- fairness refines the component, dropping states where an untaken step is
-- enabled.
fairComponent :: Product -> [S.Set Int] -> (Int -> String) -> [Fairness] -> IS.IntSet -> Maybe IS.IntSet
fairComponent product' accepting labelCommand fairness component
  | null steps' = Nothing
  | not (all (\set -> any (\v -> (productNodes product' ! v) `S.member` set) members) accepting) = Nothing
  | otherwise = case [l | l <- strong, not (taken l)] of
      l : _ ->
        let remaining = IS.filter (\v -> not (l `IS.member` productEnabled product' v)) component
        in listToMaybe [found | sub <- components product' remaining, Just found <- [fairComponent product' accepting labelCommand fairness sub]]
      [] | any (\l -> not (taken l) && all (\v -> l `IS.member` productEnabled product' v) members) weak -> Nothing
         | otherwise -> Just component
  where
    members = IS.toList component
    steps' = inside product' component
    takenLabels = IS.fromList [l | (_, l, _) <- steps']
    taken l = l `IS.member` takenLabels
    (weak, strong) = fairLabels product' labelCommand fairness component

-- | A cycle from entry through a fair component: a state of each accepting
-- set, each fair step (or a state where it is not enabled), and back.
cycleThrough :: Product -> [S.Set Int] -> (Int -> String) -> [Fairness] -> IS.IntSet -> Int -> [Int]
cycleThrough product' accepting labelCommand fairness component entry = map snd (if null walked then loop else walked)
  where
    local = fmap (filter ((`IS.member` component) . snd)) (productEdges product')
    steps' = inside product' component
    pick xs = case xs of x : _ -> [x]; [] -> []
    (weak, strong) = fairLabels product' labelCommand fairness component
    waypoints = concat [pick [Left v | v <- IS.toList component, (productNodes product' ! v) `S.member` set] | set <- accepting] ++
      concat [ case [(v, l, t) | (v, l, t) <- steps', l == wanted] of
                 step : _ -> [Right step]
                 [] -> pick [Left v | v <- IS.toList component, not (wanted `IS.member` productEnabled product' v)]
             | wanted <- nub (weak ++ strong) ]
    to from v = fromMaybe [] (pathTo local [from] (== v))
    walk from targets = case targets of
      [] -> to from entry
      Left v : more -> to from v ++ walk v more
      Right (v, l, t) : more -> to from v ++ [(t, l)] ++ walk t more
    walked = walk entry waypoints
    -- At least one step: leave the entry and come back.
    loop = case [(t, l) | (l, t) <- local ! entry] of
      (t, l) : _ -> (t, l) : to t entry
      [] -> []

-- | A shortest path (breadth first) from any of the starts to a target, as
-- (vertex reached, label).
pathTo :: Array Int [(Int, Int)] -> [Int] -> (Int -> Bool) -> Maybe [(Int, Int)]
pathTo edges starts target = go (Q.fromList [(s, []) | s <- starts]) (IS.fromList starts)
  where
    go queue seen = case Q.viewl queue of
      Q.EmptyL -> Nothing
      (v, path) Q.:< rest
        | target v -> Just (reverse path)
        | otherwise ->
            let next = [ (t, (t, l) : path) | (l, t) <- edges ! v, t `IS.notMember` seen ]
                seen' = foldl' (\s (t, _) -> IS.insert t s) seen next
            in go (rest Q.>< Q.fromList (nubOn fst next)) seen'
    nubOn f xs = M.elems (M.fromListWith (\_ old -> old) [(f x, x) | x <- xs])

-- | A history's verdict: it holds (whatever comes next, for an open
-- history), it breaks at an entry, or (open histories only) what comes
-- next decides.
data Verdict = Holds | Breaks Int | Open deriving (Eq, Show)

-- | Judge a formula over a finite history of n entries, as LTL3 does (Bauer,
-- Leucker and Schallhart): an open history holds when no continuation can
-- break the formula, breaks when none can keep it, and is open otherwise; a
-- complete history ends, staying in its last entry. The entry where it
-- breaks is the first prefix no continuation can satisfy.
judge :: Bool -> Formula -> Int -> (String -> Int -> Either String Bool) -> Either String Verdict
judge complete formula n holds
  | n <= 0 = case formula of
      FTrue -> Right Holds
      FFalse -> Right (Breaks 0)
      _ | complete -> Left "a complete temporal history needs at least one entry"
        | otherwise -> Right Open
  | otherwise = do
      firstBreak <- earliest formula
      if complete
        then do
          let system = System [0] (\i -> Right [("", "next", i + 1) | i + 1 < n]) (\a i -> holds a i) id
          outcome <- search (max 1000 (4 * n)) system [] (negation formula)
          case outcome of
            NoRun _ -> Right Holds
            Lasso _ _ -> Right (Breaks (maybe (n - 1) id firstBreak))
            Bounded count why -> Left ("history search incomplete after " ++ show count ++ " states: " ++ why)
        else do
          satisfied <- earliest (negation formula)
          pure $ case (firstBreak, satisfied) of
            (Just i, _) -> Breaks i
            (Nothing, Just _) -> Holds
            _ -> Open
  where
    -- The first prefix after which no continuation satisfies f.
    earliest f = do
      let (nodes, initials) = tableau f
          table = M.fromList nodes
          literals node = [(a, True) | FAtom a <- S.toList (nodeOld node)] ++ [(a, False) | FNotAtom a <- S.toList (nodeOld node)]
          fits i q = and <$> mapM (\(a, want) -> (== want) <$> holds a i) (literals (table M.! q))
          next q = [j | (j, node) <- nodes, q `S.member` nodeIncoming node]
          accepting = acceptance f nodes
          -- The automaton alone, as a product whose vertices are its nodes.
          ids = map fst nodes
          count = if null ids then 0 else maximum ids + 1
          automaton = Product (listArray (0, count - 1) [0 .. count - 1]) []
            (listArray (0, count - 1) [[(-1, j) | j <- next q] | q <- [0 .. count - 1]]) (const IS.empty)
          present = IS.fromList ids
          fairSets = [component | component <- components automaton present
                                , fairComponent automaton accepting (const "") [] component == Just component]
          goodNodes = S.fromList (concatMap IS.toList fairSets)
          live = backwards goodNodes
          backwards good = let more = S.fromList [q | (q, _) <- nodes, any (`S.member` good) (next q)]
                               grown = S.union good more
                           in if S.size grown == S.size good then good else backwards grown
          step i reached = fmap concat (mapM (\q -> filterM' (fits i) (next q)) reached)
          go i reached
            | i >= n = Right Nothing
            | otherwise = do
                here <- if i == 0 then filterM' (fits 0) initials else step i reached
                let alive = nub here
                if not (any (`S.member` live) alive) then Right (Just i) else go (i + 1) alive
      go 0 []
    filterM' p xs = fmap (map fst . filter snd) (mapM (\x -> (\b -> (x, b)) <$> p x) xs)
