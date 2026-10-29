-- | Stateful models and their commands.
module StatefulModelSpec (test_statefulModelsElaborateFromTypestate) where

import FixtureSource (extendUnit)
import Data.List (isInfixOf)
import Control.Monad (forM_)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Core.Machine
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)
import qualified LawSpec.ModelLaws as ML
import qualified LawSpec.Core.ModelCheck as MC

stack :: String
stack = unlines
  [ "unit example.stack"
   ++ "\n", ""
  , "type Stack (n :: Whole) is one of"
  , "  | Empty where n = 0"
  , "  | Push of type record{ top :: Int8 rest :: Stack m} where n = m + 1"
  , "end type"
  , "empty :: Unit -> Stack 0"
  , "push :: (x :: Int8) -> Stack n / Stack (n + 1) -> Unit"
  , "pop :: Stack (n + 1) / Stack n -> Int8"
  , "clear :: Stack n / Stack 0 -> Unit"
  , "function modelPush (x :: Int8) (xs :: List Int8) -> List Int8 is Cons x xs end function\n"
  , "function modelPop (xs :: List Int8) -> Pair Int8 (List Int8) is"
  , "  first matching case of xs :"
  , "  when Nil then Pair record{ first = 0 , second = Nil}"
  , "  when Cons x rest then Pair record{ first = x , second = rest}"
  , "  end case"
  , "end function"
  , "function modelClear (xs :: List Int8) -> List Int8 is Nil end function\n"
  , "function short (xs :: List Int8) -> Bool is prelude.length xs <= 3 end function\n"
  , "\nend unit" ]

counter :: String
counter = unlines
  [ "unit example.counter"
   ++ "\n", ""
  , "type Counter is a record{  id :: Int32} end type\n"
  , "newCounter :: Unit -> Counter"
  , "increment :: Counter -> Int64"
  , "decrement :: Counter -> Int64"
  , "function modelIncrement (n :: Int64 where n >= 0 && n <= 1000) -> Pair Int64 Int64 is Pair record{ first = (n + 1) , second = (n + 1)} end function\n"
  , "function modelDecrement (n :: Int64 where n >= 0 && n <= 1000) -> Pair Int64 Int64 is Pair record{ first = (n - 1) , second = (n - 1)} end function\n"
  , "function positive (n :: Int64) -> Bool is n > 0 end function\n"
  , "\nend unit" ]

machinesOf :: String -> Either String [Machine String]
machinesOf source = case compile [Source "model.lawspec" source] of
  Left diagnostics -> Left (concatMap show diagnostics)
  Right (units, _) -> Right (concatMap machines units)

