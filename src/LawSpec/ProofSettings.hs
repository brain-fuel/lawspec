-- | A harness's `prove ...` settings (LawSpec.Model.Proving), as each law's
-- proof plan for lawspec prove (LawSpec.Core.Smt.LawProof). A setting before
-- the first `for` applies to every law of the unit; a law's own `for` block
-- overrides it. Cited laws must be laws of the same unit, and citations may
-- not form a cycle. ref:DEC-smt-induction
module LawSpec.ProofSettings (proofSettings) where

import Control.Monad (forM, forM_, when)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import LawSpec.Common
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Smt as Smt
import qualified LawSpec.Model as S

proofSettings :: [S.Unit] -> Either [Diagnostic] (M.Map C.Id Smt.LawProof)
proofSettings units = do
  plans <- concat <$> forM units unitPlans
  let table = M.fromList plans
      cites = [ (law, law, lemmas) | (law, Smt.LawProof _ (Smt.InductionOn _ lemmas)) <- plans ]
  forM_ (stronglyConnComp cites) $ \component -> case component of
    CyclicSCC laws -> Left [Diagnostic "harness" ("laws cite each other in a cycle: " ++
      intercalate " cites " (map shown (laws ++ take 1 laws)) ++ "; a law cannot rest on itself") Nothing]
    AcyclicSCC _ -> Right ()
  pure table
  where
    shown (C.Id text) = case breakLaw text of (_, name) -> name
    breakLaw text = go "" text
      where go before rest = case rest of
              ':' : ':' : 'l' : 'a' : 'w' : ':' : ':' : name -> (reverse before, name)
              c : more -> go (c : before) more
              [] -> (text, text)

unitPlans :: S.Unit -> Either [Diagnostic] [(C.Id, Smt.LawProof)]
unitPlans u = case S.unitHarness u of
  Nothing -> Right []
  Just harness -> do
    let items = S.harnessItems harness
        defaults = [(p, range) | S.HarnessDefault (S.ProveSetting p) range <- items]
        blocks = [(names, [(p, range) | (S.ProveSetting p, range) <- settings]) | S.HarnessFor names settings _ <- items]
        lawNames = map S.lawName (S.laws u)
        identity name = C.Id (S.unitName u ++ "::law::" ++ name)
    base <- plan Nothing defaults
    named <- forM [(name, own) | (names, own) <- blocks, not (null own), name <- names] $ \(name, own) -> do
      chosen <- plan (Just name) own
      pure (name, chosen)
    let laws = M.fromListWith (\new old -> combine old new) [(name, p) | (name, p) <- named]
    resolved <- forM (if null defaults then M.toList laws else [(name, M.findWithDefault blank name laws) | name <- lawNames]) $ \(name, own) -> do
      let Partial unfolding induction = combine base own
      lemmas <- case induction of
        Just (Smt.InductionOn input cited) -> do
          forM_ cited $ \(C.Id lemma) -> do
            when (lemma `notElem` lawNames) (problem ("prove by induction on " ++ input ++ " using " ++ lemma ++
              ": the unit has no law " ++ lemma))
            when (lemma == name) (problem ("prove by induction on " ++ input ++ ": the law " ++ name ++ " cannot cite itself"))
          pure (Just (Smt.InductionOn input [identity lemma | C.Id lemma <- cited]))
        other -> pure other
      pure (identity name, Smt.LawProof (maybe (Smt.proofUnfolding Smt.defaultLawProof) id unfolding)
                                        (maybe Smt.DefaultInduction id lemmas))
    pure resolved
  where
    problem message = Left [Diagnostic "harness" message Nothing]

-- | A law's settings so far: the encoding and induction, each if given.
data Partial = Partial (Maybe Smt.Unfolding) (Maybe Smt.Induction)

blank :: Partial
blank = Partial Nothing Nothing

-- | The later settings win, each part separately.
combine :: Partial -> Partial -> Partial
combine (Partial u i) (Partial u' i') = Partial (maybe u Just u') (maybe i Just i')

-- | One level's settings (the defaults, or one law's block): at most one
-- encoding and one induction setting.
plan :: Maybe String -> [(S.Proving, Span)] -> Either [Diagnostic] Partial
plan owner settings = do
  let encodings = [(e, r) | (p, r) <- settings, Just e <- [encoding p]]
      inductions = [(i, r) | (p, r) <- settings, Just i <- [induction p]]
      at range = Just (spanStart range)
      whose = maybe "the harness's defaults" ("the law " ++) owner
  case encodings of
    _ : (_, r) : _ -> Left [Diagnostic "harness" ("two prove by settings choose how " ++ whose ++ " unfolds recursion") (at r)]
    _ -> Right ()
  case inductions of
    _ : (_, r) : _ -> Left [Diagnostic "harness" ("two induction settings for " ++ whose) (at r)]
    _ -> Right ()
  pure (Partial (fst <$> headMay encodings) (fst <$> headMay inductions))
  where
    headMay xs = case xs of
      x : _ -> Just x
      [] -> Nothing
    encoding p = case p of
      S.ProveByUnfolding fuel False -> Just (Smt.Unfold (maybe Smt.defaultFuel fromInteger fuel))
      S.ProveByUnfolding fuel True -> Just (Smt.UnfoldThenSolver (maybe Smt.defaultFuel fromInteger fuel))
      S.ProveBySolverRecursion -> Just Smt.SolverRecursion
      _ -> Nothing
    induction p = case p of
      S.ProveByInduction input lemmas -> Just (Smt.InductionOn input (map C.Id lemmas))
      S.ProveWithoutInduction -> Just Smt.NoInduction
      _ -> Nothing
