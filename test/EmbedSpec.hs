-- | The compiler carries runtime/, the bundled examples and the Unicode tables
-- as Template Haskell splices (LawSpec.Embed). Each embedded text must equal
-- its file, decoded as UTF-8, and each walked directory must be embedded
-- whole: a decoding or literal fault would change what every generated
-- project receives. ref:DEC-no-build-output-in-git
module EmbedSpec (test_embeddedSourcesEqualTheirFiles) where

import Control.Monad (forM)
import qualified Data.ByteString as B
import Data.Char (ord)
import Data.List (isSuffixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import LawSpec.App.ExampleSources (exampleSpecifications, paymentsProjects, paymentsSpecification)
import LawSpec.CaseFoldData (caseFoldMappings)
import LawSpec.ClojureSources (clojureSource)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.DotNetSources (dotnetFiles, dotnetSource)
import LawSpec.Embed (Tree (..), defaultsTree, dotnetTree, languageTree, runtimeFiles)
import LawSpec.GroovySources (groovySource)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.SwiftSources (swiftFiles, swiftSource)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec

test_embeddedSourcesEqualTheirFiles :: Spec
test_embeddedSourcesEqualTheirFiles = describe "embedded sources" $ do
  it "equal the runtime files, by key" $ do
    differing <- fmap concat $ forM runtimeFiles $ \(key, file) -> do
      text <- source ("runtime" </> file)
      pure [key | runtimeSource key /= text]
    differing `shouldBe` []
  it "compare text with non-ASCII characters, so the UTF-8 path is checked" $ do
    texts <- mapM (source . ("runtime" </>) . snd) runtimeFiles
    any (> 0x7F) (map ord (concat texts)) `shouldBe` True
  it "embed every file of each walked directory, with its text" $ do
    let trees =
          [ ("runtime/defaults", defaultsTree, defaultSource),
            ("runtime/dotnet", dotnetTree, dotnetSource),
            ("runtime/groovy", languageTree, groovySource),
            ("runtime/clojure", languageTree, clojureSource),
            ("runtime/swift", languageTree, swiftSource)
          ]
    differing <- fmap concat $ forM trees $ \(root, tree, lookupSource) -> do
      paths <- walk tree root ""
      fmap concat $ forM paths $ \path -> do
        text <- source (root </> path)
        pure [root </> path | lookupSource path /= text]
    differing `shouldBe` []
    dotnet <- walk dotnetTree "runtime/dotnet" ""
    swift <- walk languageTree "runtime/swift" ""
    (dotnetFiles, swiftFiles) `shouldBe` (dotnet, swift)
  it "equal the bundled examples" $ do
    names <- sort . filter (".lawspec" `isSuffixOf`) <$> listDirectory "examples/specs"
    specifications <- mapM (\name -> (,) name <$> source ("examples/specs" </> name)) names
    exampleSpecifications `shouldBe` specifications
    source "examples/rc1/native-payments.lawspec" >>= (paymentsSpecification `shouldBe`)
    targets <- sort <$> listDirectory "examples/native-payments"
    projects <- forM targets $ \target -> do
      paths <- walk (Tree (const True) (const True)) ("examples/native-payments" </> target) ""
      (,) target <$> mapM (\path -> (,) path <$> source ("examples/native-payments" </> target </> path)) paths
    paymentsProjects `shouldBe` projects
  it "hold the pinned case folding" $
    length caseFoldMappings `shouldBe` 1585
  where
    source path = T.unpack . T.decodeUtf8 <$> B.readFile path

-- | The files under a directory a tree keeps, as LawSpec.Embed walks them.
walk :: Tree -> FilePath -> FilePath -> IO [FilePath]
walk tree root prefix = do
  entries <- sort <$> listDirectory (root </> prefix)
  fmap concat $ forM entries $ \entry -> do
    let path = if null prefix then entry else prefix </> entry
    directory <- doesDirectoryExist (root </> path)
    if directory
      then if treeEnters tree entry then walk tree root path else pure []
      else pure [path | treeKeeps tree entry]
