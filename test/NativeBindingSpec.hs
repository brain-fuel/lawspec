-- | Resolution of native type and function bindings.
module NativeBindingSpec (test_nativeBindingsResolveToOneUnambiguousIdentity) where

import Control.Monad (forM_)
import Test.Hspec
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft)
import Data.List (isInfixOf, sort)
import qualified LawSpec.HaskellData as Haskell
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Frontend (compileCore,compileCoreCanonical)
import qualified LawSpec.NativeRequest as Request
import qualified LawSpec.RustNativeBinding as Rust
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.Testing (planTesting)
import LawSpec.NativeBinding

source :: String
source = unlines
  [ "unit domain"
   ++ "\n", ""
  , "type Currency is one of USD | EUR end type\n"
  , "type Money is a record{  amount :: Decimal currency :: Currency} end type\n"
  , "type Box (a :: Type) is a record{  value :: a} end type\n"
  , "\nend unit" ]

ref :: String -> NativeRef
ref name = NativeRef ["app",name]

money :: TypeBinding
money = TypeBinding (C.Id "domain::type::Money") (ref "Price")
  [ConstructorBinding "Money" (ref "Price") RecordConstructor
    [FieldBinding "currency" "unit", FieldBinding "amount" "major"]] Nothing Nothing

resolve :: Bindings -> Either String ResolvedBindings
resolve bindings = case compileCore 64 defaultGeneration [Source "native" source] of
  Left diagnostics -> Left (show diagnostics)
  Right program -> resolveBindings (C.programDataDeclarations program) bindings

