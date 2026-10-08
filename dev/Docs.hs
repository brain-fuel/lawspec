{-# LANGUAGE NoOverloadedStrings, ScopedTypeVariables #-}
-- | The documentation site: docs/ rendered through templates/site/ into a static
-- site with an in-browser compiler, ready for any static host (Cloudflare
-- Pages: see docs/how-to/contribute.md), split by Diátaxis. ref:DEC-diataxis-docs
--
--   lawspec-dev docs --out <dir>   build the site (needs npm/core.wasm)
--   lawspec-dev docs --check       compile every snippet and check every link
--
-- Every page begins with front matter naming its id, its Diátaxis kind and its
-- title (the Folio form canon reads); the title is the page's one home.
-- ref:DEC-page-titles-in-front-matter
-- docs/nav.json orders the pages: [{"path"} | {"title", "track"?, "children"}],
-- a page entry possibly with "track" and "children" too, but never a title.
-- A page listed under a node with "track" is rendered once for that track, to
-- <directory of the track node's first page>/../<track>/<page>.html.
--
-- Fenced blocks:
--   ```lawspec [include=<spec>] [run=<adapter>,...] [target=<t>]
--       an editable playground, compiled here (the build fails on any
--       diagnostic) with its adapter stubs rendered; run= names JavaScript
--       adapters under acceptance/lessons/javascript/files, so the page can
--       run the generated tests
--   ```lawspec fragment [include=<spec>]   a partial snippet, shown as code
--   ```<lang> include=<path> [region=<name>]
--       the file, or the lines between "region <name>" and "endregion" comments
--   ```<lang> file=<path> ...  a block canon tangles into <path>; shown as is
--   (ref:DEC-include-fences)
--   ::: only <track> ... :::  text for one track of a lesson
module Docs (docsCommand) where

import Commonmark (commonmarkWith, defaultSyntaxSpec)
import Commonmark.Extensions (autoIdentifiersSpec, gfmExtensions)
import Commonmark.Html (Html, renderHtml)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value(..), eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (isAlphaNum, isSpace)
import Data.IORef
import Data.Functor.Identity (runIdentity)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sort, stripPrefix)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Vector as V
import System.Directory
import System.Exit (ExitCode(..), die)
import System.FilePath ((</>), dropExtension, joinPath, makeRelative, normalise, splitDirectories, takeDirectory, takeFileName)
import System.IO (readFile')
import System.Process (readProcessWithExitCode)
import Gen.Template (Fill(..), fillTemplate)
import Generate (currentVersion)
import LawSpec.Api (dispatch)
import LawSpec.Scaffold (scaffoldTargets, testCommand)
import LawSpec.Targets (targetLabel)

data Page = Page { pageSource :: FilePath, pageOutput :: FilePath, pageTitle :: String, pageTrack :: Maybe String } deriving Eq
-- A navigation node: a title, an optional page, and children.
data Nav = Nav String (Maybe Page) [Nav]

repository :: String
repository = "https://github.com/brain-fuel/lawspec/blob/main/"

docsCommand :: [String] -> IO ()
docsCommand args = case args of
  ["--check"] -> build Nothing
  ["--out", out] -> build (Just out)
  _ -> die "usage: lawspec-dev docs --out <dir> | --check"

build :: Maybe FilePath -> IO ()
build out = do
  version <- currentVersion
  navJson <- BL.readFile "docs/nav.json"
  tree <- either (die . ("docs/nav.json: " ++)) (pure . navTree Nothing) (eitherDecode navJson)
  nav <- either die pure tree >>= titled
  cited <- citations
  checkFrontMatter nav
  let pages = navPages nav
  pageTemplate <- readFile' "templates/site/page.html"
  errors <- newIORef []
  snippets <- newIORef (0 :: Int)
  rendered <- forM (zip [0 :: Int ..] pages) $ \(index, page) -> do
    markdown <- snd . frontMatter <$> readFile' (pageSource page)
    body <- preprocess cited errors snippets pages page markdown
    html <- case runIdentity (commonmarkWith (defaultSyntaxSpec <> gfmExtensions <> autoIdentifiersSpec) (pageSource page) (T.pack body)) of
      Right (h :: Html ()) -> pure (TL.unpack (renderHtml h))
      Left problem -> pure ("<pre>" ++ escape (show problem) ++ "</pre>")
    let root = concat (replicate (length (splitDirectories (takeDirectory (pageOutput page))) - (if takeDirectory (pageOutput page) == "." then 1 else 0)) "../")
        neighbour offset = let i = index + offset in if i >= 0 && i < length pages then Just (pages !! i) else Nothing
        pager = concat
          [ maybe "<span></span>" (\p -> "<a href=\"" ++ relativeUrl page (pageOutput p) ++ "\">← " ++ escape (pageTitle p) ++ "</a>") (neighbour (-1))
          , maybe "<span></span>" (\p -> "<a href=\"" ++ relativeUrl page (pageOutput p) ++ "\">" ++ escape (pageTitle p) ++ " →</a>") (neighbour 1) ]
        fills =
          [ ("title", Inline (escape (pageTitle page))), ("root", Inline root)
          , ("version", Inline ("v" ++ version))
          , ("nav", Inline (navHtml page nav)), ("content", Inline (trackSwitcher pages page ++ html))
          , ("pager", Inline pager) ]
    (filled, _) <- either die pure (fillTemplate "templates/site/page.html" fills pageTemplate)
    pure (pageOutput page, filled)
  -- README.md is not part of the site, but its snippets must compile too.
  readme <- readFile' "README.md"
  _ <- preprocess cited errors snippets [] (Page "README.md" "README.html" "README" Nothing) readme
  problems <- readIORef errors
  count <- readIORef snippets
  unless (null problems) (die (intercalate "\n" (reverse problems)))
  case out of
    Nothing -> putStrLn ("Documentation: " ++ show (length pages) ++ " pages, " ++ show count ++ " snippets compiled, links resolve.")
    Just directory -> do
      exists <- doesDirectoryExist directory
      when exists (removeDirectoryRecursive directory)
      forM_ rendered $ \(path, content) -> writeAt (directory </> path) content
      assets directory
      putStrLn ("Built " ++ show (length pages) ++ " pages into " ++ directory ++ ".")

-- | Pages in navigation order.
navPages :: [Nav] -> [Page]
navPages = concatMap (\(Nav _ page children) -> maybe [] pure page ++ navPages children)

navTree :: Maybe String -> Value -> Either String [Nav]
navTree track (Array items) = mapM (navEntry track) (V.toList items)
navTree _ _ = Left "expected an array of entries"

-- | A page's title is read from its front matter afterwards (titled), so a
-- page entry carries none; a section without a page names its own.
navEntry :: Maybe String -> Value -> Either String Nav
navEntry track (Object o) = do
  let title = case KM.lookup (K.fromString "title") o of
        Just (String t) -> Just (T.unpack t)
        _ -> Nothing
      track' = case KM.lookup (K.fromString "track") o of
        Just (String t) -> Just (T.unpack t)
        _ -> track
      page = case KM.lookup (K.fromString "path") o of
        Just (String p) -> Just (Page ("docs" </> T.unpack p) (outputFor track' (T.unpack p)) "" track')
        _ -> Nothing
  children <- maybe (Right []) (navTree track') (KM.lookup (K.fromString "children") o)
  case (page, title) of
    (Just p, Just _) -> Left ("entry " ++ pageSource p ++ " names a title; the page's front matter holds it")
    (Just _, Nothing) -> Right (Nav "" page children)
    (Nothing, Just t) | not (null children) -> Right (Nav t Nothing children)
    (Nothing, _) -> Left "an entry needs a path, or a title and children"
navEntry _ _ = Left "expected an object"

-- | Each page entry takes its title from the page's front matter.
titled :: [Nav] -> IO [Nav]
titled = mapM $ \(Nav title page children) -> do
  page' <- forM page $ \p -> do
    (fields, _) <- frontMatter <$> readFile' (pageSource p)
    case lookup "title" fields of
      Just t -> pure p { pageTitle = t }
      Nothing -> die (pageSource p ++ ": front matter names no title")
  Nav (maybe title pageTitle page') page' <$> titled children

-- | Every page under docs/ is listed and carries front matter naming its id,
-- kind and title, with ids unique and each kind the quadrant it lives in.
-- The landing page, docs/index.md, is the one page of kind index.
-- ref:DEC-docs-landing-page ref:diataxis
checkFrontMatter :: [Nav] -> IO ()
checkFrontMatter nav = do
  sources <- filter (".md" `isSuffixOf`) <$> walk "docs"
  let listed = map pageSource (navPages nav)
  fields <- forM sources $ \source -> (,) source . fst . frontMatter <$> readFile' source
  let problems =
        [ source ++ ": not listed in docs/nav.json" | source <- sources, source `notElem` listed ] ++
        [ source ++ ": front matter names no " ++ key | (source, fs) <- fields, key <- ["id", "kind", "title"], lookup key fs == Nothing ] ++
        [ source ++ ": kind " ++ kind ++ " does not match its directory"
        | (source, fs) <- fields, Just kind <- [lookup "kind" fs], not (kindFits source kind) ] ++
        [ "duplicate page id " ++ i | (i, n) <- counts [i | (_, fs) <- fields, Just i <- [lookup "id" fs]], n > (1 :: Int) ]
  unless (null problems) (die (intercalate "\n" problems))
  where
    kindFits source kind = case lookup kind quadrants of
      Just dir -> dir `elem` splitDirectories (takeDirectory source)
      Nothing -> kind == "index" && source == "docs/index.md"
    quadrants = [("tutorial", "tutorials"), ("how-to", "how-to"), ("reference", "reference"), ("explanation", "explanation")]
    counts xs = [(x, length (filter (== x) xs)) | x <- sort (unique xs)]
    unique = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | The keys a page may cite, written "ref:" and the key, with where each leads: a registry
-- entry to its locator (a repository path to that file on GitHub), a ledger
-- decision to the ledger. Both files hold one top-level key per entry, with
-- its fields indented below it. ref:DEC-rationale-in-ledger
citations :: IO [(String, String)]
citations = do
  registry <- entries <$> readFile' "canonical_refs.yaml"
  ledger <- entries <$> readFile' "canonical_decisions.yaml"
  pure ([(k, locator fields) | (k, fields) <- registry] ++
        [(k, repository ++ "canonical_decisions.yaml") | (k, _) <- ledger])
  where
    entries = go . lines
    go (l : rest) | Just key <- topKey l =
      let (fields, more) = span (\x -> maybe True (const False) (topKey x)) rest in (key, fields) : go more
    go (_ : rest) = go rest
    go [] = []
    topKey l = case l of
      c : _ | not (isSpace c), Just key <- stripSuffix' ":" l -> Just key
      _ -> Nothing
    stripSuffix' suffix l = reverse <$> stripPrefix (reverse suffix) (reverse l)
    locator fields = case [url | f <- fields, Just url <- [stripPrefix "  locator: " f]] of
      url : _ | any (`isPrefixOf` url) ["http://", "https://"] -> url
              | otherwise -> repository ++ url
      [] -> repository ++ "canonical_refs.yaml"

-- | Front matter: the lines between a first line "---" and the next "---",
-- each "key: value". Returns the fields and the page without them.
frontMatter :: String -> ([(String, String)], String)
frontMatter content = case lines content of
  "---" : rest | (fields, _ : body) <- break (== "---") rest ->
    ([(trim k, trim (drop 1 v)) | f <- fields, let (k, v) = break (== ':') f, not (null v)], unlines body)
  _ -> ([], content)

-- | A track page lives beside its lesson directory: tutorials/lessons/01.md is
-- tutorials/java/01.html for the Java track.
outputFor :: Maybe String -> FilePath -> FilePath
outputFor Nothing path = dropExtension path ++ ".html"
outputFor (Just track) path = takeDirectory (takeDirectory path) </> track </> dropExtension (takeFileName path) ++ ".html"

navHtml :: Page -> [Nav] -> String
navHtml current items = "<ul>" ++ concatMap item items ++ "</ul>"
  where
    -- Sections open only around the current page.
    item (Nav title page []) = "<li>" ++ label title page ++ "</li>"
    item node@(Nav title page children) =
      "<li><details" ++ (if contains node then " open" else "") ++ "><summary>" ++ label title page ++
      "</summary>" ++ navHtml current children ++ "</details></li>"
    contains (Nav _ page children) = maybe False ((== pageOutput current) . pageOutput) page || any contains children
    label title Nothing = "<span class=\"section\">" ++ escape title ++ "</span>"
    label title (Just p) = "<a href=\"" ++ relativeUrl current (pageOutput p) ++ "\"" ++
      (if pageOutput p == pageOutput current then " aria-current=\"page\"" else "") ++ ">" ++ escape title ++ "</a>"

-- | Links to the same lesson in the other tracks.
trackSwitcher :: [Page] -> Page -> String
trackSwitcher pages page = case pageTrack page of
  Nothing -> ""
  Just _ ->
    let same = [p | p <- pages, pageSource p == pageSource page, pageTrack p /= Nothing]
    in "<div class=\"tracks\">" ++ concat
      [ "<a href=\"" ++ relativeUrl page (pageOutput p) ++ "\"" ++ (if pageOutput p == pageOutput page then " aria-current=\"page\"" else "") ++ ">" ++ maybe "" label (pageTrack p) ++ "</a>"
      | p <- same ] ++ "</div>"
  where label = targetLabel

relativeUrl :: Page -> FilePath -> String
relativeUrl from to = relative (takeDirectory (pageOutput from)) to

relative :: FilePath -> FilePath -> String
relative fromDirectory to =
  let a = filter (/= ".") (splitDirectories fromDirectory)
      b = splitDirectories to
      common = length (takeWhile id (zipWith (==) a (init' b)))
  in intercalate "/" (replicate (length a - common) ".." ++ drop common b)
  where init' xs = if null xs then xs else init xs

-- | The modules a sandbox links besides the generated ones, as paths under
-- assets/, and the bare specifiers generated code imports them by.
sandboxManifest :: [FilePath] -> String
sandboxManifest vendored = BLC.unpack (encode (object
  [ K.fromString "modules" .= object [K.fromString f .= f | f <- ["node-test.mjs", "assert.mjs"] ++ vendored]
  , K.fromString "aliases" .= object ([K.fromString k .= v | (k, v) <- specifiers]) ])) ++ "\n"
  where
    specifiers =
      [ ("node:test", "node-test.mjs"), ("node:assert/strict", "assert.mjs"), ("node:assert", "assert.mjs")
      , ("fast-check", "vendor/fast-check/fast-check.js") ] ++
      [ ("pure-rand/" ++ sub, "vendor/pure-rand/" ++ sub ++ ".js") | sub <- pureRandExports ]

pureRandExports :: [String]
pureRandExports =
  [ "distribution/uniformBigInt", "distribution/uniformInt", "distribution/uniformFloat32", "distribution/uniformFloat64"
  , "generator/congruential32", "generator/mersenne", "generator/xorshift128plus", "generator/xoroshiro128plus"
  , "utils/generateN", "utils/purify", "utils/skipN" ]

-- | Expand includes, filter tracks, turn LawSpec blocks into playgrounds and
-- rewrite links, recording problems rather than stopping at the first.
preprocess :: [(String, String)] -> IORef [String] -> IORef Int -> [Page] -> Page -> String -> IO String
preprocess cited errors snippets pages page markdown = unlines <$> go (lines markdown)
  where
    here = pageSource page
    problem message = modifyIORef errors ((here ++ ": " ++ message) :)
    go [] = pure []
    go (l : rest)
      | Just info <- stripPrefix "```" l, not (null (trim info)) = do
          let (block, after) = break (\x -> trim x == "```") rest
          replacement <- fence (words info) block
          (replacement ++) <$> go (drop 1 after)
      | Just track <- stripPrefix "::: only " l = do
          let (inner, after) = break (\x -> trim x == ":::") rest
          kept <- if maybe True (== trim track) (pageTrack page) then go inner else pure []
          (kept ++) <$> go (drop 1 after)
      | otherwise = (:) <$> rewriteLinks l <*> go rest
    fence ("lawspec" : attributes) block
      | "fragment" `elem` attributes = case lookup "include" (mapMaybe attribute attributes) of
          Just file -> do
            content <- readIncluded file
            pure (["```lawspec"] ++ lines content ++ ["```"])
          Nothing -> pure (["```lawspec"] ++ block ++ ["```"])
      | otherwise = do
          let attrs = mapMaybe attribute attributes
          -- Several files compile together; the last is the one shown.
          files <- case lookup "include" attrs of
            Just list -> forM (splitOn ',' list) $ \file -> (,) (takeFileName file) <$> readIncluded file
            Nothing -> pure [("spec.lawspec", unlines block)]
          let (name, source) = last files
              extra = init files
          modifyIORef snippets (+ 1)
          let sources = [object [K.fromString "path" .= p, K.fromString "content" .= c] | (p, c) <- files]
              request method more = decodeValue (dispatch (encode (object
                ([K.fromString "method" .= method, K.fromString "sources" .= sources] ++ more))))
          case diagnostics (request "check" []) of
            [] -> pure ()
            ds -> problem ("snippet does not compile:\n  " ++ intercalate "\n  " ds ++ "\n" ++ source)
          -- implementations=<dir>: for each target, the files of <dir>/<target>/files
          -- that implement this example's adapters, found by the paths the
          -- compiler gives them. Acceptance suites test those files for real.
          implementations <- case lookup "implementations" attrs of
            Nothing -> pure []
            Just root -> fmap concat $ forM targetNames $ \t -> do
              found <- fmap concat $ forM (userFiles (request "planGeneration" [K.fromString "target" .= t])) $ \(p, _) -> do
                let file = root </> t </> "files" </> p
                exists <- doesFileExist file
                if exists then (\c -> [(p, c)]) <$> readFile' file else pure []
              pure [(t, found) | not (null found)]
          let target = fromMaybe (fromMaybe "java" (pageTrack page)) (lookup "target" attrs)
              key = fromMaybe (intercalate "," (map fst files)) (lookup "key" attrs)
              attributes' = [("data-path", name), ("data-source", source), ("data-target", target), ("data-key", key)] ++
                [("data-view", v) | Just v <- [lookup "view" attrs]] ++
                [("data-extra", BLC.unpack (encode [object [K.fromString "path" .= p, K.fromString "content" .= c] | (p, c) <- extra])) | not (null extra)] ++
                [("data-implementations", BLC.unpack (encode (object [K.fromString t .= object [K.fromString p .= c | (p, c) <- fs] | (t, fs) <- implementations])))
                | not (null implementations)]
          -- The opening tag alone on its line makes this a raw HTML block.
          pure [ "<lawspec-playground " ++ unwords [k ++ "=\"" ++ escapeAttribute v ++ "\"" | (k, v) <- attributes'] ++ ">"
               , "</lawspec-playground>", "" ]
    fence (language : attributes) block = do
      let attrs = mapMaybe attribute attributes
      -- A block with file= is canon's: it tangles into that file, and the
      -- page shows the block itself.
      case lookup "include" attrs of
        Nothing -> pure (["```" ++ language] ++ block ++ ["```"])
        Just file -> do
          content <- readIncluded file
          selected <- case lookup "region" attrs of
            Nothing -> pure (lines content)
            Just region -> case regionOf region (lines content) of
              Just ls -> pure ls
              Nothing -> problem ("no region " ++ region ++ " in " ++ file) >> pure []
          pure (["```" ++ language] ++ selected ++ ["```"])
    fence [] block = pure (["```"] ++ block ++ ["```"])
    readIncluded file = do
      exists <- doesFileExist file
      if exists then readFile' file else problem ("missing included file " ++ file) >> pure ""
    attribute a = case break (== '=') a of
      (k, '=' : v) -> Just (k, v)
      _ -> Nothing
    -- [text](target): relative Markdown links become the rendered page; links
    -- to other repository files point to the repository.
    -- Inline code is left alone: `f[T](value)` is not a link.
    rewriteLinks [] = pure []
    rewriteLinks ('`' : cs) = let (code, after) = break (== '`') cs
      in (('`' : code ++ take 1 after) ++) <$> rewriteLinks (drop 1 after)
    rewriteLinks s@(c : cs)
      | Just rest <- stripPrefix "](" s = do
          let (target, after) = break (== ')') rest
          target' <- link target
          (("](" ++ target') ++) <$> rewriteLinks after
      -- ref:KEY cites a registry entry or a ledger decision, as canon reads
      -- it; the site links the source, or the decision in the ledger.
      | Just rest <- stripPrefix "ref:" s, (key@(_ : _), after) <- span citationChar rest = do
          let (key', trailing) = case reverse key of
                end : before | end `elem` ".-" -> (reverse before, [end])
                _ -> (key, [])
          citation <- case lookup key' cited of
            Just url -> pure ("<sup>[" ++ (if "DEC-" `isPrefixOf` key' then "decision" else "source") ++ "](" ++ url ++ ")</sup>")
            Nothing -> problem ("ref:" ++ key' ++ " is in neither canonical_refs.yaml nor canonical_decisions.yaml") >> pure ""
          ((citation ++ trailing) ++) <$> rewriteLinks after
      | otherwise = (c :) <$> rewriteLinks cs
    citationChar ch = isAlphaNum ch || ch == '-' || ch == '.' 
    link target
      | any (`isPrefixOf` target) ["http://", "https://", "mailto:", "#"] || null target = pure target
      | otherwise = do
          let (file, anchor) = break (== '#') target
              collapsed = collapse (normalise (takeDirectory here </> file))
          -- A track page is linked by its source or by its rendered path.
          let asOutput = maybe "" (\rel -> dropExtension rel ++ ".html") (stripPrefix "docs/" collapsed)
          case [p | p <- pages, pageSource p == collapsed || pageOutput p == asOutput] of
            candidates@(first : _) ->
              let chosen = case [p | p <- candidates, pageTrack p == pageTrack page] of
                    same : _ -> same
                    [] -> first
              in pure (relativeUrl page (pageOutput chosen) ++ anchor)
            [] | pageSource page == "README.md" -> pure target
               | otherwise -> do
                   exists <- (||) <$> doesFileExist collapsed <*> doesDirectoryExist collapsed
                   when ("docs/" `isPrefixOf` collapsed && ".md" `isSuffixOf` collapsed)
                     (problem ("link to a page missing from docs/nav.json: " ++ target))
                   unless exists (problem ("broken link: " ++ target))
                   pure (repository ++ collapsed ++ anchor)
    collapse path = joinPath (reverse (foldl step [] (splitDirectories path)))
      where step acc ".." = drop 1 acc
            step acc "." = acc
            step acc part = part : acc

regionOf :: String -> [String] -> Maybe [String]
regionOf name ls =
  let start = dropWhile (not . marker ("region " ++ name)) ls
  in case start of
    _ : body -> Just (takeWhile (not . marker "endregion") body)
    [] -> Nothing
  where marker m l = let t = trim l in any (\c -> (c ++ " " ++ m) == t || (c ++ m) == t) ["//", "#", "--"]

targetNames :: [String]
targetNames = scaffoldTargets

-- | The user-owned files of a generation response: the adapters.
userFiles :: Value -> [(String, String)]
userFiles (Object o) = case KM.lookup (K.fromString "files") o of
  Just (Array files) -> [ (T.unpack p, T.unpack c) | Object f <- V.toList files
                        , Just (String owner) <- [KM.lookup (K.fromString "ownership") f], owner == T.pack "user"
                        , Just (String p) <- [KM.lookup (K.fromString "path") f]
                        , Just (String c) <- [KM.lookup (K.fromString "content") f] ]
  _ -> []
userFiles _ = []

diagnostics :: Value -> [String]
diagnostics (Object o) = case KM.lookup (K.fromString "diagnostics") o of
  Just (Array ds) -> [ render d | Object d <- V.toList ds ]
  _ -> ["no response"]
  where render d = maybe "" text (KM.lookup (K.fromString "code") d) ++ ": " ++ maybe "" text (KM.lookup (K.fromString "message") d)
        text (String t) = T.unpack t
        text v = BLC.unpack (encode v)
diagnostics _ = ["no response"]

decodeValue :: BL.ByteString -> Value
decodeValue = either (const Null) id . eitherDecode

-- | Static assets: the site templates, the compiler and the vendored test
-- libraries, which are fetched from npm at pinned versions and verified.
assets :: FilePath -> IO ()
assets out = do
  let dir = out </> "assets"
  partials <- forM ["core-instance"] $ \name -> do
    source <- readFile' ("templates/partials" </> name ++ ".mjs")
    pure ("partial-" ++ name, Block (lines source))
  -- How each target's tests run in a project, from LawSpec.Scaffold.
  let commands = ("test-commands", Inline (BLC.unpack (encode (object
        [K.fromString t .= c | t <- scaffoldTargets, Just c <- [testCommand t]]))))
      labels = ("target-labels", Inline (BLC.unpack (encode
        [[t, targetLabel t] | t <- scaffoldTargets])))
  forM_ ["style.css", "playground.mjs", "highlight.mjs", "lawspec-core.mjs", "node-test.mjs", "assert.mjs"] $ \file -> do
    source <- readFile' ("templates/site" </> file)
    (content, _) <- either die pure (fillTemplate ("templates/site" </> file) (commands : labels : partials) source)
    writeAt (dir </> file) content
  copyFile "templates/site/_headers" (out </> "_headers")
  forM_ ["core.wasm", "core_jsffi.js"] $ \file -> do
    exists <- doesFileExist ("npm" </> file)
    unless exists (die ("npm/" ++ file ++ " is missing; run make wasm first"))
    copyFile ("npm" </> file) (dir </> file)
  lock <- BL.readFile "docs/vendor.lock.json" >>= either (die . ("docs/vendor.lock.json: " ++)) pure . eitherDecode
  -- Syntax highlighting: highlight.js's core and the languages the docs use.
  let highlighted = ["languages/" ++ l ++ ".min.js" | l <- highlightLanguages]
  forM_ [ ("fast-check", "fast-check", "lib", \f -> ".js" `isSuffixOf` f && not ("/" `isInfixOf` f))
        , ("pure-rand", "pure-rand", "lib/esm", (".js" `isSuffixOf`))
        , ("@highlightjs/cdn-assets", "highlight", "es", \f -> f == "core.js" || f `elem` highlighted)
        -- The TypeScript compiler, loaded only to run TypeScript: it
        -- transpiles in the page, and the sandbox runs the JavaScript.
        , ("typescript", "typescript", "lib", (== "typescript.js")) ] $ \(name, target, root, keep) -> do
    unpacked <- vendor lock name
    files <- walk (unpacked </> "package" </> root)
    forM_ files $ \file -> do
      let within = makeRelative (unpacked </> "package" </> root) file
      when (keep within) (copyTo file (dir </> "vendor" </> target </> within))
  sandboxed <- filter (\f -> any (`isPrefixOf` f) ["vendor/fast-check/", "vendor/pure-rand/"]) . map (makeRelative dir) <$> walk dir
  writeAt (dir </> "vendor" </> "sandbox.json") (sandboxManifest sandboxed)
  where copyTo from to = createDirectoryIfMissing True (takeDirectory to) >> copyFile from to

highlightLanguages :: [String]
highlightLanguages = ["bash", "go", "haskell", "java", "javascript", "json", "kotlin", "plaintext", "python", "rust", "typescript"]

vendor :: Value -> String -> IO FilePath
vendor (Object lock) name = do
  (version, integrity) <- case KM.lookup (K.fromString name) lock of
    Just (Object entry) | Just (String v) <- KM.lookup (K.fromString "version") entry
                        , Just (String i) <- KM.lookup (K.fromString "integrity") entry -> pure (T.unpack v, T.unpack i)
    _ -> die ("docs/vendor.lock.json has no entry for " ++ name)
  let cache = ".artifacts/vendor"
      stem = map (\c -> if c == '/' then '-' else c) (filter (/= '@') name) ++ "-" ++ version
      unpacked = cache </> stem
  ready <- doesDirectoryExist unpacked
  unless ready $ do
    createDirectoryIfMissing True cache
    (code, out, err) <- readProcessWithExitCode "npm" ["pack", name ++ "@" ++ version, "--json", "--pack-destination", cache] ""
    unless (code == ExitSuccess) (die ("npm pack " ++ name ++ " failed: " ++ err))
    let reported = case eitherDecode (BLC.pack out) of
          Right (Array items) | Object item : _ <- V.toList items, Just (String i) <- KM.lookup (K.fromString "integrity") item -> T.unpack i
          _ -> ""
    unless (reported == integrity) (die (name ++ "@" ++ version ++ " integrity " ++ reported ++ " does not match docs/vendor.lock.json"))
    createDirectoryIfMissing True unpacked
    (code', _, err') <- readProcessWithExitCode "tar" ["-xzf", cache </> (stem ++ ".tgz"), "-C", unpacked] ""
    unless (code' == ExitSuccess) (die ("cannot unpack " ++ name ++ ": " ++ err'))
  pure unpacked
vendor _ _ = die "docs/vendor.lock.json must be an object"

walk :: FilePath -> IO [FilePath]
walk dir = do
  entries <- sort <$> listDirectory dir
  concat <$> forM entries (\entry -> do
    let path = dir </> entry
    isDirectory <- doesDirectoryExist path
    if isDirectory then walk path else pure [path])

writeAt :: FilePath -> String -> IO ()
writeAt path content = createDirectoryIfMissing True (takeDirectory path) >> writeFile path content

escape :: String -> String
escape = concatMap (\c -> case c of '&' -> "&amp;"; '<' -> "&lt;"; '>' -> "&gt;"; '"' -> "&quot;"; _ -> [c])

-- | One line: raw HTML blocks end at a blank line.
escapeAttribute :: String -> String
escapeAttribute = concatMap (\c -> case c of '\n' -> "&#10;"; '\r' -> ""; '\'' -> "&#39;"; _ -> escape [c])

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, _ : rest) -> a : splitOn c rest
  (a, []) -> [a]
