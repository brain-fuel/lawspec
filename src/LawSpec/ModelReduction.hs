-- | Partial-order reduction for the explicit-state checker (LawSpec.Core.
-- ModelCheck): of a state's steps, explore only a persistent set, as SPIN's
-- ample sets and Valmari's stubborn sets do. ref:DEC-model-checker-reductions
--
-- Which steps are independent comes from each step's footprint: the fields
-- of the model state its reference, precondition and refinements read, and
-- the fields its reference writes. A footprint is computed from the checked
-- definitions themselves, with the step's arguments known and the state
-- unknown, by a small abstract interpreter: a match on a known constructor
-- takes its one branch, a call is followed into the definition it names,
-- and anything it cannot follow reads and writes every field. Two steps
-- whose footprints do not overlap (neither writes what the other reads or
-- writes) commute, and neither enables nor disables the other.
--
-- A state's persistent set is a stubborn set (Valmari): start from one
-- enabled step; add every step dependent on an enabled step in the set, and
-- for a disabled one, every step that writes a field it reads (one that
-- could enable it). The set is used only when it is smaller than the
-- enabled steps and none of its steps writes a field the law's predicates
-- read (invisibility). The explorer avoids cycles of cut states.
-- Together these are Peled's conditions for preserving every LTL property
-- without next, which is all a law can say. Fairness assumptions are about
-- particular steps, which a reduction may postpone, so a law that assumes
-- fairness is never reduced; nor is a deadline, nor a model with typestate.
module LawSpec.ModelReduction (Footprint(..), footprints, persistent, readsOfPredicate) where

import qualified Data.IntSet as IS
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.LawAnalysis as A
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))

-- | Fields read and written; Nothing is every field.
data Footprint = Footprint { footprintReads :: Maybe IS.IntSet, footprintWrites :: Maybe IS.IntSet }
  deriving (Eq, Show)

-- An abstract value: known, a field of the state as it was, the whole
-- state as it was, a record or constructor of abstract fields, or anything
-- (with the fields it was computed from).
data Abs = Known Value | Field Int | Whole | Built C.Id [Abs] | Anything (Maybe IS.IntSet)
  deriving (Eq, Show)

type Reads = Maybe IS.IntSet

everything :: Reads
everything = Nothing

union :: Reads -> Reads -> Reads
union a b = IS.union <$> a <*> b

-- | The fields an abstract value was computed from.
readsOf :: Abs -> Reads
readsOf v = case v of
  Known _ -> Just IS.empty
  Field i -> Just (IS.singleton i)
  Whole -> everything
  Built _ fs -> foldr (union . readsOf) (Just IS.empty) fs
  Anything r -> r

join :: Int -> C.Id -> Abs -> Abs -> Abs
join n ctor a b
  | a == b = a
  | otherwise = case (expand a, expand b) of
      (Built c xs, Built d ys) | c == d && length xs == length ys -> Built c (zipWith (join n ctor) xs ys)
      _ -> Anything (union (readsOf a) (readsOf b))
  where
    expand Whole = Built ctor (map Field [0 .. n - 1])
    expand (Known (DataValue _ tag vs)) = Built tag (map Known vs)
    expand x = x

-- | A definition's analysis context: the program's definitions, an
-- evaluator for known values, and the state record's constructor and size.
data Context = Context
  { contextDefinitions :: M.Map C.Id C.Definition
  , contextEvaluate :: [(C.Id, Value)] -> C.Expr -> Either String Value
  , contextCtor :: C.Id, contextSize :: Int }

