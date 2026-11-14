-- | The solver reasons about a collection operation through its capability
-- instance's definition: by unfolding on a list that is written out, and by
-- induction over any list. ref:DEC-capability-instances
module SmtInstancesSpec (test_solverUsesInstanceDefinitions) where

import Control.Monad (forM)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isSuffixOf)
import qualified Data.Text as T
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Api as API

definitions :: [String]
definitions =
  [ "import lawspec.instances (mapList, filterList, foldLeftList, foldRightList, allList, lengthList, appendList)"
  , "type Reading is a record{"
  , "  amount :: Rational"
  , "  count :: Int32"
  , "}"
  , "end type"
  , "wrapper Several (a :: Type) is List a where prelude.length value > 0"
  , "end wrapper"
  , "function doubled (reading :: Reading) -> Rational is reading.amount + reading.amount end function"
  , "function size (several :: Several Int32) -> Integer is prelude.length (valueOfSeveral several) end function"
  , "function lowered (n :: Int32) -> Int32 is if n > 0 then n - 1 else n end if end function"
  , "function positive (n :: Int32) -> Bool is n > 0 end function"
  , "function capped (limit :: Int32) (n :: Int32) -> Int32 is if n > limit then limit else n end if end function"
  , "function plus (a :: Integer) (b :: Integer) -> Integer is a + b end function" ]

laws :: [String]
laws =
  [ law "map one" "for all (x :: Int32) => prelude.map lowered [x] = [lowered x] end for all"
  , law "fold two" "for all (x :: Integer) (y :: Integer) => prelude.foldLeft plus 0 [x, y] = x + y and prelude.foldRight plus 0 [x, y] = x + y end for all"
  , law "written out" "prelude.filter positive [1, -2, 3] = [1, 3] and prelude.all positive [1, 2] and prelude.length [lowered 1, 2, 3] = 3 and [lowered 1] ++ [2] = [0, 2]"
  , law "map wrong" "for all (x :: Int32) => prelude.map lowered [x] = [x] end for all"
  , law "map keeps length" "for all (xs :: List Int32) => prelude.length (prelude.map lowered xs) = prelude.length xs end for all"
  , law "filter keeps the accepted" "for all (xs :: List Int32) => prelude.all positive (prelude.filter positive xs) end for all"
  , law "filter shortens" "for all (xs :: List Int32) => prelude.length (prelude.filter positive xs) <= prelude.length xs end for all"
  , law "filter keeps all" "for all (xs :: List Int32) => prelude.filter positive xs = xs end for all"
  , law "append nil" "for all (xs :: List Int32) => xs ++ [] = xs end for all"
  , law "captured" "for all (limit :: Int32) (xs :: List Int32) => prelude.length (prelude.map (capped limit) xs) = prelude.length xs end for all"
  , law "map over append" "for all (xs :: List Int32) (ys :: List Int32) => prelude.map lowered (xs ++ ys) = prelude.map lowered xs ++ prelude.map lowered ys end for all"
  , law "map is mapList" "for all (xs :: List Int32) => prelude.map lowered xs = mapList lowered xs end for all"
  , law "filter is filterList" "for all (xs :: List Int32) => prelude.filter positive xs = filterList positive xs end for all"
  , law "all is allList" "for all (xs :: List Int32) => prelude.all positive xs = allList positive xs end for all"
  , law "length is lengthList" "for all (xs :: List Int32) => prelude.length xs = lengthList xs end for all"
  , law "append is appendList" "for all (xs :: List Int32) => xs ++ [1] = appendList xs [1] end for all"
  , law "foldLeft is foldLeftList" "for all (start :: Integer) (xs :: List Integer) => prelude.foldLeft plus start xs = foldLeftList plus start xs end for all"
  , law "foldRight is foldRightList" "for all (xs :: List Integer) => prelude.foldRight plus 0 xs = foldRightList plus 0 xs end for all" ]
  ++
  [ law "rational field" "for all (reading :: Reading) => doubled reading = 2 * reading.amount end for all"
  , law "rational field wrong" "for all (reading :: Reading) => doubled reading = reading.amount end for all"
  , law "no reading squares to two" "there exists (reading :: Reading) such that reading.amount * reading.amount = 2 end exists"
  , law "some reading is a half" "there exists (reading :: Reading) such that reading.amount + reading.amount = 1 end exists"
  , law "several is never empty" "for all (several :: Several Int32) => size several > 0 end for all"
  , law "several wrong" "for all (several :: Several Int32) => size several > 1 end for all" ]
  where law name body = "law \"|" ++ name ++ "| is definition: " ++ body ++ " end definition end law"

