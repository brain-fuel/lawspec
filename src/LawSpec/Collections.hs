-- | Portable collections: Set, KeyVal, Queue, Stack and Deque, with Entry and
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
  ( collectionsUnit, collectionsAlias, collectionTypes, collectionsSource, collectionSourceOwner, collectionSharedTypes
  , usedCollections, usedCollectionsCanonical, collectionOperation, canonicalCollectionOperation, collectionOperations, canonicalCollectionOperations
  , canonicalCollectionTypes, canonicalCollectionValues, canonicalCollectionNames
  , boundedArithmeticBlock, boundedArithmeticTypes, boundedArithmeticDefinition, boundedArithmeticDefinitions
  , internalConstructor, isCollectionsType, collectionContainer, entryTypeName
  ) where

import Data.Char (isAlphaNum)
import Data.List (isInfixOf, isPrefixOf, nub)

-- | Collections are an ordinary LawSpec unit, so their laws are checked like any
-- other and each target needs no special support.
-- ref:DEC-portable-total-order-collections
collectionsUnit :: String
collectionsUnit = "lawspec.collections"

-- | The implicit import's alias; prelude.<op> resolves through it.
collectionsAlias :: String
collectionsAlias = "lawspecCollections"

-- | The names a program may use without importing the collections unit.
collectionTypes :: [String]
collectionTypes = ["Set", "KeyVal", "Queue", "Stack", "Deque", "Entry", "Ordering", "Pair", "SizedStack", "SizedQueue"]

-- | Emitters map these types onto each target's own containers.
isCollectionsType :: String -> Bool
isCollectionsType name = (collectionsUnit ++ "::type::") `isPrefixOf` name

-- | A built-in container's short name, from its Core type name.
collectionContainer :: String -> Maybe String
collectionContainer name = case stripPrefix' (collectionsUnit ++ "::type::") name of
  Just short | short `elem` ["Set", "KeyVal", "Queue", "Stack", "Deque"] -> Just short
  _ -> Nothing
  where stripPrefix' prefix t = if prefix `isPrefixOf` t then Just (drop (length prefix) t) else Nothing

-- | Key-value entries are named in generated code and runtimes alike.
entryTypeName :: String
entryTypeName = collectionsUnit ++ "::type::Entry"

-- | A container's single, internal constructor, which source cannot name.
internalConstructor :: String -> Maybe String
internalConstructor name = lookup name
  [("Set", "SetItems"), ("EqSet", "EqSetItems"), ("KeyVal", "KeyValEntries"), ("Queue", "QueueItems"), ("Stack", "StackItems"), ("Deque", "DequeItems")]

-- Canonical names select existing resolved identities; provider definitions
-- continue to use their own versioned names and capabilities.
canonicalCollectionTypes :: [(String,String)]
canonicalCollectionTypes = [("Set","EqSet"),("SortedSet","Set")]

canonicalCollectionValues :: [(String,String)]
canonicalCollectionValues =
  [(public,internal) | (public,internal) <- setNames] ++
  [("sortedS" ++ drop 1 public,public) | (public,_) <- setNames]
  where setNames = [("setOf","eqSetOf"),("setMember","eqSetMember"),("setInsert","eqSetInsert"),
          ("setRemove","eqSetRemove"),("setUnion","eqSetUnion"),
          ("setIntersection","eqSetIntersection"),("setDifference","eqSetDifference")]

canonicalCollectionNames :: [String] -> [String]
canonicalCollectionNames = map (\name -> case name of "EqSet" -> "Set"; "Set" -> "SortedSet"; _ -> name)

canonicalCollectionOperation :: String -> Maybe (String,String)
canonicalCollectionOperation op = lookup op canonicalCollectionOperations

canonicalCollectionOperations :: [(String,(String,String))]
canonicalCollectionOperations = [(op,(name,"SortedSet")) | (op,name) <- sorted] ++ collectionOperations
  where sorted = [("sortedSetOf","sortedSetOf"),("sortedSetMember","sortedSetMember"),
          ("sortedSetInsert","sortedSetInsert"),("sortedSetRemove","sortedSetRemove"),
          ("sortedSetUnion","sortedSetUnion"),("sortedSetIntersection","sortedSetIntersection"),
          ("sortedSetDifference","sortedSetDifference")]

