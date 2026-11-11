-- | Manifest admission inputs retain missing and malformed fields separately.
-- These domain records contain no compiler implementation or external-format AST.
-- ref:DEC-haskell-application-port ref:DEC-application-controller-workers
module LawSpec.Manifest.Types where

-- | A present field of the wrong shape still counts as present for source and
-- identity selection. Decoders must not turn malformed fields into missing ones.
data Field a = Absent | Invalid | Present a deriving (Eq, Show)

-- | Admission needs only the supported version, without materializing arbitrary
-- numeric exponents supplied by an external document.
data ManifestVersion = ManifestVersion1 | UnsupportedManifestVersion deriving (Eq, Show)

data Manifest = Manifest
  { manifestKeys :: [String],
    manifestVersion :: Field ManifestVersion,
    languageProfile :: Field String,
    componentIdentity :: Field Identity,
    packageIdentity :: Field Identity,
    sources :: Field [Field String],
    manifestTargets :: Field [Field Target],
    dependencies :: Field [(String, Field Dependency)],
    packages :: Field [Field String],
    inputs :: Field [Field String],
    assets :: Field [Field String],
    authoringExceptions :: Field [Field AuthoringException],
    provides :: Field [Field Contract],
    requires :: Field [(String, Field Contract)]
  }
  deriving (Eq, Show)

data Identity = Identity
  { identityKeys :: [String],
    identityName :: Field String,
    identityVersion :: Field String
  }
  deriving (Eq, Show)

data Target = Target
  { targetKeys :: [String],
    targetLanguage :: Field String,
    targetRoot :: Field String,
    targetActors :: Field Actors
  }
  deriving (Eq, Show)

-- | A JVM target's actor runtime choice (`:actors {:runtime :pekko}`).
-- A present nil keeps the default runtime. ref:DEC-pekko-runtime
data Actors
  = NoActors
  | Actors
      { actorsKeys :: [String],
        actorsRuntime :: Field String,
        actorsRemote :: Field String
      }
  deriving (Eq, Show)

-- | Recursive source versions retain existing admission behavior, including
-- malformed nested declarations; resolution can apply its own later checks.
data Dependency = VersionRange String | SourceDependency Source deriving (Eq, Show)

data Source = Source
  { sourceKeys :: [String],
    sourceVersion :: Field Dependency,
    sourcePath :: Field String,
    sourceGit :: Field String,
    sourceRevision :: Field String,
    sourceTagPrefix :: Field String,
    sourceSubdirectory :: Field String,
    sourceArchive :: Field String,
    sourceDigest :: Field String
  }
  deriving (Eq, Show)

data AuthoringException = AuthoringException
  { exceptionKeys :: [String],
    exceptionDeclaration :: Field String,
    exceptionRule :: Field String,
    exceptionReason :: Field String
  }
  deriving (Eq, Show)

data Contract = Contract
  { contractKeys :: [String],
    contractName :: Field String,
    contractAbilities :: Field [Field String],
    contractDeclarations :: Field [Field String],
    contractSettings :: Field [Field String]
  }
  deriving (Eq, Show)
