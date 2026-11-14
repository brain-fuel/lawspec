-- | A definition may take a function as a parameter. Each call names the
-- function where it is written, and a first-order copy is made for it.
-- ref:DEC-function-parameters
module FunctionParameterSpec (test_definitionsTakeFunctionParameters) where

import Control.Monad (forM)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import qualified LawSpec.Api as API
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

program :: [String] -> Either [Diagnostic] C.Program
program body = compileCore 64 defaultGeneration
  [Source "functions.lawspec" (unlines (["unit functions.eval"] ++ body ++ ["end unit"]))]

evaluated :: [String] -> Either [Diagnostic] ()
evaluated body = program body >>= dischargeEvidence >>= \_ -> pure ()

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

helpers :: [String]
helpers =
  [ "function double (n :: Integer) -> Integer is n * 2 end function"
  , "function increment (n :: Integer) -> Integer is n + 1 end function"
  , "function scaled (factor :: Integer) (n :: Integer) -> Integer is factor * n end function"
  , "function isEven (n :: Integer) -> Bool is prelude.rem n 2 = 0 end function" ]

-- | The proof tasks of a unit over bounded integers, through the API.
proofTasks :: [String] -> Maybe Value
proofTasks laws = decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("proofTasks" :: String)
  , "verification" .= object ["layers" .= ["proof" :: String]]
  , "sources" .= [object ["path" .= ("functions.lawspec" :: String), "content" .= unlines (["unit functions.smt"] ++
      [ "function lowered (n :: Int32) -> Int32 is if n > 0 then n - 1 else n end if end function"
      , "function count (xs :: List Int32) -> Whole is"
      , "  first matching case of xs: when Nil then 0 when Cons x rest then 1 + count rest end case"
      , "end function" ] ++ each ++ laws ++ ["end unit"])]] ])))

field :: K.Key -> Value -> Maybe Value
field k (Object o) = K.lookup k o
field _ _ = Nothing

textOf :: K.Key -> Value -> String
textOf k v = case field k v of Just (String t) -> T.unpack t; _ -> ""

taskFor :: String -> Maybe Value -> Maybe Value
taskFor name response = case response >>= field "proofTasks" of
  Just (Array ts) -> case [t | t <- toList ts, ("::law::" ++ name) `isSuffixOf` textOf "declaration" t] of
    t : _ -> Just t
    [] -> Nothing
  _ -> Nothing

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

-- | Each induction case's outcome: its first encoding's, else its alternative's.
caseOutcomes :: FilePath -> Value -> IO [String]
caseOutcomes z3 task = case field "induction" task >>= field "cases" of
  Just (Array cs) -> forM (toList cs) $ \c -> do
    first <- solve z3 (textOf "script" c)
    if first == "unsat" then pure first else maybe (pure first) (solve z3 . textOf "script") (field "alternative" c)
  _ -> fail ("no induction cases: " ++ show task)

each :: [String]
each =
  [ "function each (f :: a -> b) (xs :: List a) -> List b is"
  , "  first matching case of xs: when Nil then [] when Cons x rest then Cons (f x) (each f rest) end case"
  , "end function" ]

