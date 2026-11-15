-- | A harness's `prove ...` settings (LawSpec.Model.Proving), as each law's
-- proof plan for lawspec prove (LawSpec.Core.Smt.LawProof). A setting before
-- the first `for` applies to every law of the unit; a law's own `for` block
-- overrides it. A cited law is a law of the same unit or, when the unit has
-- none of that name, a capability law (LawSpec.CapabilityLaws); citations
-- may not form a cycle. ref:DEC-smt-induction ref:DEC-capability-laws
module LawSpec.ProofSettings (proofSettings, capabilityLawTasks, capabilityLawKeys, capabilityLawKey, capabilityCitation) where

import Control.Monad (forM, forM_, when)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Aeson (Value(..), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import qualified Data.Text as T
import LawSpec.CapabilityLaws (capabilityLaws, capabilityLawsProgram)
import LawSpec.CapabilityReceipts (capabilityReceipts)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Common
import LawSpec.Instances (instanceLawsUnit)
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Smt as Smt
import qualified LawSpec.Model as S

proofSettings :: [S.Unit] -> Either [Diagnostic] (M.Map C.Id Smt.LawProof)
proofSettings units = do
  plans <- concat <$> forM units unitPlans
  let table = M.fromList plans
      cites = [ (law, law, lemmas) | (law, Smt.LawProof _ (Smt.InductionOn _ lemmas) _) <- plans ]
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
            when (lemma `notElem` lawNames && not (capability lemma)) (problem ("prove by induction on " ++ input ++ " using " ++ lemma ++
              ": the unit has no law " ++ lemma ++ ", and no capability law has that name"))
            when (lemma == name) (problem ("prove by induction on " ++ input ++ ": the law " ++ name ++ " cannot cite itself"))
          pure (Just (Smt.InductionOn input [if lemma `elem` lawNames then identity lemma else general lemma | C.Id lemma <- cited]))
        other -> pure other
      -- A capability law is cited on its receipt: LawSpec's own checks
      -- proved the law as it is now.
      let library = case lemmas of
            Just (Smt.InductionOn _ cited) | general@(_ : _) <- filter (`notElem` map identity lawNames) cited ->
              Just (mapM_ (capabilityCitation capabilityReceipts capabilityLawKeys) general >> capabilityLaws)
            _ -> Nothing
      pure (identity name, Smt.LawProof (maybe (Smt.proofUnfolding Smt.defaultLawProof) id unfolding)
                                        (maybe Smt.DefaultInduction id lemmas) library)
    pure resolved
  where
    problem message = Left [Diagnostic "harness" message Nothing]
    general name = C.Id (instanceLawsUnit ++ "::law::" ++ name)
    capability name = either (const False) (any ((== general name) . C.propertyId) . C.unitProperties) capabilityLaws

-- | The capability laws' proof tasks, as their unit's harness has them
-- proved.
capabilityLawTasks :: Either String [Smt.ProofTask]
capabilityLawTasks = do
  (units, program) <- capabilityLawsProgram
  either (Left . unwords . map message) Right $ do
    plans <- concat <$> forM units unitPlans
    tasks <- Smt.proofTasksWith (M.fromList plans) program
    pure [t | t <- tasks, Smt.taskOwner t == C.Id instanceLawsUnit]

-- | What a capability law's receipt is bound to: every script its proof
-- runs, which holds the law, the instance definitions it unfolds and the
-- encoding of both. ref:DEC-capability-laws
capabilityLawKey :: Smt.ProofTask -> String
capabilityLawKey task = digestHex (digestString (concatMap frame ("lawspec.capability-receipt.v1" : scripts (toJSON task))))
  where
    frame text = show (length text) ++ ":" ++ text
    scripts value = case value of
      Object fields -> concat [ case (Key.toText key, field) of
                                  (name, String script) | name == T.pack "script" -> [T.unpack script]
                                  _ -> scripts field
                              | (key, field) <- K.toList fields ]
      Array items -> concatMap scripts (toList items)
      _ -> []

capabilityLawKeys :: Either String [(C.Id, String)]
capabilityLawKeys = map (\t -> (Smt.taskLaw t, capabilityLawKey t)) <$> capabilityLawTasks

-- | Whether a capability law may be cited: its receipt is for the law as it
-- is now.
capabilityCitation :: [(String, String)] -> Either String [(C.Id, String)] -> C.Id -> Either String ()
capabilityCitation receipts keys law = do
  current <- keys
  let name = case C.idText law of text -> drop (length (instanceLawsUnit ++ "::law::")) text
  case (lookup (C.idText law) receipts, lookup law current) of
    (Just receipt, Just key) | receipt == key -> Right ()
    (Nothing, _) -> Left ("cited law " ++ name ++ ": LawSpec has no receipt of its proof, so it cannot be cited")
    _ -> Left ("cited law " ++ name ++ ": its receipt is for an earlier form of the law or of its encoding (lawspec-dev capability-receipts renews it)")

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
