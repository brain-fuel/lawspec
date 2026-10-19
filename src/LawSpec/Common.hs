-- | Shared protocol infrastructure: no syntax, inference or backend dependencies.
module LawSpec.Common where
import Data.Aeson
import GHC.Generics (Generic)
import Data.Char (toUpper)
import LawSpec.TargetNames (phraseNativeName)

-- | One set of generation limits for every target, mapped onto each framework's
-- own settings, so a law is tried as hard on one target as on another.
-- ref:DEC-native-property-frameworks
data Generation = Generation { cases :: Int, maxAttempts :: Int, maxShrinks :: Int, exhaustiveLimit :: Int } deriving (Eq, Show, Generic)
-- | A hundred cases is the common default of the property frameworks LawSpec
-- targets; the exhaustive limit lets small domains be checked completely.
-- ref:quickcheck
defaultGeneration :: Generation
defaultGeneration = Generation 100 10000 1000 4096
-- Logical binders are separate from existentially packaged data types.
data Quantification = ForEvery | ForSome deriving (Eq, Show, Generic)
instance ToJSON Quantification
-- Canonical universal obligations include empty domains. Legacy test inputs
-- retain their explicit nonempty-population requirement.
data InputDomain = NonemptyDomain | UniversalDomain deriving (Eq, Show, Generic)
instance ToJSON InputDomain where
  toJSON NonemptyDomain = String "nonempty"
  toJSON UniversalDomain = String "universal"
-- Documentary scalars have no effect on a law's proposition or ownership
-- namespace. Their names are contextual within a law's metadata prefix.
data LawMetadata = LawMetadata
  { metadataIdentifier :: Maybe String, metadataOwner :: Maybe String
  } deriving (Eq, Show, Generic)
emptyLawMetadata :: LawMetadata
emptyLawMetadata = LawMetadata Nothing Nothing
instance ToJSON LawMetadata where
  toJSON metadata = object
    (["id" .= value | Just value <- [metadataIdentifier metadata]] ++
     ["owner" .= value | Just value <- [metadataOwner metadata]])
-- Documentary links retain identity and origin, never a copy of the linked
-- proposition. This permits cycles without introducing proof dependencies.
data ReferenceSelector = ReferenceDefinition | ReferenceDescription
  | ReferenceRationale | ReferenceReferences | ReferenceNamed String
  deriving (Eq, Show, Generic)
data DocumentaryTarget = DocumentaryTarget
  { documentaryId :: String, documentaryUnit :: String, documentaryName :: String
  , documentarySpan :: Span, documentaryReferenceSpan :: Span } deriving (Eq, Show, Generic)
data DocumentaryReference target = LawReference target (Maybe ReferenceSelector)
  | FunctionReference target | ExternalReference (Maybe String) String
  deriving (Eq, Show, Generic)
traverseReference :: Applicative f => (a -> f b) -> DocumentaryReference a -> f (DocumentaryReference b)
traverseReference f (LawReference target selector) = (`LawReference` selector) <$> f target
traverseReference f (FunctionReference target) = FunctionReference <$> f target
traverseReference _ (ExternalReference name resource) = pure (ExternalReference name resource)
referenceSelectorText :: ReferenceSelector -> String
referenceSelectorText ReferenceDefinition = "definition"
referenceSelectorText ReferenceDescription = "description"
referenceSelectorText ReferenceRationale = "rationale"
referenceSelectorText ReferenceReferences = "references"
referenceSelectorText (ReferenceNamed name) = "references." ++ name
renderReference :: (target -> String) -> DocumentaryReference target -> String
renderReference name reference = case reference of
  LawReference target selector -> "ref law " ++ name target ++ maybe "" ((" " ++) . referenceSelectorText) selector
  FunctionReference target -> "ref function " ++ name target
  ExternalReference Nothing resource -> resource
  ExternalReference (Just label) resource -> label ++ ": " ++ resource
instance ToJSON ReferenceSelector where
  toJSON (ReferenceNamed name) = object ["kind" .= ("named-reference" :: String), "name" .= name]
  toJSON selector = object ["kind" .= referenceSelectorText selector]
instance ToJSON DocumentaryTarget where
  toJSON target = object ["id" .= documentaryId target, "unit" .= documentaryUnit target,
    "name" .= documentaryName target, "span" .= documentarySpan target,
    "referenceSpan" .= documentaryReferenceSpan target]
instance ToJSON target => ToJSON (DocumentaryReference target) where
  toJSON (LawReference target selector) = object
    (["kind" .= ("law" :: String), "target" .= target] ++ ["selector" .= s | Just s <- [selector]])
  toJSON (FunctionReference target) = object ["kind" .= ("function" :: String), "target" .= target]
  toJSON (ExternalReference name resource) = object
    (["kind" .= ("external" :: String), "resource" .= resource] ++ ["name" .= n | Just n <- [name]])
