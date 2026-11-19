{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The path and capability policy every command runs under. The core
-- enforces it here, before a request reaches any host, and confines the host
-- to the same policy, so the host enforces it again independently. Paths
-- are compared lexically after normalisation, as WASI preopens are; a host
-- also resolves symbolic links ('escapes'), which the core cannot see.
--
-- Under every policy, 'guardrail' refuses a write, removal or directory
-- creation that targets a protected path (the root, the user's home and
-- temporary directories, the working directory, the project roots) or an
-- ancestor of one, a removal or rename of a write root or of a path not
-- strictly inside one, and every path effect while a write root is
-- protected. It is defence in depth
-- against a defect in a command: no grant, however wrong, lets a command
-- delete outside its project. Hosts apply it again, with their own home and
-- temporary directories and with symbolic links resolved ('enforced').
-- ref:DEC-host-effect-abi ref:wasi-capabilities
module LawSpec.Host.Sandbox
  ( Policy (..),
    closed,
    sandboxed,
    allows,
    Access (..),
    Resolution (..),
    touched,
    escapes,
    enforced,
    guardrail,
    guardrailResolved,
    systemProtected,
    protects,
  )
where

import Control.Applicative ((<|>))
import Data.List (intercalate)
import Data.Maybe (fromMaybe, listToMaybe, maybeToList)
import LawSpec.Host.Effect
import LawSpec.Host.Path (isAbsolute, normalise, segments, within)
import LawSpec.Host.Policy

-- | Refuse, with 'Denied', every request the policy does not allow, and pass
-- the rest to the host confined to the same policy. Confining a sandboxed
-- host again replaces its policy.
sandboxed :: forall m. (Applicative m) => Policy -> Host m -> Host m
sandboxed policy host = Host check (`sandboxed` host)
  where
    inner = confined host policy
    check :: forall a. Effect a -> m (Either HostError a)
    check effect = case allows policy effect of
      Nothing -> perform inner effect
      Just problem -> pure (Left (HostError Denied problem))

-- | 'Nothing' when allowed, or why not. Hosts apply the same rules. The
-- guard comes first, so that its refusals name it.
allows :: Policy -> Effect a -> Maybe String
allows policy effect = guardrail policy effect <|> granted policy effect

granted :: Policy -> Effect a -> Maybe String
granted policy = \case
  ReadFile path -> readable path
  ListDirectory path -> readable path
  Stat _ path -> readable path
  RealPath path -> readable path
  WriteFile _ _ path _ -> writable path
  Remove _ path -> writable path
  Rename from to -> writable from <|> writable to
  MakeDirectories _ path -> writable path
  Spawn request -> case spawnArguments request of
    [] -> Just "spawn needs a program"
    program : _
      | program `notElem` programs policy -> Just ("program not allowed: " ++ program)
      | otherwise -> readable (spawnDirectory request)
  Fetch request
    | not (network policy) -> Just "network access is not allowed"
    | take 8 (fetchUrl request) /= "https://" -> Just ("only https URLs may be fetched: " ++ fetchUrl request)
    | otherwise -> Nothing
  Serve _
    | listening policy -> Nothing
    | otherwise -> Just "listening is not allowed"
  Accept {} -> Nothing
  Respond {} -> Nothing
  Poll {} -> Nothing
  Kill {} -> Nothing
  GetEnvironment _ -> Nothing
  GetClock -> Nothing
  WriteOutput {} -> Nothing
  ReadInput _ -> Nothing
  QueryTerminal _ -> Nothing
  where
    readable path = inside (readRoots policy ++ writeRoots policy) path
    writable = inside (writeRoots policy)
    inside roots path
      | not (isAbsolute path) = Just ("path is not absolute: " ++ path)
      | any (`within` normalise path) roots = Nothing
      | otherwise = Just ("path is outside the sandbox: " ++ path)

data Access = ReadAccess | WriteAccess deriving (Eq, Show)

-- | How a host resolves symbolic links in a path before comparing it with
-- the roots: all of it ('Whole'), or only its directory, because the effect
-- acts on a final link itself ('Parent': @stat@ without following, @remove@,
-- @rename@ and the atomic @write@, which renames over the path).
data Resolution = Whole | Parent deriving (Eq, Show)

-- | The paths an effect touches, with the access it needs.
touched :: Effect a -> [(Access, Resolution, FilePath)]
touched = \case
  ReadFile path -> [(ReadAccess, Whole, path)]
  ListDirectory path -> [(ReadAccess, Whole, path)]
  Stat Follow path -> [(ReadAccess, Whole, path)]
  Stat NoFollow path -> [(ReadAccess, Parent, path)]
  RealPath path -> [(ReadAccess, Whole, path)]
  WriteFile _ _ path _ -> [(WriteAccess, Parent, path)]
  Remove _ path -> [(WriteAccess, Parent, path)]
  Rename from to -> [(WriteAccess, Parent, from), (WriteAccess, Parent, to)]
  MakeDirectories _ path -> [(WriteAccess, Whole, path)]
  Spawn request -> [(ReadAccess, Whole, spawnDirectory request)]
  _ -> []

-- | The host's second check, after 'allows': with the host's own resolver
-- (symbolic links followed, missing trailing components kept), every touched
-- path must still lie under a root resolved the same way. A link inside a
-- root that leads outside it is refused.
escapes :: (Monad m) => (Resolution -> FilePath -> m FilePath) -> Policy -> Effect a -> m (Maybe String)
escapes resolve policy effect = go (touched effect)
  where
    go [] = pure Nothing
    go ((access, resolution, path) : rest) = do
      real <- resolve resolution (normalise path)
      roots <- mapM (resolve Whole . normalise) (rootsFor access)
      if any (`within` real) roots
        then go rest
        else pure (Just ("path leaves the sandbox through a symbolic link: " ++ path))
    rootsFor ReadAccess = readRoots policy ++ writeRoots policy
    rootsFor WriteAccess = writeRoots policy

-- | Everything a host checks before it performs a request, in order. A
-- malformed request (a relative path, a spawn without a program) is left to
-- the interpreter, which answers 'Invalid'; then the core's rules
-- ('allows', the guard included); then the paths with their links resolved
-- ('escapes'), and the guard again over the resolved paths
-- ('guardrailResolved'). A host adds its own home and temporary
-- directories to the policy's 'protectedPaths' first.
enforced :: (Monad m) => (Resolution -> FilePath -> m FilePath) -> Policy -> Effect a -> m (Maybe String)
enforced resolve policy effect
  | malformed = pure Nothing
  | Just problem <- allows policy effect = pure (Just problem)
  | otherwise = do
      escaped <- escapes resolve policy effect
      case escaped of
        Just problem -> pure (Just problem)
        Nothing -> guardrailResolved resolve policy effect
  where
    malformed =
      any (\(_, _, path) -> not (isAbsolute path)) (touched effect) || case effect of
        Spawn request -> null (spawnArguments request)
        _ -> False

-- | The paths the guard protects on every host, whatever the policy says:
-- the root and the system temporary roots. macOS's per-user temporary
-- directories (@/var/folders/xx/yyy/T@) are protected by their shape.
systemProtected :: [FilePath]
systemProtected = ["/", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"]

-- | A path under both of its macOS names: @/tmp@, @/var@ and @/etc@ are
-- symbolic links to the same names under @/private@.
aliases :: FilePath -> [FilePath]
aliases path = case segments (normalise path) of
  "private" : top : rest | top `elem` linked -> [normalise path, rebuild (top : rest)]
  top : rest | top `elem` linked -> [normalise path, rebuild ("private" : top : rest)]
  _ -> [normalise path]
  where
    linked = ["tmp", "var", "etc"]
    rebuild names = '/' : intercalate "/" names

-- | Whether a path is protected: one of the anchors (under either macOS
-- name), an ancestor of one, or a per-user temporary directory on macOS
-- (@/var/folders/xx/yyy/T@) or an ancestor of one.
protects :: [FilePath] -> FilePath -> Bool
protects anchors path = any (within path) (concatMap aliases anchors) || perUserTemporary
  where
    perUserTemporary = case dropPrivate (segments (normalise path)) of
      "var" : "folders" : rest -> length rest < 3 || (length rest == 3 && last rest == "T")
      _ -> False
    dropPrivate ("private" : rest) = rest
    dropPrivate names = names

-- | The paths a guarded effect targets, with the operation's name: both of
-- a rename's.
guardedTargets :: Effect a -> [(String, FilePath)]
guardedTargets effect = case effect of
  WriteFile _ _ path _ -> [(effectName effect, path)]
  Remove _ path -> [(effectName effect, path)]
  Rename from to -> [(effectName effect, from), (effectName effect, to)]
  MakeDirectories _ path -> [(effectName effect, path)]
  _ -> []

-- | The operations whose targets must lie strictly inside a write root:
-- removing or renaming a write root itself is refused.
strictlyInside :: [String]
strictlyInside = ["remove", "rename"]

-- | The guard's rules over paths in one form (lexical, or resolved by a
-- host): the anchors that no write root may be or contain, those that only
-- a project root may be or contain, the project roots, the write roots, and
-- the effect's targets. Each path is paired with the form a message names.
guarding :: [FilePath] -> [FilePath] -> [FilePath] -> [(FilePath, FilePath)] -> [(String, FilePath, FilePath)] -> Maybe String
guarding hard soft projects roots targets =
  listToMaybe ([problem | (shown, root) <- roots, Just problem <- [rootProblem shown root]] ++ [problem | target <- targets, Just problem <- [targetProblem target]])
  where
    rootProblem shown root
      | protects hard root || (protects soft root && not (any (same root) projects)) =
          Just ("a write root is a protected path or contains one: " ++ shown)
      | otherwise = Nothing
    targetProblem (operation, shown, path)
      | protects (hard ++ soft) path = Just (operation ++ " of a protected path, or of an ancestor of one, is refused: " ++ shown)
      | operation `elem` strictlyInside && (any (same path . snd) roots || not (any ((`within` path) . snd) roots)) =
          Just (operation ++ " is allowed only strictly inside a write root, never of one: " ++ shown)
      | otherwise = Nothing
    same left right = normalise left == normalise right

-- | The anchors no write root may be or contain, and those only a project
-- root may: the fixed system paths with the policy's protected paths, then
-- the working directory with the project roots.
anchors :: Policy -> ([FilePath], [FilePath])
anchors policy = (systemProtected ++ protectedPaths policy, maybeToList (workingDirectory policy) ++ projectRoots policy)

-- | The guard, lexically: 'Nothing' when it allows the effect, or why not.
-- A write, removal or directory creation may not target a protected path
-- or an ancestor of one; a removal, and each path of a rename, must name a
-- path strictly inside a write root and not a write root itself; and while a write root is a protected path or contains one
-- (a project root may be a write root itself), no effect that touches a
-- path is allowed. Malformed requests are left to 'allows'.
guardrail :: Policy -> Effect a -> Maybe String
guardrail policy effect
  | null paths || any (not . isAbsolute) paths = Nothing
  | otherwise = guarding hard soft (projectRoots policy) [(root, normalise root) | root <- writeRoots policy] target
  where
    paths = [path | (_, _, path) <- touched effect]
    (hard, soft) = anchors policy
    target = [(operation, path, normalise path) | (operation, path) <- guardedTargets effect]

-- | The guard again over the paths a host resolves through symbolic links:
-- the target as 'touched' resolves it, and the write roots, anchors and
-- project roots whole. The anchors are kept in their lexical form as well.
guardrailResolved :: (Monad m) => (Resolution -> FilePath -> m FilePath) -> Policy -> Effect a -> m (Maybe String)
guardrailResolved resolve policy effect
  | null (touched effect) = pure Nothing
  | otherwise = do
      let (hard, soft) = anchors policy
          whole = resolve Whole . normalise
      hard' <- mapM whole hard
      soft' <- mapM whole soft
      projects <- mapM whole (projectRoots policy)
      roots <- mapM (\root -> (,) root <$> whole root) (writeRoots policy)
      target <-
        mapM
          ( \(operation, path) -> do
              let resolution = fromMaybe Whole (listToMaybe [how | (WriteAccess, how, touchedPath) <- touched effect, touchedPath == path])
              real <- resolve resolution (normalise path)
              pure (operation, path, real)
          )
          (guardedTargets effect)
      pure (guarding (hard ++ hard') (soft ++ soft') (projectRoots policy ++ projects) roots target)
