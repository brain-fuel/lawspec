-- | The laws about a function, checked together: completeness, overlap,
-- conflict and vacuity, on by default; `laws for f are ... end laws` states
-- claims and excuses checks, until a version or a UTC date-time.
module LawAnalysisSpec (test_lawSetsAreCheckedTogether) where

import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Test.Hspec
import qualified LawSpec.Api as API
import LawSpec.Model (Source(..))
import LawSpec.SourceText (formatSource)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

orders :: [String] -> String
orders extra = unlines $
  [ "unit claims.orders\n"
  , "type State is one of | Pending | Shipped | Cancelled end type\n"
  , "function next (state :: State) -> State is"
  , "  first matching case of state:"
  , "    when Pending then Shipped"
  , "    otherwise state"
  , "  end case"
  , "end function\n"
  , "law \"|pending orders ship| is"
  , "  definition: for all (state :: State) => state = Pending implies next state = Shipped end for all end definition"
  , "end law\n"
  , "law \"|shipped orders stay| is"
  , "  definition: for all (state :: State) => state = Shipped implies next state = Shipped end for all end definition"
  , "end law\n" ] ++ extra ++ ["end unit"]

block :: [String] -> [String]
block items = ["laws for next are"] ++ map ("  " ++) items ++ ["end laws\n"]

check :: [(Key.Key, Value)] -> String -> Maybe Value
check extra source = decode (API.dispatch (encode (object ([ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
  , "method" .= ("check" :: String), "verification" .= object ["layers" .= ["exhaustive" :: String]]
  , "sources" .= [object ["path" .= ("orders.lawspec" :: String), "content" .= source]]] ++ map (uncurry (.=)) extra))))

-- | The row of a check of next: its status and reason.
row :: String -> Maybe Value -> Maybe (String, String)
row stage response = case response of
  Just (Object r) | Just (Array rows) <- K.lookup "evidence" r ->
    case [ (T.unpack s, T.unpack why) | Object o <- toList rows, K.lookup "stage" o == Just (String (T.pack stage))
         , K.lookup "declaration" o == Just (String "claims.orders::next")
         , Just (String s) <- [K.lookup "status" o], Just (String why) <- [K.lookup "reason" o] ] of
      found : _ -> Just found
      [] -> Nothing
  _ -> Nothing

diagnostics :: Maybe Value -> [(String, String)]
diagnostics response = case response of
  Just (Object r) | Just (Array ds) <- K.lookup "diagnostics" r ->
    [(T.unpack c, T.unpack m) | Object d <- toList ds, Just (String c) <- [K.lookup "code" d], Just (String m) <- [K.lookup "message" d]]
  _ -> []

status :: Maybe (String, String) -> Maybe String
status = fmap fst

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

-- | The host's round trip: the compiler's Z3 tasks, Z3's answers (or a
-- given outcome for every task), and the evidence the compiler settles.
proved :: Maybe String -> FilePath -> String -> IO (Value, [(String, String, String)])
proved forced binary source = do
  let request extra = encode (object ([ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
        , "method" .= ("proofTasks" :: String), "verification" .= object ["layers" .= ["proof" :: String]]
        , "sources" .= [object ["path" .= ("portfolio.lawspec" :: String), "content" .= source]]] ++ extra))
      field key (Object o) = K.lookup key o
      field _ _ = Nothing
      text key o = case field key o of Just (String t) -> T.unpack t; _ -> ""
  Just first <- pure (decode (API.dispatch (request [])) :: Maybe Value)
  let tasks = [ t | Just (Array rows) <- [field "analysisTasks" first], row <- toList rows
              , Just (Array ts) <- [field "tasks" row], t <- toList ts ]
  answers <- mapM (\t -> do
    let script = text "script" t ++ "(check-sat)\n"
        names = [T.unpack n | Just (Array ns) <- [field "inputs" t], String n <- toList ns]
    (outcome, values) <- case forced of
      Just given -> pure (given, "")
      Nothing -> do
        let z3 input = do
              (code, out, _) <- readProcessWithExitCode binary ["-in", "-smt2", "-t:10000"] input
              code `shouldBe` ExitSuccess
              pure (break (== '\n') out)
        (verdict, _) <- z3 script
        if verdict == "sat" && not (null names)
          then (\(_, rest) -> (verdict, drop 1 rest)) <$> z3 (script ++ "(get-value (" ++ unwords names ++ "))\n")
          else pure (verdict, "")
    pure (object ["fingerprint" .= text "fingerprint" t, "outcome" .= outcome, "values" .= values])) tasks
  Just settled <- pure (decode (API.dispatch (request ["analysisResults" .= answers])) :: Maybe Value)
  let rows = [ (last (splitOn (text "declaration" e)), text "stage" e ++ " " ++ text "status" e, text "reason" e)
             | Just (Array es) <- [field "analysisEvidence" settled], e <- toList es ]
  pure (settled, rows)
  where
    splitOn d = case break (== ':') d of
      (x, ':' : ':' : more) -> x : splitOn more
      (x, _) -> [x]

