-- | Checked literal data as constructor shapes and fresh factories. Sharing
-- applies to emitted code, never to a runtime value or its symbol context.
-- Ordered roots, fields, list elements and witness fields stay unchanged.
-- ref:DEC-planned-generation ref:DEC-readable-output-default
module LawSpec.Testing.Literals
  ( LiteralShape(..), LiteralTerm(..), LiteralPlan(..)
  , planLiterals, literalReference, foldLiteral, coverLiterals
  ) where

import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import LawSpec.Core (Type(..), Argument(..), Id)
import LawSpec.Core.Value (Value(..), listItems)
import LawSpec.Scalar (Scalar)
import LawSpec.Testing.Cover (FiniteCover(..), CaseDomain(..))

-- | Lists keep their existing ordered representation; constructors retain
-- their complete checked type, tag and payload, including existential witnesses.
data LiteralShape
  = ConstructorShape Type Id
  | ListShape Type
  | PresenceShape Type Bool
  deriving (Eq, Ord, Show)

-- | A shared term is a function invocation in the current call's context.
-- A shape application constructs a new value from its newly evaluated fields.
data LiteralTerm
  = ScalarLiteral Scalar
  | ApplyLiteral Int [LiteralTerm]
  | SharedLiteral Int
  deriving (Eq, Show)

data LiteralPlan = LiteralPlan
  { literalShapes :: [(Int, LiteralShape)]
  -- Dependency order: a factory only invokes factories earlier in this list.
  , literalFactories :: [(Int, LiteralTerm)]
  , literalReferences :: M.Map Value LiteralTerm
  } deriving (Eq, Show)

data Builder = Builder
  { shapes :: M.Map LiteralShape Int
  , shapeOrder :: [(Int, LiteralShape)]
  , factories :: [(Int, LiteralTerm)]
  , references :: M.Map Value LiteralTerm
  }

-- | Repeated structural subvalues become context-taking functions. Primitive
-- data remains inline; no finite domain, root or repeated observation is removed.
planLiterals :: [Value] -> Either String LiteralPlan
planLiterals values = do
  counts <- execStateT (mapM_ count values) M.empty
  (_, state) <- runStateT (mapM_ (build counts) values) (Builder M.empty [] [] M.empty)
  pure (LiteralPlan (reverse (shapeOrder state)) (reverse (factories state)) (references state))
  where
    count :: Value -> StateT (M.Map Value Int) (Either String) ()
    count value = do
      view <- lift (inspect value)
      case view of
        Nothing -> pure ()
        Just (_, children) -> do
          modify' (M.insertWith (+) value (1 :: Int))
          mapM_ count children
    build :: M.Map Value Int -> Value -> StateT Builder (Either String) LiteralTerm
    build counts value = do
      known <- gets (M.lookup value . references)
      case known of
        Just term -> pure term
        Nothing -> do
          view <- lift (inspect value)
          term <- case (value, view) of
            (ScalarValue scalar, _) -> pure (ScalarLiteral scalar)
            (_, Just (shape, children)) -> do
              fields <- mapM (build counts) children
              knownShape <- gets (M.lookup shape . shapes)
              index <- case knownShape of
                Just index -> pure index
                Nothing -> do
                  index <- gets ((+ 1) . M.size . shapes)
                  modify' (\state -> state { shapes = M.insert shape index (shapes state), shapeOrder = (index, shape) : shapeOrder state })
                  pure index
              let body = ApplyLiteral index fields
              if M.findWithDefault 0 value counts > 1
                then do
                  index <- gets ((+ 1) . length . factories)
                  modify' (\state -> state { factories = (index, body) : factories state })
                  pure (SharedLiteral index)
                else pure body
            _ -> lift (Left "invalid structural literal")
          modify' (\state -> state { references = M.insert value term (references state) })
          pure term

inspect :: Value -> Either String (Maybe (LiteralShape, [Value]))
inspect (ScalarValue _) = pure Nothing
inspect value@(DataValue ty@(Constructor "List" [TypeArgument _]) _ _) =
  (\items -> Just (ListShape ty, items)) <$> listItems value
inspect (DataValue ty tag fields) = pure (Just (ConstructorShape ty tag, fields))
inspect (PresenceValue ty payload) = pure (Just (PresenceShape ty (maybe False (const True) payload), maybe [] pure payload))

literalReference :: LiteralPlan -> Value -> Either String LiteralTerm
literalReference plan value = maybe (Left "literal was not included in its emission plan") Right
  (M.lookup value (literalReferences plan))

-- | Target callbacks build structured expressions. Shared references must emit
-- calls with the current context; they must not read a stored native value.
foldLiteral :: Monad m => (Scalar -> m a) -> (Int -> [a] -> m a) -> (Int -> m a)
  -> LiteralTerm -> m a
foldLiteral scalar shape shared term = case term of
  ScalarLiteral value -> scalar value
  ApplyLiteral index fields -> mapM (foldLiteral scalar shape shared) fields >>= shape index
  SharedLiteral index -> shared index

-- | Intervals already have compact runtime generators. Only explicit value
-- domains contribute factories, without enumerating an interval's endpoints.
coverLiterals :: FiniteCover -> [Value]
coverLiterals (Complete _) = []
coverLiterals (Alternatives branches) = concat
  [(case domain of Values values -> values; IntegerInterval {} -> []) ++ coverLiterals suffix
  | (domain, suffix) <- branches]
