-- | lawspec-smtlib-v1 is frozen. Every task the corpus in
-- test/fixtures/smt-v1 makes keeps its script, task fingerprint and program
-- fingerprint byte for byte, so a receipt recorded for it stays current with
-- no re-run. A task v1 refused may become ready only as lawspec-smtlib-v2.
-- The tasks come through the API's proofTasks method, as `lawspec prove`
-- gets them. When corpus.jsonl is missing the test records it; refreezing
-- means deleting it, which a review sees. ref:DEC-smtlib-encoding-versions
module SmtFrozenSpec (test_smtV1IsFrozen) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Foldable (toList)
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Data.Text (Text, pack)
import qualified Data.Aeson.Key as Key
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec
import qualified LawSpec.Api as API

corpus :: FilePath
corpus = "test/fixtures/smt-v1"

frozen :: FilePath
frozen = corpus </> "corpus.jsonl"

-- | The fields a receipt binds, per task. A refused task keeps only its
-- identity and status: its reason is a message, not a binding.
type Key = (Text, Integer, Text, Text)

tasksOf :: FilePath -> Integer -> String -> IO [(Key, Value)]
tasksOf name bits content = do
  let request = object
        [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
        , "method" .= ("proofTasks" :: String), "machineBits" .= bits
        , "verification" .= object ["layers" .= ["proof" :: String]]
        , "sources" .= [object ["path" .= name, "content" .= content]] ]
  response <- maybe (fail ("no API response for " ++ name)) pure
    (decode (API.dispatch (encode request)) :: Maybe Value)
  rows <- case response of
    Object result | Just (Array tasks) <- K.lookup "proofTasks" result -> pure (toList tasks)
    _ -> fail ("no proof tasks for " ++ name ++ ": " ++ BL.unpack (encode response))
  forM rows $ \row -> case row of
    Object task | Just (String owner) <- K.lookup "owner" task, Just (String law) <- K.lookup "declaration" task -> do
      let fields = if K.lookup "status" task == Just (String "ready")
            then ["owner", "declaration", "status", "encoding", "machineBits", "programFingerprint", "taskFingerprint", "script"]
            else ["owner", "declaration", "status", "encoding", "machineBits"]
          kept = K.filterWithKey (\key _ -> key `elem` fields) task
          key = (pack name, bits, owner, law)
      pure (key, Object (K.insert "source" (String (pack name)) kept))
    _ -> fail ("malformed proof task in " ++ name)

current :: IO [(Key, Value)]
current = do
  names <- sort . filter (".lawspec" `isSuffixOf`) <$> listDirectory corpus
  concat <$> sequence [ readFile (corpus </> name) >>= tasksOf name bits | name <- names, bits <- [32, 64] ]

field :: Text -> Value -> Maybe Value
field name (Object o) = K.lookup (Key.fromText name) o
field _ _ = Nothing

ready :: Value -> Bool
ready row = field "status" row == Just (String "ready")

encoded :: Text -> Value -> Bool
encoded name row = field "encoding" row == Just (String name)

test_smtV1IsFrozen :: Spec
test_smtV1IsFrozen = describe "lawspec-smtlib-v1 receipts" $
  it "keeps every frozen task byte for byte, and gives new features only to v2" $ do
    now <- current
    recorded <- doesFileExist frozen
    unless recorded $ do
      BL.writeFile frozen (BL.unlines (map (encode . snd) now))
      pendingWith ("recorded " ++ frozen ++ "; commit it")
    stored <- map (maybe (error "malformed corpus line") id . decode) . BL.lines <$> BL.readFile frozen
    let keyOf row = case (field "source" row, field "machineBits" row, field "owner" row, field "declaration" row) of
          (Just (String source), Just (Number bits), Just (String owner), Just (String law)) ->
            (source, round bits, owner, law)
          _ -> error "malformed corpus row"
        table = M.fromList now
    length stored `shouldSatisfy` (> 0)
    forM_ stored $ \row -> case M.lookup (keyOf row) table of
      Nothing -> expectationFailure ("a frozen task is gone: " ++ show (keyOf row))
      Just fresh
        | ready row -> (keyOf row, fresh) `shouldBe` (keyOf row, row)
        | ready fresh -> (keyOf row, encoded "lawspec-smtlib-v2" fresh) `shouldBe` (keyOf row, True)
        | otherwise -> pure ()
    let frozenKeys = M.fromList [(keyOf row, ()) | row <- stored]
    forM_ now $ \(key, fresh) -> unless (M.member key frozenKeys || not (ready fresh && encoded "lawspec-smtlib-v1" fresh)) $
      expectationFailure ("a new v1 task is not in the frozen corpus: " ++ show key)
    length (filter ready stored) `shouldSatisfy` (> 0)