-- | prelude.<op>: the definition implementing it and the type it belongs to.
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
                   ("peekBack", "dequePeekBack")])
      , ("SizedStack", [("sizedPush", "sizedStackPush"), ("sizedPop", "sizedStackPop"), ("sizedTop", "sizedStackTop"),
                        ("sizedStackItems", "sizedStackItems")])
      , ("SizedQueue", [("sizedEnqueue", "sizedQueueEnqueue"), ("sizedDequeue", "sizedQueueDequeue"),
                        ("sizedFront", "sizedQueueFront"), ("sizedQueueItems", "sizedQueueItems")]) ]
  , (op, definition) <- pairs ]

-- | prelude.<op> on a collection resolves to the collections unit's definition.
collectionOperation :: String -> Maybe (String, String)
collectionOperation op = lookup op collectionOperations

-- User sources and versioned built-ins have different meanings for Set.
-- Both representations retain separate, stable nominal identities.
usedCollectionsCanonical :: [String] -> [String] -> [String]
usedCollectionsCanonical users versioned =
  let user = usedCollections users
      legacy = usedCollections versioned
      wordsOf = words . map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ')
      explicit = any (\text -> "import lawspec.collections" `isInfixOf` text) users
      setOps = ["prelude." ++ op | (op,(_,owner)) <- collectionOperations, owner == "Set"]
      eqSet = "Set" `elem` user || explicit || any ("#S" `isInfixOf`) users ||
        any (\text -> any (`elem` wordsOf text) setOps) users
      sorted = explicit || any (\text -> "SortedSet" `elem` wordsOf text ||
        any (\token -> case stripPrefix "prelude." token >>= canonicalCollectionOperation of
          Just (_,"SortedSet") -> True; _ -> False) (wordsOf text)) users
      wanted = filter (/= "Set") user ++ legacy ++ ["Set" | eqSet || sorted] ++ ["EqSet" | eqSet]
      closed = wanted ++ ["Ordering" | "Set" `elem` wanted]
  in [name | name <- collectionTypes ++ ["EqSet",boundedArithmeticBlock], name `elem` closed]
  where stripPrefix prefix text = if prefix `isPrefixOf` text then Just (drop (length prefix) text) else Nothing

