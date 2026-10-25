-- | Content identity: what changes a semantic hash, and what does not.
module IdentitySpec (test_semanticIdentityIsBehaviourAndPresentationIsTheRest) where

import qualified Data.Map.Strict as M
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Dependencies (Identity(..), Ref(..), dependencyGraph, dependencyGraphWithBits, identityOf, nodeIdentity, semanticKey)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import qualified LawSpec.Core.Smt as Smt
import LawSpec.TestManifest (TestEntry(..), testManifest)
import FixtureSource (extendUnit)

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
        after = identities (header ++ init (drop 2 rest) ++ take 2 rest ++ [last rest])
    [k | k <- everything, not (same k after && names k after (at k))] `shouldBe` []
  it "keeps a caller's semantic hash when a definition is renamed" $ do
    let after = identities (edit "double" "twice" base)
    semantic "twice" after (at "double") `shouldBe` True
    semantic "twices" after (at "doubles") `shouldBe` True
    names "twices" after (at "doubles") `shouldBe` False
  it "keeps a unit's names hash when a same-width behaviour edit changes only a dependency's body" $ do
    let unitIdentity source =
          let program = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines source)])
              graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
          in identityOf graph (head (C.programUnits program))
        first = unitIdentity base
        changed = unitIdentity (edit "is x + x end" "is x - x end" base)
    semanticHash changed `shouldNotBe` semanticHash first
    namesHash changed `shouldBe` namesHash first
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
  it "keeps tied-shape recursive graph identities under renaming and declaration reordering" $ do
    let first = cycleIdentities [("alpha","beta","beta"),("beta","alpha","alpha")]
        renamed = cycleIdentities [("zeta","beta","beta"),("beta","zeta","zeta")]
        reordered = cycleIdentities [("beta","zeta","zeta"),("zeta","beta","beta")]
    semantic "zeta" renamed (first M.! "alpha") `shouldBe` True
    semantic "beta" renamed (first M.! "beta") `shouldBe` True
    semanticHash (renamed M.! "zeta") `shouldBe` semanticHash (reordered M.! "zeta")
    semanticHash (first M.! "alpha") `shouldBe` semanticHash (first M.! "beta")
  it "changes tied-shape recursive identities when the call graph changes" $ do
    let first = cycleIdentities [("alpha","beta","beta"),("beta","alpha","gamma"),("gamma","beta","alpha")]
        renamed = cycleIdentities [("zeta","beta","beta"),("beta","zeta","gamma"),("gamma","beta","zeta")]
        changed = cycleIdentities [("alpha","beta","gamma"),("beta","alpha","gamma"),("gamma","beta","alpha")]
    semantic "zeta" renamed (first M.! "alpha") `shouldBe` True
    semantic "beta" renamed (first M.! "beta") `shouldBe` True
    semantic "alpha" changed (first M.! "alpha") `shouldBe` False
  it "keeps adapter-calling test keys under checked local and definition renames" $ do
    let source = edit "double x = x * 2" "observe (double x) = observe (x * 2)"
          (take 1 base ++ ["observe :: Integer -> Integer"] ++ drop 1 base)
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines text)]))]
    keys (edit "(x :: Integer) -> Integer is x + x end" "(local :: Integer) -> Integer is local + local end" source)
      `shouldBe` keys source
    keys (edit "double" "twice" source) `shouldBe` keys source
    keys (edit "observe" "readNative" source) `shouldNotBe` keys source
  it "erases a checked generic definition's specialization provenance from semantic keys" $ do
    let source name variable = unlines
          ["unit identity.generic", "function " ++ name ++ " (value :: " ++ variable ++ ") -> " ++ variable ++ " is value end function",
           "law selected is definition: for all (input :: Int8) => " ++ name ++ " input = input end for all end definition end law", "end unit"]
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "generic.lawspec" text]))]
    keys (source "identity" "a") `shouldBe` keys (source "unchanged" "element")
  it "keeps model test keys when an unrelated checked definition changes" $ do
    let fixture = "test/fixtures/canonical-model-layer-selection.lawspec"
    original <- readFile fixture
    let source body = extendUnit original ("function unrelated (value :: Integer) -> Integer is " ++ body ++ " end function")
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source fixture text])), entryKind e == Just "model"]
        first = keys (source "value + 1")
    first `shouldSatisfy` (not . null)
    keys (source "value + 2") `shouldBe` first
    keys (unlines (edit "Pair n n end function" "Pair 0 n end function" (lines (source "value + 1"))))
      `shouldNotBe` first
  it "reruns no test and no proof after a reformat and a local rename" $ do
    let compiled source = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines source)])
        edited = concatMap (\line -> [line, ""]) (edit "(x :: Integer) -> Integer is x + x end" "(y :: Integer) -> Integer is y + y end" base)
        testKeys program = [ (entryLaw e, entryKey e) | target <- ["python", "rust", "haskell"], e <- testManifest target Nothing program ]
        proofKeys program = either (error . show) (map (\t -> (Smt.taskLaw t, Smt.taskProgram t))) (Smt.proofTasks program)
    testKeys (compiled edited) `shouldBe` testKeys (compiled base)
    length (testKeys (compiled base)) `shouldSatisfy` (> 0)
    proofKeys (compiled edited) `shouldBe` proofKeys (compiled base)
  it "includes machine bounds only in definitions that depend on machine types" $ do
    let identity bits ty =
          let source = unlines ["unit identity.profile", "function identity (value :: " ++ ty ++ ") -> " ++ ty ++ " is value end function", "end unit"]
              program = either (error . show) id (compileCore bits defaultGeneration [Source "profile.lawspec" source])
              graph = dependencyGraphWithBits bits (C.programDataDeclarations program) (C.programUnits program)
              definition = head (C.unitDefinitions (head (C.programUnits program)))
          in semanticHash (identityOf graph definition)
    mapM_ (\ty -> identity 32 ty `shouldNotBe` identity 64 ty) ["IntSize", "UIntSize", "UIntPtr"]
    mapM_ (\ty -> identity 32 ty `shouldBe` identity 64 ty) ["Int32", "UInt64", "Integer"]
  it "keeps distinct Unicode key contexts distinct" $ do
    let program = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines base)])
        graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
        value = head (C.programUnits program)
    semanticKey graph "\x100" value `shouldNotBe` semanticKey graph "\x0" value
  it "leaves names and spans out of the semantic encoding" $
    show (semanticHash (at "doubles")) `shouldSatisfy` (not . ("doubles" `isInfixOf`))
  where
    everything = ["double", "triple", "count", "doubles", "counts"]

