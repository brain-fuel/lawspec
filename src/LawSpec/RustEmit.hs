-- | Rust consumes an execution plan made entirely from typed core.
module LawSpec.RustEmit (emitRust, emitRustWithFormat, emitRustWithBindings, rustType, emitRustSchema) where
import LawSpec.Core
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Core.Machine (machineActor)
import LawSpec.TestNames (unitTestNames, lawWords)
import qualified LawSpec.RustExpr as Expression
import qualified LawSpec.RustDefinitions as Definitions
import qualified LawSpec.AbilityEmit.Rust as Abilities
import qualified LawSpec.RustAbilityPaths as Paths
import LawSpec.AbilityNames (ownAbilities, interfaceName, specName, productionName, ownerName)
import Data.Maybe (listToMaybe)
import LawSpec.Remote (remoteManifest)
import qualified LawSpec.ModelTests as ModelTests
import qualified LawSpec.Core.Schema as Schema
import qualified LawSpec.Backend as Presentation
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.NativeBinding as NB
import qualified LawSpec.NativeRequest as NR
import qualified LawSpec.RustNativeGenerators as NG
import qualified LawSpec.RustNativeBinding as RB
import qualified LawSpec.Core.Value as V
import LawSpec.Scalar
import qualified LawSpec.RustData as NativeData
import LawSpec.RuntimeSources
import qualified LawSpec.Code.Doc as Doc
import Data.Char (isAlphaNum, isAscii, isUpper, toLower)
import Data.List (intercalate, find, nub, sortOn, stripPrefix, tails)
import Data.Maybe (mapMaybe)
import LawSpec.Naming (NameKind(..), nativeIdentifier, claimAll, scopeWith, exampleTestSuffix, boundaryTestSuffix, displayLabel, escapeKeyword)
import LawSpec.SourceLink (sourceLink, locationLink, exampleLocation, labelled, generatedHeader, unitSourceFile)
import LawSpec.RustExpr (mentions, unusedAs)
import qualified LawSpec.RustLayout as RL
import Control.Monad (forM, unless)
import LawSpec.Search (lawDescriptors, searchable)
import LawSpec.Bounds (inputRange)

q :: String -> String
q = Expression.quoted
comma :: [String] -> String
comma = intercalate ", "
ident :: String -> String
ident = map (\c -> if isAlphaNum c || c == '_' then c else '_')
-- | LawSpec's containers map onto Rust's own, Vec and Option, so adapters take
-- the types a Rust developer expects. ref:DEC-idiomatic-generated-types
rustType :: Type -> Either String String
rustType (Constructor "List" [TypeArgument a]) = (\t -> "Vec<" ++ t ++ ">") <$> rustType a
rustType (Constructor "Maybe" [TypeArgument a]) = (\t -> "Option<" ++ t ++ ">") <$> rustType a
rustType (Constructor "Either" [TypeArgument a, TypeArgument b]) = do
  left <- rustType a
  right <- rustType b
  pure ("ls::Either<" ++ left ++ ", " ++ right ++ ">")
rustType (Constructor n []) = maybe (Left ("no Rust representation for " ++ n)) Right (nativeRepresentation "rust" n)
rustType (Constructor n [TypeArgument a]) | n `elem` ["Nullable","Optional"] = (\t -> "ls::" ++ n ++ "<" ++ t ++ ">") <$> rustType a
rustType t = Left ("no Rust representation for " ++ show t)
rustArgumentType :: Type -> Either String String
rustArgumentType (Constructor "Integer" []) = Right "ls::BigInt"
rustArgumentType (Constructor "List" [TypeArgument a]) = (\t -> "Vec<" ++ t ++ ">") <$> rustArgumentType a
rustArgumentType (Constructor "Maybe" [TypeArgument a]) = (\t -> "Option<" ++ t ++ ">") <$> rustArgumentType a
rustArgumentType (Constructor "Either" [TypeArgument a,TypeArgument b]) = do
  left <- rustArgumentType a
  right <- rustArgumentType b
  pure ("ls::Either<" ++ left ++ ", " ++ right ++ ">")
rustArgumentType (Constructor n [TypeArgument a]) | n `elem` ["Nullable","Optional"] = (\t -> "ls::" ++ n ++ "<" ++ t ++ ">") <$> rustArgumentType a
rustArgumentType t = rustType t
machineType :: Type -> Bool
machineType (Constructor n args) = n `elem` ["IntSize","UIntSize","UIntPtr"] || any (\a -> case a of TypeArgument t -> machineType t; _ -> False) args
machineType (Arrow a b) = machineType a || machineType b
machineType _ = False
typeName :: Type -> String
typeName (Constructor n args) = unwords (n:[typeName t | TypeArgument t <- args])
typeName t = show t

-- | Preserve type applications structurally; runtime schema validation never has
-- to parse a target-specific spelling or infer generic field types.
schemaVector :: [Doc.Doc] -> Doc.Doc
schemaVector [value] = Doc.text "vec![" <> value <> Doc.text "]"
schemaVector values = rustDelimited "vec![" "]" values

-- | Rustfmt's default argument/array width is 60, inside the 100-column page.
rustDelimited :: String -> String -> [Doc.Doc] -> Doc.Doc
rustDelimited opening closing values
  | length (comma (map (Doc.render Doc.Compact) values)) > 60 =
      Doc.text opening <> Doc.nest 4 (Doc.hardline <>
        Doc.joinWith Doc.hardline [value <> Doc.text "," | value <- values]) <>
      Doc.hardline <> Doc.text closing
  | otherwise = Doc.delimitTrailing 4 opening closing values

typeReference :: Schema.TypeRef -> Doc.Doc
typeReference = renderTypeReference False

typeReferences :: [Schema.TypeRef] -> Doc.Doc
typeReferences [value] = Doc.text "vec![" <> renderTypeReference True value <> Doc.text "]"
typeReferences values = schemaVector (map typeReference values)

renderTypeReference :: Bool -> Schema.TypeRef -> Doc.Doc
renderTypeReference _ (Schema.Parameter index) =
  Doc.text ("ls::TypeRef::Parameter(" ++ show index ++ ")")
renderTypeReference singleElement (Schema.Named name arguments) =
  let values = [Doc.text (q name), typeReferences arguments]
      -- A type reference is also a single array element; rustfmt wraps the
      -- nested call when that element exceeds its array-width heuristic.
      longElement = singleElement && length (comma (map (Doc.render Doc.Compact) values)) + length ("ls::TypeRef::named()" :: String) > 60
  in Doc.text "ls::TypeRef::named" <> if longElement
    then Doc.text "(" <> Doc.nest 4 (Doc.hardline <>
      Doc.joinWith Doc.hardline [value <> Doc.text "," | value <- values]) <> Doc.hardline <> Doc.text ")"
    else rustDelimited "(" ")" values

-- | Constructor invariants are proved before the schema is emitted, so the
-- generated checks are the proved ones.
emitRustSchema :: Int -> Doc.Layout -> [DataDeclaration] -> Either String String
emitRustSchema bits layout declarations = do
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas,contracts) <- Schema.dataSchemasWithContracts declarations
  let entries = zip [0 :: Int ..] [(contract,predicate) | contract <- contracts,
        predicate <- Schema.contractPredicates contract]
      callbackName index = "field_predicate_" ++ show index
      metadata = [record "ls::ConstructorContract"
        [("tag",Doc.text (q (Schema.contractTag contract))),
         ("predicates",records [Doc.text (callbackName index) | (index,(owner,_)) <- entries,
            Schema.contractTag owner == Schema.contractTag contract])] | contract <- contracts]
      definitions = map definition schemas
  callbacks <- forM entries $ \(index,(contract,predicate)) -> do
    let reference ty = do
          ref <- typeReference <$> Schema.typeReference (Schema.contractParameters contract) ty
          pure (if variable ty then ref <> Doc.text ".instantiate(_types)?" else ref)
        key ty | variable ty = do
          ref <- typeReference <$> Schema.typeReference (Schema.contractParameters contract) ty
          pure (Doc.text "&" <> ref <> Doc.text ".instantiate(_types)?.expression_key()?")
               | otherwise = pure (Doc.text (q (Expression.typeName ty)))
        names = zip (map binderId (Schema.contractFields contract))
          ["_fields[" ++ show i ++ "]" | i <- [0 :: Int ..]]
    body <- Expression.renderExpressionWithContext declarations (Doc.text "bits") (Doc.text "_schema") reference key [] names predicate
    pure (Doc.text ("fn " ++ callbackName index) <> Doc.delimitTrailing 4 "(" ")"
      (map Doc.text ["_schema: &ls::Schema", "_types: &[ls::TypeRef]", "_fields: &[ls::Value]",
        "bits: u32", "ctx: &mut ls::Context"]) <> Doc.text " -> ls::Result<bool> " <>
      Doc.block 4 (Doc.hang 4 (Doc.text "let accepted =") body <> Doc.text ";" <>
        Doc.hardline <> Doc.text "accepted.boolean()"))
  let refined = [c | s <- schemas, c <- Schema.constructors s,
        not (null (Schema.constructorRefinements c)) || Schema.constructorExistentials c > 0]
      refinementTable = [RL.expr (RL.Macro "" "(" ")" [RL.atom (q (Schema.constructorTag c)),
        RL.vecOf [RL.Macro "" "(" ")" [RL.atom (show index), RL.Laid (typeReference pattern)] | (index, pattern) <- Schema.constructorRefinements c],
        RL.atom (show (Schema.constructorExistentials c))]) | c <- refined]
      base = if not (null refined)
        then Expression.call "ls::Schema::with_refinements" [records definitions, records metadata, records refinementTable]
        else if null contracts
        then Doc.text "ls::Schema::new(" <> records definitions <> Doc.text ")"
        else Expression.call "ls::Schema::with_contracts" [records definitions,records metadata]
      table entries = RL.prefix "&" (RL.vecOf [RL.Macro "" "(" ")" [RL.atom (q tag), RL.atom ("&[" ++ intercalate ", " values ++ "][..]")] | (tag, values) <- entries])
      indexTables = [(Schema.constructorTag c, map q (Schema.constructorIndex c)) | s <- schemas, c <- Schema.constructors s, not (null (Schema.constructorIndex c))]
      witnessTables = [(Schema.constructorTag c, map show (Schema.constructorWitnesses c)) | s <- schemas, c <- Schema.constructors s, not (null (Schema.constructorWitnesses c))]
      -- A handle type's values are handles, which the schema passes unopened.
      handleNames = [q (idText (dataId d)) | d <- declarations, dataHandle d]
      steps = [("with_indices", table indexTables) | not (null indexTables)] ++
              [("with_witnesses", table witnessTables) | not (null witnessTables)] ++
              [("with_handles", RL.prefix "&" (RL.Macro "" "[" "]" (map RL.atom handleNames))) | not (null handleNames)]
      factory = RL.expr (foldl (\acc (step, argument) -> RL.method acc "map" [RL.closure "|schema|" (RL.method (RL.atom "schema") step [argument])]) (RL.Laid base) steps)
  pure (Doc.render layout (Doc.text "// Generated by LawSpec. Do not edit." <>
    Doc.hardline <> Doc.text "use crate::lawspec_runtime as ls;" <> Doc.hardline <> Doc.hardline <>
    Doc.joinWith (Doc.hardline <> Doc.hardline) (callbacks ++
      [ Doc.text "/// The program's data schema, built once." <> Doc.hardline <>
        Doc.text "pub fn schema() -> ls::Result<&'static ls::Schema> " <> Doc.block 4 (Doc.joinWith Doc.hardline
          [ Doc.text "static SCHEMA: std::sync::OnceLock<ls::Result<ls::Schema>> = std::sync::OnceLock::new();"
          , Doc.text "SCHEMA" <> Doc.nest 4 (Doc.hardline <> Doc.joinWith Doc.hardline
              (map Doc.text [".get_or_init(build)", ".as_ref()", ".map_err(|error| error.clone())"])) ])
      , Doc.text "fn build() -> ls::Result<ls::Schema> " <> Doc.block 4 factory ]) <> Doc.hardline))
  where
    variable (TypeVariable _) = True
    variable (Constructor _ args) = any (\arg -> case arg of TypeArgument ty -> variable ty; _ -> False) args
    variable (Arrow a b) = variable a || variable b
    -- (a single record overflows the brackets)
    records [value] = Doc.text "vec![" <> value <> Doc.text "]"
    records values = RL.expr (RL.vecOf (map RL.Laid values))
    record name fields = Doc.text (name ++ " ") <> Doc.block 4
      (Doc.joinWith Doc.hardline [Doc.text (key ++ ": ") <> value <> Doc.text "," | (key,value) <- fields])
    definition declaration = record "ls::DataSchema"
      [("name",Doc.text (q (Schema.typeName declaration))),
       ("parameters",Doc.text (show (Schema.parameterCount declaration))),
       ("constructors",records (map constructor (Schema.constructors declaration)))]
    constructor value = record "ls::ConstructorSchema"
      [("tag",Doc.text (q (Schema.constructorTag value))),
       ("fields",typeReferences (map Schema.fieldType (Schema.fields value)))]

