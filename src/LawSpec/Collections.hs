-- Portable collections: Set, KeyVal, Queue, Stack and Deque, with Entry and
-- Ordering. They are ordinary data of a built-in unit, lawspec.collections,
-- whose operations are checked LawSpec definitions over each collection's
-- items: a Set's are sorted and distinct, a KeyVal's entries are sorted by
-- distinct keys, a Queue's and a Deque's run front to back, and a Stack's top
-- to bottom. The order is prelude.compare's portable total order.
--
-- The unit is added only to programs that use a collection, with only the
-- types they need: a type a program declares itself shadows the built-in one,
-- along with its operations.
module LawSpec.Collections
  ( collectionsUnit, collectionsAlias, collectionTypes, collectionsSource
  , usedCollections, collectionOperation, collectionOperations
  , internalConstructor, isCollectionsType, collectionContainer, entryTypeName
  ) where

import Data.Char (isAlphaNum)
import Data.List (isInfixOf, isPrefixOf, nub)

collectionsUnit :: String
collectionsUnit = "lawspec.collections"

-- The implicit import's alias; prelude.<op> resolves through it.
collectionsAlias :: String
collectionsAlias = "lawspecCollections"

collectionTypes :: [String]
collectionTypes = ["Set", "KeyVal", "Queue", "Stack", "Deque", "Entry", "Ordering", "Pair"]

isCollectionsType :: String -> Bool
isCollectionsType name = (collectionsUnit ++ "::type::") `isPrefixOf` name

-- A built-in container's short name, from its Core type name.
collectionContainer :: String -> Maybe String
collectionContainer name = case stripPrefix' (collectionsUnit ++ "::type::") name of
  Just short | short `elem` ["Set", "KeyVal", "Queue", "Stack", "Deque"] -> Just short
  _ -> Nothing
  where stripPrefix' prefix t = if prefix `isPrefixOf` t then Just (drop (length prefix) t) else Nothing

entryTypeName :: String
entryTypeName = collectionsUnit ++ "::type::Entry"

-- A container's single, internal constructor, which source cannot name.
internalConstructor :: String -> Maybe String
internalConstructor name = lookup name
  [("Set", "SetItems"), ("KeyVal", "KeyValEntries"), ("Queue", "QueueItems"), ("Stack", "StackItems"), ("Deque", "DequeItems")]

-- prelude.<op>: the definition implementing it and the type it belongs to.
collectionOperations :: [(String, (String, String))]
collectionOperations =
  [ (op, (definition, owner))
  | (owner, pairs) <-
      [ ("Set", [("setOf", "setOf"), ("member", "setMember"), ("insert", "setInsert"), ("remove", "setRemove"),
                 ("union", "setUnion"), ("intersection", "setIntersection"), ("difference", "setDifference")])
      , ("KeyVal", [("keyValOf", "keyValOf"), ("lookup", "keyValLookup"), ("put", "keyValPut"), ("delete", "keyValDelete"),
                    ("keys", "keyValKeys"), ("values", "keyValValues"), ("entries", "keyValEntries")])
      , ("Stack", [("stackOf", "stackOf"), ("push", "stackPush"), ("pop", "stackPop"), ("peek", "stackPeek")])
      , ("Queue", [("queueOf", "queueOf"), ("enqueue", "queueEnqueue"), ("dequeue", "queueDequeue"), ("front", "queueFront")])
      , ("Deque", [("dequeOf", "dequeOf"), ("pushFront", "dequePushFront"), ("pushBack", "dequePushBack"),
                   ("popFront", "dequePopFront"), ("popBack", "dequePopBack"), ("peekFront", "dequePeekFront"),
                   ("peekBack", "dequePeekBack")]) ]
  , (op, definition) <- pairs ]

collectionOperation :: String -> Maybe (String, String)
collectionOperation op = lookup op collectionOperations

