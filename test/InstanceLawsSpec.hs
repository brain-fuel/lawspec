-- | The capability laws, proved for the built-in instances with their
-- functions left abstract. ref:DEC-capability-laws
module InstanceLawsSpec (test_capabilityLawsAreProved, test_capabilityLawsAreCited) where

import Control.Monad (forM)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Api as API
import LawSpec.CapabilityReceipts (capabilityReceipts)
import qualified LawSpec.Core as C
import LawSpec.ProofSettings (capabilityCitation, capabilityLawKeys)

tasksOf :: [String] -> Maybe Value
tasksOf body = decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
  , "verification" .= object ["layers" .= ["proof" :: String]]
  , "sources" .= [object ["path" .= ("probe.lawspec" :: String), "content" .= unlines (["unit probe.laws"] ++ body ++ ["end unit"])]] ])))

field :: K.Key -> Value -> Maybe Value
field k (Object o) = K.lookup k o
field _ _ = Nothing

textOf :: K.Key -> Value -> String
textOf k v = case field k v of Just (String t) -> T.unpack t; _ -> ""

tasks :: String -> Maybe Value -> IO [Value]
tasks prefix response = case response >>= field "proofTasks" of
  Just (Array ts) -> pure [t | t <- toList ts, prefix `isPrefixOf` textOf "declaration" t]
  _ -> fail ("no tasks: " ++ show response)

solver :: (FilePath -> IO ()) -> IO ()
solver action = do
  explicit <- lookupEnv "LAWSPEC_Z3"
  installed <- maybe (findExecutable "z3") (pure . Just) explicit
  maybe (pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks") action installed

solve :: FilePath -> String -> IO String
solve z3 script = do
  (status, output, errors) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] (script ++ "(check-sat)\n")
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure (takeWhile (/= '\n') output)

outcome :: FilePath -> Value -> IO String
outcome z3 scripted = do
  first <- solve z3 (textOf "script" scripted)
  if first == "unsat" then pure first else maybe (pure first) (solve z3 . textOf "script") (field "alternative" scripted)

-- | Proved outright, or in every case of its induction.
proved :: FilePath -> Value -> IO Bool
proved z3 task = do
  direct <- outcome z3 task
  if direct == "unsat" then pure True else case field "induction" task >>= field "cases" of
    Just (Array cs) | not (null cs) -> all (== "unsat") <$> forM (toList cs) (outcome z3)
    _ -> pure False

uses :: [String]
uses =
  [ "import lawspec.instances.laws (negated)"
  , "law \"|uses| is definition: negated true = false end definition end law" ]

test_capabilityLawsAreProved :: Spec
test_capabilityLawsAreProved = describe "capability laws" $ do
  it "are each a proof task, none unsupported" $ do
    found <- tasks "lawspec.instances.laws::law::" (tasksOf uses)
    length found `shouldSatisfy` (>= 20)
    [textOf "declaration" t ++ ": " ++ textOf "reason" t | t <- found, textOf "status" t == "unsupported"] `shouldBe` []
  it "are proved for the built-in instances, with their functions abstract" $ solver $ \z3 -> do
    found <- tasks "lawspec.instances.laws::law::" (tasksOf uses)
    results <- forM found $ \t -> (,) (textOf "declaration" t) <$> proved z3 t
    [name | (name, False) <- results] `shouldBe` []
  it "leave a spec's own adapter unsupported" $ do
    found <- tasks "probe.laws::law::" (tasksOf
      [ "native :: Integer -> Integer"
      , "law \"|own| is definition: for all (n :: Integer) => native n = native n end for all end definition end law" ])
    map (textOf "status") found `shouldBe` ["unsupported"]
    concatMap (textOf "reason") found `shouldSatisfy` ("native" `isInfixOf`)

