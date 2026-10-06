{-# LANGUAGE DeriveGeneric #-}
-- | A checked scenario, as the scenario runtimes run it: its processes'
-- acts over a shared model's commands and the scenario's channels.
-- Constants are resolved to plain values (constructor tags qualified).
module LawSpec.Core.Program
  ( Program(..), Act(..), Operand(..), Constant(..), programSpec
  ) where

import GHC.Generics (Generic)

-- | A scenario compiled to a flat program the runtimes interpret, so the
-- scenario semantics are written once and read by every target.
-- ref:DEC-sessions-by-construction
data Program = Program
  { programTitle :: String, programMachine :: String
  , programChannels :: [String], programActs :: [Act]
  -- The protocol each channel follows, in the order of programChannels.
  , programProtocols :: [String]
  -- Each channel's step types as descriptors, for runs whose channels
  -- cross a network: filled in when the program is emitted.
  , programWire :: String
  -- Each mailbox, with its message type as written.
  , programMailboxes :: [(String, String)]
  -- Whether its channels close a cycle between processes (accepted because
  -- no process can wait for another in a cycle) rather than form a tree.
  , programCyclic :: Bool
  } deriving (Eq, Show, Generic)

-- | The few steps a scenario process can take; each runtime implements exactly
-- these.
data Act
  = Invoke String (Maybe String) [Operand]   -- command, the variable bound
  | Deliver String Operand                   -- send on a channel
  | Accept String String (Maybe [Act])       -- receive from a channel into a variable;
                                             -- or else these acts, when its other process failed
  | Fork [[Act]]                             -- par: processes at once
  | Assert String Constant                   -- expect variable = constant
  deriving (Eq, Show, Generic)

-- | An argument is a bound variable or a literal; nothing needs evaluating.
data Operand = Variable String | Literal Constant
  deriving (Eq, Show, Generic)

-- | Literals the runtimes can read without a type system.
data Constant = IntConst Integer | TextConst String | BoolConst Bool | TagConst String
  deriving (Eq, Show, Generic)

-- | The program as an s-expression for the runtimes' read_descriptor. Command
-- names index the machine's commands by name.
programSpec :: Program -> String
programSpec p = unwords
  [ "(scenario " ++ quote (programTitle p) ++ " " ++ programMachine p ++ ")"
  , "(channels" ++ concatMap (' ' :) (programChannels p) ++ ")"
  , "(mailboxes" ++ concatMap ((' ' :) . fst) (programMailboxes p) ++ ")"
  , "(process" ++ concatMap ((' ' :) . act) (programActs p) ++ ")" ] ++
  (if null (programWire p) then "" else " " ++ programWire p)
  where
    act a = case a of
      Invoke command bound operands -> "(call " ++ command ++ " " ++ maybe "_" id bound ++ concatMap ((' ' :) . operand) operands ++ ")"
      Deliver c o -> "(send " ++ c ++ " " ++ operand o ++ ")"
      Accept c x Nothing -> "(receive " ++ c ++ " " ++ x ++ ")"
      Accept c x (Just handler) -> "(receiveor " ++ c ++ " " ++ x ++ " (process" ++ concatMap ((' ' :) . act) handler ++ "))"
      Fork branches -> "(par " ++ unwords ["(process" ++ concatMap ((' ' :) . act) b ++ ")" | b <- branches] ++ ")"
      Assert x c -> "(expect " ++ x ++ " " ++ constant c ++ ")"
    operand (Variable x) = "(var " ++ x ++ ")"
    operand (Literal c) = constant c
    constant c = case c of
      IntConst n -> "(int " ++ show n ++ ")"
      TextConst s -> "(text " ++ quote s ++ ")"
      BoolConst b -> "(bool " ++ (if b then "true" else "false") ++ ")"
      TagConst t -> "(tag " ++ t ++ ")"
    quote s = "\"" ++ concatMap escape s ++ "\""
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape ch = [ch]