-- The collection types a program's sources use and do not themselves declare:
-- a type name or a prelude operation of one. A source's own type shadows the
-- built-in only in that source. Entry and Ordering come with KeyVal and Set,
-- which need them.
usedCollections :: [String] -> [String]
usedCollections sources =
  let wanted = nub (concatMap used sources)
      closure = nub (wanted ++ ["Ordering" | any (`elem` wanted) ["Set", "KeyVal"]] ++ ["Entry" | "KeyVal" `elem` wanted])
  in [t | t <- collectionTypes, t `elem` closure]
  where
    used text =
      let tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') (stripComments text))
          declared = [name | (keyword, name) <- zip tokens (drop 1 tokens), keyword `elem` ["type", "wrapper"]]
          named = [t | t <- collectionTypes, t `elem` tokens]
          operated = [owner | t <- tokens, Just op <- [stripPrefix' "prelude." t], Just (_, owner) <- [collectionOperation op]] ++
            ["Ordering" | "prelude.compare" `elem` tokens] ++
            -- The railway combinator both (<*>) pairs two results.
            ["Pair" | "prelude.both" `elem` tokens || "<*>" `isInfixOf` stripComments text]
      in [t | t <- named ++ operated, t `notElem` declared]
    stripPrefix' prefix t = if prefix `isPrefixOf` t then Just (drop (length prefix) t) else Nothing
    stripComments = unlines . map (\line -> takeComment line) . lines
    takeComment ('-' : '-' : _) = ""
    takeComment (c : rest) = c : takeComment rest
    takeComment [] = []

-- The unit's source, with the given types and the operations over them.
collectionsSource :: [String] -> String
collectionsSource types = unlines $
  ["unit " ++ collectionsUnit, ""] ++
  concat [block | (t, block) <- declarations, t `elem` types] ++
  (if any (`elem` types) ["Set", "Queue", "Stack", "Deque"] then listHelpers else []) ++
  concat [block | (t, block) <- operations, t `elem` types]
  where
    declarations =
      [ ("Ordering", ["type Ordering is", "  | Less", "  | Equal", "  | Greater", "end", ""])
      , ("Entry", ["type Entry (k :: Type) (v :: Type) is Entry key :: k value :: v end", ""])
      , ("Pair", ["type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end", ""])
      , ("Set", ["type Set (a :: Type) is SetItems items :: List a end", ""])
      , ("KeyVal", ["type KeyVal (k :: Type) (v :: Type) is KeyValEntries entries :: List (Entry k v) end", ""])
      , ("Queue", ["type Queue (a :: Type) is QueueItems items :: List a end", ""])
      , ("Stack", ["type Stack (a :: Type) is StackItems items :: List a end", ""])
      , ("Deque", ["type Deque (a :: Type) is DequeItems items :: List a end", ""]) ]
    listHelpers =
      [ "definition collectionAppend (xs :: List a) (ys :: List a) :: List a is"
      , "  match xs with"
      , "  | Nil -> ys"
      , "  | Cons h t -> Cons h (collectionAppend t ys)"
      , "  end"
      , "end"
      , ""
      , "definition collectionTail (xs :: List a) :: List a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> t"
      , "  end"
      , "end"
      , ""
      , "definition collectionHead (xs :: List a) :: Maybe a is"
      , "  match xs with"
      , "  | Nil -> Nothing"
      , "  | Cons h t -> Just h"
      , "  end"
      , "end"
      , ""
      , "definition collectionLast (xs :: List a) :: Maybe a is"
      , "  match xs with"
      , "  | Nil -> Nothing"
      , "  | Cons h t -> match t with"
      , "    | Nil -> Just h"
      , "    | Cons second rest -> collectionLast t"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition collectionInit (xs :: List a) :: List a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> match t with"
      , "    | Nil -> t"
      , "    | Cons second rest -> Cons h (collectionInit t)"
      , "    end"
      , "  end"
      , "end"
      , "" ]
    operations =
      [ ("Set", setOperations), ("KeyVal", keyValOperations), ("Stack", stackOperations)
      , ("Queue", queueOperations), ("Deque", dequeOperations) ]
    setOperations =
      [ "definition setInsertItems (x :: a) (xs :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> [x]"
      , "  | Cons h t -> match prelude.compare x h with"
      , "    | Less -> Cons x xs"
      , "    | Equal -> xs"
      , "    | Greater -> Cons h (setInsertItems x t)"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition setRemoveItems (x :: a) (xs :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> match prelude.compare x h with"
      , "    | Less -> xs"
      , "    | Equal -> t"
      , "    | Greater -> Cons h (setRemoveItems x t)"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition setMemberItems (x :: a) (xs :: List a) :: Bool requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> false"
      , "  | Cons h t -> match prelude.compare x h with"
      , "    | Less -> false"
      , "    | Equal -> true"
      , "    | Greater -> setMemberItems x t"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "-- [x] when x is among xs, otherwise empty; and the converse."
      , "definition setFoundItems (x :: a) (xs :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> match prelude.compare x h with"
      , "    | Less -> Nil"
      , "    | Equal -> [x]"
      , "    | Greater -> setFoundItems x t"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition setMissingItems (x :: a) (xs :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> [x]"
      , "  | Cons h t -> match prelude.compare x h with"
      , "    | Less -> [x]"
      , "    | Equal -> Nil"
      , "    | Greater -> setMissingItems x t"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition setFromItems (xs :: List a) (acc :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> acc"
      , "  | Cons h t -> setFromItems t (setInsertItems h acc)"
      , "  end"
      , "end"
      , ""
      , "definition setIntersectionItems (xs :: List a) (ys :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> collectionAppend (setFoundItems h ys) (setIntersectionItems t ys)"
      , "  end"
      , "end"
      , ""
      , "definition setDifferenceItems (xs :: List a) (ys :: List a) :: List a requires Keyed a is"
      , "  match xs with"
      , "  | Nil -> xs"
      , "  | Cons h t -> collectionAppend (setMissingItems h ys) (setDifferenceItems t ys)"
      , "  end"
      , "end"
      , ""
      , "definition setOf (xs :: List a) :: Set a requires Keyed a is SetItems (setFromItems xs Nil) end"
      , ""
      , "definition setMember (x :: a) (s :: Set a) :: Bool requires Keyed a is"
      , "  match s with | SetItems xs -> setMemberItems x xs end"
      , "end"
      , ""
      , "definition setInsert (x :: a) (s :: Set a) :: Set a requires Keyed a is"
      , "  match s with | SetItems xs -> SetItems (setInsertItems x xs) end"
      , "end"
      , ""
      , "definition setRemove (x :: a) (s :: Set a) :: Set a requires Keyed a is"
      , "  match s with | SetItems xs -> SetItems (setRemoveItems x xs) end"
      , "end"
      , ""
      , "definition setUnion (s :: Set a) (t :: Set a) :: Set a requires Keyed a is"
      , "  match s with | SetItems xs -> match t with | SetItems ys -> SetItems (setFromItems xs ys) end end"
      , "end"
      , ""
      , "definition setIntersection (s :: Set a) (t :: Set a) :: Set a requires Keyed a is"
      , "  match s with | SetItems xs -> match t with | SetItems ys -> SetItems (setIntersectionItems xs ys) end end"
      , "end"
      , ""
      , "definition setDifference (s :: Set a) (t :: Set a) :: Set a requires Keyed a is"
      , "  match s with | SetItems xs -> match t with | SetItems ys -> SetItems (setDifferenceItems xs ys) end end"
      , "end"
      , "" ]
    keyValOperations =
      [ "definition keyValPutItems (k :: a) (v :: b) (es :: List (Entry a b)) :: List (Entry a b) requires Keyed a is"
      , "  match es with"
      , "  | Nil -> [Entry k v]"
      , "  | Cons e t -> match e with"
      , "    | Entry key value -> match prelude.compare k key with"
      , "      | Less -> Cons (Entry k v) es"
      , "      | Equal -> Cons (Entry k v) t"
      , "      | Greater -> Cons e (keyValPutItems k v t)"
      , "      end"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition keyValDeleteItems (k :: a) (es :: List (Entry a b)) :: List (Entry a b) requires Keyed a is"
      , "  match es with"
      , "  | Nil -> es"
      , "  | Cons e t -> match e with"
      , "    | Entry key value -> match prelude.compare k key with"
      , "      | Less -> es"
      , "      | Equal -> t"
      , "      | Greater -> Cons e (keyValDeleteItems k t)"
      , "      end"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition keyValLookupItems (k :: a) (es :: List (Entry a b)) :: Maybe b requires Keyed a is"
      , "  match es with"
      , "  | Nil -> Nothing"
      , "  | Cons e t -> match e with"
      , "    | Entry key value -> match prelude.compare k key with"
      , "      | Less -> Nothing"
      , "      | Equal -> Just value"
      , "      | Greater -> keyValLookupItems k t"
      , "      end"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition keyValFromItems (es :: List (Entry a b)) (acc :: List (Entry a b)) :: List (Entry a b) requires Keyed a is"
      , "  match es with"
      , "  | Nil -> acc"
      , "  | Cons e t -> match e with"
      , "    | Entry key value -> keyValFromItems t (keyValPutItems key value acc)"
      , "    end"
      , "  end"
      , "end"
      , ""
      , "definition keyValKeysItems (es :: List (Entry a b)) :: List a is"
      , "  match es with"
      , "  | Nil -> Nil"
      , "  | Cons e t -> match e with | Entry key value -> Cons key (keyValKeysItems t) end"
      , "  end"
      , "end"
      , ""
      , "definition keyValValuesItems (es :: List (Entry a b)) :: List b is"
      , "  match es with"
      , "  | Nil -> Nil"
      , "  | Cons e t -> match e with | Entry key value -> Cons value (keyValValuesItems t) end"
      , "  end"
      , "end"
      , ""
      , "definition keyValOf (es :: List (Entry a b)) :: KeyVal a b requires Keyed a is"
      , "  KeyValEntries (keyValFromItems es Nil)"
      , "end"
      , ""
      , "definition keyValLookup (k :: a) (m :: KeyVal a b) :: Maybe b requires Keyed a is"
      , "  match m with | KeyValEntries es -> keyValLookupItems k es end"
      , "end"
      , ""
      , "definition keyValPut (k :: a) (v :: b) (m :: KeyVal a b) :: KeyVal a b requires Keyed a is"
      , "  match m with | KeyValEntries es -> KeyValEntries (keyValPutItems k v es) end"
      , "end"
      , ""
      , "definition keyValDelete (k :: a) (m :: KeyVal a b) :: KeyVal a b requires Keyed a is"
      , "  match m with | KeyValEntries es -> KeyValEntries (keyValDeleteItems k es) end"
      , "end"
      , ""
      , "definition keyValKeys (m :: KeyVal a b) :: List a is"
      , "  match m with | KeyValEntries es -> keyValKeysItems es end"
      , "end"
      , ""
      , "definition keyValValues (m :: KeyVal a b) :: List b is"
      , "  match m with | KeyValEntries es -> keyValValuesItems es end"
      , "end"
      , ""
      , "definition keyValEntries (m :: KeyVal a b) :: List (Entry a b) is"
      , "  match m with | KeyValEntries es -> es end"
      , "end"
      , "" ]
    stackOperations =
      [ "definition stackOf (xs :: List a) :: Stack a is StackItems xs end"
      , ""
      , "definition stackPush (x :: a) (s :: Stack a) :: Stack a is"
      , "  match s with | StackItems xs -> StackItems (Cons x xs) end"
      , "end"
      , ""
      , "definition stackPop (s :: Stack a) :: Stack a is"
      , "  match s with | StackItems xs -> StackItems (collectionTail xs) end"
      , "end"
      , ""
      , "definition stackPeek (s :: Stack a) :: Maybe a is"
      , "  match s with | StackItems xs -> collectionHead xs end"
      , "end"
      , "" ]
    queueOperations =
      [ "definition queueOf (xs :: List a) :: Queue a is QueueItems xs end"
      , ""
      , "definition queueEnqueue (x :: a) (q :: Queue a) :: Queue a is"
      , "  match q with | QueueItems xs -> QueueItems (collectionAppend xs [x]) end"
      , "end"
      , ""
      , "definition queueDequeue (q :: Queue a) :: Queue a is"
      , "  match q with | QueueItems xs -> QueueItems (collectionTail xs) end"
      , "end"
      , ""
      , "definition queueFront (q :: Queue a) :: Maybe a is"
      , "  match q with | QueueItems xs -> collectionHead xs end"
      , "end"
      , "" ]
    dequeOperations =
      [ "definition dequeOf (xs :: List a) :: Deque a is DequeItems xs end"
      , ""
      , "definition dequePushFront (x :: a) (d :: Deque a) :: Deque a is"
      , "  match d with | DequeItems xs -> DequeItems (Cons x xs) end"
      , "end"
      , ""
      , "definition dequePushBack (x :: a) (d :: Deque a) :: Deque a is"
      , "  match d with | DequeItems xs -> DequeItems (collectionAppend xs [x]) end"
      , "end"
      , ""
      , "definition dequePopFront (d :: Deque a) :: Deque a is"
      , "  match d with | DequeItems xs -> DequeItems (collectionTail xs) end"
      , "end"
      , ""
      , "definition dequePopBack (d :: Deque a) :: Deque a is"
      , "  match d with | DequeItems xs -> DequeItems (collectionInit xs) end"
      , "end"
      , ""
      , "definition dequePeekFront (d :: Deque a) :: Maybe a is"
      , "  match d with | DequeItems xs -> collectionHead xs end"
      , "end"
      , ""
      , "definition dequePeekBack (d :: Deque a) :: Maybe a is"
      , "  match d with | DequeItems xs -> collectionLast xs end"
      , "end"
      , "" ]
