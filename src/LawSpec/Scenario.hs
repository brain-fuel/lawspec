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
import Data.List (nub, nubBy)
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
  | ReceiveFrom String String (Maybe [Statement]) Span
                                          -- receive channel x [or else ...]
  | Par [[Statement]] Span                -- par ... with ... end
  | Expect String Expr Span               -- expect x = value
  deriving (Eq, Show)

data Scenario = Scenario
  { scenarioName :: String, scenarioModel :: String
  , scenarioChannels :: [(String, String, Span)]
  , scenarioBody :: [Statement], scenarioSpan :: Span
  -- mailbox m of T: any process sends, one receives.
  , scenarioMailboxes :: [(String, Type, Span)] }
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
  forM_ (scenarioMailboxes s) $ \(m, _, at) -> do
    when (length [() | (d, _, _) <- scenarioMailboxes s, d == m] > 1) (failing at ("mailbox " ++ m ++ " is declared twice"))
    when (m `elem` [c | (c, _, _) <- channels]) (failing at (m ++ " is declared as both a channel and a mailbox"))
  edges <- concat <$> mapM (mailboxEdges (located (scenarioBody s))) (scenarioMailboxes s)
  forest ([("channel " ++ c, at, a, b) | (c, at, a, b) <- joins] ++ edges)
  _ <- run machine [(c, steps) | (c, steps, _) <- channels] (Holding M.empty M.empty) (scenarioBody s)
  pure ()
  where
    failing :: Span -> String -> Either Failure a
    failing at message = Left (Just at, "scenario " ++ show (scenarioName s) ++ ": " ++ message)
    mailboxTypes = M.fromList [(m, t) | (m, t, _) <- scenarioMailboxes s]

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

    -- A mailbox has one receiving process, and every message sent to it is
    -- received. Each process that sends to it is joined to the receiver,
    -- as by a channel: sends never wait, but the receiver waits for them.
    mailboxEdges located' (m, _, declared) = do
      let uses = [(p, h, st) | (p, h, st) <- located', case st of
                    SendTo c _ _ -> c == m
                    ReceiveFrom c _ _ _ -> c == m
                    _ -> False]
          sends = [(p, at) | (p, _, SendTo _ _ at) <- uses]
          receives = [(p, at) | (p, _, ReceiveFrom _ _ _ at) <- uses]
      forM_ [st | (_, True, st) <- uses] $ \st ->
        failing (statementSpan st) ("mailbox " ++ m ++ " is used inside an or else; a mailbox's sends and receives must each happen exactly once")
      when (null uses) (failing declared ("mailbox " ++ m ++ " is never used"))
      owner <- case nub (map fst receives) of
        [p] -> pure p
        [] -> failing declared ("mailbox " ++ m ++ " is sent to but never received from")
        _ -> failing (snd (last receives)) ("mailbox " ++ m ++ " is received from by more than one process; a mailbox has one receiver")
      unless (length sends == length receives)
        (failing declared ("mailbox " ++ m ++ " is sent " ++ show (length sends) ++ " messages but receives " ++ show (length receives) ++
          "; every message sent must be received"))
      pure [("mailbox " ++ m, at, p, owner) | (p, at) <- nubBy (\a b -> fst a == fst b) sends, p /= owner]

    -- The joins between processes form a forest; a cycle could deadlock.
    forest joins = foldM add M.empty joins >> pure ()
      where
        root parents x = maybe x (root parents) (M.lookup x parents)
        add parents (c, at, a, b) = do
          let (ra, rb) = (root parents a, root parents b)
          when (ra == rb) (failing at (c ++ " closes a cycle between processes, which could deadlock; " ++
            "LawSpec accepts only tree-shaped connections for now: reply on a channel that came with the request"))
          pure (M.insert ra rb parents)

    -- Runs one process's statements over what it holds.
    run machine channels = foldM (statement machine channels)
    statement machine channels holding st = case st of
      Bind x command args at -> do
        (held, result) <- call machine holding command args at
        pure held { values = M.insert x result (values held) }
      Call command args at -> fst <$> call machine holding command args at
      SendTo c value at | Just t <- M.lookup c mailboxTypes -> give holding value t at
      SendTo c value at -> case M.lookup c (ends holding) of
        Nothing -> failing at ("this process does not hold an end of channel " ++ c)
        Just (Send expected : more) -> do
          held <- give holding value expected at
          pure held { ends = M.insert c more (ends held) }
        Just (Receive expected : _) -> failing at ("channel " ++ c ++ " must receive " ++ prettyType expected ++ " here, not send" ++ sides)
        Just [] -> failing at ("channel " ++ c ++ "'s protocol has ended; nothing more may be sent")
      ReceiveFrom c x handler _ | Just t <- M.lookup c mailboxTypes -> do
        forM_ handler $ \h -> run machine channels holding h
        pure $ case protocolOf t of
          Just steps -> holding { ends = M.insert x steps (ends holding) }
          Nothing -> holding { values = M.insert x t (values holding) }
      ReceiveFrom c x handler at -> case M.lookup c (ends holding) of
        Nothing -> failing at ("this process does not hold an end of channel " ++ c)
        -- When c's other process has failed, the handler runs instead of
        -- the rest of this process, without c; ends it still holds after
        -- are given up, so their other processes' receives fail too.
        Just steps@(Receive _ : _) | Just h <- handler -> do
          when (x `elem` concatMap mentioned h)
            (failing at ("the or else of receive " ++ c ++ " " ++ x ++ " runs when nothing was received, so it cannot use " ++ x))
          _ <- run machine channels holding { ends = M.delete c (ends holding) } h
          statement machine channels holding (ReceiveFrom c x Nothing at) <* pure steps
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
      let (parameters, full) = split ty
          -- An actor's handler returns its reply with the next state.
          result
            | machineActor machine = case bare full of
                Application "Pair" [r, _] -> r
                _ -> Named "Unit"
            | otherwise = full
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
    go (ReceiveFrom _ _ (Just handler) _) = collectPars handler
    go _ = []

