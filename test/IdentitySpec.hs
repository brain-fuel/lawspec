-- | Content identity: what changes a semantic hash, and what does not.
module IdentitySpec (test_semanticIdentityIsBehaviourAndPresentationIsTheRest) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as M
import Data.List (isInfixOf, isPrefixOf)
import Data.Char (isHexDigit)
import qualified LawSpec.Core.Validate as Validate
import qualified LawSpec.Core.Value as Value
import LawSpec.Common (Diagnostic(..))
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Program as Scenario
import LawSpec.Dependencies (Identity(..), Ref(..), dependencyGraph, dependencyGraphWithBits, identityOf, nodeIdentity, semanticKey)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import qualified LawSpec.Core.Smt as Smt
import LawSpec.TestManifest (TestEntry(..), testManifest, testManifestWithNativeContext)
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
  it "changes data and dependent identities when a constructor rename changes portable order" $ do
    let source = ["unit identity.ordering", "type Choice is one of Alpha | Middle end type",
          "function precedes (unused :: Unit) -> Ordering is prelude.compare Alpha Middle end function",
          "law precedence is definition: precedes unitValue = Less end definition end law", "end unit"]
        renamed = edit "Alpha" "Zulu" source
        preserving = edit "Alpha" "Apple" source
        compile text = either (error . show) id (compileCore 64 defaultGeneration [Source "order.lawspec" (unlines text)])
        keys text = map entryKey (testManifest "javascript" Nothing (compile text))
        ordering text =
          let program = compile text
              [declaration] = filter ((== "Choice") . C.dataName) (C.programDataDeclarations program)
              [first,second] = C.dataConstructors declaration
              ty = C.Constructor (C.idText (C.dataId declaration)) []
          in Value.compareValues (Value.DataValue ty (C.constructorId first) []) (Value.DataValue ty (C.constructorId second) [])
    ordering source `shouldBe` Right LT
    ordering renamed `shouldBe` Right GT
    ordering preserving `shouldBe` Right LT
    forM_ ["Choice","precedes","precedence"] $ \name -> do
      semanticHash (identities renamed M.! name) `shouldNotBe` semanticHash (identities source M.! name)
      semanticHash (identities preserving M.! name) `shouldBe` semanticHash (identities source M.! name)
    keys renamed `shouldNotBe` keys source
    keys preserving `shouldBe` keys source
  it "binds recorded renderings to their nominal interface and external files" $ do
    let source = ["unit identity.recording", "type Choice is one of Alpha | Middle end type",
          "function choose (unused :: Unit) -> Choice is Alpha end function",
          "law snapshot is definition: choose unitValue = recorded \"first\" end definition end law",
          "law ordinary is definition: choose unitValue = Alpha end definition end law", "end unit"]
        entries text = testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "recording.lawspec" (unlines text)]))
        keys = map entryKey . entries
        [snapshot,ordinary] = entries source
    map entryCallsAdapters [snapshot,ordinary] `shouldBe` [True,False]
    let [renamedSnapshot,renamedOrdinary] = entries (edit "Alpha" "Apple" source)
    entryKey renamedSnapshot `shouldNotBe` entryKey snapshot
    entryKey renamedOrdinary `shouldBe` entryKey ordinary
    keys (edit "choose" "select" (edit "snapshot" "history" (edit "unused" "ignored" source))) `shouldBe` keys source
    keys (concatMap (\line -> [line, "-- presentation only"]) source) `shouldBe` keys source
    keys (init source ++ ["type Unrelated is one of Separate end type", last source]) `shouldBe` keys source
    let replaceSnapshot section = take 3 source ++ [
          "law snapshot is definition: for all (sample :: Unit) => choose sample = Alpha end for all end definition " ++ section ++ " end law"] ++ drop 4 source
        example = replaceSnapshot "example \"|recording|: sample = unitValue expect choose sample = recorded \"first\" end example"
        documentary = replaceSnapshot "description: \"A case.\\n```example\\nsample = unitValue\\nexpect choose sample = recorded \\\"first\\\"\\n```\" end description"
    forM_ [example,documentary] $ \text -> do
      map entryCallsAdapters (entries text) `shouldBe` [True,False]
      head (keys (edit "Alpha" "Apple" text)) `shouldNotBe` head (keys text)
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
  it "keeps adapter local refactors but tracks exported generated interfaces" $ do
    let source = edit "double x = x * 2" "observe (double x) = observe (x * 2)"
          (take 1 base ++ ["observe :: Integer -> Integer"] ++ drop 1 base)
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec" (unlines text)]))]
    keys (edit "(x :: Integer) -> Integer is x + x end" "(local :: Integer) -> Integer is local + local end" source)
      `shouldBe` keys source
    keys (edit "double" "twice" source) `shouldNotBe` keys source
    keys (edit "observe" "readNative" source) `shouldNotBe` keys source
  it "erases a checked generic definition's specialization provenance from semantic keys" $ do
    let source name variable = unlines
          ["unit identity.generic", "function " ++ name ++ " (value :: " ++ variable ++ ") -> " ++ variable ++ " is value end function",
           "law selected is definition: for all (input :: Int8) => " ++ name ++ " input = input end for all end definition end law", "end unit"]
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "generic.lawspec" text]))]
    keys (source "identity" "a") `shouldBe` keys (source "unchanged" "element")
  it "uses semantic concrete-type suffixes for generic instances under a nominal type rename" $ do
    let source name = unlines
          ["unit identity.genericNames", "type " ++ name ++ " is a record { count :: Integer enabled :: Bool small :: Int8 } end type",
           "function identity (value :: a) -> a is value end function",
           "law selected is definition: for all (input :: " ++ name ++ ") => identity input = input end for all end definition end law", "end unit"]
        suffixes text = [reverse (takeWhile isHexDigit (reverse (C.declarationName declaration))) |
          let program = either (error . show) id (compileCore 64 defaultGeneration [Source "generic.lawspec" text]),
          u <- C.programUnits program, d <- C.unitDefinitions u, let declaration = C.definitionDeclaration d,
          "lawspec_identity_" `isPrefixOf` C.declarationName declaration]
        first = suffixes (source "Before")
    first `shouldSatisfy` (not . null)
    suffixes (source "After") `shouldBe` first
  it "keeps law keys when a resolved strategy or its harness is renamed" $ do
    laws <- readFile "examples/specs/harness.lawspec"
    harness <- readFile "examples/specs/harness_testing.lawspec"
    let keys body = [entryKey entry | entry <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "harness.lawspec" laws, Source "harness_testing.lawspec" body]))]
        renamed = unlines (edit "example.harness.testing" "example.harness.renamed" .
          edit "strategy orders ::" "strategy generatedOrders ::" . edit "use orders for" "use generatedOrders for" $ lines harness)
    keys harness `shouldSatisfy` (not . null)
    keys renamed `shouldBe` keys harness
  it "keeps resource-law keys under a law rename with validated generated sharing scopes" $ do
    original <- readFile "examples/specs/resources.lawspec"
    let source = unlines (edit "share Pool per unit" "share Pool per group" (lines original))
        keys text = [entryKey entry | entry <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source "resources.lawspec" text]))]
        renamed = unlines (edit "a pool starts each case empty" "a pool is reset before a case" (lines source))
    keys source `shouldSatisfy` (not . null)
    keys renamed `shouldBe` keys source
  it "keeps explicit resource keys semantic and rejects forged generated provenance" $ do
    source <- readFile "examples/specs/resources.lawspec"
    let program = either (error . show) id (compileCore 64 defaultGeneration [Source "resources.lawspec" source])
        unit = head [u | u <- C.programUnits program, any (not . null . C.propertyResources) (C.unitProperties u)]
        property = head [p | p <- C.unitProperties unit, not (null (C.propertyResources p))]
        resource = head (C.propertyResources property)
        graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
        keyed value = property { C.propertyResources = [resource { C.resourceShared = Just value, C.resourceSharedScope = Nothing }] }
        forged = property { C.propertyResources = [resource { C.resourceShared = Just "a literal user key", C.resourceSharedScope = Just C.ResourcePerLaw }] }
        replaceProperty p = program { C.programUnits = [if C.unitId candidate == C.unitId unit then candidate { C.unitProperties = [p] } else candidate | candidate <- C.programUnits program] }
    semanticHash (identityOf graph (keyed "first user key")) `shouldNotBe` semanticHash (identityOf graph (keyed "second user key"))
    Validate.validateProgram (replaceProperty forged) `shouldSatisfy`
      either (any (("scope provenance" `isInfixOf`) . message)) (const False)
  it "marks native dependencies reached through a checked workflow" $ do
    let source = unlines ["unit identity.nativeClosure",
          "workflow wrapper :: Integer -> Either Text Integer is",
          "  foreign :: Integer -> Either Text Integer", "end workflow",
          "law selected is definition: for all (value :: Integer) => wrapper value = Right value end for all end definition end law",
          "end unit"]
        program = either (error . show) id (compileCore 64 defaultGeneration [Source "closure.lawspec" source])
        selected = [entryCallsAdapters entry | entry <- testManifest "javascript" Nothing program,
          entryLaw entry == C.Id "identity.nativeClosure::law::selected"]
    selected `shouldBe` [True]
  it "preserves opaque generated API dependencies for explicitly bound native codecs" $ do
    let make body = either (error . show) id (compileCore 64 defaultGeneration [Source "identity.lawspec"
          (unlines (edit "x + x + x" body base))])
        selected opaque program = [(entryKey entry,entryCallsAdapters entry) |
          entry <- testManifestWithNativeContext True opaque "javascript" Nothing program,
          entryLaw entry `elem` [C.propertyId property | unit <- C.programUnits program, property <- C.unitProperties unit,
            filter (`notElem` ("\"|" :: String)) (C.propertyName property) == "doubles"]]
        before = make "x + x + x"
        after = make "x * 3"
    map snd (selected False before) `shouldBe` [False]
    selected False before `shouldBe` selected False after
    map snd (selected True before) `shouldBe` [True]
    map fst (selected True before) `shouldNotBe` map fst (selected True after)
  it "conservatively invalidates opaque model adapters when a callable generated definition changes" $ do
    let fixture = "test/fixtures/canonical-model-layer-selection.lawspec"
    original <- readFile fixture
    let source body = extendUnit original ("function unrelated (value :: Integer) -> Integer is " ++ body ++ " end function")
        keys text = [entryKey e | e <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source fixture text])), entryKind e == Just "model"]
        first = keys (source "value + 1")
    first `shouldSatisfy` (not . null)
    keys (source "value + 2") `shouldNotBe` first
    keys (unlines (edit "Pair n n end function" "Pair 0 n end function" (lines (source "value + 1"))))
      `shouldNotBe` first
  it "keeps admitted model/scenario keys under local/channel renames and isolates a changed scenario" $ do
    let fixture = "test/fixtures/canonical-model-layer-selection.lawspec"
    original <- readFile fixture
    let keys text = [(entryLaw entry,entryKey entry) | entry <- testManifest "javascript" Nothing
          (either (error . show) id (compileCore 64 defaultGeneration [Source fixture text])), entryKind entry == Just "model"]
        rename = unlines . edit "send receipt n" "send transport deposited" .
          edit "n <- deposit 5" "deposited <- deposit 5" . edit "channel receipt ::" "channel transport ::" .
          edit "receive receipt m" "receive transport received" . edit "expect m = 5" "expect received = 5" . lines
        first = keys original
        changed = keys (unlines (edit "expect m = 5" "expect m = 6" (lines original)))
    first `shouldSatisfy` (not . null)
    keys (rename original) `shouldBe` first
    let invalidated = [name | (name,key) <- changed, lookup name first /= Just key]
    invalidated `shouldSatisfy` (not . null)
    invalidated `shouldSatisfy` all (("scenario" `isInfixOf`) . C.idText)
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
  it "resolves a model's state type by semantic identity under a nominal rename" $ do
    let source name = unlines ["unit identity.modelType", "type " ++ name ++ " is a record { identifier :: Int32 } end type",
          "openBox :: Unit -> " ++ name, "bump :: " ++ name ++ " -> Unit",
          "function next (value :: Integer) -> Integer is value + 1 end function",
          "model box :: shared " ++ name ++ " by Integer is", "  start openBox ~ 0", "  bump ~ next", "end model", "end unit"]
        key text = let program = either (error . show) id (compileCore 64 defaultGeneration [Source "state.lawspec" text])
                       graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
                   in semanticHash (identityOf graph (C.unitMachines (head (C.programUnits program))))
    key (source "Carrier") `shouldBe` key (source "Payload")
  it "alpha-normalizes scenario locals, captured fork bindings and delegated channel ends" $ do
    let program variable channel = Scenario.Program "displayed title" "free-machine" [channel]
          [Scenario.Invoke "new" (Just variable) [],
           Scenario.Fork [[Scenario.Deliver channel (Scenario.Variable variable)],
             [Scenario.Accept channel "received" (Just [Scenario.Assert variable (Scenario.IntConst 0)]),
              Scenario.Deliver "received" (Scenario.Literal (Scenario.IntConst 3))]],
           Scenario.Assert variable (Scenario.IntConst 0)] ["Protocol"] "" [] False
        graph = dependencyGraph [] []
        first = identityOf graph (program "outer" "messages")
        renamed = identityOf graph (program "renamed" "transport")
        changed = identityOf graph ((program "renamed" "transport") { Scenario.programActs = [Scenario.Assert "unbound" (Scenario.IntConst 0)] })
    semanticHash renamed `shouldBe` semanticHash first
    namesHash renamed `shouldNotBe` namesHash first
    semanticHash changed `shouldNotBe` semanticHash first
    semanticHash (identityOf graph ((program "outer" "messages") { Scenario.programMachine = "other-free-machine" }))
      `shouldNotBe` semanticHash first
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
