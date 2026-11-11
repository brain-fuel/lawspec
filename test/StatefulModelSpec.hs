-- | Stateful models and their commands.
module StatefulModelSpec (test_statefulModelsElaborateFromTypestate, test_actorRuntimeSettings) where

import FixtureSource (extendUnit)
import Data.List (isInfixOf)
import Control.Monad (forM_)
import Test.Hspec
import LawSpec.ActorRuntime
import LawSpec.Compile
import Data.Aeson (Value (..), object, (.=))
import LawSpec.Core.Machine
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore, elaborateCanonical)
import LawSpec.Model hiding (Expectation)
import qualified LawSpec.ModelLaws as ML
import qualified LawSpec.Core.ModelCheck as MC
import LawSpec.Core.Evidence (Obligation(..), Status(..))

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
  -- ref:DEC-restart-keeps-state
  it "elaborates restart keeps state into checked identities, not bridges" $ do
    input <- readFile "examples/specs/restarts.lawspec"
    case compileCore 64 defaultGeneration [Source "restarts.lawspec" input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let units = C.programUnits program
            declarations = [(C.declarationId d,d) | u <- units, d <- C.unitDeclarations u]
            restarts = [c | u <- units, m <- C.unitMachines u, c <- machineCommands m, commandRestart c]
            named identity = fmap C.declarationName (lookup identity declarations)
        [(named (commandSystem c), commandRun c == commandSystem c) | c <- restarts]
          `shouldBe` [(Just "tabKeepState", True)]
  -- time passes by r: the actor's timePasses step, whose adapter LawSpec
  -- declares; laws over its runs may assume it is fair. ref:DEC-time-passes
  it "elaborates time passes into the actor's timePasses step" $ do
    input <- readFile "acceptance/pekko-samples/fsm/hakkers.lawspec"
    case compileCore 64 defaultGeneration [Source "hakkers.lawspec" input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let units = C.programUnits program
            declarations = [(C.declarationId d,d) | u <- units, d <- C.unitDeclarations u]
            steps = [c | u <- units, m <- C.unitMachines u, c <- machineCommands m, commandName c == "timePasses"]
        [(fmap C.declarationName (lookup (commandSystem c) declarations), commandReturnsUnit c) | c <- steps]
          `shouldBe` [(Just "hakkerTimePasses", False)]
  it "rejects a second time passes line and a handler named timePasses" $ do
    input <- readFile "acceptance/pekko-samples/fsm/hakkers.lawspec"
    let line = "  time passes by modelTimePasses when timerSet"
        twice = unlines (concatMap (\l -> if l == line then [l, l] else [l]) (lines input))
        named = unlines (concatMap (\l -> if l == "  on think by modelThink when waiting" then ["  on timePasses by modelThink when waiting"]
          else if l == "openDiner :: Unit -> Diner" then [l, "timePasses :: Diner -> Diner"] else [l]) (lines input))
    case compileCore 64 defaultGeneration [Source "hakkers.lawspec" twice] of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "says how time passes more than once"
      Right _ -> expectationFailure "expected a rejection"
    case compileCore 64 defaultGeneration [Source "hakkers.lawspec" named] of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "timePasses names its time passes step"
      Right _ -> expectationFailure "expected a rejection"
  it "refutes every hungry hakker eating, with time passing fairly" $ do
    input <- readFile "acceptance/pekko-samples/fsm/hakkers.lawspec"
    let starving = unlines (concatMap (\l -> if l == "law \"|a hakker can eat| in model hakker is"
          then [ "law \"|every hungry hakker eats| in model hakker assuming strong fairness for think, time passes,"
               , "    asksLeft, putsDownLeft, asksRight, putsDownRight, leftTaken, leftBusy, rightTaken, rightBusy is"
               , "  definition: every run holds whenever hungry, eventually eats end definition"
               , "end law", l]
          else [l]) (lines input))
    case compileCanonical [Source "hakkers.lawspec" starving] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right (us, es) -> case elaborateCanonical 64 us es of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right core -> case ML.modelLawEvidence True us core of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right obligations -> do
            let verdict name = [(obligationStatus o, obligationReason o) | o <- obligations, C.idText (obligationDeclaration o) == "sample.hakkers::law::|" ++ name ++ "|"]
            map fst (verdict "every hungry hakker eats") `shouldBe` [Refuted]
            concatMap snd (verdict "every hungry hakker eats") `shouldSatisfy` isInfixOf "strong fairness for timePasses"
            map fst (verdict "a hakker can eat") `shouldBe` [Proved]
  it "rejects an actor with two restart lines" $ do
    input <- readFile "examples/specs/restarts.lawspec"
    let twice = unlines (concatMap (\line -> if line == "  restart keeps state" then [line, line] else [line]) (lines input))
    case compileCore 64 defaultGeneration [Source "restarts.lawspec" twice] of
      Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "says how it restarts more than once"
      Right _ -> expectationFailure "expected a rejection"
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

-- | A target's :actors settings pick its actor runtime; the JVM runtimes are
-- refused elsewhere, and nothing unknown is ignored. ref:DEC-pekko-runtime
test_actorRuntimeSettings :: Spec
test_actorRuntimeSettings = describe "actor runtime settings" $ do
  let settings target value = actorSettings "actors" (Just target) (Just value)
  it "default to LawSpec's runtime" $
    actorSettings "actors" (Just "java") Nothing `shouldBe` Right defaultActorSettings
  it "select Pekko on a JVM target" $
    settings "kotlin" (object ["runtime" .= ("pekko" :: String)])
      `shouldBe` Right (ActorSettings PekkoActors LawSpecRemote)
  it "reject Pekko off the JVM, unknown fields and cluster without a JVM runtime" $ do
    settings "python" (object ["runtime" .= ("pekko" :: String)])
      `shouldSatisfy` either (any (isInfixOf "runs on the JVM")) (const False)
    settings "java" (object ["mailbox" .= ("x" :: String)])
      `shouldSatisfy` either (any (isInfixOf "unknown field mailbox")) (const False)
    settings "java" (object ["remote" .= ("cluster" :: String)])
      `shouldSatisfy` either (any (isInfixOf "needs :runtime :pekko or :spring")) (const False)
