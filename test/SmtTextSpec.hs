-- | Text in Z3 tasks (lawspec-smtlib-v2): SMT strings of Unicode scalar
-- values, the matchers, and portable regexes, with the U+2FFFF rule: a task
-- that could tell a character above U+2FFFF apart is unsupported.
module SmtTextSpec (test_smtText) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Smt as SMT
import LawSpec.Frontend (compileCoreCanonical)
import qualified LawSpec.Model as S
import LawSpec.Regex (parseRegex, regexMatches, regexSamples)
import LawSpec.Core.Counterexample (checkStatus, validateCounterexample)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import qualified Data.Text as T
import qualified LawSpec.Api as API

task :: String -> IO SMT.ProofTask
task body = snd <$> programAndTask body

programAndTask :: String -> IO (C.Program, SMT.ProofTask)
programAndTask body = do
  program <- either (fail . show) pure (compileCoreCanonical 64 S.defaultGeneration
    [S.Source "text.lawspec" ("unit smt.text\n\nlaw selected is definition: " ++ body ++ " end definition end law\nend unit\n")])
  prepared <- either (fail . show) pure (SMT.proofTasks program)
  case [t | t <- prepared, C.idText (SMT.taskLaw t) == "smt.text::law::selected"] of
    [t] -> pure (program, t)
    _ -> fail "expected one task"

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

run :: FilePath -> String -> IO String
run z3 script = do
  (status, output, errors) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] (script ++ "(check-sat)\n")
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure (takeWhile (/= '\n') output)

answer :: FilePath -> String -> IO String
answer z3 body = do
  t <- task body
  script <- either fail pure (SMT.taskQuery t)
  run z3 script

-- | Portable regexes the differential check covers.
patterns :: [String]
patterns =
  [ "[A-Z]{3}", "[a-z]+(-[a-z]+)*", "\\d{2,4}", "(ab|cd)*e?", "[^a-c]x", ".", "\\w+@\\w+\\.com", "[^\\d\\s]*", "a{0,2}b{2,}" ]

-- | Texts to try on each pattern: its samples, and some that miss.
texts :: String -> [[Int]]
texts pattern = case parseRegex pattern of
  Right r -> map (map fromEnum) (regexSamples 12 r) ++ map (map fromEnum) ["", "a", "ABC", "abcd", "12", "x-y", "\n", "ab@cd.com", "aabbb", "é", "AB"]
  Left _ -> []

-- | Each law of a unit, and whether Z3 proves it as lawspec prove would:
-- its task, else its other encoding, else every induction case (in either
-- encoding).
provedLaws :: FilePath -> String -> [FilePath] -> IO [(String, Bool)]
provedLaws z3 owner files = do
  sources <- mapM (\f -> (\c -> object ["path" .= f, "content" .= c]) <$> readFile f) files
  Just response <- pure (decode (API.dispatch (encode (object
    [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
    , "verification" .= object ["layers" .= ["proof" :: String]], "sources" .= sources ]))) :: Maybe Value)
  let tasks = case field "proofTasks" response of
        Just (Array ts) -> [t | t <- toList ts, textOf "owner" t == owner]
        _ -> []
  mapM (\t -> do
    let attempts c = textOf "script" c : maybe [] (\a -> [textOf "script" a]) (field "alternative" c)
        unsat scripts = or <$> mapM (fmap (== "unsat") . run z3) scripts
    direct <- if textOf "status" t == "ready" then unsat (attempts t) else pure False
    byCases <- if direct then pure True else case field "induction" t >>= field "cases" of
      Just (Array cs) -> and <$> mapM (unsat . attempts) (toList cs)
      _ -> pure False
    pure (reverse (takeWhile (/= ':') (reverse (textOf "declaration" t))), byCases)) tasks
  where
    field :: Key.Key -> Value -> Maybe Value
    field k (Object o) = K.lookup k o
    field _ _ = Nothing
    textOf k v = case field k v of Just (String x) -> T.unpack x; _ -> ""

