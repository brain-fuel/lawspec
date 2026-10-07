-- | Native Hedgehog generation and shrinking for checked Core schemas.
--
-- Generated tests run in Hedgehog, under Hspec, so failures shrink and report
-- as Haskell developers expect; the generators are built from Hedgehog's own so
-- its integrated shrinking reduces counterexamples and shrinking stays within
-- the declared domain. ref:DEC-native-property-frameworks ref:hedgehog
-- ref:DEC-shrink-within-domain
module LawSpecDataStrategies
  (strategy, checkedStrategy, checkedStrategyWith, primitiveStrategy
  , indexedStrategy, NativeFactory, nativeValues, nativeArguments) where

import Control.Monad (unless, when, foldM)
import Control.Monad.State.Strict (StateT, evalStateT, get, modify, lift)
import Data.List (nub)
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
import qualified LawSpecCodecs as Codec

-- | Factories return native Hedgehog trees; fmap preserves their shrink structure.
type NativeFactory = S.TypeRef -> [Gen LS.Scalar]
                   -> Either String (Gen LS.Scalar)

nativeValues :: Codec.Codec a -> Gen a -> Gen LS.Scalar
nativeValues codec = fmap $ \value ->
  case Codec.encode codec value of
    Left message -> error ("native generator: " ++ message)
    Right logical -> LS.forceScalar logical `seq` logical

nativeArguments :: Codec.Codec a -> Gen LS.Scalar -> Gen a
nativeArguments codec = fmap $ \value ->
  either (error . ("native generator argument: " ++)) id
    (Codec.decode codec value)

type Cache = Map.Map (S.TypeRef, Int) (Maybe (Gen LS.Scalar))
type Build = StateT Cache (Either String)

strategy :: S.Schema -> S.TypeRef -> Int -> Int
         -> (String -> Either String (Gen LS.Scalar))
         -> Either String (Gen LS.Scalar)
strategy schema reference bits budget scalar = do
  when (S.hasContracts schema)
    (Left "constructor contracts require checked strategies")
  buildStrategy schema reference bits budget scalar (\_ _ -> id)

-- | Predicate failures are native discards. Evaluation errors remain exceptions,
-- which Hedgehog reports as property failures rather than retrying them.
-- filterT prunes rejected shrink subtrees: searching every descendant of a
-- sparse identity predicate can otherwise make shrinking effectively unbounded.
checkedStrategy :: S.Schema -> S.TypeRef -> Int -> Int -> Maybe LS.SymbolContext
                -> [LS.Scalar] -> (String -> Either String (Gen LS.Scalar))
                -> Either String (Gen LS.Scalar)
checkedStrategy = checkedStrategyWith []

checkedStrategyWith :: [(String, NativeFactory)]
                    -> S.Schema -> S.TypeRef -> Int -> Int -> Maybe LS.SymbolContext
                    -> [LS.Scalar] -> (String -> Either String (Gen LS.Scalar))
                    -> Either String (Gen LS.Scalar)
checkedStrategyWith factories schema reference bits budget scope witnesses scalar = do
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
  generated <- buildStrategyWith factories schema reference bits budget scalar finish
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
        expected:_ -> do
          types <- S.witnessKeys schema tag fields >>= S.witnessed schema tag [ty | S.Field _ ty <- expected]
          foldM (\acc (ty, child) -> indexWitness schema ty acc child)
            indexed (zip types fields)
        [] -> pure indexed
    _ -> pure indexed

buildStrategy :: S.Schema -> S.TypeRef -> Int -> Int
              -> (String -> Either String (Gen LS.Scalar))
              -> (S.TypeRef -> Int -> Gen LS.Scalar -> Gen LS.Scalar)
              -> Either String (Gen LS.Scalar)
buildStrategy = buildStrategyWith []

buildStrategyWith :: [(String, NativeFactory)]
                  -> S.Schema -> S.TypeRef -> Int -> Int
                  -> (String -> Either String (Gen LS.Scalar))
                  -> (S.TypeRef -> Int -> Gen LS.Scalar -> Gen LS.Scalar)
                  -> Either String (Gen LS.Scalar)
