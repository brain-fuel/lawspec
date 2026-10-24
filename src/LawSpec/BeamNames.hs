-- | The names generated BEAM code uses for what the specification names:
-- each checked definition's function, each ability's and handler's
-- functions, and each binder's variable, from their source names
-- (LawSpec.Naming). A collision gets _2, _3 in declaration order.
-- ref:DEC-readable-generated-names
module LawSpec.BeamNames
  ( erlangReserved, functionAtom, definitionEntries, abilityEntries
  , variableName, variables, generatedVariables
  ) where

import qualified LawSpec.Core as C
import LawSpec.Naming (NameKind(..), Casing(..), cased, nameWords, claimAll, scopeWith, readableDefinitionName, typeWords, localIdentifier)
import Data.Char (isDigit)
import Data.List (nub)

-- | Erlang's reserved words, and the function every module has.
erlangReserved :: [String]
erlangReserved = words "after begin case try cond catch andalso orelse end fun if let of receive when bnot not div rem band and bor bxor bsl bsr or xor maybe else module_info"

-- | A function's atom from source words: snake_case, a keyword escaped
-- with a trailing underscore.
functionAtom :: String -> String
functionAtom source = escaped (leading (cased Snake ws))
  where
    ws = case nameWords source of
      [] -> ["value"]
      found -> found
    leading name@(c : _) | isDigit c = "f" ++ name
    leading name = name
    escaped name = if name `elem` erlangReserved then name ++ "_" else name

-- | lawspec_definitions' function for every declaration: its name, or a
-- specialised copy's definition and argument types (count_list_int32).
definitionEntries :: [C.Unit] -> [(C.Id, String)]
definitionEntries units = zip (map C.declarationId declarations)
  (fst (claimAll (scopeWith erlangReserved) (map base declarations)))
  where
    declarations = concatMap C.unitDeclarations units
    base d = functionAtom (readableDefinitionName (C.declarationName d) (fst (C.functionType (C.declarationType d))))

-- | lawspec_abilities' functions for each ability (by its instance) and
-- each handler: their names, the ability's type arguments added, and
-- numbered names should two ever share a derived function.
abilityEntries :: [C.Ability] -> [C.Handler] -> ([(C.AbilityRef, String)], [(C.Id, String)])
abilityEntries abilities handlers
  | length derived == length (nub derived) = (zip (map C.abilityInstance abilities) abilityNames, zip (map C.handlerId handlers) handlerNames)
  | otherwise = ( [(C.abilityInstance a, "ability_" ++ show i) | (i, a) <- zip [0 :: Int ..] abilities]
                , [(C.handlerId h, "handler_" ++ show i) | (i, h) <- zip [0 :: Int ..] handlers] )
  where
    (names, _) = claimAll (scopeWith (erlangReserved ++ ["with_context"]))
      ([functionAtom (unwords (C.abilityName a : concatMap typeWords (C.abilityRefArguments (C.abilityInstance a)))) | a <- abilities] ++
       [functionAtom (C.handlerName h) | h <- handlers])
    (abilityNames, handlerNames) = splitAt (length abilities) names
    derived = "with_context" :
      [n ++ s | n <- abilityNames, s <- ["_parts", "_to_native", "_from_native", "_production", "_recording"]] ++
      [n ++ s | n <- handlerNames, s <- ["", "_native", "_state", "_set_state", "_typed_state", "_set_typed_state"]]

-- | An Erlang variable for a source binder: its words in PascalCase.
-- Compiler-made binders are named by what they hold.
variableName :: String -> String
variableName source = case cased Pascal (nameWords (localIdentifier "erlang" source)) of
  "" -> "Value"
  name@(c : _) | isDigit c -> "V" ++ name
  name -> name

-- | Variables for binders, unique among themselves and the names already
-- taken, in order.
variables :: [String] -> [String] -> [String]
variables taken sources = fst (claimAll (scopeWith taken) (map variableName sources))

-- | The variables generated BEAM code binds itself; a source binder never
-- takes one of these names.
generatedVariables :: [String]
generatedVariables = words "Schema Symbols Values BaseSchema ExampleSchema Result Native Handler Context Resources"