test_smtText :: Spec
test_smtText = describe "SMT text" $ do
  it "proves the codec portfolio (13.3): a round trip and the applied left-inverse law" $ solver $ \z3 ->
    provedLaws z3 "portfolio.codec" ["test/fixtures/codec-proofs.lawspec"] >>= (`shouldSatisfy` \rows -> length rows == 4 && all snd rows)
  it "proves unbounded laws of the Chapter 6 reference models" $ solver $ \z3 ->
    provedLaws z3 "nand2tetris.proofs" ["chap06.lawspec", "test/fixtures/chapter6-proofs.lawspec"]
      >>= (`shouldSatisfy` \rows -> length rows == 5 && all snd rows)
  it "gives Text laws v2 tasks, with each Text a string of Unicode scalar values" $ do
    t <- task "for all (a :: Text) (b :: Text) => prelude.length (a ++ b) = prelude.length a + prelude.length b end for all"
    SMT.taskEncoding t `shouldBe` SMT.SmtLibV2
    either id id (SMT.taskQuery t) `shouldSatisfy` isInfixOf "(re.range \"\\u{e000}\" \"\\u{2ffff}\")"
  it "refuses a literal or a regex range above U+2FFFF" $ do
    t <- task "for all (t :: Text) => t != \"\x30000\" end for all"
    SMT.taskQuery t `shouldSatisfy` either (isInfixOf "above U+2FFFF") (const False)
    r <- task "for all (t :: Text where t matches regex \"[a-\x30000]\") => prelude.length t = 1 end for all"
    SMT.taskQuery r `shouldSatisfy` either (isInfixOf "above U+2FFFF") (const False)
    SMT.regexTerm <$> either (const Nothing) Just (parseRegex "[\x40000]") `shouldSatisfy` maybe False isLeft
  it "proves laws over text and the matchers" $ solver $ \z3 -> forM_
    [ "for all (a :: Text) (b :: Text) => prelude.length (a ++ b) = prelude.length a + prelude.length b end for all"
    , "for all (t :: Text where t matches regex \"[A-Z]{3}\") => prelude.length t = 3 end for all"
    , "for all (t :: Text) (p :: Text) => (p ++ t) starts with p end for all"
    , "for all (t :: Text) => (t ++ \"-done\") ends with \"done\" end for all"
    , "for all (a :: Text) (b :: Text) (c :: Text) => (a ++ b ++ c) contains b end for all"
    , "prelude.slice 1 3 \"kafka\" = \"af\""
    , "for all (t :: Text) => prelude.slice 0 (prelude.length t) t = t end for all"
    , "for all (n :: Int32 where n >= 0 and n <= 9) => prelude.length (prelude.textOf n) = 1 end for all"
    , "prelude.textOf (-12) = \"-12\""
    , "for all (t :: Text where t matches regex \"[a-z]+\") => not (t matches regex \"\\\\d+\") end for all" ]
    (\law -> answer z3 law >>= (`shouldBe` "unsat") . (\a -> if a == "unsat" then a else a ++ " for " ++ law))
  it "does not prove a false text law" $ solver $ \z3 -> forM_
    [ "for all (t :: Text) => prelude.length t > 0 end for all"
    , "for all (t :: Text where t matches regex \"[a-z]*\") => prelude.length t <= 5 end for all" ]
    (\law -> answer z3 law >>= (`shouldNotBe` "unsat"))
  it "refutes a false text law with a text the evaluator confirms" $ solver $ \z3 -> do
    (program, t) <- programAndTask "for all (t :: Text) (p :: Text) => (t ++ p) starts with \"a\" end for all"
    query <- either fail pure (SMT.taskCounterexample t)
    let names = map fst (SMT.counterexampleInputs query)
    (status, output, _) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"]
      (SMT.counterexampleScript query ++ "(check-sat)\n(get-value (" ++ unwords names ++ "))\n")
    status `shouldBe` ExitSuccess
    let (verdict, rest) = break (== '\n') output
    verdict `shouldBe` "sat"
    checkStatus (validateCounterexample program t rest) `shouldBe` "refuted"
  it "translates every portable regex as LawSpec.Regex matches it" $ solver $ \z3 -> forM_ patterns $ \pattern -> do
    regex <- either fail pure (parseRegex pattern)
    term <- either fail pure (SMT.regexTerm regex)
    forM_ (texts pattern) $ \text -> do
      literal <- either fail pure (SMT.textLiteral text)
      got <- run z3 ("(assert (str.in_re " ++ literal ++ " " ++ term ++ "))\n")
      (pattern, map toEnum text :: String, got) `shouldBe` (pattern, map toEnum text, if regexMatches regex text then "sat" else "unsat")