buildStrategyWith factories schema reference bits budget scalar finish = do
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
          -- A custom distribution owns its samples and shrink tree. It must
          -- never acquire fallback witnesses or discard invalid native values.
          result <- case ty of
            S.Named name arguments | Just factory <- lookup name factories -> do
              -- A native factory may ignore a phantom parameter. Discard only
              -- if it actually requests a value from an uninhabited child.
              children <- mapM (\child -> maybe Gen.discard id <$>
                build child (available - 1)) arguments
              Just <$> lift (factory ty children)
            _ -> fmap (finish ty available) <$> assemble ty available
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

    variant available (S.Constructor tag fields) = variantWith available tag fields []

    -- Witness values follow the generated declared fields.
    variantWith available tag fields witnesses = do
      costs <- allocation fields (available - 1)
      case costs of
        Nothing -> pure Nothing
        Just amounts -> do
          children <- sequence <$> sequence
            [build ty amount | (S.Field _ ty, amount) <- zip fields amounts]
          pure
            ((\generators -> LS.SData tag . (++ witnesses) <$> sequence generators) <$> children)

    -- A field-only existential takes each type of the witness pool.
    witnessVariants available constructor@(S.Constructor tag _) = do
      choices <- lift (S.witnessChoices schema constructor)
      mapM (\(fields, witnesses) -> variantWith available tag fields witnesses) choices

    assemble ty available = do
      constructors <- lift (S.constructors schema ty)
      case constructors of
        Just variants -> do
          generator <- concat <$> mapM (witnessVariants available) variants >>= alternatives
          -- Generated collections are canonicalised rather than filtered.
          pure (case ty of
            S.Named name _ | name `elem` ["lawspec.collections::type::Set", "lawspec.collections::type::KeyVal"] ->
              fmap (fmap (canonical (name == "lawspec.collections::type::KeyVal"))) generator
            _ -> generator)
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

-- | Values whose structural index equals the target. Each constructor carries
-- its index term then its guards, in prefix notation over field indices
-- (f<i>), literals (c<n>) and + - * div mod ^, with == and >= guards. Indices
-- are naturals: subtraction never goes below zero. Reachability is a forward
-- least fixpoint over levels 0..target+slack, so children may exceed their
-- parent's index; generation then solves the target backwards, never filters,
-- and Gen.element shrinks each choice toward smaller field indices.
data IndexTerm = IndexConstant Integer | IndexField Int | IndexOp String IndexTerm IndexTerm

parseIndexTerm :: [String] -> Either String (IndexTerm, [String])
parseIndexTerm tokens = case tokens of
  ('c' : digits) : rest -> Right (IndexConstant (read digits), rest)
  ('f' : digits) : rest -> Right (IndexField (read digits), rest)
  op : rest | op `elem` ["+", "-", "*", "div", "mod", "^"] -> do
    (a, afterA) <- parseIndexTerm rest
    (b, afterB) <- parseIndexTerm afterA
    Right (IndexOp op a b, afterB)
  _ -> Left "malformed index term"

evalIndexTerm :: Map.Map Int Integer -> IndexTerm -> Maybe Integer
evalIndexTerm fields term = case term of
  IndexConstant n -> Just n
  IndexField i -> Map.lookup i fields
  IndexOp op a b -> do
    x <- evalIndexTerm fields a
    y <- evalIndexTerm fields b
    case op of
      "+" -> Just (x + y)
      "-" | x >= y -> Just (x - y)
      "*" -> Just (x * y)
      "div" | y > 0 -> Just (x `div` y)
      "mod" | y > 0 -> Just (x `mod` y)
      "^" | y >= 0 && y <= 64 -> Just (x ^ y)
      _ -> Nothing

indexTermFields :: IndexTerm -> [Int]
indexTermFields term = case term of
  IndexField i -> [i]
  IndexOp _ a b -> indexTermFields a ++ indexTermFields b
  _ -> []

indexSlack :: Integer
indexSlack = 16

indexChoices :: Int
indexChoices = 6

indexedStrategy :: S.Schema -> S.TypeRef -> Int -> Int -> LS.Scalar
                -> [(String, [String])]
                -> (String -> Either String (Gen LS.Scalar))
                -> Either String (Gen LS.Scalar)
