-- | lawspec.json's bindings on Clojure. A bound function, constructor or
-- method is a Clojure function the unit's Java bridge calls in place of the
-- adapter's; a bound handler is a Clojure function returning a map of the
-- ability's operations, which a generated Java class presents as the
-- ability's interface; a bound failure is an ex-info whose :type is a
-- keyword, which becomes a failure constructor. Clojure binds no types and
-- no generators: a Clojure program uses the model's data.
-- ref:DEC-clojure-over-java
module LawSpec.Clojure.Bindings (ClojureBindings(..), noClojureBindings, splitBindings) where

import Data.Char (isAlphaNum, toUpper)
import Data.List (intercalate)
import qualified LawSpec.Core as C
import LawSpec.Common (Diagnostic(..))
import qualified LawSpec.NativeRequest as NB
import LawSpec.NativeBinding (NativeRef(..), ResolvedBindings(..))
import LawSpec.TargetNames (nativeName)
import LawSpec.Clojure.Bridge (kebab)

data ClojureBindings = ClojureBindings
  -- (unit, the Java adapter's method) to (namespace, function).
  { boundFunctions :: [((String, String), (String, String))]
  -- The ability's key, the generated class, and (namespace, function).
  , boundHandlers :: [(String, String, (String, String))]
  -- The ex-info's :type, the failure constructor, and whether it takes the
  -- ex-info's message.
  , boundFailures :: [(String, String, Bool)] }

noClojureBindings :: ClojureBindings
noClojureBindings = ClojureBindings [] [] []

-- | The bindings the Java model keeps (handlers, as generated classes), and
-- those the Clojure bridges take.
splitBindings :: NB.BindingPlan -> Either [Diagnostic] (NB.BindingPlan, ClojureBindings)
splitBindings plan = do
  let representations = NB.bindingRepresentations plan
  case (resolvedTypes representations, resolvedGenerators representations) of
    ([], []) -> pure ()
    _ -> Left [Diagnostic "native-binding" "Clojure binds functions, handlers and failures, not types or generators: a Clojure program uses the model's data" Nothing]
  let unitOf d = takeWhile (/= ':') (C.idText (C.declarationId d))
      javaName d = nativeName "java" (nativeName "clojure" (C.declarationName d))
      -- lawspec.json's names are identifiers: an underscore is Clojure's hyphen.
      target (NativeRef parts) = (intercalate "." (map hyphens (init parts)), hyphens (last parts))
      constructors = [(unitOf d, target r) | (d, NB.ConstructorCall r) <- NB.bindingCalls plan]
  calls <- mapM (\(d, call) -> case call of
      NB.ConstructorCall r -> pure ((unitOf d, javaName d), target r)
      NB.StaticCall r -> pure ((unitOf d, javaName d), target r)
      NB.MethodCall method -> case lookup (unitOf d) constructors of
        Just (ns, _) -> pure ((unitOf d, javaName d), (ns, kebab method))
        Nothing -> Left [Diagnostic "native-binding" ("Clojure finds a method's function in the namespace of its handle's constructor, and " ++ unitOf d ++ " binds none") Nothing])
    (NB.bindingCalls plan)
  let functions = [((unitOf d, javaName d), target r) | (d, r) <- NB.bindingFunctions plan] ++ calls
      handlers = [(C.idText key, className (C.idText key), target r) | (key, r) <- NB.bindingHandlers plan]
      failures = [ (intercalate "." (map hyphens (init (C.failureNative f))) ++ "/" ++ hyphens (last (C.failureNative f)), C.idText (C.failureConstructor f), C.failureMessage f)
                 | f <- NB.bindingFailures plan, not (null (C.failureNative f)) ]
      java = plan { NB.bindingRepresentations = ResolvedBindings [] [], NB.bindingFunctions = [], NB.bindingCalls = []
                  , NB.bindingFailures = []
                  , NB.bindingHandlers = [(key, NativeRef ["lawspec", "clojure", "bound", className (C.idText key)]) | (key, _) <- NB.bindingHandlers plan] }
  pure (java, ClojureBindings functions handlers failures)
  where
    hyphens = map (\c -> if c == '_' then '-' else c)
    -- example.till::ability::Drawer is ExampleTillDrawer.
    className key = concatMap capital (words (map (\c -> if isAlphaNum c then c else ' ') (dropAbility key)))
    dropAbility key = case breakOn "::ability::" key of
      (unit, Just ability) -> unit ++ " " ++ ability
      (whole, Nothing) -> whole
    capital (c : cs) = toUpper c : cs
    capital [] = []
    breakOn sep s = go "" s
      where
        go acc rest@(c : more)
          | take (length sep) rest == sep = (reverse acc, Just (drop (length sep) rest))
          | otherwise = go (c : acc) more
        go acc [] = (reverse acc, Nothing)
