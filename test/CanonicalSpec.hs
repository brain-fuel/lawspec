-- | RC1 surface forms use the established typed and total definition pipeline.
module CanonicalSpec (test_canonicalAuthoringPreservesIntrinsicGuarantees) where

import Data.Either (isRight, isLeft)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Aeson
import qualified Data.Aeson.KeyMap
import qualified LawSpec.Model
import Data.Aeson.Types (parseEither, Parser)
import Test.Hspec
import LawSpec.Model (Source(..), Diagnostic, defaultGeneration)
import LawSpec.Parser (parseSource, parseSourceCanonical, parseSourcesWithCanonical)
import LawSpec.Compile (compileCanonicalWithImports)
import LawSpec.Frontend (compileCore, compileCoreCanonical)
import LawSpec.Discharge (dischargeEvidenceWith)
import LawSpec.Testing (planTestingWith, plannedUnits, plannedProperties, finiteCases, boundaryCases, generatorRequirements)
import qualified LawSpec.Core as C
import LawSpec.Core.Definitions (prepareDefinitions)
import qualified LawSpec.Core.Value as CV
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.Scalar
import LawSpec.Core.Evidence
import qualified LawSpec.Core.Verification as V
import LawSpec.SourceText
import LawSpec.Api (dispatch)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import qualified LawSpec.NativeRequest as NB
import LawSpec.Blake3 (blake3Hex)

source :: String -> Source
source body = Source "canonical.lawspec" ("unit example.canonical\n" ++ body)
core :: String -> Either [Diagnostic] C.Program
core body = compileCoreCanonical 64 defaultGeneration [source body]