-- Internal graph fixtures isolate SCC hashing from admission. Mutual total
-- recursion is deliberately unsupported by the language's current validator;
-- these fixtures exercise the graph representation, not a new admitted
-- program or any claim of termination/proof support.
cycleIdentities :: [(String, String, String)] -> M.Map String Identity
cycleIdentities members = M.fromList [(name, i) | (name, _, _) <- members,
  Just i <- [nodeIdentity graph (DeclarationNode (identity name))]]
  where
    program = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines base)])
    unit = head (C.programUnits program)
    template = head (C.unitDefinitions unit)
    integer = C.scalarType "Integer"
    identity name = C.Id ("identity.cycle::" ++ name)
    make (name, left, right) = template
      { C.definitionDeclaration = (C.definitionDeclaration template)
          { C.declarationId = identity name, C.declarationName = name, C.declarationType = C.Arrow integer integer }
      , C.definitionArguments = [binder]
      , C.definitionBody = C.Expr integer (C.Binary C.Add (C.Numeric integer) (call left) (call right)) origin }
      where
        origin = C.GeneratedFrom (identity name)
        binder = C.Binder (C.Id (name ++ "::input")) "input" integer
        call target = C.Expr integer (C.ExternalCall (identity target)
          [C.Expr integer (C.Local (C.binderId binder)) origin]) origin
    definitions = map make members
    graph = dependencyGraph (C.programDataDeclarations program)
      [unit { C.unitDefinitions = definitions, C.unitDeclarations = map C.definitionDeclaration definitions,
              C.unitContracts = [], C.unitProperties = [] }]
