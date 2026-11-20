-- | Native authoring advice for a program target: authoring.mjs
-- analyzeNative, over the facts the Haskell extractors read from native
-- sources (LawSpec.Authoring.Extract). It compares the application's
-- sources with the compiler's generation plan and reports review
-- candidates: copied generated files, local models that compete with
-- generated ones, adapters that refer to them and manual conversions.
-- Findings are review candidates, not proof of semantic or nominal
-- equivalence. ref:DEC-authoring-advisories
module LawSpec.Authoring.Native
  ( -- * Inputs
    Inspection (..),
    PlannedFile (..),
    Binding (..),
    inspectionOf,
    bindingsOf,
    sourcesOf,

    -- * Results
    Finding (..),
    Check (..),
    analyze,
    findingSuggestion,
    checkScope,

    -- * Composite targets
    hostLanguages,
  )
where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import LawSpec.Authoring.Extract (extract, languageOf)
import LawSpec.Authoring.Syntax (Declaration (..), Facts (..), Source (..))
import LawSpec.Digest (digest, digestHex)
import LawSpec.Targets (artifactTargets, programTargets)

-- | A file of the generation plan.
data PlannedFile = PlannedFile
  { plannedPath :: FilePath,
    plannedContent :: Text,
    plannedOwnership :: Maybe Text
  }
  deriving (Eq, Show)

-- | What analysis reads from an inspect result: the planned files, the
-- interface's generated names and accepted digests, and the record shapes
-- of the program's data types.
data Inspection = Inspection
  { inspectionFiles :: [PlannedFile],
    -- | Each unbound interface declaration's native name and constructor
    -- names.
    inspectionNames :: [Text],
    inspectionDigests :: [(FilePath, [String])],
    inspectionShapes :: [[Text]]
  }
  deriving (Eq, Show)

-- | A checked native binding of a model: its type (as JavaScript shows it
-- in a message) and the native references of the type and constructors.
data Binding = Binding
  { bindingType :: Text,
    bindingReferences :: [[Text]]
  }
  deriving (Eq, Show)

data Finding = Finding
  { findingRule :: Text,
    findingPath :: FilePath,
    findingDeclaration :: Text,
    findingLine :: Int,
    findingMessage :: Text
  }
  deriving (Eq, Show)

-- | A check's status. A rule-level check carries the scope; the others
-- name a path or nothing.
data Check = Check
  { checkRule :: Text,
    checkPath :: Maybe FilePath,
    checkStatus :: Text,
    checkReason :: Maybe Text,
    checkScoped :: Bool
  }
  deriving (Eq, Show)

findingSuggestion :: Text
findingSuggestion =
  "Migrate to the generated interface; retain an application model through explicit checked bindings/codecs, or a declaration-scoped exception with a reason."

checkScope :: Text
checkScope = "declared native syntax; no whole-program type equivalence"

-- | Composite targets analyze their emitted host language as well.
hostLanguages :: String -> [String]
hostLanguages target = fromMaybe [target] (lookup target table)
  where
    table =
      [ ("javascript", ["javascript", "typescript", "tsx"]),
        ("typescript", ["typescript", "javascript", "tsx"]),
        ("haskell", ["haskell", "literate-haskell"]),
        ("kotlin", ["kotlin", "java"]),
        ("scala", ["scala", "java"]),
        ("groovy", ["groovy", "java"]),
        ("clojure", ["clojure", "java"]),
        ("elixir", ["elixir", "erlang"]),
        ("gleam", ["gleam", "erlang"]),
        ("csharp", ["csharp", "fsharp"]),
        ("prolog", ["prolog", "python"])
      ]

-- | An inspect result as analysis reads it; absent members read as empty,
-- as they do in JavaScript.
inspectionOf :: Value -> Inspection
inspectionOf result =
  Inspection
    { inspectionFiles = [file | Object o <- array "files" result, Just file <- [planned o]],
      inspectionNames =
        concat
          [ [n | Just (String n) <- [KM.lookup "nativeName" o]]
              ++ [n | Object c <- array "constructors" (Object o), Just (String n) <- [KM.lookup "allocatedName" c]]
          | Object o <- array "data" interface',
            KM.lookup "ownership" o /= Just (String "bound")
          ],
      inspectionDigests =
        [ (T.unpack path, [T.unpack d | String d <- array "sha256" (Object o)])
        | Object o <- array "generatedDigests" interface',
          Just (String path) <- [KM.lookup "path" o]
        ],
      inspectionShapes =
        [ sortUtf16 [fromMaybe "undefined" (textOf =<< KM.lookup "name" f) | Object f <- array "fields" constructor]
        | Object t <- array "dataTypes" result,
          [constructor] <- [array "constructors" (Object t)]
        ]
    }
  where
    interface' = fromMaybe Null (field "interface" result)
    planned o = case (KM.lookup "path" o, KM.lookup "content" o) of
      (Just (String path), Just (String content)) ->
        Just (PlannedFile (T.unpack path) content (textOf =<< KM.lookup "ownership" o))
      _ -> Nothing

