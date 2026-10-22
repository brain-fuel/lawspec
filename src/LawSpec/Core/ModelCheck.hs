-- | Explicit-state LTL model checking with fairness, in-house and pure, so the
-- native and WASM compilers share it (owner decision 12). A formula is
-- translated to a generalized Büchi automaton by the on-the-fly tableau of
-- Gerth, Peled, Vardi and Wolper ("Simple on-the-fly automatic verification
-- of linear temporal logic", 1995); the product with the system is explored
-- breadth first, and its strongly connected components (Tarjan) are searched
-- for an accepting, fair cycle, refining components for strong fairness as
-- Lichtenstein and Pnueli do. A run that ends stays in its last state.
-- ref:DEC-model-checking
module LawSpec.Core.ModelCheck
  ( Formula(..), System(..), Fairness(..), Outcome(..), negation, search
  , Verdict(..), judge
  ) where

import Data.List (foldl', nub, sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Sequence as Q

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

-- | A system: its first states, each state's steps (a command, how to show
-- the step, and the next state), and its predicates. States are compared by
-- a key.
data System s = System
  { systemInitial :: [s]
  , systemSteps :: s -> Either String [(String, String, s)]
  , systemHolds :: String -> s -> Either String Bool
  , systemKey :: s -> String }

-- | Weak fairness: a command that stays enabled is taken; strong: one
-- enabled again and again is taken.
data Fairness = Weak String | Strong String deriving (Eq, Show)

-- | Every reachable product state explored with no accepting fair cycle; a
-- lasso (the steps to the cycle, and the cycle); or a search that stopped
-- at its bound.
data Outcome = NoRun Int | Lasso [String] [String] | Bounded Int String deriving (Eq, Show)

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
-- assumptions, searching at most limit product states.
search :: Int -> System s -> [Fairness] -> Formula -> Either String Outcome
search limit system fairness formula = do
  let (nodes, initials) = tableau formula
      nodeTable = M.fromList nodes
      accepting = acceptance formula nodes
      literals n = [(a, True) | FAtom a <- S.toList (nodeOld n)] ++ [(a, False) | FNotAtom a <- S.toList (nodeOld n)]
      fits s n = and <$> mapM (\(a, want) -> (== want) <$> systemHolds system a s) (literals n)
      successorsOf node = [i | (i, n) <- nodes, node `S.member` nodeIncoming n]
  starts <- fmap concat $ mapM (\s -> do
      matches <- mapM (\i -> fits s (nodeTable M.! i)) initials
      pure [(s, i) | (i, True) <- zip initials matches]) (systemInitial system)
  -- Breadth-first exploration of the product: (state, node) pairs.
  let key (s, i) = (systemKey system s, i)
      explore queue0 seen edges states enabled count = case Q.viewl queue0 of
       Q.EmptyL -> Right (seen, edges, states, enabled)
       (p@(s, i)) Q.:< queue -> explore1 p s i queue seen edges states enabled count
      explore1 p s i queue seen edges states enabled count
        | count >= limit = Left (Bounded count "the search stops there")
        | otherwise = case systemSteps system s of
            Left why -> Left (Bounded count why)
            Right steps -> do
              let moves = if null steps then [("", "stays", s)] else steps
              targets <- fmap concat $ either (Left . Bounded count) Right $ mapM (\(command, shown, s') -> do
                ok <- mapM (\j -> fits s' (nodeTable M.! j)) (successorsOf i)
                pure [((command, shown), (s', j)) | (j, True) <- zip (successorsOf i) ok]) moves
              let new = [t | (_, t) <- targets, key t `M.notMember` seen]
                  unique = M.elems (M.fromList [(key t, t) | t <- new])
                  seen' = foldl' (\m t -> M.insert (key t) t m) seen unique
                  edges' = M.insert (key p) [(label, key t) | (label, t) <- targets] edges
              -- What the system may do here, whatever the property allows:
              -- fairness is about the system's commands.
              let enabled' = M.insert (key p) (S.fromList [command | (command, _, _) <- steps]) enabled
              explore (queue Q.>< Q.fromList unique) seen' edges' (M.insert (key p) p states) enabled' (count + 1)
  case explore (Q.fromList (nubOn key starts)) (M.fromList [(key p, p) | p <- starts]) M.empty M.empty M.empty (0 :: Int) of
    Left outcome -> Right outcome
    Right (_, edges, states, enabled) -> do
      let allNodes = M.keys states
          enabledAt k c = c `S.member` M.findWithDefault S.empty k enabled
          explored = reachable (Q.fromList (systemInitial system)) (S.fromList (map (systemKey system) (systemInitial system)))
          firsts = [key p | p <- nubOn key starts]
      case listToMaybe [ fair | component <- sccs allNodes edges, Just fair <- [fairComponent accepting edges enabledAt fairness component] ] of
        Nothing -> Right (either id NoRun explored)
        Just component -> do
          -- The shortest way into the cycle, then the cycle from there.
          let prefix = fromMaybe [] (pathTo edges firsts component)
              entry = case reverse prefix of
                (k, _) : _ -> k
                [] -> head ([k | k <- firsts, k `S.member` component] ++ [S.findMin component])
          Right (Lasso (map snd prefix) (cycleThrough accepting edges enabledAt fairness component entry))
  where
    nubOn f = M.elems . M.fromList . map (\x -> (f x, x))
    -- How many states the system reaches: the states a proof covers.
    reachable queue0 seen = case Q.viewl queue0 of
      Q.EmptyL -> Right (S.size seen)
      s Q.:< queue
        | S.size seen > limit -> Left (Bounded limit "the reachable-state search stops there")
        | otherwise -> case systemSteps system s of
        Left why -> Left (Bounded (S.size seen) why)
        Right moves ->
          let new = nubOn (systemKey system) [t | (_, _, t) <- moves, systemKey system t `S.notMember` seen]
          in reachable (queue Q.>< Q.fromList new) (foldl' (\acc t -> S.insert (systemKey system t) acc) seen new)

type Key = (String, Int)
type Edges = M.Map Key [((String, String), Key)]

-- | Strongly connected components of the explored product (Tarjan), as node
-- sets.
sccs :: [Key] -> Edges -> [S.Set Key]
sccs nodes edges = reverse (fst4 (foldl' visit ([], M.empty, M.empty, (0, [])) nodes))
  where
    fst4 (a, _, _, _) = a
    next k = [t | (_, t) <- M.findWithDefault [] k edges]
    visit acc@(_, indices, _, _) k
      | k `M.member` indices = acc
      | otherwise = strong acc k
    strong (found, indices, lows, (counter, stack)) v =
      let indices1 = M.insert v counter indices
          lows1 = M.insert v counter lows
          state1 = (found, indices1, lows1, (counter + 1, v : stack))
          stateAfter = foldl' (\st@(f, idx, lw, (c, stk)) w ->
            if w `M.notMember` idx
              then let st'@(f', idx', lw', cs') = strong st w
                   in (f', idx', M.insert v (min (lw' M.! v) (lw' M.! w)) lw', cs')
              else if w `elem` stk
                then (f, idx, M.insert v (min (lw M.! v) (idx M.! w)) lw, (c, stk))
                else st) state1 (next v)
          (found2, indices2, lows2, (counter2, stack2)) = stateAfter
      in if lows2 M.! v == indices2 M.! v
           then let (component, rest) = span (/= v) stack2
                in (S.fromList (v : component) : found2, indices2, lows2, (counter2, drop 1 rest))
           else (found2, indices2, lows2, (counter2, stack2))

-- | The part of a component holding an accepting, fair cycle, if any;
-- strong fairness refines the component, dropping states where an untaken
-- command is enabled.
fairComponent :: [S.Set Int] -> Edges -> (Key -> String -> Bool) -> [Fairness] -> S.Set Key -> Maybe (S.Set Key)
fairComponent accepting edges enabledAt fairness component
  | null inside = Nothing
  | not (all (\set -> any ((`S.member` set) . snd) (S.toList component)) accepting) = Nothing
  | otherwise = case [c | Strong c <- fairness, not (taken c), any (`enabledAt` c) (S.toList component)] of
      c : _ ->
        let remaining = S.filter (\k -> not (enabledAt k c)) component
            inner = restrict remaining edges
        in listToMaybe [found | sub <- sccs (S.toList remaining) inner, Just found <- [fairComponent accepting inner enabledAt fairness sub]]
      [] | any weakUnfair [c | Weak c <- fairness] -> Nothing
         | otherwise -> Just component
  where
    inside = steps component edges
    taken c = any (\(_, (command, _), _) -> command == c) inside
    weakUnfair c = not (taken c) && all (`enabledAt` c) (S.toList component)

restrict :: S.Set Key -> Edges -> Edges
restrict keep edges = M.map (filter ((`S.member` keep) . snd)) (M.filterWithKey (\k _ -> k `S.member` keep) edges)

steps :: S.Set Key -> Edges -> [(Key, (String, String), Key)]
steps component edges = [(k, label, t) | k <- S.toList component, (label, t) <- M.findWithDefault [] k edges, t `S.member` component]

-- | A cycle from entry through a fair component: a state of each accepting
-- set, each fair command's step (or a state where it is not enabled), and
-- back.
cycleThrough :: [S.Set Int] -> Edges -> (Key -> String -> Bool) -> [Fairness] -> S.Set Key -> Key -> [String]
cycleThrough accepting edges enabledAt fairness component entry = map snd (if null walked then loop else walked)
  where
    local = restrict component edges
    inside = steps component edges
    pick xs = case xs of x : _ -> [x]; [] -> []
    waypoints = concat [pick [Left k | k <- S.toList component, snd k `S.member` set] | set <- accepting] ++
      concat [ case [(k, label, t) | (k, label@(command, _), t) <- inside, command == c] of
                 step : _ -> [Right step]
                 [] -> pick [Left k | k <- S.toList component, not (enabledAt k c)]
             | c <- nub (map commandOf fairness) ]
    to from k = fromMaybe [] (pathTo local [from] (S.singleton k))
    walk from targets = case targets of
      [] -> to from entry
      Left k : more -> to from k ++ walk k more
      Right (k, label, t) : more -> to from k ++ [(t, snd label)] ++ walk t more
    walked = walk entry waypoints
    -- At least one step: leave the entry and come back.
    loop = case [(t, snd label) | (label, t) <- M.findWithDefault [] entry local] of
      (t, shown) : _ -> (t, shown) : to t entry
      [] -> []
    commandOf (Weak c) = c
    commandOf (Strong c) = c

-- | A shortest path (breadth first) from any of the starts to a target, as
-- (state reached, step shown).
pathTo :: Edges -> [Key] -> S.Set Key -> Maybe [(Key, String)]
pathTo edges starts targets = go [(s, []) | s <- starts] (S.fromList starts)
  where
    go [] _ = Nothing
    go ((k, path) : queue) seen
      | k `S.member` targets = Just (reverse path)
      | otherwise =
          let next = [ (t, (t, shown) : path) | ((_, shown), t) <- sortOn (fst . fst) (M.findWithDefault [] k edges), t `S.notMember` seen ]
              seen' = foldl' (\s (t, _) -> S.insert t s) seen next
          in go (queue ++ next) seen'

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
          let system = System [0] (\i -> Right [("", "next", i + 1) | i + 1 < n]) (\a i -> holds a i) show
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
          keyed = [(("", q), [(("", ""), ("", j)) | j <- next q]) | (q, _) <- nodes]
          edges = M.fromList keyed
          fairSets = [component | component <- sccs (map fst keyed) edges, Just component' <- [fairComponent accepting edges (\_ _ -> False) [] component], component' == component]
          goodNodes = S.fromList [q | component <- fairSets, (_, q) <- S.toList component]
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
