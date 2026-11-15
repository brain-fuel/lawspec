-- | The capability laws, proved for the built-in instances with their
-- functions left abstract. ref:DEC-capability-laws
module InstanceLawsSpec (test_capabilityLawsAreProved) where

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
