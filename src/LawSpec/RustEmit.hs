-- Rust consumes an execution plan made entirely from typed core.
module LawSpec.RustEmit (emitRust, emitRustWithFormat, emitRustWithBindings, rustType, emitRustSchema) where
import LawSpec.Core
import LawSpec.Core.Total (constructorProofContracts)
import qualified LawSpec.RustExpr as Expression
import qualified LawSpec.RustDefinitions as Definitions
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
import Data.Char (ord, isAlphaNum, isAscii, toLower)
import Data.List (intercalate, find, nub, sortOn)
import Numeric (showHex)
import Control.Monad (forM, unless)

q :: String -> String
q s = '"':concatMap escape s ++ "\"" where
  escape '"' = "\\\""
  escape '\\' = "\\\\"
  escape c | ord c < 32 || ord c == 127 = "\\u{" ++ showHex (ord c) "}"
           | otherwise = [c]
comma :: [String] -> String
comma = intercalate ", "
ident :: String -> String
ident = map (\c -> if isAlphaNum c || c == '_' then c else '_')
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

-- Preserve type applications structurally; runtime schema validation never has
-- to parse a target-specific spelling or infer generic field types.
schemaVector :: [Doc.Doc] -> Doc.Doc
schemaVector [value] = Doc.text "vec![" <> value <> Doc.text "]"
schemaVector values = rustDelimited "vec![" "]" values

-- Rustfmt's default argument/array width is 60, inside the 100-column page.
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
      refinementTable = [Doc.text "(" <> Doc.text (q (Schema.constructorTag c)) <> Doc.text ", " <>
        records [Doc.text ("(" ++ show index ++ ", ") <> typeReference pattern <> Doc.text ")" | (index, pattern) <- Schema.constructorRefinements c] <>
        Doc.text (", " ++ show (Schema.constructorExistentials c) ++ ")") | c <- refined]
      base = if not (null refined)
        then Expression.call "ls::Schema::with_refinements" [records definitions, records metadata, records refinementTable]
        else if null contracts
        then Doc.text "ls::Schema::new(" <> records definitions <> Doc.text ")"
        else Expression.call "ls::Schema::with_contracts" [records definitions,records metadata]
      indexTables = [Doc.text ("(" ++ q (Schema.constructorTag c) ++ ", &[" ++ intercalate ", " (map q (Schema.constructorIndex c)) ++ "][..])")
        | s <- schemas, c <- Schema.constructors s, not (null (Schema.constructorIndex c))]
      witnessTables = [Doc.text ("(" ++ q (Schema.constructorTag c) ++ ", &[" ++ intercalate ", " (map show (Schema.constructorWitnesses c)) ++ "][..])")
        | s <- schemas, c <- Schema.constructors s, not (null (Schema.constructorWitnesses c))]
      indexed = if null indexTables then base
        else base <> Doc.text ".map(|schema| schema.with_indices(&" <> records indexTables <> Doc.text "))"
      factory = if null witnessTables then indexed
        else indexed <> Doc.text ".map(|schema| schema.with_witnesses(&" <> records witnessTables <> Doc.text "))"
  pure (Doc.render layout (Doc.text "// Generated by LawSpec. Do not edit." <>
    (if null contracts then mempty else Doc.hardline <> Doc.text "#![allow(unused_variables)]") <>
    Doc.hardline <> Doc.text "use crate::lawspec_runtime as ls;" <> Doc.hardline <> Doc.hardline <>
    Doc.joinWith (Doc.hardline <> Doc.hardline) (callbacks ++
      [Doc.text "pub fn schema() -> ls::Result<ls::Schema> " <> Doc.block 4 factory]) <> Doc.hardline))
  where
    variable (TypeVariable _) = True
    variable (Constructor _ args) = any (\arg -> case arg of TypeArgument ty -> variable ty; _ -> False) args
    variable (Arrow a b) = variable a || variable b
    records [] = Doc.text "vec![]"
    records [value] = Doc.text "vec![" <> value <> Doc.text "]"
    records values = Doc.text "vec![" <> Doc.nest 4
      (Doc.hardline <> Doc.joinWith Doc.hardline [value <> Doc.text "," | value <- values]) <>
      Doc.hardline <> Doc.text "]"
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
  ["List::Nil", "List::Cons", "Maybe::Nothing", "Maybe::Just", "Either::Left", "Either::Right"]

