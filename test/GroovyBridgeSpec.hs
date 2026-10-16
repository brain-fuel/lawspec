module GroovyBridgeSpec (test_groovyJavaBody) where

import Data.List (isInfixOf)
import Test.Hspec
import LawSpec.Groovy.Spock (needsJavaBody, javaBodySpecification)

test_groovyJavaBody :: Spec
test_groovyJavaBody = describe "large Groovy execution bodies" $ do
  it "retains independent Spock features, skip metadata and original Java harness bodies" $ do
    let source = unlines
          [ "package example;", "import org.junit.jupiter.api.Test;"
          , "@org.junit.jupiter.api.TestMethodOrder(lawspec.testing.LawSpecOrder.class)"
          , "public final class SearchLawSpecTest {"
          , "  private void harness() { throw new AssertionError(\"failure\"); }"
          , "  @Test", "  void first() throws Throwable {", "    harness();", "  }"
          , "  @org.junit.jupiter.api.Disabled(\"deferred\")"
          , "  @Test", "  void skipped() {}", "}" ]
        (body,specification) = javaBodySpecification "SearchLawSpecTest" (\name -> name ++ " $ result") source
    body `shouldSatisfy` isInfixOf "public final class SearchLawSpecTestBody"
    body `shouldSatisfy` isInfixOf "public void first() throws Throwable"
    body `shouldSatisfy` isInfixOf "harness();"
    body `shouldNotSatisfy` isInfixOf "@Test"
    specification `shouldSatisfy` isInfixOf "@lawspec.testing.LawSpecRandomOrder"
    specification `shouldSatisfy` isInfixOf "@spock.lang.Ignore('deferred')"
    specification `shouldSatisfy` isInfixOf "def \"first \\$ result\"()"
    specification `shouldSatisfy` isInfixOf "new SearchLawSpecTestBody().first();"
    specification `shouldSatisfy` isInfixOf "new SearchLawSpecTestBody().skipped();"
    specification `shouldNotSatisfy` isInfixOf "throw new AssertionError"
  it "selects the bridge independently of whitespace and literal formatting" $ do
    let callbacks = concat (replicate 128 "LawSpecRuntime.let(value, x -> x)")
    needsJavaBody callbacks `shouldBe` True
    needsJavaBody (unlines (replicate 128 "  LawSpecRuntime.let(value, x -> x)")) `shouldBe` True
    needsJavaBody (concat (replicate 127 "LawSpecRuntime.let(value, x -> x)")) `shouldBe` False