-- | Analyse an expression: its abstract value and the fields it inspected.
analyse :: Context -> Int -> M.Map C.Id Abs -> C.Expr -> (Abs, Reads)
analyse ctx depth env e = case C.expressionNode e of
  C.Constant s -> (Known (ScalarValue s), Just IS.empty)
  C.Local x -> (M.findWithDefault (Anything everything) x env, Just IS.empty)
  C.Construct ctor args ->
    let rs = map go args
        vs = map fst rs
        readSet = foldr (union . snd) (Just IS.empty) rs
    in case mapM known vs of
         Just values -> (Known (DataValue (C.expressionType e) ctor values), readSet)
         Nothing -> (Built ctor vs, readSet)
  C.Project _ i inner -> let (v, r) = go inner in case v of
    Whole -> (Field i, r)
    Built _ fs | i < length fs -> (fs !! i, r)
    Known (DataValue _ _ vs) | i < length vs -> (Known (vs !! i), r)
    _ -> (Anything (readsOf v), union r (readsOf v))
  C.Update _ i base value ->
    let (b, rb) = go base
        (v, rv) = go value
        replace fs = [if j == i then v else f | (j, f) <- zip [0 ..] fs]
        r = union rb rv
    in case b of
         Whole -> (Built (contextCtor ctx) (replace (map Field [0 .. contextSize ctx - 1])), r)
         Built c fs -> (Built c (replace fs), r)
         Known (DataValue _ tag vs) -> (Built tag (replace (map Known vs)), r)
         _ -> (Anything (union (readsOf b) (readsOf v)), union r (union (readsOf b) (readsOf v)))
  C.Match scrutinee cases ->
    let (s, rs) = go scrutinee
        branch c values = let env' = foldr (\(b, v) m -> M.insert (C.binderId b) v m) env (zip (C.caseBinders c) values)
                          in analyse ctx depth env' (C.caseBody c)
        chosen tag fields = case [c | c <- cases, C.caseConstructor c == tag] of
          c : _ -> let (v, r) = branch c fields in (v, union rs r)
          [] -> (Anything everything, everything)
    in case s of
         Known (DataValue _ tag vs) -> chosen tag (map Known vs)
         Built tag fs -> chosen tag fs
         Whole | [c] <- cases -> let (v, r) = branch c (map Field [0 .. contextSize ctx - 1]) in (v, union rs r)
         _ -> let inspected = union rs (readsOf s)
                  results = [ branch c [Anything (readsOf s) | _ <- C.caseBinders c] | c <- cases ]
              in case results of
                   [] -> (Anything everything, everything)
                   (v0, r0) : more -> (foldl (\acc (v, _) -> join (contextSize ctx) (contextCtor ctx) acc v) v0 more,
                                       foldr (union . snd) (union inspected r0) more)
  C.If c a b -> let (cv, rc) = go c in case cv of
    Known (ScalarValue (SBool True)) -> let (v, r) = go a in (v, union rc r)
    Known (ScalarValue (SBool False)) -> let (v, r) = go b in (v, union rc r)
    _ -> let (va, ra) = go a
             (vb, rb) = go b
         in (join (contextSize ctx) (contextCtor ctx) va vb, union (union rc (readsOf cv)) (union ra rb))
  C.Let b value body -> let (v, r) = go value
                            (w, r') = analyse ctx depth (M.insert (C.binderId b) v env) body
                        in (w, union r r')
  C.ExternalCall f args
    | depth > 0, Just d <- M.lookup f (contextDefinitions ctx), length (C.definitionArguments d) == length args ->
        let rs = map go args
            env' = M.fromList (zip (map C.binderId (C.definitionArguments d)) (map fst rs))
            (v, r) = analyse ctx (depth - 1) env' (C.definitionBody d)
        in (v, foldr (union . snd) r rs)
  _ -> computed
  where
    go = analyse ctx depth env
    known (Known v) = Just v
    known _ = Nothing
    -- Any other node: computed from its operands, each analysed in turn.
    -- When every operand is known, the evaluator gives its value. A local
    -- bound inside the node (by a quantifier, say) is unknown to its
    -- operand's analysis, which then reads every field: conservative.
    computed
      | not (closed e) = (Anything everything, everything)
      | otherwise =
          let operands = map go (C.children e)
              readSet = foldr (\(v, r) acc -> union acc (union r (readsOf v))) (Just IS.empty) operands
              values = [ (x, v) | x <- localsOf e, Just (Known v) <- [M.lookup x env] ]
          in if all (isKnown . fst) operands
               then case contextEvaluate ctx values e of
                 Right v -> (Known v, Just IS.empty)
                 Left _ -> (Anything readSet, readSet)
               else (Anything readSet, readSet)
    isKnown (Known _) = True
    isKnown _ = False
    -- Nodes the analysis treats as plain computations of their operands.
    closed x = case C.expressionNode x of
      C.Perform _ _ -> False
      C.Handle _ _ -> False
      C.Calls _ _ -> False
      C.ExternalCall f _ -> M.member f (contextDefinitions ctx) && all closed (C.children x)
      _ -> all closed (C.children x)
    localsOf x = case C.expressionNode x of
      C.Local v -> [v]
      _ -> concatMap localsOf (C.children x)

-- | The context for a model whose state is a record, or Nothing.
contextFor :: C.Program -> C.Type -> Either String (Maybe Context)
contextFor program stateType = do
  ctx <- A.context program
  let definitions = M.fromList [ (C.declarationId (C.definitionDeclaration d), d) | u <- C.programUnits program, d <- C.unitDefinitions u ]
  pure $ case stateType of
    C.Constructor name [] | [d] <- [d | d <- C.programDataDeclarations program, C.idText (C.dataId d) == name]
                          , [ctor] <- C.dataConstructors d ->
      Just (Context definitions (A.contextEvaluate ctx) (C.constructorId ctor) (length (C.constructorFields ctor)))
    _ -> Nothing

-- | Each step's footprint, by (command, shown), for the steps given as
-- (command, shown, reference, precondition, argument values). The
-- reference takes the arguments and then the state.
footprints :: C.Program -> C.Type -> [C.Contract] -> [(String, String, C.Definition, Maybe C.Definition, [Value])]
  -> Either String (M.Map (String, String) Footprint)
footprints program stateType contracts steps = do
  found <- contextFor program stateType
  pure $ case found of
    Nothing -> M.fromList [ ((c, shown), Footprint everything everything) | (c, shown, _, _, _) <- steps ]
    Just ctx -> M.fromList [ ((c, shown), footprintOf ctx ref guard' values) | (c, shown, ref, guard', values) <- steps ]
  where
    depth = 12
    footprintOf ctx ref guard' values =
      let binders = C.definitionArguments ref
          env = M.fromList (zip (map C.binderId binders) (map Known values ++ [Whole]))
          (result, readSet) = analyse ctx depth env (C.definitionBody ref)
          state = case result of
            Built _ [r, s] | resultful -> (Just r, s)
            Known (DataValue _ _ [r, s]) | resultful -> (Just (Known r), Known s)
            _ | resultful -> (Just (Anything (readsOf result)), Anything everything)
              | otherwise -> (Nothing, result)
          resultful = case snd (C.functionType (C.declarationType (C.definitionDeclaration ref))) of
            C.Constructor "Pair" _ -> True
            _ -> False
          (answer, after) = state
          (writes, moved) = case after of
            Whole -> (Just IS.empty, Just IS.empty)
            Built _ fs | length fs == contextSize ctx ->
              let changed = [ (i, f) | (i, f) <- zip [0 ..] fs, f /= Field i ]
              in (Just (IS.fromList (map fst changed)), foldr (union . readsOf . snd) (Just IS.empty) changed)
            Known (DataValue _ _ _) -> (Just (IS.fromList [0 .. contextSize ctx - 1]), Just IS.empty)
            other -> (everything, readsOf other)
          guardReads = case guard' of
            Just g -> let (v, r) = analyse ctx depth (M.fromList [(C.binderId b, Whole) | b <- C.definitionArguments g]) (C.definitionBody g)
                      in union r (readsOf v)
            Nothing -> Just IS.empty
          -- A contract names its parameters itself.
          refinementReads = foldr union (Just IS.empty)
            [ let (v, r) = analyse ctx depth (M.fromList (zip (map C.binderId (C.contractArguments c)) (map Known values ++ [Whole]))) p in union r (readsOf v)
            | c <- contracts, C.contractDeclaration c == C.declarationId (C.definitionDeclaration ref), p <- C.contractPreconditions c ]
      in Footprint (foldr union readSet [maybe (Just IS.empty) readsOf answer, moved, guardReads, refinementReads]) writes

-- | The fields a predicate of the state reads.
readsOfPredicate :: C.Program -> C.Type -> C.Definition -> Either String Reads
readsOfPredicate program stateType d = do
  found <- contextFor program stateType
  pure $ case found of
    Nothing -> everything
    Just ctx -> let (v, r) = analyse ctx 12 (M.fromList [(C.binderId b, Whole) | b <- C.definitionArguments d]) (C.definitionBody d)
                in union r (readsOf v)

overlaps :: Maybe IS.IntSet -> Maybe IS.IntSet -> Bool
overlaps a b = case (a, b) of
  (Just x, Just y) -> not (IS.null (IS.intersection x y))
  (Just x, Nothing) -> not (IS.null x)
  (Nothing, Just y) -> not (IS.null y)
  (Nothing, Nothing) -> True

-- | Whether two steps may not commute.
dependent :: Footprint -> Footprint -> Bool
dependent a b = overlaps (footprintWrites a) (union' (footprintReads b) (footprintWrites b))
  || overlaps (footprintWrites b) (footprintReads a)
  where union' x y = IS.union <$> x <*> y

-- | A state's persistent subset of its steps, or Nothing to take them all.
-- alphabet: every step the model has, with its footprint; visible: the
-- fields the law reads.
persistent :: M.Map (String, String) Footprint -> Reads -> [(String, String, s)] -> Maybe [(String, String, s)]
persistent alphabet visible steps
  | length steps < 2 = Nothing
  | otherwise = case sortOn length [ chosen | start <- enabledKeys, invisible start, Just chosen <- [stubborn start] ] of
      best : _ | length best < length steps -> Just [ step | step@(c, shown, _) <- steps, (c, shown) `elem` best ]
      _ -> Nothing
  where
    -- A set holding a visible step is no use, so only invisible steps
    -- start one.
    enabledKeys = [ (c, shown) | (c, shown, _) <- steps ]
    enabled = M.fromList [ (k, ()) | k <- enabledKeys ]
    footprint k = fromMaybe (Footprint everything everything) (M.lookup k alphabet)
    invisible k = not (overlaps (footprintWrites (footprint k)) visible)
    stubborn start = grow [start] (M.singleton start ())
      where
        grow [] set = let chosen = [k | k <- enabledKeys, M.member k set]
                      in if all invisible chosen then Just chosen else Nothing
        grow (k : rest) set
          | M.size (M.intersection set enabled) >= length enabledKeys = Nothing
          | otherwise =
              let f = footprint k
                  more = if M.member k enabled
                    then [ k' | (k', f') <- M.toList alphabet, dependent f f' ]
                    else [ k' | (k', f') <- M.toList alphabet, overlaps (footprintWrites f') (footprintReads f) ]
                  new = [ k' | k' <- more, not (M.member k' set) ]
              in grow (rest ++ new) (foldr (\k' m -> M.insert k' () m) set new)
