-- | Stateful models and their commands.
module StatefulModelSpec (test_statefulModelsElaborateFromTypestate) where

import Data.List (isInfixOf)
import Control.Monad (forM_)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Core.Machine
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)

stack :: String
stack = unlines
  [ "unit example.stack"
  , "type Stack (n :: Natural) is"
  , "  | Empty where n = 0"
  , "  | Push top :: Int8 rest :: Stack m where n = m + 1"
  , "end"
  , "empty :: Unit -> Stack 0"
  , "push :: (x :: Int8) -> Stack n / Stack (n + 1) -> Unit"
  , "pop :: Stack (n + 1) / Stack n -> Int8"
  , "clear :: Stack n / Stack 0 -> Unit"
  , "definition modelPush (x :: Int8) (xs :: List Int8) :: List Int8 is Cons x xs end"
  , "definition modelPop (xs :: List Int8) :: Pair Int8 (List Int8) is"
  , "  match xs with"
  , "  | Nil -> Pair 0 Nil"
  , "  | Cons x rest -> Pair x rest"
  , "  end"
  , "end"
  , "definition modelClear (xs :: List Int8) :: List Int8 is Nil end"
  , "definition short (xs :: List Int8) :: Bool is prelude.length xs <= 3 end" ]

counter :: String
counter = unlines
  [ "unit example.counter"
  , "type Counter is Counter id :: Int32 end"
  , "newCounter :: Unit -> Counter"
  , "increment :: Counter -> Int64"
  , "decrement :: Counter -> Int64"
  , "definition modelIncrement (n :: Int64 where n >= 0 && n <= 1000) :: Pair Int64 Int64 is Pair (n + 1) (n + 1) end"
  , "definition modelDecrement (n :: Int64 where n >= 0 && n <= 1000) :: Pair Int64 Int64 is Pair (n - 1) (n - 1) end"
  , "definition positive (n :: Int64) :: Bool is n > 0 end" ]

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
        length bridges `shouldBe` 4
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
    case machinesOf (stack ++ unlines
      [ "model stack :: Stack n by List Int8 is"
      , "  start empty by Nil"
      , "  push by modelPush"
      , "  pop by modelPop"
      , "  clear ~ modelClear"
      , "  invariant short"
      , "end" ]) of
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
    case machinesOf (counter ++ unlines
      [ "model counter :: shared Counter by Int64 is"
      , "  start newCounter ~ 0"
      , "  increment ~ modelIncrement"
      , "  decrement ~ modelDecrement when positive"
      , "end" ]) of
      Left message -> expectationFailure message
      Right [m] -> do
        machineShared m `shouldBe` True
        [(commandName c, commandWhen c, commandStatePosition c) | c <- machineCommands m] `shouldBe`
          [("increment", Nothing, 0), ("decrement", Just "positive", 0)]
      Right other -> expectationFailure (show other)
  describe "reject" $ do
    it "a reference of the wrong type" $
      rejects "command pop's reference modelPush must have type" (stack ++ unlines
        [ "model stack :: Stack n by List Int8 is"
        , "  pop by modelPush"
        , "end" ])
    it "an indexed shared state" $
      rejects "a shared state's type cannot change" (stack ++ unlines
        [ "model stack :: shared Stack n by List Int8 is"
        , "  push by modelPush"
        , "end" ])
    it "a linear command without a flow parameter" $
      rejects "must take the state as a flow parameter" (counter ++ unlines
        [ "model counter :: Counter by Int64 is"
        , "  increment ~ modelIncrement"
        , "end" ])
    it "a checked definition as a command" $
      rejects "commands are adapters" (counter ++ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  positive ~ modelIncrement"
        , "end" ])
    it "a precondition that is not over the model state" $
      rejects "precondition modelIncrement must have type" (counter ++ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  increment ~ modelIncrement when modelIncrement"
        , "end" ])
    it "a start that does not make the state" $
      rejects "start increment must return Counter" (counter ++ unlines
        [ "model counter :: shared Counter by Int64 is"
        , "  start increment ~ 0"
        , "end" ])