indexedStrategy schema reference bits budget target equations scalar = do
  requested <- case target of
    LS.SInteger _ n -> Right n
    _ -> Left "index target must be an integer"
  let limit = max requested 0 + indexSlack
      parse text = do
        (term, rest) <- parseIndexTerm (words text)
        unless (null rest) (Left "malformed index term")
        Right term
      guardOf text = case words text of
        relation : rest | relation `elem` ["==", ">="] -> do
          (a, afterA) <- parseIndexTerm rest
          (b, afterB) <- parseIndexTerm afterA
          unless (null afterB) (Left "malformed index guard")
          Right (relation, a, b)
        _ -> Left "malformed index guard"
      details ty = do
        constructors <- S.constructors schema ty
        variants <- maybe (Left "indexed generation requires a data type") Right constructors
        mapM (\(S.Constructor tag fields) -> do
          texts <- maybe (Left ("missing index equation for " ++ tag)) Right (lookup tag equations)
          (term, guards) <- case texts of
            first : rest -> (,) <$> parse first <*> mapM guardOf rest
            [] -> Left ("missing index equation for " ++ tag)
          let positions = nub (indexTermFields term ++ concat [indexTermFields a ++ indexTermFields b | (_, a, b) <- guards])
          pure (tag, fields, term, guards, positions)) variants
      indexTypes (_, fields, _, _, positions) = [ty | (i, S.Field _ ty) <- zip [0 ..] fields, i `elem` positions]
      explore seen [] = pure seen
      explore seen (ty : rest)
        | ty `elem` map fst seen = explore seen rest
        | otherwise = do
            variants <- details ty
            explore ((ty, variants) : seen) (concatMap indexTypes variants ++ rest)
  families <- explore [] [reference]
  let plainFields (_, fields, _, _, positions) =
        [ty | (i, S.Field _ ty) <- zip [0 ..] fields, i `notElem` positions]
      plain = Map.fromList [(ty, either (const Nothing) Just
        (buildStrategy schema ty bits budget scalar (\_ _ -> id)))
        | ty <- nub (concatMap plainFields (concatMap snd families))]
      plainReady variant = all (\ty -> maybe False (const True)
        (Map.findWithDefault Nothing ty plain)) (plainFields variant)
      fieldType (_, fields, _, _, _) i = case drop i fields of
        S.Field _ ty : _ -> ty
        [] -> error "index field out of range"
      -- Every assignment of reachable indices to the variant's index fields
      -- that satisfies its guards, with the index it produces.
      assignments table variant@(_, _, term, guards, positions) =
        [ (value, assignment)
        | assignment <- mapM (\i -> [(i, v) | v <- [0 .. limit],
            Map.findWithDefault False (fieldType variant i, v) table]) positions
        , let fields = Map.fromList assignment
        , all (holds fields) guards
        , Just value <- [evalIndexTerm fields term]
        , value <= limit ]
      holds fields (relation, a, b) = case (evalIndexTerm fields a, evalIndexTerm fields b) of
        (Just x, Just y) -> if relation == "==" then x == y else x >= y
        _ -> False
      step table = foldr (\(ty, variants) acc -> foldr (\variant inner ->
          if plainReady variant
            then foldr (\(value, _) t -> Map.insert (ty, value) True t) inner (assignments table variant)
            else inner) acc variants) table families
      fixpoint table = let next = step table in if next == table then table else fixpoint next
      table = fixpoint Map.empty
      variantsOf ty = maybe [] id (lookup ty families)
      generate ty j = do
        let options = [ (variant, choices) | variant <- variantsOf ty, plainReady variant
                      , let choices = [assignment | (value, assignment) <- assignments table variant, value == j]
                      , not (null choices) ]
        ((tag, fields, _, _, _), choices) <- Gen.element options
        assignment <- Gen.element choices
        values <- mapM (\(i, S.Field _ ty) -> case lookup i assignment of
          Just index -> generate ty index
          Nothing -> maybe (error "uninhabited field in indexed generation") id
            (Map.findWithDefault Nothing ty plain)) (zip [0 ..] fields)
        pure (LS.SData tag values)
  -- An open target (negative), or one drawn from earlier inputs that breaks
  -- their preconditions or names no value, generates from the smallest
  -- reachable indices; an index claim rejects a mismatch.
  let reachable level = Map.findWithDefault False (reference, level) table
      levels = if reachable requested then [requested]
        else take indexChoices (filter reachable [0 .. limit])
  when (null levels) (Left ("no value of " ++ show reference ++ " has an index"))
  pure (either error id . S.validateWith Nothing schema reference bits <$> (Gen.element levels >>= generate reference))

-- | Primitive shrinkers remain in Hedgehog: integers, lists, and IEEE bit words.
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

-- | A Set's or KeyVal's items in canonical order.
canonical :: Bool -> LS.Scalar -> LS.Scalar
canonical keyed value = case value of
  LS.SData tag [LS.SList items] -> LS.SData tag [LS.SList (LS.canonicalItems keyed items)]
  _ -> value