-- | A row's status and reason, for a function and a check.
of_ :: String -> String -> [(String, String, String)] -> Maybe (String, String)
of_ function stage rows = case [ (drop (length stage + 1) s, why) | (f, s, why) <- rows, f == function, takeWhile (/= ' ') s == stage ] of
  found : _ -> Just found
  [] -> Nothing

test_lawSetsAreCheckedTogether :: Spec
test_lawSetsAreCheckedTogether = describe "law sets" $ do
  describe "default checks" $ do
    it "refutes an incomplete set with the uncovered input, and fails the build" $ do
      let response = check [] (orders [])
      row "completeness" response `shouldSatisfy` maybe False (\(s, why) -> s == "refuted" && "not covered: state = Cancelled" `isInfixOf` why)
      diagnostics response `shouldSatisfy` any (\(c, m) -> c == "refuted" && "not covered" `isInfixOf` m)
    it "checks a complete set exhaustively" $
      status (row "completeness" (check [] (orders (block ["complete over state != Cancelled"])))) `shouldBe` Just "exhaustively-checked"
    it "refutes overlap and conflict with the laws and the input" $ do
      let response = check [] (orders ([ "law \"|pending orders are cancelled| is"
            , "  definition: for all (state :: State) => state = Pending implies next state = Cancelled end for all end definition"
            , "end law\n" ] ++ block ["partial because \"cancelled orders are not covered\""]))
      row "overlap" response `shouldSatisfy` maybe False (\(s, why) -> s == "refuted" && "both apply to state = Pending" `isInfixOf` why)
      row "conflict" response `shouldSatisfy` maybe False (\(s, why) -> s == "refuted" && "requires" `isInfixOf` why)
    it "refutes a law whose assumptions no input satisfies" $
      status (row "vacuity" (check [] (orders ([ "law \"|impossible| is"
        , "  definition: for all (state :: State) => state = Pending and state = Shipped implies next state = Pending end for all end definition"
        , "end law\n" ] ++ block ["partial because \"cancelled orders are not covered\""])))) `shouldBe` Just "refuted"
  describe "exemptions" $ do
    it "excuses a check with its reason, keeping the counterexample" $ do
      let response = check [] (orders (block ["partial because \"cancelled orders are not covered\""]))
      row "completeness" response `shouldSatisfy` maybe False (\(s, why) -> s == "exempted" && "not covered: state = Cancelled" `isInfixOf` why
        && "cancelled orders are not covered" `isInfixOf` why)
      diagnostics response `shouldBe` []
    it "excuses a vacuous law by name" $
      status (row "vacuity" (check [] (orders ([ "law \"|impossible| is"
        , "  definition: for all (state :: State) => state = Pending and state = Shipped implies next state = Pending end for all end definition"
        , "end law\n" ] ++ block ["partial because \"cancelled orders are not covered\"", "vacuity allowed for \"|impossible| because \"kept as a record\""])))) `shouldBe` Just "exempted"
    it "expires at the project's version and refutes the check" $ do
      let source = orders (block ["partial until 1.2.0 because \"cancelled orders come later\""])
      row "completeness" (check ["projectVersion" .= ("1.1.4" :: String)] source)
        `shouldSatisfy` maybe False (\(s, why) -> s == "exempted" && "until 1.2.0 (project is 1.1.4)" `isInfixOf` why)
      let expired = check ["projectVersion" .= ("1.2.0" :: String)] source
      row "completeness" expired `shouldSatisfy` maybe False (\(s, why) -> s == "refuted" && "expired" `isInfixOf` why)
      diagnostics expired `shouldSatisfy` any ((== "refuted") . fst)
      diagnostics (check [] source) `shouldSatisfy` any (\(c, m) -> c == "laws-for" && "project's version" `isInfixOf` m)
    it "expires at a UTC date-time" $ do
      let source = orders (block ["partial until 2026-03-01T00:00Z because \"cancelled orders come later\""])
      status (row "completeness" (check ["now" .= ("2026-02-28T23:59:59.000Z" :: String)] source)) `shouldBe` Just "exempted"
      status (row "completeness" (check ["now" .= ("2026-03-01T00:00:00.000Z" :: String)] source)) `shouldBe` Just "refuted"
  describe "portfolio 13.6 with Z3" $ do
    let portfolio = readFile "test/fixtures/law-sets.lawspec"
    -- Z3 runs the portfolio once; each check reads its rows.
    describe "the rows" $ beforeAll (do
        explicit <- lookupEnv "LAWSPEC_Z3"
        installed <- maybe (findExecutable "z3") (pure . Just) explicit
        traverse (\z3 -> proved Nothing z3 =<< portfolio) installed) $ do
      let withRows check result = maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") check result
      it "proves compatible requirements, with a witness for each law's assumptions" $ withRows $ \(_, rows) -> do
        [fmap fst (of_ "decide" c rows) | c <- ["completeness", "overlap", "conflict", "vacuity"]] `shouldBe` replicate 4 (Just "proved")
        of_ "decide" "vacuity" rows `shouldSatisfy` maybe False (isInfixOf "confirmed by the evaluator" . snd)
      it "refutes a contradiction with both laws and the input the evaluator confirms" $ withRows $ \(settled, rows) -> do
        of_ "settle" "conflict" rows `shouldSatisfy` maybe False (\(s, why) -> s == "refuted"
          && "|refunds within the capture are approved| requires Approved" `isInfixOf` why
          && "|nothing captured means no refund| requires Rejected" `isInfixOf` why
          && "amount = 0, captured = 0" `isInfixOf` why && "the evaluator confirms it" `isInfixOf` why)
        diagnostics (Just settled) `shouldSatisfy` any ((== "refuted") . fst)
        fmap fst (of_ "settle" "overlap" rows) `shouldBe` Just "exempted"
      it "proves a partial law complete in its scope" $ withRows $ \(_, rows) ->
        fmap fst (of_ "quote" "completeness" rows) `shouldBe` Just "proved"
      it "reports an uncovered input under an exemption" $ withRows $ \(_, rows) ->
        of_ "triage" "completeness" rows `shouldSatisfy` maybe False (\(s, why) -> s == "exempted"
          && "not covered: amount = 5001" `isInfixOf` why && "manual review" `isInfixOf` why)
      it "reports a suspected overlap Z3 cannot resolve as incomplete" $ withRows $ \(_, rows) -> do
        of_ "rarity" "overlap" rows `shouldSatisfy` maybe False (\(s, why) -> s == "incomplete" && "a suspected overlap Z3 cannot resolve" `isInfixOf` why)
        of_ "rarity" "conflict" rows `shouldSatisfy` maybe False (\(s, why) -> s == "incomplete" && "a suspected conflict Z3 cannot resolve" `isInfixOf` why)
    it "keeps an unresolved check incomplete" $ do
      (_, rows) <- proved (Just "unknown") "z3" =<< portfolio
      fmap fst (of_ "decide" "overlap" rows) `shouldBe` Just "incomplete"
    it "rejects a model the evaluator does not confirm" $ do
      (_, rows) <- proved (Just "sat") "z3" =<< portfolio
      fmap fst (of_ "quote" "completeness" rows) `shouldBe` Just "incomplete"
  describe "the block" $ do
    it "rejects a date-time that is not UTC" $
      diagnostics (check [] (orders (block ["partial until 2027-03-01T00:00+01:00 because \"later\""])))
        `shouldSatisfy` any (\(c, m) -> c == "parse" && "must be UTC" `isInfixOf` m)
    it "needs until for an allowed conflict" $
      diagnostics (check [] (orders (block ["conflict allowed because \"later\""])))
        `shouldSatisfy` any (\(_, m) -> "conflict allowed needs until" `isInfixOf` m)
    it "names a function and a law of its unit, and no claim with its own exemption" $ do
      diagnostics (check [] (orders ["laws for missing are", "  without overlap", "end laws\n"]))
        `shouldSatisfy` any (\(c, m) -> c == "laws-for" && "no function missing" `isInfixOf` m)
      diagnostics (check [] (orders (block ["without overlap", "overlap allowed because \"x\""])))
        `shouldSatisfy` any (\(_, m) -> "claims without overlap and allows overlap" `isInfixOf` m)
      diagnostics (check [] (orders (block ["vacuity allowed for \"|unknown| because \"x\""])))
        `shouldSatisfy` any (\(_, m) -> "no law |unknown|" `isInfixOf` m)
    it "keeps its layout when formatted" $ do
      let source = orders (block ["complete over state != Cancelled", "without conflict"])
          Source _ formatted = formatSource (Source "orders.lawspec" source)
      formatted `shouldSatisfy` isInfixOf "laws for next are\n  complete over state != Cancelled\n  without conflict\nend laws"
