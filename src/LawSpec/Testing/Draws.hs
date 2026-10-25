{-# LANGUAGE DeriveGeneric #-}
-- | Checked strategy draws form a dependency-ordered graph. Each helper's
-- captures are explicit arguments, so sharing code never shares a random
-- sample, a generator context or an effect from an unchosen branch.
-- ref:DEC-planned-generation ref:DEC-readable-output-default
module LawSpec.Testing.Draws
  ( DrawPlan(..), DrawNode(..), DrawCall(..), DrawStep(..), planDraw ) where

import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Data.List (nub)
import qualified Data.Map.Strict as M
import GHC.Generics (Generic)
import qualified LawSpec.Core as C
import LawSpec.Core.Identity (Encode, Collect, Resolver(..), semanticBytes, encode)
import LawSpec.Testing (GeneratorRequirement(..), IndexedGeneration(..))

-- | A call supplies the free values in the callee's capture order.
data DrawCall = DrawCall { drawCallee :: Int, drawArguments :: [C.Id] }
  deriving (Eq, Show, Generic)

-- | A shallow draw keeps the choice and scope constructs in checked Core.
data DrawStep
  = AnyDraw C.Type (Maybe C.Quantifier)
  | OneOfDraw C.Type [C.Expr]
  | FrequencyDraw [(Integer, DrawCall)]
  | FilterDraw DrawCall C.Binder C.Expr Integer
  | BindDraw C.Binder DrawCall DrawCall
  deriving (Eq, Show, Generic)

-- | Captures bind the original free identities in this representative body.
data DrawNode = DrawNode { drawNumber :: Int, drawCaptures :: [C.Binder], drawStep :: DrawStep }
  deriving (Eq, Show)

data DrawPlan = DrawPlan { drawRoot :: DrawCall, drawNodes :: [DrawNode] }
  deriving (Eq, Show)

instance Collect DrawCall
instance Encode DrawCall
instance Collect DrawStep
instance Encode DrawStep

-- | Intern shallow, alpha-normal bodies. Children precede their callers;
-- edges pass actual free values even when their callee uses other binders.
-- The requirement is fixed within a graph: an Any draw retains that input's
-- directed domain rather than accidentally inheriting another input's bounds.
planDraw :: GeneratorRequirement -> [C.Binder] -> C.Draw -> Either String DrawPlan
planDraw requirement available root = do
  (call, (_, nodes)) <- runStateT (visit root) (M.empty, [])
  pure (DrawPlan call nodes)
  where
    registry = M.fromList [(C.binderId b,b) | b <- available ++ binders root]
    capture identity = maybe (Left ("strategy draw has an unbound capture: " ++ C.idText identity)) Right (M.lookup identity registry)
    resolver = Resolver (const Nothing) (const Nothing)
    visit :: C.Draw -> StateT (M.Map B.ByteString Int, [DrawNode]) (Either String) DrawCall
    visit draw = do
      step <- case draw of
        C.DrawAny ty aim -> pure (AnyDraw ty aim)
        C.DrawOneOf ty values -> pure (OneOfDraw ty values)
        C.DrawFrequency alternatives -> FrequencyDraw <$> mapM (\(weight,child) -> (,) weight <$> visit child) alternatives
        C.DrawSuchThat inner binder predicate limit -> FilterDraw <$> visit inner <*> pure binder <*> pure predicate <*> pure limit
        C.DrawBind binder from rest -> BindDraw binder <$> visit from <*> visit rest
      let identities = nub (free step)
      captures <- lift (mapM capture identities)
      -- Free type/index variables name lexical parameters, not helper
      -- value arguments. Keep those references distinct when normalizing
      -- value binders for sharing.
      let typeReferences = nub (concatMap variables (map C.binderType captures ++ stepTypes step))
          key = semanticBytes (encode resolver (typeReferences, captures, step))
      (known, nodes) <- get
      case M.lookup key known of
        Just number -> pure (DrawCall number identities)
        Nothing -> do
          let number = length nodes
          put (M.insert key number known, nodes ++ [DrawNode number captures step])
          pure (DrawCall number identities)
    free step = case step of
      AnyDraw _ (Just q) -> without (C.quantifiedBinder q) (concatMap C.freeBinders
        (C.quantifiedPredicates q ++ map snd (C.quantifiedBounds q)))
      AnyDraw ty Nothing | ty == C.binderType (generatorBinder requirement) ->
        without (generatorBinder requirement) (concatMap C.freeBinders
          (generatorPredicates requirement ++ map snd (generatorBounds requirement) ++ generatorHints requirement ++
           [indexedTarget index | Just index <- [generatorIndex requirement]]))
      AnyDraw _ Nothing -> []
      OneOfDraw _ values -> concatMap C.freeBinders values
      FrequencyDraw alternatives -> concatMap (drawArguments . snd) alternatives
      FilterDraw inner binder predicate _ -> drawArguments inner ++ without binder (C.freeBinders predicate)
      BindDraw binder from rest -> drawArguments from ++ without binder (drawArguments rest)
    stepTypes step = case step of
      AnyDraw ty aim -> ty : maybe [] (\q -> C.binderType (C.quantifiedBinder q) :
        concatMap expressionTypes (C.quantifiedPredicates q ++ map snd (C.quantifiedBounds q))) aim
      OneOfDraw ty expressions -> ty : concatMap expressionTypes expressions
      FrequencyDraw _ -> []
      FilterDraw _ binder predicate _ -> C.binderType binder : expressionTypes predicate
      BindDraw binder _ _ -> [C.binderType binder]
    expressionTypes expression = C.expressionType expression : concatMap expressionTypes (C.children expression)
    variables ty = case ty of
      C.TypeVariable identity -> [C.idText identity]
      C.Arrow a b -> variables a ++ variables b
      C.Constructor _ arguments -> concatMap argumentVariables arguments
    argumentVariables argument = case argument of
      C.TypeArgument ty -> variables ty
      C.IndexArgument (C.IndexVariable identity) -> [C.idText identity]
      C.IndexArgument _ -> []
    without binder = filter (/= C.binderId binder)
    binders draw = case draw of
      C.DrawAny _ aim -> maybe [] (pure . C.quantifiedBinder) aim
      C.DrawOneOf _ _ -> []
      C.DrawFrequency alternatives -> concatMap (binders . snd) alternatives
      C.DrawSuchThat inner binder _ _ -> binder : binders inner
      C.DrawBind binder from rest -> binder : binders from ++ binders rest