-- | A binding ties a LawSpec type to the developer's own type, so it must
-- resolve to exactly one identity; an ambiguous or unknown one would generate
-- code against the wrong type. ref:DEC-native-bindings-typed-identity
-- ref:REQ-native-binding-resolution
test_nativeBindingsResolveToOneUnambiguousIdentity :: Spec
test_nativeBindingsResolveToOneUnambiguousIdentity = describe "native binding resolution" $ do
  it "renders Haskell native codecs with named fields in both directions" $ do
    case compileCore 64 defaultGeneration [Source "native" source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let declarations = C.programDataDeclarations program
        -- Constructor IDs come from Core, never reconstructed from native names.
        let moneyDeclaration = head [d | d <- declarations, C.dataName d == "Money"]
            constructorId = C.constructorId (head (C.dataConstructors moneyDeclaration))
            mapped fields = Haskell.emitHaskellCodecsWithRepresentations
              (Doc.Pretty 100) declarations "LawSpecNativeCodecs" ["Domain"]
              [(C.dataId moneyDeclaration, "Domain.Price")]
              [(constructorId, ("Domain.Price", fields))]
        case mapped ["Domain.major", "Domain.unit"] of
          Left message -> expectationFailure message
          Right output -> do
            output `shouldSatisfy` isInfixOf "Codec.Codec Domain.Price"
            output `shouldSatisfy` isInfixOf "Domain.major = amountIn"
            output `shouldSatisfy` isInfixOf "Domain.unit = currencyOut"
            output `shouldSatisfy` isInfixOf "import qualified Domain"
        mapped ["Domain.major"] `shouldSatisfy` isLeft
  it "imports only emitted Rust converters and preserves mixed handle indices" $ do
    let input = unlines
          [ "unit handles"
          , "handle Shelf"
          , "type Count is a record { value :: Int32 } end type"
          , "end unit" ]
        shelf = TypeBinding (C.Id "handles::type::Shelf") (ref "Shelf")
          [] Nothing Nothing
        count = TypeBinding (C.Id "handles::type::Count") (ref "Count")
          [ConstructorBinding "Count" (ref "Count") RecordConstructor
            [FieldBinding "value" "value"]] Nothing Nothing
        names index = ["_lawspec_from_native_" ++ show index,
          "_lawspec_to_native_" ++ show index]
        cases = [([shelf], []), ([shelf,count], names (1 :: Int)),
          ([count,shelf], names (0 :: Int))]
    case compileCore 64 defaultGeneration [Source "handles" input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> forM_ cases $ \(bindings, expected) -> do
        let declarations = C.programDataDeclarations program
        case resolveBindings declarations (Bindings bindings []) of
          Left message -> expectationFailure message
          Right bound -> do
            Rust.conversionNames bound `shouldBe` expected
            case Rust.emitConversions declarations
              Request.emptyBindingPlan { Request.bindingRepresentations = bound } of
              Left message -> expectationFailure message
              Right output -> do
                let exports =
                      [ takeWhile (/= '(') name
                      | line <- lines (Doc.render (Doc.Pretty 100) output)
                      , "pub" : "fn" : name : _ <- [words line] ]
                sort exports `shouldBe` expected
  it "resolves codec hooks in place of constructor mappings" $ do
    let hook = CodecBinding (ref "decodePrice") (ref "encodePrice")
        binding = money {boundConstructors = [], boundCodec = Just hook}
    case resolve (Bindings [binding] []) of
      Left message -> expectationFailure message
      Right bound -> do
        map resolvedCodec (resolvedTypes bound) `shouldBe` [Just hook]
        map resolvedConstructors (resolvedTypes bound) `shouldBe` [[]]
    resolve (Bindings [money {boundCodec = Just hook}] []) `shouldSatisfy` isLeft
    resolve (Bindings [binding {boundCodec = Just (hook {codecToNative = NativeRef []})}] []) `shouldSatisfy` isLeft
  it "preserves the no-binding default" $
    resolve emptyBindings `shouldBe` Right (ResolvedBindings [] [])
  it "resolves fields in declaration order, regardless of config order" $
    case resolve (Bindings [money] []) of
      Left message -> expectationFailure message
      Right bound -> do
        let mapped = head (resolvedTypes bound)
            fields = resolvedFields (head (resolvedConstructors mapped))
        C.dataId (resolvedDeclaration mapped) `shouldBe` C.Id "domain::type::Money"
        map (C.binderName . fst) fields `shouldBe` ["amount","currency"]
        map snd fields `shouldBe` ["major","unit"]
  it "shares instantiated packing and projection trees with every emitter" $ do
    let source="unit domain\n\ntype Parcel (a :: Type) is one of Packed of type record{last :: a first :: record{count :: UInt8 flag :: Bool}} end type\nend unit\n"
        binding=TypeBinding (C.Id "domain::type::Parcel") (ref "Parcel")
          [ConstructorBinding "Packed" (ref "Packed") VariantConstructor
            [NestedFieldBinding "value" "quantity" ["first","count"] 2,
             NestedFieldBinding "value" "tail" ["last"] 0,
             NestedFieldBinding "value" "enabled" ["first","flag"] 1]] Nothing Nothing
    case compileCoreCanonical 64 defaultGeneration [Source "native" source] of
      Left diagnostics->expectationFailure (show diagnostics)
      Right program->case resolveBindings (C.programDataDeclarations program) (Bindings [binding] []) of
        Left message->expectationFailure message
        Right resolved->do
          let [mapped]=resolvedTypes resolved
              [constructor]=resolvedConstructors mapped
              Just tree=resolvedFieldLayout constructor
              leaves=concatMap (\case NativeLeaf field index->[(index,C.binderType field)];NativeRecord _ _ children->leaves children)
          nativeLayoutPaths tree `shouldBe` [[0,1],[0,0,1],[0,0,0]]
          map (C.binderName . fst) (resolvedFields constructor) `shouldBe` ["last","flag","count"]
          lookup 0 (leaves tree) `shouldBe` Just (C.TypeVariable (head (C.dataParameters (resolvedDeclaration mapped))))
          lookup 1 (leaves tree) `shouldBe` Just (C.scalarType "Bool")
          lookup 2 (leaves tree) `shouldBe` Just (C.scalarType "UInt8")
          foldNativeLayoutM (Right . pure) (\_ _ children->Right (concat children)) tree
            `shouldBe` (Right [[2,1,0]]::Either String [[Int]])
  it "resolves generic generator factories with argument arities" $
    case resolve (Bindings []
      [GeneratorBinding (C.Id "domain::type::Box") (ref "boxes") False,
       GeneratorBinding (C.Id "Either") (ref "choices") False,
       GeneratorBinding (C.Id "Decimal") (ref "amounts") False]) of
      Left message -> expectationFailure message
      Right bound -> map generatorParameterCount (resolvedGenerators bound) `shouldBe` [1,2,0]
  it "rejects unknown type identities, including ambiguous short names" $ do
    resolve (Bindings [money {boundType = C.Id "Money"}] []) `shouldSatisfy` isLeft
    resolve (Bindings [] [GeneratorBinding (C.Id "Missing") (ref "values") False]) `shouldSatisfy` isLeft
  it "retains generator scaffold requests and rejects shared scaffold identities" $ do
    let generator = GeneratorBinding (C.Id "domain::type::Box") (ref "boxes") True
    case resolve (Bindings [] [generator]) of
      Left message -> expectationFailure message
      Right bound -> do
        map resolvedGeneratorStub (resolvedGenerators bound) `shouldBe` [True]
        map generatorParameterCount (resolvedGenerators bound) `shouldBe` [1]
    resolve (Bindings [] [generator, generator {generatorType = C.Id "List", generatorStub = False}])
      `shouldSatisfy` isLeft
  it "rejects duplicate bindings and ambiguous native type identities" $ do
    resolve (Bindings [money,money] []) `shouldSatisfy` isLeft
    resolve (Bindings [money,money {boundType=C.Id "domain::type::Currency"}] []) `shouldSatisfy` isLeft
    let gen = GeneratorBinding (C.Id "Decimal") (ref "amounts") False
    resolve (Bindings [] [gen,gen]) `shouldSatisfy` isLeft
  it "requires complete constructor and field mappings" $ do
    resolve (Bindings [money {boundConstructors=[]}] []) `shouldSatisfy` isLeft
    let constructor = head (boundConstructors money)
        invalid fields = resolve (Bindings [money {boundConstructors=[constructor {boundFields=fields}]}] [])
    invalid [FieldBinding "amount" "major"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "unknown" "unit"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "currency" "major"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "amount" "unit"] `shouldSatisfy` isLeft
  it "rejects record encodings of sums and payloads on unit constructors" $ do
    let currency = TypeBinding (C.Id "domain::type::Currency") (ref "Code")
          [ConstructorBinding "USD" (ref "Dollars") RecordConstructor [],
           ConstructorBinding "EUR" (ref "Euros") UnitConstructor []] Nothing Nothing
    resolve (Bindings [currency] []) `shouldSatisfy` isLeft
    let constructor = head (boundConstructors money)
    resolve (Bindings [money {boundConstructors=[constructor {constructorStyle=UnitConstructor}]}] []) `shouldSatisfy` isLeft
  it "rejects target code fragments and empty reference parts" $
    mapM_ (\name -> resolve (Bindings [money {nativeType=NativeRef [name]}] []) `shouldSatisfy` isLeft)
      ["", "app.Price", "Price<T>", "Price; panic!()", "../Price", "_"]
  it "finds machine-sized fields through recursive declarations and type arguments" $ do
    let recursive = unlines
          [ "unit machine"
           ++ "\n", ""
          , "type Chain (a :: Type) is one of Stop | More of type record{ value :: a tail :: Maybe (Chain a)} end type\n"
          , "type Native is one of Done | Next of type record{ tail :: Maybe Native width :: UIntPtr} end type\n"
          , "\nend unit" ]
        chain ty = C.Constructor "machine::type::Chain" [C.TypeArgument (C.scalarType ty)]
    case compileCore 64 defaultGeneration [Source "machine" recursive] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let uses = usesMachineRepresentation (C.programDataDeclarations program)
        uses (chain "Int8") `shouldBe` False
        uses (chain "IntSize") `shouldBe` True
        uses (C.Constructor "machine::type::Native" []) `shouldBe` True
  -- An existing Pekko actor stands in for a LawSpec actor only when its
  -- binding covers exactly the actor's handlers, every result can be asked
  -- for, and nothing reads the actor's private state.
  -- ref:DEC-native-actor-binding
  it "resolves native actor bindings against the actor's handlers" $ do
    let actorSource abstract = unlines
          [ "unit bank"
          , "type Account is a record{ balance :: Int64 } end type"
          , "openAccount :: Unit -> Account"
          , "deposit :: Account -> UInt8 -> Pair Int64 Account"
          , "close :: Account -> Account"
          , "peek :: Account -> Int64"
          , "function modelDeposit (amount :: UInt8) (n :: Int64 where n >= 0 && n <= 1000000) -> Pair Int64 Int64 is Pair (n + amount) (n + amount) end function"
          , "function modelClose (n :: Int64) -> Int64 is 0 end function"
          , "actor account :: Account by Int64 is"
          , "  start openAccount by 0"
          , "  on deposit by modelDeposit"
          , "  on close by modelClose"
          , if abstract then "  abstract peek" else ""
          , "end actor"
          , "end unit" ]
        deposit = Request.actorHandler "deposit" (ref "Deposit") True (Just (ref "Balance")) (Just "balance")
        close = Request.actorHandler "close" (ref "Close") False Nothing Nothing
        actor handlers = Request.ActorBinding "bank::account" (Request.BehaviorFactory (NativeRef ["app","Account","create"]))
          Nothing Nothing handlers []
        resolveActors abstract actors = case compileCore 64 defaultGeneration [Source "bank" (actorSource abstract)] of
          Left diagnostics -> Left (show diagnostics)
          Right program -> Request.resolveNativeRequest program Request.emptyNativeRequest { Request.requestActors = actors }
    case resolveActors False [actor [deposit, close]] of
      Left message -> expectationFailure message
      Right plan -> case Request.bindingActors plan of
        [bound] -> do
          map Request.resolvedHandlerArguments (Request.resolvedActorHandlers bound)
            `shouldBe` [[C.scalarType "UInt8"], []]
          map Request.resolvedHandlerResult (Request.resolvedActorHandlers bound)
            `shouldBe` [Just (C.scalarType "Int64"), Nothing]
          sort (map C.idText (Request.resolvedActorAdapters bound))
            `shouldBe` ["bank::close", "bank::deposit", "bank::openAccount"]
        other -> expectationFailure (show other)
    let rejected actors expected = case resolveActors False actors of
          Left message -> message `shouldSatisfy` isInfixOf expected
          Right _ -> expectationFailure ("accepted; expected " ++ expected)
    rejected [actor [deposit]] "handler close has no message binding"
    rejected [actor [deposit, close, close {Request.boundHandlerName = "open"}]] "there is no handler open"
    rejected [actor [deposit {Request.handlerReplyTo = False}, close]] "needs a replyTo"
    rejected [actor [deposit {Request.handlerReply = Nothing}, close]] "needs the reply class"
    rejected [actor [deposit, close {Request.handlerResult = Just "value"}]] "returns no result"
    rejected [(actor [deposit, close]) {Request.boundActorName = "bank::teller"}] "unknown actor"
    rejected [actor [deposit, close], actor [deposit, close]] "duplicate native actor binding"
    case resolveActors True [actor [deposit, close]] of
      Left message -> message `shouldSatisfy` isInfixOf "unsupported: its abstract function"
      Right _ -> expectationFailure "an abstraction over a native actor's state was accepted"
  it "rejects several reply classes for one native actor handler" $ do
    let parsed reply = eitherDecode (BL.pack ("{\"actors\": [{\"actor\": \"bank::account\", \"behavior\": [\"app\", \"create\"], " ++
          "\"handlers\": [{\"handler\": \"deposit\", \"message\": [\"app\", \"Deposit\"], \"replyTo\": true, \"reply\": " ++ reply ++ "}]}]}"))
          :: Either String Request.NativeRequest
    parsed "[\"app\", \"Balance\"]" `shouldSatisfy` (not . isLeft)
    either id (const "") (parsed "[[\"app\", \"Balance\"], [\"app\", \"Rejected\"]]")
      `shouldSatisfy` isInfixOf "several replies"
  -- The pekko-samples' own messages: a chopstick that knows its hakker by
  -- address, a StatusReply, a public field and a sharded entity's id.
  -- ref:DEC-pekko-sample-suites
  it "resolves callers, sharded entities and reply fields of native actor handlers" $ do
    let source = unlines
          [ "unit bank"
          , "type Account is a record{ balance :: Int64 } end type"
          , "openAccount :: Unit -> Account"
          , "deposit :: Account -> Text -> UInt8 -> Pair Int64 Account"
          , "close :: Account -> Text -> Account"
          , "function modelDeposit (who :: Text) (amount :: UInt8) (n :: Int64 where n >= 0 && n <= 1000000) -> Pair Int64 Int64 is Pair (n + amount) (n + amount) end function"
          , "function modelClose (who :: Text) (n :: Int64) -> Int64 is 0 end function"
          , "actor account :: Account by Int64 is"
          , "  start openAccount by 0"
          , "  on deposit by modelDeposit"
          , "  on close by modelClose"
          , "end actor"
          , "end unit" ]
        deposit = (Request.actorHandler "deposit" (ref "Deposit") False (Just (ref "Balance")) Nothing)
          { Request.handlerCaller = True, Request.handlerResultField = Just "balance" }
        close = Request.actorHandler "close" (ref "Close") False Nothing Nothing
        actor handlers = Request.ActorBinding "bank::account" (Request.BehaviorFactory (NativeRef ["app","Account","create"]))
          Nothing Nothing handlers []
        resolve actors = case compileCore 64 defaultGeneration [Source "bank" source] of
          Left diagnostics -> Left (show diagnostics)
          Right program -> Request.resolveNativeRequest program Request.emptyNativeRequest { Request.requestActors = actors }
        rejected actors expected = case resolve actors of
          Left message -> message `shouldSatisfy` isInfixOf expected
          Right _ -> expectationFailure ("accepted; expected " ++ expected)
        sharded = (actor [deposit { Request.handlerCaller = False, Request.handlerReplyTo = True }, close])
          { Request.boundActorEntity = Just (ref "TypeKey") }
    either expectationFailure (const (pure ())) (() <$ resolve [actor [deposit, close]])
    either expectationFailure (const (pure ())) (() <$ resolve [sharded])
    rejected [actor [deposit { Request.handlerReplyTo = True }, close]] "has no replyTo as well"
    rejected [actor [deposit { Request.handlerResult = Just "balance" }, close]] "not both"
    rejected [sharded { Request.boundActorPersistence = Just Request.EventSourced }] "event-sourced sharded entity"
    rejected [(actor [deposit, close]) { Request.boundActorEntity = Just (ref "TypeKey") }] "a caller of a sharded entity"
    rejected [actor [deposit { Request.handlerReplyArguments = [ref "Summary"], Request.handlerReply = Nothing }, close]] "type arguments need the reply class"
    let parsed handler = eitherDecode (BL.pack ("{\"actors\": [{\"actor\": \"bank::account\", \"behavior\": [\"app\", \"create\"], " ++
          "\"handlers\": [" ++ handler ++ "]}]}")) :: Either String Request.NativeRequest
    case parsed "{\"handler\": \"deposit\", \"messageFactory\": [\"app\", \"Messages\", \"deposit\"], \"replyTo\": true, \"reply\": [\"app\", \"StatusReply\"], \"replyArguments\": [[\"app\", \"Balance\"]], \"result\": \"isSuccess\"}" of
      Right request -> map Request.boundActorHandlers (Request.requestActors request) `shouldBe`
        [[(Request.actorHandler "deposit" (NativeRef ["app","Messages","deposit"]) True (Just (ref "StatusReply")) (Just "isSuccess"))
          { Request.handlerReplyArguments = [ref "Balance"], Request.handlerMessageFactory = True }]]
      Left message -> expectationFailure message
    either id (const "") (parsed "{\"handler\": \"close\", \"message\": [\"app\", \"Close\"], \"messageFactory\": [\"app\", \"close\"]}")
      `shouldSatisfy` isInfixOf "exactly one of message, messageFactory"
  -- A hakker answers nothing: probes stand in for its chopsticks, hear what
  -- it sends and answer for them, and time passes on virtual time.
  -- ref:DEC-tell-only-actors ref:DEC-time-passes
  it "resolves probes, heard and answered messages, reply cases and time passes" $ do
    source <- readFile "acceptance/pekko-samples/fsm/hakkers.lawspec"
    sticks <- readFile "acceptance/pekko-samples/fsm/chopsticks.lawspec"
    bindings <- BL.readFile "acceptance/pekko-samples/fsm/scala/bindings.json"
    let request = either error id (eitherDecode bindings) :: Request.NativeRequest
        resolve actors = case compileCore 64 defaultGeneration [Source "hakkers.lawspec" source, Source "chopsticks.lawspec" sticks] of
          Left diagnostics -> Left (show diagnostics)
          Right program -> Request.resolveNativeRequest program request { Request.requestActors = actors }
        [chopstick, hakker] = Request.requestActors request
        rejected actors expected = case resolve actors of
          Left message -> message `shouldSatisfy` isInfixOf expected
          Right _ -> expectationFailure ("accepted; expected " ++ expected)
        handler name = head [h | h <- Request.boundActorHandlers hakker, Request.boundHandlerName h == name]
        replaced name h = hakker { Request.boundActorHandlers = [if Request.boundHandlerName x == name then h else x | x <- Request.boundActorHandlers hakker] }
    case resolve [chopstick, hakker] of
      Left message -> expectationFailure message
      Right plan -> do
        [(Request.resolvedActorName a, Request.resolvedActorTime a) | a <- Request.bindingActors plan]
          `shouldBe` [("chopstick", False), ("hakker", True)]
        [C.idText i | a <- Request.bindingActors plan, i <- Request.resolvedActorAdapters a, Request.resolvedActorName a == "hakker"]
          `shouldSatisfy` elem "sample.hakkers::hakkerTimePasses"
    Request.handlerReplyCases (head (Request.boundActorHandlers chopstick))
      `shouldBe` [("Busy", Request.CaseBool False), ("Taken", Request.CaseBool True)]
    rejected [chopstick, replaced "asksLeft" ((handler "asksLeft") { Request.handlerProbe = Just "middle" })] "probe middle is not one of the behavior's probes"
    rejected [chopstick, replaced "asksLeft" ((handler "asksLeft") { Request.handlerProbe = Nothing })] "names the probe it hears at"
    rejected [chopstick, replaced "leftTaken" ((handler "leftTaken") { Request.handlerAnswers = Nothing, Request.handlerReplyTo = False })] "hears at it"
    rejected [chopstick, replaced "think" ((handler "think") { Request.handlerReplyTo = True, Request.handlerReply = Just (NativeRef ["sample","Hakker","Think"]) })] "sends a message value"
    rejected [chopstick { Request.boundActorHandlers = [h { Request.handlerReplyCases = [("Taken", Request.CaseText "yes")] } | h <- take 1 (Request.boundActorHandlers chopstick)] ++ drop 1 (Request.boundActorHandlers chopstick) }, hakker]
      "reply cases give a Bool"
    rejected [chopstick, hakker { Request.boundActorPersistence = Just Request.EventSourced }] "unsupported: behavior arguments"
    rejected [chopstick, hakker { Request.boundActorArguments = [Request.ProbeArgument "left", Request.ProbeArgument "left"] }] "a probe is named twice"
  it "reports time passes unsupported without a native Pekko actor" $ do
    source <- readFile "acceptance/pekko-samples/fsm/hakkers.lawspec"
    case compileCore 64 defaultGeneration [Source "hakkers.lawspec" source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> forM_ ["python", "java"] $ \target ->
        case planTesting program >>= emitPlanWithNativeOptions False target Nothing Nothing Request.emptyBindingPlan of
          Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf "lets time pass, which needs virtual time"
          Right _ -> expectationFailure ("time passes was emitted for " ++ target)