builtinConstructor :: Id -> Bool
builtinConstructor tag = idText tag `elem`
  ["List::Nil", "List::Cons", "Maybe::Absent", "Maybe::Present", "Either::Left", "Either::Right"]

-- | Readable output unless asked otherwise. ref:DEC-readable-output-default
emitRust :: Plan -> Either [Diagnostic] [Artifact]
emitRust = emitRustWithFormat False

-- | No native bindings unless the project declares some.
emitRustWithFormat :: Bool -> Plan -> Either [Diagnostic] [Artifact]
emitRustWithFormat minify = emitRustWithBindings minify NR.emptyBindingPlan

-- | Names are escaped against Rust's keywords before emission, so a law about
-- type or match still compiles as Rust. ref:DEC-idiomatic-generated-types
emitRustWithBindings :: Bool -> NR.BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitRustWithBindings minify bindings plan@Plan{..} = either (Left . pure . (\m -> Diagnostic "rust" m Nothing)) Right $ do
  let declarations = concatMap (unitDeclarations . plannedUnit) plannedUnits
      keywords = words "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen"
  unless (all (\d -> declarationName d `notElem` keywords && all (\c -> isAscii c && (isAlphaNum c || c == '_')) (declarationName d)) declarations) (Left "reserved or invalid Rust adapter identifier")
  unless (all (\u -> let n = ident (idText (unitId (plannedUnit u))) in n `notElem` keywords && all (\c -> isAscii c && (isAlphaNum c || c == '_')) n) plannedUnits) (Left "reserved or invalid Rust module identifier")
  unless (not (NR.hasBindings bindings) || NR.bindingRustCrate bindings /= Nothing)
    (Left "Rust native bindings require rustCrate for application-library test linkage")
  unless (null (NB.resolvedTypes (NR.bindingRepresentations bindings)) || not (null (NR.bindingFunctions bindings)) || not (null (NR.bindingCalls bindings)) || hasNativeGenerators)
    (Left "Rust native type bindings require function or generator bindings")
  nativeConversions <- RB.emitConversions planDataDeclarations bindings
  schema <- emitRustSchema planMachineBits (Doc.selectLayout minify (Doc.Pretty 100)) planDataDeclarations
  nativeData <- NativeData.emitRustData (Doc.selectLayout minify (Doc.Pretty 100)) planDataDeclarations
  definitions <- Definitions.emitRustDefinitions (Doc.selectLayout minify (Doc.Pretty 100)) planMachineBits planDataDeclarations (map plannedUnit plannedUnits)
  -- Each ability's trait, spec handlers, recording and operation bridges.
  abilitySource <- if hasAbilities then Abilities.emit minify planMachineBits planDataDeclarations (map plannedUnit plannedUnits) else pure ""
  units <- concat <$> mapM emitUnit plannedUnits
  unless (length units == length (nub (map (map toLower . artifactPath) units))) (Left "units map to the same Rust output path")
  let modules = [("lawspec_runtime", "lawspec_runtime.rs")] ++
        [("lawspec_native", "lawspec_native.rs") | hasNativeTypes] ++
        [("lawspec_definitions", "lawspec_definitions.rs") | hasDefinitions] ++
        [("lawspec_schema", "lawspec_schema.rs") | hasSchema] ++
        [("lawspec_data", "lawspec_data.rs") | not (null planDataDeclarations)] ++
        [("lawspec_sessions", "lawspec_sessions.rs") | hasSessions] ++
        [("lawspec_actors", "lawspec_actors.rs") | hasActors] ++
        [("lawspec_remote", "lawspec_remote.rs") | hasRemote] ++
        [("lawspec_mailboxes", "lawspec_mailboxes.rs") | hasMailboxes] ++
        [("lawspec_abilities", "lawspec_abilities.rs") | hasAbilities] ++
        [(ident (idText (unitId (plannedUnit u))),
          map (\c -> if c == '.' then '/' else c) (idText (unitId (plannedUnit u))) ++ ".rs") | u <- plannedUnits]
      moduleSource = Doc.render layout (Doc.text "// Generated by LawSpec. Do not edit." <> Doc.hardline <>
        statements [Doc.text ("#[path = " ++ q filename ++ "]") <> Doc.hardline <>
          Doc.text ("pub mod " ++ name ++ ";") | (name, filename) <- sortOn fst modules] <> Doc.hardline)
      files = units ++ [Artifact "src/lawspec_native.rs"
        (Doc.render layout (Doc.text "// Generated native conversions. Do not edit." <> Doc.hardline <>
         Doc.text "#![allow(unused_imports, non_snake_case)]" <> Doc.hardline <>
         Doc.text "use crate::lawspec_runtime as ls;" <> Doc.hardline <> nativeConversions <> Doc.hardline))
        "generated" "source" | hasNativeTypes] ++ [Artifact "src/lawspec_data.rs" nativeData "generated" "source" | not (null planDataDeclarations)] ++ [Artifact "src/lawspec_schema.rs" schema "generated" "source" | hasSchema] ++
        [Artifact "src/lawspec_definitions.rs" definitions "generated" "source" | hasDefinitions] ++
        [Artifact "src/lawspec_abilities.rs" abilitySource "generated" "source" | hasAbilities] ++
        [ Artifact "src/lawspec_runtime.rs" (runtimeSource "rust") "generated" "source"
        , Artifact "src/lawspec_modules.rs" moduleSource "generated" "source"
        , Artifact "tests/support/lawspec_strategies.rs" (runtimeSource "rust-strategies") "generated" "test"
        ] ++
        -- The harness plane's runtime, for programs with a harness.
        [Artifact "tests/support/lawspec_harness.rs" (runtimeSource "rust-harness") "generated" "test"
          | any ((/= Nothing) . unitHarnessSettings . LawSpec.Testing.plannedUnit) plannedUnits]
  unless (length files == length (nub (map (map toLower . artifactPath) files))) (Left "Rust runtime or module path collision")
  generatorStubs <- NG.emitGeneratorStubs planDataDeclarations bindings
  pure (files ++ generatorStubs)
  where
    hasNativeTypes = not (null (NB.resolvedTypes (NR.bindingRepresentations bindings)))
    -- An adapter's native binding: a static function, or a handle's method
    -- or constructor.
    nativeCall d = maybe (lookup d (NR.bindingCalls bindings)) (Just . NR.StaticCall)
      (lookup d (NR.bindingFunctions bindings))
    hasNativeGenerators = not (null (NB.resolvedGenerators (NR.bindingRepresentations bindings)))
    customInput ty = case ty of
      Constructor name _ -> any ((== Id name) . NB.resolvedGeneratorType)
        (NB.resolvedGenerators (NR.bindingRepresentations bindings))
      _ -> False
    definitionNames = Definitions.definitionNames (map plannedUnit plannedUnits)
    hasFieldContracts = hasConstructorContracts planDataDeclarations
    hasDefinitions = not (null definitionNames)
    -- Typed channel ends (LawSpec.Sessions), which adapters use.
    hasSessions = any (not . null . unitSessions . plannedUnit) plannedUnits
    -- Typed actors (LawSpec.Actors), which adapters use too.
    hasActors = any (any machineActor . unitMachines . plannedUnit) plannedUnits
    -- Definitions other nodes can evaluate (LawSpec.Remote).
    hasRemote = not (null (snd (remoteManifest plan)))
    hasMailboxes = any (not . null . unitMailboxes . plannedUnit) plannedUnits
    hasAbilities = any (not . null . unitAbilities . plannedUnit) plannedUnits
    -- Each bound production handler, wrapped in the generated trait: its
    -- operations' values cross with the native conversions. The binding
    -- names the native type, which is Default.
    boundWrappers unit = forM [(a, r) | a <- ownAbilities unit, Just r <- [lookup (Id (abilityKey (abilityInstance a))) (NR.bindingHandlers bindings)]] $ \(a, r) -> do
      native <- RB.rustReference r
      let name = interfaceName a ++ "Bound"
          function = map toLower (take 1 (interfaceName a)) ++ drop 1 (interfaceName a) ++ "_bound"
      methods <- forM (abilityOperations a) $ \(op, ty) -> do
        let (args, result) = functionType ty
        types <- mapM (NativeData.rustDataType planDataDeclarations) args
        resultType <- NativeData.rustDataType planDataDeclarations result
        converted <- sequence [RB.convertExpression planDataDeclarations bindings True t (Doc.text ("value" ++ show i)) | (i, t) <- zip [0 :: Int ..] args]
        back <- RB.convertExpression planDataDeclarations bindings False result (Doc.text "native_result")
        pure (Doc.text ("fn " ++ op ++ "(&self" ++ concat [", value" ++ show i ++ ": " ++ t | (i, t) <- zip [0 :: Int ..] types] ++ ") -> " ++ resultType ++ " ") <>
          block (statements [Doc.text "let native_result = self.inner." <> Doc.text op <> Doc.delimitTrailing 4 "(" ")" converted <> Doc.text ";", back]))
      pure (Doc.text ("/// The bound production handler of " ++ abilityName a ++ ", " ++ native ++ ", as the generated trait.") <> Doc.hardline <>
        Doc.text ("pub struct " ++ name ++ " ") <> block (Doc.text ("inner: " ++ native ++ ",")) <> Doc.hardline <> Doc.hardline <>
        RL.function ("pub fn " ++ function) [] name (RL.expr (RL.struct name [("inner", RL.call "Default::default" [])])) <> Doc.hardline <> Doc.hardline <>
        Doc.text ("impl crate::" ++ Abilities.traitPath allUnits (abilityInstance a) ++ " for " ++ name ++ " ") <>
        block (Doc.joinWith (Doc.hardline <> Doc.hardline) methods))
    allUnits = map plannedUnit plannedUnits
    -- A handler from the context, borrowed as its ability's trait.
    -- A handler from the context, typed by its binding.
    handlerValue ability = RL.expr (RL.try' (RL.method (RL.atom "ctx") "handler" [RL.atom (q (abilityKey ability))]))
    handlerType ability = "std::sync::Arc<dyn " ++ Abilities.traitPath allUnits ability ++ ">"
    -- A law's handlers, made afresh each time it runs and installed in its context.
    -- A handler of several abilities is made once and installed for each;
    -- a native handler made with a resource (ability A with T) is made once
    -- the case has acquired its T.
    handlerInstalls owner p =
      [RL.stmt (RL.Let (sharedName h) (RL.call "std::sync::Arc::new" [RL.call ("lawspec_abilities::" ++ Abilities.moduleOf owner ++ "::" ++ specName h ++ "::new") [RL.atom "ctx"]])) | h <- sharedOf owner p] ++
      installsWith owner (made owner p) [(a, c) | (a, c) <- propertyHandlers p, resourceFor p a c == Nothing]
    lateInstalls owner p = installsWith owner (made owner p) [(a, c) | (a, c) <- propertyHandlers p, resourceFor p a c /= Nothing]
    installsFor owner = installsWith owner (\_ _ _ -> Nothing)
    installsWith owner making handlers = case [(a, c) | (a, c) <- handlers, not (isFail a)] of
      [] -> []
      -- Made first, then installed: making a handler may read the context.
      chosen -> [RL.stmt (RL.Let "installing" (RL.vecOf
        [RL.Macro "" "(" ")" [RL.method (RL.atom (q (abilityKey a))) "to_string" [], Abilities.handlerConstructionWith (NR.bindingRustCrate bindings) allUnits owner (making a) a c] | (a, c) <- chosen])),
        Doc.text "ctx.install_handlers(installing);"]
    sharedName h = "shared_" ++ handlerName h
    sharedOf owner p = nub [h | (_, c) <- propertyHandlers p, Just h <- [specOf owner c], not (null (handlerAlso h))]
    specOf owner c = case c of
      SpecHandler h -> listToMaybe [x | x <- unitHandlers owner, handlerId x == h]
      RecordingHandler inner -> specOf owner inner
      ProductionHandler -> Nothing
    resourceFor p a c = case c of
      ProductionHandler -> do
        (_, ability) <- findAbility allUnits a
        t <- abilityResource ability
        listToMaybe [(t, "resource" ++ show i) | (i, r) <- zip [0 :: Int ..] (propertyResources p), binderType (resourceBinder r) == t]
      RecordingHandler inner -> resourceFor p a inner
      SpecHandler _ -> Nothing
    made owner p a trait c = case c of
      SpecHandler _ | Just h <- specOf owner c, h `elem` sharedOf owner p ->
        Just (RL.method (RL.atom (sharedName h)) "clone" [])
      ProductionHandler | Just (t, local) <- resourceFor p a c, Just (_, ability) <- findAbility allUnits a ->
        let native = either error id (NativeData.rustDataType planDataDeclarations t)
            reference = either error id (schemaType t)
            owned = if ownerName ability == idText (unitId owner) then "adapter" else Abilities.moduleOfName (ownerName ability)
            maker = case abilityNative ability of
              Just parts -> intercalate "::" parts
              Nothing -> owned ++ "::" ++ productionName ability ++ "::new"
            value = RL.try' (RL.method (RL.try' (RL.call "lawspec_schema::schema" [])) "native_value_with_context"
              [RL.method (RL.atom local) "clone" [], RL.prefix "&" (RL.Laid reference), RL.atom (show planMachineBits), RL.atom "ctx"])
        in Just (RL.call "std::sync::Arc::new" [RL.call maker [RL.try' (RL.call ("<" ++ native ++ " as ls::FromValue>::from_value") [value])]])
      _ -> Nothing
    hasSchema = hasNativeGenerators || not (null planDataDeclarations) || hasDefinitions ||
      any (any containsPayload . propertyExpressions . plannedProperty)
        (concatMap plannedProperties plannedUnits) ||
      any (any containsPayload . contractExpressions)
        (concatMap (unitContracts . plannedUnit) plannedUnits)
    containsPayload term = case expressionNode term of
      AllPayloads _ _ -> True
      _ -> any containsPayload (children term)
    usesData ty = case ty of
      Constructor name arguments -> any ((== Id name) . dataId) planDataDeclarations ||
        any (\argument -> case argument of TypeArgument t -> usesData t; _ -> False) arguments
      Arrow a b -> usesData a || usesData b
      _ -> False
    nativeMachineType = NB.usesMachineRepresentation planDataDeclarations
    nativeType ty = if usesData ty then NativeData.rustDataType planDataDeclarations ty else rustType ty
    argumentType ty = if usesData ty then NativeData.rustDataType planDataDeclarations ty else rustArgumentType ty
    schemaType = Expression.reference
    bits = Doc.text (show planMachineBits)
    layout = Doc.selectLayout minify (Doc.Pretty 100)
    emitUnit PlannedUnit{..} = do
      let unit = plannedUnit
          modulePath = map (\c -> if c == '.' then '/' else c) (idText (unitId unit))
          testName = ident (idText (unitId unit))
          declarations = unitDeclarations unit
          adapters = [d | d <- declarations, declarationId d `notElem` map fst definitionNames]
          declarationNames = [(identity,"lawspec_definitions::" ++ name) | (identity,name) <- definitionNames] ++
            zip (map declarationId adapters) wrapperNames ++
            Definitions.operationBridges allUnits
          -- Each adapter's checked call is named after its declaration.
          wrapperNames = fst (claimAll (scopeWith (Expression.reservedLocals ++ ["lawspec_runtime", "lawspec_harness", "native_generators"]))
            [nativeIdentifier "rust" FunctionName (declarationName d) | d <- adapters])
          render = Expression.renderExpression planDataDeclarations planMachineBits declarationNames
          renderL = Expression.renderExpressionL planDataDeclarations planMachineBits declarationNames
          -- The harness plane (LawSpec.Harness).
          runSettings h = harnessTimeout h /= Nothing || harnessRepeat h /= 1 || harnessRetries h /= 0 || observed h
          observed h = not (null (harnessCover h) && null (harnessClassify h) && null (harnessLabels h)) || harnessTarget h /= Nothing
          observationsDoc names p = do
            let h = propertyHarness p
                label = idText (unitId unit) ++ "::" ++ propertyName p
            covers <- mapM (\(Cover _ l w) -> (\t -> (l, t)) <$> renderL names w) (harnessCover h)
            classes <- mapM (\(c, l) -> (\t -> (l, t)) <$> renderL names c) (harnessClassify h)
            labels <- mapM (render names) (harnessLabels h)
            target' <- traverse (render names) (harnessTarget h)
            let pairs prefix xs = [RL.stmt (RL.Let (prefix ++ show k) (RL.try' (RL.method t "boolean" []))) | (k, (_, t)) <- zip [0::Int ..] xs]
                refs prefix xs = Doc.text "&[" <> Doc.joinWith (Doc.text ", ") [Doc.text "(" <> string l <> Doc.text (", " ++ prefix ++ show k ++ ")") | (k, (l, _)) <- zip [0::Int ..] xs] <> Doc.text "]"
            pure (pairs "cover_" covers ++ pairs "class_" classes ++
              [binding ("label_" ++ show k) t | (k, t) <- zip [0::Int ..] labels] ++
              [statement (invoke "lawspec_harness::observe" [string label, refs "cover_" covers, refs "class_" classes,
                Doc.text "&[" <> Doc.joinWith (Doc.text ", ") [Doc.text ("label_" ++ show k) | k <- [0 .. length labels - 1]] <> Doc.text "]"])] ++
              [statement (invoke "lawspec_harness::target" [Doc.text "&" <> parensDoc t, string label]) | Just t <- [target']])
          parensDoc d = Doc.text "(" <> d <> Doc.text ")"
          -- A harness strategy: a seed from proptest, and the strategy's
          -- draws from it; the value must satisfy the input's refinements.
          harnessStrategy prior input name strategy d = do
            drawDoc' <- drawExpr prior strategy d
            predicates <- mapM (render (prior ++ [(binderId (quantifiedBinder input), name)])) (quantifiedPredicates input)
            pure (block (statements
              ([Doc.text "let context = ctx.clone();",
                binding "prior" (Doc.text "vec![" <> Doc.joinWith (Doc.text ", ") [Doc.text (n ++ ".clone()") | (_, n) <- prior] <> Doc.text "]" <> Doc.text " as Vec<ls::Value>"),
                Doc.text "proptest::num::u64::ANY.prop_map(move |seed| lawspec_harness::drawn((|| -> ls::Result<ls::Value> " <> block (statements
                  ([Doc.text "let ctx = &mut context.clone();"] ++
                   [binding n (Doc.text ("prior[" ++ show j ++ "].clone()")) | (j, (_, n)) <- zip [0::Int ..] prior] ++
                   [Doc.text "let mut draws = lawspec_harness::Draws::new(seed);",
                    binding "value" drawDoc'] ++
                   [block (statements [binding name (Doc.text "value.clone()"),
                     conditional (Doc.text "!(" <> t <> Doc.text ").boolean()?")
                       (Doc.text "return Err(lawspec_harness::outside(" <> string strategy <> Doc.text ", " <> string (binderName (quantifiedBinder input)) <> Doc.text ", &value));")])
                   | t <- predicates] ++
                   [Doc.text "Ok(value)"])) <> Doc.text ")())).boxed()"])))
          drawExpr names strategy d = case d of
            -- A refined strategy's any draws inside its refinement's range.
            DrawAny ty (Just aim)
              | Just (low, high) <- inputRange planMachineBits aim -> do
                  let constant n = Expr ty (Constant (SInteger (typeName ty) n)) (GeneratedFrom (binderId (quantifiedBinder aim)))
                  lowDoc <- render names (constant low)
                  highDoc <- render names (constant high)
                  pure (invoke "draws.any" [Doc.text "&" <> invoke "ls_gen::bounded_integer" [string (typeName ty),
                    Expression.vector [Doc.text "(\">=\", " <> lowDoc <> Doc.text ")", Doc.text "(\"<=\", " <> highDoc <> Doc.text ")"], bits] <>
                    Doc.text "?.ok_or_else(|| " <> string ("the strategy " ++ strategy ++ " has an empty range") <> Doc.text ".to_string())?"])
            DrawAny ty _
              | usesData ty -> do
                  ref <- schemaType ty
                  pure (invoke "draws.any" [Doc.text "&" <> invoke "ls_gen::schema_strategy" [Doc.text "lawspec_schema::schema()?", borrow ref, bits, Doc.text "64"] <> Doc.text "?"])
              | otherwise -> pure (invoke "draws.any" [Doc.text "&" <> invoke "ls_gen::strategy_with_profile" [string (typeName ty), bits] <> Doc.text "?"])
            DrawOneOf _ values -> do
              docs <- mapM (render names) values
              pure (Doc.text ("match draws.choose(" ++ show (length values) ++ ") ") <> block (statements
                [Doc.text (if k == length docs - 1 then "_ => " else show k ++ " => ") <> v <> Doc.text "," | (k, v) <- zip [0..] docs]))
            DrawFrequency alternatives -> do
              docs <- mapM (drawExpr names strategy . snd) alternatives
              let bounds' = scanl1 (+) (map fst alternatives)
                  branches = [(b, doc) | (b, doc) <- zip bounds' docs]
                  chain' [(_, doc)] = Doc.text "{ " <> doc <> Doc.text " }"
                  chain' ((b, doc) : rest) = Doc.text ("if pick < " ++ show b ++ " { ") <> doc <> Doc.text " } else " <> chain' rest
                  chain' [] = Doc.text "unreachable!()"
              pure (block (statements [binding "pick" (Doc.text ("draws.choose(" ++ show (sum (map fst alternatives)) ++ ")")), chain' branches]))
            DrawSuchThat inner binder predicate limit -> do
              doc <- drawExpr names strategy inner
              let x = "drawn_" ++ unraw (Expression.sourceLocal names binder)
              keep <- render (names ++ [(binderId binder, x)]) predicate
              pure (block (statements
                [Doc.text "let mut found = None;",
                 Doc.text ("for _ in 0..=" ++ show limit ++ " ") <> block (statements
                   [binding x doc, conditional (Doc.text "(" <> keep <> Doc.text ").boolean()?")
                     (statements [Doc.text ("found = Some(" ++ x ++ ");"), Doc.text "break;"])]),
                 Doc.text ("found.ok_or_else(|| lawspec_harness::discarded(") <> string strategy <> Doc.text (", " ++ show limit ++ "))?")]))
            DrawBind binder from rest -> do
              let x = "drawn_" ++ unraw (Expression.sourceLocal names binder)
              fromDoc <- drawExpr names strategy from
              restDoc <- drawExpr (names ++ [(binderId binder, x)]) strategy rest
              pure (block (statements [binding x fromDoc, restDoc]))
          -- An expectation names its law, its example and where it is
          -- written; the runtime says how the values differ.
          proposition names label p = case p of
            Equation _ a b -> do
              x <- renderL names a
              y <- renderL names b
              let context = either id (\l -> labelled l (listToMaybe (mapMaybe (writtenLink . expressionOrigin) [a, b]))) label
              pure (statements
                [ RL.stmt (RL.Let "actual" x)
                , RL.stmt (RL.Let "expected" y)
                , statement (invoke "ls::expect_equal" [Doc.text "&actual", Doc.text "&expected", string context] <> Doc.text "?")])
            Implication g body -> do
              guard <- renderL names g
              inner <- proposition names label body
              pure (statements [RL.stmt (RL.Let "condition" guard),
                conditional (Doc.text "condition.boolean()?") inner])
            Conjunction ps -> statements <$> mapM (proposition names label) ps
            Quantified _ _ _ -> Left "a scoped proposition requires complete search planning before native emission"
            Negation _ -> Left "proposition negation requires execution planning before native emission"
          predicate names label p = do
            value <- renderL names p
            pure (block (statements [RL.stmt (RL.Let "condition" value),
              conditional (Doc.text "!condition.boolean()?")
                (statement (Doc.text "return " <> invoke "Err" [string label <> Doc.text ".into()"]))]))
      let mappedAdapters = [(d,call) | d <- adapters, Just call <- [nativeCall d]]
          generatedAdapter = not (null mappedAdapters)
      unless (not generatedAdapter || length mappedAdapters == length adapters)
        (Left ("native function bindings must cover every adapter in unit " ++ idText (unitId unit)))
      generatorModules <- NG.generatorImports bindings
      generatorSupport <- if hasNativeGenerators then NG.emitGenerators planDataDeclarations bindings
        [binderType (quantifiedBinder input) | unit <- plannedUnits, property <- LawSpec.Testing.plannedProperties unit, input <- propertyInputs (plannedProperty property)] else pure mempty
      stubs <- forM adapters $ \d -> do
        let (args,result) = functionType (declarationType d)
        argTypes <- mapM argumentType args
        resultType <- nativeType result
        let arguments = [Doc.text (handlerName ability ++ ": &dyn crate::" ++ Abilities.traitPath allUnits ability) | ability <- declarationUses d, not (isFail ability)] ++
              [Doc.text ("value" ++ show i ++ ": " ++ t) | (i,t) <- zip [0::Int ..] argTypes]
            handlerName ability = case [interfaceName a | Just (_, a) <- [findAbility allUnits ability]] of
              n : _ -> nativeIdentifier "rust" ValueName n
              [] -> "handler"
            signature = Doc.text ((if declarationAsync d then "pub async fn " else "pub fn ") ++ declarationName d)
              <> Doc.delimitTrailing 4 "(" ")" arguments
              <> Doc.text (" -> " ++ resultType ++ " ")
        body <- case nativeCall d of
          Nothing -> pure (invoke "todo!" [string (idText (declarationId d))])
          Just native -> RB.emitCall planMachineBits planDataDeclarations bindings [handlerName ability | ability <- declarationUses d, not (isFail ability)] d native
        -- The adapter keeps its declaration's name, which Rust's lint may
        -- not call snake case.
        pure (Doc.lineComment 100 "// " (labelled (declarationName d) (sourceLink (declarationOrigin d))) <>
          Doc.lineComment 100 "// " ("LawSpec type: " ++ outerless (Presentation.prettyType (declarationType d))) <>
          (if any isUpper (declarationName d) then Doc.text "#[allow(non_snake_case)]" <> Doc.hardline else mempty) <>
          signature <> block body)
      wrappers <- forM adapters $ \d -> do
        let (args,result) = functionType (declarationType d)
            fn = maybe "missing" id (lookup (declarationId d) declarationNames)
            contract = find ((== declarationId d) . contractDeclaration) (unitContracts unit)
            -- The arguments are named as the adapter's are, or as its
            -- contract names them.
            argumentNames = case contract of
              Just c | length (contractArguments c) == length args -> Expression.sourceLocals [] (contractArguments c)
              _ -> ["value" ++ show i | i <- [0 .. length args - 1]]
            names = case contract of
              Nothing -> []
              Just c -> zip (map binderId (contractArguments c)) argumentNames ++ [(binderId (contractResult c),"result")]
            native name = "native_" ++ unraw name
        args' <- forM (zip argumentNames args) $ \(name,t) -> do
          ty <- argumentType t
          ref <- schemaType t
          let value = Doc.text (name ++ ".clone()")
              -- Separate checked bridge values from native decoding; this also
              -- keeps deeply applied native type names out of nested calls.
              convert term = block (statements [binding "value" term,
                invoke ("<" ++ ty ++ " as ls::FromValue>::from_value") [Doc.text "value"] <> Doc.text "?"])
          pure $ if usesData t
            then convert (invoke "lawspec_schema::schema()?.native_value_with_context" [value,borrow ref,bits,Doc.text "ctx"] <> Doc.text "?")
            else if typeName t == "CodeUnit16"
            then Doc.text "match " <> value <> Doc.text " " <> block (statements
              [Doc.text "ls::Value::CodeUnit16(x) => x,",
               Doc.text "_ => return Err(\"expected CodeUnit16\".into()),"])
            else convert (invoke "ls::native_value" [value,string (typeName t)] <> Doc.text "?")
        pre <- maybe (Right []) (mapM (predicate names (declarationName d ++ " precondition")) . contractPreconditions) contract
        post <- maybe (Right []) (mapM (predicate names (declarationName d ++ " postcondition")) . contractPostconditions) contract
        -- An async adapter's future is awaited where it is called.
        -- An adapter that uses abilities gets their handlers first.
        failureType <- case [a | a@(AbilityRef _ [_]) <- declarationUses d, isFail a] of
          AbilityRef _ [failure] : _ -> Just <$> nativeType failure
          _ -> pure Nothing
        let uses = [ability | ability <- declarationUses d, not (isFail ability)]
            -- Each ability's handler, named after its interface.
            handlerNames = fst (claimAll (scopeWith (Expression.reservedLocals ++ argumentNames))
              [nativeIdentifier "rust" ValueName (case [interfaceName a | Just (_, a) <- [findAbility allUnits ability]] of
                 n : _ -> n
                 [] -> "handler") | ability <- uses])
            handlerBindings = [binding (n ++ ": " ++ handlerType ability) (handlerValue ability) | (n, ability) <- zip handlerNames uses]
            call = invoke ("adapter::" ++ declarationName d)
              ([Doc.text ("&*" ++ n) | n <- handlerNames] ++ map (Doc.text . native) argumentNames)
            plain = if declarationAsync d then invoke "ls::block_on" [call] else call
            -- An adapter that fails with E: its native code calls ls::fail
            -- with a native E (or panics with what lawspec.json maps).
            called = case (failureType, [a | a@(AbilityRef _ [_]) <- declarationUses d, isFail a]) of
              (Just native, ability@(AbilityRef _ [failure]) : _) -> invoke ("ls::native_failures::<" ++ native ++ ", _>")
                [string (abilityKey ability), Doc.text "|native| ls::IntoValue::into_value(native)", Doc.text "|| " <> plain,
                 Doc.text (Paths.mappedFailures planMachineBits (NR.bindingRustCrate bindings) (unitFailureBindings unit) failure)]
              _ -> plain
            wrapped = invoke (if typeName result == "CodeUnit16" then "ls::Value::CodeUnit16" else "ls::IntoValue::into_value") [Doc.text "native_result"]
        ref <- schemaType result
        let checkedResult = (if usesData result
              then invoke "lawspec_schema::schema()?.validate_with_context" [wrapped,borrow ref,bits,Doc.text "ctx"]
              else invoke "ls::validate" [wrapped,string (typeName result),bits]) <> Doc.text "?"
        let wrapperBody = statements
              ([statement (invoke "ls::require_architecture" [bits] <> Doc.text "?") | nativeMachineType (declarationType d)] ++
               [binding name (Doc.text ("args[" ++ show i ++ "].clone()")) | (i, name) <- zip [0::Int ..] argumentNames] ++
               pre ++ [binding (native name) value | (name,value) <- zip argumentNames args'] ++ handlerBindings ++
               [binding "native_result" called,binding "result" checkedResult] ++ post ++ [Doc.text "Ok(result)"])
        pure (Doc.lineComment 100 "// " (labelled (declarationName d) (sourceLink (declarationOrigin d))) <>
          function fn [Doc.text (unusedAs "ctx" wrapperBody ++ ": &mut ls::Context"), Doc.text (unusedAs "args" wrapperBody ++ ": Vec<ls::Value>")]
            "ls::Result<ls::Value>" wrapperBody)
      -- A model's test hands its spec and callbacks to the model runtime.
      -- Benchmarks: measured, never asserted.
      benchmarks <- forM (maybe [] harnessBenchmarks (unitHarnessSettings unit)) $ \(n, e) -> do
        -- The production handlers a benchmark runs under are installed in
        -- its context, as a law's are.
        let peel term = case expressionNode term of
              Handle (WithHandler a ProductionHandler) inner -> let (hs, core) = peel inner in ((a, ProductionHandler) : hs, core)
              _ -> ([], term)
            (installed, core) = peel e
            installs = installsFor unit installed
        body <- render [] core
        pure (Doc.text "#[test]" <> Doc.hardline <> function ("benchmark_" ++ intercalate "_" (lawWords n)) [] "ls::Result<()>"
          (statements $ [Doc.text "let ctx = &mut ls::Context::testing();"] ++ installs ++ [
            closureCall "lawspec_harness::benchmark" [string n] (Doc.text "|| " <> block (statements [binding "_measured" body, Doc.text "Ok(())"]))]))
      modelTests <- map (reverse . dropWhile (== '\n') . reverse) <$>
        either (Left . concatMap message) Right (ModelTests.rustModelTests planMachineBits planDataDeclarations definitionNames (modelTestUnit plan unit))
      let testNames = unitTestNames "rust" (map (propertyName . plannedProperty) plannedProperties)
          unitName = idText (unitId unit)
      -- Each law is a module of tests: one per example and boundary case,
      -- and one for its generated cases, so a failure names what failed.
      -- Every test of the unit has its own turn under order random.
      tests <- forM (zip [0::Int ..] plannedProperties) $ \(index,pp) -> do
        let p = plannedProperty pp
            label = propertyName p
            shown = displayLabel label
            sourceBinders = map quantifiedBinder (propertyInputs p) ++ map resourceBinder (propertyResources p)
            locals = Expression.sourceLocals [(Id "", w) | w <- wrapperNames] sourceBinders
            names = zip (map (binderId . quantifiedBinder) (propertyInputs p)) locals
            resourceNames = zip (map (binderId . resourceBinder) (propertyResources p)) (drop (length names) locals)
            withResources = names ++ resourceNames
            lawLink = Presentation.propertyLink p >>= written
            lawContext = labelled (unitName ++ "::" ++ shown) lawLink
            -- Each case's workflows wait on their own virtual clock; a case
            -- makes its context when what follows reads it.
            opening rest = [Doc.text (clockRegistration unit) | not (null (clockRegistration unit))] ++
              [Doc.text "let ctx = &mut ls::Context::testing();" | mentions "ctx" (statements rest)]
            opened rest = opening rest ++ rest
            parameters used = Doc.text (if mentions "ctx" used then "ctx: &mut ls::Context" else "_ctx: &mut ls::Context") :
              [Doc.text (unusedAs n used ++ ": ls::Value") | (_,n) <- names]
        -- A law's resources: each case acquires them, then runs, then
        -- releases them, the last first, even when the case fails or panics.
        let bracket inner [] = pure (statements (lateInstalls unit p ++ inner))
            -- A shared resource (share R per ...): the runtime keeps one per
            -- scope key, resets it before each later use, holds it for this
            -- case until its guard drops, and releases it at exit.
            bracket inner ((r, (_, local)) : rest) | Just key <- resourceShared r, Just reset <- resourceReset r = do
              acquired <- renderL withResources (resourceAcquire r)
              resetting <- renderL withResources reset
              released <- renderL withResources (resourceRelease r)
              nested <- bracket inner rest
              let usedIn e = mentions "ctx" (RL.expr e)
                  ctxParam e = (if usedIn e then "ctx" else "_ctx") ++ ": &mut ls::Context"
                  use e = RL.closure ("|" ++ ctxParam e ++ ", " ++ unusedAs local (RL.expr e) ++ ": ls::Value| -> ls::Result<ls::Value>")
                    (RL.Block [] (Just (RL.call "Ok" [e])))
              pure (statements
                [ RL.stmt (RL.Let ("(" ++ local ++ ", _shared_" ++ unraw local ++ ")") (RL.try' (RL.call "ls::share"
                    [ RL.atom (q key), RL.atom "ctx"
                    , RL.closure ("|" ++ ctxParam acquired ++ "| -> ls::Result<ls::Value>") (RL.Block [] (Just (RL.call "Ok" [acquired])))
                    , use resetting, use released, RL.atom (if resourceConcurrent r then "true" else "false") ])))
                , nested ])
            -- A resource the case acquires, then releases after it runs,
            -- even when it fails or panics (ls::bracket).
            bracket inner ((r, (_, local)) : rest) = do
              acquired <- renderL withResources (resourceAcquire r)
              released <- renderL withResources (resourceRelease r)
              nested <- bracket inner rest
              let param used = "|" ++ unusedAs "ctx" used ++ "|"
                  body = RL.Block [RL.Item nested] (Just (RL.atom "Ok(())"))
              pure (statements
                [ RL.stmt (RL.Let local acquired)
                , RL.stmt (RL.Semi (RL.try' (RL.call "ls::bracket"
                    [ RL.atom "ctx"
                    , RL.closure (param nested) body
                    , RL.closure (param (RL.expr released)) (RL.call "Ok" [released]) ]))) ])
            resourced inner = bracket inner (zip (propertyResources p) resourceNames)
        body <- proposition withResources (Left lawContext) (propertyBody p) >>= resourced . pure
        checkedInputs <- if null planDataDeclarations then pure [] else
          forM (zip (propertyInputs p) names) $ \(input,(_,name)) -> do
            ty <- schemaType (binderType (quantifiedBinder input))
            pure (binding name (invoke "lawspec_schema::schema()?.validate_with_context" [Doc.text name,borrow ty,bits,Doc.text "ctx"] <> Doc.text "?"))
        valid <- forM (concatMap quantifiedPredicates (propertyInputs p)) $ \predicateExpr -> do
          term <- renderL names predicateExpr
          pure (statements [RL.stmt (RL.Let "condition" term),
            conditional (Doc.text "!condition.boolean()?") (Doc.text "return Ok(false);")])
        strategies <- forM (zip3 [0::Int ..] (propertyInputs p) (generatorRequirements pp)) $ \(i,input,requirement) -> do
          bounds <- forM (quantifiedBounds input) $ \(op,e) -> do
            value <- renderL names e
            pure (RL.Macro "" "(" ")" [RL.atom (q (binaryName op)), value])
          hints <- mapM (render names) (generatorHints requirement)
          seeds <- mapM valueLiteral (generatorBoundaries requirement)
          let inputType = binderType (quantifiedBinder input)
              checked = hasFieldContracts && (hasNativeGenerators || usesData inputType)
              required expression = case expressionNode expression of
                ShortCircuit And a b -> required a ++ required b
                Binary Equal _ a b -> [value | (local,value) <- [(a,b),(b,a)],
                  expressionNode local == Local (binderId (quantifiedBinder input)),
                  expressionType value == scalarType "Symbol",
                  binderId (quantifiedBinder input) `notElem` freeBinders value,
                  case expressionNode value of Constant _ -> True; Local _ -> True; _ -> False]
                _ -> []
          symbols <- if inputType == scalarType "Symbol"
            then mapM (render names) (concatMap required (quantifiedPredicates input)) else pure []
          indexTarget <- traverse (render names . indexedTarget) (generatorIndex requirement)
          baseStrategy <- case (usesData inputType, generatorIndex requirement, indexTarget) of
           (True, Just indexed, Just target) -> do
            -- Evaluate once before borrowing the context for constructor checks:
            -- an earlier input's measure may itself need mutable evaluation.
            ty <- schemaType inputType
            let budget = maximum (64 : map ((+ 8) . valueBudget) (generatorBoundaries requirement))
                table = Expression.vector [Doc.text "(" <> string (idText tag) <> Doc.text ", &" <>
                  Expression.vector (map string texts) <> Doc.text "[..])"
                  | (tag,texts) <- indexedEquations indexed]
            pure (block (statements [binding "index_target" target,
              invoke (if checked then "ls_gen::checked_indexed_strategy" else "ls_gen::indexed_strategy")
              ([Doc.text "lawspec_schema::schema()?",borrow ty,bits,Doc.text (show budget)] ++
               [Doc.text "ctx" | checked] ++
               [Doc.text "&index_target",Doc.text "&" <> table]) <> Doc.text "?"]))
           _ -> if usesData inputType || hasNativeGenerators then do
            ty <- schemaType inputType
            let budget = maximum (64 : map ((+ 8) . valueBudget) (generatorBoundaries requirement))
            let name = (if checked then "ls_gen::checked_schema_strategy" else "ls_gen::schema_strategy") ++
                  (if hasNativeGenerators then "_with_generators" else "")
            pure (invoke name
              ([Doc.text "lawspec_schema::schema()?",borrow ty,bits,Doc.text (show budget)] ++
               (if checked then [Doc.text "ctx",Doc.text "seeds.clone()"] else [Doc.text "ctx" | hasNativeGenerators]) ++
               [Doc.text "&native_generators()?" | hasNativeGenerators]) <> Doc.text "?")
            else pure (case symbols of
              _:_ -> invoke "proptest::strategy::Just" [Doc.text "symbol"] <> Doc.text ".boxed()"
              [] -> invoke "ls_gen::strategy_with_profile" [string (typeName inputType),bits] <> Doc.text "?")
          -- A harness strategy draws this input from a seed proptest chooses.
          harnessDraw <- case [(n', d) | (bi, n', d) <- harnessDraws (propertyHarness p), bi == binderId (quantifiedBinder input)] of
            [] -> pure Nothing
            (strategy, d) : _ -> Just <$> harnessStrategy (take i names) input (snd (names !! i)) strategy d
          let construct = case harnessDraw of
                Just doc -> Doc.text "Ok::<_, String>(Some(" <> doc <> Doc.text "))"
                Nothing | null bounds || customInput inputType -> Doc.text "Ok::<_, String>(Some(" <> baseStrategy <> Doc.text "))"
                        | otherwise -> RL.expr (RL.call "ls_gen::bounded_integer" [RL.atom (q (typeName inputType)), RL.vecOf bounds, RL.atom (show planMachineBits)])
              seeded = not (harnessDraw /= Nothing || checked || customInput inputType)
              made = statements
                ([binding "symbol" value | value <- take 1 symbols] ++
                 [binding "seeds" (Expression.vector (if null symbols then hints ++ seeds else [])) | seeded || checked] ++
                 [binding "base" (construct <> Doc.text "?"),
                  Doc.text (if harnessDraw /= Nothing then (if hasFieldContracts then "Ok(base.map(|base| base.prop_map(Ok).boxed()))" else "Ok(base)")
                    else if checked then "Ok(base)" else if customInput inputType
                    then if hasFieldContracts then "Ok(base.map(|base| base.prop_map(Ok).boxed()))" else "Ok(base)"
                    else if hasFieldContracts
                    then "Ok(base.map(|base| ls_gen::seeded(base, seeds).prop_map(Ok).boxed()))"
                    else "Ok(base.map(|base| ls_gen::seeded(base, seeds)))")])
              -- Earlier inputs, and the case's context, only where this
              -- input's strategy reads them.
              earlier = [binding n (Doc.text ("case.values[" ++ show j ++ "].clone()")) | (j,(_,n)) <- zip [0::Int ..] (take i names), mentions n made]
              candidate = Doc.text "(|| -> ls::Result<Option<ValueStrategy>> " <> block (statements
                ([Doc.text "let ctx = &mut case.context;" | mentions "ctx" made] ++ earlier ++ [made])) <>
                Doc.text ")()" <> Doc.softbreak <> Doc.text ".unwrap_or_else(|e| panic!(\"{e}\"))"
              extend = Doc.text "(proptest::strategy::Just(case), s)" <>
                Doc.nest 4 (Doc.softbreak <> Doc.text ".prop_map(|(mut case, x)| " <>
                  block (statements [if hasFieldContracts
                    then Doc.text "match x " <> block (statements
                      [Doc.text "Ok(value) => case.values.push(value),",Doc.text "Err(error) => case.error = Some(error),"])
                    else Doc.text "case.values.push(x);",Doc.text "case"]) <> Doc.text ")" <>
                  Doc.softbreak <> Doc.text ".boxed()")
              matched = Doc.text "match candidate " <> block (statements
                [Doc.text "Some(s) => " <> extend <> Doc.text ",",
                 Doc.text "None => " <> block (statements
                  [Doc.text "case.values.clear();",Doc.text "proptest::strategy::Just(case).boxed()"])] )
          pure (binding "strategy" (Doc.text "strategy" <> Doc.nest 4
            (Doc.softbreak <> Doc.text ".prop_flat_map(|mut case| " <> block (statements
            [conditional (Doc.text ("case.values.len() != " ++ show i))
              (Doc.text "return proptest::strategy::Just(case).boxed();"),
             binding "candidate" candidate,matched]) <> Doc.text ")" <>
             Doc.softbreak <> Doc.text ".boxed()")))
        examples <- forM (propertyExamples p) $ \e -> do
          bindings <- forM (exampleBindings e) $ \(i,x) -> do
            value <- render [] x
            name <- maybe (Left "unbound example input") Right (lookup i names)
            pure (name, value)
          let exampleContext = unitName ++ "::" ++ shown ++ " example " ++ displayLabel (exampleName e)
          checks <- mapM (proposition withResources (Right exampleContext)) (exampleExpectations e)
          lawCheck <- proposition withResources (Left lawContext) (propertyBody p)
          checked <- resourced (checks ++ [lawCheck])
          let rest = handlerInstalls unit p ++ [checked]
              -- An example's value that nothing reads is still made, as written.
              named = [binding (unusedAs n (statements (later ++ rest))) v | ((n, v), later) <- zip bindings (drop 1 (tails (map (uncurry binding) bindings)))]
          pure (e, statements (opened (named ++ rest)))
        let searchKept = searchable (finiteCases pp /= Nothing) p && lawDescriptors planMachineBits planDataDeclarations p /= Nothing
            predicated = not (null valid)
            inputArgs from = [Doc.text (from ++ "[" ++ show n ++ "].clone()") | n <- [0..length names-1]]
            tupleArgs = inputArgs "case.values"
            valueArgs = inputArgs "values"
            lawCall ctx args' = invoke "check" (Doc.text ctx : args')
            generated = case finiteCases pp of
              Just _ -> []
              Nothing ->
                [Doc.text "let strategy = proptest::strategy::Just(ls_gen::Case::default()).boxed();"] ++ strategies ++
                [ binding "refinement" (Doc.text "|case: &ls_gen::Case| " <>
                    (if not hasFieldContracts && not predicated then Doc.text ("case.values.len() == " ++ show (length names)) else
                    block (statements ([conditional (Doc.text "case.error.is_some()") (Doc.text "return true;") | hasFieldContracts] ++
                      (if predicated
                        then [conditional (Doc.text ("case.values.len() != " ++ show (length names))) (Doc.text "return false;"),
                              binding "result" (invoke "valid" (Doc.text "&mut case.context.clone()" : tupleArgs)),
                              Doc.text "result.unwrap_or_else(|e| panic!(\"{e}\"))"]
                        else [Doc.text ("case.values.len() == " ++ show (length names))])))))
                , RL.stmt (RL.Let "strategy" (RL.method (RL.atom "strategy") "prop_filter" [RL.Laid (string (shown ++ " refinement")), RL.atom "refinement"]))
                , binding "config" (Doc.text "proptest::test_runner::Config " <> block (statements
                    ([Doc.text ("cases: " ++ show (cases (propertyGeneration p)) ++ ","),
                     Doc.text ("max_global_rejects: " ++ show (maxAttempts (propertyGeneration p)) ++ ",")] ++
                     [Doc.text ("max_local_rejects: " ++ show (maxAttempts (propertyGeneration p)) ++ ",") | hasFieldContracts] ++
                     [Doc.text ("max_shrink_iters: " ++ show (maxShrinks (propertyGeneration p)) ++ ","),
                     Doc.text "rng_seed: ls_gen::rng_seed(),",
                     Doc.text "failure_persistence: ls_gen::failure_persistence(),",
                     Doc.text "..Default::default()"]) ))
                , binding "check" (Doc.text "|mut case: ls_gen::Case| " <>
                    block (statements ([Doc.text "if let Some(error) = case.error " <> block
                      (Doc.text "return Err(proptest::test_runner::TestCaseError::fail(error));") | hasFieldContracts] ++
                      -- What the case covers, classifies and labels.
                      [RL.stmt (RL.Semi (RL.try' (RL.method (RL.call "observe" (RL.atom "&mut case.context" : map RL.Laid tupleArgs))
                        "map_err" [RL.atom "proptest::test_runner::TestCaseError::fail"]))) | observed (propertyHarness p)] ++
                      [binding "result" (lawCall "&mut case.context" tupleArgs)] ++
                      -- A failing case's inputs go to the failure database.
                      [conditional (Doc.text "result.is_err()") (statement (invoke "ls::search_remember" [string (unitName ++ "::" ++ label),
                         Doc.text "SEARCH_INPUTS", Doc.text "&case.values"])) | searchKept] ++
                      [Doc.text "result.map_err(proptest::test_runner::TestCaseError::fail)"])))
                , statement (Doc.text "proptest::test_runner::TestRunner::new(config)" <>
                    Doc.nest 4 (Doc.softbreak <> invoke ".run" [Doc.text "&strategy",Doc.text "check"] <>
                      Doc.softbreak <> Doc.text ".map_err(|e| format!(\"{e}\"))?"))
                ]
        boundaryCases' <- forM (maybe (boundaryCases pp) id (finiteCases pp)) (mapM valueLiteral)
        observations <- observationsDoc names p
        -- LawSpec's own search (LawSpec.Search): the failure database's
        -- inputs are replayed before the law's generated cases, a failing
        -- case's inputs are kept, and a law with `target maximize` climbs
        -- after them, as proptest has no targeting.
        let descriptors = if searchable (finiteCases pp /= Nothing) p then lawDescriptors planMachineBits planDataDeclarations p else Nothing
            lawKey = unitName ++ "::" ++ label
        score <- traverse (render names) (harnessTarget (propertyHarness p))
        let searchItems = case descriptors of
              Nothing -> []
              Just ds -> [RL.stmt (RL.Let' "const SEARCH_INPUTS: &[&str]" (RL.prefix "&" (RL.Macro "" "[" "]" (map (RL.atom . q) ds))))] ++
                [function "score" (parameters scored) "ls::Result<f64>" scored | Just s <- [score], let scored = statements [binding "score" s, Doc.text "Ok(ls::search_number(&score))"]] ++
                [function "search_case" [Doc.text "values: &[ls::Value]"] "ls::Result<Option<f64>>" (statements
                  ([ Doc.text "let ctx = &mut ls::Context::testing();" ] ++
                   [ conditional (Doc.text "!" <> invoke "valid" (Doc.text "ctx" : valueArgs) <> Doc.text "?") (Doc.text "return Ok(None);") | predicated ] ++
                   [ statement (lawCall "ctx" valueArgs <> Doc.text "?")
                   , if score == Nothing then Doc.text "Ok(Some(0.0))" else Doc.text "Ok(Some(" <> invoke "score" (Doc.text "ctx" : valueArgs) <> Doc.text "?))" ]))]
            replay = [statement (invoke "ls::search_replay" [string lawKey, Doc.text "SEARCH_INPUTS", Doc.text "search_case"] <> Doc.text "?") | descriptors /= Nothing]
            climb = [statement (invoke "ls::search_climb" [string lawKey, Doc.text "SEARCH_INPUTS", Doc.text "search_case"] <> Doc.text "?")
                    | descriptors /= Nothing, harnessTarget (propertyHarness p) /= Nothing]
            h = propertyHarness p
            -- order random: each test waits for its turn (lawspec_harness::turn).
            parallelUnit = maybe False harnessParallel (unitHarnessSettings unit)
            turn k = [statement (invoke "lawspec_harness::parallelism" [string unitName]) | parallelUnit] ++
                   [binding "_turn" (invoke "lawspec_harness::turn" [string unitName, Doc.text (show k), Doc.text (if parallelUnit then "true" else "false")])
                   | maybe False harnessOrderRandom (unitHarnessSettings unit)]
            moduleName = testNames !! index
            -- A test's statements and its last expression: the law's check
            -- of a case's values, or Ok(()).
            -- A boundary or finite case runs the law once on its values;
            -- values that read the context are made before the call.
            caseRun values
              | any (mentions "ctx") values = let made = [binding "values" (Expression.vector values)]
                  in (opening [Doc.text "ctx"] ++ made, Just (lawCall "ctx" valueArgs))
              | otherwise = (opening [Doc.text "ctx"], Just (lawCall "ctx" values))
            boundaryTests = [caseRun values | Nothing <- [finiteCases pp], values <- boundaryCases']
            -- A law over finitely many cases checks them all in one test.
            exhaustive = [(replay ++ [block (asStatements (caseRun values)) | values <- boundaryCases'], Nothing) | Just _ <- [finiteCases pp]]
            property = [(replay ++ generated ++ climb, Nothing) | Nothing <- [finiteCases pp]]
            asStatements (stmts, final) = statements (stmts ++ [statement (final' <> Doc.text "?") | Just final' <- [final]])
            asBody (stmts, final) = statements (stmts ++ [maybe (Doc.text "Ok(())") id final])
            taken = ["check", "valid", "observe", "score", "search_case", "property", "exhaustive", "skipped", "known_failing"]
            exampleNames = exampleTestSuffix "rust" taken (map (exampleName . fst) examples)
            boundaryNames = fst (claimAll (scopeWith (taken ++ exampleNames)) (map boundaryTestSuffix [0 .. length boundaryTests - 1]))
            caseTests = [(escapeKeyword "rust" n, Just e, ([d], Nothing)) | (n, (e, d)) <- zip exampleNames examples] ++
              [(n, Nothing, d) | (n, d) <- zip boundaryNames boundaryTests] ++
              [("exhaustive", Nothing, d) | d <- exhaustive] ++ [("property", Nothing, d) | d <- property]
            whole = statements ([block (asStatements d) | (_, _, d) <- caseTests] ++ [Doc.text "Ok(())"])
            -- The harness plane: a law that is skipped or expected to fail is
            -- one test; otherwise each test runs under the harness's settings.
            harnessed k name' isProperty (stmts, final) =
              let turned = asBody (turn k ++ stmts, final)
                  runner = stackClosure turned
              in if runSettings h
                then closureCall "lawspec_harness::run" [string (unitName ++ "::" ++ label), string (moduleName ++ "::" ++ name'), Doc.text (show (maybe 0 id (harnessTimeout h))),
                      Doc.text (show (harnessRepeat h)), Doc.text (show (harnessRetries h)),
                      if isProperty then Doc.text "&[" <> Doc.joinWith (Doc.text ", ") [Doc.text ("(" ++ show c ++ ", ") <> string l <> Doc.text ")" | Cover c l _ <- harnessCover h] <> Doc.text "]" else Doc.text "&[]",
                      Doc.text (if isProperty && observed h then "true" else "false")] runner
                else withStack turned
            testsOf = case (harnessSkip h, harnessKnownFailing h) of
              (Just reason, _) -> [Doc.text "#[test]" <> Doc.hardline <> Doc.text ("#[ignore = " ++ q (shown ++ ": " ++ reason) ++ "]") <> Doc.hardline <>
                Doc.text "fn skipped() {}"]
              (_, Just reason) -> [Doc.text "#[test]" <> Doc.hardline <> function "known_failing" [] "ls::Result<()>"
                (closureCall "lawspec_harness::known_failing" [string (unitName ++ "::" ++ label), string (moduleName ++ "::known_failing"), string reason]
                  (stackClosure whole))]
              _ -> [ maybe mempty (\e -> Doc.lineComment 96 "// " (labelled ("example " ++ displayLabel (exampleName e)) (sourceLinkOf e))) example <>
                     Doc.text "#[test]" <> Doc.hardline <> function name' [] "ls::Result<()>" (harnessed (index * 1000 + k) name' (name' == "property") d)
                   | (k, (name', example, d)) <- zip [0..] caseTests ]
            items = [Doc.text "use super::*;"] ++
              [function "check" (parameters lawBody) "ls::Result<()>" lawBody] ++
              [function "valid" (parameters validBody) "ls::Result<bool>" validBody | predicated] ++
              [function "observe" (parameters observeBody) "ls::Result<()>" observeBody | observed h] ++
              searchItems ++ testsOf
            lawBody = statements (handlerInstalls unit p ++ checkedInputs ++ [body, Doc.text "Ok(())"])
            validBody = statements (valid ++ [Doc.text "Ok(true)"])
            observeBody = statements (observations ++ [Doc.text "Ok(())"])
            sourceLinkOf e = fmap locationLink (exampleLocation e)
        pure (mconcat (map (Doc.lineComment 100 "// ") (Presentation.lawCommentLines pp)) <>
          Doc.text ("mod " ++ moduleName ++ " ") <> block (Doc.joinWith blank items))
      productions <- if generatedAdapter then boundWrappers unit else mapM (Abilities.productionStub planDataDeclarations unit) (ownAbilities unit)
      let adapterItems = Doc.joinWith blank (stubs ++ productions)
          adapterDoc = statements ([Doc.text (if generatedAdapter then "// " ++ generatedHeader (unitSourceFile unit)
              else "// Scaffolded by LawSpec" ++ maybe "" (" from " ++) (unitSourceFile unit) ++ ". User-owned; never overwritten.")] ++
            [Doc.text "use crate::lawspec_runtime as ls;" | mentions "ls" adapterItems] ++
            [Doc.text "use crate::lawspec_native::*;" | generatedAdapter && hasNativeTypes]) <>
            (if null stubs && null productions then mempty else blank <> adapterItems) <> Doc.hardline
          -- The definitions file calls workflow steps by their crate paths;
          -- this unit's own module is already mounted as adapter.
          workflowModules mount = [if owner == unitId unit then Doc.text ("use adapter as " ++ ident (idText owner) ++ ";") else mount owner
            | owner <- nub ([o | hasDefinitions, o <- Definitions.workflowAdapterUnits (map LawSpec.Testing.plannedUnit plannedUnits)] ++
                -- The production handlers of imported abilities are their owners'.
                map Id (Abilities.foreignOwners unit))]
          -- A shared module the tests mount uses only part of it there; the
          -- adapter and the test support are the tests' own.
          moduleDoc filename name = Doc.text ("#[path = " ++ q filename ++ "]") <> Doc.hardline <>
            (if name `elem` ["adapter", "ls_gen", "lawspec_runtime", "lawspec_harness"] then mempty else Doc.text "#[allow(dead_code, unused_imports)]" <> Doc.hardline) <>
            Doc.text ("mod " ++ name ++ ";")
          localImports = [moduleDoc ("../src/" ++ modulePath ++ ".rs") "adapter"] ++
            [moduleDoc "../src/lawspec_data.rs" "lawspec_data" | not (null planDataDeclarations)] ++
            [moduleDoc "../src/lawspec_definitions.rs" "lawspec_definitions" | hasDefinitions] ++
            workflowModules (\owner -> moduleDoc ("../src/" ++ map (\c -> if c == '.' then '/' else c) (idText owner) ++ ".rs") (ident (idText owner))) ++
            [moduleDoc "../src/lawspec_runtime.rs" "lawspec_runtime"] ++
            [moduleDoc "../src/lawspec_sessions.rs" "lawspec_sessions" | hasSessions] ++
            [moduleDoc "../src/lawspec_actors.rs" "lawspec_actors" | hasActors] ++
            [moduleDoc "../src/lawspec_remote.rs" "lawspec_remote" | hasRemote] ++
            [moduleDoc "../src/lawspec_mailboxes.rs" "lawspec_mailboxes" | hasMailboxes] ++
            [moduleDoc "../src/lawspec_abilities.rs" "lawspec_abilities" | hasAbilities] ++
            [moduleDoc "../src/lawspec_schema.rs" "lawspec_schema" | hasSchema] ++
            [moduleDoc "support/lawspec_strategies.rs" "ls_gen"] ++
            [moduleDoc "support/lawspec_harness.rs" "lawspec_harness" | unitHarnessSettings unit /= Nothing]
          imports = case NR.bindingRustCrate bindings of
            Nothing -> localImports
            Just library -> [Doc.text ("use " ++ library ++ "::" ++ testName ++ " as adapter;")] ++
              [Doc.text ("use " ++ library ++ "::lawspec_data;") | not (null planDataDeclarations)] ++
              [moduleDoc "../src/lawspec_definitions.rs" "lawspec_definitions" | hasDefinitions] ++
              workflowModules (\owner -> Doc.text ("use " ++ library ++ "::" ++ ident (idText owner) ++ ";")) ++
              [Doc.text ("use " ++ library ++ "::lawspec_runtime;")] ++
              [Doc.text ("use " ++ library ++ "::lawspec_sessions;") | hasSessions] ++
              [Doc.text ("use " ++ library ++ "::lawspec_actors;") | hasActors] ++
              [Doc.text ("use " ++ library ++ "::lawspec_remote;") | hasRemote] ++
              [Doc.text ("use " ++ library ++ "::lawspec_mailboxes;") | hasMailboxes] ++
              [Doc.text ("use " ++ library ++ "::lawspec_abilities;") | hasAbilities] ++
              [Doc.text ("use " ++ library ++ "::lawspec_native::*;") | hasNativeTypes] ++
              [Doc.text ("use " ++ library ++ "::lawspec_schema;") | hasSchema] ++
              [moduleDoc "support/lawspec_strategies.rs" "ls_gen"] ++
              [moduleDoc "support/lawspec_harness.rs" "lawspec_harness" | unitHarnessSettings unit /= Nothing]
          content = Doc.joinWith blank (filter (not . null . Doc.render Doc.Compact) (wrappers ++ tests ++ benchmarks ++ map Doc.text modelTests))
          -- Only what the tests use: proptest's Strategy methods and the
          -- strategy type when a law has generated cases.
          strategyUsed = any (`mentions` content) ["boxed", "prop_map", "prop_flat_map", "prop_filter"]
          -- Modules, then uses, each in rustfmt's order (by name).
          ordered = sortOn fst [(sortKey (Doc.render Doc.Compact d), d) | d <- imports ++ generatorModules] ++
            [(("2", ""), Doc.text "use lawspec_runtime as ls;") | mentions "ls" content || mentions "ValueStrategy" content] ++ [(("2", ""), Doc.text "use proptest::strategy::Strategy;") | strategyUsed]
          sortKey text = case [w | l <- lines text, w <- take 1 (drop 1 (words l)), take 4 l == "mod "] of
            name : _ -> ("0", name)
            [] -> ("1", text)
          testDoc = statements ([Doc.text ("// " ++ generatedHeader (unitSourceFile unit))] ++ map snd ordered) <>
            (if mentions "ValueStrategy" content then blank <> Doc.text ("type ValueStrategy = proptest::strategy::BoxedStrategy<" ++ (if hasFieldContracts then "ls::Result<ls::Value>" else "ls::Value") ++ ">;") else mempty) <>
            (if hasNativeGenerators then blank <> generatorSupport else mempty) <>
            (if null (Doc.render Doc.Compact content) then mempty else blank <> content) <> Doc.hardline
      pure [Artifact ("src/" ++ modulePath ++ ".rs") (Doc.render layout adapterDoc) (if generatedAdapter then "generated" else "user") "source",
        Artifact ("tests/" ++ testName ++ "_lawspec.rs") (Doc.render layout testDoc) "generated" "test"]

-- | Test scaffolding retains documents until the complete artifact is laid out.
invoke :: String -> [Doc.Doc] -> Doc.Doc
invoke "Err" [value] = Doc.text "Err(" <> value <> Doc.text ")"
invoke "format!" (format:args)
  | length (Doc.render Doc.Compact (Doc.commaSep (format:args))) > 60 =
      Doc.text "format!(" <> Doc.nest 4 (Doc.softbreak <> format <> Doc.text "," <>
        Doc.softline <> Doc.group (Doc.commaSep args <> Doc.text ",")) <>
      Doc.softbreak <> Doc.text ")"
invoke name args = Expression.call name args
string :: String -> Doc.Doc
string = Expression.stringLiteral
block :: Doc.Doc -> Doc.Doc
block = Doc.block 4
blank :: Doc.Doc
blank = Doc.hardline <> Doc.hardline
statements :: [Doc.Doc] -> Doc.Doc
statements = Doc.joinWith Doc.hardline
statement :: Doc.Doc -> Doc.Doc
statement value = value <> Doc.text ";"
-- | A let, laid out as rustfmt lays out its value.
binding :: String -> Doc.Doc -> Doc.Doc
binding name value = RL.stmt (RL.Let name (RL.Laid value))
borrow :: Doc.Doc -> Doc.Doc
borrow value = Doc.text "&" <> value
conditional :: Doc.Doc -> Doc.Doc -> Doc.Doc
conditional condition body = Doc.text "if " <> condition <> Doc.text " " <> block body
function :: String -> [Doc.Doc] -> String -> Doc.Doc -> Doc.Doc
function name args result body = Doc.text ("fn " ++ name) <>
  Doc.delimitTrailing 4 "(" ")" args <> Doc.text (" -> " ++ result ++ " ") <> block body

valueLiteral :: V.Value -> Either String Doc.Doc
valueLiteral value = RL.expr <$> valueExpr value

-- | A value as a Rust expression that makes it.
valueExpr :: V.Value -> Either String RL.Expr
valueExpr (V.ScalarValue value) = Expression.scalarExpr value
valueExpr value@(V.DataValue (Constructor "List" [TypeArgument _]) _ _) = do
  items <- V.listItems value
  values <- mapM valueExpr items
  let nested item = case item of
        V.DataValue (Constructor "List" _) _ _ -> True
        _ -> False
      names = ["element_" ++ show i | i <- [0 :: Int .. length values - 1]]
      list entries = RL.call "ls::Value::List" [RL.vecOf entries]
  pure (if any nested items
    then RL.Block [RL.Let name body | (name, body) <- zip names values] (Just (list (map RL.atom names)))
    else list values)
valueExpr (V.DataValue _ tag fields) = do
  values <- mapM valueExpr fields
  let made = RL.call (if builtinConstructor tag then "ls::construct" else "ls::construct_data") [RL.atom (q (idText tag)), RL.vecOf values]
  pure (if builtinConstructor tag then RL.try' made else made)
valueExpr (V.PresenceValue (Constructor name [TypeArgument _]) payload) = case payload of
  Nothing -> pure (RL.call ("ls::Value::" ++ name) [RL.atom "None"])
  Just x -> do
    value <- valueExpr x
    pure (RL.call ("ls::Value::" ++ name) [RL.Block [RL.Let "value" value] (Just (RL.call "Some" [RL.call "Box::new" [RL.atom "value"]]))])
valueExpr _ = Left "invalid structural literal for Rust"


-- | Every scalar, container and data constructor consumes one structural node.
valueBudget :: V.Value -> Integer
valueBudget (V.ScalarValue _) = 1
valueBudget (V.PresenceValue _ Nothing) = 1
valueBudget (V.PresenceValue _ (Just value)) = 1 + valueBudget value
valueBudget value@(V.DataValue (Constructor "List" _) _ _) =
  either (const 1) (\items -> 1 + sum (map valueBudget items)) (V.listItems value)
valueBudget (V.DataValue _ _ fields) = 1 + sum (map valueBudget fields)

-- A unit whose laws install a Clock handler registers how workflows read
-- one (lawspec.time's register_clock_ability) before each case.
clockRegistration :: Unit -> String
clockRegistration unit
  | not (or [abilityKey a == "lawspec.time::ability::Clock" | p <- unitProperties unit, (a, _) <- propertyHandlers p]) = ""
  | idText (unitId unit) == "lawspec.time" = "adapter::register_clock_ability();"
  | otherwise = "lawspec_time::register_clock_ability();"

-- | A Rust identifier without its raw prefix, to build a longer name from.
unraw :: String -> String
unraw name = maybe name id (stripPrefix "r#" name)

-- | A link to where something is written in the program's own sources; the
-- prelude is LawSpec's, not the reader's.
writtenLink :: Origin -> Maybe String
writtenLink origin = sourceLink origin >>= written

written :: String -> Maybe String
written link = if take 1 link == "<" then Nothing else Just link

-- | A test's body on a thread with room for deep values.
-- | A closure running body under ls::with_stack: rustfmt puts a body that
-- breaks over lines in braces.
stackClosure :: Doc.Doc -> Doc.Doc
stackClosure body
  | Doc.render Doc.Compact body == "Ok(())" = Doc.text "|| " <> withStack body
  | otherwise = Doc.text "|| " <> block (withStack body)

withStack :: Doc.Doc -> Doc.Doc
withStack body
  | Doc.render Doc.Compact body == "Ok(())" = Doc.text "ls::with_stack(|| Ok(()))"
  | otherwise = Doc.text "ls::with_stack(|| " <> block body <> Doc.text ")"

-- | A call whose last argument is a closure: rustfmt keeps the closure's
-- opening on the call's line when the other arguments fit there.
closureCall :: String -> [Doc.Doc] -> Doc.Doc -> Doc.Doc
closureCall name arguments closure = Doc.prefixChoice firstLine
  (Doc.text (name ++ "(") <> Doc.joinWith (Doc.text ", ") arguments <> Doc.text ", " <> closure <> Doc.text ")")
  (Doc.text (name ++ "(") <> Doc.nest 4 (Doc.hardline <> Doc.joinWith (Doc.text "," <> Doc.hardline) (arguments ++ [closure]) <> Doc.text ",") <>
    Doc.hardline <> Doc.text ")")
  where firstLine = name ++ "(" ++ intercalate ", " (map (Doc.render Doc.Compact) arguments) ++ ", " ++ takeWhile (/= '{') (Doc.render Doc.Compact closure) ++ "{"

-- | A type as written, without the parentheses around the whole.
outerless :: String -> String
outerless text@('(' : rest) | not (null rest), last rest == ')', balanced (init rest) = init rest
  where
    balanced = go (0 :: Int)
    go n [] = n == 0
    go n (c : cs)
      | c == '(' = go (n + 1) cs
      | c == ')' = n > 0 && go (n - 1) cs
      | otherwise = go n cs
outerless text = text

