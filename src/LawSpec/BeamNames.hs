-- | The names generated BEAM code uses for what the specification names:
-- each checked definition's function, each ability's and handler's
-- functions, and each binder's variable, from their source names
-- (LawSpec.Naming). A collision gets _2, _3 in declaration order.
-- ref:DEC-readable-generated-names
module LawSpec.BeamNames
  ( nativeModuleAliases, erlangReserved, functionAtom, definitionEntries, abilityEntries
  , variableName, variables, generatedVariables, stubParameters, operationVariables
  ) where

import qualified LawSpec.Core as C
import LawSpec.Naming (NameKind(..), Casing(..), cased, nameWords, claimAll, scopeWith, readableDefinitionName, typeWords, localIdentifier, parameterNamesWith)
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

-- | A stub's parameters by the names its signature declares, or ones made
-- from their types (LawSpec.Naming): Erlang variables in PascalCase
-- (Int32_1), Elixir's and Gleam's in snake_case, clear of the names taken.
-- Nothing asks for the reference spelling, which each stub keeps as it
-- always wrote it. ref:DEC-generated-parameter-names
stubParameters :: String -> [String] -> C.ParameterNames -> [C.Type] -> Maybe [String]
stubParameters target taken declared types = case declared of
  C.PositionalParameters -> Nothing
  _ -> Just (parameterNamesWith (if target == "erlang" then Pascal else Snake) id taken "value" declared types)

-- | An operation's parameters where generated code passes them on beside a
-- handler: named as the operation declares or from their types, clear of
-- the handler's own variable. ref:DEC-generated-parameter-names
operationVariables :: String -> C.Ability -> String -> [String]
operationVariables target ability operation = case C.operationParameters ability operation of
  C.PositionalParameters -> [(if erlang then "Value" else "value") ++ show i | (i, _) <- zip [0 :: Int ..] types]
  declared -> parameterNamesWith (if erlang then Pascal else Snake) escape [if erlang then "Handler" else "handler"] "value" declared types
  where
    erlang = target == "erlang"
    -- An Erlang variable is never a reserved word; Elixir's and Gleam's
    -- words take a trailing underscore.
    escape name = if name `elem` reserved then name ++ "_" else name
    reserved = case target of
      "elixir" -> words "after and catch do else end false fn in nil not or rescue true when"
      "gleam" -> words "as assert auto case const delegate derive echo else fn if implement import let macro opaque panic pub test todo type use"
      _ -> []
    types = maybe [] (fst . C.functionType) (lookup operation (C.abilityOperations ability))

-- | The variables generated BEAM code binds itself; a source binder never
-- takes one of these names.
generatedVariables :: [String]
generatedVariables = words "Schema Symbols Values BaseSchema ExampleSchema Result Native Handler Context Resources"

-- | The alias a generated Gleam module imports each native module under:
-- native_ and the module's path (native_application_factory), numbered from
-- 2 where two paths spell alike.
nativeModuleAliases :: [[String]] -> [([String], String)]
nativeModuleAliases = go []
  where
    go _ [] = []
    go used (parts : rest) =
      let stem = "native_" ++ map (\c -> if c `elem` (['a' .. 'z'] ++ ['0' .. '9'] ++ "_") then c else '_') (concatMap (\(i, part) -> (if i == (0 :: Int) then "" else "_") ++ part) (zip [0 ..] parts))
          chosen = case [candidate | candidate <- stem : [stem ++ "_" ++ show n | n <- [2 :: Int ..]], candidate `notElem` used] of
            candidate : _ -> candidate
            [] -> stem
      in (parts, chosen) : go (chosen : used) rest