emitRust :: Plan -> Either [Diagnostic] [Artifact]
emitRust = emitRustWithFormat False

emitRustWithFormat :: Bool -> Plan -> Either [Diagnostic] [Artifact]
emitRustWithFormat minify = emitRustWithBindings minify NR.emptyBindingPlan

emitRustWithBindings :: Bool -> NR.BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitRustWithBindings minify bindings Plan{..} = either (Left . pure . (\m -> Diagnostic "rust" m Nothing)) Right $ do
  let declarations = concatMap (unitDeclarations . plannedUnit) plannedUnits
      keywords = words "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen"
  unless (all (\d -> declarationName d `notElem` keywords && all (\c -> isAscii c && (isAlphaNum c || c == '_')) (declarationName d)) declarations) (Left "reserved or invalid Rust adapter identifier")
  unless (all (\u -> let n = ident (idText (unitId (plannedUnit u))) in n `notElem` keywords && all (\c -> isAscii c && (isAlphaNum c || c == '_')) n) plannedUnits) (Left "reserved or invalid Rust module identifier")
  unless (not (NR.hasBindings bindings) || NR.bindingRustCrate bindings /= Nothing)
    (Left "Rust native bindings require rustCrate for application-library test linkage")
  unless (null (NB.resolvedTypes (NR.bindingRepresentations bindings)) || not (null (NR.bindingFunctions bindings)) || hasNativeGenerators)
    (Left "Rust native type bindings require function or generator bindings")
  nativeConversions <- RB.emitConversions planDataDeclarations bindings
  schema <- emitRustSchema planMachineBits (Doc.selectLayout minify (Doc.Pretty 100)) planDataDeclarations
  nativeData <- NativeData.emitRustData (Doc.selectLayout minify (Doc.Pretty 100)) planDataDeclarations
  definitions <- Definitions.emitRustDefinitions (Doc.selectLayout minify (Doc.Pretty 100)) planMachineBits planDataDeclarations (map plannedUnit plannedUnits)
  units <- concat <$> mapM emitUnit plannedUnits
  unless (length units == length (nub (map (map toLower . artifactPath) units))) (Left "units map to the same Rust output path")
  let modules = [("lawspec_runtime", "lawspec_runtime.rs")] ++
        [("lawspec_native", "lawspec_native.rs") | hasNativeTypes] ++
        [("lawspec_definitions", "lawspec_definitions.rs") | hasDefinitions] ++
        [("lawspec_schema", "lawspec_schema.rs") | hasSchema] ++
        [("lawspec_data", "lawspec_data.rs") | not (null planDataDeclarations)] ++
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
        [ Artifact "src/lawspec_runtime.rs" (runtimeSource "rust") "generated" "source"
        , Artifact "src/lawspec_modules.rs" moduleSource "generated" "source"
        , Artifact "tests/support/lawspec_strategies.rs" (runtimeSource "rust-strategies") "generated" "test"
        ]
  unless (length files == length (nub (map (map toLower . artifactPath) files))) (Left "Rust runtime or module path collision")
  generatorStubs <- NG.emitGeneratorStubs planDataDeclarations bindings
  pure (files ++ generatorStubs)
  where
    hasNativeTypes = not (null (NB.resolvedTypes (NR.bindingRepresentations bindings)))
    hasNativeGenerators = not (null (NB.resolvedGenerators (NR.bindingRepresentations bindings)))
    customInput ty = case ty of
      Constructor name _ -> any ((== Id name) . NB.resolvedGeneratorType)
        (NB.resolvedGenerators (NR.bindingRepresentations bindings))
      _ -> False
    definitionNames = Definitions.definitionNames (map plannedUnit plannedUnits)
    hasFieldContracts = any (not . null . constructorPredicates) (concatMap dataConstructors planDataDeclarations)
    hasDefinitions = not (null definitionNames)
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
            [(declarationId d,"call_" ++ show n) | (n,d) <- zip [0::Int ..] adapters]
          localNames p = [(binderId (quantifiedBinder a),"input_" ++ show n) | (n,a) <- zip [0::Int ..] (propertyInputs p)]
          render = Expression.renderExpression planDataDeclarations planMachineBits declarationNames
          proposition names label p = case p of
            Equation _ a b -> do
              x <- render names a
              y <- render names b
              pure (block (statements
                [ binding "left" x
                , binding "right" y
                , conditional (Doc.text "!ls::equal(&left, &right)?")
                    (statement (Doc.text "return " <> invoke "Err"
                      [invoke "format!" [string "{}: {:?} != {:?}",
                        string (label ++ " | expect " ++ Presentation.propositionText p),
                        Doc.text "left", Doc.text "right"]]))]))
            Implication g body -> do
              guard <- render names g
              inner <- proposition names label body
              pure (block (statements [binding "condition" guard,
                conditional (Doc.text "condition.boolean()?") inner]))
            Conjunction ps -> statements <$> mapM (proposition names label) ps
          predicate names label p = do
            value <- render names p
            pure (block (statements [binding "condition" value,
              conditional (Doc.text "!condition.boolean()?")
                (statement (Doc.text "return " <> invoke "Err" [string label <> Doc.text ".into()"]))]))
      let mappedAdapters = [(d,ref) | d <- adapters, Just ref <- [lookup d (NR.bindingFunctions bindings)]]
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
        let arguments = [Doc.text ("value" ++ show i ++ ": " ++ t) | (i,t) <- zip [0::Int ..] argTypes]
            signature = Doc.text ("pub fn " ++ declarationName d)
              <> Doc.delimitTrailing 4 "(" ")" arguments
              <> Doc.text (" -> " ++ resultType ++ " ")
        body <- case lookup d (NR.bindingFunctions bindings) of
          Nothing -> pure (invoke "todo!" [string (idText (declarationId d))])
          Just reference -> RB.emitCall planDataDeclarations bindings d reference
        pure (Doc.lineComment 100 "// " ("LawSpec: " ++ Presentation.prettyType (declarationType d)) <>
          signature <> block body)
      wrappers <- forM adapters $ \d -> do
        let (args,result) = functionType (declarationType d)
            fn = maybe "missing" id (lookup (declarationId d) declarationNames)
            contract = find ((== declarationId d) . contractDeclaration) (unitContracts unit)
            names = case contract of
              Nothing -> []
              Just c -> [(binderId b,"arg_" ++ show n) | (n,b) <- zip [0::Int ..] (contractArguments c)] ++ [(binderId (contractResult c),"result")]
        args' <- forM (zip [0::Int ..] args) $ \(i,t) -> do
          ty <- argumentType t
          ref <- schemaType t
          let value = Doc.text ("arg_" ++ show i ++ ".clone()")
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
        let called = invoke ("adapter::" ++ declarationName d)
              [Doc.text ("native_arg_" ++ show i) | i <- [0..length args-1]]
            wrapped = invoke (if typeName result == "CodeUnit16" then "ls::Value::CodeUnit16" else "ls::IntoValue::into_value") [Doc.text "native_result"]
        ref <- schemaType result
        let checkedResult = (if usesData result
              then invoke "lawspec_schema::schema()?.validate_with_context" [wrapped,borrow ref,bits,Doc.text "ctx"]
              else invoke "ls::validate" [wrapped,string (typeName result),bits]) <> Doc.text "?"
        pure (function fn [Doc.text "ctx: &mut ls::Context",Doc.text "args: Vec<ls::Value>"] "ls::Result<ls::Value>" (statements
          ([statement (invoke "ls::require_architecture" [bits] <> Doc.text "?") | nativeMachineType (declarationType d)] ++
           [binding ("arg_" ++ show i) (Doc.text ("args[" ++ show i ++ "].clone()")) | i <- [0..length args-1]] ++
           pre ++ [binding ("native_arg_" ++ show i) value | (i,value) <- zip [0::Int ..] args'] ++
           [binding "native_result" called,binding "result" checkedResult] ++ post ++ [Doc.text "Ok(result)"])))
      tests <- forM (zip [0::Int ..] plannedProperties) $ \(index,pp) -> do
        let p = plannedProperty pp
            names = localNames p
            label = propertyName p
            law = "law_" ++ show index
            args = Doc.text "ctx: &mut ls::Context" : [Doc.text (n ++ ": ls::Value") | (_,n) <- names]
            context = Doc.text "let ctx = &mut ls::Context::default();"
        body <- proposition names label (propertyBody p)
        checkedInputs <- if null planDataDeclarations then pure [] else
          forM (zip (propertyInputs p) names) $ \(input,(_,name)) -> do
            ty <- schemaType (binderType (quantifiedBinder input))
            pure (binding name (invoke "lawspec_schema::schema()?.validate_with_context" [Doc.text name,borrow ty,bits,Doc.text "ctx"] <> Doc.text "?"))
        valid <- forM (concatMap quantifiedPredicates (propertyInputs p)) $ \predicateExpr -> do
          term <- render names predicateExpr
          pure (block (statements [binding "condition" term,
            conditional (Doc.text "!condition.boolean()?") (Doc.text "return Ok(false);")]))
        strategies <- forM (zip3 [0::Int ..] (propertyInputs p) (generatorRequirements pp)) $ \(i,input,requirement) -> do
          bounds <- forM (quantifiedBounds input) $ \(op,e) -> do
            value <- render names e
            pure (Doc.text "(" <> string (binaryName op) <> Doc.text ", " <> value <> Doc.text ")")
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
            -- The target is evaluated from the inputs bound earlier in this case.
            ty <- schemaType inputType
            let budget = maximum (64 : map ((+ 8) . valueBudget) (generatorBoundaries requirement))
                table = Expression.vector [Doc.text "(" <> string (idText tag) <> Doc.text ", &" <>
                  Expression.vector (map string texts) <> Doc.text "[..])"
                  | (tag,texts) <- indexedEquations indexed]
            pure (invoke "ls_gen::indexed_strategy"
              [Doc.text "&lawspec_schema::schema()?",borrow ty,bits,Doc.text (show budget),
               Doc.text "&" <> target,Doc.text "&" <> table] <> Doc.text "?")
           _ -> if usesData inputType || hasNativeGenerators then do
            ty <- schemaType inputType
            let budget = maximum (64 : map ((+ 8) . valueBudget) (generatorBoundaries requirement))
            let name = (if checked then "ls_gen::checked_schema_strategy" else "ls_gen::schema_strategy") ++
                  (if hasNativeGenerators then "_with_generators" else "")
            pure (invoke name
              ([Doc.text "&lawspec_schema::schema()?",borrow ty,bits,Doc.text (show budget)] ++
               (if checked then [Doc.text "ctx",Doc.text "seeds.clone()"] else [Doc.text "ctx" | hasNativeGenerators]) ++
               [Doc.text "&_lawspec_native_generators()?" | hasNativeGenerators]) <> Doc.text "?")
            else pure (case symbols of
              _:_ -> invoke "proptest::strategy::Just" [Doc.text "symbol"] <> Doc.text ".boxed()"
              [] -> invoke "ls_gen::strategy_with_profile" [string (typeName inputType),bits] <> Doc.text "?")
          let construct = if null bounds || customInput inputType
                then Doc.text "Ok::<_, String>(Some(" <> baseStrategy <> Doc.text "))"
                else invoke "ls_gen::bounded_integer" [string (typeName inputType),Expression.vector bounds,bits]
              candidate = Doc.text "(|| -> ls::Result<Option<ValueStrategy>> " <> block (statements
                ([Doc.text "let ctx = &mut case.context;"] ++
                 [binding n (Doc.text ("case.values[" ++ show j ++ "].clone()")) | (j,(_,n)) <- zip [0::Int ..] (take i names)] ++
                 [binding "symbol" value | value <- take 1 symbols] ++
                 [binding "seeds" (Expression.vector (if null symbols then hints ++ seeds else [])),
                  binding "base" (construct <> Doc.text "?"),
                  Doc.text (if checked then "Ok(base)" else if customInput inputType
                    then if hasFieldContracts then "Ok(base.map(|base| base.prop_map(Ok).boxed()))" else "Ok(base)"
                    else if hasFieldContracts
                    then "Ok(base.map(|base| ls_gen::seeded(base, seeds).prop_map(Ok).boxed()))"
                    else "Ok(base.map(|base| ls_gen::seeded(base, seeds)))")])) <>
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
        fixed <- forM (maybe (boundaryCases pp) id (finiteCases pp)) $ \values -> do
          callArgs <- mapM valueLiteral values
          -- A law without inputs has one empty case and needs no values.
          pure (block (statements ([context] ++ [binding "values" (Expression.vector callArgs) | not (null callArgs)] ++ [
            statement (invoke law (Doc.text "ctx" :
              [Doc.text ("values[" ++ show i ++ "].clone()") | i <- [0..length names-1]]) <> Doc.text "?")])))
        examples <- forM (propertyExamples p) $ \e -> do
          bindings <- forM (exampleBindings e) $ \(i,x) -> do
            value <- render [] x
            name <- maybe (Left "unbound example input") Right (lookup i names)
            pure (binding name value)
          checks <- mapM (proposition names (label ++ " example " ++ exampleName e)) (exampleExpectations e)
          lawCheck <- proposition names label (propertyBody p)
          pure (block (statements (context : bindings ++ checks ++ [lawCheck])))
        let predicateFn = "valid_" ++ show index
            tupleArgs = [Doc.text ("case.values[" ++ show n ++ "].clone()") | n <- [0..length names-1]]
            random = case finiteCases pp of
              Just _ -> []
              Nothing ->
                [Doc.text "let strategy = proptest::strategy::Just(ls_gen::Case::default()).boxed();"] ++ strategies ++
                [ binding "refinement" (Doc.text "|case: &ls_gen::Case| " <>
                    block (statements ([conditional (Doc.text "case.error.is_some()") (Doc.text "return true;") | hasFieldContracts] ++
                      [conditional (Doc.text ("case.values.len() != " ++ show (length names)))
                        (Doc.text "return false;"),
                      binding "result" (invoke predicateFn (Doc.text "&mut case.context.clone()" : tupleArgs)),
                      Doc.text "result.unwrap_or_else(|e| panic!(\"{e}\"))"])))
                , binding "strategy" (invoke "strategy.prop_filter" [string (label ++ " refinement"),Doc.text "refinement"])
                , binding "config" (Doc.text "proptest::test_runner::Config " <> block (statements
                    ([Doc.text ("cases: " ++ show (cases (propertyGeneration p)) ++ ","),
                     Doc.text ("max_global_rejects: " ++ show (maxAttempts (propertyGeneration p)) ++ ",")] ++
                     [Doc.text ("max_local_rejects: " ++ show (maxAttempts (propertyGeneration p)) ++ ",") | hasFieldContracts] ++
                     [Doc.text ("max_shrink_iters: " ++ show (maxShrinks (propertyGeneration p)) ++ ","),
                     Doc.text "..Default::default()"]) ))
                , binding "check" (Doc.text "|mut case: ls_gen::Case| " <>
                    block (statements ([Doc.text "if let Some(error) = case.error " <> block
                      (Doc.text "return Err(proptest::test_runner::TestCaseError::fail(error));") | hasFieldContracts] ++
                      [binding "result" (invoke law (Doc.text "&mut case.context" : tupleArgs)),
                      Doc.text "result.map_err(proptest::test_runner::TestCaseError::fail)"])))
                , statement (Doc.text "proptest::test_runner::TestRunner::new(config)" <>
                    Doc.nest 4 (Doc.softbreak <> invoke ".run" [Doc.text "&strategy",Doc.text "check"] <>
                      Doc.softbreak <> Doc.text ".map_err(|e| format!(\"{e}\"))?"))
                ]
        pure (Presentation.metadataDocument 100 "//" pp <>
          function law args "ls::Result<()>" (statements (checkedInputs ++ [body,Doc.text "Ok(())"])) <>
          blank <> function predicateFn args "ls::Result<bool>" (statements (valid ++ [Doc.text "Ok(true)"])) <>
          -- Deep generated values need more stack than a test thread has.
          blank <> Doc.text "#[test]" <> Doc.hardline <>
          function ("test_" ++ show index) [] "ls::Result<()>"
            (invoke "ls::with_stack" [Doc.text ("run_" ++ show index)]) <>
          blank <> function ("run_" ++ show index) [] "ls::Result<()>"
            (statements ([context] ++ fixed ++ examples ++ random ++ [Doc.text "Ok(())"])))
      let adapterDoc = statements [Doc.text (if generatedAdapter then "// Generated native bridge by LawSpec. Do not edit." else "// Scaffolded by LawSpec. User-owned; never overwritten."),
            Doc.text "#![allow(unused_variables, unused_imports, non_snake_case)]",
            Doc.text "use crate::lawspec_runtime as ls;"] <>
            (if generatedAdapter && hasNativeTypes then Doc.hardline <> Doc.text "use crate::lawspec_native::*;" else mempty) <>
            (if null stubs then mempty else blank <> Doc.joinWith blank stubs) <> Doc.hardline
          moduleDoc filename name = Doc.text ("#[path = " ++ q filename ++ "]") <> Doc.hardline <> Doc.text ("mod " ++ name ++ ";")
          localImports = [moduleDoc ("../src/" ++ modulePath ++ ".rs") "adapter"] ++
            [moduleDoc "../src/lawspec_data.rs" "lawspec_data" | not (null planDataDeclarations)] ++
            [moduleDoc "../src/lawspec_definitions.rs" "lawspec_definitions" | hasDefinitions] ++
            [moduleDoc "../src/lawspec_runtime.rs" "lawspec_runtime"] ++
            [moduleDoc "../src/lawspec_schema.rs" "lawspec_schema" | hasSchema] ++
            [moduleDoc "support/lawspec_strategies.rs" "ls_gen"]
          imports = case NR.bindingRustCrate bindings of
            Nothing -> localImports
            Just library -> [Doc.text ("use " ++ library ++ "::" ++ testName ++ " as adapter;")] ++
              [Doc.text ("use " ++ library ++ "::lawspec_data;") | not (null planDataDeclarations)] ++
              [moduleDoc "../src/lawspec_definitions.rs" "lawspec_definitions" | hasDefinitions] ++
              [Doc.text ("use " ++ library ++ "::lawspec_runtime;")] ++
              [Doc.text ("use " ++ library ++ "::lawspec_native::*;") | hasNativeTypes] ++
              [Doc.text ("use " ++ library ++ "::lawspec_schema;") | hasSchema] ++
              [moduleDoc "support/lawspec_strategies.rs" "ls_gen"]
          testDoc = statements ([Doc.text "// Generated by LawSpec. Do not edit.",
            Doc.text "#![allow(unused_variables, unused_imports, dead_code)]"] ++ imports ++ generatorModules ++
            [Doc.text "use lawspec_runtime as ls;",Doc.text "use proptest::strategy::Strategy;"]) <>
            blank <> Doc.text ("type ValueStrategy = proptest::strategy::BoxedStrategy<" ++ (if hasFieldContracts then "ls::Result<ls::Value>" else "ls::Value") ++ ">;") <>
            (if hasNativeGenerators then blank <> generatorSupport else mempty) <>
            blank <> Doc.joinWith blank (wrappers ++ tests) <> Doc.hardline
      pure [Artifact ("src/" ++ modulePath ++ ".rs") (Doc.render layout adapterDoc) (if generatedAdapter then "generated" else "user") "source",
        Artifact ("tests/" ++ testName ++ "_lawspec.rs") (Doc.render layout testDoc) "generated" "test"]

-- Test scaffolding retains documents until the complete artifact is laid out.
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
binding :: String -> Doc.Doc -> Doc.Doc
binding name value = statement (Doc.hang 4 (Doc.text ("let " ++ name ++ " =")) value)
borrow :: Doc.Doc -> Doc.Doc
borrow value = Doc.text "&" <> value
conditional :: Doc.Doc -> Doc.Doc -> Doc.Doc
conditional condition body = Doc.text "if " <> condition <> Doc.text " " <> block body
function :: String -> [Doc.Doc] -> String -> Doc.Doc -> Doc.Doc
function name args result body = Doc.text ("fn " ++ name) <>
  Doc.delimitTrailing 4 "(" ")" args <> Doc.text (" -> " ++ result ++ " ") <> block body

valueLiteral :: V.Value -> Either String Doc.Doc
valueLiteral (V.ScalarValue value) = Expression.scalarLiteral value
valueLiteral value@(V.DataValue (Constructor "List" [TypeArgument _]) _ _) = do
  items <- V.listItems value
  values <- mapM valueLiteral items
  let nested item = case item of
        V.DataValue (Constructor "List" _) _ _ -> True
        _ -> False
      names = ["element_" ++ show i | i <- [0 :: Int .. length values - 1]]
      list entries = Doc.text "ls::Value::List(" <> Expression.vector entries <> Doc.text ")"
  pure (if any nested items then Doc.block 4
    (Doc.joinWith Doc.hardline
      ([Doc.hang 4 (Doc.text ("let " ++ name ++ " =")) body <> Doc.text ";"
        | (name,body) <- zip names values] ++ [list (map Doc.text names)]))
    else list values)
valueLiteral (V.DataValue _ tag fields) = do
  values <- mapM valueLiteral fields
  pure (invoke (if builtinConstructor tag then "ls::construct" else "ls::construct_data")
    [string (idText tag),Expression.vector values] <> if builtinConstructor tag then Doc.text "?" else mempty)
valueLiteral (V.PresenceValue (Constructor name [TypeArgument _]) payload) = case payload of
  Nothing -> pure (Expression.presenceValue name Nothing)
  Just x -> do
    value <- valueLiteral x
    pure (Expression.presenceValue name (Just value))
valueLiteral _ = Left "invalid structural literal for Rust"


-- Every scalar, container and data constructor consumes one structural node.
valueBudget :: V.Value -> Integer
valueBudget (V.ScalarValue _) = 1
valueBudget (V.PresenceValue _ Nothing) = 1
valueBudget (V.PresenceValue _ (Just value)) = 1 + valueBudget value
valueBudget value@(V.DataValue (Constructor "List" _) _ _) =
  either (const 1) (\items -> 1 + sum (map valueBudget items)) (V.listItems value)
valueBudget (V.DataValue _ _ fields) = 1 + sum (map valueBudget fields)