reversal :: String -> [String]
reversal harness =
  [ "function double (n :: Integer) -> Integer is n * 2 end function"
  , "function bump (n :: Int32) -> Int32 is if n < 100 then n + 1 else n end if end function"
  , "function total (xs :: List Integer) -> Integer is"
  , "  first matching case of xs:"
  , "    when Nil then 0"
  , "    when Cons x rest then x + total rest"
  , "  end case"
  , "end function"
  , "function backwards (xs :: List Integer) -> List Integer is"
  , "  first matching case of xs:"
  , "    when Nil then []"
  , "    when Cons x rest then backwards rest ++ [x]"
  , "  end case"
  , "end function"
  , "law \"|doubling commutes with reversal| is definition:"
  , "  for all (xs :: List Integer) =>"
  , "    prelude.map double (backwards xs) = backwards (prelude.map double xs)"
  , "  end for all"
  , "end definition end law"
  , "law \"|bumping keeps the length| is definition:"
  , "  for all (xs :: List Int32) (ys :: List Int32) =>"
  , "    prelude.length (prelude.map bump (xs ++ ys)) = prelude.length xs + prelude.length ys"
  , "  end for all"
  , "end definition end law"
  , "law \"|a sum is itself| is definition:"
  , "  for all (xs :: List Integer) => total xs = total xs end for all"
  , "end definition end law"
  , "harness probe.laws.proofs for probe.laws is"
  , harness
  , "end harness" ]

-- | A law's induction cases, or why it has none.
inductionOf :: String -> [Value] -> Either String [Value]
inductionOf name found = case [t | t <- found, name `isInfixOf` textOf "declaration" t] of
  [task] -> case field "induction" task of
    Just plan | Just (Array cs) <- field "cases" plan -> Right (toList cs)
              | otherwise -> Left (textOf "reason" plan)
    Nothing -> Left "no induction"
  _ -> Left "no such task"

test_capabilityLawsAreCited :: Spec
test_capabilityLawsAreCited = describe "citing a capability law" $ do
  it "proves a law by the capability law at the law's own function" $ solver $ \z3 -> do
    cited <- tasks "probe.laws::law::" (tasksOf (reversal
      "for law \"|doubling commutes with reversal|\n prove by induction on xs using \"|map distributes over append|\n end for law"))
    plain <- tasks "probe.laws::law::" (tasksOf (reversal
      "for law \"|doubling commutes with reversal|\n prove by induction on xs\n end for law"))
    with <- either fail (mapM (outcome z3)) (inductionOf "reversal" cited)
    without <- either fail (mapM (outcome z3)) (inductionOf "reversal" plain)
    with `shouldBe` ["unsat", "unsat"]
    without `shouldSatisfy` (/= ["unsat", "unsat"])
  it "adds neither the capability laws nor their unit to the program" $ do
    found <- tasks "" (tasksOf (reversal
      "for law \"|doubling commutes with reversal|\n prove by induction on xs using \"|map distributes over append|\n end for law"))
    [textOf "declaration" t | t <- found, "lawspec.instances.laws" `isPrefixOf` textOf "declaration" t] `shouldBe` []
  it "asks of a function over a bounded type that it has a value everywhere" $ solver $ \z3 -> do
    found <- tasks "probe.laws::law::" (tasksOf (reversal
      "for law \"|bumping keeps the length|\n prove by induction on xs using \"|map keeps the length|, \"|length of an append is the sum|\n end for law"))
    cases <- either fail pure (inductionOf "bumping" found)
    concatMap (textOf "script") cases `shouldSatisfy` ("(=> (forall ((v" `isInfixOf`)
    mapM (outcome z3) cases `shouldReturn` ["unsat", "unsat"]
  it "refuses a citation the law writes nothing for" $ do
    found <- tasks "probe.laws::law::" (tasksOf (reversal
      "for law \"|a sum is itself|\n prove by induction on xs using \"|filters commute|\n end for law"))
    inductionOf "a sum is itself" found `shouldSatisfy` either ("writes no function" `isInfixOf`) (const False)
  it "rejects a name that is neither the unit's law nor a capability law" $ do
    show (tasksOf (reversal
      "for law \"|a sum is itself|\n prove by induction on xs using \"|no such law|\n end for law"))
      `shouldSatisfy` ("no capability law has that name" `isInfixOf`)
  it "has a current receipt for every capability law (lawspec-dev capability-receipts)" $ do
    keys <- either fail pure capabilityLawKeys
    length keys `shouldSatisfy` (>= 20)
    [C.idText law | (law, key) <- keys, lookup (C.idText law) capabilityReceipts /= Just key] `shouldBe` []
  it "refuses a capability law whose receipt is missing or for another form of it" $ do
    let law = C.Id "lawspec.instances.laws::law::|append associates|"
        keys = Right [(law, "now")]
    capabilityCitation [(C.idText law, "now")] keys law `shouldBe` Right ()
    capabilityCitation [(C.idText law, "before")] keys law `shouldSatisfy` either ("earlier form" `isInfixOf`) (const False)
    capabilityCitation [] keys law `shouldSatisfy` either ("no receipt" `isInfixOf`) (const False)