-- The channels a list of statements uses, directly or in nested pars.
channelsIn :: [Statement] -> [String]
channelsIn = nub . concatMap go
  where
    -- Sending a channel end over c uses that channel too.
    go (SendTo c (Held x) _) = [c, x]
    go (SendTo c (Given x) _) = [c, x]
    go (SendTo c _ _) = [c]
    go (ReceiveFrom c _ handler _) = c : maybe [] channelsIn handler
    go (Par branches _) = concatMap channelsIn branches
    go _ = []

-- A checked scenario as its runtime program, with constants resolved:
-- constructor names become tags qualified by their data type.
toProgram :: Unit -> Scenario -> Either Failure P.Program
toProgram u s = (\acts -> P.Program (scenarioName s) (scenarioModel s) [c | (c, _, _) <- scenarioChannels s] acts
    [p | (_, p, _) <- scenarioChannels s] "" [(m, prettyType t) | (m, t, _) <- scenarioMailboxes s]) <$> mapM act (scenarioBody s)
  where
    act st = case st of
      Bind x command args at -> P.Invoke command (Just x) <$> mapM (operand at) args
      Call command args at -> P.Invoke command Nothing <$> mapM (operand at) args
      SendTo c v at -> P.Deliver c <$> operand at v
      ReceiveFrom c x handler _ -> P.Accept c x <$> traverse (mapM act) handler
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

-- The variables a list of statements uses.
mentioned :: Statement -> [String]
mentioned st = case st of
  Bind _ _ args _ -> concatMap argument args
  Call _ args _ -> concatMap argument args
  SendTo _ v _ -> argument v
  ReceiveFrom _ _ handler _ -> maybe [] (concatMap mentioned) handler
  Par branches _ -> concatMap (concatMap mentioned) branches
  Expect x _ _ -> [x]
  where
    argument a = case a of
      Held x -> [x]
      Given x -> [x]
      Constant _ -> []

-- Every statement with the process that runs it, and whether it is inside
-- an or else: (-1, 0) is the scenario's own process, and (i, n) is branch n
-- of the i-th par, numbered as collectPars lists them.
located :: [Statement] -> [((Int, Int), Bool, Statement)]
located body = fst (go (-1, 0) False body 0)
  where
    go p h sts k = foldl (\(acc, k') st -> let (more, k'') = one p h st k' in (acc ++ more, k'')) ([], k) sts
    one p h st k = case st of
      Par branches _ ->
        let (inner, k') = foldl (\(acc, kk) (n, b) -> let (more, kk') = go (k, n) h b kk in (acc ++ more, kk')) ([], k + 1) (zip [0 ..] branches)
        in ((p, h, st) : inner, k')
      ReceiveFrom _ _ (Just handler) _ -> let (inner, k') = go p True handler k in ((p, h, st) : inner, k')
      _ -> ([(p, h, st)], k)

statementSpan :: Statement -> Span
statementSpan st = case st of
  Bind _ _ _ at -> at
  Call _ _ at -> at
  SendTo _ _ at -> at
  ReceiveFrom _ _ _ at -> at
  Par _ at -> at
  Expect _ _ at -> at
