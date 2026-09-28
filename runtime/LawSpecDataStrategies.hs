-- Native Hedgehog generation and shrinking for checked Core schemas.
module LawSpecDataStrategies
  (strategy, checkedStrategy, primitiveStrategy) where

import Control.Monad (unless, when, foldM)
import Control.Monad.State.Strict (StateT, evalStateT, get, modify, lift)
import Data.Maybe (catMaybes)
import Numeric (showHex)
import Data.Char (chr)
import Data.Ratio (numerator, denominator, (%))
import qualified Data.Map.Strict as Map
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified LawSpecRuntime as LS
import qualified LawSpecSchema as S

type Cache = Map.Map (S.TypeRef, Int) (Maybe (Gen LS.Scalar))
type Build = StateT Cache (Either String)

strategy :: S.Schema -> S.TypeRef -> Int -> Int
         -> (String -> Either String (Gen LS.Scalar))
         -> Either String (Gen LS.Scalar)
strategy schema reference bits budget scalar = do
  when (S.hasContracts schema)
    (Left "constructor contracts require checked strategies")
  buildStrategy schema reference bits budget scalar (\_ _ -> id)

-- Predicate failures are native discards. Evaluation errors remain exceptions,
-- which Hedgehog reports as property failures rather than retrying them.
-- filterT prunes rejected shrink subtrees: searching every descendant of a
-- sparse identity predicate can otherwise make shrinking effectively unbounded.
checkedStrategy :: S.Schema -> S.TypeRef -> Int -> Int -> Maybe LS.SymbolContext
                -> [LS.Scalar] -> (String -> Either String (Gen LS.Scalar))
                -> Either String (Gen LS.Scalar)
checkedStrategy schema reference bits budget scope witnesses scalar = do
  checked <- mapM (S.validateWith scope schema reference bits) witnesses
  seeds <- foldM (indexWitness schema reference) Map.empty checked
  let scoped = maybe id LS.scopeSymbols scope
      accepted ty value = case S.validateChecked scope schema ty bits value of
        Right _ -> True
        Left (S.Rejected _) -> False
        Left (S.EvaluationFailure message) -> error message
      finish ty available generator =
        let values = filter ((<= available) . valueNodes)
              (Map.findWithDefault [] ty seeds)
            native = scoped <$> generator
            choices = if null values then native
              else Gen.choice [native, Gen.element values]
        in Gen.filterT (accepted ty) choices
  generated <- buildStrategy schema reference bits budget scalar finish
  pure
    (either error id . S.validateWith scope schema reference bits <$> generated)

valueNodes :: LS.Scalar -> Int
valueNodes value = 1 + sum (map valueNodes (case value of
  LS.SData _ fields -> fields
  LS.SList values -> values
  LS.SPresent _ payload -> maybe [] pure payload
  _ -> []))

indexWitness :: S.Schema -> S.TypeRef -> Map.Map S.TypeRef [LS.Scalar]
             -> LS.Scalar -> Either String (Map.Map S.TypeRef [LS.Scalar])
indexWitness schema reference witnesses value = do
  let indexed = Map.insertWith (++) reference [value] witnesses
      descend ty values = foldM (indexWitness schema ty) indexed values
  case (reference, value) of
    (S.Named "List" [element], LS.SList values) -> descend element values
    (S.Named name [element], LS.SPresent _ payload)
      | name `elem` ["Nullable", "Optional"] ->
        descend element (maybe [] pure payload)
    (S.Named "Maybe" [element], LS.SData "Maybe::Just" [child]) ->
      descend element [child]
    (S.Named "Either" [left, _], LS.SData "Either::Left" [child]) ->
      descend left [child]
    (S.Named "Either" [_, right], LS.SData "Either::Right" [child]) ->
      descend right [child]
    (_, LS.SData tag fields) -> do
      constructors <- S.constructors schema reference
      let matches =
            [expected | S.Constructor name expected <- maybe [] id constructors,
                        name == tag]
      case matches of
        expected:_ -> foldM
          (\acc (S.Field _ ty, child) -> indexWitness schema ty acc child)
          indexed (zip expected fields)
        [] -> pure indexed
    _ -> pure indexed

buildStrategy :: S.Schema -> S.TypeRef -> Int -> Int
              -> (String -> Either String (Gen LS.Scalar))
              -> (S.TypeRef -> Int -> Gen LS.Scalar -> Gen LS.Scalar)
              -> Either String (Gen LS.Scalar)
