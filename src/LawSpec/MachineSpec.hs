-- The static part of a stateful model for the model runtimes: one
-- s-expression holding the data types its arguments use, its start, and each
-- command's argument descriptors (see the runtimes' read_descriptor),
-- typestate and flags. Callbacks (the bridge definitions, references,
-- preconditions, abstraction and invariants) are passed beside it, in the
-- order the spec lists them.
module LawSpec.MachineSpec (machineSpec) where

import Control.Monad (forM, unless)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import LawSpec.Scalar (integerBounds, isInteger)

-- The spec of a machine, given the program's data types and the unit's
-- declarations.
machineSpec :: Int -> [C.DataDeclaration] -> [C.Declaration] -> Machine C.Id -> Either String String
machineSpec bits datas declarations machine = do
  let typeOf name = case filter ((== name) . C.declarationId) declarations of
        [d] -> Right (C.declarationType d)
        _ -> Left ("model " ++ machineName machine ++ ": no declaration for " ++ C.idText name)
      describeAll types = foldr (\t acc -> do (ds, table) <- acc; (d, table') <- describe bits datas table t; pure (d : ds, table'))
        (Right ([], [])) types
  start <- forM (machineStart machine) $ \s -> do
    ty <- typeOf (startSystem s)
    pure (s, fst (C.functionType ty))
  commands <- forM (machineCommands machine) $ \c -> do
    ty <- typeOf (commandSystem c)
    let (args, _) = C.functionType ty
    pure (c, [args !! i | i <- commandArguments c])
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
        " (shifts" ++ concatMap ((' ' :) . shift) (commandShifts c) ++ "))"
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
     , "(invariants" ++ concatMap ((' ' :) . invariant) (machineInvariants machine) ++ ")" ]))
  where
    bool b = if b then "true" else "false"
    need (AtLeast k) = "(atleast " ++ show k ++ ")"
    need (Exactly k) = "(exactly " ++ show k ++ ")"
    shift (By d) = "(by " ++ show d ++ ")"
    shift (To k) = "(to " ++ show k ++ ")"
    splitPlaces [] _ = []
    splitPlaces (n : ns) xs = let (a, b) = splitAt n xs in a : splitPlaces ns b

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