test_definitionsTakeFunctionParameters :: Spec
test_definitionsTakeFunctionParameters =
  describe "definitions with function parameters" $ do
    it "applies a named definition passed as a parameter" $
      evaluated (helpers ++
        [ "function applyTwice (f :: Integer -> Integer) (n :: Integer) -> Integer is f (f n) end function"
        , "law \"|twice| is definition :"
        , "  applyTwice double 3 = 12 and applyTwice increment 3 = 5"
        , "end definition end law" ])
        `shouldSatisfy` isRight
    it "refutes a wrong result through a function parameter" $
      evaluated (helpers ++
        [ "function applyTwice (f :: Integer -> Integer) (n :: Integer) -> Integer is f (f n) end function"
        , "law \"|twice| is definition : applyTwice double 3 = 11 end definition end law" ])
        `shouldSatisfy` isLeft
    it "passes its own function parameter to a recursive call" $
      evaluated (helpers ++ each ++
        [ "law \"|each| is definition :"
        , "  each double [1, 2, 3] = [2, 4, 6] and each isEven [1, 2] = [false, true]"
        , "end definition end law" ])
        `shouldSatisfy` isRight
    it "takes a partial application, whose arguments are evaluated at the call" $
      evaluated (helpers ++ each ++
        [ "law \"|scaled| is definition :"
        , "  each (scaled 3) [1, 2] = [3, 6] and each (scaled (1 + 1)) [5] = [10]"
        , "end definition end law" ])
        `shouldSatisfy` isRight
    it "takes a composition" $
      evaluated (helpers ++ each ++
        [ "law \"|composed| is definition : each (double . increment) [1, 2] = [4, 6] end definition end law" ])
        `shouldSatisfy` isRight
    it "passes a function parameter on to another definition" $
      evaluated (helpers ++ each ++
        [ "function eachTwice (f :: a -> a) (xs :: List a) -> List a is each f (each f xs) end function"
        , "law \"|twice| is definition : eachTwice double [1, 2] = [4, 8] end definition end law" ])
        `shouldSatisfy` isRight
    it "takes two function parameters" $
      evaluated (helpers ++
        [ "function keepThen (keep :: a -> Bool) (f :: a -> b) (xs :: List a) -> List b is"
        , "  first matching case of xs:"
        , "    when Nil then []"
        , "    when Cons x rest then if keep x then Cons (f x) (keepThen keep f rest) else keepThen keep f rest end if"
        , "  end case"
        , "end function"
        , "law \"|kept| is definition : keepThen isEven double [1, 2, 3, 4] = [4, 8] end definition end law" ])
        `shouldSatisfy` isRight
    it "makes one first-order copy per function, shared by equal calls" $
      case program (helpers ++ each ++
        [ "law \"|shared| is definition :"
        , "  each double [1] = [2] and each double [2] = [4] and each increment [1] = [2]"
        , "end definition end law" ]) of
        Left problems -> expectationFailure (show problems)
        Right compiled -> do
          let copies = [C.idText (C.declarationId (C.definitionDeclaration d))
                | u <- C.programUnits compiled, d <- C.unitDefinitions u
                , "each" `isInfixOf` C.idText (C.declarationId (C.definitionDeclaration d))]
          length copies `shouldBe` 2
    it "admits a definition with a function parameter that nothing calls" $
      evaluated (helpers ++ each ++
        [ "law \"|plain| is definition : double 2 = 4 end definition end law" ])
        `shouldSatisfy` isRight
    it "rejects a non-terminating definition with a function parameter" $
      program (helpers ++
        [ "function forever (f :: Integer -> Integer) (n :: Integer) -> Integer is forever f (f n) end function"
        , "law \"|plain| is definition : double 2 = 4 end definition end law" ])
        `shouldSatisfy` isLeft
    it "rejects a definition that returns a function" $
      program (helpers ++
        [ "function pick (n :: Integer) -> Integer -> Integer is double end function"
        , "law \"|plain| is definition : double 2 = 4 end definition end law" ])
        `shouldSatisfy` failsWith "result"
    it "gives the solver the first-order copy, proved by unfolding" $ solver $ \z3 -> do
      let response = proofTasks
            [ "law \"|one| is definition: for all (x :: Int32) => each lowered [x] = [lowered x] end for all end definition end law" ]
      task <- maybe (fail ("no task: " ++ show response)) pure (taskFor "|one|" response)
      textOf "status" task `shouldNotBe` "unsupported"
      solve z3 (textOf "script" task) >>= (`shouldBe` "unsat")
    it "proves a law over a list by induction through the copy" $ solver $ \z3 -> do
      let response = proofTasks
            [ "law \"|counted| is definition: for all (xs :: List Int32) => count (each lowered xs) = count xs end for all end definition end law" ]
      task <- maybe (fail ("no task: " ++ show response)) pure (taskFor "|counted|" response)
      caseOutcomes z3 task >>= (`shouldBe` ["unsat", "unsat"])
    it "does not prove a false law about the copy" $ solver $ \z3 -> do
      let response = proofTasks
            [ "law \"|wrong| is definition: for all (x :: Int32) => each lowered [x] = [x] end for all end definition end law" ]
      task <- maybe (fail ("no task: " ++ show response)) pure (taskFor "|wrong|" response)
      solve z3 (textOf "script" task) >>= (`shouldNotBe` "unsat")
