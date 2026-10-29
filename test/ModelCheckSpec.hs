-- | Laws about a model's runs (law n in model m ... every run holds P),
-- checked over the model's reference by the in-house explicit-state search
-- (LawSpec.Core.ModelCheck), with weak and strong fairness.
module ModelCheckSpec (test_modelChecking) where

import Control.Monad (foldM)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as K
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import Test.Hspec
import qualified LawSpec.Api as API
import qualified LawSpec.Core.ModelCheck as MC

check :: String -> Maybe Value
check source = decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("check" :: String)
  , "verification" .= object ["layers" .= ["exhaustive" :: String]]
  , "sources" .= [object ["path" .= ("model.lawspec" :: String), "content" .= source]] ])))

-- | A law's row: its status and reason.
row :: String -> Maybe Value -> Maybe (String, String)
row law response = case response of
  Just (Object r) | Just (Array rows) <- K.lookup "evidence" r ->
    case [ (T.unpack s, T.unpack why) | Object o <- toList rows, K.lookup "stage" o == Just (String "law")
         , Just (String d) <- [K.lookup "declaration" o], ("::law::|" ++ law ++ "|") `isSuffixOf` T.unpack d
         , Just (String s) <- [K.lookup "status" o], Just (String why) <- [K.lookup "reason" o] ] of
      found : _ -> Just found
      [] -> Nothing
  _ -> Nothing

diagnostics :: Maybe Value -> [String]
diagnostics response = case response of
  Just (Object r) | Just (Array ds) <- K.lookup "diagnostics" r -> [T.unpack m | Object d <- toList ds, Just (String m) <- [K.lookup "message" d]]
  _ -> []

-- | A three-state model: flip moves 0 and 1 back and forth, and go is
-- enabled only at 1 and leads to 2.
toggle :: String -> String
toggle law = unlines
  [ "unit portfolio.toggle\n"
  , "type Box is a record{ id :: Int32 } end type"
  , "newBox :: Unit -> Box"
  , "flip :: Box -> Unit"
  , "go :: Box -> Unit"
  , "function flipped (s :: Int8 where s >= 0 && s <= 1) -> Int8 is 1 - s end function"
  , "function done (s :: Int8) -> Int8 is 2 end function"
  , "function canFlip (s :: Int8) -> Bool is s < 2 end function"
  , "function isOne (s :: Int8) -> Bool is s = 1 end function"
  , "function isTwo (s :: Int8) -> Bool is s = 2 end function"
  , "model box :: shared Box by Int8 is"
  , "  start newBox ~ 0"
  , "  flip ~ flipped when canFlip"
  , "  go ~ done when isOne"
  , "end model\n"
  , law
  , "end unit" ]

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

