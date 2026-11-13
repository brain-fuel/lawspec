-- | Guards of a law's claim: generation hints, finite covers from membership,
-- authoring advice and the vacuous status. ref:DEC-vacuous-outcome
module VacuitySpec (test_guardsDirectGenerationAndAreReported) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Authoring (adviceView)
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..), statusName, statuses)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Core.Vacuity
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing

spec :: String
spec = unlines
  [ "unit example.guards"
  , "type Offer is a record{  code :: Text amount :: Int32} end type"
  , "type Kind is one of | Short | Long end type"
  , "type Stage is a record{  token :: Text meaning :: Text} end type"
  , "mapping stagesOf of type Kind -> List Stage is"
  , "  row Short, [Stage record{token = \"A\", meaning = \"Act\"}]"
  , "  row Long, [Stage record{token = \"P\", meaning = \"Plan\"}, Stage record{token = \"D\", meaning = \"Do\"}]"
  , "end mapping"
  , "shout :: (name :: Text) -> Text"
  , "accepts :: (offer :: Offer) -> Bool"
  , "describe :: (offer :: Offer) -> Text"
  , "law \"|guarded name| is"
  , "  definition : for all (name :: Text) => name matches regex \"[A-Za-z]{2,40}\" implies prelude.length (shout name) = prelude.length name end for all end definition"
  , "end law"
  , "law \"|refined name| is"
  , "  definition : for all (name :: Text where name matches regex \"[A-Za-z]{2,40}\") => prelude.length (shout name) = prelude.length name end for all end definition"
  , "end law"
  , "law \"|accepted offer| is"
  , "  definition : for all (offer :: Offer) => accepts offer implies describe offer = offer.code end for all end definition"
  , "end law"
  , "law \"|listed key| is"
  , "  definition : for all (key :: Text where key in [\"a\", \"b\", \"c\"]) => shout key = shout key end for all end definition"
  , "end law"
  , "law \"|guarded key| is"
  , "  definition : for all (key :: Text) => key in [\"north\", \"south\"] implies shout key = shout key end for all end definition"
  , "end law"
  , "law \"|two guards| is"
  , "  definition : for all (n :: Int32) (m :: Int32) => n > 5 implies m < n implies shout \"a\" = \"a\" end for all end definition"
  , "end law"
  , "law \"|every stage has a meaning| is"
  , "  definition : for all (kind :: Kind) (stage :: Stage where stage in stagesOf kind) => prelude.length stage.meaning > 0 end for all end definition"
  , "end law"
  , "end unit" ]

compiled :: Either [Diagnostic] C.Program
compiled = compileCore 64 defaultGeneration [Source "guards.lawspec" spec]

law :: String -> C.Program -> C.Property
law name program = case [p | u <- C.programUnits program, p <- C.unitProperties u, name `isInfixOf` C.propertyName p] of
  p : _ -> p
  [] -> error ("no law " ++ name)

planned :: String -> Plan -> PlannedProperty
planned name plan = case [p | u <- plannedUnits plan, p <- plannedProperties u, name `isInfixOf` C.propertyName (plannedProperty p)] of
  p : _ -> p
  [] -> error ("no planned law " ++ name)

texts :: [C.Expr] -> [String]
texts hints = [map toEnum codes | C.Expr _ (C.Constant (SSequence "Text" codes)) _ <- hints]

