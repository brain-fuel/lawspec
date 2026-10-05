-- Protocols and scenarios. A protocol lists what one end of a channel sends
-- and receives, in order; the other end does the opposite (its dual). A
-- scenario drives a shared model's commands from processes that run at the
-- same time (`par ... with ... end`) and talk over channels.
--
-- The checks here make a scenario deadlock-free and race-free by
-- construction (propositions as sessions: Caires and Pfenning, Wadler):
--
--   * each channel joins exactly two processes, the branches of one `par`,
--     and the channels of the scenario form a tree over the processes;
--   * each end follows its protocol, step by step, to the end;
--   * a value sent away is no longer the sender's to use.
--
-- A channel end only travels over a channel, which joins the sender and the
-- receiver, so delegation keeps the processes a tree.
module LawSpec.Scenario
  ( Step(..), Protocol(..), Statement(..), Scenario(..), Argument(..)
  , checkScenarios, dual, channelsIn, toProgram
  ) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Data.List (nub)
import qualified Data.Map.Strict as M
import LawSpec.Common (Span(..))
import LawSpec.Core.Machine (Machine(..), Command(..))
import qualified LawSpec.Core.Program as P
import LawSpec.Model


-- A command or message argument: a variable the process holds (given up
-- when written ~x), or a constant.
data Argument = Held String | Given String | Constant Expr
  deriving (Eq, Show)

data Statement
  = Bind String String [Argument] Span    -- x <- command args
  | Call String [Argument] Span           -- command args
  | SendTo String Argument Span           -- send channel value
  | ReceiveFrom String String Span        -- receive channel x
  | Par [[Statement]] Span                -- par ... with ... end
  | Expect String Expr Span               -- expect x = value
  deriving (Eq, Show)

data Scenario = Scenario
  { scenarioName :: String, scenarioModel :: String
  , scenarioChannels :: [(String, String, Span)]
  , scenarioBody :: [Statement], scenarioSpan :: Span }
  deriving (Eq, Show)

type Failure = (Maybe Span, String)

-- The other end's steps.
dual :: [Step] -> [Step]
dual = map flipped
  where
    flipped (Send t) = Receive t
    flipped (Receive t) = Send t

-- Checks every scenario against the unit's protocols, models and signatures.
checkScenarios :: [Protocol] -> [Scenario] -> Unit -> Either Failure ()
checkScenarios protocols scenarios u = do
  let names = map protocolName protocols
  forM_ protocols $ \p -> when (length (filter (== protocolName p) names) > 1)
    (Left (Just (protocolSpan p), "protocol " ++ protocolName p ++ " is declared twice"))
  mapM_ (checkScenario protocols u) scenarios

-- What a process holds: its variables' types and, for each channel end it
-- holds, the steps left.
data Holding = Holding { values :: M.Map String Type, ends :: M.Map String [Step] }

