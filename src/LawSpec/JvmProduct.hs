-- | A JVM backend product keeps its files and checked integration interfaces
-- together. Public generation APIs project the files; Groovy and Clojure use
-- the signatures and case plans without inspecting generated source.
-- ref:DEC-readable-output-default
module LawSpec.JvmProduct where

import LawSpec.Common (Artifact)
import qualified LawSpec.JavaAbi as A

-- Paths identify the adapter artifact whose implementation belongs to a user.
data JvmProduct = JvmProduct
  { jvmArtifacts :: [Artifact]
  , jvmAdapters :: [(FilePath, A.Stub)]
  , jvmInterfaces :: [A.InterfaceAbi]
  , jvmCases :: [A.CaseClass]
  } deriving (Eq, Show)

instance Semigroup JvmProduct where
  a <> b = JvmProduct
    (jvmArtifacts a ++ jvmArtifacts b)
    (jvmAdapters a ++ jvmAdapters b)
    (jvmInterfaces a ++ jvmInterfaces b)
    (jvmCases a ++ jvmCases b)

instance Monoid JvmProduct where
  mempty = JvmProduct [] [] [] []

files :: [Artifact] -> JvmProduct
files artifacts = mempty { jvmArtifacts = artifacts }

mapFiles :: ([Artifact] -> [Artifact]) -> JvmProduct -> JvmProduct
mapFiles transform product = product { jvmArtifacts = transform (jvmArtifacts product) }
