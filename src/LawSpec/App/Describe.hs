-- | @lawspec describe@: the component document, ported from component.mjs
-- resolveComponent and input-files.mjs fingerprintInputs. The host has no
-- realpath, so the working directory and the component root are taken as
-- they are named; a host starts the CLI in a directory's real path.
-- ref:DEC-haskell-application-port
module LawSpec.App.Describe
  ( describeComponent,
  )
where

import Control.Monad (forM, forM_, unless)
import Data.List (intercalate, isSuffixOf, sortBy)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call)
import LawSpec.App.Files (atomicWrite, collectSources, compareUtf16, digestText)
import LawSpec.App.Json
import LawSpec.App.Packages
import LawSpec.App.Project
import LawSpec.Digest (digest, digestHex)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, join, relative, resolve, takeDirectory)

describeComponent :: (Monad m) => Invocation -> Arguments -> FilePath -> Command m Json
describeComponent invocation arguments file = do
  manifest <- readManifest file
  let root = takeDirectory file
      cwd = invocationDirectory invocation
  grantRead [root]
  grantProject [root]
  grantWrite [root]
  resolved <- resolveDependencies file manifest (resolveOptions cwd) {resolveLocked = flag "locked" arguments, resolveOffline = flag "offline" arguments}
  sources <- collectSources root (strings "sources" manifest) root
  let sourceList = JArray [JObject [("path", JString path'), ("content", JString content)] | (path', content) <- sources]
      version' = case member "component" manifest >>= member "version" of
        Just value -> Just value
        Nothing -> member "package" manifest >>= member "version"
      input =
        jsObject
          ( [ ("sources", sourceList),
              ("languageProfile", fromMaybe JNull (member "languageProfile" manifest)),
              ("verification", fromMaybe (JObject [("layers", JArray [])]) (member "verification" manifest))
            ]
              ++ [("package", identity) | Just identity <- [member "package" manifest]]
              ++ [ ("dependencies", dependencyRanges manifest),
                   ("packages", JArray (resolvedPackages resolved))
                 ]
              ++ [("generation", value) | Just value <- [member "generation" manifest]]
              ++ [ ("machineBits", fromMaybe (integer 64) (member "machineBits" manifest))
                 ]
              ++ [("projectVersion", value) | Just value <- [version']]
          )
      relativeCache = relative cwd (join root ".lawspec/cache")
      escapes = relativeCache == ".." || take 3 relativeCache == "../" || isAbsolute relativeCache
  cache <-
    if member "cache" manifest /= Just (JBool False) && not escapes
      then do
        let build = take 16 (buildDigest invocation)
            directory = join (join cwd relativeCache) build
        grantWrite [join cwd relativeCache]
        effect (nodeFailure "mkdir" directory) (MakeDirectories Nothing directory)
        atomicWrite (join (join cwd relativeCache) ".gitignore") "*\n" False
        -- The Node launcher keeps a folder per build below the directory.
        pure (Just (join directory build))
      else pure Nothing
  let request = setMember "verification" (JObject [("layers", JArray [])]) input
      request' = jsObject (members request ++ maybe [] (\directory -> [("cacheDirectory", JString directory)]) cache)
  checked <- call "check" request' >>= checkedOrFail
  forM_ (fromMaybe [] (member "targets" manifest >>= arrayOf)) $ \target ->
    forM_ (member "nativeBindings" target) $ \bindings ->
      call "check" (jsObject (members request' ++ [("nativeBindings", bindings)])) >>= checkedOrFail
  let units = fromMaybe [] (member "units" checked >>= arrayOf)
      laws = fromMaybe [] (member "laws" checked >>= arrayOf)
      declarations =
        S.fromList
          ( [ text "id" item
            | unit <- units,
              item <- list "declarations" unit ++ list "abilities" unit
            ]
              ++ map (text "id") laws
          )
      lock = resolvedLock resolved
      lockPackages = list "packages" lock
      lockRoots = maybe [] members (member "roots" lock)
      identities = resolvedIdentities resolved
      find' identifier = case [entry | entry <- lockPackages, member "id" entry == Just identifier] of
        entry : _ -> Just entry
        [] -> Nothing
      release value entry = text "name" entry == text "name" value && text "version" entry == text "version" value
  ownContract <- case member "package" manifest of
    Nothing -> pure []
    Just identity -> do
      content <- packageDigest root
      let dependencies =
            [ (name, maybe JNull id (selected >>= \entry -> case filter (release entry) identities of found : _ -> member "digest" found; [] -> Nothing))
            | (name, identifier) <- lockRoots,
              let selected = find' identifier
            ]
          digest' = if null dependencies then content else digestText (canonical (JObject [("content", JString content), ("dependencies", jsObject dependencies)]))
      pure [(text "name" identity, setMember "digest" (JString digest') identity)]
  let contracts = M.fromList ([(name, entry) | (name, identifier) <- lockRoots, Just entry <- [find' identifier]] ++ ownContract)
      requires = maybe [] members (member "requires" manifest)
      provides = list "provides" manifest
  forM_ (requires ++ [("provides[" ++ show index ++ "]", value) | (index, value) <- zip [0 :: Int ..] provides]) $ \(name, requirement) -> do
    let contract = text "contract" requirement
    unless (M.member contract contracts) $
      manifestFailure (name ++ ": contract " ++ (maybe "undefined" jsString (member "contract" requirement)) ++ " is not resolved") (Just file)
    forM_ (strings "abilities" requirement ++ strings "declarations" requirement) $ \declaration ->
      unless (S.member declaration declarations) (manifestFailure (name ++ ": unknown declaration " ++ declaration) (Just file))
  inputs <- fingerprintInputs root (member "inputs" manifest)
  manifestBytes <- effect (nodeFailure "open" file) (ReadFile file)
  let identityDocument =
        JObject
          [ ("manifest", manifest),
            ("sources", sourceList),
            ("dependencies", JArray identities),
            ("inputs", JArray [JArray [JString path', JString hash] | (path', hash) <- inputs])
          ]
      contractView value =
        let selected = M.lookup (text "contract" value) contracts
            content = selected >>= \entry -> case filter (release entry) identities of found : _ -> Just found; [] -> Nothing
            requirement = member "dependencies" manifest >>= member (text "contract" value)
         in jsObject
              ( members value
                  ++ [ ("version", fromMaybe JNull (selected >>= member "version")),
                       ("digest", fromMaybe JNull (case content >>= member "digest" of Just d -> Just d; Nothing -> selected >>= member "digest"))
                     ]
                  ++ case requirement of
                    Just r | isTruthy r -> [("versionRequirement", case r of JString _ -> r; _ -> fromMaybe JNull (member "version" r))]
                    _ -> []
              )
      -- An undefined member is left out, as JSON.stringify does.
      defined = filter ((/= Nothing) . snd)
  pure . jsObject $
    [ (key, value)
    | (key, Just value) <-
        defined
          [ ("format", Just (JString "lawspec-component")),
            ("version", Just (integer 1)),
            ("manifest", Just (JString file)),
            ("root", Just (JString root)),
            ("component", Just (fromMaybe JNull (member "component" manifest))),
            ("package", Just (fromMaybe JNull (member "package" manifest))),
            ("fingerprint", Just (JString (digestText (canonical identityDocument)))),
            ("manifestDigest", Just (JString (digestHex (digest manifestBytes)))),
            ("targets", Just (fromMaybe (JArray []) (member "targets" manifest))),
            ("provides", Just (JArray (map contractView provides))),
            ("requires", Just (jsObject [(name, contractView value) | (name, value) <- requires])),
            ("dependencies", Just (JArray identities)),
            ("laws", Just (fromMaybe (JArray []) (member "laws" checked))),
            ("declarations", Just (JArray (map JString (sortBy compareUtf16 (S.toList declarations)))))
          ]
    ]
  where
    text key value = maybe "undefined" jsString (member key value)
    list key value = fromMaybe [] (member key value >>= arrayOf)
    strings key value = [entry | JString entry <- list key value]
    checkedOrFail result = case member "diagnostics" result of
      Just items@(JArray (_ : _)) ->
        failWithDiagnostics (intercalate "\n" [maybe "undefined" jsString (member "message" item) | item <- fromMaybe [] (arrayOf items)]) items
      _ -> pure result

-- | input-files.mjs fingerprintInputs: each declared input file's SHA-256,
-- sorted by path, skipping build directories and attestation documents.
fingerprintInputs :: (Monad m) => FilePath -> Maybe Json -> Command m [(String, String)]
fingerprintInputs root declared = do
  entries <- case fromMaybe (JArray []) declared of
    JArray items | all nonempty items -> pure [text' | JString text' <- items]
    _ -> failWith "Component inputs must be an array of nonempty paths"
  rows <- concat <$> forM entries (\entry -> visit (resolve root entry) entry)
  let unique = M.toList (M.fromList rows)
  pure (sortBy (\(a, _) (b, _) -> compareUtf16 a b) unique)
  where
    nonempty (JString (_ : _)) = True
    nonempty _ = False
    visit file path' = do
      grantRead [file]
      status <- effect (nodeFailure "lstat" file) (Stat NoFollow file)
      case statusKind status of
        SymbolicLinkKind -> failWith ("Symbolic links are not supported in component inputs: " ++ path')
        DirectoryKind -> do
          names <- map entryName <$> effect (nodeFailure "scandir" file) (ListDirectory file)
          fmap concat . forM (sortBy compareUtf16 names) $ \name ->
            let next = path' ++ "/" ++ name
             in if name `elem` buildDirectories || "testdata/rapid" `isSuffixOf` next
                  then pure []
                  else visit (join file name) next
        FileKind
          | cryptoBuildOutput path' -> pure []
          | otherwise -> do
              bytes <- effect (nodeFailure "open" file) (ReadFile file)
              if ".json" `isSuffixOf` path' && attestation (fromUtf8 bytes)
                then pure []
                else pure [(path', digestHex (digest bytes))]
        _ -> pure []
    attestation content = case parseJson content of
      Right value@(JObject _) -> member "format" value == Just (JString "environment-attestation")
      _ -> False
    buildDirectories =
      [".git", ".lawspec", "node_modules", "dist", "build", "target", "out", ".gradle", "bin", "obj", "TestResults", ".stack-work", "_build", "deps", ".elixir_ls", "__pycache__", ".hypothesis", ".pytest_cache", ".venv", "venv", ".idea", ".vscode", ".scala-build", ".bsp", ".bloop", ".metals", ".build", ".swiftpm", ".cpcache"]
    -- priv/lawspec_crypto_native.(so|dll), with .build or .<n>.tmp.
    cryptoBuildOutput file =
      let name = reverse (takeWhile (/= '/') (reverse file))
          parent = reverse (takeWhile (/= '/') (drop 1 (dropWhile (/= '/') (reverse file))))
          stem = "lawspec_crypto_native."
          rest = drop (length stem) name
          library = case break (== '.') rest of
            (kind, suffix) -> kind `elem` ["so", "dll"] && (null suffix || suffix == ".build" || temporary suffix)
          temporary suffix = case suffix of
            '.' : more -> case span (`elem` ['0' .. '9']) more of
              (digits@(_ : _), ".tmp") -> not (null digits)
              _ -> False
            _ -> False
       in parent == "priv" && take (length stem) name == stem && library
