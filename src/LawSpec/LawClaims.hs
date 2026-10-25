-- | `laws for f are ... end laws` (LawSpec.Model.LawClaims), elaborated for
-- the law-set analysis (LawSpec.Core.LawAnalysis), and the analysis rows
-- turned into evidence: an exemption that has not expired excuses a
-- check's counterexample; one past its version or UTC date-time no longer
-- does, and the check is refuted. ref:DEC-law-set-analysis
module LawSpec.LawClaims
  ( elaborateClaims, Expiry(..), analysisEvidence, exemptionView, analysisTaskViews, settleAnalysis
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson.Key
import Data.Char (isDigit)
import qualified Data.Map.Strict as M
import LawSpec.Common
import qualified LawSpec.Core as C
import qualified LawSpec.Core.LawAnalysis as A
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.Elaboration (elaborateResolvedWithData)
import qualified LawSpec.Core.LawTasks as Tasks
import LawSpec.Core.Smt (encodingName, Encoding(..))
import qualified LawSpec.Model as S

-- | Each block's function must be in its unit; `complete over` must name a
-- checked definition's arguments; a claim and the exemption of the same
-- check cannot both be written; `vacuity allowed for` names a law.
elaborateClaims :: Int -> [S.Unit] -> C.Program -> Either [Diagnostic] (M.Map C.Id A.Claims)
elaborateClaims bits units program = M.fromList . concat <$> forM units (\u -> forM (S.lawClaims u) (claimsOf u))
  where
    claimsOf u block = do
      let name = S.claimsFunction block
          f = C.Id (S.unitName u ++ "::" ++ name)
          at = Just (spanStart (S.claimsSpan block))
          problem message = Left [Diagnostic "laws-for" ("laws for " ++ name ++ ": " ++ message) at]
          items = map fst (S.claimsItems block)
          kinds = [kind | S.Exempt kind _ _ <- items]
      unless (f `elem` [C.declarationId d | cu <- C.programUnits program, d <- C.unitDeclarations cu])
        (problem ("the unit " ++ S.unitName u ++ " has no function " ++ name))
      when (S.WithoutOverlap `elem` items && S.OverlapExemption `elem` kinds)
        (problem "it claims without overlap and allows overlap")
      when (S.WithoutConflict `elem` items && S.ConflictExemption `elem` kinds)
        (problem "it claims without conflict and allows conflict")
      when (any isComplete items && S.PartialExemption `elem` kinds)
        (problem "it claims complete over a condition and is partial")
      when (length (filter isComplete items) > 1) (problem "it has more than one complete over")
      forM_ [law | S.VacuityExemption law <- kinds] $ \law ->
        unless (law `elem` map S.lawName (S.laws u)) (problem ("the unit has no law " ++ law))
      complete <- case [e | S.CompleteOver e <- items] of
        [] -> pure Nothing
        e : _ -> case [d | d <- S.functionDefinitions u, S.functionName d == name] of
          [definition] -> do
            let core = [d | cu <- C.programUnits program, d <- C.unitDefinitions cu, C.declarationId (C.definitionDeclaration d) == f]
            binders <- case core of
              d : _ -> pure (C.definitionArguments d)
              [] -> problem "complete over needs a checked definition"
            let parameters = S.functionArguments definition
                table = zip (map fst parameters) (map C.binderId binders)
                resolve n = maybe (C.Id (S.unitName u ++ "::" ++ n)) id (lookup n table)
            either (\message -> problem ("complete over: " ++ message)) (pure . Just)
              (elaborateResolvedWithData (C.programDataDeclarations program)
                [C.declarationId d | cu <- C.programUnits program, d <- C.unitDeclarations cu]
                bits (C.Id (C.idText f ++ "::complete-over")) resolve parameters e)
          _ -> problem "complete over names the arguments of a checked definition; an adapter has none"
      let exemptions = [ A.Exemption (check kind) (law kind) (fmap expiry until) reason | S.Exempt kind until reason <- items ]
      pure (f, A.Claims f complete exemptions)
    isComplete (S.CompleteOver _) = True
    isComplete _ = False
    check kind = case kind of
      S.PartialExemption -> A.Completeness
      S.OverlapExemption -> A.Overlap
      S.ConflictExemption -> A.Conflict
      S.VacuityExemption _ -> A.Vacuity
    law (S.VacuityExemption name) = Just name
    law _ = Nothing
    expiry (S.UntilVersion v) = A.UntilVersion v
    expiry (S.UntilTime t) = A.UntilTime t

-- | What an exemption's expiry is compared with: the project's version and
-- the current UTC time, from the request.
data Expiry = Expiry { expiryVersion :: Maybe String, expiryNow :: Maybe String }

-- | The analysis rows as evidence, and the exemption each row shows.
analysisEvidence :: Bool -> Bool -> Bool -> Expiry -> [A.Row] -> Either [Diagnostic] [(Obligation, Maybe Value)]
analysisEvidence ran proof solved expiry rows = forM rows $ \row -> do
  let obligation status reason = Obligation (A.rowUnit row) (A.rowFunction row) (A.checkStage (A.rowCheck row)) Nothing status reason
  case A.rowExemption row of
    Nothing -> pure (plain obligation (A.rowOutcome row), Nothing)
    Just e -> do
      (expired, against) <- expiredAt expiry e
      let excuse = "excused" ++ maybe "" (\u -> " until " ++ untilText u ++ against) (A.exemptUntil e) ++ " because " ++ show (A.exemptReason e)
          view = Just (exemptionView e expired)
      pure $ case A.rowOutcome row of
        A.Fails counterexample
          | expired -> (obligation Refuted (counterexample ++ "; the exemption expired (" ++ excuse ++ ")"), view)
          | otherwise -> (obligation Exempted (excuse ++ "; " ++ counterexample), view)
        A.Holds why -> (plain obligation (A.Holds (why ++ "; the exemption is not needed")), view)
        A.Proven why -> (plain obligation (A.Proven (why ++ "; the exemption is not needed")), view)
        outcome | expired -> (plain obligation outcome, view)
                | otherwise -> (obligation Exempted (excuse ++ "; " ++ reasonOf outcome), view)
  where
    plain obligation outcome = case outcome of
      _ | not ran -> obligation NotVerified "no law verification layers selected"
      A.Holds why -> obligation ExhaustivelyChecked why
      A.Proven why -> obligation Proved why
      A.Fails counterexample -> obligation Refuted counterexample
      A.Undecided why | solved -> obligation Incomplete why
                      | proof -> obligation Planned (why ++ "; lawspec prove runs it")
                      | otherwise -> obligation Incomplete (why ++ "; select the proof layer to run it with Z3")
      A.Unsupported why -> obligation Unsupported why
    reasonOf outcome = case outcome of
      A.Holds why -> why
      A.Fails why -> why
      A.Undecided why -> why
      A.Unsupported why -> why
      A.Proven why -> why

exemptionView :: A.Exemption -> Bool -> Value
exemptionView e expired = object
  [ "reason" .= A.exemptReason e, "until" .= fmap untilText (A.exemptUntil e), "expired" .= expired
  , "law" .= A.exemptLaw e ]

untilText :: A.Until -> String
untilText (A.UntilVersion v) = v
untilText (A.UntilTime t) = t

-- | Whether an exemption has expired, and the project version or time it
-- was compared with. A version needs the project's version; a time without
-- the current time cannot expire.
expiredAt :: Expiry -> A.Exemption -> Either [Diagnostic] (Bool, String)
expiredAt expiry e = case A.exemptUntil e of
  Nothing -> Right (False, "")
  Just (A.UntilVersion v) -> case expiryVersion expiry of
    Nothing -> Left [Diagnostic "laws-for" ("an exemption until " ++ v ++
      " needs the project's version: set projectVersion in lawspec.edn, or version in lawspec.edn") Nothing]
    Just current -> Right (compareVersions current v /= LT, " (project is " ++ current ++ ")")
  Just (A.UntilTime t) -> case expiryNow expiry of
    Nothing -> Right (False, " (no current time given)")
    Just now -> Right (normal now >= normal t, " (now " ++ normal now ++ ")")
  where
    -- yyyy-mm-ddThh:mm[:ss[.fff]]Z, to seconds.
    normal text = let core = takeWhile (/= 'Z') text
                      seconds = if length core == 16 then core ++ ":00" else take 19 core
                  in seconds ++ "Z"

-- | Versions compare by their numeric parts; a prerelease is before its
-- release.
compareVersions :: String -> String -> Ordering
compareVersions a b = compare (key a) (key b)
  where
    key v = let (core, rest) = break (== '-') v
            in (map number (split core), null rest)
    number part = if not (null part) && all isDigit part then read part else (0 :: Integer)
    split s = case break (== '.') s of
      (x, '.' : more) -> x : split more
      (x, _) -> [x]

-- | The Z3 tasks of the checks the compiler left undecided, for the host.
-- A row whose tasks cannot be encoded says why.
analysisTaskViews :: C.Program -> M.Map C.Id A.Claims -> [A.Row] -> [Value]
analysisTaskViews program claims rows =
  [ case tasks of
      Right ts -> object (identity row ++ ["status" .= ("ready" :: String), "tasks" .= map taskView ts])
      Left why -> object (identity row ++ ["status" .= ("unsupported" :: String), "reason" .= why])
  | (row, tasks) <- Tasks.analysisTasks program claims rows ]
  where
    taskView t = object
      [ "fingerprint" .= Tasks.taskFingerprint t, "semanticFingerprint" .= Tasks.taskSemanticFingerprint t,
        "encoding" .= encodingName SmtLibV2
      , "script" .= Tasks.taskScript t, "inputs" .= Tasks.taskNames t ]

identity :: A.Row -> [(Data.Aeson.Key.Key, Value)]
identity row = [ "owner" .= C.idText (A.rowUnit row), "declaration" .= C.idText (A.rowFunction row)
               , "stage" .= A.checkStage (A.rowCheck row) ]

-- | Z3's answers, by task fingerprint, settle the undecided rows; the rows
-- become evidence with their exemptions, and each task gets a verdict.
settleAnalysis :: Bool -> Expiry -> M.Map C.Id A.Claims -> C.Program -> [A.Row] -> [(String, Tasks.Answer)]
  -> Either [Diagnostic] ([(Obligation, Maybe Value)], [Value])
settleAnalysis proof expiry claims program rows answers = do
  let answered = [ (row, [(t, a) | t <- ts, Just a <- [lookup (Tasks.taskFingerprint t) answers]])
                 | (row, Right ts) <- Tasks.analysisTasks program claims rows ]
      settled = Tasks.settle program claims answered
      final = [maybe row fst (lookup (rowKey row) [(rowKey (fst s), s) | s <- settled]) | row <- rows]
      rowKey row = (A.rowFunction row, A.rowCheck row)
  evidence <- analysisEvidence True proof True expiry final
  let status :: A.Row -> String
      status row = maybe "incomplete" (statusText . obligationStatus . fst)
        (lookup (rowKey row) [((A.rowFunction r, A.rowCheck r), e) | (r, e) <- zip final evidence])
      statusText :: Status -> String
      statusText s = case s of
        Refuted -> "refuted"
        Exempted -> "exempted"
        Proved -> "proved"
        _ -> "incomplete"
      verdicts = [ object (identity row ++ [ "fingerprint" .= Tasks.taskFingerprint t, "status" .= taskStatus row s
                                           , "reason" .= why, "check" .= status row ])
                 | (row, vs) <- settled, (t, s, why) <- vs ]
      -- A task's own result, unless its row is exempted.
      taskStatus :: A.Row -> String -> String
      taskStatus row s = if status row == "exempted" && s == "refuted" then "exempted" else s
  pure (evidence, verdicts)