findings :: Value -> [(String, String, String)]
findings (Object view) =
  [ (rule, declaration, suggestion)
  | Just (Array rows) <- [KM.lookup "findings" view], Object row <- toList rows
  , Just (String rule') <- [KM.lookup "rule" row], Just (String declaration') <- [KM.lookup "declaration" row]
  , Just (String suggestion') <- [KM.lookup "suggestion" row]
  , let rule = show rule'; declaration = show declaration'; suggestion = show suggestion' ]
findings _ = []

test_guardsDirectGenerationAndAreReported :: Spec
test_guardsDirectGenerationAndAreReported = describe "guards of a law's claim" $ do
  it "finds each guard outermost first, and none under an unguarded claim" $
    case compiled of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        guardCount (law "guarded name" program) `shouldBe` 1
        guardCount (law "refined name" program) `shouldBe` 0
        guardCount (law "two guards" program) `shouldBe` 2
  it "gives a regex guard on a quantified input the hints of the refined quantifier" $
    case compiled >>= planTesting of
      Left ds -> expectationFailure (show ds)
      Right plan -> do
        let hints name = concatMap generatorHints (generatorRequirements (planned name plan))
        texts (hints "guarded name") `shouldNotBe` []
        texts (hints "guarded name") `shouldBe` texts (hints "refined name")
        -- The guard is not a refinement: the domain stays every Text.
        concatMap generatorPredicates (generatorRequirements (planned "guarded name" plan)) `shouldBe` []
  it "seeds a literal list from a refinement or a guard, but not a comparison guard" $
    case compiled >>= planTesting of
      Left ds -> expectationFailure (show ds)
      Right plan -> do
        let hints name = concatMap generatorHints (generatorRequirements (planned name plan))
        texts (hints "listed key") `shouldBe` ["a", "b", "c"]
        texts (hints "guarded key") `shouldBe` ["north", "south"]
        hints "two guards" `shouldBe` []
  it "reads membership in a list as the finite cover of the input" $
    case compiled >>= planTesting of
      Left ds -> expectationFailure (show ds)
      Right plan -> do
        fmap length (finiteCases (planned "listed key" plan)) `shouldBe` Just 3
        -- One stage for Short, two for Long.
        fmap length (finiteCases (planned "every stage has a meaning" plan)) `shouldBe` Just 3
        -- A guard never narrows the domain.
        finiteCases (planned "guarded key" plan) `shouldBe` Nothing
  it "checks a law over membership in a mapping's row exhaustively" $
    case compiled >>= dischargeEvidence of
      Left ds -> expectationFailure (show ds)
      Right obligations ->
        [ obligationStatus o | o <- obligations
        , "every stage has a meaning" `isInfixOf` C.idText (obligationDeclaration o), obligationStage o == "law" ]
          `shouldBe` [ExhaustivelyChecked]
  it "advises the refined quantifier for regex and list guards" $
    case compiled of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let found = findings (adviceView [] program)
            suggestions rule name = [s | (r, d, s) <- found, rule `isInfixOf` r, name `isInfixOf` d]
        suggestions "vacuous-guard" "guarded name" `shouldSatisfy`
          any ("(name :: Text where name matches regex \\\"[A-Za-z]{2,40}\\\")" `isInfixOf`)
        suggestions "vacuous-guard" "guarded key" `shouldSatisfy`
          any ("(key :: Text where key in [\\\"north\\\", \\\"south\\\"])" `isInfixOf`)
        suggestions "vacuous-guard" "refined name" `shouldBe` []
        suggestions "vacuous-guard" "accepted offer" `shouldBe` []
  it "advises a harness strategy for a guard that calls an adapter" $
    case compiled of
      Left ds -> expectationFailure (show ds)
      Right program -> do
        let advice name = programGuardAdvice program (law name program)
        map adviceRule (advice "accepted offer") `shouldBe` ["adapter-guard"]
        map adviceInput (advice "accepted offer") `shouldBe` ["offer"]
        advice "accepted offer" `shouldSatisfy` all (("use accepted for offer" `isInfixOf`) . adviceSuggestion)
        advice "guarded name" `shouldSatisfy` all ((== "vacuous-guard") . adviceRule)
        advice "listed key" `shouldBe` []
  it "names vacuous among the statuses, after flaky" $ do
    statusName Vacuous `shouldBe` "vacuous"
    takeWhile (/= Skipped) (dropWhile (/= Flaky) statuses) `shouldBe` [Flaky, Vacuous]
  it "counts reach on the targets that say so" $
    reachTargets `shouldBe` ["java", "javascript", "python", "scala", "typescript"]
