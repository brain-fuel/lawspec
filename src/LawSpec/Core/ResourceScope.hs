-- | Generated resource sharing keys have checked scope provenance, so names
-- can move without changing identity. Explicit keys retain literal meaning.
module LawSpec.Core.ResourceScope (resourceSharingKey, validateResourceSharing) where

import Control.Monad (unless)
import LawSpec.Core

-- | Match the key used by native runtimes exactly; never infer provenance
-- by stripping a prefix from an arbitrary user key.
resourceSharingKey :: Property -> Resource -> ResourceSharingScope -> String
resourceSharingKey property resource scope = case scope of
  ResourcePerRun -> "run/" ++ resourceName
  ResourcePerUnit -> unitName ++ "/" ++ resourceName
  ResourcePerLaw -> unitName ++ "/law " ++ propertyName property ++ "/" ++ resourceName
  ResourceGroup group -> unitName ++ "/group " ++ group ++ "/" ++ resourceName
  where
    unitName = takeWhile (/= ':') (idText (propertyId property))
    resourceName = case binderType (resourceBinder resource) of
      Constructor name _ -> reverse (takeWhile (/= ':') (reverse name))
      _ -> ""

-- | Admission checks the runtime key and group against the claimed scope.
-- A malformed claim cannot erase the actual key from semantic identity.
validateResourceSharing :: Property -> Resource -> Either String ()
validateResourceSharing property resource = case resourceSharedScope resource of
  Nothing -> pure ()
  Just scope -> do
    unless (resourceShared resource == Just (resourceSharingKey property resource scope))
      (Left "a generated resource sharing key does not match its scope provenance")
    unless (resourceReset resource /= Nothing)
      (Left "a shared resource requires reset")
    case scope of
      ResourcePerLaw -> unless (harnessGroup (propertyHarness property) == Nothing)
        (Left "a per-law resource cannot claim a named sharing group")
      ResourceGroup group -> unless (harnessGroup (propertyHarness property) == Just group)
        (Left "a resource's named sharing group does not match its harness")
      _ -> pure ()
