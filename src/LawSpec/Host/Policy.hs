-- | The capability policy a command runs under. The core enforces it before
-- a request reaches any host ("LawSpec.Host.Sandbox") and sends it with
-- every effect request, so the host enforces it again independently.
-- ref:DEC-host-effect-abi ref:wasi-capabilities
module LawSpec.Host.Policy
  ( Policy (..),
    closed,
  )
where

data Policy = Policy
  { -- | Directories (or single files) that may be read, listed and stat'ed.
    readRoots :: [FilePath],
    -- | Directories (or single files) that may be written, created and removed.
    -- Every write root is also readable.
    writeRoots :: [FilePath],
    -- | Programs that may be spawned, compared with argv[0] exactly: the
    -- declared toolchains.
    programs :: [FilePath],
    -- | Whether HTTPS fetches are allowed.
    network :: Bool,
    -- | Whether the command may listen for HTTP on the loopback interface.
    listening :: Bool,
    -- | Paths the guard protects besides its fixed system paths: the user's
    -- home and temporary directories, as the host's environment names them.
    -- No write, removal or directory creation may target one of them or an
    -- ancestor of one, and no write root may be one or contain one,
    -- whatever the roots grant ("LawSpec.Host.Sandbox".'guard').
    protectedPaths :: [FilePath],
    -- | The invocation's working directory, protected in the same way.
    workingDirectory :: Maybe FilePath,
    -- | The project roots, protected in the same way, except that a write
    -- root may be a project root exactly: commands write inside it.
    projectRoots :: [FilePath]
  }
  deriving (Eq, Show)

-- | Standard streams, the environment and the clock only.
closed :: Policy
closed = Policy [] [] [] False False [] Nothing []