response :: Maybe Value
response = decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
  , "verification" .= object ["layers" .= ["proof" :: String]]
  , "sources" .= [object ["path" .= ("instances.lawspec" :: String), "content" .= unlines (["unit instances.smt"] ++ definitions ++ laws ++
      [ "harness instances.smt.proofs for instances.smt is"
      , "for law \"|map over append|", "  prove by induction on xs", "end for law"
      , "end harness", "end unit" ])]] ])))

field :: K.Key -> Value -> Maybe Value
field k (Object o) = K.lookup k o
field _ _ = Nothing

textOf :: K.Key -> Value -> String
textOf k v = case field k v of Just (String t) -> T.unpack t; _ -> ""

task :: String -> IO Value
task name = case response >>= field "proofTasks" of
  Just (Array ts) -> case [t | t <- toList ts, ("::law::|" ++ name ++ "|") `isSuffixOf` textOf "declaration" t] of
    t : _ -> pure t
    [] -> fail ("no task for " ++ name ++ ": " ++ show (response >>= field "diagnostics"))
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

-- | A script's outcome: its first encoding's, else its alternative's.
outcome :: FilePath -> Value -> IO String
outcome z3 scripted = do
  first <- solve z3 (textOf "script" scripted)
  if first == "unsat" then pure first else maybe (pure first) (solve z3 . textOf "script") (field "alternative" scripted)

direct :: FilePath -> String -> IO String
direct z3 name = task name >>= outcome z3

byInduction :: FilePath -> String -> IO [String]
byInduction z3 name = do
  found <- task name
  case field "induction" found >>= field "cases" of
    Just (Array cs) -> forM (toList cs) (outcome z3)
    _ -> fail ("no induction cases for " ++ name ++ ": " ++ textOf "status" found ++ " " ++ textOf "reason" found)

test_solverUsesInstanceDefinitions :: Spec
test_solverUsesInstanceDefinitions =
  describe "the solver on collection operations" $ do
    it "gives every operation a task, none unsupported" $ do
      statuses <- forM ["map one", "fold two", "written out", "map keeps length", "filter shortens", "append nil", "foldRight is foldRightList"] $ \name ->
        textOf "status" <$> task name
      statuses `shouldNotContain` ["unsupported"]
    it "proves a law about a list that is written out, by unfolding" $ solver $ \z3 -> do
      direct z3 "map one" >>= (`shouldBe` "unsat")
      direct z3 "fold two" >>= (`shouldBe` "unsat")
      direct z3 "written out" >>= (`shouldBe` "unsat")
    it "does not prove a false law" $ solver $ \z3 -> do
      direct z3 "map wrong" >>= (`shouldNotBe` "unsat")
      byInduction z3 "filter keeps all" >>= (`shouldNotBe` ["unsat", "unsat"])
    it "proves laws over any list by induction" $ solver $ \z3 -> do
      byInduction z3 "map keeps length" >>= (`shouldBe` ["unsat", "unsat"])
      byInduction z3 "filter keeps the accepted" >>= (`shouldBe` ["unsat", "unsat"])
      byInduction z3 "filter shortens" >>= (`shouldBe` ["unsat", "unsat"])
      byInduction z3 "append nil" >>= (`shouldBe` ["unsat", "unsat"])
    it "passes what the function captures as an argument" $ solver $ \z3 ->
      byInduction z3 "captured" >>= (`shouldBe` ["unsat", "unsat"])
    it "gives one function to every place that writes the same function" $ solver $ \z3 ->
      byInduction z3 "map over append" >>= (`shouldBe` ["unsat", "unsat"])
    it "proves each operation equal to its definition in lawspec.instances" $ solver $ \z3 -> do
      results <- forM ["map is mapList", "filter is filterList", "all is allList", "length is lengthList", "append is appendList", "foldLeft is foldLeftList", "foldRight is foldRightList"] $ \name ->
        (,) name <$> byInduction z3 name
      results `shouldBe` [(name, ["unsat", "unsat"]) | (name, _) <- results]
    it "takes a record with a Rational field, and a wrapper with a type parameter" $ solver $ \z3 -> do
      direct z3 "rational field" >>= (`shouldBe` "unsat")
      direct z3 "rational field wrong" >>= (`shouldNotBe` "unsat")
      direct z3 "several is never empty" >>= (`shouldBe` "unsat")
      direct z3 "several wrong" >>= (`shouldNotBe` "unsat")
    it "keeps a Rational field exact where some value is claimed" $ solver $ \z3 -> do
      direct z3 "some reading is a half" >>= (`shouldBe` "unsat")
      direct z3 "no reading squares to two" >>= (`shouldNotBe` "unsat")
