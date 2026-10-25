-- | Incremental compilation and its cache keys.
module IncrementalSpec (test_incrementalCompilationGivesTheSameResultAsAFreshOne) where

import Control.Monad (forM_)
import Control.Exception (evaluate)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.ByteString.Lazy as B
import Data.List (find, isInfixOf, isPrefixOf)
import Data.Char (toLower)
import Data.Foldable (toList)
import qualified LawSpec.Code.ECMAScript as ECMAScript
import qualified Data.Aeson.KeyMap as KeyMap
import qualified LawSpec.Code.Doc as Doc
import qualified Data.Binary as Binary
import qualified Control.Monad.State.Strict as State
import Data.Version (showVersion)
import Paths_lawspec (version)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as EmissionContext
import LawSpec.Api (dispatch)
import LawSpec.Dependencies (dependencyGraph, fullKey)
import LawSpec.SurfaceContext (contextFor)
import LawSpec.SourceContext (emptyContext)
import qualified LawSpec.Model as Surface
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Testing (Plan(..), PlannedUnit(..), PlannedProperty(..), planTesting)
import LawSpec.Core.Evidence (Obligation(..))
import qualified Data.ByteString.Lazy.Char8 as BC
import System.Directory (getTemporaryDirectory, removePathForcibly, listDirectory, createDirectoryIfMissing, copyFile)
import System.FilePath ((</>))
import LawSpec.Memo (newPersistentTable, memoized, memoizedState, withCacheDirectory, withoutMemoization)
import LawSpec.Discharge (dischargeEvidence)

-- Read only the structured document prefix of a persisted (document,state)
-- result. The type-private helper state remains owned by the emitter.
documentPrefix :: Binary.Binary a => B.ByteString -> a
documentPrefix bytes = case Binary.decodeOrFail bytes of
  Right (_,_,Right document) -> document
  Right (_,_,Left message) -> error ("cached document failed: " ++ (message :: String))
  Left (_,_,message) -> error message

cachedHelperDocuments :: String -> FilePath -> IO [String]
cachedHelperDocuments target directory = do
  files <- listDirectory directory
  bytes <- mapM (B.readFile . (directory </>)) files
  pure [map toLower (if target `elem` ["javascript","typescript"]
    then ECMAScript.printModule ECMAScript.TypeScript (documentPrefix value)
    else Doc.render (Doc.Pretty 100) (documentPrefix value)) | value <- bytes]

cachedPublicDocuments :: String -> String -> FilePath -> IO [String]
cachedPublicDocuments target kind directory = do
  files <- listDirectory directory
  bytes <- mapM (B.readFile . (directory </>)) files
  pure [map toLower (case target of
    "javascript" -> ECMAScript.printModule ECMAScript.JavaScript (documentPrefix value)
    "typescript" -> ECMAScript.printModule ECMAScript.TypeScript (documentPrefix value)
    "fsharp" -> documentPrefix value
    "python" -> Doc.render (Doc.Pretty 100) (Doc.joinWith Doc.hardline (documentPrefix value))
    "haskell" | kind == "data" -> Doc.render (Doc.Pretty 100) (Doc.joinWith Doc.hardline (documentPrefix value))
    _ -> Doc.render (Doc.Pretty 100) (documentPrefix value)) | value <- bytes]

-- | Two programs that differ only in one law of their second unit. The compiler
-- memoizes stages by content, so a missing input in any key would make one
-- program's result depend on whether the other was compiled first.
programs :: String -> ([(String, String)], [(String, String)])
programs tag = (render "x + 0 = x", render "0 + x = x")
  where
    render law =
      [ ("first.lawspec", unlines
          [ "unit incremental." ++ tag ++ ".first"
          , "double :: Int32 -> Int32"
          , "law \"|double is deterministic| is definition : for all (x :: Int32) => double x = double x end for all end definition end law\n", "end unit" ])
      , ("second.lawspec", unlines
          [ "unit incremental." ++ tag ++ ".second"
          , "identity :: Int32 -> Int32"
          , "law \"|zero is neutral| is definition: for all (x :: Int32) => " ++ law ++ " end for all end definition end law", "end unit" ]) ]