checkScenario :: [Protocol] -> Unit -> Scenario -> Either Failure ()
checkScenario protocols u s = do
  machine <- maybe (failing (scenarioSpan s) ("there is no model " ++ scenarioModel s)) pure
    (lookup (scenarioModel s) [(machineName m, m) | m <- machines u])
  unless (machineShared machine)
    (failing (scenarioSpan s) ("model " ++ scenarioModel s ++ " is linear; a scenario runs a shared model, whose commands may run at once"))
  channels <- forM (scenarioChannels s) $ \(c, p, at) ->
    case lookup p [(protocolName q, q) | q <- protocols] of
      Nothing -> failing at ("channel " ++ c ++ " follows an unknown protocol " ++ p)
      Just q -> pure (c, protocolSteps q, at)
  forM_ channels $ \(c, _, at) -> when (length [() | (d, _, _) <- channels, d == c] > 1)
    (failing at ("channel " ++ c ++ " is declared twice"))
  joins <- concat <$> mapM (joinOf (scenarioBody s)) channels
  forest joins
  _ <- run machine [(c, steps) | (c, steps, _) <- channels] (Holding M.empty M.empty) (scenarioBody s)
  pure ()
  where
    failing :: Span -> String -> Either Failure a
    failing at message = Left (Just at, "scenario " ++ show (scenarioName s) ++ ": " ++ message)

    -- The two branches a channel joins; it must be used by exactly two
    -- branches of exactly one par.
    joinOf body (c, _, declared) = do
      let pars = collectPars body
          uses = [(i, at, n) | (i, (at, branches)) <- zip [0 :: Int ..] pars, (n, branch) <- zip [0 :: Int ..] branches
                             , c `elem` channelsIn branch]
          outer = [(i, at, n) | (i, at, n) <- uses, not (any (\(j, _, _) -> j < i && nested j i pars) uses)]
      case nub [i | (i, _, _) <- outer] of
        [] -> pure []
        [i] -> case [(at, n) | (j, at, n) <- outer, j == i] of
          [(at, a), (_, b)] -> pure [(c, at, (i, a), (i, b))]
          [(at, _)] -> failing at ("channel " ++ c ++ " is used by one process only; a channel joins two")
          ((at, _) : _) -> failing at ("channel " ++ c ++ " is used by more than two processes; a channel joins two")
          [] -> failing declared ("channel " ++ c ++ " is never used")
        _ -> failing declared ("channel " ++ c ++ " is used in more than one par; a channel joins the branches of one")
    -- Whether par j encloses par i (pars are listed outermost first).
    nested j i pars = i `elem` innerPars j pars
    innerPars j pars = case drop j pars of
      ((_, branches) : _) -> [k | (k, p) <- zip [0 :: Int ..] pars, k > j, p `elem` concatMap collectPars branches]
      [] -> []

    -- The joins between processes form a forest; a cycle could deadlock.
    forest joins = foldM add M.empty joins >> pure ()
      where
        root parents x = maybe x (root parents) (M.lookup x parents)
        add parents (c, at, a, b) = do
          let (ra, rb) = (root parents a, root parents b)
          when (ra == rb) (failing at ("channel " ++ c ++ " closes a cycle between processes, which could deadlock; " ++
            "LawSpec accepts only tree-shaped connections for now: reply on a channel that came with the request"))
          pure (M.insert ra rb parents)

    -- Runs one process's statements over what it holds.
    run machine channels = foldM (statement machine channels)
    statement machine channels holding st = case st of
      Bind x command args at -> do
        (held, result) <- call machine holding command args at
        pure held { values = M.insert x result (values held) }
      Call command args at -> fst <$> call machine holding command args at
      SendTo c value at -> case M.lookup c (ends holding) of
        Nothing -> failing at ("this process does not hold an end of channel " ++ c)
        Just (Send expected : more) -> do
          held <- give holding value expected at
          pure held { ends = M.insert c more (ends held) }
        Just (Receive expected : _) -> failing at ("channel " ++ c ++ " must receive " ++ prettyType expected ++ " here, not send" ++ sides)
        Just [] -> failing at ("channel " ++ c ++ "'s protocol has ended; nothing more may be sent")
      ReceiveFrom c x at -> case M.lookup c (ends holding) of
        Nothing -> failing at ("this process does not hold an end of channel " ++ c)
        -- Receiving a channel end (a protocol's type) delegates it here,
        -- from its start; any other value is held as a variable.
        Just (Receive t : more) -> pure $ case protocolOf t of
          Just steps -> holding { ends = M.insert x steps (M.insert c more (ends holding)) }
          Nothing -> holding { values = M.insert x t (values holding), ends = M.insert c more (ends holding) }
        Just (Send expected : _) -> failing at ("channel " ++ c ++ " must send " ++ prettyType expected ++ " here, not receive" ++ sides)
        Just [] -> failing at ("channel " ++ c ++ "'s protocol has ended; nothing more may be received")
      Par branches at -> do
        -- The first branch to use a channel follows its protocol; the
        -- second follows the dual.
        let first c = head [k | (k, b) <- zip [0 :: Int ..] branches, c `elem` channelsIn b]
            starting n branch = Holding (values holding)
              (M.fromList [(c, if first c == n then steps else dual steps) | (c, steps) <- channels, c `elem` channelsIn branch])
        finished <- mapM (\(n, branch) -> run machine channels (starting n branch) branch) (zip [0 ..] branches)
        forM_ finished $ \held -> forM_ (M.toList (ends held)) $ \(c, rest) -> case rest of
          next : _ -> failing at ("channel " ++ c ++ "'s protocol is not finished: it still expects " ++ describe next)
          [] -> pure ()
        pure holding
      Expect x _ at -> do
        unless (M.member x (values holding)) (failing at ("expect names " ++ x ++ ", which this process does not hold"))
        pure holding
    sides = " (in a par, the first branch to use a channel follows its protocol and the other branch follows the reverse)"
    describe (Send t) = "send " ++ prettyType t
    describe (Receive t) = "receive " ++ prettyType t
    -- Sending a variable or a channel end gives it up; a constant is
    -- copied. An end is delegated unused, from its protocol's start.
    give holding value expected at = case value of
      Constant _ -> pure holding
      Held x -> gives x
      Given x -> gives x
      where
        gives x | Just steps <- M.lookup x (ends holding) = case protocolOf expected of
          Just full | steps == full -> pure holding { ends = M.delete x (ends holding) }
          Just _ -> failing at ("send gives channel " ++ x ++ " after using it; LawSpec delegates a channel end only before its first step")
          Nothing -> failing at ("send gives channel " ++ x ++ ", but the protocol sends " ++ prettyType expected)
        gives x = case M.lookup x (values holding) of
          Nothing -> failing at ("send gives " ++ x ++ ", which this process does not hold")
          Just t -> do
            unless (bare t == bare expected)
              (failing at ("send gives " ++ x ++ " :: " ++ prettyType t ++ ", but the protocol sends " ++ prettyType expected))
            -- Data is copied; only channel ends are given up.
            pure holding
    call machine holding command args at = do
      c <- maybe (failing at ("there is no command " ++ command ++ " in model " ++ machineName machine)) pure
        (lookup command [(commandName c, c) | c <- machineCommands machine, not (commandRestart c)])
      ty <- maybe (failing at ("command " ++ command ++ " has no signature")) pure (lookup command (functions u))
      let (parameters, result) = split ty
          others = [p | (i, p) <- zip [0 :: Int ..] parameters, i /= commandStatePosition c]
      unless (length others == length args)
        (failing at ("command " ++ command ++ " takes " ++ show (length others) ++ " arguments here; the model's handle is passed for you"))
      held <- foldM (\h a -> case a of
        Given x | M.member x (values h) -> pure h { values = M.delete x (values h) }
        Given x -> failing at ("~" ++ x ++ " is not held by this process")
        Held x | M.member x (values h) -> pure h
        Held x -> failing at (x ++ " is not held by this process")
        Constant _ -> pure h) holding args
      pure (held, result)
    -- A protocol's type stands for a channel end following it.
    protocolOf t = case bare t of
      Named p -> lookup p [(protocolName q, protocolSteps q) | q <- protocols]
      _ -> Nothing
    split (Arrow a b) = let (as, r) = split b in (a : as, r)
    split t = ([], t)
    bare t = case t of
      Refined _ inner _ -> bare inner
      other -> other

-- Each par with its branches, outermost first.
collectPars :: [Statement] -> [(Span, [[Statement]])]
collectPars = concatMap go
  where
    go (Par branches at) = (at, branches) : concatMap collectPars branches
    go _ = []

-- The channels a list of statements uses, directly or in nested pars.
channelsIn :: [Statement] -> [String]
channelsIn = nub . concatMap go
  where
    -- Sending a channel end over c uses that channel too.
    go (SendTo c (Held x) _) = [c, x]
    go (SendTo c (Given x) _) = [c, x]
    go (SendTo c _ _) = [c]
    go (ReceiveFrom c _ _) = [c]
    go (Par branches _) = concatMap channelsIn branches
    go _ = []

-- A checked scenario as its runtime program, with constants resolved:
-- constructor names become tags qualified by their data type.
toProgram :: Unit -> Scenario -> Either Failure P.Program
toProgram u s = P.Program (scenarioName s) (scenarioModel s) [c | (c, _, _) <- scenarioChannels s] <$> mapM act (scenarioBody s)
  where
    act st = case st of
      Bind x command args at -> P.Invoke command (Just x) <$> mapM (operand at) args
      Call command args at -> P.Invoke command Nothing <$> mapM (operand at) args
      SendTo c v at -> P.Deliver c <$> operand at v
      ReceiveFrom c x _ -> pure (P.Accept c x)
      Par branches _ -> P.Fork <$> mapM (mapM act) branches
      Expect x e at -> P.Assert x <$> constant at e
    operand _ (Held x) = pure (P.Variable x)
    operand _ (Given x) = pure (P.Variable x)
    operand at (Constant e) = P.Literal <$> constant at e
    constant at e = case e of
      Located _ inner -> constant at inner
      Number n -> pure (P.IntConst n)
      Unary "-" inner | Number n <- strip inner -> pure (P.IntConst (negate n))
      StringLit t -> pure (P.TextConst t)
      BoolLit b -> pure (P.BoolConst b)
      ConstructLit n [] -> case [unitName u ++ "::type::" ++ dataTypeName d ++ "::" ++ n
                                | d <- dataTypes u, c <- dataTypeConstructors d, dataConstructorName c == n] of
        [tag] -> pure (P.TagConst tag)
        _ -> Left (Just at, "scenario " ++ show (scenarioName s) ++ ": " ++ n ++ " is not a constructor of this unit")
      _ -> Left (Just at, "scenario " ++ show (scenarioName s) ++ ": a scenario's constants are numbers, text, true, false or constructors without fields")
    strip (Located _ inner) = strip inner
    strip other = other
