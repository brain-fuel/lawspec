-- Railway combinators on Either e a. Each is written as a symbol or as a
-- prelude name, and is rewritten into match expressions while the unit is
-- parsed, so type inference, Core and every target see only ordinary matches.
-- A function given to a combinator is a named adapter or definition, a partial
-- application or a composition; after the rewrite it is applied to a value,
-- so checked definitions stay first-order.
--
--   symbol   English                  meaning
--   m >>= f  prelude.bind m f         continue with f on Right
--            prelude.then m f
--   f <$> m  prelude.map f m          map the success value
--   g <!> m  prelude.mapError g m     map the error
--   m <|> h  prelude.orElse m h       recover with a fallible handler h e
--   m ?? v   prelude.fallback m v     the success value, or v on failure
--            prelude.fromEither v m
--   f >=> g  prelude.andThen f g      compose fallible functions (applied)
--   x |> f   prelude.pipe x f         f x
--   m <*> n  prelude.both m n         both successes as a Pair, else the first error
--            prelude.ensure p e m     fail with e unless p holds of the value
--            prelude.isLeft m, prelude.isRight m
module LawSpec.Railway (railwayUnit, railwayLaw, railwayExpr, railwayOperators, usesPair) where

import Control.Monad.State.Strict (State, evalState, get, put)
import Data.List (isInfixOf)
import qualified Data.Set as S
import LawSpec.Model

-- The symbols, loosest last, as the parser binds them.
railwayOperators :: [String]
railwayOperators = [">=>", "<$>", "<!>", "<*>", ">>=", "<|>", "??", "|>"]

-- Whether a source uses pairs, which the collections unit provides.
usesPair :: String -> Bool
usesPair text = "<*>" `isInfixOf` text || "prelude.both" `isInfixOf` text

railwayLaw :: Law -> Law
railwayLaw l = case laws (railwayUnit emptyUnit { laws = [l] }) of
  [rewritten] -> rewritten
  _ -> l
  where emptyUnit = Unit "" [] [] [] [] [] [] [] [] [] [] []

