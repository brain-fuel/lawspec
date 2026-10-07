-- | Harness units: strategies, adequacy, run metadata, sharing and scheduling.
module HarnessSpec (test_harnessesChangeHowLawsRunNeverWhatTheyMean) where

import Data.Either (isRight)
import Data.List (isInfixOf, nub)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.TestManifest (TestEntry(..), testManifest, BenchmarkEntry(..), benchmarkManifest)
import LawSpec.Search (lawDescriptors)
import LawSpec.TestNames (unitTestNames)
import LawSpec.Bounds (inputRange)

-- A unit, and a harness in a file of its own.
compiled :: String -> Either [Diagnostic] C.Program
compiled harness = compileCore 64 defaultGeneration
  [Source "shop.lawspec" shop, Source "shop_testing.lawspec" harness]

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

shop :: String
shop = unlines
  [ "unit example.shop"
  , "type Order is Order items :: Int32 total :: Int32 end"
  , "definition itemsOf (order :: Order) :: Int32 is match order with | Order items total -> items end end"
  , "definition isEmpty (order :: Order) :: Bool is itemsOf order == 0 end"
  , "discount :: Order -> Int32"
  , "ability Ledger is"
  , "  accept :: Int32 -> Bool"
  , "end"
  , "handler fakeLedger for Ledger is accept cents is cents > 0 end end"
  , "book :: Int32 -> Bool uses Ledger"
  , "law `discount is small` is"
  , "  definition is `for all` (order :: Order where itemsOf order >= 0) . (discount order <= 100) = true end"
  , "end"
  , "law `booking succeeds` is"
  , "  definition is `for all` (cents :: Int32 where cents > 0) . book cents = true end"
  , "end"
  , "law `reflexive` is"
  , "  definition is `for all` (x :: Int32) . x = x end"
  , "end"
  , "handle Scratch"
  , "openScratch :: Unit -> Scratch"
  , "closeScratch :: Scratch -> Unit"
  , "handle Socket"
  , "openSocket :: Unit -> Socket"
  , "closeSocket :: Socket -> Unit"
  , "resource Scratch is"
  , "  acquire is openScratch unitValue end"
  , "  release s is closeScratch s end"
  , "  reset s is closeScratch s end"
  , "end"
  , "resource Socket is"
  , "  acquire is openSocket unitValue end"
  , "  release s is closeSocket s end"
  , "end"
  , "scratchOpen :: Scratch -> Bool"
  , "law `scratch is open` for s :: Scratch is"
  , "  definition is scratchOpen s = true end"
  , "end" ]

harness :: [String] -> String
harness items = unlines (["harness example.shop.testing for example.shop is"] ++ items ++ ["end"])

lawHarness :: String -> C.Program -> Maybe C.LawHarness
lawHarness name program = lookup name [(C.propertyName p, C.propertyHarness p) | u <- C.programUnits program, p <- C.unitProperties u]

statusOf :: String -> [Obligation] -> [Status]
statusOf name evidence = [obligationStatus o | o <- evidence, obligationStage o == "law", name `isInfixOf` C.idText (obligationDeclaration o)]