buildStrategy schema reference bits budget scalar finish = do
  unless (budget > 0) (Left "structural node budget must be positive")
  unless (bits == 32 || bits == 64) (Left "machineBits must be 32 or 64")
  S.checkType schema 0 reference
  result <- evalStateT (build reference budget) Map.empty
  maybe (Left ("no value of " ++ show reference ++
               " within structural node budget " ++ show budget)) Right result
  where
    build :: S.TypeRef -> Int -> Build (Maybe (Gen LS.Scalar))
    build _ available | available < 1 = pure Nothing
    build ty available = do
      cached <- Map.lookup (ty, available) <$> get
      case cached of
        Just result -> pure result
        Nothing -> do
          raw <- assemble ty available
          let result = fmap (finish ty available) raw
          modify (Map.insert (ty, available) result)
          pure result

    minimumCost ty limit = search 1
      where
        search cost | cost > limit = pure Nothing
        search cost = do
          candidate <- build ty cost
          case candidate of
            Just _ -> pure (Just cost)
            Nothing -> search (cost + 1)

    -- Reserve every field's minimum before distributing spare nodes.
    allocation [] _ = pure (Just [])
    allocation fields available = do
      minima <- reserve fields available
      pure $ fmap distribute minima
      where
        reserve [] _ = pure (Just [])
        reserve (S.Field _ ty : rest) remaining = do
          cost <- minimumCost ty remaining
          case cost of
            Nothing -> pure Nothing
            Just amount -> fmap (amount :) <$> reserve rest (remaining - amount)
        distribute costs =
          let (share, extra) = (available - sum costs) `divMod` length costs
          in zipWith (\index cost -> cost + share + fromEnum (index < extra))
               [0 ..] costs

    alternatives = pure . choose . catMaybes
    choose [] = Nothing
    choose [only] = Just only
    choose choices = Just (Gen.choice choices)

    variant available (S.Constructor tag fields) = do
      costs <- allocation fields (available - 1)
      case costs of
        Nothing -> pure Nothing
        Just amounts -> do
          children <- sequence <$> sequence
            [build ty amount | (S.Field _ ty, amount) <- zip fields amounts]
          pure
            ((\generators -> LS.SData tag <$> sequence generators) <$> children)

    assemble ty available = do
      constructors <- lift (S.constructors schema ty)
      case constructors of
        Just variants -> mapM (variant available) variants >>= alternatives
        Nothing -> builtin ty available

    builtin (S.Named name []) _ = do
      generator <- lift (scalar name)
      -- Scalar generators come from the target's typed primitive registry.
      pure (Just generator)
    builtin (S.Named "List" [element]) available = do
      cost <- minimumCost element (available - 1)
      let maximumLength = maybe 0 ((available - 1) `div`) cost
      sized <- mapM (listOfLength element (available - 1)) [1 .. maximumLength]
      let generators = pure (LS.SList []) : sized
      pure (Just (Gen.int (Range.linear 0 maximumLength) >>= (generators !!)))
    builtin (S.Named name [element]) available
      | name `elem` ["Maybe", "Nullable", "Optional"] = do
          child <- build element (available - 1)
          let absent = if name == "Maybe"
                then LS.SData "Maybe::Nothing" [] else LS.SPresent name Nothing
              present value = if name == "Maybe"
                then LS.SData "Maybe::Just" [value]
                else LS.SPresent name (Just value)
          alternatives [Just (pure absent), fmap (fmap present) child]
    builtin (S.Named "Either" [left, right]) available =
      mapM (variant available)
        [S.Constructor "Either::Left" [S.Field "value" left],
         S.Constructor "Either::Right" [S.Field "value" right]] >>= alternatives
    builtin ty _ = lift (Left ("unsupported generator type: " ++ show ty))

    listOfLength element remaining count = do
      child <- build element (remaining `div` count)
      case child of
        Nothing -> lift (Left "internal list budget allocation failure")
        Just generator -> pure
          (LS.SList <$> Gen.list (Range.singleton count) generator)

-- Primitive shrinkers remain in Hedgehog: integers, lists, and IEEE bit words.
primitiveStrategy :: Int -> String -> Either String (Gen LS.Scalar)
primitiveStrategy bits name
  | bits /= 32 && bits /= 64 = Left "machineBits must be 32 or 64"
  | LS.isInteger name =
      let (lo, hi) = maybe
            (if name == "BigUInt" then (0, 2^(256 :: Int))
             else (-2^(256 :: Int), 2^(256 :: Int))) id
            (LS.integerBounds bits name)
      in Right (LS.SInteger name <$> Gen.integral (Range.linearFrom 0 lo hi))
  | name == "Bool" = Right (LS.SBool <$> Gen.bool)
  | name `elem` ["Unit", "Null", "Undefined"] =
      Right (pure (LS.SAbsent name))
  | name `elem` ["Char", "CodePoint", "CodeUnit16"] =
      Right (LS.SCharacter name <$> unit name)
  | name `elem` ["Text", "CodePointText", "Utf16Text", "Bytes"] =
      Right (LS.SSequence name <$> Gen.list (Range.linear 0 100) (unit name))
  | name == "Decimal" = Right
      (LS.SDecimal <$> integer <*> Gen.integral (Range.linearFrom 0 (-20) 20))
  | name == "Rational" = Right $ do
      n <- integer
      d <- Gen.integral (Range.linear 1 (2^(256 :: Int)))
      let reduced = n % d
      pure (LS.SRational (numerator reduced) (denominator reduced))
  | name `elem` ["Float32", "Float64"] =
      let digits = if name == "Float32" then 8 else 16
          patternGenerator = Gen.integral (Range.constant 0 (16^digits - 1))
          encode word =
            let hex = showHex (word :: Integer) ""
            in LS.SFloat name (replicate (digits - length hex) '0' ++ hex)
      in Right (encode <$> patternGenerator)
  | name `elem` ["Complex64", "Complex128"] = do
      component <- primitiveStrategy bits
        (if name == "Complex64" then "Float32" else "Float64")
      Right (LS.SComplex name <$> component <*> component)
  | name == "Symbol" = Right
      (LS.SSymbol <$> Gen.string (Range.linear 0 40) Gen.alphaNum <*>
        (map chr <$> Gen.list (Range.linear 0 40) (unit "Text")))
  | otherwise = Left ("unknown scalar generator: " ++ name)
  where
    integer = Gen.integral (Range.linearFrom 0
      (-2^(256 :: Int)) (2^(256 :: Int)))
    unit kind =
      let upper = if kind == "Bytes" then 255
                  else if kind `elem` ["CodeUnit16", "Utf16Text"] then 65535
                  else 1114111
          generator = Gen.int (Range.linear 0 upper)
      in if kind `elem` ["Char", "Text"]
         then Gen.filter (\point -> point < 55296 || point > 57343) generator
         else generator
