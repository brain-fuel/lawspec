-- The static part of a stateful model for the model runtimes: one
-- s-expression holding the data types its arguments use, its start, and each
-- command's argument descriptors (see the runtimes' read_descriptor),
-- typestate and flags. Callbacks (the bridge definitions, references,
-- preconditions, abstraction and invariants) are passed beside it, in the
-- order the spec lists them.
module LawSpec.MachineSpec (machineSpec, scenarioWire) where

import Control.Monad (foldM, forM, unless, when)
import Data.List (isInfixOf)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import LawSpec.Scalar (Scalar(..), integerBounds, isInteger)

-- The spec of a machine, given the program's data types and the unit's
-- declarations.
machineSpec :: Int -> [C.DataDeclaration] -> [C.Declaration] -> [C.Contract] -> Machine C.Id -> Either String String
machineSpec bits datas declarations contracts machine = do
  let typeOf name = case filter ((== name) . C.declarationId) declarations of
        [d] -> Right (C.declarationType d)
        _ -> Left ("model " ++ machineName machine ++ ": no declaration for " ++ C.idText name)
      describeAll types = foldr (\(t, range) acc -> do (ds, table) <- acc; (d, table') <- describe bits datas table t; pure (narrow range d : ds, table'))
        (Right ([], [])) types
      -- An argument's integer bounds from its adapter's preconditions.
      rangeOf name i = case [c | c <- contracts, C.contractDeclaration c == name] of
        [c] | i < length (C.contractArguments c) -> bounds (C.binderId (C.contractArguments c !! i)) (C.contractPreconditions c)
        _ -> (Nothing, Nothing)
  start <- forM (machineStart machine) $ \s -> do
    ty <- typeOf (startSystem s)
    pure (s, [(t, rangeOf (startSystem s) i) | (i, t) <- zip [0 ..] (fst (C.functionType ty))])
  commands <- forM (machineCommands machine) $ \c -> do
    ty <- typeOf (commandSystem c)
    let (args, _) = C.functionType ty
    pure (c, [(args !! i, rangeOf (commandSystem c) i) | i <- commandArguments c])
  -- One table of data types across the start and every command.
  (descriptors, table) <- describeAll (concat (maybe [] snd start : map snd commands))
  let (startDescriptors, rest) = splitAt (maybe 0 (length . snd) start) descriptors
      commandDescriptors = splitPlaces (map (length . snd) commands) rest
      startForm = case start of
        Nothing -> "(start)"
        Just (s, _) -> "(start (indices" ++ concatMap ((' ' :) . show) (maybe [] id (startIndices s)) ++ ") (arguments" ++
          concatMap (' ' :) startDescriptors ++ "))"
      commandForm (c, _) ds = "(command " ++ commandName c ++ " (arguments" ++ concatMap (' ' :) ds ++ ")" ++
        " (state " ++ show (commandStatePosition c) ++ ")" ++
        " (unit " ++ bool (commandReturnsUnit c) ++ ")" ++
        " (when " ++ bool (commandWhen c /= Nothing) ++ ")" ++
        " (needs" ++ concatMap ((' ' :) . need) (commandNeeds c) ++ ")" ++
        " (shifts" ++ concatMap ((' ' :) . shift) (commandShifts c) ++ ")" ++
        " (key " ++ maybe "none" show (commandKey c) ++ ")" ++
        " (restart " ++ bool (commandRestart c) ++ "))"
      invariant (OnModel _) = "model"
      invariant (OnState _) = "state"
  unless (maybe False (const True) start) $
    Left ("model " ++ machineName machine ++ " needs a start command: LawSpec does not yet generate starting states")
  pure (unwords
    ([ "(machine " ++ machineName machine ++ " " ++ (if machineShared machine then "shared" else "linear") ++ ")" ] ++
     map snd (reverse table) ++
     [startForm] ++
     zipWith commandForm commands commandDescriptors ++
     [ "(abstract " ++ bool (machineAbstractRun machine /= Nothing) ++ ")"
     , "(invariants" ++ concatMap ((' ' :) . invariant) (machineInvariants machine) ++ ")"
     , "(perkey " ++ bool (machinePerKey machine) ++ ")"
     , "(actor " ++ bool (machineActor machine) ++ ")" ]))
  where
    bool b = if b then "true" else "false"
    need (AtLeast k) = "(atleast " ++ show k ++ ")"
    need (Exactly k) = "(exactly " ++ show k ++ ")"
    shift (By d) = "(by " ++ show d ++ ")"
    shift (To k) = "(to " ++ show k ++ ")"
    splitPlaces [] _ = []
    splitPlaces (n : ns) xs = let (a, b) = splitAt n xs in a : splitPlaces ns b

