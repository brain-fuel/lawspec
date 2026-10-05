module ImportSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Key, Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Either (isRight)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Vector as V
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Api (dispatch)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)
import LawSpec.Packages (parseVersion, satisfies, parseRange)
import LawSpec.Testing (planTesting)

money :: String
money = unlines
  [ "unit shop.money"
  , "type Currency is | Usd | Eur end"
  , "type Money is Money currency :: Currency cents :: Cents end"
  , "refinement Cents is (c :: Int64 where c >= 0 && c <= 1000000) end"
  , "wrapper Quantity is Int32 where value >= 1 && value <= 1000 end"
  , "definition centsOf (m :: Money) :: Int64 is match m with | Money c n -> n end end"
  , "definition doubled (m :: Money) :: BigInt is centsOf m * 2 end"
  , "law `commutative` (f :: a -> a -> a) requires Eq a is"
  , "  definition is `for all` (x :: a) (y :: a) . f x y = f y x end"
  , "end"
  , "convert :: Currency -> Money -> Money"
  , "law `convert keeps cents` is"
  , "  definition is `for all` (c :: Currency) (m :: Money) . centsOf (convert c m) = centsOf m end"
  , "end" ]

orders :: String -> String
orders body = unlines ["unit shop.orders", "import shop.money as money (Money, Cents, `commutative`)"] ++ body

compileUnits :: [String] -> Either [Diagnostic] C.Program
compileUnits texts = compileCore 64 defaultGeneration [Source ("u" ++ show i ++ ".lawspec") t | (i, t) <- zip [0 :: Int ..] texts]

rejects :: String -> [String] -> Expectation
rejects fragment texts = case compileUnits texts of
  Left diagnostics -> concatMap message diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

accepts :: [String] -> Expectation
accepts texts = case compileUnits texts of
  Left diagnostics -> expectationFailure (show diagnostics)
  Right _ -> pure ()

-- A generation request through the API, with packages.
request :: [(Key, Value)] -> [(String, String)] -> Value
request extra sources = maybe Null id $ decode $ dispatch $ encode $ object $
  [ "method" .= ("check" :: String)
  , "sources" .= [object ["path" .= p, "content" .= c] | (p, c) <- sources] ] ++ extra

diagnosticText :: Value -> String
diagnosticText (Object o) = maybe "" show (KM.lookup "diagnostics" o)
diagnosticText _ = ""

packaged :: String -> String -> [(String, String)] -> Value
packaged name version dependencies = object
  [ "name" .= name, "version" .= version, "dependencies" .= M.fromList dependencies
  , "sources" .= [object ["path" .= ("money.lawspec" :: String), "content" .= money] | name == "shop.money"] ]

