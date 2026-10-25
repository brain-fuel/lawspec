-- | A regression guard for generated tests: both readable and compact output
-- must stay proportional to the specification and its registered obligations.
-- Fixed runtime libraries are separate artifacts, not copied per case.
-- ref:DEC-planned-generation ref:DEC-readable-output-default
module LawSpec.Testing.Size (SizeBudget(..), testSizeBudget, checkTestSize) where

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import LawSpec.Common (Artifact(..), Source(..))

data SizeBudget = SizeBudget { maximumTestBytes :: Integer, maximumTestLines :: Integer }
  deriving (Eq, Show)

-- These are source-size regression limits, not startup or execution budgets.
-- Counting bytes also catches expanded code hidden on a single compact line.
testSizeBudget :: [Source] -> Int -> SizeBudget
testSizeBudget sources obligations = SizeBudget
  (32768 + 48 * sourceBytes + 4096 * toInteger obligations)
  (512 + 2 * sourceBytes + 128 * toInteger obligations)
  where
    sourceBytes = sum [toInteger (B.length (T.encodeUtf8 (T.pack (content source)))) | source <- sources]

checkTestSize :: SizeBudget -> Artifact -> Either String ()
checkTestSize budget artifact
  | ownership artifact /= "generated" || artifactPlacement artifact /= "test" = Right ()
  | bytes <= maximumTestBytes budget && lineCount <= maximumTestLines budget = Right ()
  | otherwise = Left (artifactPath artifact ++ ": generated test exceeds the compact-code budget (" ++
      show bytes ++ " bytes, " ++ show lineCount ++ " lines; limits " ++
      show (maximumTestBytes budget) ++ " bytes, " ++ show (maximumTestLines budget) ++ " lines)")
  where
    bytes = toInteger (B.length (T.encodeUtf8 (T.pack (artifactContent artifact))))
    lineCount = toInteger (length (lines (artifactContent artifact)))