-- | The collection types a program's sources use and do not themselves declare:
-- a type name or a prelude operation of one. A source's own type shadows the
-- built-in only in that source. Entry and Ordering come with KeyVal and Set,
-- which need them.
usedCollections :: [String] -> [String]
usedCollections sources =
  let wanted = nub (concatMap used sources)
      closure = nub (wanted ++ ["Ordering" | any (`elem` wanted) ["Set", "KeyVal"]] ++ ["Entry" | "KeyVal" `elem` wanted])
  in [t | t <- collectionTypes, t `elem` closure] ++ [boundedArithmeticBlock | boundedArithmeticBlock `elem` closure]
  where
    used text =
      let tokens = words (map (\c -> if isAlphaNum c || c `elem` ("._" :: String) then c else ' ') (stripComments text))
          declared = [name | (previous,keyword,name) <- zip3 ("":tokens) tokens (drop 1 tokens),
            keyword `elem` ["type", "wrapper"], previous /= "of"]
          named = [t | t <- collectionTypes, t `elem` tokens]
          operated = [owner | t <- tokens, Just op <- [stripPrefix' "prelude." t], Just (_, owner) <- [collectionOperation op]] ++
            ["Ordering" | "prelude.compare" `elem` tokens] ++
            -- The railway combinator both (<*>) pairs two results.
            ["Pair" | "prelude.both" `elem` tokens || "<*>" `isInfixOf` stripComments text] ++
            -- A model that behaves like a collection gets references over pairs.
            ["Pair" | "behaves" `elem` tokens] ++
            -- A handler with state gives Pair result state from each clause.
            ["Pair" | "handler" `elem` tokens && "state" `elem` tokens] ++
            [boundedArithmeticBlock | any (`elem` tokens) ["prelude.wrapping", "prelude.saturating", "prelude.bounded"]]
      in [t | t <- named ++ operated, t `notElem` declared]
    stripPrefix' prefix t = if prefix `isPrefixOf` t then Just (drop (length prefix) t) else Nothing
    stripComments = unlines . map (\line -> takeComment line) . lines
    takeComment ('-' : '-' : _) = ""
    takeComment (c : rest) = c : takeComment rest
    takeComment [] = []

collectionSharedTypes :: [String]
collectionSharedTypes = ["Set","EqSet","Queue","Stack","Deque"]

-- | The unit's source, with the given types and the operations over them.
collectionsSource :: [String] -> String
collectionsSource = unlines . concatMap snd . collectionSourceParts

-- The generated provider records its own block boundaries. Import resolution
-- preserves definition spans, so discovery need not guess ownership from names.
-- The empty owner denotes the list helpers shared by several containers.
collectionSourceOwner :: [String] -> Int -> Maybe String
collectionSourceOwner types row = lookup row
  (zip [1..] (concat [replicate (length block) owner | (owner,block)<-collectionSourceParts types])) >>= id

collectionSourceParts :: [String] -> [(Maybe String,[String])]
collectionSourceParts types =
  [(Nothing,["unit " ++ collectionsUnit, ""])] ++
  [(Just t,block) | (t,block)<-declarations,t `elem` types] ++
  [(Just "",listHelpers) | any (`elem` types) collectionSharedTypes] ++
  [(Just t,block) | (t,block)<-operations,t `elem` types] ++
  [(Just boundedArithmeticBlock,boundedArithmeticSource) | boundedArithmeticBlock `elem` types] ++
  [(Nothing,["end unit"])]
  where
    declarations =
      [ ("Ordering", [ "type Ordering is one of"
                     , "  | Less"
                     , "  | Equal"
                     , "  | Greater"
                     , "end type"
                     , ""
                     , "" ])
      , ("Entry", [ "type Entry (k :: Type) (v :: Type) is a record{  key :: k value :: v} end type"
                  , ""
                  , "" ])
      , ("Pair", [ "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type"
                 , ""
                 , "" ])
      , ("Set", [ "type Set (a :: Type) is one of SetItems  of type List a end type"
                , ""
                , "" ])
      -- Internal representation; canonical exports are introduced separately.
      , ("EqSet", [ "type EqSet (a :: Type) is one of EqSetItems  of type List a end type"
                  , ""
                  , "" ])
      , ("KeyVal", [ "type KeyVal (k :: Type) (v :: Type) is one of KeyValEntries  of type List (Entry k v) end type"
                   , ""
                   , "" ])
      , ("Queue", [ "type Queue (a :: Type) is one of QueueItems  of type List a end type"
                  , ""
                  , "" ])
      , ("Stack", [ "type Stack (a :: Type) is one of StackItems  of type List a end type"
                  , ""
                  , "" ])
      , ("Deque", [ "type Deque (a :: Type) is one of DequeItems  of type List a end type"
                  , ""
                  , "" ])
      -- Size-indexed: a pop or a front needs a non-empty one, by its type.
      , ("SizedStack",
          [ "type SizedStack (n :: Whole) (a :: Type) is one of"
          , "  | SizedStackEmpty where n = 0"
          , "  | SizedStackPush of type record{ top :: a rest :: SizedStack m a} where n = m + 1"
          , "end type"
          , ""
          , "" ])
      , ("SizedQueue",
          [ "type SizedQueue (n :: Whole) (a :: Type) is one of"
          , "  | SizedQueueEmpty where n = 0"
          , "  | SizedQueueFront of type record{ front :: a rest :: SizedQueue m a} where n = m + 1"
          , "end type"
          , ""
          , "" ]) ]
    listHelpers =
      [ "function collectionAppend (xs :: List a) (ys :: List a) -> List a is"
      , "  first matching case of xs :"
      , "  when Nil then ys"
      , "  when Cons h t then Cons h (collectionAppend t ys)"
      , "  end case"
      , "end function"
      , ""
      , "function collectionTail (xs :: List a) -> List a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then t"
      , "  end case"
      , "end function"
      , ""
      , "function collectionHead (xs :: List a) -> Maybe a is"
      , "  first matching case of xs :"
      , "  when Nil then Absent"
      , "  when Cons h t then Present h"
      , "  end case"
      , "end function"
      , ""
      , "function collectionLast (xs :: List a) -> Maybe a is"
      , "  first matching case of xs :"
      , "  when Nil then Absent"
      , "  when Cons h t then first matching case of t :"
      , "    when Nil then Present h"
      , "    when Cons second rest then collectionLast t"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function collectionInit (xs :: List a) -> List a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then first matching case of t :"
      , "    when Nil then t"
      , "    when Cons second rest then Cons h (collectionInit t)"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "" ]
    operations =
      [ ("Set", setOperations), ("EqSet", eqSetOperations), ("KeyVal", keyValOperations), ("Stack", stackOperations)
      , ("Queue", queueOperations), ("Deque", dequeOperations)
      , ("SizedStack", sizedStackOperations), ("SizedQueue", sizedQueueOperations) ]
    eqSetOperations =
      [ "function eqSetContainsItems (x :: a) (xs :: List a) -> Bool requires Eq a is"
      , "  first matching case of xs :"
      , "  when Nil then false"
      , "  when Cons h t then x = h || eqSetContainsItems x t"
      , "  end case"
      , "end function"
      , ""
      , "function eqSetDistinctItems (xs :: List a) (seen :: List a) -> List a requires Eq a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then if eqSetContainsItems h seen then eqSetDistinctItems t seen"
      , "    else Cons h (eqSetDistinctItems t (Cons h seen)) end if"
      , "  end case"
      , "end function"
      , ""
      , "function eqSetOf (xs :: List a) -> EqSet a requires Eq a is"
      , "  EqSetItems (eqSetDistinctItems xs [])"
      , "end function"
      , ""
      , "function eqSetItems (set :: EqSet a) -> List a is"
      , "  first matching case of set : when EqSetItems items then items end case"
      , "end function"
      , ""
      , "function eqSetMember (x :: a) (set :: EqSet a) -> Bool requires Eq a is"
      , "  eqSetContainsItems x (eqSetItems set)"
      , "end function"
      , ""
      , "function eqSetInsert (x :: a) (set :: EqSet a) -> EqSet a requires Eq a is"
      , "  if eqSetMember x set then set"
      , "  else EqSetItems (collectionAppend (eqSetItems set) [x]) end if"
      , "end function"
      , ""
      , "function eqSetRemoveItems (x :: a) (items :: List a) -> List a requires Eq a is"
      , "  first matching case of items :"
      , "  when Nil then items"
      , "  when Cons h t then if x = h then eqSetRemoveItems x t"
      , "    else Cons h (eqSetRemoveItems x t) end if"
      , "  end case"
      , "end function"
      , ""
      , "function eqSetRemove (x :: a) (set :: EqSet a) -> EqSet a requires Eq a is"
      , "  EqSetItems (eqSetRemoveItems x (eqSetItems set))"
      , "end function"
      , ""
      , "function eqSetUnion (left :: EqSet a) (right :: EqSet a) -> EqSet a requires Eq a is"
      , "  eqSetOf (collectionAppend (eqSetItems left) (eqSetItems right))"
      , "end function"
      , ""
      , "function eqSetFilterItems (items :: List a) (other :: List a) (keepMembers :: Bool) -> List a requires Eq a is"
      , "  first matching case of items :"
      , "  when Nil then items"
      , "  when Cons h t then if (eqSetContainsItems h other) = keepMembers"
      , "    then Cons h (eqSetFilterItems t other keepMembers)"
      , "    else eqSetFilterItems t other keepMembers end if"
      , "  end case"
      , "end function"
      , ""
      , "function eqSetIntersection (left :: EqSet a) (right :: EqSet a) -> EqSet a requires Eq a is"
      , "  EqSetItems (eqSetFilterItems (eqSetItems left) (eqSetItems right) true)"
      , "end function"
      , ""
      , "function eqSetDifference (left :: EqSet a) (right :: EqSet a) -> EqSet a requires Eq a is"
      , "  EqSetItems (eqSetFilterItems (eqSetItems left) (eqSetItems right) false)"
      , "end function"
      , ""
      , "function eqSetSize (set :: EqSet a) -> Whole is"
      , "  prelude.length (eqSetItems set)"
      , "end function"
      , ""
      , "function eqSetIsEmpty (set :: EqSet a) -> Bool is"
      , "  first matching case of eqSetItems set : when Nil then true when Cons h t then false end case"
      , "end function"
      , ""
      , "" ]
    setOperations =
      [ "function setInsertItems (x :: a) (xs :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then [x]"
      , "  when Cons h t then first matching case of prelude.compare x h :"
      , "    when Less then Cons x xs"
      , "    when Equal then xs"
      , "    when Greater then Cons h (setInsertItems x t)"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function setRemoveItems (x :: a) (xs :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then first matching case of prelude.compare x h :"
      , "    when Less then xs"
      , "    when Equal then t"
      , "    when Greater then Cons h (setRemoveItems x t)"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function setMemberItems (x :: a) (xs :: List a) -> Bool requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then false"
      , "  when Cons h t then first matching case of prelude.compare x h :"
      , "    when Less then false"
      , "    when Equal then true"
      , "    when Greater then setMemberItems x t"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "-- [x] when x is among xs, otherwise empty; and the converse."
      , "function setFoundItems (x :: a) (xs :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then first matching case of prelude.compare x h :"
      , "    when Less then Nil"
      , "    when Equal then [x]"
      , "    when Greater then setFoundItems x t"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function setMissingItems (x :: a) (xs :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then [x]"
      , "  when Cons h t then first matching case of prelude.compare x h :"
      , "    when Less then [x]"
      , "    when Equal then Nil"
      , "    when Greater then setMissingItems x t"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function setFromItems (xs :: List a) (acc :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then acc"
      , "  when Cons h t then setFromItems t (setInsertItems h acc)"
      , "  end case"
      , "end function"
      , ""
      , "function setIntersectionItems (xs :: List a) (ys :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then collectionAppend (setFoundItems h ys) (setIntersectionItems t ys)"
      , "  end case"
      , "end function"
      , ""
      , "function setDifferenceItems (xs :: List a) (ys :: List a) -> List a requires Keyed a is"
      , "  first matching case of xs :"
      , "  when Nil then xs"
      , "  when Cons h t then collectionAppend (setMissingItems h ys) (setDifferenceItems t ys)"
      , "  end case"
      , "end function"
      , ""
      , "function setOf (xs :: List a) -> Set a requires Keyed a is SetItems (setFromItems xs Nil) end function"
      , ""
      , "function setMember (x :: a) (s :: Set a) -> Bool requires Keyed a is"
      , "  first matching case of s : when SetItems xs then setMemberItems x xs end case"
      , "end function"
      , ""
      , "function setInsert (x :: a) (s :: Set a) -> Set a requires Keyed a is"
      , "  first matching case of s : when SetItems xs then SetItems (setInsertItems x xs) end case"
      , "end function"
      , ""
      , "function setRemove (x :: a) (s :: Set a) -> Set a requires Keyed a is"
      , "  first matching case of s : when SetItems xs then SetItems (setRemoveItems x xs) end case"
      , "end function"
      , ""
      , "function setUnion (s :: Set a) (t :: Set a) -> Set a requires Keyed a is"
      , "  first matching case of s : when SetItems xs then first matching case of t : when SetItems ys then SetItems (setFromItems xs ys) end case end case"
      , "end function"
      , ""
      , "function setIntersection (s :: Set a) (t :: Set a) -> Set a requires Keyed a is"
      , "  first matching case of s : when SetItems xs then first matching case of t : when SetItems ys then SetItems (setIntersectionItems xs ys) end case end case"
      , "end function"
      , ""
      , "function setDifference (s :: Set a) (t :: Set a) -> Set a requires Keyed a is"
      , "  first matching case of s : when SetItems xs then first matching case of t : when SetItems ys then SetItems (setDifferenceItems xs ys) end case end case"
      , "end function"
      , ""
      , "" ]
    keyValOperations =
      [ "function keyValPutItems (k :: a) (v :: b) (es :: List (Entry a b)) -> List (Entry a b) requires Keyed a is"
      , "  first matching case of es :"
      , "  when Nil then [Entry record{ key = k , value = v}]"
      , "  when Cons e t then first matching case of e :"
      , "    when Entry record{ key = key , value = value} then first matching case of prelude.compare k key :"
      , "      when Less then Cons (Entry record{ key = k , value = v}) es"
      , "      when Equal then Cons (Entry record{ key = k , value = v}) t"
      , "      when Greater then Cons e (keyValPutItems k v t)"
      , "      end case"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValDeleteItems (k :: a) (es :: List (Entry a b)) -> List (Entry a b) requires Keyed a is"
      , "  first matching case of es :"
      , "  when Nil then es"
      , "  when Cons e t then first matching case of e :"
      , "    when Entry record{ key = key , value = value} then first matching case of prelude.compare k key :"
      , "      when Less then es"
      , "      when Equal then t"
      , "      when Greater then Cons e (keyValDeleteItems k t)"
      , "      end case"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValLookupItems (k :: a) (es :: List (Entry a b)) -> Maybe b requires Keyed a is"
      , "  first matching case of es :"
      , "  when Nil then Absent"
      , "  when Cons e t then first matching case of e :"
      , "    when Entry record{ key = key , value = value} then first matching case of prelude.compare k key :"
      , "      when Less then Absent"
      , "      when Equal then Present value"
      , "      when Greater then keyValLookupItems k t"
      , "      end case"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValFromItems (es :: List (Entry a b)) (acc :: List (Entry a b)) -> List (Entry a b) requires Keyed a is"
      , "  first matching case of es :"
      , "  when Nil then acc"
      , "  when Cons e t then first matching case of e :"
      , "    when Entry record{ key = key , value = value} then keyValFromItems t (keyValPutItems key value acc)"
      , "    end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValKeysItems (es :: List (Entry a b)) -> List a is"
      , "  first matching case of es :"
      , "  when Nil then Nil"
      , "  when Cons e t then first matching case of e : when Entry record{ key = key , value = value} then Cons key (keyValKeysItems t) end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValValuesItems (es :: List (Entry a b)) -> List b is"
      , "  first matching case of es :"
      , "  when Nil then Nil"
      , "  when Cons e t then first matching case of e : when Entry record{ key = key , value = value} then Cons value (keyValValuesItems t) end case"
      , "  end case"
      , "end function"
      , ""
      , "function keyValOf (es :: List (Entry a b)) -> KeyVal a b requires Keyed a is"
      , "  KeyValEntries (keyValFromItems es Nil)"
      , "end function"
      , ""
      , "function keyValLookup (k :: a) (m :: KeyVal a b) -> Maybe b requires Keyed a is"
      , "  first matching case of m : when KeyValEntries es then keyValLookupItems k es end case"
      , "end function"
      , ""
      , "function keyValPut (k :: a) (v :: b) (m :: KeyVal a b) -> KeyVal a b requires Keyed a is"
      , "  first matching case of m : when KeyValEntries es then KeyValEntries (keyValPutItems k v es) end case"
      , "end function"
      , ""
      , "function keyValDelete (k :: a) (m :: KeyVal a b) -> KeyVal a b requires Keyed a is"
      , "  first matching case of m : when KeyValEntries es then KeyValEntries (keyValDeleteItems k es) end case"
      , "end function"
      , ""
      , "function keyValKeys (m :: KeyVal a b) -> List a is"
      , "  first matching case of m : when KeyValEntries es then keyValKeysItems es end case"
      , "end function"
      , ""
      , "function keyValValues (m :: KeyVal a b) -> List b is"
      , "  first matching case of m : when KeyValEntries es then keyValValuesItems es end case"
      , "end function"
      , ""
      , "function keyValEntries (m :: KeyVal a b) -> List (Entry a b) is"
      , "  first matching case of m : when KeyValEntries es then es end case"
      , "end function"
      , ""
      , "" ]
    stackOperations =
      [ "function stackOf (xs :: List a) -> Stack a is StackItems xs end function"
      , ""
      , "function stackPush (x :: a) (s :: Stack a) -> Stack a is"
      , "  first matching case of s : when StackItems xs then StackItems (Cons x xs) end case"
      , "end function"
      , ""
      , "function stackPop (s :: Stack a) -> Stack a is"
      , "  first matching case of s : when StackItems xs then StackItems (collectionTail xs) end case"
      , "end function"
      , ""
      , "function stackPeek (s :: Stack a) -> Maybe a is"
      , "  first matching case of s : when StackItems xs then collectionHead xs end case"
      , "end function"
      , ""
      , "" ]
    queueOperations =
      [ "function queueOf (xs :: List a) -> Queue a is QueueItems xs end function"
      , ""
      , "function queueEnqueue (x :: a) (q :: Queue a) -> Queue a is"
      , "  first matching case of q : when QueueItems xs then QueueItems (collectionAppend xs [x]) end case"
      , "end function"
      , ""
      , "function queueDequeue (q :: Queue a) -> Queue a is"
      , "  first matching case of q : when QueueItems xs then QueueItems (collectionTail xs) end case"
      , "end function"
      , ""
      , "function queueFront (q :: Queue a) -> Maybe a is"
      , "  first matching case of q : when QueueItems xs then collectionHead xs end case"
      , "end function"
      , ""
      , "" ]
    dequeOperations =
      [ "function dequeOf (xs :: List a) -> Deque a is DequeItems xs end function"
      , ""
      , "function dequePushFront (x :: a) (d :: Deque a) -> Deque a is"
      , "  first matching case of d : when DequeItems xs then DequeItems (Cons x xs) end case"
      , "end function"
      , ""
      , "function dequePushBack (x :: a) (d :: Deque a) -> Deque a is"
      , "  first matching case of d : when DequeItems xs then DequeItems (collectionAppend xs [x]) end case"
      , "end function"
      , ""
      , "function dequePopFront (d :: Deque a) -> Deque a is"
      , "  first matching case of d : when DequeItems xs then DequeItems (collectionTail xs) end case"
      , "end function"
      , ""
      , "function dequePopBack (d :: Deque a) -> Deque a is"
      , "  first matching case of d : when DequeItems xs then DequeItems (collectionInit xs) end case"
      , "end function"
      , ""
      , "function dequePeekFront (d :: Deque a) -> Maybe a is"
      , "  first matching case of d : when DequeItems xs then collectionHead xs end case"
      , "end function"
      , ""
      , "function dequePeekBack (d :: Deque a) -> Maybe a is"
      , "  first matching case of d : when DequeItems xs then collectionLast xs end case"
      , "end function"
      , ""
      , "" ]

sizedStackOperations :: [String]
sizedStackOperations =
  [ "function sizedStackPush (x :: a) (s :: SizedStack n a) -> SizedStack (n + 1) a is SizedStackPush record{ top = x , rest = s} end function"
  , ""
  , "function sizedStackPop (s :: SizedStack (n + 1) a) -> SizedStack n a is"
  , "  first matching case of s : when SizedStackPush record{ top = top , rest = rest} then rest end case"
  , "end function"
  , ""
  , "function sizedStackTop (s :: SizedStack (n + 1) a) -> a is"
  , "  first matching case of s : when SizedStackPush record{ top = top , rest = rest} then top end case"
  , "end function"
  , ""
  , "function sizedStackItems (s :: SizedStack n a) -> List a is"
  , "  first matching case of s :"
  , "  when SizedStackEmpty then Nil"
  , "  when SizedStackPush record{ top = top , rest = rest} then Cons top (sizedStackItems rest)"
  , "  end case"
  , "end function"
  , ""
  , "" ]

sizedQueueOperations :: [String]
sizedQueueOperations =
  [ "function sizedQueueEnqueue (x :: a) (q :: SizedQueue n a) -> SizedQueue (n + 1) a is"
  , "  first matching case of q :"
  , "  when SizedQueueEmpty then SizedQueueFront record{ front = x , rest = SizedQueueEmpty}"
  , "  when SizedQueueFront record{ front = front , rest = rest} then SizedQueueFront record{ front = front , rest = (sizedQueueEnqueue x rest)}"
  , "  end case"
  , "end function"
  , ""
  , "function sizedQueueDequeue (q :: SizedQueue (n + 1) a) -> SizedQueue n a is"
  , "  first matching case of q : when SizedQueueFront record{ front = front , rest = rest} then rest end case"
  , "end function"
  , ""
  , "function sizedQueueFront (q :: SizedQueue (n + 1) a) -> a is"
  , "  first matching case of q : when SizedQueueFront record{ front = front , rest = rest} then front end case"
  , "end function"
  , ""
  , "function sizedQueueItems (q :: SizedQueue n a) -> List a is"
  , "  first matching case of q :"
  , "  when SizedQueueEmpty then Nil"
  , "  when SizedQueueFront record{ front = front , rest = rest} then Cons front (sizedQueueItems rest)"
  , "  end case"
  , "end function"
  , ""
  , "" ]

-- | prelude.wrapping, prelude.saturating and prelude.bounded are checked
-- definitions here, one per bounded integer type, which elaboration picks
-- by the type the context wants (LawSpec.Elaboration).
boundedArithmeticBlock :: String
boundedArithmeticBlock = "Bounded"

boundedArithmeticTypes :: [String]
boundedArithmeticTypes = ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "IntSize", "UIntSize", "UIntPtr"]

-- | The definition of an operation at a type: wrappingInt32.
boundedArithmeticDefinition :: String -> String -> String
boundedArithmeticDefinition operation t = operation ++ t

boundedArithmeticDefinitions :: [String]
boundedArithmeticDefinitions = [boundedArithmeticDefinition o t | t <- boundedArithmeticTypes, o <- ["wrapping", "saturating", "bounded"]]

boundedArithmeticSource :: [String]
boundedArithmeticSource = concat
  [ [ "function wrapping" ++ t ++ " (value :: Integer) -> " ++ t ++ " is"
    , "  let r = prelude.rem (value - " ++ t ++ ".min) (" ++ t ++ ".max - " ++ t ++ ".min + 1) in"
    , "  if r < 0 then prelude." ++ t ++ " (r + (" ++ t ++ ".max - " ++ t ++ ".min + 1) + " ++ t ++ ".min) else prelude." ++ t ++ " (r + " ++ t ++ ".min) end if end let"
    , "end function"
    , ""
    , "function saturating" ++ t ++ " (value :: Integer) -> " ++ t ++ " is"
    , "  if value > " ++ t ++ ".max then " ++ t ++ ".max else if value < " ++ t ++ ".min then " ++ t ++ ".min else prelude." ++ t ++ " value end if end if"
    , "end function"
    , ""
    , "function bounded" ++ t ++ " (value :: Integer) -> Maybe " ++ t ++ " is"
    , "  if value >= " ++ t ++ ".min && value <= " ++ t ++ ".max then Present (prelude." ++ t ++ " value) else Absent end if"
    , "end function"
    , "" ]
  | t <- boundedArithmeticTypes ]
