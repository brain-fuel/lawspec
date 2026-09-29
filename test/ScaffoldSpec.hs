-- LawSpec.Scaffold must reproduce npm/templates.mjs byte for byte until the npm
-- CLI uses the Haskell scaffolds (then the JavaScript copy is deleted).
module ScaffoldSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict as M
import System.Process (readProcess)
import Test.Hspec
import LawSpec.Scaffold

spec :: Spec
spec = describe "project scaffolds" $
  forM_ scaffoldTargets $ \target -> forM_ [False, True] $ \minify ->
    it ("match the npm templates for " ++ target ++ (if minify then " (minified)" else "")) $ do
      output <- readProcess "node" ["--input-type=module", "-e",
        "import {templates} from './npm/templates.mjs'; process.stdout.write(JSON.stringify(Object.entries(templates("
          ++ show target ++ ", {minify: " ++ (if minify then "true" else "false") ++ "}))))"] ""
      let expected = maybe (error "invalid template JSON") id (decode (BL.pack output)) :: [(String, String)]
      fmap M.fromList (scaffoldFiles minify target) `shouldBe` Right (M.fromList expected)
      fmap (map fst) (scaffoldFiles minify target) `shouldBe` Right (map fst expected)