-- | input.nativeBindings?.types: each binding's references, as arrays.
bindingsOf :: Value -> [Binding]
bindingsOf request =
  [ Binding
      (maybe "undefined" display (KM.lookup "type" o))
      [ map display (toList parts)
      | Just (Array parts) <- KM.lookup "native" o : [KM.lookup "native" c | Object c <- array "constructors" (Object o)]
      ]
  | Object o <- array "types" (fromMaybe Null (field "nativeBindings" request))
  ]
  where
    display (String text) = text
    display value = T.pack (show value)

-- | The native sources of a request: Nothing when they are not an array,
-- and a malformed entry as Nothing.
sourcesOf :: Value -> Maybe [Maybe Source]
sourcesOf value = case value of
  Array items -> Just (map source (toList items))
  _ -> Nothing
  where
    source (Object o)
      | Just (String path) <- KM.lookup "path" o,
        Just (String content) <- KM.lookup "content" o =
          Just (Source (T.unpack path) content)
    source _ = Nothing

field :: Text -> Value -> Maybe Value
field key (Object o) = KM.lookup (K.fromText key) o
field _ _ = Nothing

array :: Text -> Value -> [Value]
array key value = case field key value of
  Just (Array items) -> toList items
  _ -> []

textOf :: Value -> Maybe Text
textOf (String text) = Just text
textOf _ = Nothing

-- | Array.prototype.sort's default order: UTF-16 code units.
sortUtf16 :: [Text] -> [Text]
sortUtf16 = map snd . sort . map (\t -> (utf16 t, t))
  where
    utf16 = concatMap units . T.unpack
    units c
      | fromEnum c < 0x10000 = [fromEnum c]
      | otherwise = let v = fromEnum c - 0x10000 in [0xD800 + v `div` 0x400, 0xDC00 + v `mod` 0x400]

-- | The findings and checks of a target's native sources.
analyze :: String -> Inspection -> [Binding] -> Maybe [Maybe Source] -> ([Finding], [Check])
analyze target inspection bindings supplied
  | target `elem` artifactTargets = ([], ruleChecks "not-applicable" (Just "Artifact target has no native application model"))
  | target `notElem` programTargets = ([], ruleChecks "unsupported" (Just "Unknown program target"))
  | otherwise = case supplied of
      Nothing -> ([], ruleChecks "incomplete" (Just "Native sources were not supplied"))
      Just entries -> case sequence entries of
        Nothing -> ([], ruleChecks "incomplete" (Just "Malformed native source"))
        Just sources -> sourcesAnalysis target inspection bindings sources

ruleChecks :: Text -> Maybe Text -> [Check]
ruleChecks status reason =
  [Check rule Nothing status reason True | rule <- ["copied-generated", "native-model", "adapter-identity", "manual-conversion"]]

-- | The state the source loop accumulates, in the order JavaScript fills it.
data Progress = Progress
  { progressFindings :: [Finding],
    progressChecks :: [Check],
    progressIncomplete :: Bool,
    progressObserved :: S.Set Text
  }