-- The tightest constant bounds a precondition conjunction puts on a binder.
bounds :: C.Id -> [C.Expr] -> (Maybe Integer, Maybe Integer)
bounds binder = foldl tighten (Nothing, Nothing) . concatMap conjuncts
  where
    conjuncts e = case C.expressionNode e of
      C.ShortCircuit C.And a b -> conjuncts a ++ conjuncts b
      _ -> [e]
    tighten (lo, hi) e = case C.expressionNode e of
      C.Binary op _ a b -> case (local a, constant b, constant a, local b) of
        (True, Just n, _, _) -> apply op n (lo, hi)
        (_, _, Just n, True) -> apply (flipped op) n (lo, hi)
        _ -> (lo, hi)
      _ -> (lo, hi)
    local e = case C.expressionNode e of
      C.Local i -> i == binder
      C.Convert _ _ inner -> local inner
      _ -> False
    constant e = case C.expressionNode e of
      C.Constant (SInteger _ n) -> Just n
      C.Convert _ _ inner -> constant inner
      _ -> Nothing
    apply op n (lo, hi) = case op of
      C.GreaterEqual -> (Just (maybe n (max n) lo), hi)
      C.Greater -> (Just (maybe (n + 1) (max (n + 1)) lo), hi)
      C.LessEqual -> (lo, Just (maybe n (min n) hi))
      C.Less -> (lo, Just (maybe (n - 1) (min (n - 1)) hi))
      C.Equal -> (Just n, Just n)
      _ -> (lo, hi)
    flipped op = case op of
      C.GreaterEqual -> C.LessEqual
      C.Greater -> C.Less
      C.LessEqual -> C.GreaterEqual
      C.Less -> C.Greater
      other -> other

-- An integer descriptor narrowed to a refinement's bounds.
narrow :: (Maybe Integer, Maybe Integer) -> String -> String
narrow (Nothing, Nothing) d = d
narrow (lo, hi) d = case words (filter (`notElem` ("()" :: String)) d) of
  ["int", t, l, h] | take 5 d == "(int " ->
    "(int " ++ t ++ " " ++ tighter max lo l ++ " " ++ tighter min hi h ++ ")"
  _ -> d
  where
    -- A bound replaces the type's own when it is tighter; _ is no bound.
    tighter f new old = case (new, reads old :: [(Integer, String)]) of
      (Just n, [(o, "")]) -> show (f n o)
      (Just n, _) -> show n
      (Nothing, _) -> old

