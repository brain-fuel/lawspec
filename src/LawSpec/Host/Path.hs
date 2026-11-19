-- | Lexical POSIX path arithmetic, with the semantics of Node's path.posix
-- (resolve, join, relative), so commands compute the same paths on every
-- host without asking one. Windows paths are out of scope, as Windows is an
-- unsupported platform (DEC-haskell-application-port).
-- ref:DEC-host-effect-abi
module LawSpec.Host.Path
  ( normalise,
    resolve,
    join,
    relative,
    within,
    takeDirectory,
    isAbsolute,
    segments,
  )
where

import Data.List (intercalate, isPrefixOf)

isAbsolute :: FilePath -> Bool
isAbsolute = ("/" `isPrefixOf`)

-- | A path's names, split at its separators, with empty names dropped.
segments :: FilePath -> [String]
segments = filter (not . null) . split
  where
    split text = case break (== '/') text of
      (part, []) -> [part]
      (part, _ : rest) -> part : split rest

-- | Collapse @.@, @..@ and repeated or trailing separators. An absolute path
-- never climbs above the root; a relative one keeps leading @..@.
normalise :: FilePath -> FilePath
normalise path
  | isAbsolute path = '/' : intercalate "/" (fold True (segments path))
  | otherwise = case intercalate "/" (fold False (segments path)) of
      [] -> "."
      text -> text
  where
    fold absolute = reverse . foldl (step absolute) []
    step _ kept "." = kept
    step absolute kept ".." = case kept of
      (top : rest) | top /= ".." -> rest
      _ | absolute -> kept
      _ -> ".." : kept
    step _ kept part = part : kept

-- | path.posix.resolve(base, path) with an absolute base.
resolve :: FilePath -> FilePath -> FilePath
resolve base path
  | isAbsolute path = normalise path
  | otherwise = normalise (base ++ "/" ++ path)

-- | path.posix.join(left, right).
join :: FilePath -> FilePath -> FilePath
join left right = normalise (left ++ "/" ++ right)

-- | path.posix.relative(from, to) for absolute paths.
relative :: FilePath -> FilePath -> FilePath
relative from to = intercalate "/" (replicate (length rest) ".." ++ target)
  where
    (rest, target) = strip (segments (normalise from)) (segments (normalise to))
    strip (a : as) (b : bs) | a == b = strip as bs
    strip as bs = (as, bs)

-- | Whether a normalised absolute path is the root itself or below it.
within :: FilePath -> FilePath -> Bool
within root path = rootSegments `isPrefixOf` segments (normalise path)
  where
    rootSegments = segments (normalise root)

-- | path.posix.dirname for a normalised absolute path.
takeDirectory :: FilePath -> FilePath
takeDirectory path = case reverse (segments path) of
  [] -> "/"
  _ : rest -> '/' : intercalate "/" (reverse rest)
