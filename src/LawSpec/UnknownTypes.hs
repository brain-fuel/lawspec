-- | A data declaration that names a type nothing in its unit provides is
-- refused where it names it. The type registry would refuse the program too,
-- but only when its first consumer builds it, and that consumer is whichever
-- field restriction is checked first, in any unit.
module LawSpec.UnknownTypes (unknownFieldTypes) where

import Data.List (intercalate, nub)
import Data.Maybe (listToMaybe)
import qualified Data.Set as S
import LawSpec.Builtins (builtinSource, builtinUnits, clockSource)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Types (builtinDataDeclarations)
import LawSpec.Model
import LawSpec.Scalar (primitiveName, primitives)
import LawSpec.SourceOrigins (SourceOriginMap, originalLocation, sourceCoordinatesFor)
import LawSpec.SourceTokens (Token(..), TokenKind(..), sourceTokens)

-- | The headers are those of the units' data types, in order
-- (LawSpec.Data.dataDeclarationHeaders): a name they leave unresolved is one
-- that import resolution found in no scope of its unit. The diagnostic is at
-- the name's use. It says which unit declares the name and what to write in
-- the import, when a unit of the program does.
unknownFieldTypes :: [SourceOriginMap] -> [Source] -> [(String, [Import])] -> [Unit] -> [C.DataDeclaration]
  -> Either [Diagnostic] ()
unknownFieldTypes origins sources imports units headers = case found of
  [] -> Right ()
  diagnostics -> Left diagnostics
  where
    known = S.fromList (map primitiveName primitives ++ ["Nullable", "Optional"] ++
      map (C.idText . C.dataId) (builtinDataDeclarations ++ headers))
    found = nub
      [ diagnostic unit (C.constructorOrigin constructor) name
      | ((unit, _), header) <- zip [(unit, declaration) | unit <- units, declaration <- dataTypes unit] headers
      , constructor <- C.dataConstructors header
      , ty <- map C.binderType (C.constructorFields constructor) ++ map snd (C.constructorEquations constructor)
      , name <- typeNames ty, name `S.notMember` known ] ++
      -- A header leaves an anonymous record payload as a placeholder, so its
      -- fields are read from the declaration.
      [ diagnostic unit (C.constructorOrigin constructor) name
      | ((unit, declaration), header) <- zip [(unit, declaration) | unit <- units, declaration <- dataTypes unit] headers
      , (source, constructor) <- zip (dataTypeConstructors declaration) (C.dataConstructors header)
      , (_, ty) <- dataConstructorFields source
      , name <- payloadNames False ty, name `S.notMember` known, name `notElem` dataTypeParameters declaration ]
    -- The type names inside a record written in place.
    payloadNames inside ty = case ty of
      RecordShape fields -> concatMap (payloadNames True . recordFieldType) fields
      Named name -> [name | inside]
      Applied name argument -> [name | inside] ++ payloadNames inside argument
      Application name arguments -> [name | inside] ++ concatMap (payloadNames inside) arguments
      Arrow argument result -> payloadNames inside argument ++ payloadNames inside result
      Refined _ base _ -> payloadNames inside base
      Qualified _ base -> payloadNames inside base
      CheckedType _ base -> payloadNames inside base
      _ -> []
    typeNames ty = case ty of
      C.Constructor name arguments -> name : concat [typeNames argument | C.TypeArgument argument <- arguments]
      C.Arrow argument result -> typeNames argument ++ typeNames result
      C.TypeVariable _ -> []
    diagnostic unit origin name =
      let range = case origin of
            C.SourceSpan declared -> Just declared
            _ -> Nothing
          location = maybe Nothing (\declared -> Just (maybe (spanStart declared) id (useWithin declared name))) range
          declaring = nub [unitName provider | provider <- units, unitName provider /= unitName unit
            , name `elem` (map dataTypeName (dataTypes provider) ++ map refinementName (refinements provider))]
          providers = if null declaring then builtinProviders name else declaring
      in case providers of
        [] -> Diagnostic "data-type" ("unknown type: " ++ name ++ ". No unit of the program declares it, and it is not a built-in type") location
        _ -> Diagnostic "import" (name ++ " is not imported. " ++ intercalate "; " (map (advice unit name) providers)) location
    -- What to write for one unit that declares the name.
    advice unit name provider =
      case [item | item <- maybe [] id (lookup (unitName unit) imports), importUnit item == provider, authored item] of
        item : _ ->
          provider ++ " declares it: add it to the import list (import " ++ provider ++ renamed item
            ++ " (" ++ intercalate ", " (importItems item ++ [name]) ++ ")) or write " ++ importAlias item ++ "." ++ name
        [] -> provider ++ " declares it: write import " ++ provider ++ " (" ++ name ++ ")"
    -- A built-in unit joins a program only when a unit imports it, so the
    -- name is looked up in its source.
    builtinProviders name =
      [ provider | (provider, text) <- ("lawspec.time", clockSource) : [(provider, builtinSource provider) | provider <- builtinUnits]
      , any (\declaration -> take 2 (words declaration) `elem` [["wrapper", name], ["type", name]]) (lines text) ]
    renamed item = if importAlias item == lastSegment (importUnit item) then "" else " as " ++ importAlias item
    lastSegment = reverse . takeWhile (/= '.') . reverse
    -- An implicit import of a built-in unit has a span in that unit.
    authored item = take 1 (file (spanStart (importSpan item))) /= "<"
    -- Where the declaration writes the name as a word of its own.
    useWithin declared name = listToMaybe
      [ location
      | source <- sources, path source == file (spanStart declared)
      , let coordinates = sourceCoordinatesFor origins source
      , (before, token) <- withPrevious (filter ((`notElem` [TriviaToken, CommentToken]) . tokenKind) (sourceTokens (content source)))
      , tokenKind token == WordToken, tokenText token == name, before /= Just "."
      , Just location <- [originalLocation coordinates (tokenOffset token)]
      , file location == file (spanStart declared)
      , (line location, column location) >= (line (spanStart declared), column (spanStart declared))
      , (line location, column location) <= (line (spanEnd declared), column (spanEnd declared)) ]
    withPrevious tokens = zip (Nothing : map (Just . tokenText) tokens) tokens