-- | The harness says how laws are tested and never what they mean, so a law's
-- obligation is the same whatever its harness. ref:REQ-harness-units
test_harnessesChangeHowLawsRunNeverWhatTheyMean :: Spec
test_harnessesChangeHowLawsRunNeverWhatTheyMean = describe "harness units" $ do
  it "attaches each law's harness: strategies, adequacy and run metadata" $ do
    let source = harness
          [ "  strategy small :: Order is bind n :: Int32 from (one of 0, 1, 2) in one of Order n (n * 100) end"
          , "  tags pricing"
          , "  for law `discount is small`"
          , "    use small for order"
          , "    cover 10% \"empty\" when isEmpty order"
          , "    classify itemsOf order > 1 as \"several\""
          , "    timeout 2 s"
          , "    repeat 3"
          , "    retry flaky 2" ]
    case compiled source of
      Left ds -> expectationFailure (show ds)
      Right program -> case lawHarness "discount is small" program of
        Nothing -> expectationFailure "no law"
        Just h -> do
          C.harnessTags h `shouldBe` ["pricing"]
          map C.coverLabel (C.harnessCover h) `shouldBe` ["empty"]
          map snd (C.harnessClassify h) `shouldBe` ["several"]
          C.harnessTimeout h `shouldBe` Just 2000
          (C.harnessRepeat h, C.harnessRetries h) `shouldBe` (3, 2)
          [n | (_, n, _) <- C.harnessDraws h] `shouldBe` ["small"]
  it "rejects a harness that declares a law, a definition or a handler" $ do
    compiled (harness ["  law `smuggled` is definition is 1 = 1 end end"]) `shouldSatisfy` failsWith "a harness cannot declare a law"
    compiled (harness ["  definition sneaky (x :: Int32) :: Int32 is x end"]) `shouldSatisfy` failsWith "a harness cannot declare a definition"
    compiled (harness ["  handler other for Ledger is accept cents is true end end"]) `shouldSatisfy` failsWith "a harness cannot declare a handler"
  it "refers only to the laws and handlers of the unit it serves" $ do
    compiled (harness ["  for law `no such law`", "    tags x"]) `shouldSatisfy` failsWith "has no law of that name"
    compiled (harness ["  test with stripe"]) `shouldSatisfy` failsWith "has no handler called stripe"
    compileCore 64 defaultGeneration [Source "shop.lawspec" shop,
      Source "t.lawspec" "harness elsewhere.testing for elsewhere is end"] `shouldSatisfy` failsWith "there is no unit called elsewhere"
  it "type-checks strategies against the inputs they draw" $ do
    compiled (harness ["  strategy numbers :: Int32 is one of 1, 2 end", "  for law `discount is small`", "    use numbers for order"])
      `shouldSatisfy` failsWith "a strategy may only produce values of its type"
    compiled (harness ["  strategy orders :: Order is one of 1 end", "  for law `discount is small`", "    use orders for order"])
      `shouldSatisfy` (not . isRight)
    compiled (harness ["  strategy loop :: Order is loop end"]) `shouldSatisfy` failsWith "may not be recursive"
  it "lets harness expressions call checked definitions only" $ do
    compiled (harness ["  for law `discount is small`", "    cover 10% \"cheap\" when discount order < 10"])
      `shouldSatisfy` failsWith "may call only checked definitions"
    compiled (harness ["  for law `discount is small`", "    label itemsOf order"]) `shouldSatisfy` (not . isRight)
  it "shares only resources that declare reset" $ do
    compiled (harness ["  share Scratch per unit"]) `shouldSatisfy` isRight
    compiled (harness ["  share Socket per unit"]) `shouldSatisfy` failsWith "does not declare reset"
    compiled (harness ["  parallel", "  share Scratch per unit"]) `shouldSatisfy` failsWith "share Scratch with parallel"
    let concurrentShop = compileCore 64 defaultGeneration
          [Source "shop.lawspec" (replaceOnce "resource Scratch is\n" "resource Scratch is concurrent\n" shop),
           Source "shop_testing.lawspec" (harness ["  parallel", "  share Scratch per unit"])]
    concurrentShop `shouldSatisfy` isRight
  it "shares a resource at run time: each law that takes it gets its scope's key, and its reset" $ do
    let resourcesOf program = [C.propertyResources p | u <- C.programUnits program, p <- C.unitProperties u, C.propertyName p == "scratch is open"]
    case compiled (harness ["  share Scratch per unit"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        map (map C.resourceShared) (resourcesOf program) `shouldBe` [[Just "example.shop/Scratch"]]
        map (map ((/= Nothing) . C.resourceReset)) (resourcesOf program) `shouldBe` [[True]]
    case compiled (harness ["  share Scratch per run"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> map (map C.resourceShared) (resourcesOf program) `shouldBe` [[Just "run/Scratch"]]
    case compiled (harness []) of
      Left ds -> expectationFailure (show ds)
      Right program -> map (map C.resourceShared) (resourcesOf program) `shouldBe` [[Nothing]]
  it "lets a strategy's type be an inline refinement, kept like such that" $
    case compiled (harness ["  strategy small :: (o :: Order where itemsOf o <= 3) is any end", "  for law `discount is small`", "    use small for order"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> case lawHarness "discount is small" program of
        Just h | [(_, "small", C.DrawSuchThat _ _ _ 100)] <- C.harnessDraws h -> pure ()
        other -> expectationFailure (show other)
  it "aims a refined strategy's any at its refinement, as a law input's generator aims" $
    case compiled (harness ["  strategy digits :: (n :: Int32 where n >= 1 && n <= 9) is any end", "  for law `reflexive`", "    use digits for x"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> case lawHarness "reflexive" program of
        Just h | [(_, "digits", C.DrawSuchThat (C.DrawAny _ (Just aim)) _ _ 100)] <- C.harnessDraws h ->
          inputRange 64 aim `shouldBe` Just (1, 9)
        other -> expectationFailure (show other)
  it "runs a benchmark that uses abilities under their production handlers" $
    case compiled (harness ["  benchmark `booking` is book 100 end"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> case [b | u <- C.programUnits program, Just h <- [C.unitHarnessSettings u], (_, b) <- C.harnessBenchmarks h] of
        [b] | C.Handle (C.WithHandler _ C.ProductionHandler) _ <- C.expressionNode b -> pure ()
        other -> expectationFailure (show other)
  it "describes a law's inputs for the failure database and targeted search" $
    case compiled (harness []) of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let descriptorsOf name = [lawDescriptors 64 (C.programDataDeclarations program) p | u <- C.programUnits program, p <- C.unitProperties u, C.propertyName p == name]
        -- An integer narrowed to its refinement's bounds; a data type with its table.
        descriptorsOf "booking succeeds [fakeLedger]" `shouldBe` [Just ["(int Int32 1 2147483647)"]]
        case descriptorsOf "discount is small" of
          [Just [d]] -> d `shouldSatisfy` ("(data example.shop::type::Order" `isInfixOf`)
          other -> expectationFailure (show other)
  it "resolves a unit's import aliases in harness expressions" $ do
    let money = "unit shop.money\ndefinition isBig (cents :: Int32) :: Bool is cents > 1000 end\n"
        orders = unlines
          [ "unit shop.orders", "import shop.money as money", "double :: Int32 -> Int32"
          , "law `doubling is monotone` is"
          , "  definition is `for all` (x :: Int32 where x >= 0 && x <= 100000) . (double x >= x) = true end"
          , "end"
          , "harness shop.orders.testing for shop.orders is"
          , "  for law `doubling is monotone`"
          , "    classify money.isBig x as \"big\""
          , "end" ]
    case compileCore 64 defaultGeneration [Source "money.lawspec" money, Source "orders.lawspec" orders] of
      Left ds -> expectationFailure (show ds)
      Right program -> fmap (map snd . C.harnessClassify) (lawHarness "doubling is monotone" program) `shouldBe` Just ["big"]
  it "lists benchmarks and parallel units in the manifest" $
    case compiled (harness ["  parallel", "  benchmark `a booking` is book 1 end"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        nub (map entryParallel (testManifest "python" Nothing program)) `shouldBe` [True]
        [(benchmarkName b, benchmarkTest b) | b <- benchmarkManifest "go" Nothing program] `shouldBe` [("a booking", "TestBenchmarkABooking")]
        map benchmarkTest (benchmarkManifest "python" Nothing program) `shouldBe` ["test_benchmark__a_booking"]
  it "keeps the variants test with leaves out as skipped obligations" $
    case compiled (harness ["  test with fakeLedger"]) >>= dischargeEvidence of
      Left ds -> expectationFailure (show ds)
      Right evidence -> do
        statusOf "booking succeeds [native]" evidence `shouldBe` [Skipped]
        statusOf "booking succeeds [fakeLedger]" evidence `shouldSatisfy` all (/= Skipped)
  it "reports skipped and known-failing laws in evidence" $
    case compiled (harness ["  for law `discount is small`", "    known failing \"rounding\"", "  for law `booking succeeds`", "    skip \"offline\""]) >>= dischargeEvidence of
      Left ds -> expectationFailure (show ds)
      Right evidence -> do
        statusOf "discount is small" evidence `shouldBe` [KnownFailing]
        nub (statusOf "booking succeeds" evidence) `shouldBe` [Skipped]
  it "rejects known failing on a law the compiler proves" $
    (compiled (harness ["  for law `reflexive`", "    known failing \"never\""]) >>= dischargeEvidence)
      `shouldSatisfy` failsWith "cannot mark it known failing"
  it "names tests after law labels, uniquely, and carries tags in the manifest" $ do
    unitTestNames "python" ["a law", "a law", "1 more"] `shouldBe` ["test_a_law", "test_a_law_2", "test_law_1_more"]
    unitTestNames "go" ["a law"] `shouldBe` ["TestALaw"]
    unitTestNames "java" ["a law"] `shouldBe` ["lawALaw"]
    unitTestNames "rust" ["a law"] `shouldBe` ["law_a_law"]
    case compiled (harness ["  for law `reflexive`", "    tags fast, unit"]) of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let entries = testManifest "python" Nothing program
        [entryTags e | e <- entries, entryLabel e == "example.shop::reflexive"] `shouldBe` [["fast", "unit"]]
        [entryName e | e <- entries, entryLabel e == "example.shop::reflexive"] `shouldBe` ["test_reflexive"]

replaceOnce :: String -> String -> String -> String
replaceOnce needle replacement haystack = case haystack of
  [] -> []
  _ | take (length needle) haystack == needle -> replacement ++ drop (length needle) haystack
  c : rest -> c : replaceOnce needle replacement rest