spec :: Spec
spec = describe "cross-unit imports" $ do
  it "resolves qualified and listed names across units, with unit-scoped constructors" $ do
    let program = compileUnits [money, orders $ unlines
          [ "type Currency is | Usd | Gbp end"
          , "settle :: Currency -> money.Currency"
          , "total :: Money -> Money -> Money"
          , "limit :: Cents -> Cents"
          , "law `dollars settle in dollars` is definition is settle Usd = money.Usd end end"
          , "law `total commutes` is definition is `commutative` total end end"
          , "law `doubled` is"
          , "  definition is `for all` (m :: Money) . money.doubled m = money.centsOf m * 2 end"
          , "  example `two` is m = Money money.Usd 5 expect money.doubled m = 10 end"
          , "end"
          , "law `limit` is definition is `for all` (c :: Cents) . limit c <= c end end" ]]
    program `shouldSatisfy` isRight
    case program of
      Right core -> do
        let constructors = [C.idText (C.constructorId c) | d <- C.programDataDeclarations core, c <- C.dataConstructors d]
        forM_ ["shop.money::type::Currency::Usd", "shop.orders::type::Currency::Usd"] $ \c ->
          constructors `shouldContain` [c]
        -- The imported definition and everything it calls are copied.
        let definitions = [C.idText (C.declarationId (C.definitionDeclaration d)) | u <- C.programUnits core, d <- C.unitDefinitions u]
        forM_ ["shop.orders::shopMoneyDoubled", "shop.orders::shopMoneyCentsOf"] $ \d ->
          definitions `shouldContain` [d]
        forM_ targets $ \target -> (planTesting core >>= emitPlan target) `shouldSatisfy` isRight
      Left _ -> pure ()

  it "imports transitively without re-exporting" $ do
    let base = "unit a\ndefinition one (x :: Int32) :: Int32 is 1 end\n"
        middle = "unit b\nimport a\ndefinition two (x :: Int32) :: BigInt is a.one x + a.one x end\n"
        top body = "unit c\nimport b\nf :: Int32 -> Int32\n" ++ body
    accepts [base, middle, top "law `two` is definition is `for all` (x :: Int32) . b.two x = 2 end end\n"]
    -- Without its own import of a, a.one is not a qualified name in c.
    rejects "unknown" [base, middle, top "law `one` is definition is `for all` (x :: Int32) . a.one x = 1 end end\n"]
    rejects "b does not export one" [base, middle, "unit c\nimport b (one)\n"]

  it "re-exports imported names from a facade, keeping the original identity" $ do
    let facade = unlines
          [ "unit shop.facade", "import shop.money as money (Money, Cents, `commutative`)"
          , "export Money, Cents, money.centsOf, money.Currency, `commutative`" ]
        client body = unlines ["unit app", "import shop.facade (Money, Cents, centsOf, Currency, `commutative`)"] ++ body
        program = compileUnits [money, facade, client $ unlines
          [ "total :: Money -> Money -> Money"
          , "law `total commutes` is definition is `for all` (a :: Money) (b :: Money) . total a b = total b a end end"
          , "law `cents` is definition is `for all` (m :: Money) . centsOf m >= 0 end"
          , "  example `usd` is m = Money Usd 5 expect centsOf m = 5 end end" ]]
    program `shouldSatisfy` isRight
    case program of
      Right core -> do
        -- One Money: the facade's Money is shop.money's, not a copy.
        let types = [C.idText (C.dataId d) | d <- C.programDataDeclarations core]
        types `shouldContain` ["shop.money::type::Money"]
        filter ("Money" `isInfixOf`) types `shouldBe` ["shop.money::type::Money"]
        forM_ targets $ \target -> (planTesting core >>= emitPlan target) `shouldSatisfy` isRight
      Left _ -> pure ()
    -- Qualified through the facade's alias works too.
    accepts [money, facade, "unit app\nimport shop.facade as s\nf :: s.Money -> s.Cents\n"]
    -- A facade of a facade still reaches the one declaration.
    accepts [money, facade, "unit shop.outer\nimport shop.facade as f\nexport f.Money, f.centsOf\n",
      "unit app\nimport shop.outer (Money, centsOf)\nf :: Money -> Money\n" ++
      "law `kept` is definition is `for all` (m :: Money) . centsOf (f m) = centsOf m end end\n"]
    rejects "import cycle" ["unit a\nimport b\nexport b.one\n", "unit b\nimport a\ndefinition one (x :: Int32) :: Int32 is 1 end\n"]
    rejects "export names Pounds, which shop.facade does not import" [money, "unit shop.facade\nimport shop.money (Money)\nexport Pounds\n"]
    rejects "export names centsOf, which shop.facade does not import" [money, "unit shop.facade\nimport shop.money (Money)\nexport centsOf\n"]
    rejects "export lists Money, which shop.facade also declares"
      [money, "unit shop.facade\nimport shop.money as m\nexport m.Money\ntype Money is | Free end\n"]
    rejects "export lists size twice"
      [ "unit p\ndefinition size (x :: Int32) :: Int32 is 1 end\n", "unit q\ndefinition size (x :: Int32) :: Int32 is 2 end\n"
      , "unit r\nimport p\nimport q\nexport p.size, q.size\n" ]

  it "keeps two units' same-named definitions apart" $
    accepts
      [ "unit p\ndefinition size (x :: Int32) :: Int32 is 1 end\n"
      , "unit q\ndefinition size (x :: Int32) :: Int32 is 2 end\n"
      , "unit r\nimport p\nimport q\nf :: Int32 -> Int32\n" ++
        "law `sizes` is definition is `for all` (x :: Int32) . p.size x + q.size x = 3 end end\n" ]

  it "imports indexed families with implicit indices, qualified or listed" $ do
    let vec = unlines
          [ "unit lib.vec"
          , "type Vec (n :: Natural) (a :: Type) is"
          , "  | VNil where n = 0"
          , "  | VCons head :: a tail :: Vec m a where n = m + 1"
          , "end" ]
    accepts [vec, "unit app\nimport lib.vec as v\nrev :: v.Vec n Int32 -> v.Vec n Int32\n" ++
      "law `twice` is definition is `for all` (x :: v.Vec 2 Int32) . rev (rev x) = x end end\n"]
    accepts [vec, "unit app\nimport lib.vec (Vec)\nrev :: Vec n Int32 -> Vec n Int32\n" ++
      "law `twice` is definition is `for all` (x :: Vec 2 Int32) . rev (rev x) = x end end\n"]

  it "imports wrappers with their constructor and unwrapping function" $
    accepts [money, unlines
      [ "unit shop.lines", "import shop.money (Quantity)"
      , "half :: Quantity -> Int32"
      , "law `half` is definition is `for all` (q :: Quantity) . half q <= valueOfQuantity q end"
      , "  example `two` is q = Quantity 2 expect half q = 1 end end" ]]

  it "rejects imports that do not resolve" $ do
    rejects "unknown unit: shop.nothing" ["unit a\nimport shop.nothing\n"]
    rejects "import cycle" ["unit a\nimport b\n", "unit b\nimport a\n"]
    rejects "import cycle" ["unit a\nimport a\n"]
    rejects "prelude is available without an import" ["unit a\nimport prelude\n"]
    rejects "duplicate import alias" [money, "unit x.money\n", "unit a\nimport shop.money\nimport x.money\n"]
    rejects "shop.money does not export Pounds" [money, "unit a\nimport shop.money (Pounds)\n"]
    rejects "Usd is a constructor; import its type" [money, "unit a\nimport shop.money (Usd)\n"]
    rejects "convert is an adapter of shop.money" [money, "unit a\nimport shop.money (convert)\n"]
    rejects "convert is an adapter of shop.money"
      [money, orders "f :: Money -> Money\nlaw `c` is definition is `for all` (m :: Money) . money.convert money.Eur m = f m end end\n"]
    rejects "has no parameters; only generic laws" [money, "unit a\nimport shop.money (`convert keeps cents`)\n"]
    rejects "is imported from shop.money and also declared in a"
      [money, "unit a\nimport shop.money (Money)\ntype Money is Money cents :: Int32 end\n"]
    rejects "is imported from more than one unit"
      [ "unit p\ndefinition size (x :: Int32) :: Int32 is 1 end\n"
      , "unit q\ndefinition size (x :: Int32) :: Int32 is 2 end\n"
      , "unit r\nimport p (size)\nimport q (size)\n" ]

  it "rejects imported laws and definitions that use their unit's adapters" $
    rejects "an imported law or definition cannot use it"
      [ "unit a\nf :: Int32 -> Int32\nlaw `uses f` (g :: Int32 -> Int32) is definition is `for all` (x :: Int32) . g x = f x end end\n"
      , "unit b\nimport a (`uses f`)\nh :: Int32 -> Int32\nlaw `h` is definition is `uses f` h end end\n" ]

  describe "packages" $ do
    let project extra = request extra [("orders.lawspec", orders "total :: Money -> Money -> Money\nlaw `t` is definition is `commutative` total end end\n")]
        withMoney version range = project
          [ ("dependencies", object ["shop.money" .= (range :: String)])
          , ("packages", toList [packaged "shop.money" version []]) ]
        toList = Array . V.fromList
    it "accepts a satisfied dependency and reports the packages" $ do
      let response = withMoney "1.4.2" "^1.2.0"
      diagnosticText response `shouldBe` "Array []"
      show response `shouldSatisfy` isInfixOf "\"units\""
    it "rejects unsatisfied, missing and unused packages" $ do
      diagnosticText (withMoney "2.0.0" "^1.2.0") `shouldSatisfy` isInfixOf "requires shop.money ^1.2.0, but version 2.0.0 is supplied"
      diagnosticText (project [("dependencies", object ["shop.money" .= ("^1.0.0" :: String)])])
        `shouldSatisfy` isInfixOf "which is not supplied"
      diagnosticText (project [("packages", toList [packaged "shop.money" "1.0.0" []])])
        `shouldSatisfy` isInfixOf "is supplied but not required"
      diagnosticText (withMoney "1.0" "^1.0.0") `shouldSatisfy` isInfixOf "invalid version"
    it "keeps units in their package namespace and imports within dependencies" $ do
      let stray = request
            [ ("dependencies", object ["shop.money" .= ("^1.0.0" :: String)])
            , ("packages", toList [object [ "name" .= ("shop.money" :: String), "version" .= ("1.0.0" :: String)
                , "sources" .= [object ["path" .= ("x.lawspec" :: String), "content" .= ("unit other.place\n" :: String)]] ]]) ]
            [("a.lawspec", "unit a\n")]
      diagnosticText stray `shouldSatisfy` isInfixOf "must be named shop.money or shop.money.<name>"
      let undeclared = request [] [("money.lawspec", money), ("orders.lawspec", orders "")]
      diagnosticText undeclared `shouldBe` "Array []"
      let outside = request [("package", object ["name" .= ("shop.orders" :: String), "version" .= ("0.1.0" :: String)])]
            [("money.lawspec", money), ("orders.lawspec", orders "")]
      diagnosticText outside `shouldSatisfy` isInfixOf "unit shop.money of package shop.orders must be named"
      let hidden = request
            [ ("dependencies", object ["shop.core" .= ("*" :: String)])
            , ("packages", toList
                [ object [ "name" .= ("shop.core" :: String), "version" .= ("1.0.0" :: String)
                  , "sources" .= [object ["path" .= ("c.lawspec" :: String), "content" .= ("unit shop.core\n" :: String)]] ]
                , packaged "shop.money" "1.0.0" [] ]) ]
            [("orders.lawspec", orders "")]
      diagnosticText hidden `shouldSatisfy` isInfixOf "is supplied but not required"
    it "builds several versions of one package side by side" $ do
      let moneyAt version = object
            [ "name" .= ("shop.money" :: String), "version" .= (version :: String)
            , "sources" .= [object ["path" .= ("money.lawspec" :: String), "content" .= money]] ]
          report = object
            [ "name" .= ("shop.report" :: String), "version" .= ("1.0.0" :: String)
            , "dependencies" .= M.fromList [("shop.money" :: String, "^2.0.0" :: String)]
            , "sources" .= [object ["path" .= ("report.lawspec" :: String), "content" .= unlines
                [ "unit shop.report", "import shop.money (Money)"
                , "definition kept (m :: Money) :: Money is m end" ]]] ]
          buildWith extra body = request
            [ ("dependencies", object ["shop.money" .= ("^1.0.0" :: String), "shop.report" .= ("^1.0.0" :: String)])
            , ("packages", toList ([moneyAt "1.4.0", moneyAt "2.1.0", report] ++ extra)) ]
            [("orders.lawspec", unlines ["unit shop.orders", "import shop.money (Money)", "import shop.report"] ++ body)]
          build = buildWith []
          fine = build "same :: Money -> Money\nlaw `same` is definition is `for all` (m :: Money) . same m = m end end\n"
      diagnosticText fine `shouldBe` "Array []"
      show fine `shouldSatisfy` isInfixOf "shop.money.v1x4x0"
      show fine `shouldSatisfy` isInfixOf "shop.money.v2x1x0"
      -- 1.2.0 is supplied, but no range selects it over 1.4.0.
      diagnosticText (buildWith [moneyAt "1.2.0"] "") `shouldSatisfy`
        isInfixOf "package shop.money 1.2.0 is supplied but not required"
      diagnosticText (buildWith [moneyAt "1.4.0"] "") `shouldSatisfy` isInfixOf "supplied more than once: shop.money 1.4.0"
      let crossed = build "same :: Money -> Money\nlaw `crossed` is definition is `for all` (m :: Money) . report.kept m = same m end end\n"
      diagnosticText crossed `shouldSatisfy` isInfixOf
        "type mismatch: shop.money::type::Money (shop.money 2.1.0) and shop.money::type::Money (shop.money 1.4.0)"

    it "keeps versions apart whose numbers would run together" $ do
      let moneyAt version = object
            [ "name" .= ("shop.money" :: String), "version" .= (version :: String)
            , "sources" .= [object ["path" .= ("money.lawspec" :: String), "content" .= money]] ]
          report = object
            [ "name" .= ("shop.report" :: String), "version" .= ("1.0.0" :: String)
            , "dependencies" .= M.fromList [("shop.money" :: String, "^11.0.0" :: String)]
            , "sources" .= [object ["path" .= ("report.lawspec" :: String), "content" .= unlines
                [ "unit shop.report", "import shop.money (Money)"
                , "definition kept (m :: Money) :: Money is m end" ]]] ]
          generate versions = request
            [ ("dependencies", object ["shop.money" .= ("^1.0.0" :: String), "shop.report" .= ("^1.0.0" :: String)])
            , ("packages", toList (map moneyAt versions ++ [report]))
            , ("method", String "planGeneration"), ("target", String "go") ]
            [("orders.lawspec", unlines ["unit shop.orders", "import shop.money (Money)", "import shop.report"
              , "same :: Money -> Money", "law `same` is definition is `for all` (m :: Money) . same m = m end end"])]
          -- 1.10.0 and 11.0.0 would both be V1100 without a separator.
          both = generate ["1.10.0", "11.0.0"]
      diagnosticText both `shouldBe` "Array []"
      forM_ ["shop.money.v1x10x0", "shop.money.v11x0x0", "ShopMoneyV1x10x0Money", "ShopMoneyV11x0x0Money"] $ \name ->
        show both `shouldSatisfy` isInfixOf name
      -- Prerelease tags are free text; versions that would still share names are refused.
      let clash = request
            [ ("dependencies", object ["shop.money" .= (">=1.0.0-a.b <2.0.0" :: String)])
            , ("packages", toList [moneyAt "1.0.0-a.b", moneyAt "1.0.0-a-b"]) ] [("a.lawspec", "unit a\n")]
      diagnosticText clash `shouldSatisfy` isInfixOf "package shop.money versions 1.0.0-a.b and 1.0.0-a-b would share generated names"

    it "orders and matches semantic versions" $ do
      let holds range version = either (const False) id (satisfies <$> parseRange range <*> parseVersion version)
      holds "^1.2.3" "1.9.0" `shouldBe` True
      holds "^1.2.3" "2.0.0" `shouldBe` False
      holds "^1.2.3" "1.2.2" `shouldBe` False
      holds "^0.2.3" "0.2.9" `shouldBe` True
      holds "^0.2.3" "0.3.0" `shouldBe` False
      holds "^0.0.3" "0.0.4" `shouldBe` False
      holds "~1.2.3" "1.2.9" `shouldBe` True
      holds "~1.2.3" "1.3.0" `shouldBe` False
      holds ">=1.0.0 <2.0.0" "1.5.0" `shouldBe` True
      holds "*" "3.1.4" `shouldBe` True
      holds "1.2.3" "1.2.3" `shouldBe` True
      holds "^1.2.3" "1.3.0-beta.1" `shouldBe` False
      holds "^1.3.0-beta.1" "1.3.0-beta.2" `shouldBe` True
      holds "^1.3.0-beta.2" "1.3.0-beta.10" `shouldBe` True
      parseVersion "01.2.3" `shouldSatisfy` either (const True) (const False)