rejects :: String -> String -> Expectation
rejects fragment source = case machinesOf source of
  Left message -> message `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

-- | A model checks real implementations against a history of calls, so each
-- command's typestate and precondition must come from its declaration and a
-- malformed model must be rejected. ref:DEC-stateful-models-linearizability
-- ref:REQ-stateful-models
test_statefulModelsElaborateFromTypestate :: Spec
test_statefulModelsElaborateFromTypestate = describe "stateful models" $ do
  -- ref:DEC-typed-core-boundary ref:DEC-actors-otp-supervision
  it "preserves adapters' ability rows and async flags in model bridges" $ do
    input <- readFile "acceptance/beam-actor-api/actor_api.lawspec"
    case compileCore 64 defaultGeneration [Source "actor_api.lawspec" input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let units = C.programUnits program
            declarations = [(C.declarationId d,d) | u <- units, d <- C.unitDeclarations u]
            bridges = concat [ [(startRun s,startSystem s) | Just s <- [machineStart m]] ++
              [(commandRun c,commandSystem c) | c <- machineCommands m]
              | u <- units, m <- C.unitMachines u]
        [C.declarationName a | (_,adapter) <- bridges, Just a <- [lookup adapter declarations]]
          `shouldMatchList` ["openCounter", "add", "total", "clear", "echo", "reopen"]
        forM_ bridges $ \(bridge,adapter) -> case (lookup bridge declarations,lookup adapter declarations) of
          (Just b,Just a) -> do
            C.declarationUses b `shouldBe` C.declarationUses a
            C.declarationAsync b `shouldBe` C.declarationAsync a
          _ -> expectationFailure "missing model bridge or adapter"
        [C.declarationAsync d | (identity,d) <- declarations, identity `elem` map fst bridges]
          `shouldSatisfy` or
        [C.declarationUses d | (identity,d) <- declarations, identity `elem` map fst bridges]
          `shouldSatisfy` any (not . null)
  it "read each command's typestate from its flow parameter" $
    case machinesOf (extendUnit stack $ unlines
      [ "model stack :: Stack n by List Int8 is"
      , "  start empty by Nil"
      , "  push by modelPush"
      , "  pop by modelPop"
      , "  clear ~ modelClear"
      , "  invariant short"
      , "end"  ++ " model"]) of
      Left message -> expectationFailure message
      Right [m] -> do
        machineShared m `shouldBe` False
        machineState m `shouldBe` "Stack"
        fmap startIndices (machineStart m) `shouldBe` Just (Just [0])
        [(commandName c, commandNeeds c, commandShifts c) | c <- machineCommands m] `shouldBe`
          [("push", [AtLeast 0], [By 1]), ("pop", [AtLeast 1], [By (-1)]), ("clear", [AtLeast 0], [To 0])]
        machineInvariants m `shouldBe` [OnModel "short"]
        let [push, pop, _] = machineCommands m
        admits pop [0] `shouldBe` False
        shifted push [0] `shouldBe` [1]
      Right other -> expectationFailure (show other)
  it "elaborate a shared model with a precondition" $
    case machinesOf (extendUnit counter $ unlines
      [ "model counter :: shared Counter by Int64 is"
      , "  start newCounter ~ 0"
      , "  increment ~ modelIncrement"
      , "  decrement ~ modelDecrement when positive"
      , "end"  ++ " model"]) of
      Left message -> expectationFailure message
      Right [m] -> do
        machineShared m `shouldBe` True
        [(commandName c, commandWhen c, commandStatePosition c) | c <- machineCommands m] `shouldBe`
          [("increment", Nothing, 0), ("decrement", Just "positive", 0)]
      Right other -> expectationFailure (show other)
  describe "reject" $ do
    it "a reference of the wrong type" $
      rejects "command pop's reference modelPush must have type" (extendUnit stack $ unlines
        [ "model stack :: Stack n by List Int8 is"
        , "  pop by modelPush"
        , "end"  ++ " model"])
    it "an indexed shared state" $
      rejects "a shared state's type cannot change" (extendUnit stack $ unlines
        [ "model stack :: shared Stack n by List Int8 is"
        , "  push by modelPush"
        , "end"  ++ " model"])
    it "a linear command without a flow parameter" $
      rejects "must take the state as a flow parameter" (extendUnit counter $ unlines
        [ "model counter :: Counter by Int64 is"
        , "  increment ~ modelIncrement"
        , "end"  ++ " model"])
    it "a checked definition as a command" $
      rejects "commands are adapters" (extendUnit counter $ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  positive ~ modelIncrement"
        , "end"  ++ " model"])
    it "a precondition that is not over the model state" $
      rejects "precondition modelIncrement must have type" (extendUnit counter $ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  increment ~ modelIncrement when modelIncrement"
        , "end"  ++ " model"])
    it "a start that does not make the state" $
      rejects "start increment must return Counter" (extendUnit counter $ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  start increment ~ 0"
        , "end"  ++ " model"])
  -- The reference domain changes after each transition; enumerating once
  -- at the initial state would permanently lose chooseAt. ref:DEC-dependent-model-arguments
  it "enumerates dependent arguments at zero, after transitions, and after clearing" $ do
    source <- readFile "test/fixtures/dependent-model-arguments.lawspec"
    let core = either (error . show) id (compileCore 64 defaultGeneration [Source "dependent.lawspec" source])
        machine = head [m | u <- C.programUnits core, m <- C.unitMachines u]
        system = either error id (ML.systemOf core machine)
        first = head (MC.systemInitial system)
        steps state = either error id (MC.systemSteps system state)
        chosen state = [shown | (name,shown,_) <- steps state, name == "chooseAt"]
        next command state = head [s | (name,_,s) <- steps state, name == command]
        one = next "push" first
        two = next "push" one
    chosen first `shouldBe` []
    chosen one `shouldBe` ["chooseAt 0"]
    chosen two `shouldBe` ["chooseAt 0", "chooseAt 1"]
    chosen (next "clear" two) `shouldBe` []