-- A type's descriptor, adding the data types it reaches to the table (each
-- once, by name, so recursion goes through (ref NAME)).
describe :: Int -> [C.DataDeclaration] -> [(String, String)] -> C.Type -> Either String (String, [(String, String)])
describe bits datas table ty = case ty of
  C.Constructor "Bool" [] -> pure ("(bool)", table)
  C.Constructor "Text" [] -> pure ("(text)", table)
  C.Constructor "Unit" [] -> pure ("(unit)", table)
  C.Constructor n [] | isInteger n -> pure ("(int " ++ n ++ " " ++ bounds n ++ ")", table)
  C.Constructor "List" [C.TypeArgument t] -> wrap "list" [t]
  C.Constructor "Maybe" [C.TypeArgument t] -> wrap "maybe" [t]
  C.Constructor "Either" [C.TypeArgument a, C.TypeArgument b] -> wrap "either" [a, b]
  C.Constructor n []
    | Just _ <- lookup n table -> pure ("(ref " ++ n ++ ")", table)
    | [d] <- [d | d <- datas, C.idText (C.dataId d) == n] -> do
        when (C.dataHandle d) (Left ("a model command's argument cannot be the handle " ++ C.dataName d ++
          ": LawSpec cannot generate one; only the model's start makes handles"))
        unless (null (C.dataParameters d)) (unsupported "a generic data type")
        unless (all (null . C.constructorPredicates) (C.dataConstructors d) && all (null . C.constructorEquations) (C.dataConstructors d)
            && C.dataIndex d == Nothing)
          (unsupported "a data type with constructor refinements or indices")
        -- The placeholder stops recursion; it is replaced when the type is done.
        let placeholder = (n, "")
        (ctors, table') <- foldl (\acc ctor -> do
            (done, current) <- acc
            (fields, current') <- foldl (\inner field -> do
                (fs, t) <- inner
                (f, t') <- describe bits datas t (C.binderType field)
                pure (fs ++ [f], t')) (Right ([], current)) (C.constructorFields ctor)
            pure (done ++ ["(ctor " ++ C.idText (C.constructorId ctor) ++ concatMap (' ' :) fields ++ ")"], current'))
          (Right ([], placeholder : table)) (C.dataConstructors d)
        let form = "(data " ++ n ++ concatMap (' ' :) ctors ++ ")"
        pure ("(ref " ++ n ++ ")", [(k, if k == n then form else v) | (k, v) <- table'])
  _ -> unsupported ("the type " ++ show ty)
  where
    unsupported what = Left ("a model command's arguments cannot yet be generated for " ++ what)
    bounds n = case integerBounds bits n of
      Just (lo, hi) -> show lo ++ " " ++ show hi
      Nothing | n == "BigUInt" -> "0 _"
              | otherwise -> "_ _"
    wrap kind ts = do
      (ds, table') <- foldl (\acc t -> do (done, current) <- acc; (d, current') <- describe bits datas current t; pure (done ++ [d], current'))
        (Right ([], table)) ts
      pure ("(" ++ kind ++ concatMap (' ' :) ds ++ ")", table')

-- A scenario's channels for network runs: (wire (data ...)... (channel c
-- (send D) (receive D) ...) ...), each step from the protocol's first end.
-- A step sending a channel end is (end): its address travels as text.
scenarioWire :: Int -> [C.DataDeclaration] -> [C.Session] -> P.Program -> Either String String
scenarioWire bits datas sessions program = do
  let protocol p = [s | s <- sessions, C.sessionName s == p]
      step table (sends, ty) = case ty of
        C.Constructor n [] | "::session::" `isInfixOf` n -> pure ("(" ++ verb sends ++ " (end))", table)
        _ -> do
          (d, table') <- describe bits datas table ty
          pure ("(" ++ verb sends ++ " " ++ d ++ ")", table')
      channel table (c, p) = case protocol p of
        s : _ -> do
          (steps, table') <- foldM (\(acc, t) st -> (\(d, t') -> (acc ++ [d], t')) <$> step t st) ([], table) (C.sessionSteps s)
          pure ("(channel " ++ c ++ concatMap (' ' :) steps ++ ")", table')
        [] -> Left ("scenario " ++ P.programTitle program ++ ": no protocol " ++ p)
      verb sends = if sends then "send" else "receive"
  (forms, table) <- foldM (\(acc, t) cp -> (\(f, t') -> (acc ++ [f], t')) <$> channel t cp) ([], [])
    (zip (P.programChannels program) (P.programProtocols program))
  pure ("(wire" ++ concatMap ((' ' :) . snd) (reverse table) ++ concatMap (' ' :) forms ++ ")")