sourcesAnalysis :: String -> Inspection -> [Binding] -> [Source] -> ([Finding], [Check])
sourcesAnalysis target inspection bindings sources =
  let final = foldl' visit afterBaselines sources
      unobserved = [b | b <- bindings, not (S.member (bindingType b) (progressObserved final))]
      checks =
        reverse (progressChecks final)
          ++ [ Check "native-binding-reference" Nothing "incomplete" (Just ("Bound model " <> bindingType b <> " was not resolved to a declaration in the supplied source inventory")) False
             | b <- unobserved
             ]
      incomplete = progressIncomplete final || not (null unobserved)
   in ( reverse (progressFindings final),
        checks
          ++ ruleChecks
            (if incomplete then "incomplete" else "complete")
            (if incomplete then Just "Some selected syntax could not be analyzed" else Nothing)
      )
  where
    files = inspectionFiles inspection
    known path = lookup path (reverse [(plannedPath f, f) | f <- files])
    accepted = M.fromList [(path, S.fromList digests) | (path, digests) <- inspectionDigests inspection]
    rawCopies =
      M.fromList
        ( [(sha (plannedContent f), plannedPath f) | f <- files, plannedOwnership f == Just "generated", isJust (languageOf (plannedPath f))]
            ++ [(hash, path) | (path, digests) <- insertionOrder (inspectionDigests inspection), hash <- digests]
        )
    relevant =
      [ f
      | f <- files,
        isJust (languageOf (plannedPath f)),
        plannedOwnership f == Just "user"
          || (any (`isInfixOf` lower (plannedPath f)) ["data", "types", "schema"] && not (any (`isInfixOf` lower (plannedPath f)) ["runtime", "testing"]))
      ]
    lower = map toLowerAscii
    -- The baselines: generated declarations by fingerprint and model names,
    -- and the names adapters declare.
    (baselineChecks, baselines, generatedNames, adapterNames) = foldl' baseline ([], M.empty, S.empty, S.empty) relevant
    baseline (checks, prints, names', adapters) file =
      let parsed = extract (plannedPath file) (plannedContent file)
       in if factsStatus parsed /= "complete"
            then (Check "native-baseline" (Just (plannedPath file)) (factsStatus parsed) (factsReason parsed) False : checks, prints, names', adapters)
            else
              foldl'
                ( \(c, p, n, a) d ->
                    if plannedOwnership file == Just "user"
                      then (c, p, n, if declarationModel d then a else S.insert (declarationName d) a)
                      else (c, M.insert (declarationFingerprint d) (plannedPath file) p, if declarationModel d then S.insert (declarationName d) n else n, a)
                )
                (checks, prints, names', adapters)
                (factsDeclarations parsed)
    names = foldl' (flip S.insert) generatedNames (inspectionNames inspection)
    afterBaselines = Progress [] baselineChecks (not (null baselineChecks)) S.empty
    modulePaths = [withoutExtension path | path <- map plannedPath files ++ map sourcePath sources]
    pathCheck rule path status reason = Check rule (Just path) status (Just reason) False
    visit progress source =
      let path = sourcePath source
          language = languageOf path
          add rule name line message p = p {progressFindings = Finding rule path (T.pack path <> "::" <> name) line message : progressFindings p}
          check c p = p {progressChecks = c : progressChecks p}
          incomplete p = p {progressIncomplete = True}
       in case language of
            Just l
              | l `notElem` hostLanguages target ->
                  check (pathCheck "native-language" path "not-applicable" (T.pack l <> " is outside the selected target's native languages")) progress
            _ -> case known path of
              Just file
                | plannedOwnership file == Just "generated" ->
                    if plannedContent file /= sourceContent source
                      && not (maybe False (S.member (sha (sourceContent source))) (M.lookup path accepted))
                      then
                        let original = extract (plannedPath file) (plannedContent file)
                            actual = extract path (sourceContent source)
                         in if factsStatus original /= "complete" || factsStatus actual /= "complete"
                              then incomplete (check (pathCheck "generated-ownership" path "incomplete" "Cannot compare changed generated syntax with the current plan") progress)
                              else
                                if factsFingerprint original /= factsFingerprint actual
                                  then add "copied-generated" "<file>" 1 "Compiler-owned source differs from the generation plan." progress
                                  else progress
                      else progress
              _ -> case M.lookup (sha (sourceContent source)) rawCopies of
                Just copy -> add "copied-generated" "<file>" 1 ("This file copies compiler-owned " <> T.pack copy <> ".") progress
                Nothing -> declarations progress source path add check incomplete
    declarations progress source path add check incomplete =
      let parsed = extract path (sourceContent source)
       in if factsStatus parsed /= "complete"
            then incomplete (check (Check "native-parse" (Just path) (factsStatus parsed) (factsReason parsed) False) progress)
            else
              let limited = foldl' (\p reason -> incomplete (check (Check "native-construct" (Just path) "unsupported" (Just reason) False) p)) progress (factsLimits parsed)
                  referenced = foldl' (reference path) limited (factsImports parsed)
                  (bound, observed) = boundDeclarations path parsed (progressObserved referenced)
                  competitors = S.fromList [declarationName d | (d, False) <- zip (factsDeclarations parsed) bound, competing d]
                  models =
                    foldl'
                      ( \p (d, isBound) ->
                          if isBound || not (competing d)
                            then p
                            else add "native-model" (declarationName d) (declarationLine d) (modelMessage d) p
                      )
                      referenced {progressObserved = observed}
                      (zip (factsDeclarations parsed) bound)
                  reviewed =
                    foldl'
                      ( \p d ->
                          let identifiers = declarationIdentifiers d
                              adapter =
                                if S.member (declarationName d) adapterNames && any (`S.member` competitors) identifiers
                                  then add "adapter-identity" (declarationName d) (declarationLine d) "Adapter refers to a competing local model; check the generated signature and nominal identity."
                                  else id
                              conversion =
                                if any (`S.member` names) identifiers && any (`S.member` competitors) identifiers && not (S.member (declarationName d) competitors)
                                  then add "manual-conversion" (declarationName d) (declarationLine d) "This function mentions a generated model name and a competing local declaration; review the boundary for migration or supported native bindings."
                                  else id
                           in conversion (adapter p)
                      )
                      models
                      (factsDeclarations parsed)
               in reviewed
      where
        competing d = isJust (M.lookup (declarationFingerprint d) baselines) || termShape d || S.member (declarationName d) names
        termShape d = not (null (declarationFields d)) && declarationFields d `elem` inspectionShapes inspection
        modelMessage d
          | termShape d = "Native dict fields match a generated record schema; review the constructor identity and meaning."
          | Just clone <- M.lookup (declarationFingerprint d) baselines = "Declaration matches a supported generated syntax shape in " <> T.pack clone <> "; review its meaning and ownership."
          | otherwise = "Declaration shares a generated model name; review identity and domain meaning."
    reference path progress imported =
      let normalized = stripStar (replaceSeparators imported)
          relative' = withoutExtension (posixNormalize (posixJoin (posixDirname path) (T.unpack imported)))
          -- A module and the members it declares: a.b.C.D imports a member
          -- of a.b.C (a nested class, a Rust item) when a.b.C is a module.
          -- Rust paths also start at crate, self, super or the crate's name.
          segments = splitOn '/' normalized
          rooted = case segments of
            first : rest | first `elem` ["crate", "self", "super"] -> [rest]
            _ : rest | target == "rust" -> [segments, rest]
            _ -> [segments]
          candidates = [intercalate "/" (take n s) | s <- rooted, n <- [length s, length s - 1 .. 1]]
          module' m candidate =
            m == candidate
              || ("/" ++ candidate) `isSuffixOf` m
              || ("/" ++ candidate ++ "/mod") `isSuffixOf` m
              || m == candidate ++ "/__init__"
              || ("/" ++ candidate ++ "/__init__") `isSuffixOf` m
          resolved =
            standard target imported
              || any
                ( \m ->
                    m == relative'
                      || any (module' m) candidates
                      -- a package (Java, Scala, Kotlin) or a Swift module directory
                      || ("/" ++ normalized ++ "/") `isInfixOf` m
                      || (normalized ++ "/") `isPrefixOf` m
                )
                modulePaths
              -- The generated Package.swift declares the App module at src/.
              || (target == "swift" && imported == "App" && any ("src/" `isPrefixOf`) modulePaths)
       in if resolved
            then progress
            else
              progress
                { progressIncomplete = True,
                  progressChecks = Check "native-reference" (Just path) "incomplete" (Just ("Import " <> imported <> " is outside the supplied/generated source inventory; identity resolution is incomplete")) False : progressChecks progress
                }
    -- Whether each declaration resolves to a checked binding, and the
    -- bindings observed so far (the first binding that matches is observed).
    boundDeclarations path parsed observed =
      let file = withoutExtension path
          declared = [T.unpack (T.replace "::" "/" (T.replace "." "/" m)) | m <- factsModules parsed]
          matches d binding = any (matching d) (bindingReferences binding)
          matching d ref = case reverse ref of
            [] -> False
            final : before ->
              let module' = intercalate "/" [T.unpack p | p <- reverse before, p /= "crate"]
               in (length ref > 1 && T.intercalate "." ref == declarationName d)
                    || ( final == declarationName d
                           && not (null module')
                           && ( file == module'
                                  || ("/" ++ module') `isSuffixOf` file
                                  || ("/" ++ module' ++ "/" ++ T.unpack final) `isSuffixOf` file
                                  || file == module' ++ "/" ++ T.unpack final
                                  || module' `elem` declared
                              )
                       )
          step (flags, seen) d = case [b | b <- bindings, matches d b] of
            b : _ -> (True : flags, S.insert (bindingType b) seen)
            [] -> (False : flags, seen)
          (flags', observed') = foldl' step ([], observed) (factsDeclarations parsed)
       in (reverse flags', observed')

-- | A JavaScript Map built from pairs: each key at its first position,
-- with its last value.
insertionOrder :: (Eq k) => [(k, v)] -> [(k, v)]
insertionOrder pairs = [(k, last [v | (k', v) <- pairs, k' == k]) | (k, _) <- firsts pairs []]
  where
    firsts [] _ = []
    firsts ((k, v) : rest) seen
      | k `elem` seen = firsts rest seen
      | otherwise = (k, v) : firsts rest (k : seen)

sha :: Text -> String
sha = digestHex . digest . T.encodeUtf8

toLowerAscii :: Char -> Char
toLowerAscii c
  | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c

-- | path.replace(/\.[^.]+$/, ''): everything from the last dot, when
-- something follows it.
withoutExtension :: FilePath -> FilePath
withoutExtension path = case break (== '.') (reverse path) of
  (_ : _, '.' : before) -> reverse before
  _ -> path

-- | imported.replace(/::|\./g, '/')
replaceSeparators :: Text -> String
replaceSeparators = T.unpack . T.replace "." "/" . T.replace "::" "/"

-- | .replace(/\/\*$/, '')
stripStar :: String -> String
stripStar text
  | "/*" `isSuffixOf` text = take (length text - 2) text
  | otherwise = text

-- | The standard libraries, and the testing libraries generated projects
-- declare, whose imports need no source. A Go import path whose first
-- element has no dot is the standard library's, by the go command's rule.
standard :: String -> Text -> Bool
standard target imported =
  root `elem` modules
    || any (`T.isPrefixOf` imported) prefixes
    || (target == "go" && not (T.any (== '.') (T.takeWhile (/= '/') imported)))
  where
    root = T.takeWhile (/= '.') imported
    modules =
      -- Python
      [ "builtins", "typing", "typing_extensions", "dataclasses", "functools", "fractions", "decimal", "math", "collections", "abc", "sys", "os", "pathlib", "threading", "json", "time", "warnings", "random", "itertools", "re", "enum", "datetime", "contextlib", "contextvars", "asyncio", "concurrent", "inspect", "io", "operator", "copy", "traceback", "unittest", "uuid", "hashlib", "struct", "string", "unicodedata", "numbers", "statistics", "heapq", "bisect", "base64", "zlib", "tempfile", "shutil", "subprocess", "signal", "weakref", "types", "textwrap", "secrets", "hypothesis", "pytest", "importlib",
        -- Swift
        "Foundation", "Testing", "XCTest", "PackageDescription", "Dispatch", "Darwin", "Glibc",
        -- Haskell
        "Prelude", "Hedgehog",
        -- the others
        "System", "std", "erlang", "qcheck", "fast-check", "proptest"
      ]
    prefixes =
      [ "node:", "java.", "javax.", "scala.", "kotlin.", "kotlinx.", "groovy.", "System.", "Microsoft.", "std::", "std.", "core::", "alloc::", "proptest::",
        "Data.", "Control.", "GHC.", "Test.", "gleam/", "Elixir.", "clojure.", "library(",
        "org.junit.", "spock.", "net.jqwik.", "org.jetbrains.jetCheck.", "io.kotest.", "FsCheck", "Xunit", "pgregory.net/rapid"
      ]

-- | Splits at a separator, keeping empty parts.
splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, _ : rest) -> part : splitOn separator rest
  (part, []) -> [part]

-- | path.posix.dirname.
posixDirname :: FilePath -> FilePath
posixDirname path =
  let trimmed = case reverse (dropWhile (== '/') (reverse path)) of
        [] | "/" `isPrefixOf` path -> "/"
        t -> t
   in if trimmed == "/"
        then "/"
        else case break (== '/') (reverse trimmed) of
          (_, []) -> "."
          (_, _ : before) -> case reverse (dropWhile (== '/') before) of
            [] -> "/"
            directory -> directory

-- | path.posix.join of two parts.
posixJoin :: FilePath -> FilePath -> FilePath
posixJoin left right = case filter (not . null) [left, right] of
  [] -> "."
  parts -> posixNormalize (intercalate "/" parts)

-- | path.posix.normalize: keeps a trailing separator, as Node does.
posixNormalize :: FilePath -> FilePath
posixNormalize "" = "."
posixNormalize path =
  let absolute = "/" `isPrefixOf` path
      trailing = "/" `isSuffixOf` path
      parts = reverse (foldl' step [] (filter (not . null) (splitOn path)))
      step kept "." = kept
      step kept ".." = case kept of
        top : rest | top /= ".." -> rest
        _ | absolute -> kept
        _ -> ".." : kept
      step kept part = part : kept
      body = intercalate "/" parts
      body'
        | null body && not absolute = "."
        | otherwise = body
      withTrailing = if trailing && not (null body) then body' ++ "/" else body'
   in if absolute then '/' : withTrailing else withTrailing
  where
    splitOn text = case break (== '/') text of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitOn rest
