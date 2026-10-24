-- | Content identity: what changes a semantic hash, and what does not.
module IdentitySpec (test_semanticIdentityIsBehaviourAndPresentationIsTheRest) where

import qualified Data.Map.Strict as M
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Dependencies (Identity(..), Ref(..), dependencyGraph, identityOf, nodeIdentity)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)

-- | A program's laws and declarations by their source names, each with its
-- identity.
identities :: [String] -> M.Map String Identity
identities source = M.fromList $
  [ (filter (`notElem` ("\"|" :: String)) (C.propertyName p), identityOf graph p) | u <- C.programUnits program, p <- C.unitProperties u ] ++
  [ (C.declarationName (C.definitionDeclaration d), i) | u <- C.programUnits program, d <- C.unitDefinitions u
  , Just i <- [nodeIdentity graph (DeclarationNode (C.declarationId (C.definitionDeclaration d)))] ] ++
  [ (C.dataName d, i) | d <- C.programDataDeclarations program, Just i <- [nodeIdentity graph (TypeNode (C.dataId d))] ]
  where
    program = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines source)])
    graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)

base :: [String]
base =
  [ "unit identity.example", ""
  , "function double (x :: Integer) -> Integer is x + x end function", ""
  , "function triple (x :: Integer) -> Integer is x + x + x end function", ""
  , "function count (xs :: List Integer) -> Integer is"
  , "  first matching case of xs :"
  , "    when Nil then 0"
  , "    when Cons head tail then 1 + count tail"
  , "  end case"
  , "end function", ""
  , "law \"|doubles| is"
  , "  description: \"Doubling adds a number to itself.\" end description"
  , "  definition : for all (x :: Integer) => double x = x * 2 end for all end definition"
  , "end law", ""
  , "law \"|counts| is definition : for all (xs :: List Integer) => count xs >= 0 end for all end definition end law", ""
  , "end unit" ]

edit :: String -> String -> [String] -> [String]
edit from to = map (replace from to)
  where
    replace a b s | null s = s
                  | a `isPrefixOf'` s = b ++ replace a b (drop (length a) s)
                  | otherwise = head s : replace a b (tail s)
    isPrefixOf' a s = take (length a) s == a

semantic, names, shown :: String -> M.Map String Identity -> Identity -> Bool
semantic key m i = fmap semanticHash (M.lookup key m) == Just (semanticHash i)
names key m i = fmap namesHash (M.lookup key m) == Just (namesHash i)
shown key m i = fmap presentationHash (M.lookup key m) == Just (presentationHash i)

-- | A law's tests and proofs are keyed by its semantic hash, so the hash
-- must change exactly when behaviour does, and every edit that keeps
-- behaviour must leave it alone. The presentation hash carries the rest.
-- ref:DEC-content-identity
test_semanticIdentityIsBehaviourAndPresentationIsTheRest :: Spec
test_semanticIdentityIsBehaviourAndPresentationIsTheRest = describe "content identity" $ do
  let before = identities base
      at key = before M.! key
      same key after = semantic key after (at key)
  it "keeps the semantic hash when a bound local is renamed" $ do
    let after = identities (edit "(x :: Integer) -> Integer is x + x end" "(y :: Integer) -> Integer is y + y end" base)
    same "double" after `shouldBe` True
    same "doubles" after `shouldBe` True
    names "double" after (at "double") `shouldBe` False
  it "keeps the semantic hash when a law's bound input is renamed" $ do
    let after = identities (edit "for all (x :: Integer) => double x = x * 2" "for all (n :: Integer) => double n = n * 2" base)
    same "doubles" after `shouldBe` True
    shown "doubles" after (at "doubles") `shouldBe` False
  it "keeps the semantic and names hashes when the source is reformatted" $ do
    let after = identities (concatMap (\line -> [line, ""]) (edit "x + x + x" "x  +  x  +  x" base))
    [k | k <- everything, not (same k after && names k after (at k))] `shouldBe` []
    shown "doubles" after (at "doubles") `shouldBe` False
  it "keeps every hash when declarations are reordered" $ do
    let (header, rest) = splitAt 2 base
        after = identities (header ++ drop 2 rest ++ take 2 rest)
    [k | k <- everything, not (same k after && names k after (at k))] `shouldBe` []
  it "keeps a caller's semantic hash when a definition is renamed" $ do
    let after = identities (edit "double" "twice" base)
    semantic "twice" after (at "double") `shouldBe` True
    semantic "twices" after (at "doubles") `shouldBe` True
    names "twices" after (at "doubles") `shouldBe` False
  it "keeps the semantic and names hashes when a description is edited" $ do
    let after = identities (edit "Doubling adds a number to itself." "Doubling a number adds it to itself." base)
    same "doubles" after `shouldBe` True
    names "doubles" after (at "doubles") `shouldBe` True
    shown "doubles" after (at "doubles") `shouldBe` False
  it "keeps a law's hashes when a definition it does not reach is edited" $ do
    let after = identities (edit "x + x + x" "x * 3" base)
    same "doubles" after `shouldBe` True
    shown "doubles" after (at "doubles") `shouldBe` True
    same "triple" after `shouldBe` False
  it "changes the semantic hash on a behaviour edit" $ do
    let after = identities (edit "x * 2" "x + x" base)
    same "doubles" after `shouldBe` False
  it "changes a law's semantic hash when a definition it reaches changes behaviour" $ do
    let after = identities (edit "is x + x end" "is x * 2 end" base)
    same "double" after `shouldBe` False
    same "doubles" after `shouldBe` False
    same "counts" after `shouldBe` True
  it "hashes a recursive definition as a group, the same under renaming" $ do
    let after = identities (edit "tail" "rest" (edit "count" "size" base))
    semantic "size" after (at "count") `shouldBe` True
    semantic "sizes" after (at "counts") `shouldBe` True
    let changed = identities (edit "1 + count tail" "2 + count tail" base)
    same "count" changed `shouldBe` False
    same "counts" changed `shouldBe` False
  it "leaves names and spans out of the semantic encoding" $
    show (semanticHash (at "doubles")) `shouldSatisfy` (not . ("doubles" `isInfixOf`))
  where
    everything = ["double", "triple", "count", "doubles", "counts"]