railwayUnit :: Unit -> Unit
railwayUnit u = u
  { functions = [(n, typ t) | (n, t) <- functions u]
  , laws = map law (laws u)
  , refinements = [r { refinementParameters = [(n, typ t) | (n, t) <- refinementParameters r]
                     , refinementBody = typ (refinementBody r) } | r <- refinements u]
  , contracts = [c { contractArguments = [(n, typ t) | (n, t) <- contractArguments c]
                   , contractResult = let (n, t) = contractResult c in (n, typ t)
                   , contractPreconditions = map railwayExpr (contractPreconditions c)
                   , contractPostconditions = map railwayExpr (contractPostconditions c) } | c <- contracts u]
  , dataTypes = [d { dataTypeConstructors = [k { dataConstructorFields = [(n, typ t) | (n, t) <- dataConstructorFields k] }
                                            | k <- dataTypeConstructors d] } | d <- dataTypes u]
  , functionDefinitions = [f { functionArguments = [(n, typ t) | (n, t) <- functionArguments f]
                             , functionResult = typ (functionResult f)
                             , functionBody = railwayExpr (functionBody f) } | f <- functionDefinitions u]
  }
  where
    typ = mapType id railwayExpr
    law l = l { parameters = [(n, typ t) | (n, t) <- parameters l], definition = definition' (definition l)
              , examples = [x { expectations = [c { actual = railwayExpr (actual c) } | c <- expectations x] } | x <- examples l] }
    definition' d = case d of
      Forall bs body -> Forall [(n, typ t) | (n, t) <- bs] (definition' body)
      Equal a b -> Equal (railwayExpr a) (railwayExpr b)
      Holds a -> Holds (railwayExpr a)
      Implies g body -> Implies (railwayExpr g) (definition' body)
      And a b -> And (definition' a) (definition' b)
      Invoke n args -> Invoke n (map railwayExpr args)

railwayExpr :: Expr -> Expr
railwayExpr e = evalState (go e) 0
  where
    taken = S.fromList (names e)
    fresh :: String -> State Int String
    fresh base = do
      n <- get
      put (n + 1)
      let candidate = base ++ show n
      if S.member candidate taken then fresh base else pure candidate
    go :: Expr -> State Int Expr
    go expression = descend expression >>= rewrite
    descend expression = case expression of
      Located range a -> Located range <$> go a
      Apply a b -> Apply <$> go a <*> go b
      Compose a b -> Compose <$> go a <*> go b
      ListLit xs -> ListLit <$> mapM go xs
      ConstructLit n xs -> ConstructLit n <$> mapM go xs
      MatchExpr s bs -> MatchExpr <$> go s <*> mapM (\(MatchBranch t ns b) -> MatchBranch t ns <$> go b) bs
      AllElementsExpr a n b -> (\x y -> AllElementsExpr x n y) <$> go a <*> go b
      AllPayloadsExpr a fs -> AllPayloadsExpr <$> go a <*> mapM (\(n, x) -> (,) n <$> go x) fs
      Binary op a b -> Binary op <$> go a <*> go b
      Unary op a -> Unary op <$> go a
      Annotate a t -> (`Annotate` t) <$> go a
      _ -> pure expression
    rewrite expression = case unlocated expression of
      Binary ">>=" m f -> bind m f
      Binary "<$>" f m -> mapping f m
      Binary "<!>" g m -> mapError g m
      Binary "<|>" m h -> orElse m h
      Binary "??" m v -> fallback m v
      Binary "|>" x f -> apply f x
      Binary "<*>" m n -> both m n
      Apply f x | composed f -> apply f x
      _ -> case spine expression of
        (Var "prelude.bind", [m, f]) -> bind m f
        (Var "prelude.then", [m, f]) -> bind m f
        (Var "prelude.map", [f, m]) -> mapping f m
        (Var "prelude.mapError", [g, m]) -> mapError g m
        (Var "prelude.orElse", [m, h]) -> orElse m h
        (Var "prelude.fallback", [m, v]) -> fallback m v
        (Var "prelude.fromEither", [v, m]) -> fallback m v
        (Var "prelude.andThen", [f, g, x]) -> apply f x >>= \first -> bind first g
        (Var "prelude.pipe", [x, f]) -> apply f x
        (Var "prelude.both", [m, n]) -> both m n
        (Var "prelude.ensure", [p, failure, m]) -> ensure p failure m
        (Var "prelude.isLeft", [m]) -> side True m
        (Var "prelude.isRight", [m]) -> side False m
        _ -> pure expression
    eitherMatch m onLeft onRight = do
      e <- fresh "railwayError"
      v <- fresh "railwayValue"
      pure (MatchExpr m [MatchBranch "Either::Left" [e] (onLeft (Var e)), MatchBranch "Either::Right" [v] (onRight (Var v))])
    -- Constructors are named by identity, so a unit's own Left or Right
    -- does not make them ambiguous.
    left x = ConstructLit "Either::Left" [x]
    right x = ConstructLit "Either::Right" [x]
    -- Applying a fallible composition f >=> g (or prelude.andThen f g)
    -- binds; any other function is applied as written.
    composed f = case unlocated f of
      Binary ">=>" _ _ -> True
      _ -> case spine f of (Var "prelude.andThen", [_, _]) -> True; _ -> False
    apply f x = case unlocated f of
      Binary ">=>" g h -> apply g x >>= \first -> bind first h
      _ | (Var "prelude.andThen", [g, h]) <- spine f -> apply g x >>= \first -> bind first h
        | otherwise -> pure (Apply f x)
    -- A literal Right or Left decides the match: Right x >>= f is f x.
    eitherMatchM m onLeft onRight
      | ConstructLit tag [v] <- unlocated m, tag `elem` ["Right", "Either::Right"] = onRight v
      | ConstructLit tag [e] <- unlocated m, tag `elem` ["Left", "Either::Left"] = onLeft e
    eitherMatchM m onLeft onRight = do
      e <- fresh "railwayError"
      v <- fresh "railwayValue"
      l <- onLeft (Var e)
      r <- onRight (Var v)
      pure (MatchExpr m [MatchBranch "Either::Left" [e] l, MatchBranch "Either::Right" [v] r])
    bind m f = eitherMatchM m (pure . left) (apply f)
    mapping f m = eitherMatchM m (pure . left) (fmap right . apply f)
    mapError g m = eitherMatchM m (fmap left . apply g) (pure . right)
    orElse m h = eitherMatchM m (apply h) (pure . right)
    fallback m v = eitherMatch m (const v) id
    side isLeft m = eitherMatch m (const (BoolLit isLeft)) (const (BoolLit (not isLeft)))
    both m n = do
      e <- fresh "railwayError"
      first <- fresh "railwayValue"
      second <- eitherMatch n left (\b -> right (ConstructLit "Pair" [Var first, b]))
      pure (MatchExpr m [MatchBranch "Either::Left" [e] (left (Var e)), MatchBranch "Either::Right" [first] second])
    ensure p failure m = eitherMatchM m (pure . left) (\v -> do
      holds <- apply p v
      pure (Apply (Apply (Apply (Var "prelude.select") holds) (right v)) (left failure)))
    spine x = case unlocated x of
      Apply a b -> let (h, as) = spine a in (h, as ++ [b])
      other -> (other, [])

-- Every name in an expression, bound or free.
names :: Expr -> [String]
names expression = case expression of
  Located _ a -> names a
  Var n -> [n]
  Apply a b -> names a ++ names b
  Compose a b -> names a ++ names b
  ListLit xs -> concatMap names xs
  ConstructLit _ xs -> concatMap names xs
  MatchExpr s bs -> names s ++ concat [ns ++ names b | MatchBranch _ ns b <- bs]
  AllElementsExpr a n b -> n : names a ++ names b
  AllPayloadsExpr a fs -> names a ++ concat [n : names x | (n, x) <- fs]
  Binary _ a b -> names a ++ names b
  Unary _ a -> names a
  Annotate a _ -> names a
  _ -> []
