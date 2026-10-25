{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
-- | The canonical encodings behind content identity. Checked Core is written
-- twice over in one traversal: a semantic stream, which says what a thing
-- does, and two presentation streams, its names and its docs and spans.
--
-- The semantic stream (lawspec.semantic.v1) writes binders as their position
-- in traversal order, references to other nodes as their semantic hashes
-- (or, inside a recursive group, as member positions), and literals in a
-- normal form. Names, identity spellings, docs, origins and spans go to the
-- presentation streams instead. So alpha-equivalent Core encodes the same,
-- and an edit that changes only names or layout changes only the
-- presentation streams. Hashing is structural, never up to computation.
-- ref:DEC-content-identity
module LawSpec.Core.Identity
  ( Reference(..), Resolver(..), Encoded(..), Encode(..), Collect(..)
  , encode, encodeAdapter, references, presentationFields, semanticVersion
  ) where

import Control.Monad.Trans.State.Strict (State, execState, get, modify', put)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Generics
import LawSpec.Common
import LawSpec.Core
import qualified LawSpec.Core.Value as CoreValue
import LawSpec.Core.Machine
import LawSpec.Core.Policy
import qualified LawSpec.Core.Program as Scenario
import LawSpec.Core.RecordIdentity (scalarValue)
import LawSpec.IndexTerm
import LawSpec.Scalar (Scalar, Family, Primitive)

-- | The encoding's version tag, written first in every semantic stream.
semanticVersion :: String
semanticVersion = "lawspec.semantic.v1"

-- | How a reference to another node is written.
data Reference
  = Hashed B.ByteString          -- ^ the node's semantic hash
  | Member Int                   -- ^ a member of the group being hashed
  | Hidden                       -- ^ a group member, position not yet known
  | ConstructorOf Reference Int  -- ^ a constructor: its type and position
  deriving (Eq, Show)

-- | What the encoder knows about other nodes: identities (declarations,
-- constructors, handlers, abilities) and type names (data declarations).
data Resolver = Resolver { resolveId :: Id -> Maybe Reference, resolveType :: String -> Maybe Reference }

-- | The three streams of one value.
data Encoded = Encoded { semanticBytes :: !B.ByteString, nameBytes :: !B.ByteString, docBytes :: !B.ByteString }

data Stream = Semantic | Names | Docs deriving Eq

data St = St
  { stSemantic :: !BB.Builder, stNames :: !BB.Builder, stDocs :: !BB.Builder
  , stStream :: !Stream
  , stBinders :: !(M.Map Id Int), stTypeVariables :: !(M.Map Id Int)
  , stNextBinder :: !Int, stNextType :: !Int, stBindTypes :: !Bool }

type M = State St

-- | Record fields that are presentation. Every other field of Core is
-- semantic. A name here moves the field's whole content to that stream.
presentationFields :: M.Map String Stream
presentationFields = M.fromList $
  [ (f, Names) | f <- [ "declarationId", "declarationName", "declarationSource", "declarationTemplate", "dataId", "dataName", "constructorId", "constructorName"
                      , "abilityName", "handlerId", "handlerName", "propertyId", "propertyName", "contractDeclaration"
                      , "sessionId", "sessionName", "unitId", "unitHarnessName", "exampleName", "coverLabel" ] ] ++
  [ (f, Docs) | f <- [ "declarationOrigin", "dataOrigin", "constructorOrigin", "expressionOrigin", "abilityOrigin"
                     , "handlerOrigin", "propertyLocation", "propertyDescription", "propertyRationale"
                     , "propertyReferences", "propertyTrace", "propertyMetadata" ] ]

-- | Fields whose identities bind type variables.
typeBinderFields :: S.Set String
typeBinderFields = S.fromList ["dataParameters", "constructorExistentials", "abilityParameters"]

-- | Encode a value against a resolver.
encode :: Encode a => Resolver -> a -> Encoded
encode resolver value = finish (execState (tag semanticVersion >> enc resolver value) start)

-- | An adapter has no body: its identity is the native code it binds, so
-- its qualified name and native source are semantic too.
encodeAdapter :: Encode a => Resolver -> String -> a -> Encoded
encodeAdapter resolver binding value = finish (execState (tag semanticVersion >> tag "adapter" >> text binding >> enc resolver value) start)

start :: St
start = St mempty mempty mempty Semantic M.empty M.empty 0 0 False

finish :: St -> Encoded
finish s = Encoded (strict (stSemantic s)) (strict (stNames s)) (strict (stDocs s))
  where strict = BL.toStrict . BB.toLazyByteString

-- Writing ------------------------------------------------------------------

emit :: BB.Builder -> M ()
emit b = modify' $ \s -> case stStream s of
  Semantic -> s { stSemantic = stSemantic s <> b }
  Names -> s { stNames = stNames s <> b }
  Docs -> s { stDocs = stDocs s <> b }

-- | A name beside the semantic content: to the names stream, or to the
-- current stream when that is already presentation.
aside :: Stream -> String -> M ()
aside stream value = modify' $ \s -> case (stStream s, stream) of
  (Semantic, Names) -> s { stNames = stNames s <> framed value }
  (Semantic, Docs) -> s { stDocs = stDocs s <> framed value }
  (Names, _) -> s { stNames = stNames s <> framed value }
  (_, _) -> s { stDocs = stDocs s <> framed value }

inStream :: Stream -> M () -> M ()
inStream stream action = do
  before <- stStream <$> get
  modify' (\s -> s { stStream = if before == Semantic then stream else before })
  action
  modify' (\s -> s { stStream = before })

framed :: String -> BB.Builder
framed value = let bytes = T.encodeUtf8 (T.pack value)
  in BB.wordDec (fromIntegral (B.length bytes)) <> BB.char7 ':' <> BB.byteString bytes

text :: String -> M ()
text = emit . framed

tag :: String -> M ()
tag = text

number :: Integer -> M ()
number n = emit (BB.char7 '#' <> BB.integerDec n <> BB.char7 ';')

reference :: Reference -> M ()
reference r = case r of
  Hashed h -> emit (BB.char7 'H' <> BB.byteString h)
  Member i -> emit (BB.char7 'M') >> number (toInteger i)
  Hidden -> emit (BB.char7 'm')
  ConstructorOf owner i -> emit (BB.char7 'C') >> reference owner >> number (toInteger i)

-- The class --------------------------------------------------------------

-- | A value with a canonical encoding. Most of Core uses the generic
-- instance; identities, binders, types and literals are written by hand.
class Collect a => Encode a where
  enc :: Resolver -> a -> M ()
  default enc :: (Generic a, GEncode (Rep a)) => Resolver -> a -> M ()
  enc r = genc r . from

class GEncode f where
  genc :: Resolver -> f p -> M ()

instance GEncode V1 where genc _ _ = pure ()
instance GEncode U1 where genc _ _ = pure ()
instance (GEncode a, GEncode b) => GEncode (a :*: b) where
  genc r (a :*: b) = genc r a >> genc r b
instance (GEncode a, GEncode b) => GEncode (a :+: b) where
  genc r (L1 a) = genc r a
  genc r (R1 b) = genc r b
instance GEncode a => GEncode (M1 D c a) where
  genc r (M1 a) = genc r a
instance (Constructor c, GEncode a) => GEncode (M1 C c a) where
  genc r m@(M1 a) = tag (conName m) >> genc r a
instance (Selector s, GEncode a) => GEncode (M1 S s a) where
  genc r m@(M1 a) = case M.lookup (selName m) presentationFields of
    Just stream -> inStream stream (genc r a)
    Nothing
      | S.member (selName m) typeBinderFields -> do
          modify' (\s -> s { stBindTypes = True })
          genc r a
          modify' (\s -> s { stBindTypes = False })
      | otherwise -> genc r a
instance Encode a => GEncode (K1 i a) where
  genc r (K1 a) = enc r a

-- Hand-written instances ----------------------------------------------------

instance Encode Id where
  enc r i = do
    s <- get
    if stStream s /= Semantic then text (idText i)
    else if stBindTypes s then bindType i
    else case (M.lookup i (stBinders s), M.lookup i (stTypeVariables s)) of
      (Just level, _) -> emit (BB.char7 'b') >> number (toInteger level) >> aside Names (idText i)
      (_, Just level) -> emit (BB.char7 'v') >> number (toInteger level) >> aside Names (idText i)
      _ -> case resolveId r i of
        Just ref -> reference ref >> aside Names (idText i)
        Nothing -> emit (BB.char7 'f') >> text (idText i)

bindType :: Id -> M ()
bindType i = do
  s <- get
  put s { stTypeVariables = M.insert i (stNextType s) (stTypeVariables s), stNextType = stNextType s + 1 }
  emit (BB.char7 'V')
  aside Names (idText i)

instance Encode Binder where
  enc r (Binder i name ty) = do
    modify' (\s -> s { stBinders = M.insert i (stNextBinder s) (stBinders s), stNextBinder = stNextBinder s + 1 })
    emit (BB.char7 'B')
    aside Names name
    aside Names (idText i)
    enc r ty

instance Encode Type where
  enc r ty = case ty of
    Constructor name arguments -> do
      case resolveType r name of
        Just ref -> emit (BB.char7 'T') >> reference ref >> aside Names name
        Nothing -> emit (BB.char7 'P') >> text name
      enc r arguments
    TypeVariable i -> typeVariable i
    Arrow a b -> emit (BB.char7 'A') >> enc r a >> enc r b

-- | A type variable is numbered by its first occurrence: implicitly bound
-- variables have no binder to number them.
typeVariable :: Id -> M ()
typeVariable i = do
  s <- get
  level <- case M.lookup i (stTypeVariables s) of
    Just level -> pure level
    Nothing -> do
      let level = stNextType s
      put s { stTypeVariables = M.insert i level (stTypeVariables s), stNextType = level + 1 }
      pure level
  emit (BB.char7 'v') >> number (toInteger level) >> aside Names (idText i)

instance Encode Index where
  enc _ (Natural n) = emit (BB.char7 'n') >> number n
  enc _ (IndexVariable i) = typeVariable i

instance Encode Scalar where
  enc _ value = emit (BB.char7 'L') >> emit (BB.lazyByteString (Aeson.encode (scalarValue value)))

instance Encode Origin where enc _ o = aside Docs (show o)
instance Encode Location where enc _ o = aside Docs (show o)
instance Encode Span where enc _ o = aside Docs (show o)

instance {-# OVERLAPPING #-} Encode String where enc _ = text
instance Encode Integer where enc _ = number
instance Encode Int where enc _ = number . toInteger
instance Encode Bool where enc _ b = emit (BB.char7 (if b then 'y' else 'n'))
instance Encode a => Encode [a] where
  enc r xs = emit (BB.char7 '[') >> number (toInteger (length xs)) >> mapM_ (enc r) xs
instance Encode a => Encode (Maybe a) where
  enc _ Nothing = emit (BB.char7 '_')
  enc r (Just a) = emit (BB.char7 '?') >> enc r a
instance (Encode a, Encode b) => Encode (Either a b) where
  enc r (Left a) = emit (BB.char7 '<') >> enc r a
  enc r (Right b) = emit (BB.char7 '>') >> enc r b
instance (Encode a, Encode b) => Encode (a, b) where
  enc r (a, b) = enc r a >> enc r b
instance (Encode a, Encode b, Encode c) => Encode (a, b, c) where
  enc r (a, b, c) = enc r a >> enc r b >> enc r c
instance (Encode a, Encode b, Encode c, Encode d) => Encode (a, b, c, d) where
  enc r (a, b, c, d) = enc r a >> enc r b >> enc r c >> enc r d
instance (Encode k, Encode v) => Encode (M.Map k v) where
  enc r = enc r . M.toList

-- | A law's template parameters are bound before its inputs and body use
-- them, so they are written first. The pattern names every field, so a new
-- one cannot be left out.
instance Encode Property where
  enc r (MkProperty identity name location inputs body examples generation description rationale refs trace
                    handlers resources harness domain metadata parameters) = do
    tag "law"
    inStream Names (enc r identity >> text name)
    inStream Docs (enc r location >> text description >> text rationale >> enc r refs >> enc r trace >> enc r metadata)
    enc r parameters
    enc r inputs
    enc r body
    enc r examples
    enc r generation
    enc r handlers
    enc r resources
    enc r harness
    enc r domain

instance Encode Declaration
instance Encode Definition
instance Encode Contract
instance Encode DataDeclaration
instance Encode DataConstructor
instance Encode StructuralRecord
instance Encode Expr
instance Encode CoreValue.Value
instance Encode Node
instance Encode MatchCase
instance Encode AbilityRef
instance Encode Operation
instance Encode Handling
instance Encode HandlerRef
instance Encode Ability
instance Encode Handler
instance Encode BinaryOp
instance Encode UnaryOp
instance Encode LogicalOp
instance Encode Conversion
instance Encode Evidence
instance Encode Builtin
instance Encode Proposition
instance Encode Quantifier
instance Encode Quantification
instance Encode Example
instance Encode LawHarness
instance Encode WitnessChoice
instance Encode Cover
instance Encode Draw
instance Encode UnitHarness
instance Encode Resource
instance Encode Unit
instance Encode FailureBinding
instance Encode FailurePayload
instance Encode Mailbox
instance Encode Session
instance Encode Program
instance Encode Kind
instance Encode Argument
instance Encode Generation
instance Encode InputDomain
instance Encode LawMetadata
instance Encode ReferenceSelector
instance Encode DocumentaryTarget
instance Encode a => Encode (DocumentaryReference a)
instance Encode a => Encode (Machine a)
instance Encode Consistency
instance Encode a => Encode (MachineStart a)
instance Encode a => Encode (Command a)
instance Encode Need
instance Encode Shift
instance Encode a => Encode (Invariant a)
instance Encode Supervisor
instance Encode SupervisionStrategy
instance Encode Lifetime
instance Encode a => Encode (StagePolicy a)
instance Encode a => Encode (Limit a)
instance Encode a => Encode (Breaker a)
instance Encode Hedge
instance Encode a => Encode (Bulkhead a)
instance Encode a => Encode (Retry a)
instance Encode a => Encode (Strategy a)
instance Encode Jitter
instance Encode IndexOperation
instance Encode IndexTerm
instance Encode IndexRelation
instance Encode IndexGuard
instance Encode ConstructorIndex
instance Encode FamilyIndex
instance Encode Family
instance Encode Primitive
instance Encode Scenario.Program
instance Encode Scenario.Act
instance Encode Scenario.Operand
instance Encode Scenario.Constant

-- References -----------------------------------------------------------------

-- | The identities and type names a value's semantic fields mention, for the
-- graph's edges. It walks the same fields the encoder writes semantically,
-- so every reference the encoder resolves is an edge.
class Collect a where
  collect :: a -> [String] -> [String]
  default collect :: (Generic a, GCollect (Rep a)) => a -> [String] -> [String]
  collect = gcollect . from

class GCollect f where gcollect :: f p -> [String] -> [String]
instance GCollect V1 where gcollect _ = id
instance GCollect U1 where gcollect _ = id
instance (GCollect a, GCollect b) => GCollect (a :*: b) where gcollect (a :*: b) = gcollect a . gcollect b
instance (GCollect a, GCollect b) => GCollect (a :+: b) where
  gcollect (L1 a) = gcollect a
  gcollect (R1 b) = gcollect b
instance GCollect a => GCollect (M1 D c a) where gcollect (M1 a) = gcollect a
instance GCollect a => GCollect (M1 C c a) where gcollect (M1 a) = gcollect a
instance (Selector s, GCollect a) => GCollect (M1 S s a) where
  gcollect m@(M1 a) = if M.member (selName m) presentationFields || S.member (selName m) typeBinderFields then id else gcollect a
instance Collect a => GCollect (K1 i a) where gcollect (K1 a) = collect a

-- | Every mention, without repeats, in first-mention order.
references :: Collect a => a -> [String]
references value = go S.empty (collect value [])
  where
    go _ [] = []
    go seen (x : xs) | S.member x seen = go seen xs
                     | otherwise = x : go (S.insert x seen) xs

instance Collect Id where collect i = (idText i :)
instance Collect Type where
  collect ty = case ty of
    Constructor name arguments -> (name :) . collect arguments
    TypeVariable _ -> id
    Arrow a b -> collect a . collect b
instance Collect Binder where collect b = collect (binderType b)
instance Collect Index where collect _ = id
instance Collect Scalar where collect _ = id
instance Collect CoreValue.Value
instance Collect Origin where collect _ = id
instance Collect Location where collect _ = id
instance Collect Span where collect _ = id
instance {-# OVERLAPPING #-} Collect String where collect _ = id
instance Collect Integer where collect _ = id
instance Collect Int where collect _ = id
instance Collect Bool where collect _ = id
instance Collect a => Collect [a] where collect xs rest = foldr collect rest xs
instance Collect a => Collect (Maybe a) where collect = maybe id collect
instance (Collect a, Collect b) => Collect (Either a b) where collect = either collect collect
instance (Collect a, Collect b) => Collect (a, b) where collect (a, b) = collect a . collect b
instance (Collect a, Collect b, Collect c) => Collect (a, b, c) where collect (a, b, c) = collect a . collect b . collect c
instance (Collect a, Collect b, Collect c, Collect d) => Collect (a, b, c, d) where
  collect (a, b, c, d) = collect a . collect b . collect c . collect d
instance (Collect k, Collect v) => Collect (M.Map k v) where collect = collect . M.toList
instance Collect Property where
  collect p = collect (propertyParameters p) . collect (propertyInputs p) . collect (propertyBody p) .
    collect (propertyExamples p) . collect (propertyHandlers p) . collect (propertyResources p) . collect (propertyHarness p)

instance Collect Declaration
instance Collect Definition
instance Collect Contract
instance Collect DataDeclaration
instance Collect DataConstructor
instance Collect StructuralRecord
instance Collect Expr
instance Collect Node
instance Collect MatchCase
instance Collect AbilityRef
instance Collect Operation
instance Collect Handling
instance Collect HandlerRef
instance Collect Ability
instance Collect Handler
instance Collect BinaryOp
instance Collect UnaryOp
instance Collect LogicalOp
instance Collect Conversion
instance Collect Evidence
instance Collect Builtin
instance Collect Proposition
instance Collect Quantifier
instance Collect Quantification
instance Collect Example
instance Collect LawHarness
instance Collect WitnessChoice
instance Collect Cover
instance Collect Draw
instance Collect UnitHarness
instance Collect Resource
instance Collect Unit
instance Collect FailureBinding
instance Collect FailurePayload
instance Collect Mailbox
instance Collect Session
instance Collect Program
instance Collect Kind
instance Collect Argument
instance Collect Generation
instance Collect InputDomain
instance Collect LawMetadata
instance Collect ReferenceSelector
instance Collect DocumentaryTarget
instance Collect a => Collect (DocumentaryReference a)
instance Collect a => Collect (Machine a)
instance Collect Consistency
instance Collect a => Collect (MachineStart a)
instance Collect a => Collect (Command a)
instance Collect Need
instance Collect Shift
instance Collect a => Collect (Invariant a)
instance Collect Supervisor
instance Collect SupervisionStrategy
instance Collect Lifetime
instance Collect a => Collect (StagePolicy a)
instance Collect a => Collect (Limit a)
instance Collect a => Collect (Breaker a)
instance Collect Hedge
instance Collect a => Collect (Bulkhead a)
instance Collect a => Collect (Retry a)
instance Collect a => Collect (Strategy a)
instance Collect Jitter
instance Collect IndexOperation
instance Collect IndexTerm
instance Collect IndexRelation
instance Collect IndexGuard
instance Collect ConstructorIndex
instance Collect FamilyIndex
instance Collect Family
instance Collect Primitive
instance Collect Scenario.Program
instance Collect Scenario.Act
instance Collect Scenario.Operand
instance Collect Scenario.Constant
