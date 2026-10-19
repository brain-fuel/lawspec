-- | Resolve documentary links without adding executable import dependencies.
-- Linked propositions are never expanded, so documentary cycles are harmless.
module LawSpec.Documentary (resolveDocumentaryReferences) where

import LawSpec.Model
import LawSpec.PreludeNames (preludeDefinitionTarget)
import Control.Monad (forM, unless)
import Data.List (intercalate, nub, isPrefixOf)
import qualified Data.Map.Strict as M

data Kind = LawTarget | FunctionTarget deriving (Eq, Show)

resolveDocumentaryReferences :: Bool -> (String -> String -> String) -> (String -> String -> Maybe String)
  -> [(Unit, [Import])] -> Either [Diagnostic] [(Unit, [Import])]
resolveDocumentaryReferences canonical referenceUnit visible units = forM units $ \(u, imports) -> do
  linked <- forM (laws u) $ \law -> do
    refs <- mapM (resolve u) (references law)
    pure law { references = refs }
  pure (u { laws = linked }, imports)
  where
    table = M.fromList [(unitName u, (u, imports)) | (u, imports) <- units]
    failAt at message = Left [Diagnostic "reference" message (Just at)]
    resolve u reference = case reference of
      ExternalReference name resource -> pure (ExternalReference name resource)
      FunctionReference target -> FunctionReference <$> resolved u FunctionTarget target
      LawReference target selector -> do
        target' <- resolved u LawTarget target
        case (target', selector) of
          (ResolvedReferenceTarget link, Just (ReferenceNamed name)) -> do
            let entries = [r | (owner, _) <- units, unitName owner == documentaryUnit link,
                  law <- laws owner, lawName law == documentaryName link, r <- references law]
            unless (any (named name) entries) (failAt (sourceLocation target)
              ("law " ++ documentaryName link ++ " has no named reference " ++ name))
          _ -> pure ()
        pure (LawReference target' selector)
    named name (ExternalReference (Just label) _) = name == label
    named _ _ = False
    sourceLocation (ParsedReferenceTarget _ span) = spanStart span
    sourceLocation (ResolvedReferenceTarget target) = spanStart (documentarySpan target)
    resolved _ _ target@ResolvedReferenceTarget{} = pure target
    resolved u kind target@(ParsedReferenceTarget parts range) = do
      let at = sourceLocation target
      found <- lookupTarget [] at kind (unitName u) parts
      case nub found of
        [link] -> pure (ResolvedReferenceTarget link { documentaryReferenceSpan = range })
        [] -> failAt at ("unresolved " ++ kindText kind ++ " reference: " ++ intercalate "." parts)
        _ -> failAt at ("ambiguous " ++ kindText kind ++ " reference: " ++ intercalate "." parts ++ "; qualify its unit")
    kindText LawTarget = "law"
    kindText FunctionTarget = "function"
    lookupTarget seen at kind owner parts = case M.lookup owner table of
      Nothing -> pure []
      Just (u, imports) -> case parts of
        [name] | not (null (local kind u name)) -> pure (local kind u name)
        [name] -> do
          imported <- concat <$> mapM (\i -> exported seen at kind owner (importUnit i) name)
            [i | i <- imports, not (null (importUnit i)), listed kind name i]
          if null imported && owner /= "prelude"
            then exported seen at kind owner "prelude" name else pure imported
        alias : names@(_ : _) -> case [i | i <- imports, length names == 1,
            not (null (importUnit i)), importAlias i == alias] of
          is@(_ : _) -> concat <$> mapM (\i -> qualified seen at kind owner (importUnit i) names) is
          [] -> qualified seen at kind owner (referenceUnit owner (intercalate "." (init parts))) [last parts]
        _ -> pure []
    qualified seen at kind owner destination names = case names of
      [name] -> exported seen at kind owner destination name
      _ -> pure []
    exported seen at kind importer destination name = do
      maybe (pure ()) (failAt at) (visible importer destination)
      let key = (kind, destination, name)
      if key `elem` seen then pure [] else case M.lookup destination table of
        Nothing -> pure []
        Just (u, imports) ->
          if not (null (local kind u name)) then pure (local kind u name)
          else case (kind,destination,preludeDefinitionTarget canonical name) of
            (FunctionTarget,"prelude",Just (provider,definition)) ->
              exported (key : seen) at kind importer provider definition
            _ -> concat <$> mapM (lookupTarget (key : seen) at kind destination . itemParts imports . unquote)
              [item | i <- imports, null (importUnit i), item <- importItems i,
                itemKind kind item, itemBase imports (unquote item) == name]
    listed kind name i = any (\item -> itemKind kind item && unquote item == name) (importItems i)
    itemKind LawTarget item = take 1 item == "`" && take 1 (reverse item) == "`"
    itemKind FunctionTarget item = take 1 item /= "`"
    unquote ('`':rest) | not (null rest) && last rest == '`' = init rest
    unquote name = name
    -- Import/export lists have at most one alias; a dot in a phrase is never
    -- qualification. Match known aliases instead of splitting phrase bodies.
    itemParts imports item = case
      [(importAlias i, drop (length (importAlias i) + 1) item) | i <- imports,
        not (null (importUnit i)), (importAlias i ++ ".") `isPrefixOf` item] of
      (alias, name) : _ -> [alias, name]
      [] -> [item]
    itemBase imports = last . itemParts imports
    local LawTarget u name =
      [DocumentaryTarget (unitName u ++ "::law::" ++ escape (lawName law)) (unitName u) (lawName law) (pointSpan (location law)) (pointSpan (location law))
      | law <- laws u, lawName law == name]
    local FunctionTarget u name =
      [DocumentaryTarget (unitName u ++ "::" ++ name) (unitName u) name span span
      | definition <- functionDefinitions u, functionName definition == name, let span = functionSpan definition]
    escape = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])