instance ToJSON Generation
instance FromJSON Generation where
  parseJSON = withObject "generation" $ \o -> Generation <$> o .:? "cases" .!= 100 <*> o .:? "maxAttempts" .!= 10000 <*> o .:? "maxShrinks" .!= 1000 <*> o .:? "exhaustiveLimit" .!= 4096
-- | Diagnostics point at a file, line and column, which every editor can follow.
data Location = Location { file :: String, line :: Int, column :: Int } deriving (Eq, Show, Generic)
-- | Every failure carries a stable code as well as a message, so tools and tests
-- can match a kind of error without parsing its wording.
data Diagnostic
  = Diagnostic { code :: String, message :: String, at :: Maybe Location }
  | BlockDiagnostic { code :: String, message :: String, at :: Maybe Location
                    , diagnosticSpan :: Span, diagnosticOpener :: Maybe Span }
  deriving (Eq, Show, Generic)
-- | The compiler reads no files itself: hosts pass sources in, so the WASM build
-- and the native build behave alike. ref:DEC-wasm-distribution
data Source = Source { path :: String, content :: String } deriving (Eq, Show, Generic)
-- | Each output says who owns it: generated files are rewritten freely, adapter
-- files belong to the user and are never overwritten. ref:DEC-adapter-ownership
data Artifact
  = Artifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String }
  | AdapterArtifact { artifactPath :: String, artifactContent :: String, ownership :: String, artifactPlacement :: String, canonicalAdapter :: String }
  deriving (Eq, Show, Generic)

-- | Canonical generated scaffold, never the user's implementation. A layout-only
-- change must not be reported as a changed adapter requirement.
adapterReference :: Artifact -> Maybe String
adapterReference AdapterArtifact{canonicalAdapter=reference} = Just reference
adapterReference _ = Nothing

-- | A rewrite of generated text, such as escaping names, must reach the
-- canonical adapter too, or regeneration would see a difference that is not
-- there.
mapArtifactContent :: (String -> String) -> Artifact -> Artifact
mapArtifactContent f artifact = case artifact of
  AdapterArtifact{} -> artifact { artifactContent = f (artifactContent artifact), canonicalAdapter = f (canonicalAdapter artifact) }
  Artifact{} -> artifact { artifactContent = f (artifactContent artifact) }
instance ToJSON Location
instance ToJSON Diagnostic where
  toJSON diagnostic = object
    (["code" .= code diagnostic, "message" .= message diagnostic, "at" .= at diagnostic] ++
     case diagnostic of
       Diagnostic{} -> []
       BlockDiagnostic{diagnosticSpan=range,diagnosticOpener=opener} ->
         ["span" .= object ["start" .= spanStart range,"end" .= spanEnd range]] ++
         ["related" .= [object ["message" .= ("Block opened here." :: String),
           "span" .= object ["start" .= spanStart origin,"end" .= spanEnd origin]]]
           | Just origin <- [opener]])
instance ToJSON Artifact where
  toJSON artifact = object
    (["path" .= artifactPath artifact, "content" .= artifactContent artifact,
      "ownership" .= ownership artifact, "placement" .= artifactPlacement artifact] ++
     maybe [] (\reference -> ["adapterReference" .= reference]) (adapterReference artifact))
instance FromJSON Source
instance ToJSON Source

-- | Core keeps the span of each expression, so a failing law points at the
-- exact text.
data Span = Span { spanStart :: Location, spanEnd :: Location } deriving (Eq, Show, Generic)
instance ToJSON Span
-- | Where only a position is known, it is a span of no width.
pointSpan :: Location -> Span
pointSpan p = Span p p

-- | An imported definition's name in the importing unit, e.g. shop.money's add
-- is shopMoneyAdd. Checked definitions are emitted as target code, so the name
-- must be an identifier in every target. Later stages recognise an imported
-- definition, such as a family's index measure, by this name too.
importedDefinitionName :: String -> String -> String
importedDefinitionName unit name = case pieces unit of
  first : rest -> first ++ concatMap capital rest ++ capital (phraseNativeName name)
  [] -> name
  where
    pieces s = case break (== '.') s of
      (a, _ : rest) -> a : pieces rest
      (a, []) -> [a]
    capital (c : cs) = toUpper c : cs
    capital [] = []

-- | A unit's Python module file, below a source root: a.b is a/b.py, or
-- a/b/__init__.py when another unit is inside it (a.b.c), so a unit may
-- share its name with its package's other units.
pythonUnitFile :: [String] -> String -> String
pythonUnitFile units unit =
  let path = map (\c -> if c == '.' then '/' else c) unit
  in if any (\other -> (unit ++ ".") == take (length unit + 1) other) units then path ++ "/__init__.py" else path ++ ".py"
