{-# LANGUAGE OverloadedStrings #-}

-- | Typed services preserve external formatting and discovery semantics.
-- ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
module ServiceSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import LawSpec.Api (dispatch)
import qualified LawSpec.Authoring as Authoring
import LawSpec.Common
import LawSpec.Component (VersionSelection (..), selectVersions)
import LawSpec.Service.Formatting
import Test.Hspec

spec :: Spec
spec = describe "typed application services" $ do
  it "preserves formatting, default admission, and diagnostic coordinates" $ do
    forM_ sources $ \input -> forM_ [False, True] $ \checked -> do
      let FormatResult output problems = formatStandalone checked input
          response =
            fromMaybe (error "invalid response")
              $ decode
              $ dispatch
              $ encode
              $ object
                [ "schemaVersion" .= (5 :: Int),
                  "languageProfile" .= ("1.0-rc.2" :: String),
                  "verification" .= object ["layers" .= ([] :: [String])],
                  "method" .= ("format" :: String),
                  "sources" .= input,
                  "compile" .= checked
                ]
      case response of
        Object fields -> do
          Just (toJSON problems) `shouldBe` KM.lookup "diagnostics" fields
          toJSON output `shouldBe` fromMaybe (toJSON ([] :: [Source])) (KM.lookup "formattedSources" fields)
        _ -> expectationFailure "expected an object"
    let invalid = [Source "definition.lawspec" "unit bad\nfunction f (x :: Rational) -> Rational is x / 0 end function\nend unit\n"]
    formatDiagnostics (formatStandalone True invalid) `shouldSatisfy` (not . null)
    formatDiagnostics (formatStandalone False invalid) `shouldBe` []

  it "retains optional verification as unselected while formatting law declarations" $ do
    let input = [Source "laws.lawspec" "unit evidence\nfunction id (x :: Int32) -> Int32 is x end function\nlaw identity is definition: for all (x :: Int32) => id x must be x end for all end definition end law\nend unit\n"]
        first = formatStandalone True input
    formatDiagnostics first `shouldBe` []
    formatStandalone True (formattedSources first) `shouldBe` first

  it "retains prelude operation identities, absent definitions and law entries" $ do
    let Authoring.PreludeResult entries source = Authoring.prelude ""
    entries `shouldSatisfy` any (\entry -> case entry of Authoring.PreludeLaw {} -> True; _ -> False)
    entries `shouldSatisfy` any (\entry -> case entry of Authoring.PreludeOperation _ _ Nothing -> True; _ -> False)
    source `shouldSatisfy` (not . null)
    Authoring.prelude "BOOL" `shouldBe` Authoring.prelude "bool"
    Authoring.preludeEntries (Authoring.prelude "no-such-prelude-entry-123") `shouldBe` []

  it "sorts accepted versions and retains candidate errors without accepting them" $ do
    selectVersions "^1.0.0" ["1.2.0", "2.0.0", "1.9.0", "1.0.0"]
      `shouldBe` VersionSelection [] (Just ["1.9.0", "1.2.0", "1.0.0"])
    let VersionSelection problems chosen = selectVersions "^1.0.0" ["invalid", "1.2.0"]
    problems `shouldSatisfy` (not . null)
    chosen `shouldBe` Just ["1.2.0"]
    selectedVersions (selectVersions "not a range" ["1.0.0"]) `shouldBe` Nothing
  where
    sources =
      [ [Source "good.lawspec" "unit good\nfunction f (x :: Int32) -> Int32 is x end function\nend unit\n"],
        [Source "unicode.lawspec" "unit text\nfunction f (x :: Bool) -> Text is \"日本語 😀 café\" end function\nend unit\n"],
        [Source "bad.lawspec" "unit bad\nfunction f (x :: Rational) -> Rational is x / 0 end function\nend unit\n"],
        [Source "syntax.lawspec" "unit bad\nfunction f (x :: Int32) -> Int32 is if then\nend unit\n"],
        [Source "a.lawspec" "unit a\nfunction\n", Source "b.lawspec" "unit b\nfunction\n"],
        []
      ]