-- ref:DEC-total-definitions
-- ref:DEC-readable-notation
test_canonicalAuthoringPreservesIntrinsicGuarantees :: Spec
test_canonicalAuthoringPreservesIntrinsicGuarantees = describe "RC1 canonical authoring" $ do
  it "chooses canonical grammar independently of user source filenames" $ do
    let legacy = "unit filename\ndefinition double (x :: Integer) :: Integer is x + x end"
        canonical = "unit filename\nfunction double (x :: Integer) -> Integer is x + x end function"
    mapM_ (\path -> do
      compileCoreCanonical 64 defaultGeneration [Source path legacy] `shouldSatisfy` isLeft
      compileCoreCanonical 64 defaultGeneration [Source path canonical] `shouldSatisfy` isRight
      parseSourcesWithCanonical [] [] [Source path legacy] `shouldSatisfy` isLeft)
      ["filename.lawspec","<filename>","<lawspec.collections>"]
  it "keeps compiler-provided collections in their versioned grammar" $
    core "function values (x :: Integer) -> Queue Integer is prelude.queueOf [x] end function" `shouldSatisfy` isRight
  it "retains intrinsic checking on pure functions with no verification layers" $
    core "function double (x of type Integer) -> Integer is x + x end function" `shouldSatisfy` isRight
  it "rejects an unsafe denominator before any optional law check" $
    core "function unsafe (x of type Integer) -> Integer is prelude.quot x 0 end function" `shouldSatisfy` isLeft
  it "rejects a recursive function without a decreasing argument" $
    core "function loops (x of type Integer) -> Integer is loops x end function" `shouldSatisfy` isLeft
  it "accepts both annotations and canonical conditional closers" $
    core "function choose (x :: Integer) -> Integer is if x > 0 then x else 0 end if end function" `shouldSatisfy` isRight
  it "preserves singleton scalar metadata without treating it as a section or obligation" $ do
    let input = source $ unlines
          [ "law documented is"
          , "owner: Product.Payments"
          , "id: \"REFUND-001\""
          , "description: \"Approval belongs to the payment requirement.\" end"
          , "definition: for all (owner :: Bool) (id :: Bool) => owner = owner end end"
          , "end" ]
        metadata = LawSpec.Model.LawMetadata (Just "REFUND-001") (Just "Product.Payments")
    fmap (map LawSpec.Model.lawMetadata . LawSpec.Model.laws) (parseSourceCanonical input) `shouldBe` Right [metadata]
    case compileCoreCanonical 64 defaultGeneration [input] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        [C.propertyMetadata p | u <- C.programUnits program,p <- C.unitProperties u] `shouldBe` [metadata]
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
    let formatted = formatSource input
    formatSource formatted `shouldBe` formatted
    lines (LawSpec.Model.content formatted) `shouldContain`
      ["  owner: Product.Payments","  id: \"REFUND-001\""]
    fmap (map LawSpec.Model.lawMetadata . LawSpec.Model.laws) (parseSourceCanonical formatted) `shouldBe` Right [metadata]
    case core "law falseClaim is id: \"PROVED\" owner: Verified definition: false end end" of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
        Left diagnostics -> map LawSpec.Model.code diagnostics `shouldContain` ["refuted"]
        Right evidence -> expectationFailure (show evidence)
  it "rejects duplicate, misplaced and multiple-valued scalar metadata" $ do
    let bodies =
          [ "id: \"one\" id: \"two\" definition: true end end"
          , "owner: first owner: second definition: true end end"
          , "definition: true end id: late end"
          , "id: \"one\" end definition: true end end"
          , "id: \"one\" \"two\" definition: true end end"
          , "id: definition: true end end"
          , "id:: \"one\" definition: true end end"
          , "owner: first second definition: true end end" ]
    mapM_ (\body -> parseSourceCanonical (source ("law invalid is " ++ body)) `shouldSatisfy` isLeft) bodies
  it "resolves typed documentary targets, selectors and groups without discharging claims" $ do
    let body = unlines
          [ "function identity (value :: Bool) -> Bool is value end function"
          , "law first is definition: true end"
          , "references: #S{ref law second description, ref function identity}"
          , "ref law second.references.\"|source.with.dots|"
          , "ref law #S{first, second} definition"
          , "\"|local citation|: \"approved wording\" end end"
          , "law second is definition: false end"
          , "references: ref law first rationale"
          , "\"|source.with.dots|: \"independent oracle\" end end" ]
    case core body of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let properties = [p | u <- C.programUnits program, p <- C.unitProperties u]
            refs = concatMap C.propertyReferences properties
            targets = [t | LawSpec.Model.LawReference t _ <- refs] ++
              [t | LawSpec.Model.FunctionReference t <- refs]
        map LawSpec.Model.documentaryName targets `shouldMatchList`
          ["second","second","first","second","first","identity"]
        map LawSpec.Model.documentaryUnit targets `shouldBe` replicate 6 "example.canonical"
        [s | LawSpec.Model.LawReference _ (Just s) <- refs] `shouldContain`
          [LawSpec.Model.ReferenceNamed "\"|source.with.dots|"]
        case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
          Left ds -> map LawSpec.Model.code ds `shouldContain` ["refuted"]
          Right evidence -> expectationFailure (show evidence)
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification []) program) `shouldBe` Right [NotVerified,NotVerified]
    let formatted = formatSource (source body)
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 defaultGeneration [formatted] `shouldSatisfy` isRight
  it "retains documentary cycles across units without introducing import cycles" $ do
    let first = Source "first.lawspec" $ unlines
          ["unit records.first", "import unrelated as records", "law first is definition: true end",
           "references: ref law records.second.\"|second.with.dots| end end"]
        second = Source "second.lawspec" $ unlines
          ["unit records.second", "law \"|second.with.dots| is definition: true end",
           "references: ref law records.first.first end end"]
    case compileCoreCanonical 64 defaultGeneration [second,first,Source "unrelated.lawspec" "unit unrelated"] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let targets = [t | u <- C.programUnits program,p <- C.unitProperties u,
              LawSpec.Model.LawReference t _ <- C.propertyReferences p]
        map LawSpec.Model.documentaryId targets `shouldMatchList`
          ["records.first::law::first","records.second::law::\"|second.with.dots|"]
        map (LawSpec.Model.file . LawSpec.Model.spanStart . LawSpec.Model.documentarySpan) targets
          `shouldMatchList` ["first.lawspec","second.lawspec"]
  it "resolves documentary function links through aliases and facades to original declarations" $ do
    let domain = Source "domain.lawspec" $ unlines
          ["unit domain", "function \"|same.value| (value :: Bool) -> Bool is value end function",
           "law generic (value :: Bool) is definition: value = value end end",
           "law concrete is definition: true end end"]
        facade = Source "facade.lawspec" $ unlines
          ["unit facade", "import domain as d (\"|same.value|, law generic)",
           "export d.\"|same.value|, law d.generic"]
        consumer = Source "consumer.lawspec" $ unlines
          ["unit consumer", "import facade as f (\"|same.value|, law generic)", "import domain as d",
           "law documented is definition: true end references:",
           "ref function \"|same.value| ref function f.\"|same.value|",
           "ref law generic ref law f.generic ref law d.concrete end end"]
    case compileCoreCanonical 64 defaultGeneration [consumer,facade,domain] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let refs = [r | u <- C.programUnits program, C.idText (C.unitId u) == "consumer",
              p <- C.unitProperties u,r <- C.propertyReferences p]
            targets = [t | LawSpec.Model.LawReference t _ <- refs] ++
              [t | LawSpec.Model.FunctionReference t <- refs]
        map LawSpec.Model.documentaryUnit targets `shouldBe` replicate 5 "domain"
        map LawSpec.Model.documentaryName targets `shouldMatchList`
          ["generic","generic","concrete","\"|same.value|","\"|same.value|"]
  it "rejects unresolved or wrong-kind documentary targets and unknown named selectors" $ do
    let invalid =
          [ "ref law missing", "ref function missing", "ref law onlyFunction", "ref function valid",
            "ref law valid references.\"|missing|", "ref function onlyFunction description" ]
        declarations = "function onlyFunction (value :: Bool) -> Bool is value end function " ++
          "law valid is definition: true end end "
    mapM_ (\reference -> core (declarations ++ "law linked is definition: true end references: " ++ reference ++ " end end")
      `shouldSatisfy` isLeft) invalid
    parseSourceCanonical (source ("law linked is definition: true end references: " ++
      "\"|same|: \"one\" \"|same|: \"two\" end end")) `shouldSatisfy` isLeft
  it "keeps ordinary ref names contextual" $
    core "function ref (value :: Bool) -> Bool is value end function law linked is definition: ref true end end"
      `shouldSatisfy` isRight
  it "enforces package visibility on documentary links without an import" $ do
    let policy importer imported = if importer == "public" && imported == "private"
          then Just "private is outside the visible package boundary" else Nothing
        units = [Source "public.lawspec" "unit public law linked is definition: true end references: ref law private.hidden end end",
          Source "private.lawspec" "unit private law hidden is definition: true end end"]
    case compileCanonicalWithImports policy 64 defaultGeneration units of
      Left ds -> do
        map LawSpec.Model.code ds `shouldBe` ["reference"]
        map LawSpec.Model.at ds `shouldBe` [Just (LawSpec.Model.Location "public.lawspec" 1 68)]
      Right _ -> expectationFailure "documentary reference crossed a private boundary"
  it "reports ambiguous documentary targets and permits explicit qualification" $ do
    let a = Source "a.lawspec" "unit a function same (value :: Bool) -> Bool is value end function"
        b = Source "b.lawspec" "unit b function same (value :: Bool) -> Bool is not value end function"
        consumer name = Source "consumer.lawspec" ("unit consumer import a (same) import b (same) law linked is definition: true end references: ref function " ++ name ++ " end end")
    case compileCoreCanonical 64 defaultGeneration [a,b,consumer "same"] of
      Left ds -> do
        map LawSpec.Model.code ds `shouldBe` ["reference"]
        map LawSpec.Model.message ds `shouldSatisfy` any (\message -> take 9 message == "ambiguous")
      Right _ -> expectationFailure "ambiguous documentary reference was accepted"
    -- Qualified-only imports avoid introducing the conflicting unqualified
    -- executable names into the ordinary import scope.
    compileCoreCanonical 64 defaultGeneration [a,b,Source "consumer.lawspec"
      "unit consumer import a import b law linked is definition: true end references: ref function a.same ref function b.same end end"]
      `shouldSatisfy` isRight
  it "resolves documentary prelude law phrases after ordinary scopes" $
    core "law linked is definition: true end references: ref law prelude.\"|left inverse| ref law \"|left inverse| end end"
      `shouldSatisfy` isRight
  it "exposes structured references in schema 5 while retaining legacy citation arrays" $ do
    let request version source = object
          (["schemaVersion" .= (version :: Int), "method" .= ("check" :: String), "sources" .= [source]] ++
           (if version == 5 then ["languageProfile" .= ("1.0-rc.1" :: String), "verification" .= object ["layers" .= ([] :: [String])]] else []))
        references response = parseEither (withObject "response" $ \o -> do
          diagnostics <- o .: "diagnostics" :: Parser [Value]
          unlessEmpty diagnostics
          laws <- o .: "laws" :: Parser [Value]
          mapM (withObject "law" (.: "references")) laws) response :: Either String [[Value]]
        unlessEmpty [] = pure ()
        unlessEmpty diagnostics = fail (show diagnostics)
        legacy = Source "legacy.lawspec" "unit legacy law `valid` is definition is true end references are \"legacy citation\" end end"
    mapM_ (\version -> case eitherDecode (dispatch (encode (request version legacy))) of
      Left message -> expectationFailure message
      Right response -> references response `shouldBe` Right [[String "legacy citation"]]) [3,4]
    let input = source "law valid is definition: true end references: ref law valid.description \"external citation\" end end"
    case eitherDecode (dispatch (encode (request 5 input))) of
      Left message -> expectationFailure message
      Right response -> case references response of
        Right [[Object law, Object external]] -> do
          Data.Aeson.KeyMap.lookup "kind" law `shouldBe` Just (String "law")
          Data.Aeson.KeyMap.lookup "selector" law `shouldBe` Just (object ["kind" .= ("description" :: String)])
          Data.Aeson.KeyMap.lookup "resource" external `shouldBe` Just (String "external citation")
        result -> expectationFailure (show result)
  it "retargets full-unit documentary links to each dependency's selected package version" $ do
    let money version = object
          [ "name" .= ("shop.money" :: String), "version" .= (version :: String)
          , "sources" .= [Source "money.lawspec" (unlines
              [ "unit shop.money", "law current is definition: true end references:"
              , "ref law shop.money.current"
              , "\"|source|: \"keep ref law shop.money.current in documentary text\" end end" ])] ]
        report = object
          [ "name" .= ("shop.report" :: String), "version" .= ("1.0.0" :: String)
          , "dependencies" .= object ["shop.money" .= ("^2.0.0" :: String)]
          , "sources" .= [Source "report.lawspec" (unlines
              [ "unit shop.report", "import shop.money as money"
              , "law current is definition: true end references:"
              , "ref law #S{shop.money.current, money.current} definition end end" ])] ]
        consumer = Source "consumer.lawspec" (unlines
          [ "unit app", "import shop.money as money", "import shop.report"
          , "law current is definition: true end references:"
          , "#S{ref law shop.money.current, ref law money.current}"
          , "ref law shop.report.current end end" ])
        request = object ["schemaVersion" .= (5 :: Int), "method" .= ("check" :: String),
          "languageProfile" .= ("1.0-rc.1" :: String), "verification" .= object ["layers" .= ([] :: [String])],
          "sources" .= [consumer], "dependencies" .= object ["shop.money" .= ("^1.0.0" :: String), "shop.report" .= ("^1.0.0" :: String)],
          "packages" .= [money "1.4.0",money "2.1.0",report]]
        owners response = parseEither (withObject "response" $ \o -> do
          diagnostics <- o .: "diagnostics" :: Parser [Value]
          if null diagnostics then pure () else fail (show diagnostics)
          laws <- o .: "laws" :: Parser [Value]
          mapM (withObject "law" $ \law -> do
            owner <- law .: "owner" :: Parser String
            refs <- law .: "references" :: Parser [Value]
            targets <- mapM (withObject "reference" $ \ref -> do
              kind <- ref .: "kind" :: Parser String
              if kind == "external" then (:[]) <$> (ref .: "resource")
                else do target <- ref .: "target"
                        withObject "target" (fmap (:[]) . (.: "unit")) target) refs
            pure (owner,concat targets)) laws) response :: Either String [(String,[String])]
    case eitherDecode (dispatch (encode request)) of
      Left message -> expectationFailure message
      Right response -> owners response `shouldBe` Right
        [ ("shop.money.v1x4x0",["shop.money.v1x4x0","keep ref law shop.money.current in documentary text"])
        , ("shop.money.v2x1x0",["shop.money.v2x1x0","keep ref law shop.money.current in documentary text"])
        , ("shop.report",["shop.money.v2x1x0","shop.money.v2x1x0"])
        , ("app",["shop.money.v1x4x0","shop.money.v1x4x0","shop.report"]) ]
  it "preserves universal/existential order and checks complete finite witnesses" $ do
    let law body = "law witnesses is definition: " ++ body ++ " end end"
    case core (law "for all (value :: Bool) => there exists (witness :: Bool) such that witness = value end end") of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let properties = [p | u <- C.programUnits program, p <- C.unitProperties u]
        map (length . C.propertyInputs) properties `shouldBe` [1]
        map (C.hasLogicalQuantifier . C.propertyBody) properties `shouldBe` [True]
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
        case planTestingWith (V.Verification [V.Exhaustive]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
    case core (law "there exists (witness :: Bool) such that for all (value :: Bool) => witness = value end end") of
      Left ds -> expectationFailure (show ds)
      Right program -> case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
        Left diagnostics -> map LawSpec.Model.code diagnostics `shouldContain` ["refuted"]
        Right evidence -> expectationFailure (show evidence)
  it "composes scoped propositions with logical precedence and short circuiting" $ do
    let propositions =
          [ "(for all (value :: Bool) => value = value end) and (for all (value :: Bool) => value = value end)"
          , "(there exists (value :: Bool) such that value and not value end) or (for all (value :: Bool where false) => false end)"
          , "(there exists (witness :: Bool) such that witness end) implies (for all (value :: Bool) => value = value end)"
          , "false implies there exists (witness :: Integer) such that false end"
          , "true or (there exists (witness :: Integer) such that false end)"
          , "not not (there exists (witness :: Bool) such that witness end)"
          , "for all (value :: Bool) => for all (value :: Bool) => value = value end end"
          , "false implies true implies false"
          , "true or false and false"
          , "(1 + 2) must be 3" ]
    mapM_ (\proposition -> case core ("law composed is definition: " ++ proposition ++ " end end") of
      Left ds -> expectationFailure (proposition ++ ": " ++ show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]) propositions
  it "does not hoist a sibling's empty universal domain over another obligation" $ do
    let propositions =
          [ "(for all (value :: Bool where false) => false end) and false"
          , "(there exists (witness :: Bool) such that false end) or false"
          , "(there exists (witness :: Bool) such that witness end) implies false" ]
    mapM_ (\proposition -> case core ("law falseClaim is definition: " ++ proposition ++ " end end") of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        [length (C.propertyInputs p) | u <- C.programUnits program,p <- C.unitProperties u] `shouldBe` [0]
        case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
          Left ds -> map LawSpec.Model.code ds `shouldContain` ["refuted"]
          Right evidence -> expectationFailure (show evidence)) propositions
    core "law escaped is definition: (for all (value :: Bool) => true end) and value end end" `shouldSatisfy` isLeft
  it "keeps legacy and canonical expansion caches distinct for an identical surface law" $ do
    let unit header section quantifier ending closing = Source "profile.lawspec" $ unlines
          [ "unit profile",header,section,"(",quantifier,"x = x",ending,closing,"and","true = true","end","end" ]
        legacy = unit "law `same` is" "definition is" "`for all` (x :: Bool) ." ")" ""
        canonical = unit "law same is" "definition:" "for all (x :: Bool) =>" "end" ")"
        counts program = [length (C.propertyInputs p) | u <- C.programUnits program,p <- C.unitProperties u]
    fmap (map LawSpec.Model.definition . LawSpec.Model.laws) (parseSource legacy) `shouldBe`
      fmap (map LawSpec.Model.definition . LawSpec.Model.laws) (parseSourceCanonical canonical)
    fmap counts (compileCore 64 defaultGeneration [legacy]) `shouldBe` Right [1]
    fmap counts (compileCoreCanonical 64 defaultGeneration [canonical]) `shouldBe` Right [0]
    fmap counts (compileCore 64 defaultGeneration [legacy]) `shouldBe` Right [1]
  it "does not let a sibling's binder hide another clause's effectful procedure" $ case core (unlines
    [ "ability Signal is signal of type Bool -> Bool end"
    , "handler echo for Signal is signal value is value end end"
    , "procedure read (value :: Bool) -> Bool uses Signal is signal value end procedure"
    , "law observed using echo is definition:"
    , "  (for all (read :: Bool) => read = read end) and read true = true"
    , "end end" ]) of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      [length (C.propertyHandlers p) | u <- C.programUnits program,p <- C.unitProperties u] `shouldBe` [1]
      fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
  it "retains the snapshot requirement for effects repeated inside a search" $ case core (unlines
    [ "ability Signal is signal of type Bool -> Bool end"
    , "handler echo for Signal is signal value is value end end"
    , "procedure read (value :: Bool) -> Bool uses Signal is signal value end procedure"
    , "law observed using echo is definition: there exists (value :: Bool) such that read value = value end end end" ]) of
    Left ds -> expectationFailure (show ds)
    Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
      (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [Unsupported]
  it "decides empty outer universal domains without evaluating a body or inventing witnesses" $ do
    let empty = "type Empty is one of | Loop of type Empty end type\n"
        bodies =
          [ "for all (value :: Empty) => false end"
          , "for all (number :: Integer) (value :: Empty) => false end"
          , "for all (value :: Bool where false) => false end"
          , "for all (value :: Bool) (other :: Bool where other and not other) => false end"
          , "for all (value :: Bool where false) => there exists (witness :: Integer) such that false end end"
          , "for all (value :: Integer where false) => false end" ]
    mapM_ (\body -> case core (empty ++ "law vacuous is definition: " ++ body ++ " end end") of
      Left ds -> expectationFailure (body ++ ": " ++ show ds)
      Right program -> do
        case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
          Left ds -> expectationFailure (show ds)
          Right evidence -> do
            let laws = filter ((== "law") . obligationStage) evidence
            map obligationStatus laws `shouldBe` [ExhaustivelyChecked]
            map obligationReason laws `shouldBe`
              ["the universal input domain is empty; no cases were evaluated and no witnesses were produced"]
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Proof]) program) `shouldBe` Right [Proved]
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Property]) program) `shouldBe` Right [Incomplete]
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification []) program) `shouldBe` Right [NotVerified]
        mapM_ (\selection -> case planTestingWith (V.Verification selection) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> do
            let properties = concatMap plannedProperties (plannedUnits plan)
            map finiteCases properties `shouldBe` [Just []]
            map boundaryCases properties `shouldBe` [[]]
            map (length . generatorRequirements) properties `shouldBe` [0]
            mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets)
          [[V.Exhaustive],[V.Property],[V.Exhaustive,V.Property]]) bodies
  it "rejects examples outside an empty universal domain and keeps inhabited false claims refutable" $ do
    case core (unlines
      [ "law invalidRow is definition: for all (value :: Bool where false) => true end end"
      , "expect value = expected in table (value, expected): row true, true end end" ]) of
      Left ds -> map LawSpec.Model.code ds `shouldContain` ["semantic"]
      Right program -> planTestingWith (V.Verification [V.Exhaustive,V.Examples]) program `shouldSatisfy` isLeft
    case core "law falseClaim is definition: for all (value :: Bool) => false end end end" of
      Left ds -> expectationFailure (show ds)
      Right program -> case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
        Left ds -> map LawSpec.Model.code ds `shouldContain` ["refuted"]
        Right evidence -> expectationFailure (show evidence)
  it "makes existential restrictions witness conditions, including dependent binders and shadowing" $ do
    let bodies =
          [ "for all (value :: Bool) => there must exist a (witness :: Bool where witness = value) such that witness = value end end"
          , "there exists (first :: Bool) (second :: Bool where second = first) such that first = second end"
          , "for all (value :: Bool) => there exists (value :: Bool where value) such that value = true end end"
          , "there does not exist (value :: Bool where false) such that true end"
          , "there must not exist an (value :: Bool) such that value and not value end"
          , "must not there exists (value :: Bool where false) such that true end"
          , "there exists (witness :: Bool) such that for all (value :: Bool where false) => false end end" ]
    mapM_ (\body -> case core ("law valid is definition: " ++ body ++ " end end") of
      Left ds -> expectationFailure (body ++ ": " ++ show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]) bodies
    core "law invalid is definition: there exists (first :: Bool where second) (second :: Bool) such that true end end end" `shouldSatisfy` isLeft
    core "law invalid is definition: there exists (value :: Bool where 1) such that true end end end" `shouldSatisfy` isLeft
  it "keeps an unavailable existential search incomplete rather than refuting existence" $ case core
    "law open is definition: there exists (value :: Integer) such that value * value = -1 end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith V.noVerification program) `shouldBe` Right [NotVerified]
      fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [Incomplete]
      planTestingWith (V.Verification [V.Exhaustive]) program `shouldSatisfy` isRight
  it "does not turn an undefined candidate into a refutation of existence" $ case core
    "law unknown is definition: there exists (value :: UInt8) such that prelude.quot 1 value = 2 end end end" of
    Left _ -> pure () -- An intrinsic definedness rejection is also sound.
    Right program -> case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
      Left diagnostics -> do
        map LawSpec.Model.code diagnostics `shouldNotContain` ["refuted"]
        map LawSpec.Model.code diagnostics `shouldContain` ["verification-incomplete"]
      Right evidence -> expectationFailure ("undefined search produced evidence: " ++ show evidence)
  it "distinguishes logical empty domains from existentially packaged data" $ do
    let declaration = "type Empty is one of end type\n"
    case core (declaration ++ "law empty is definition: there does not exist (value :: Empty) such that true end end end") of
      Left ds -> expectationFailure (show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
  it "compiles complete authorization snapshots and their nested evidence through every target" $ do
    let path = "examples/rc1/authorization-snapshots.lawspec"
    body <- readFile path
    case compileCoreCanonical 64 defaultGeneration [Source path body] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program)
          `shouldBe` Right (replicate 5 ExhaustivelyChecked)
        case planTestingWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "checks recursive record construction and traversal through every target" $ do
    body <- readFile "examples/rc1/recursive-records.lawspec"
    case compileCoreCanonical 64 defaultGeneration [Source "recursive-records.lawspec" body] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe`
            Right (replicate 4 ExhaustivelyChecked)
        case planTestingWith (V.Verification [V.Exhaustive]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "does not treat fields of rebuilt or returned records as descending arguments" $ do
    let declaration = "type Chain is a record{next :: Maybe Chain} end type\n"
        grow = "function grow (chain :: Chain) -> Chain is Chain record{next = Just chain} end function\n"
        repeats selected = "function repeats (chain :: Chain) -> Whole is first matching case of " ++ selected ++
          ": when record{next = Just rest} then repeats rest otherwise 0 end case end function"
    mapM_ (\body -> case core body of
      Left diagnostics -> map LawSpec.Model.code diagnostics `shouldContain` ["total"]
      Right _ -> expectationFailure "a rebuilt or returned record acquired structural provenance")
      [declaration ++ repeats "Chain record{next = Just chain}",declaration ++ grow ++ repeats "grow chain"]
  it "expands composed reusable requirements across nominal imports on every target" $ do
    let paths = ["examples/rc1/authorization-snapshots.lawspec", "examples/rc1/requirement-composition.lawspec"]
    sources <- mapM (\path -> Source path <$> readFile path) paths
    case compileCoreCanonical 64 defaultGeneration sources of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program)
          `shouldBe` Right (replicate 10 ExhaustivelyChecked)
        case planTestingWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "bounds finite logical expansion without claiming an unsuccessful search proves absence" $ case core
    "law bounded is definition: there exists (a :: Bool) (b :: Bool) such that a and not a end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      let limited = program { C.programUnits = [u { C.unitProperties =
            [p { C.propertyGeneration = defaultGeneration { LawSpec.Model.exhaustiveLimit = 2 } }
              | p <- C.unitProperties u] } | u <- C.programUnits program] }
      fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) limited) `shouldBe` Right [Incomplete]
  it "types worded disjunction above implication without treating it as an application argument" $ case core
    "law logic is definition: for all (a :: Bool) (b :: Bool) => (a or b) = (not (not a and not b)) end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
      (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
  it "specializes reusable existential laws under proposition negation" $ do
    let library = Source "fixed-point.lawspec" $ unlines
          [ "unit requirements.fixedPoint"
          , "law fixedPoint (operation :: a -> a) requires Eq a is"
          , "  definition: there exists (value :: a) such that operation value = value end end"
          , "end" ]
        caller = Source "toggle.lawspec" $ unlines
          [ "unit example.toggle", "import requirements.fixedPoint as r"
          , "function toggle (value :: Bool) -> Bool is not value end function"
          , "law absent is definition: must not apply law r.fixedPoint toggle end end" ]
    case compileCoreCanonical 64 defaultGeneration [library,caller] of
      Left ds -> expectationFailure (show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
  it "specializes checked generic functions inside existential scopes" $ case core (unlines
    [ "function same (value :: a) -> a is value end function"
    , "law scoped is definition: there exists (value :: Bool) such that same value = value end end end" ]) of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked]
      case planTestingWith (V.Verification [V.Exhaustive]) program of
        Left ds -> expectationFailure (show ds)
        Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "resolves imported functions before a later logical binder shadows their name" $ do
    let library = Source "selectors.lawspec" "unit selectors\nfunction later (value :: Bool) -> Bool is value end function"
        body quantifier separator = Source "ordered.lawspec" $ unlines
          [ "unit ordered", "import selectors (later)"
          , "law ordered is definition: " ++ quantifier ++ " (first :: Bool where later first)"
          , "  (later :: Bool where later = first) " ++ separator ++ " later = first end end end" ]
    mapM_ (\caller -> case compileCoreCanonical 64 defaultGeneration [library,caller] of
      Left ds -> expectationFailure (show ds)
      Right program -> fmap (map obligationStatus . filter ((== "law") . obligationStage))
        (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right [ExhaustivelyChecked])
      [body "there exists" "such that",body "for all" "=>"]
  it "requires the named function closer" $
    parseSourceCanonical (source "function f (x :: Integer) -> Integer is x end") `shouldSatisfy` isLeft
  it "rejects legacy sections and numeric aliases in the RC1 profile" $ do
    parseSourceCanonical (source "law old is definition is true end end") `shouldSatisfy` isLeft
    parseSourceCanonical (source "law old is definition: `for all` (x :: Bool) . x = x end end") `shouldSatisfy` isLeft
    parseSourceCanonical (source "function f (x :: Natural) -> Natural is x end function") `shouldSatisfy` isLeft
  it "treats each equality spelling as the same typed obligation" $ do
    let law wording = core ("law same is definition: for all (x of type Integer) => " ++ wording ++ " end end end")
        proposition (Right p) = [C.propertyBody l | u <- C.programUnits p, l <- C.unitProperties u]
        proposition (Left ds) = error (show ds)
        erase (C.Equation ev a b) = (ev, C.expressionNode a, C.expressionNode b)
        erase p = error (show p)
        meanings = map (map erase . proposition . law)
          ["x must be x", "x is x", "x = x", "x must = x", "must x = x"]
    meanings `shouldSatisfy` (\xs -> not (null xs) && all (== head xs) (tail xs))
  it "supports reordered singleton sections and expectation-first tables" $ do
    let body = unlines
          [ "function double (x of type Integer) -> Integer is x + x end function"
          , "law doubled is"
          , "  description: \"Doubling adds a value to itself.\" end"
          , "  expect double x = expected"
          , "  expect x + x = expected"
          , "  in table (x, expected): row -1, -2 row 0, 0 row 1, 2 end"
          , "  definition: for all (x of type Integer) => double x must be x + x end end"
          , "end" ]
    core body `shouldSatisfy` isRight
  it "specializes the existing inverse law in its declared argument order" $ do
    let body = unlines
          [ "function encode (value :: Bool) -> Text is if value then \"yes\" else \"no\" end if end function"
          , "function decode (text :: Text) -> Bool is text = \"yes\" end function"
          , "law roundTrip is definition: apply law \"|left inverse| decode encode end"
          , "  expect decode (encode x) = expected"
          , "  in table (x, expected): row false, false row true, true end end"
          , "law qualifiedRoundTrip is definition: apply law prelude.\"|left inverse| decode encode end end" ]
    case core body of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let properties = [p | u <- C.programUnits program, p <- C.unitProperties u]
        map (map (C.binderType . C.quantifiedBinder) . C.propertyInputs) properties `shouldBe` replicate 2 [C.scalarType "Bool"]
        map (length . C.propertyExamples) properties `shouldBe` [2,0]
        length [() | p <- properties, any (\t -> take 12 t == "left inverse") (C.propertyTrace p)] `shouldBe` 2
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive]) program) `shouldBe` Right (replicate 2 ExhaustivelyChecked)
  it "resolves reusable phrase laws across qualified, listed and re-exported imports" $ do
    let library = Source "requirements.lawspec" $ unlines
          [ "unit requirements"
          , "law \"|keeps `the.value| (operation :: a -> a) requires Eq a is"
          , "  definition: for all (value :: a) => operation value = value end end"
          , "end" ]
        facade = Source "facade.lawspec" $ unlines
          [ "unit facade", "import requirements as r (law \"|keeps `the.value|)"
          , "export law r.\"|keeps `the.value|" ]
        caller = Source "caller.lawspec" $ unlines
          [ "unit caller", "import facade as f (law \"|keeps `the.value|)"
          , "function same (value :: Bool) -> Bool is value end function"
          , "law qualified is definition: apply law f.\"|keeps `the.value| same end end"
          , "law listed is definition: apply law \"|keeps `the.value| same end end" ]
    compileCoreCanonical 64 defaultGeneration [library,facade,caller] `shouldSatisfy` isRight
  it "keeps local reusable names ahead of prelude fallback and separate from values" $
    core (unlines
      [ "function idempotent (value :: Bool) -> Bool is value end function"
      , "law idempotent (value :: Bool) is definition: value = value end end"
      , "law local is definition: apply law idempotent true end end" ]) `shouldSatisfy` isRight
  it "retains capability, arity, unknown-law and recursive-expansion failures" $ do
    mapM_ (\body -> core body `shouldSatisfy` isLeft)
      [ "law wrong is definition: apply law missing true end end"
      , "law wrong is definition: apply law \"|left inverse| true end end"
      , "law loop (value :: Bool) is definition: apply law loop value end end"
      , "law wrong (f :: a -> a) is definition: apply law \"|idempotent| f end end" ]
  it "rejects missing and duplicate definitions and duplicate metadata sections" $ do
    mapM_ (\body -> parseSourceCanonical (source body) `shouldSatisfy` isLeft)
      ["law x is description: \"x\" end end"
      ,"law x is definition: true end definition: true end end"
      ,"law x is definition: true end rationale: \"x\" end rationale: \"y\" end end"]
  it "parses phrase spelling and prefix/infix applications without a second namespace" $ do
    core (unlines
      ["function \"|adds the values| (x of type Integer) (y of type Integer) -> Integer is x + y end function"
      ,"law addition is definition: for all (x of type Integer) (y of type Integer) =>"
      ,"  \"|adds the values| x y must be x `|adds the values| y"
      ,"end end end"]) `shouldSatisfy` isRight
  it "resolves qualified prefix and infix calls, including dots inside phrase names" $
    compileCoreCanonical 64 defaultGeneration
      [ Source "names.lawspec" "unit names\nfunction \"|adds.the values| (x :: Integer) (y :: Integer) -> Integer is x + y end function"
      , Source "caller.lawspec" "unit caller\nimport names as n\nlaw agrees is definition: for all (x :: Integer) (y :: Integer) => n.\"|adds.the values| x y = x `n.\"|adds.the values| y end end end" ] `shouldSatisfy` isRight
  it "rejects empty, edge-spaced and multiline phrase names" $
    mapM_ (\name -> parseSourceCanonical (source ("function " ++ name ++ " (x :: Integer) -> Integer is x end function")) `shouldSatisfy` isLeft)
      ["\"||", "\"| x|", "\"|x |", "\"|x\ny|"]
  it "does not accept an ambiguous named infix chain" $
    parseSourceCanonical (source (unlines
      ["function add (x :: Integer) (y :: Integer) -> Integer is x + y end function"
      ,"law bad is definition: 1 `add 2 `add 3 = 6 end end"])) `shouldSatisfy` isLeft
  it "supports nominal records with explicit construction and field access" $
    core (unlines
      ["type Picture is a record{ fileName of type Text, width of type Nat } end type"
      ,"function picture (x of type Nat) -> Picture is Picture record{width = x, fileName = \"photo.jpg\"} end function"
      ,"function width (p of type Picture) -> Nat is p.width end function"]) `shouldSatisfy` isRight
  it "retains polymorphism in nominal record construction and projection" $
    core (unlines
      ["type Box (a of type Type) is a record{value of type a} end type"
      ,"function store (value of type a) -> Box a is Box record{value = value} end function"
      ,"function retrieve (box of type Box a) -> a is box.value end function"
      ,"law roundTrip is definition: for all (value of type Bool) => retrieve (store value) = value end end end"]) `shouldSatisfy` isRight
  it "rejects unknown, missing and duplicate record value fields" $
    mapM_ (\fields -> core ("type Box is a record{ value of type Integer } end type\nfunction box (x :: Integer) -> Box is Box record{" ++ fields ++ "} end function") `shouldSatisfy` isLeft)
      ["other = x", "", "value = x, value = x"]
  it "does not construct an alternative through nominal record syntax or erase a bare empty record pattern's type" $ do
    core "type Box is one of | Box of type Integer end type\nfunction box (x :: Integer) -> Box is Box record{value = x} end function" `shouldSatisfy` isLeft
    core "function value (x :: Integer) -> Integer is first matching case of x: when record{} then 0 end case end function" `shouldSatisfy` isLeft
    core "type EmptyRecord is a record{} end type\nfunction value (x :: EmptyRecord) -> Integer is first matching case of x: when EmptyRecord record{} then 0 end case end function" `shouldSatisfy` isRight
  it "retains exhaustiveness checking for explicit alternative payloads" $ do
    core (unlines
      ["type Answer is one of | Yes of type Integer | No end type"
      ,"function value (a of type Answer) -> Integer is first matching case of a: when Yes n then n when No then 0 end case end function"]) `shouldSatisfy` isRight
    core (unlines
      ["type Answer is one of | Yes of type Integer | No end type"
      ,"function value (a of type Answer) -> Integer is first matching case of a: when Yes n then n end case end function"]) `shouldSatisfy` isLeft
  it "checks ordered Boolean cases and failed guards with a fallback" $
    core "function value (x :: Integer) -> Integer is first matching case of x: when it > 0 if it < 10 then 1 when it >= 10 then 2 otherwise 0 end case end function" `shouldSatisfy` isRight
  it "keeps failed constructor-guard bindings out of later branches" $ case core (unlines
    ["type Answer is one of | Yes of type Integer | No end type"
    ,"function value (x :: Integer) (a :: Answer) -> Integer is first matching case of a: when Yes x if false then x otherwise x end case end function"]) of
    Left ds -> expectationFailure (show ds)
    Right program -> case prepareDefinitions program of
      Left ds -> expectationFailure (show ds)
      Right invoke -> invoke (C.Id "example.canonical::value")
        [CV.ScalarValue (SInteger "Integer" 100), CV.DataValue (C.scalarType "example.canonical::type::Answer")
          (C.Id "example.canonical::type::Answer::Yes") [CV.ScalarValue (SInteger "Integer" 5)]]
        `shouldBe` Right (CV.ScalarValue (SInteger "Integer" 100))
  it "preserves ordered nested record and constructor branches, including guard fall-through" $ do
    let body = unlines
          ["type Inner is one of | Number of type Integer | Zero end type"
          ,"type Details is a record{ inner of type Inner, label of type Text } end type"
          ,"type Packet is one of | Wrap of type Details | Empty end type"
          ,"function value (packet :: Packet) -> Integer is"
          ,"  first matching case of packet:"
          ,"    when Wrap (Details record{inner = Number n}) if n > 0 then n"
          ,"    when Wrap record{inner = Number n} then 0"
          ,"    when Wrap record{inner = Zero} then -1"
          ,"    when Empty then -2"
          ,"  end case"
          ,"end function"]
    case core body of
      Left ds -> expectationFailure (show ds)
      Right program -> case prepareDefinitions program of
        Left ds -> expectationFailure (show ds)
        Right invoke -> do
          let integer n = CV.ScalarValue (SInteger "Integer" n)
              inner tag fields = CV.DataValue (C.scalarType "example.canonical::type::Inner")
                (C.Id ("example.canonical::type::Inner::" ++ tag)) fields
              details value = CV.DataValue (C.scalarType "example.canonical::type::Details")
                (C.Id "example.canonical::type::Details::Details") [value,CV.ScalarValue (LawSpec.Scalar.textScalar "label")]
              packet tag fields = CV.DataValue (C.scalarType "example.canonical::type::Packet")
                (C.Id ("example.canonical::type::Packet::" ++ tag)) fields
          mapM_ (\(input,expected) -> invoke (C.Id "example.canonical::value") [input] `shouldBe` Right (integer expected))
            [(packet "Wrap" [details (inner "Number" [integer 3])],3)
            ,(packet "Wrap" [details (inner "Number" [integer (-3)])],0)
            ,(packet "Wrap" [details (inner "Zero" [])],-1)
            ,(packet "Empty" [],-2)]
  it "rejects incomplete recursive patterns, unknown fields and repeated bindings" $ do
    let prefix = "type Inner is one of | Number of type Integer | Zero end type\ntype Details is a record{inner of type Inner, label of type Text} end type\n"
        function pattern = prefix ++ "function value (details :: Details) -> Integer is first matching case of details: when " ++ pattern ++ " then 0 end case end function"
    mapM_ (\pattern -> core (function pattern) `shouldSatisfy` isLeft)
      ["Details record{inner = Number n}","record{unknown = x}","record{label = x, inner = Number x}","record{label = x, label = y}"]
  it "covers Boolean literal patterns without requiring an unnecessary fallback" $ do
    core "function flag (x :: Bool) -> Integer is first matching case of x: when true then 1 when false then 0 end case end function" `shouldSatisfy` isRight
    core "function flag (x :: Bool) -> Integer is first matching case of x: when true then 1 end case end function" `shouldSatisfy` isLeft
  it "resolves imported nominal record construction and patterns" $
    compileCoreCanonical 64 defaultGeneration
      [Source "records.lawspec" "unit records\ntype Box is a record{value of type Integer} end type"
      ,Source "caller.lawspec" "unit caller\nimport records as r\nfunction value (x :: Integer) -> Integer is first matching case of r.Box record{value = x}: when r.Box record{value = n} then n end case end function"] `shouldSatisfy` isRight
  it "keeps typed-equal literal patterns available after a failed guard, including IEEE signed zero" $ do
    mapM_ (\(first,second,input) -> case core ("function value (x :: Float64) -> Integer is first matching case of x: when " ++ first ++ " if false then 4 when " ++ second ++ " then 5 otherwise 0 end case end function") of
      Left ds -> expectationFailure (show ds)
      Right program -> case prepareDefinitions program of
        Left ds -> expectationFailure (show ds)
        Right invoke -> invoke (C.Id "example.canonical::value") [CV.ScalarValue (SFloat "Float64" input)]
          `shouldBe` Right (CV.ScalarValue (SInteger "Integer" 5)))
      [("1","1.0","3ff0000000000000")
      ,("float64Bits(\"0000000000000000\")","float64Bits(\"8000000000000000\")","0000000000000000")]
  it "cannot infer a stronger refinement than a stored field guarantees" $
    core (unlines
      ["type Picture is a record{ width of type Nat } end type"
      ,"function width (p of type Picture) -> (result of type Whole where result > p.width) is p.width end function"]) `shouldSatisfy` isLeft
  it "types contextual hexadecimal and binary constants exactly" $
    core "function bits (x :: Integer) -> Integer is 0x10 + 0b10 + x end function" `shouldSatisfy` isRight
  it "resolves canonical Set to Eq-only storage in ordinary and qualified signatures" $ do
    core "function same (values of type Set Float64) -> Set Float64 is values end function" `shouldSatisfy` isRight
    core "import lawspec.collections as c\nfunction same (values of type c.Set Float64) -> c.Set Float64 is values end function" `shouldSatisfy` isRight
  it "reports no selected checks and generates no optional law tests" $ case core
    "function same (x :: Bool) -> Bool is x end function\nlaw identity is definition: for all (x :: Bool) => same x = x end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      let result = dischargeEvidenceWith V.noVerification program
      result `shouldSatisfy` isRight
      case result of
        Right obligations -> [obligationStatus o | o <- obligations, obligationStage o == "law"] `shouldBe` [NotVerified]
        _ -> pure ()
      case planTestingWith V.noVerification program of
        Left ds -> expectationFailure (show ds)
        Right plan -> concatMap plannedProperties (plannedUnits plan) `shouldBe` []
  it "does not silently pass requested exhaustive checking over an unbounded domain" $ case core
    "law identity is definition: for all (x :: Integer) => x = x end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> planTestingWith (V.Verification [V.Exhaustive]) program `shouldSatisfy` isLeft
  it "scans named record headers after canonical infix calls in the same unit" $ do
    body <- readFile "examples/rc1-authoring.lawspec"
    compileCoreCanonical 64 defaultGeneration [Source "rc1-authoring.lawspec" body] `shouldSatisfy` isRight
  it "discovers record declarations between named infix calls without relying on line breaks" $
    core (unwords
      ["function add (x :: Integer) (y :: Integer) -> Integer is x + y end function"
      ,"law before is definition: for all (x :: Integer) => x `add x = x + x end end end"
      ,"type Box is a record{value of type Integer} end type"
      ,"function box (x :: Integer) -> Box is Box record{value = x} end function"
      ,"law after is definition: for all (x :: Integer) => x `add x = x + x end end end"]) `shouldSatisfy` isRight
  it "compiles the RC1 starter with multiple expectations referring to input and result columns" $ do
    body <- readFile "templates/npm/starter-rc1.lawspec"
    compileCoreCanonical 64 defaultGeneration [Source "starter-rc1.lawspec" body] `shouldSatisfy` isRight
  it "checks the bit codec, its reused inverse and independent expectations through every emitter" $ do
    let path = "examples/rc1/bit-codec.lawspec"
    body <- readFile path
    case compileCoreCanonical 64 defaultGeneration [Source path body] of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        fmap (map obligationStatus . filter ((== "law") . obligationStage))
          (dischargeEvidenceWith (V.Verification [V.Exhaustive,V.Examples]) program)
          `shouldBe` Right (replicate 3 ExhaustivelyChecked)
        case planTestingWith (V.Verification [V.Exhaustive,V.Examples]) program of
          Left ds -> expectationFailure (show ds)
          Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "constructs, recursively matches and checks outcomes for all eight delivery/document/file combinations" $ do
    mapM_ (\combination -> do
      let path = "examples/rc1/nesting/" ++ combination ++ ".lawspec"
      body <- readFile path
      case compileCoreCanonical 64 defaultGeneration [Source path body] of
        Left ds -> expectationFailure (combination ++ ": " ++ show ds)
        Right program -> do
          case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
            Left ds -> expectationFailure (combination ++ ": " ++ show ds)
            Right obligations -> [obligationStatus o | o <- obligations, obligationStage o == "law"]
              `shouldSatisfy` (\statuses -> not (null statuses) && all (== ExhaustivelyChecked) statuses)
          case planTestingWith V.noVerification program of
            Left ds -> expectationFailure (combination ++ ": " ++ show ds)
            Right plan -> mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets)
      ["rrr","rru","rur","ruu","urr","uru","uur","uuu"]
  it "refutes all eight filename-loss mutants only when law verification is selected" $ do
    let breakOn needle text
          | take (length needle) text == needle = ("",text)
          | first:rest <- text = let (prefix,suffix) = breakOn needle rest in (first:prefix,suffix)
          | otherwise = ("","")
    mapM_ (\combination -> do
      let path = "examples/rc1/nesting/" ++ combination ++ ".lawspec"
      body <- readFile path
      let (prefix,suffix) = breakOn "then Just name" body
          mutant = prefix ++ "then Nothing" ++ drop (length ("then Just name" :: String)) suffix
      suffix `shouldSatisfy` (not . null)
      case compileCoreCanonical 64 defaultGeneration [Source path mutant] of
        Left ds -> expectationFailure (combination ++ ": intrinsic checks rejected a well-typed mutant: " ++ show ds)
        Right program -> do
          dischargeEvidenceWith V.noVerification program `shouldSatisfy` isRight
          case dischargeEvidenceWith (V.Verification [V.Exhaustive]) program of
            Right _ -> expectationFailure (combination ++ ": filename-loss mutant escaped exhaustive checking")
            Left diagnostics -> map LawSpec.Model.code diagnostics `shouldSatisfy` elem "refuted")
      ["rrr","rru","rur","ruu","urr","uru","uur","uuu"]
  it "keeps native test plans distinct from completed evidence" $ case core
    "adapter of type Bool -> Bool\nlaw identity is definition: for all (x :: Bool) => adapter x = x end end end" of
    Left ds -> expectationFailure (show ds)
    Right program -> case dischargeEvidenceWith (V.Verification [V.Property]) program of
      Left ds -> expectationFailure (show ds)
      Right obligations -> [obligationStatus o | o <- obligations, obligationStage o == "law"] `shouldBe` [Planned]
  it "lowers finite mappings and their derived lookup definitions to checked Core" $
    core (unlines
      ["type Digit is one of | Zero | One end type"
      ,"mapping digitText of type Digit -> Text is row Zero, \"0\" row One, \"1\" end mapping"
      ,"law agreed is definition: digitText Zero = \"0\" end end"]) `shouldSatisfy` isRight
  it "rejects duplicate and non-reflexive mapping keys and incomplete coverage" $
    mapM_ (\body -> core body `shouldSatisfy` isLeft)
      ["mapping b of type Bool -> Text is row true, \"x\" row true, \"y\" otherwise \"z\" end mapping"
      ,"mapping b of type Float64 -> Text is row float64Bits(\"7ff8000000000000\"), \"NaN\" otherwise \"x\" end mapping"
      ,"type Digit is one of | Zero | One end type mapping digitText of type Digit -> Text is row Zero, \"0\" end mapping"]
  it "emits checked phrase-named functions through all seventeen backends" $ case core
    "function \"|negates the value| (value :: Bool) -> Bool is not value end function" of
    Left ds -> expectationFailure (show ds)
    Right program -> case planTestingWith V.noVerification program of
      Left ds -> expectationFailure (show ds)
      Right plan -> do
        length targets `shouldBe` 17
        mapM_ (\target -> emitPlan target plan `shouldSatisfy` isRight) targets
  it "refuses collisions in public native names" $ case core (unlines
    ["function addsValue (value :: Integer) -> Integer is value end function"
    ,"function \"|adds value| (value :: Integer) -> Integer is value end function"]) of
    Left ds -> expectationFailure (show ds)
    Right program -> case planTestingWith V.noVerification program of
      Left ds -> expectationFailure (show ds)
      Right plan -> emitPlan "python" plan `shouldSatisfy` isLeft
  it "resolves explicit public-name overrides by identity through all seventeen emitters" $ case core (unlines
    ["function flipValue (value :: Bool) -> Bool is value end function"
    ,"function \"|flip value| (value :: Bool) -> Bool is not value end function"
    ,"law agrees is definition: for all (value :: Bool) => \"|flip value| value = (not (flipValue value)) end end end"]) of
    Left ds -> expectationFailure (show ds)
    Right program -> do
      let override name = NB.emptyNativeRequest { NB.requestNames =
            [NB.NameBinding (C.Id "example.canonical::\"|flip value|") name] }
      case (NB.resolveNativeRequest program (override "toggleValue"), planTestingWith (V.Verification [V.Exhaustive]) program) of
        (Right bindings, Right plan) -> do
          NB.hasBindings bindings `shouldBe` False
          mapM_ (\target -> do
            emitPlan target plan `shouldSatisfy` isLeft
            emitPlanWithNativeOptions False target Nothing Nothing bindings plan `shouldSatisfy` isRight) targets
          case NB.resolveNativeRequest program (override "flipValue") of
            Left message -> expectationFailure message
            Right collision -> emitPlanWithNativeOptions False "python" Nothing Nothing collision plan `shouldSatisfy` isLeft
        result -> expectationFailure (show result)
      mapM_ (\name -> NB.resolveNativeRequest program (override name) `shouldSatisfy` isLeft)
        ["", "bad.name", "x()", "Uppercase"]
      NB.resolveNativeRequest program (NB.emptyNativeRequest { NB.requestNames =
        [NB.NameBinding (C.Id "unknown::value") "value"] }) `shouldSatisfy` isLeft
      NB.resolveNativeRequest program (NB.emptyNativeRequest { NB.requestNames =
        [NB.NameBinding (C.Id "example.canonical::flipValue") "firstValue",
         NB.NameBinding (C.Id "example.canonical::flipValue") "secondValue"] }) `shouldSatisfy` isLeft
  it "rejects native public-name overrides through the legacy API schema" $ do
    let request = object ["schemaVersion" .= (4 :: Int), "method" .= ("check" :: String),
          "sources" .= [Source "legacy.lawspec" "unit legacy\ndefinition value (x :: Bool) :: Bool is x end"],
          "nativeBindings" .= object ["names" .= [object ["declaration" .= ("legacy::value" :: String), "name" .= ("echo" :: String)]]]]
        response = either error id (eitherDecode (dispatch (encode request))) :: Value
    case response of
      Object fields -> Data.Aeson.KeyMap.lookup "diagnostics" fields `shouldSatisfy` (\x -> maybe False (/= toJSON ([] :: [Value])) x)
      _ -> expectationFailure "expected a request diagnostic"
  it "preserves lexical source text, literal spelling and comments during formatting" $ do
    let raw = "-- Keep this comment.  \nunit example.canonical\nfunction same (x of type Integer) -> Integer is\n       x -- Keep this too.\nend function\nlaw \"|same value| is\ndefinition:\nfor all (x :: Integer) =>\nx must be x\nend\nend\nend\n"
        original = Source "format.lawspec" raw
        formatted = formatSource original
        significant s = [(tokenKind t,tokenText t) | t <- sourceTokens s, tokenKind t /= TriviaToken]
    restoreSource (sourceTokens raw) `shouldBe` raw
    formatSource formatted `shouldBe` formatted
    significant (LawSpec.Model.content formatted) `shouldBe` significant raw
    parseSourceCanonical formatted `shouldSatisfy` isRight
  it "formats mappings and nested cases with stable two-space indentation" $ do
    let input = source (unlines
          ["mapping flag of type Bool -> Text is"
          ,"row true, \"yes\""
          ,"row false, \"no\""
          ,"end mapping"
          ,"function nested (x :: Integer) -> Integer is"
          ,"first matching case of x:"
          ,"when it > 0 then"
          ,"first matching case of x:"
          ,"when it > 1 then 2"
          ,"otherwise 1"
          ,"end case"
          ,"otherwise 0"
          ,"end case"
          ,"end function"])
        formatted = formatSource input
    lines (LawSpec.Model.content formatted) `shouldBe`
      ["unit example.canonical","mapping flag of type Bool -> Text is"
      ,"  row true, \"yes\"","  row false, \"no\"","end mapping"
      ,"function nested (x :: Integer) -> Integer is","  first matching case of x:"
      ,"    when it > 0 then","      first matching case of x:"
      ,"        when it > 1 then 2","        otherwise 1","      end case"
      ,"    otherwise 0","  end case","end function"]
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 defaultGeneration [formatted] `shouldSatisfy` isRight
  it "wraps long record expressions without changing tokens or literal values" $ do
    body <- readFile "examples/rc1/nesting/uuu.lawspec"
    let original = Source "uuu.lawspec" body
        formatted = formatSource original
        significant text = [(tokenKind t,tokenText t) | t <- sourceTokens text, tokenKind t /= TriviaToken]
    significant (LawSpec.Model.content formatted) `shouldBe` significant body
    maximum (map length (lines (LawSpec.Model.content formatted))) `shouldSatisfy` (<= 80)
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 defaultGeneration [formatted] `shouldSatisfy` isRight
  it "uses UTF-16 editor positions for supplementary characters and tab columns" $ do
    let source = Source "positions.lawspec" "a😀b\n\t😀x\n"
    utf16Position source (LawSpec.Model.Location "positions.lawspec" 1 3) `shouldBe` (0,3)
    utf16Position source (LawSpec.Model.Location "positions.lawspec" 2 10) `shouldBe` (1,3)
  it "accepts schema 5 only with the explicit RC1 profile and reports no selected checks" $ do
    let request fields = encode (object (["schemaVersion" .= (5 :: Int), "method" .= ("check" :: String),
          "sources" .= [source "law identity is definition: for all (x :: Bool) => x = x end end end"]] ++ fields))
        result fields = eitherDecode (dispatch (request fields)) :: Either String Value
        field key (Right (Object o)) = fromJSON (maybe Null id (Data.Aeson.KeyMap.lookup key o))
        field _ _ = Error "no result"
    field "diagnostics" (result ["languageProfile" .= ("1.0-rc.1" :: String)]) `shouldBe` (Success ([] :: [Value]))
    field "diagnostics" (result []) `shouldSatisfy` (/= Success ([] :: [Value]))
  it "changes emitted test plans when a warm compiler switches law layers" $ do
    let request body layers = object
          [ "schemaVersion" .= (5 :: Int),"languageProfile" .= ("1.0-rc.1" :: String)
          , "method" .= ("planGeneration" :: String),"target" .= ("javascript" :: String)
          , "verification" .= V.Verification layers
          , "sources" .= [Source "layered.lawspec" ("unit layered\nlaw identity is definition: " ++ body ++ " end end")] ]
        emitted body layers = eitherDecode (dispatch (encode (request body layers))) >>= parseEither
          (withObject "result" (\o -> do
            diagnostics <- o .: "diagnostics" :: Parser [Value]
            if null diagnostics then do
              files <- o .: "files" :: Parser [Value]
              concat <$> mapM (withObject "file" (\file -> file .: "content" :: Parser String)) files
              else fail (show diagnostics)))
        body = "for all (value :: Bool) => value = value end"
    case emitted body [V.Exhaustive] of
      Left problem -> expectationFailure problem
      Right files -> files `shouldNotContain` "fc.property("
    case emitted body [V.Property] of
      Left problem -> expectationFailure problem
      Right files -> files `shouldContain` "fc.property("
    case emitted body [V.Exhaustive] of
      Left problem -> expectationFailure problem
      Right files -> files `shouldNotContain` "fc.property("
    case emitted "true" [V.Property] of
      Left problem -> expectationFailure problem
      Right files -> files `shouldNotContain` "fc.property("
  it "matches the official BLAKE3 vectors across block, chunk and tree boundaries" $ do
    vectors <- BL.readFile "test/fixtures/blake3-256.json"
    let parseVectors :: Value -> Parser [(Int,String)]
        parseVectors = withObject "vectors" (\o -> o .: "cases" >>= mapM (withObject "case" (\c -> (,) <$> c .: "input_len" <*> c .: "hash")))
    case eitherDecode vectors >>= parseEither parseVectors of
      Left problem -> expectationFailure problem
      Right cases -> mapM_ (\(n,hash) -> blake3Hex (B.pack (take n (cycle [0..250]))) `shouldBe` hash) cases