-- | What lawspec prove does for model laws: run each model task with Z3
-- (Spacer's answer gives its invariant, a bounded search its values), send
-- the answers back, and repeat while the compiler asks for more.
settled :: FilePath -> String -> IO [(String, String, String)]
settled z3 source = go (0 :: Int) [] []
  where
    request answers = encode (object
      [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
      , "verification" .= object ["layers" .= ["proof" :: String, "exhaustive"]]
      , "sources" .= [object ["path" .= ("model.lawspec" :: String), "content" .= source]]
      , "modelResults" .= [object ["fingerprint" .= f, "outcome" .= o, "values" .= v, "invariant" .= i] | (f, o, v, i) <- answers] ])
    field :: Key.Key -> Value -> Maybe Value
    field k (Object o) = K.lookup k o
    field _ _ = Nothing
    text k v = case field k v of Just (String t) -> T.unpack t; _ -> ""
    go round answers rows = do
      Just response <- pure (decode (API.dispatch (request answers)) :: Maybe Value)
      let found = [ (text "declaration" e, text "status" e, text "reason" e) | Just (Array es) <- [field "modelEvidence" response], e <- toList es ]
          tasks = [ t | Just (Array ls) <- [field "modelTasks" response], l <- toList ls, Just (Array ts) <- [field "tasks" l], t <- toList ts
                  , text "fingerprint" t `notElem` [f | (f, _, _, _) <- answers] ]
      if null tasks || round > 3 then pure (if null found then rows else found) else do
        new <- foldM (\acc t -> do
          let script = text "script" t ++ "(check-sat)\n"
              names = [T.unpack n | Just (Array ns) <- [field "inputs" t], String n <- toList ns]
          (_, out, _) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:20000"] script
          let outcome = takeWhile (/= '\n') out
          (values, invariant) <- if outcome /= "sat" then pure ("", "") else
            if text "kind" t == "spacer" then do
              (_, model, _) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:20000"] (script ++ "(get-model)\n")
              pure ("", definition (drop 1 (dropWhile (/= '\n') model)))
            else if null names then pure ("", "") else do
              (_, model, _) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:20000"] (script ++ "(get-value (" ++ unwords names ++ "))\n")
              pure (drop 1 (dropWhile (/= '\n') model), "")
          pure (acc ++ [(text "fingerprint" t, outcome, values, invariant)])) [] tasks
        go (round + 1) (answers ++ new) (if null found then rows else found)
    -- The define-fun of Inv in Spacer's model.
    definition model = case breakOn "(define-fun Inv " model of
      Just rest -> balanced 0 rest ""
      Nothing -> ""
    balanced :: Int -> String -> String -> String
    balanced d text acc = case text of
      '(' : more -> balanced (d + 1) more ('(' : acc)
      ')' : more | d == 1 -> reverse (')' : acc)
                 | otherwise -> balanced (d - 1) more (')' : acc)
      c : more -> balanced d more (c : acc)
      [] -> reverse acc
    breakOn needle haystack = case haystack of
      _ | take (length needle) haystack == needle -> Just haystack
      _ : more -> breakOn needle more
      [] -> Nothing

test_modelChecking :: Spec
test_modelChecking = describe "model checking" $ do
  it "bounds the reachability count even when a formula prunes every product state" $ do
    let system = MC.System [0 :: Int] (\n -> Right [("up", "up", n + 1)]) (\_ _ -> Right False) show
    MC.search 8 system [] MC.FFalse `shouldBe` Right (MC.Bounded 8 "the reachable-state search stops there")
  it "keeps an unsupported reachable step incomplete when the product is empty" $ do
    let system = MC.System [0 :: Int] (\_ -> Left "unsupported command") (\_ _ -> Right False) show
    MC.search 8 system [] MC.FFalse `shouldBe` Right (MC.Bounded 1 "unsupported command")
  it "keeps an empty open history pending and refuses an empty complete temporal history" $ do
    let atom = MC.FAtom "observed"
        absent _ _ = Left "there is no entry"
    MC.judge False atom 0 absent `shouldBe` Right MC.Open
    MC.judge True atom 0 absent `shouldBe` Left "a complete temporal history needs at least one entry"
  describe "portfolio 13.7, the order workflow" $ do
    response <- runIO (check <$> readFile "test/fixtures/order-workflow.lawspec")
    it "proves invariants and orderings over every reachable state" $ do
      row "nothing ships unpaid" response `shouldBe` Just ("proved", "every run holds it: all 6 states explored")
      fmap fst (row "cancelled orders stay cancelled" response) `shouldBe` Just "proved"
      fmap fst (row "paid orders are never cancelled" response) `shouldBe` Just "proved"
    it "proves a liveness claim under weak fairness, and refutes it without, with the run" $ do
      row "validated orders finish, given fair authorization" response
        `shouldBe` Just ("proved", "every run holds it under fairness for authorize: all 6 states explored")
      row "validated orders finish" response `shouldBe` Just ("refuted", "a run breaks it: validate, decline, (decline)")
      diagnostics response `shouldSatisfy` any (isInfixOf "a run breaks it")
    it "shows a run that holds a some-run law" $
      row "an order can be fulfilled" response `shouldSatisfy` maybe False (\(s, why) -> s == "proved" && "validate, authorize, capture, fulfil" `isInfixOf` why)
  it "refutes a mutant that ships before payment, with the invalid steps" $ do
    source <- readFile "test/fixtures/order-workflow.lawspec"
    let mutant = replace "  fulfil ~ toFulfilled when isCaptured" "  fulfil ~ toFulfilled when isAuthorized" source
    row "nothing ships unpaid" (check mutant) `shouldBe` Just ("refuted", "a run breaks it: validate, authorize, fulfil, then stays")
  it "needs strong fairness when a command is enabled only again and again" $ do
    let law fairness = "law \"|it ends| in model box" ++ fairness ++ " is\n  definition: every run holds eventually isTwo end definition\nend law\n"
    fmap fst (row "it ends" (check (toggle (law "")))) `shouldBe` Just "refuted"
    fmap fst (row "it ends" (check (toggle (law " assuming fairness for go")))) `shouldBe` Just "refuted"
    row "it ends" (check (toggle (law " assuming strong fairness for go"))) `shouldBe` Just ("proved", "every run holds it under strong fairness for go: all 3 states explored")
  describe "deadlines, in whole-microsecond ticks" $ do
    response <- runIO (check <$> readFile "test/fixtures/model-deadlines.lawspec")
    it "proves a deadline the model's wait rule keeps" $
      row "captured in a day" response `shouldBe` Just ("proved", "every run holds it: all 3 states explored")
    it "refutes a deadline time can pass, with the run and the time it took" $
      row "captured in a day, without a clock rule" response `shouldBe` Just ("refuted", "a run misses the 24h deadline: authorize, wait 25h")
  it "requires an explicit wait command for a model deadline" $ do
    source <- readFile "test/fixtures/model-deadlines.lawspec"
    let withoutClock = replace "  wait ~ stay\nend model" "end model" source
    row "captured in a day, without a clock rule" (check withoutClock) `shouldBe`
      Just ("unsupported", "a deadline needs the model's wait command")
  it "settles a response reached by a wait command at its arrival time" $ do
    source <- readFile "test/fixtures/model-deadlines.lawspec"
    let respondingWait = replace "  wait ~ stay\nend model" "  wait ~ toCaptured\nend model" source
    fmap fst (row "captured in a day, without a clock rule" (check respondingWait)) `shouldBe` Just "proved"
  it "cannot prove an invariant after dropping an unencodable command obligation" $ do
    source <- readFile "test/fixtures/model-counters.lawspec"
    -- Decimal rounding evaluates normally, but is not encoded in SMT.
    -- The loose model still reaches -1 through slip; its start and up
    -- obligations alone cannot establish its invariant.
    let mutant = replace "function minus (n :: Integer) -> Integer is n - 1 end function"
          "function minus (n :: Integer) -> Integer is if prelude.round (prelude.Decimal 1) 0 = prelude.Decimal 2 then n else n - 1 end if end function" source
        request answers = decode (API.dispatch (encode (object
          [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
          , "verification" .= object ["layers" .= ["proof" :: String, "exhaustive"]]
          , "sources" .= [object ["path" .= ("counter.lawspec" :: String), "content" .= mutant]]
          , "modelResults" .= answers ]))) :: Maybe Value
        field key (Object value) = K.lookup key value
        field _ _ = Nothing
        tasks = [ t | Just response <- [request ([] :: [Value])], Just (Array laws) <- [field "modelTasks" response]
                    , law <- toList laws, Just (Array ts) <- [field "tasks" law], t <- toList ts
                    , field "declaration" law == Just (String "portfolio.counters::law::|a loose count never goes negative|") ]
        answers = object ["fingerprint" .= ("unrelated" :: String), "outcome" .= ("unknown" :: String)] :
                  [object ["fingerprint" .= fingerprint, "outcome" .= ("unsat" :: String)]
                  | t <- tasks, Just fingerprint <- [field "fingerprint" t]]
        statuses = [status | Just response <- [request answers], Just (Array rows) <- [field "modelEvidence" response]
                           , row' <- toList rows, field "declaration" row' == Just (String "portfolio.counters::law::|a loose count never goes negative|")
                           , Just status <- [field "status" row']]
    tasks `shouldBe` []
    statuses `shouldBe` [String "incomplete"]
  describe "unbounded models, with Z3" $ do
    it "leaves an unbounded model's search incomplete" $ do
      response <- check <$> readFile "test/fixtures/model-counters.lawspec"
      row "counts never go negative" response `shouldSatisfy` maybe False (\(s, why) -> s == "incomplete" && "no counterexample in the first 20000 states" `isInfixOf` why)
    it "proves an invariant by induction, refutes a mutant with a replayed run, and proves a non-inductive invariant through Spacer" $ solver $ \z3 -> do
      rows <- settled z3 =<< readFile "test/fixtures/model-counters.lawspec"
      let of_ law = [(s, why) | (d, s, why) <- rows, ("::law::|" ++ law ++ "|") `isSuffixOf` d]
      of_ "counts never go negative" `shouldSatisfy` any (\(s, why) -> s == "proved" && "by induction" `isInfixOf` why)
      of_ "a loose count never goes negative" `shouldBe` [("refuted", "a run breaks it: slip; Z3 found it and the evaluator replays it")]
      of_ "the first never goes negative" `shouldSatisfy` any (\(s, why) -> s == "proved" && "Spacer proposed and plain queries re-checked" `isInfixOf` why)
  describe "portfolio 13.5, histories with three values" $ do
    response <- runIO (check <$> readFile "test/fixtures/history-revocation.lawspec")
    it "proves an invariant of a complete snapshot" $
      row "no use after revocation, yesterday" response `shouldBe` Just ("proved", "the complete history holds it: all 4 entries checked")
    it "reports a bounded history property and an unbounded future requirement as pending, apart" $ do
      row "no use after revocation, today" response
        `shouldBe` Just ("pending", "pending: the 2 entries so far do not decide it; it holds so far, and what comes next may still break it")
      row "revoked sessions sign out, today" response
        `shouldBe` Just ("pending", "pending: the 2 entries so far do not decide it; it does not hold yet, and what comes next may make it hold")
    it "refutes a deadline as soon as observed time passes it, and a broken invariant" $ do
      row "revoked sessions sign out within an hour" response
        `shouldBe` Just ("refuted", "the history so far breaks it at entry 3 of 3, when the 1h deadline passes, observed at 2h")
      row "no use after revocation, incident" response `shouldBe` Just ("refuted", "the history so far breaks it at entry 3 of 3")
  it "refutes a deadline even when its response arrives after the deadline" $ do
    source <- readFile "test/fixtures/history-revocation.lawspec"
    let late = replace "at = 2h, event = Use" "at = 2h, event = SignOut" source
    fmap fst (row "revoked sessions sign out within an hour" (check late)) `shouldBe` Just "refuted"
  it "keeps an open history's deadline pending when no response is outstanding" $ do
    source <- readFile "test/fixtures/history-revocation.lawspec"
    let untriggered = replace "at = 5s, event = Revoke, session = 3" "at = 5s, event = SignIn, session = 3" source
    fmap fst (row "revoked sessions sign out within an hour" (check untriggered)) `shouldBe` Just "pending"
  it "refuses observation times that run backwards" $ do
    source <- readFile "test/fixtures/history-revocation.lawspec"
    let backwards = replace "at = 2h, event = Use" "at = 1s, event = Use" source
    row "revoked sessions sign out within an hour" (check backwards) `shouldBe`
      Just ("unsupported", "a history's observation times must be nondecreasing")
  it "refutes a some-run law no run holds, after exploring every state" $
    row "it never ends" (check (toggle "law \"|it never ends| in model box is\n  definition: some run holds always (isOne and not isOne) end definition\nend law\n"))
      `shouldBe` Just ("refuted", "no run holds it: all 3 states explored")
  it "names an unknown model, command or predicate" $ do
    diagnostics (check (toggle "law \"|x| in model nothing is\n  definition: every run holds always isOne end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "the unit has no model nothing")
    diagnostics (check (toggle "law \"|x| in model box assuming fairness for jump is\n  definition: every run holds always isOne end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "the model has no command jump")
    diagnostics (check (toggle "law \"|x| in model box is\n  definition: every run holds always isThree end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "no property or predicate isThree")
  -- Per-state domains must retain finite completeness and explicit limits.
  -- ref:DEC-dependent-model-arguments
  describe "dependent model domains" $ do
    source <- runIO (readFile "test/fixtures/dependent-model-arguments.lawspec")
    it "proves a finite model with state-dependent command arguments" $ do
      diagnostics (check source) `shouldBe` []
      row "bounded runs" (check source) `shouldBe` Just ("proved", "every run holds it: all 3 states explored")
    it "keeps an oversized dependent enumeration incomplete" $ do
      let wide = replace "i < n" "i < n + 10000" (replaceAll "Int8" "UInt16" source)
      fmap fst (row "bounded runs" (check wide)) `shouldBe` Just "incomplete"
    it "reports an unsupported dependent refinement without inventing an empty domain" $ do
      let unsupported = replace "i < n" "i != n" source
      fmap fst (row "bounded runs" (check unsupported)) `shouldBe` Just "unsupported"
  where
    replaceAll old new text = case breakOn old text of
      Just (before, after) -> before ++ new ++ replaceAll old new (drop (length old) after)
      Nothing -> text
    replace old new text = case breakOn old text of
      Just (before, after) -> before ++ new ++ drop (length old) after
      Nothing -> text
    breakOn needle haystack = go "" haystack
      where go acc rest | needle `isPrefixOfS` rest = Just (reverse acc, rest)
                        | otherwise = case rest of c : more -> go (c : acc) more; [] -> Nothing
            isPrefixOfS a b = take (length a) b == a
