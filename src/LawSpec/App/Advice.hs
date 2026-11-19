-- | The authoring advice that advise, check and generate report, ported
-- from the Node CLI's authoringReport and authoring.mjs: the compiler's own
-- findings, and for each selected target the analysis of its native
-- sources (LawSpec.Authoring.Native), which the Haskell extractors read.
-- ref:DEC-authoring-advisories ref:DEC-haskell-application-port
module LawSpec.App.Advice
  ( authoringReport,
    printAdvice,
    nativeExtensions,
    collectNativeSources,
  )
where

import Control.Monad (forM, forM_, unless)
import Data.Char (isSpace)
import Data.List (intercalate, isPrefixOf, sortBy)
import Data.Maybe (isJust)
import qualified Data.Set as S
import qualified Data.Text as T
import LawSpec.App.Command
import LawSpec.App.Compiler (call, diagnostics)
import LawSpec.App.Files (compareUtf16)
import LawSpec.App.Json
import LawSpec.Authoring.Extract (languageOf)
import LawSpec.Authoring.Native (Check (..), Finding (..), analyze, bindingsOf, checkScope, findingSuggestion, inspectionOf)
import LawSpec.Authoring.Syntax (Source (..))
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, relative)

-- | authoring.mjs extensions: the native sources collectNativeSources reads.
nativeExtensions :: [String]
nativeExtensions =
  [".java", ".py", ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx", ".jsx", ".go", ".hs", ".lhs", ".kt", ".kts", ".rs", ".erl", ".hrl", ".ex", ".exs", ".gleam", ".fs", ".fsx", ".fsi", ".cs", ".scala", ".groovy", ".clj", ".cljc", ".swift", ".pl"]

-- | authoring.mjs collectNativeSources: every native source below the
-- root, by its path from the root, outside dependencies, build products,
-- hidden directories and vendored code; a symbolic link fails the walk.
collectNativeSources :: (Monad m) => FilePath -> Command m [Source]
collectNativeSources root = walk root
  where
    excluded = ["node_modules", ".git", ".stack-work", ".artifacts", "vendor", "target", "build", "dist", "bin", "obj", ".venv", "venv", "__pycache__", ".gradle", ".lawspec"]
    walk directory = do
      entries <- effect (nodeFailure "scandir" directory) (ListDirectory directory)
      fmap concat . forM (sortBy (\a b -> compareUtf16 (entryName a) (entryName b)) entries) $ \entry -> do
        let file = join directory (entryName entry)
        case entryKind entry of
          SymbolicLinkKind -> failWith ("Native source symlink requires an explicit source selection: " ++ relative root file)
          DirectoryKind
            | not ("." `isPrefixOf` entryName entry) && entryName entry `notElem` excluded -> walk file
            | otherwise -> pure []
          FileKind
            | isJust (languageOf file) -> do
                bytes <- effect (nodeFailure "open" file) (ReadFile file)
                pure [Source (relative root file) (T.pack (fromUtf8 bytes))]
          _ -> pure []

-- | The Node CLI's authoringReport for the selected targets, given the
-- shared input and each target's request fields. Every target must be an
-- artifact target, or none may be selected.
authoringReport :: (Monad m) => Bool -> Json -> Json -> [(String, FilePath, [(String, Json)])] -> Command m Json
authoringReport json config input selected = do
  let exceptions = maybe (JArray []) id (member "authoringExceptions" config)
  reports <-
    if null selected
      then do
        result <- call "advise" (jsObject (members input ++ [("advice", JBool True)])) >>= diagnostics json
        report <- settle (maybe (JObject [("findings", JArray []), ("checks", JArray [])]) id (member "advice" result)) exceptions
        pure [report]
      else forM selected $ \(language, root, fields) -> do
        collected <- recover (Right <$> collectNativeSources root) (pure . Left . failureMessage)
        case collected of
          Left reason ->
            pure (JObject [("findings", JArray []), ("checks", JArray [JObject [("rule", JString "native-sources"), ("status", JString "incomplete"), ("target", JString language), ("reason", JString reason)]]), ("ok", JBool False)])
          Right sources -> do
            result <- call "inspect" (jsObject (members input ++ [("cacheAdvisory", JBool True)] ++ fields ++ [("advice", JBool True)]))
            case member "diagnostics" result of
              Just (JArray items@(_ : _)) ->
                pure
                  ( JObject
                      [ ("findings", JArray []),
                        ( "checks",
                          JArray
                            [ JObject
                                [ ("rule", JString "native-interface"),
                                  ("target", JString language),
                                  ("status", JString "incomplete"),
                                  ("reason", JString (intercalate "; " [maybe "undefined" jsString (member "message" d) | d <- items]))
                                ]
                            ]
                        ),
                        ("ok", JBool False)
                      ]
                  )
              _ -> do
                let report = maybe (JObject [("findings", JArray []), ("checks", JArray [])]) id (member "advice" result)
                    (findings, checks) =
                      analyze
                        language
                        (inspectionOf (toValue result))
                        (bindingsOf (toValue (jsObject fields)))
                        (Just (map Just sources))
                    report' =
                      setMember "checks" (JArray (list "checks" report ++ map (checkJson language) checks)) $
                        setMember "findings" (JArray (list "findings" report ++ map (findingJson language) findings)) report
                settle report' exceptions
  settle
    ( JObject
        [ ("findings", JArray (unique (concatMap (list "findings") reports))),
          ("checks", JArray (unique (concatMap (list "checks") reports)))
        ]
    )
    exceptions
  where
    list key value = maybe [] id (member key value >>= arrayOf)
    -- Native rows in authoring.mjs's member order.
    findingJson language finding =
      JObject
        [ ("rule", JString (T.unpack (findingRule finding))),
          ("target", JString language),
          ("path", JString (findingPath finding)),
          ("declaration", JString (T.unpack (findingDeclaration finding))),
          ("line", integer (fromIntegral (findingLine finding))),
          ("severity", JString "warning"),
          ("status", JString "unresolved"),
          ("message", JString (T.unpack (findingMessage finding))),
          ("suggestion", JString (T.unpack findingSuggestion))
        ]
    checkJson language check =
      JObject
        ( [("rule", JString (T.unpack (checkRule check))), ("target", JString language)]
            ++ [("path", JString path) | Just path <- [checkPath check]]
            ++ [("status", JString (T.unpack (checkStatus check)))]
            ++ [("reason", JString (T.unpack reason)) | Just reason <- [checkReason check]]
            ++ [("scope", JString (T.unpack checkScope)) | checkScoped check]
        )
    unique = go S.empty
      where
        go _ [] = []
        go seen (row : rest)
          | S.member (stringify row) seen = go seen rest
          | otherwise = row : go (S.insert (stringify row) seen) rest

-- | authoring.mjs settleAdvice.
settle :: (Monad m) => Json -> Json -> Command m Json
settle advice exceptions = do
  entries <- case exceptions of
    JArray items | all valid items -> pure items
    _ -> failWith "Authoring exceptions require a declaration, rule and nonempty reason"
  let findings =
        [ case [e | e <- entries, member "declaration" e == member "declaration" finding, member "rule" e == member "rule" finding] of
            e : _ -> setMember "reason" (maybe JNull id (member "reason" e)) (setMember "status" (JString "excepted") finding)
            [] -> finding
        | finding <- maybe [] id (member "findings" advice >>= arrayOf)
        ]
      checks = maybe [] id (member "checks" advice >>= arrayOf)
      ok =
        not (any (\f -> member "status" f == Just (JString "unresolved")) findings)
          && all (\c -> member "status" c `elem` [Just (JString "complete"), Just (JString "not-applicable")]) checks
  pure (setMember "ok" (JBool ok) (setMember "findings" (JArray findings) advice))
  where
    valid e = all (nonblank . (`member` e)) ["declaration", "reason", "rule"]
    nonblank (Just (JString text)) = not (all isSpace text)
    nonblank _ = False

-- | printAdvice: unresolved findings and incomplete checks on standard error.
printAdvice :: (Monad m) => Json -> Command m ()
printAdvice report = do
  forM_ (maybe [] id (member "findings" report >>= arrayOf)) $ \finding ->
    unless (member "status" finding /= Just (JString "unresolved")) $
      printError ("warning " ++ text "rule" finding ++ ": " ++ text "declaration" finding ++ ": " ++ text "message" finding)
  forM_ (maybe [] id (member "checks" report >>= arrayOf)) $ \check ->
    unless (member "status" check `elem` [Just (JString "complete"), Just (JString "not-applicable")]) $
      printError
        ( "advice " ++ text "status" check ++ ": "
            ++ maybe "source" jsString (firstDefined [member "declaration" check, member "path" check, member "target" check])
            ++ ": "
            ++ text "reason" check
        )
  where
    text key value = maybe "undefined" jsString (member key value)
    firstDefined values = case [v | Just v <- values, v /= JNull] of
      v : _ -> Just v
      [] -> Nothing