request :: String -> String -> [(String, String)] -> B.ByteString
request method target sources = encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String)
  , "method" .= method
  , "target" .= target
  , "verification" .= object ["layers" .= (["proof","exhaustive","property","examples","runtime","model"] :: [String])]
  , "sources" .= [object ["path" .= path, "content" .= content] | (path, content) <- sources] ])

response :: B.ByteString -> Maybe Value
response = decode . dispatch

-- | Reusing earlier work is only safe when it cannot be observed: each program
-- must get exactly the result a fresh compile would give.
-- ref:DEC-incremental-compilation ref:REQ-incremental-compilation
test_incrementalCompilationGivesTheSameResultAsAFreshOne :: Spec
test_incrementalCompilationGivesTheSameResultAsAFreshOne = describe "incremental compilation" $ do
  it "gives each program the same result whatever was compiled before" $ do
    let (one, two) = programs "order"
        targets = ["python", "java", "haskell"]
        runs programs' = [response (request "planGeneration" t p) | p <- programs', t <- targets]
        forwards = runs [one, two, one]
        backwards = runs [two, one, two]
    forwards `shouldSatisfy` all (maybe False (const True))
    take 3 forwards `shouldBe` take 3 (drop 3 backwards)
    take 3 (drop 3 forwards) `shouldBe` take 3 backwards
    drop 6 forwards `shouldBe` take 3 forwards
    take 3 forwards `shouldNotBe` take 3 (drop 3 forwards)
  it "answers every method and target from the same compiled program" $ do
    let (one, _) = programs "methods"
        check = response (request "check" "" one)
    check `shouldSatisfy` maybe False (const True)
    response (request "check" "python" one) `shouldBe` check

  describe "dependency keys" $ do
    it "digests with SHA-256" $ do
      digestHex (digestString "") `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      digestHex (digestString "abc") `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    it "changes a law's key exactly when something it reaches changes" $ do
      let before = keys "x * 3"
          after = keys "x + x + x"
      lookup "|doubles|" after `shouldBe` lookup "|doubles|" before
      lookup "|triples|" after `shouldNotBe` lookup "|triples|" before
    it "plans a law from the types it reaches" $ do
      let alone = planOf "|score|" [wrapper "Score" "0"]
          beside = planOf "|score|" [wrapper "Score" "0", wrapper "Wide" "1234"]
      beside `shouldBe` alone
      fmap (isInfixOf "1234" . show) beside `shouldBe` Just False
    it "reports the boundary cases the generated tests use" $ do
      let program = compiled $ unlines ["unit incremental.evidence\n", wrapper "Score" "0", wrapper "Wide" "1234",
            "law \"|score| is definition : for all (s :: Score) => s = s end for all end definition end law\n", "end unit"]
          Right plan = planTesting program
          Right evidence = dischargeEvidence program
          planned = [length (boundaryCases q) | u <- plannedUnits plan, q <- plannedProperties u]
          reasons = [obligationReason o | o <- evidence, obligationStage o == "law"]
      planned `shouldSatisfy` (not . null)
      reasons `shouldSatisfy` all (\r -> any (\n -> (show n ++ " boundary case") `isInfixOf` r) planned)
  describe "surface memo contexts" $ do
    let declarations = C.programDataDeclarations (compiled (unlines
          ["unit incremental.context", wrapper "Score" "0", wrapper "Wide" "1234", "end unit"]))
        selected value bindings = let (_, ds, _) = contextFor bindings declarations emptyContext value
                                  in map C.dataName ds
    it "leaves unrelated nominal types and signatures out of a law's presentation memo" $ do
      let (bindings, _, _) = contextFor [("unused", Surface.Named "Wide")] declarations emptyContext (Surface.Named "Score")
      bindings `shouldBe` []
      selected (Surface.Named "Score") [] `shouldContain` ["Score"]
      selected (Surface.Named "Score") [] `shouldSatisfy` (not . elem "Wide")
    it "closes called signatures through their nominal argument and result types" $ do
      selected (Surface.Var "convert")
        [("convert", Surface.Arrow (Surface.Named "Score") (Surface.Named "Wide"))]
        `shouldContain` ["Score", "Wide"]
    it "finds nominal owners mentioned by constructor literals and dependent annotations" $ do
      selected (Surface.ConstructLit "Score" [Surface.Number 1]) [] `shouldContain` ["Score"]
      selected (Surface.Annotate (Surface.Var "input") (Surface.Named "Wide")) [] `shouldContain` ["Wide"]
  describe "structured emission chunks" $ do
    it "keeps helper names distinct when a friendly name equals another type's digest fallback" $ do
      let graph = dependencyGraph [] []
          int = C.Constructor "Int32" []
          other = C.Constructor "Int64" []
          unit = C.Constructor "Unit" []
          alias = "collision_" ++ Identity.semanticKey graph "typed-helper" int
          base _ ty = if ty == unit then alias else "collision"
          names = EmissionContext.helperAllocation graph [] base ["convert"] [int,other,unit]
      M.size names `shouldBe` 3
      S.size (S.fromList (M.elems names)) `shouldBe` 3
      EmissionContext.helperAllocation graph [] base ["convert"] [unit,other,int] `shouldBe` names

    it "round-trips layout decisions without reading generated source" $ do
      let document = Doc.group (Doc.text "function" <> Doc.nest 2 (Doc.softline <> Doc.parens (Doc.text "argument")))
          restored = Binary.decode (Binary.encode document)
      restored `shouldBe` document
      mapM_ (\layout -> Doc.render layout restored `shouldBe` Doc.render layout document)
        [Doc.Pretty 80, Doc.Pretty 8, Doc.Compact]
    it "replays helper state with a cached document and separates incoming states" $ do
      table <- newPersistentTable "structured-transition-probe" 256 (length . show)
      let action :: State.StateT [String] (Either String) Doc.Doc
          action = do
            before <- State.get
            State.put (before ++ ["conversion"])
            pure (Doc.text "call conversion")
          run state computation = State.runStateT (memoizedState table "same-node" computation) state
      run ["initial"] action `shouldBe` Right (Doc.text "call conversion", ["initial", "conversion"])
      run ["initial"] (error "re-lowered a cached structured chunk")
        `shouldBe` Right (Doc.text "call conversion", ["initial", "conversion"])
      run ["different"] action `shouldBe` Right (Doc.text "call conversion", ["different", "conversion"])
    forM_ ["rust", "swift", "erlang"] $ \target -> it ("reuses an unchanged " ++ target ++ " function document after an unrelated body edit") $ do
      root <- (</> ("lawspec-" ++ target ++ "-definition-memo-test")) <$> getTemporaryDirectory
      removePathForcibly root
      let run body = decode (dispatch (encode (object
            ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
             "method" .= ("planGeneration" :: String), "target" .= (target :: String), "cacheDirectory" .= root,
             "sources" .= [object ["path" .= ("chunks.lawspec" :: String), "content" .= unlines
               ["unit incremental.nativeChunks",
                "function unrelated (value :: Integer) -> Integer is value + " ++ body ++ " end function",
                "function unchanged (value :: Integer) -> Integer is value + value end function", "end unit"]]]]))) :: Maybe Value
          good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
          good _ = False
      run "1" `shouldSatisfy` good
      [versioned] <- listDirectory root
      let tableName = "typed-" ++ (if target == "erlang" then "beam" else target) ++ "-function"
      first <- listDirectory (root </> versioned </> tableName)
      length first `shouldBe` 2
      run "(if value >= 0 then 2 else -2 end if)" `shouldSatisfy` good
      second <- listDirectory (root </> versioned </> tableName)
      length second `shouldBe` 3
      removePathForcibly root
    forM_ [("fsharp","typed-fsharp-function"),("haskell","typed-haskell-function")] $ \(target,table) ->
      it ("reuses an unchanged " ++ target ++ " function when an earlier function requests a new byte literal") $ do
        root <- (</> ("lawspec-" ++ target ++ "-literal-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let run body = decode (dispatch (encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("chunks.lawspec" :: String), "content" .= unlines
                 ["unit incremental.fsharpChunks",
                  "function unrelated (value :: Bytes) -> Bytes is " ++ body ++ " end function",
                  "function unchanged (value :: Integer) -> Bytes is bytes([9]) end function", "end unit"]]]]))) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "value" `shouldSatisfy` good
        [versioned] <- listDirectory root
        first <- listDirectory (root </> versioned </> table)
        length first `shouldBe` 2
        run "bytes([1, 2, 3])" `shouldSatisfy` good
        second <- listDirectory (root </> versioned </> table)
        length second `shouldBe` 3
        -- A cached function must replay its own request even if another function
        -- now introduces a distinct literal before it in the module.
        removePathForcibly root
    forM_ [("java","typed-jvm-function"),("kotlin","typed-jvm-function"),("scala","typed-jvm-function"),("python","typed-python-function"),("javascript","typed-web-function"),("typescript","typed-web-function"),("go","typed-go-function"),("haskell","typed-haskell-function")] $ \(target, table) ->
      it ("reuses an unchanged " ++ target ++ " function when an earlier function requests a new helper") $ do
        root <- (</> ("lawspec-" ++ target ++ "-definition-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let run body = decode (dispatch (encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("chunks.lawspec" :: String), "content" .= unlines
                 ["unit incremental.helperChunks",
                  "function unrelated (value :: Integer) -> Integer is " ++ body ++ " end function",
                  "function unchanged (values :: List Integer) -> Bool is values = values end function", "end unit"]]]]))) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "value + 1" `shouldSatisfy` good
        [versioned] <- listDirectory root
        first <- listDirectory (root </> versioned </> table)
        length first `shouldBe` 2
        run "if [\"x\"] = [\"x\"] then value else -value end if" `shouldSatisfy` good
        second <- listDirectory (root </> versioned </> table)
        length second `shouldBe` 3
        removePathForcibly root
    it "separates Go operation plans by machine profile while reusing pure functions" $ do
      root <- (</> "lawspec-go-operation-memo-test") <$> getTemporaryDirectory
      removePathForcibly root
      let run bits = decode (dispatch (encode (object
            ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
             "method" .= ("planGeneration" :: String), "target" .= ("go" :: String), "cacheDirectory" .= root,
             "machineBits" .= (bits :: Int), "sources" .= [object ["path" .= ("chunks.lawspec" :: String), "content" .= unlines
               ["unit incremental.goOperations", "ability Echo is echo :: Integer -> Integer end ability",
                "procedure selected (value :: Integer) -> Integer is echo value end procedure",
                "function unchanged (value :: Integer) -> Integer is value + value end function", "end unit"]]]]))) :: Maybe Value
          good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
          good _ = False
      run 64 `shouldSatisfy` good
      [versioned] <- listDirectory root
      first <- listDirectory (root </> versioned </> "typed-go-function")
      length first `shouldBe` 2
      run 32 `shouldSatisfy` good
      second <- listDirectory (root </> versioned </> "typed-go-function")
      length second `shouldBe` 3
      removePathForcibly root
    forM_ [("java","typed-jvm-data"),("kotlin","typed-jvm-data"),("scala","typed-jvm-data"),("go","typed-go-data"),("haskell","typed-haskell-data")] $ \(target,table) ->
      it ("reuses an independent " ++ target ++ " type document after another type changes") $ do
        root <- (</> ("lawspec-" ++ target ++ "-type-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let run fieldType = decode (dispatch (encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("chunks.lawspec" :: String), "content" .= unlines
                 ["unit incremental.goTypes", "type Changed is a record { value :: " ++ fieldType ++ " } end type",
                  "type Independent is a record { label :: Text } end type",
                  "function first (value :: Changed) -> Changed is value end function",
                  "function second (value :: Independent) -> Independent is value end function", "end unit"]]]]))) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "Integer" `shouldSatisfy` good
        [versioned] <- listDirectory root
        first <- listDirectory (root </> versioned </> table)
        length first `shouldSatisfy` (> 0)
        run "Int32" `shouldSatisfy` good
        second <- listDirectory (root </> versioned </> table)
        length second `shouldBe` length first + 1
        removePathForcibly root
    forM_ [("java","typed-jvm-helper",2),("kotlin","typed-jvm-helper",2),("scala","typed-jvm-helper",2),("python","typed-python-helper",2),("javascript","typed-web-helper",2),("typescript","typed-web-helper",2),
           ("go","typed-go-helper",4),("haskell","typed-haskell-helper",2),("swift","swift-data",2),("erlang","typed-beam-helper",2),
           ("erlang","beam-public-data",2),("elixir","beam-public-data",1),("gleam","beam-public-data",1)] $ \(target,table,changed) ->
      it ("reuses independent " ++ target ++ " " ++ table ++ " codec documents after another type changes") $ do
        root <- (</> ("lawspec-" ++ target ++ "-" ++ table ++ "-helper-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let run fieldType = decode (dispatch (encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("helpers.lawspec" :: String), "content" .= unlines
                 ["unit incremental.codecTypes" ++ filter (/= '-') table, "type Changed is a record { value :: " ++ fieldType ++ " } end type",
                  "type Independent is a record { label :: Text } end type",
                  "function first (value :: Changed) -> Changed is value end function",
                  "function second (value :: Independent) -> Independent is value end function", "end unit"]]]]))) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "Integer" `shouldSatisfy` good
        [versioned] <- listDirectory root
        let directory = root </> versioned </> table
            documents name = filter (isInfixOf name)
        first <- cachedHelperDocuments target directory
        documents "independent" first `shouldSatisfy` (not . null)
        run "Int32" `shouldSatisfy` good
        second <- cachedHelperDocuments target directory
        -- Portable primitive codecs may already be in memory from another
        -- unit. Count the actual nominal documents, independently of that.
        documents "independent" second `shouldMatchList` documents "independent" first
        length (documents "changed" second) `shouldBe` length (documents "changed" first) + changed
        run "Int32" `shouldSatisfy` good
        cachedHelperDocuments target directory >>= (`shouldMatchList` second)
        removePathForcibly root
  describe "public declaration chunks" $ do
    forM_ ([(target,kind) | target <- ["java","kotlin","scala","go","haskell","fsharp"], kind <- ["data","codec"]] ++
      [(target,"data") | target <- ["python","javascript","typescript","rust"]]) $ \(target,kind) ->
      it ("reuses independent public " ++ target ++ " " ++ kind ++ " documents") $ do
        root <- (</> ("lawspec-public-" ++ target ++ "-" ++ kind ++ "-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let input fieldType = encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("public.lawspec" :: String), "content" .= unlines
                 ["unit incremental.publicChunks." ++ kind ++ "Chunks", "type Changed is a record { value :: " ++ fieldType ++ " } end type",
                  "type Independent is a record { label :: Text } end type", "nativeSelected :: Independent -> Bool", "end unit"]]]])
            run = decode . dispatch . input
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "Integer" `shouldSatisfy` good
        [versioned] <- listDirectory root
        let directory = root </> versioned </> ("public-" ++ (if target `elem` ["javascript","typescript"] then "web" else target) ++ "-" ++ kind)
            documents name = filter (isInfixOf name)
        first <- cachedPublicDocuments target kind directory
        documents "independent" first `shouldSatisfy` (not . null)
        run "Int32" `shouldSatisfy` good
        second <- cachedPublicDocuments target kind directory
        documents "independent" second `shouldMatchList` documents "independent" first
        length (documents "changed" second) `shouldBe` length (documents "changed" first) + 1
        cold <- evaluate (decode (withoutMemoization dispatch (input "Int32")) :: Maybe Value)
        run "Int32" `shouldBe` cold
        removePathForcibly root
  describe "public F# codec namespaces" $ do
    it "reserves user type names before allocating recursive codec pattern aliases" $ do
      root <- (</> "lawspec-fsharp-codec-namespace-test") <$> getTemporaryDirectory
      removePathForcibly root
      let input extra = encode (object
            ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
             "method" .= ("planGeneration" :: String), "target" .= ("fsharp" :: String), "cacheDirectory" .= root,
             "sources" .= [object ["path" .= ("aliases.lawspec" :: String), "content" .= unlines
               ["unit incremental.codecNamespace", "type Choice (a :: Type) is one of NoChoice | Selected of type a end type",
                "nativeSelected :: Choice Integer -> Bool",extra,"end unit"]]]])
          good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
          good _ = False
          run = decode . dispatch . input
          added = "type CodecPatternChoice is a record { marker :: Unit } end type"
      run "" `shouldSatisfy` good
      run added `shouldSatisfy` good
      cold <- evaluate (decode (withoutMemoization dispatch (input added)) :: Maybe Value)
      run added `shouldBe` cold
      [versioned] <- listDirectory root
      documents <- cachedPublicDocuments "fsharp" "codec" (root </> versioned </> "public-fsharp-codec")
      length (filter (isInfixOf "compiledname(\"choice\")") documents) `shouldBe` 2
      removePathForcibly root
  describe "unit emission dependencies" $ do
    forM_ ["python","javascript","typescript","java","kotlin","scala","go","haskell"] $ \target ->
      it ("reuses independent " ++ target ++ " unit products after a type or unused body changes") $ do
        root <- (</> ("lawspec-outer-" ++ target ++ "-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let run fieldType increment = decode (dispatch (encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "sources" .= [object ["path" .= ("first.lawspec" :: String), "content" .= unlines
                 ["unit outer.first", "type Stable is a record { number :: Integer } end type",
                  "function stable (value :: Stable) -> Stable is value end function",
                  "function unused (value :: Integer) -> Integer is value + " ++ increment ++ " end function",
                  "law selected is definition: for all (value :: Stable) => stable value = value end for all end definition end law", "end unit"]],
                 object ["path" .= ("second.lawspec" :: String), "content" .= unlines
                 ["unit outer.second", "type Other is a record { marker :: " ++ fieldType ++ " } end type", "nativeOther :: Other -> Bool",
                  "law selected is definition: for all (value :: Other) => nativeOther value = true end for all end definition end law", "end unit"]]]]))) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "Unit" "1" `shouldSatisfy` good
        [versioned] <- listDirectory root
        let directory = root </> versioned </> "emit-product"
        before <- listDirectory directory
        length before `shouldBe` 2
        run "Maybe Unit" "1" `shouldSatisfy` good
        changedType <- listDirectory directory
        length changedType `shouldBe` 3
        run "Maybe Unit" "2" `shouldSatisfy` good
        listDirectory directory >>= (`shouldMatchList` changedType)
        removePathForcibly root
    forM_ ["python","javascript","typescript","java","kotlin","scala","go","haskell","swift","erlang","elixir","gleam"] $ \target ->
      it ("matches cold " ++ target ++ " output after name, type and contract changes") $ do
        let source fieldType increment name predicate =
              [("first.lawspec",unlines ["unit cold.first", "type Stable is a record { number :: Integer } end type",
                "function stable (value :: Stable) -> Stable is value end function",
                "function unused (value :: Integer) -> Integer is value + " ++ increment ++ " end function",
                "nativeBool :: Integer -> Bool",
                "law selected is definition: for all (value :: Stable) => stable value = value end for all end definition end law", "end unit"]),
               ("second.lawspec",unlines ["unit cold.second",
                 maybe ("type " ++ name ++ " is a record { marker :: " ++ fieldType ++ " } end type")
                   (\n -> "wrapper " ++ name ++ " is Int8 where value >= " ++ n ++ " end wrapper") predicate,
                 "nativeOther :: " ++ name ++ " -> Bool",
                 "law selected is definition: for all (value :: " ++ name ++ ") => nativeOther value = true end for all end definition end law", "end unit"])]
            variants = [source "Unit" "1" "Other" Nothing,source "Maybe Unit" "1" "Other" Nothing,
              source "Maybe Unit" "2" "Other" Nothing,source "Unit" "2" "Stable" Nothing,
              source "Unit" "2" "Other" (Just "0"),source "Unit" "2" "Other" (Just "1"),
              [(path,if path == "first.lawspec" then "\n" ++ body else body) |
                (path,body) <- source "Unit" "2" "Other" (Just "1")]] ++
              [source "Unit" "2" "NativeBool" Nothing | target == "go"]
        forM_ variants $ \sources -> do
          let input = request "planGeneration" target sources
          dispatch input `shouldBe` withoutMemoization dispatch input
    it "validates changed unused definitions before reusing a unit with law proof disabled" $ do
      let run body = response (encode (object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.2"::String),
            "method" .= ("planGeneration"::String),"target" .= ("python"::String),
            "verification" .= object ["layers" .= (["examples"]::[String])],
            "sources" .= [object ["path" .= ("admission.lawspec"::String),"content" .= unlines
              ["unit cold.admission", "function ordinary (value :: Integer) -> Integer is value + value end function",
               "function unused (value :: Integer) -> (result :: Integer where result > 0) is " ++ body ++ " end function",
               "law selected is definition: for all (value :: Integer) => ordinary value = value * 2 end for all end definition end law", "end unit"]]]]))
      case run "1" of
        Just (Object result) -> KeyMap.lookup "diagnostics" result `shouldBe` Just (Array mempty)
        result -> expectationFailure (show result)
      case run "0" of
        Just (Object result) -> KeyMap.lookup "diagnostics" result `shouldSatisfy` maybe False (\case Array diagnostics -> not (null diagnostics); _ -> False)
        result -> expectationFailure (show result)
  describe "model unit emission dependencies" $ do
    forM_ ["java","kotlin","scala","go","haskell"] $ \target ->
      it ("reuses " ++ target ++ " model products after unrelated type/body edits") $ do
        root <- (</> ("lawspec-model-outer-" ++ target ++ "-memo-test")) <$> getTemporaryDirectory
        removePathForcibly root
        let input fieldType increment = encode (object
              ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
               "method" .= ("planGeneration" :: String), "target" .= target, "cacheDirectory" .= root,
               "verification" .= object ["layers" .= (["examples","model"] :: [String])],
               "sources" .= [object ["path" .= ("models.lawspec" :: String), "content" .= unlines
                 ["unit modelChunks.counter", "type Counter is a record { id :: Int32 } end type",
                  "newCounter :: Unit -> Counter", "read :: Counter -> Int64",
                  "function modelRead (value :: Int64) -> Pair Int64 Int64 is Pair value value end function",
                  "function unused (value :: Integer) -> Integer is value + " ++ increment ++ " end function",
                  "model counter :: shared Counter by Int64 is start newCounter ~ 0 read ~ modelRead end model", "end unit"]],
                 object ["path" .= ("other.lawspec" :: String), "content" .= unlines
                  ["unit modelChunks.other", "type Other is a record { marker :: " ++ fieldType ++ " } end type",
                   "nativeOther :: Other -> Bool", "end unit"]]]])
            run ty value = decode (dispatch (input ty value)) :: Maybe Value
            good (Just (Object result)) = KeyMap.lookup "diagnostics" result == Just (Array mempty)
            good _ = False
        run "Unit" "1" `shouldSatisfy` good
        [versioned] <- listDirectory root
        let directory = root </> versioned </> "emit-product"
        first <- listDirectory directory
        length first `shouldBe` 2
        run "Text" "1" `shouldSatisfy` good
        second <- listDirectory directory
        length second `shouldBe` 3
        run "Text" "2" `shouldSatisfy` good
        listDirectory directory >>= (`shouldMatchList` second)
        cold <- evaluate (decode (withoutMemoization dispatch (input "Text" "2")) :: Maybe Value)
        run "Text" "2" `shouldBe` cold
        removePathForcibly root
  describe "native execution context" $ do
    it "keys the actual shared node budget without imposing it on Python or Web" $ do
      let sources count =
            [("budget-first.lawspec",unlines ["unit budget.first", "type Box is a record { values :: List Unit } end type",
              "law selected is definition: for all (value :: Box) => value = value end for all end definition end law", "end unit"]),
             ("budget-second.lawspec",unlines (["unit budget.second", "type Oversized is a record", "{"] ++
               ["  field" ++ show index ++ " :: Unit" | index <- [1..count :: Int]] ++ ["}", "end type",
                "law unrelated is definition: for all (value :: Oversized) => value = value end for all end definition end law", "end unit"]))]
          selected target count = case response (request "planGeneration" target (sources count)) of
            Just (Object result) | KeyMap.lookup "diagnostics" result == Just (Array mempty),
              Just (Array entries) <- KeyMap.lookup "tests" result ->
                [KeyMap.lookup "key" entry | Object entry <- toList entries,
                  KeyMap.lookup "law" entry == Just (String "budget.first::law::selected")]
            result -> error (show result)
      forM_ ["java","kotlin","scala","groovy","clojure","go","haskell"] $ \target -> do
        selected target 4 `shouldSatisfy` (not . null)
        selected target 80 `shouldNotBe` selected target 4
      forM_ ["python","javascript","typescript"] $ \target ->
        selected target 80 `shouldBe` selected target 4
  describe "the on-disk cache" $ do
    it "uses a cold baseline without reading or changing entries and restores lookup after failure" $ do
      table <- newPersistentTable "cold-baseline-probe" 256 length
      memoized table "same" "stored" `shouldBe` "stored"
      let cold value = BC.unpack (withoutMemoization (\input -> BC.pack (memoized table "same" input)) value)
      cold "recomputed" `shouldBe` "recomputed"
      memoized table "same" (error "overwrote the warm baseline") `shouldBe` "stored"
      evaluate (B.length (withoutMemoization (\() -> error "cold baseline failure") ())) `shouldThrow` anyErrorCall
      memoized table "same" (error "did not restore memo lookup") `shouldBe` "stored"
    it "reads an entry another process stored, and recomputes one it cannot read" $ do
      root <- (</> "lawspec-memo-test") <$> getTemporaryDirectory
      removePathForcibly root
      first <- newPersistentTable "probe" 16 (const 1)
      let run table value = BC.unpack (withCacheDirectory (Just root) (BC.pack (memoized table "key" value)))
      run first "stored" `shouldBe` "stored"
      -- A new table has an empty memory, as a new process would.
      second <- newPersistentTable "probe" 16 (const 1)
      run second (error "recomputed") `shouldBe` "stored"
      [versioned] <- listDirectory root
      [entry] <- listDirectory (root </> versioned </> "probe")
      writeFile (root </> versioned </> "probe" </> entry) "not a cache entry"
      third <- newPersistentTable "probe" 16 (const 1)
      run third "recomputed" `shouldBe` "recomputed"
      fourth <- newPersistentTable "probe" 16 (const 1)
      run fourth (error "recomputed again") `shouldBe` "recomputed"
      removePathForcibly root
    it "keeps each compiler build's entries apart, so a rebuilt compiler never reads another's" $ do
      root <- (</> "lawspec-memo-build-test") <$> getTemporaryDirectory
      removePathForcibly root
      first <- newPersistentTable "probe" 16 (const 1)
      let run table value = BC.unpack (withCacheDirectory (Just root) (BC.pack (memoized table "key" value)))
      run first "stored" `shouldBe` "stored"
      [build] <- listDirectory root
      -- The folder names the version and, for a native compiler, the build.
      build `shouldSatisfy` (("lawspec-" ++ showVersion version ++ "-") `isPrefixOf`)
      -- An entry another build stored, under the folder of the version alone,
      -- as compilers before this one kept them, is not read.
      createDirectoryIfMissing True (root </> ("lawspec-" ++ showVersion version) </> "probe")
      [entry] <- listDirectory (root </> build </> "probe")
      copyFile (root </> build </> "probe" </> entry) (root </> ("lawspec-" ++ showVersion version) </> "probe" </> entry)
      removePathForcibly (root </> build)
      second <- newPersistentTable "probe" 16 (const 1)
      run second "recomputed" `shouldBe` "recomputed"
      removePathForcibly root
    it "stays out of the way without a cache directory" $ do
      table <- newPersistentTable "unused" 16 (const 1)
      memoized table "key" (42 :: Int) `shouldBe` 42
  where
    compiled text = either (error . show) id (compileCore 64 defaultGeneration [Source "keys.lawspec" text])
    keys body =
      let program = compiled $ unlines
            [ "unit incremental.keys\n"
            , "function double (x :: Integer) -> Integer is x + x end function\n"
            , "function triple (x :: Integer) -> Integer is " ++ body ++ " end function"
            , "law \"|doubles| is definition : for all (x :: Integer) => double x = x * 2 end for all end definition end law\n"
            , "law \"|triples| is definition : for all (x :: Integer) => triple x = x * 3 end for all end definition end law\n" , "end unit"]
          graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
      in [ (C.propertyName p, fullKey graph "" p)
         | u <- C.programUnits program, p <- C.unitProperties u ]
    wrapper name bound = "wrapper " ++ name ++ " is Int32 where value > " ++ bound ++ " end wrapper"
    planOf law declarations = do
      let program = compiled $ unlines ([ "unit incremental.locality\n"
                                        , ""
                                        ] ++ declarations ++
            ["law \"" ++ law ++ " is definition: for all (s :: Score) => s = s end for all end definition end law", "end unit"])
      plan <- either (const Nothing) Just (planTesting program)
      fmap boundaryCases (find ((== law) . C.propertyName . plannedProperty) (concatMap plannedProperties (plannedUnits plan)))

