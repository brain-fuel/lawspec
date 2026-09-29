-- Framework-native strategies are mapped, never sampled by generated helpers.
module LawSpec.RustNativeGenerators (emitGenerators, generatorImports, emitGeneratorStubs) where

import Control.Monad (forM, unless)
import Data.List (stripPrefix, nub, isPrefixOf)
import Data.Char (toLower, isAlphaNum)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.RustExpr as E
import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.RustNativeBinding as B
import LawSpec.RustData (rustDataType)

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 4 "(" ")" args

-- Local support modules are shared by the integration-test crates. Application
-- and external-crate factories remain imports unless a scaffold is requested.
localParts :: ResolvedGeneratorBinding -> [String]
localParts binding = case referenceParts (resolvedGeneratorFactory binding) of
  prefix:rest | prefix `elem` ["crate","self"] -> rest
  parts -> parts

localRoots :: BindingPlan -> [String]
localRoots plan = nub [root | binding <- resolvedGenerators (bindingRepresentations plan),
  root:_:_ <- [localParts binding], resolvedGeneratorStub binding || root == "lawspec_generators" ||
    case referenceParts (resolvedGeneratorFactory binding) of
      prefix:_ -> prefix `elem` ["crate","self"]
      _ -> False]

generatorImports :: BindingPlan -> Either String [D.Doc]
generatorImports plan = forM (localRoots plan) $ \root -> do
  name <- B.rustReference (NativeRef [root])
  pure (D.text ("#[path = \"support/" ++ root ++ ".rs\"]") <> D.hardline <>
    D.text ("mod " ++ name ++ ";"))

-- User-owned factories always use the readable layout. Signatures describe the
-- application representation, including generic parameters, without copying or
-- replacing Proptest's native strategy implementation.
emitGeneratorStubs :: [C.DataDeclaration] -> BindingPlan -> Either String [Artifact]
emitGeneratorStubs declarations plan = do
  let requested = filter resolvedGeneratorStub (resolvedGenerators (bindingRepresentations plan))
  case requested of
    [] -> pure []
    _ -> do
      library <- maybe (Left "Rust generator scaffolds require rustCrate") Right (bindingRustCrate plan)
      let roots = nub [root | binding <- requested, root:_ <- [localParts binding]]
          reserved = words "crate self super Self std core alloc proptest ls ls_gen adapter lawspec_runtime lawspec_schema lawspec_data lawspec_native lawspec_definitions lawspec_strategies Vec Option String Box Result Strategy ValueStrategy"
      unless (length (localRoots plan) == length (nub (map (map toLower) (localRoots plan))))
        (Left "Rust generator scaffold modules collide on a case-insensitive filesystem")
      mapM_ (\binding -> do
        let parts = localParts binding
        unless (length parts >= 2 && head parts `notElem` (library:reserved))
          (Left "Rust generator scaffold requires a dedicated local test module and factory")
        unless (all (`notElem` [library,"std","proptest","Vec","Option"])
          (drop 1 (init parts)))
          (Left "Rust generator scaffold namespace shadows a signature dependency")
        _ <- B.rustReference (NativeRef parts)
        pure ()) requested
      let paths = map localParts requested
          allPaths = map localParts (resolvedGenerators (bindingRepresentations plan))
      unless (all (\a -> length (filter (== a) allPaths) == 1 &&
        not (any (\b -> a /= b && (a `isPrefixOf` b || b `isPrefixOf` a)) allPaths)) paths)
        (Left "Rust generator scaffold factory conflicts with another factory or module")
      entries <- forM requested $ \binding -> do
        let parameters = [(C.Id ("scaffold::" ++ show i), "T" ++ show i) |
              i <- [0 .. generatorParameterCount binding - 1]]
            ty = C.Constructor (C.idText (resolvedGeneratorType binding))
              [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
            parts = localParts binding
        native <- B.nativeTypeWithParameters declarations plan parameters ty
        name <- B.rustReference (NativeRef [last parts])
        let result = replaceTypePrefix "ls::" (library ++ "::lawspec_runtime::")
              (replaceTypePrefix "crate::" (library ++ "::") native)
            generic = if null parameters then mempty else D.delimitTrailing 4 "<" ">"
              [D.text (parameter ++ ": std::fmt::Debug + 'static") | (_,parameter) <- parameters]
            arguments = [D.text ("_argument_" ++ show i ++ ": proptest::strategy::BoxedStrategy<" ++ parameter ++ ">") |
              (i,(_,parameter)) <- zip [0::Int ..] parameters]
            body = D.text ("pub fn " ++ name) <> generic <> D.delimitTrailing 4 "(" ")" arguments <>
              D.text (" -> proptest::strategy::BoxedStrategy<" ++ result ++ "> ") <>
              D.block 4 (D.text "unimplemented!" <> D.delimit 4 "(" ")"
                [E.stringLiteral ("Implement generator for " ++ C.idText (resolvedGeneratorType binding))])
        pure (parts,body)
      let emit entries = do
            modules <- forM (nub [part | (part:_:_,_) <- entries]) $ \name -> do
              rendered <- B.rustReference (NativeRef [name])
              body <- emit [(rest,body) | (part:rest,body) <- entries, part == name]
              pure (D.text ("pub mod " ++ rendered ++ " ") <> D.block 4 body)
            pure (D.joinWith (D.hardline <> D.hardline) ([body | ([_],body) <- entries] ++ modules))
      forM roots $ \root -> do
        body <- emit [(rest,body) | (part:rest,body) <- entries, part == root]
        pure (Artifact ("tests/support/" ++ root ++ ".rs")
          (D.render (D.Pretty 100) (D.text "// User-owned native generator factories. Implement before running properties." <>
            D.hardline <> D.text "#![allow(dead_code)]" <> D.hardline <> D.hardline <>
            body <> D.hardline)) "user" "test")

-- Rewrite only the leading component of a type path, not an identically named
-- component inside an application module (or the suffix of a longer identifier).
replaceTypePrefix :: String -> String -> String -> String
replaceTypePrefix old new = walk True
  where
    walk boundary text
      | boundary, Just suffix <- stripPrefix old text = new ++ walk False suffix
      | c:rest <- text = c : walk (not (isAlphaNum c || c `elem` ("_#:" :: String))) rest
      | otherwise = []

emitGenerators :: [C.DataDeclaration] -> BindingPlan -> [C.Type] -> Either String D.Doc
emitGenerators declarations plan roots = do
  concrete <- if any ((>0) . generatorParameterCount)
      (resolvedGenerators (bindingRepresentations plan))
    then reachableGeneratorTypes declarations (bindingRepresentations plan) roots else pure []
  let generators = zip [0::Int ..] (resolvedGenerators (bindingRepresentations plan))
      testType text = case bindingRustCrate plan of
        Nothing -> text
        Just library -> replaceTypePrefix "crate::" (library ++ "::") text
  functions <- forM generators $ \(index,generator) -> do
    factory <- B.rustReference (resolvedGeneratorFactory generator)
    let identity = C.idText (resolvedGeneratorType generator)
        instances = if generatorParameterCount generator == 0 then [C.Constructor identity []]
          else [ty | ty@(C.Constructor name _) <- concrete, name == identity]
    branches <- forM instances $ \ty -> do
      let arguments = case ty of C.Constructor _ args -> [child | C.TypeArgument child <- args]; _ -> []
      children <- forM (zip [0::Int ..] arguments) $ \(i,child) -> do
        canonicalChild <- rustDataType declarations child
        nativeChild <- testType <$> B.nativeTypeFor declarations plan child
        converted <- B.convertExpression declarations plan True child (D.text "canonical")
        let checked = D.text "schema.native_value_with_context(value, &ty, bits, &mut context.clone()).unwrap_or_else(|e| panic!(\"native generator argument: {e}\"))"
            decoded = if child == C.scalarType "CodeUnit16"
              then D.text "match checked { ls::Value::CodeUnit16(value) => value, _ => panic!(\"native generator argument: expected CodeUnit16\") }"
              else D.text ("<" ++ canonicalChild ++ " as ls::FromValue>::from_value(checked).unwrap_or_else(|e| panic!(\"native generator argument: {e}\"))")
        pure (D.text ("let child" ++ show i ++ ": proptest::strategy::BoxedStrategy<" ++ nativeChild ++ "> = ") <>
          D.block 4 (D.joinWith D.hardline
            [D.text "let schema = _schema.clone();", D.text ("let ty = arguments[" ++ show i ++ "].clone();"),
             D.text "let bits = _bits;", D.text "let context = _context.clone();",
             D.text "children.remove(0).prop_map(move |value| " <> D.block 4
               (D.text "let checked = " <> checked <> D.text ";" <> D.hardline <>
                D.text ("let canonical: " ++ canonicalChild ++ " = ") <> decoded <> D.text ";" <> D.hardline <>
                converted) <> D.text ").boxed()"] ) <> D.text ";")
      nativeType <- testType <$> B.nativeTypeFor declarations plan ty
      canonicalType <- rustDataType declarations ty
      converted <- B.convertExpression declarations plan False ty (D.text "native")
      reference <- E.reference ty
      let encoded = if ty == C.scalarType "CodeUnit16" then "ls::Value::CodeUnit16(value)"
                    else "ls::IntoValue::into_value(value)"
          body = D.joinWith D.hardline
            ([D.text "ls::require_architecture(_bits)?;" | usesMachineRepresentation declarations ty] ++
             [D.text ("if children.len() != " ++ show (length arguments) ++ " { return Err(\"unexpected native generator arguments\".into()); }"),
              D.text "let ls::TypeRef::Named(_, arguments) = _ty else { return Err(\"uninstantiated native generator type\".into()); };" ] ++ children ++
             [D.text ("let strategy: proptest::strategy::BoxedStrategy<" ++ nativeType ++ "> = ") <>
                call factory [D.text ("child" ++ show i) | i <- [0..length arguments-1]] <> D.text ".boxed();",
              D.text "Ok(strategy.prop_map(|native| " <> D.block 4
                (D.text ("let value: " ++ canonicalType ++ " = ") <> converted <> D.text ";" <>
                 D.hardline <> D.text encoded) <> D.text ").boxed())"])
      pure (D.text "_ if _ty == &" <> reference <> D.text " => " <> D.block 4 body <> D.text ",")
    pure (D.text ("fn _lawspec_native_generator_" ++ show index) <>
      D.delimitTrailing 4 "(" ")" (map D.text
        ["_schema: &ls::Schema", "_ty: &ls::TypeRef", "_bits: u32", "_context: &ls::Context",
         "mut children: Vec<proptest::strategy::BoxedStrategy<ls::Value>>"]) <>
      D.text " -> ls::Result<proptest::strategy::BoxedStrategy<ls::Value>> " <>
      D.block 4 (D.text "match _ty " <> D.block 4 (D.joinWith D.hardline (branches ++
        [D.text "_ => Err(format!(\"unplanned native generator instantiation: {_ty:?}\")),"]))))
  let entries = [D.text ("(" ++ show (C.idText (resolvedGeneratorType generator)) ++
        ", _lawspec_native_generator_" ++ show index ++ " as ls_gen::NativeFactory)") |
        (index,generator) <- generators]
      registry = D.text "fn _lawspec_native_generators() -> ls::Result<ls_gen::NativeGenerators> " <>
        D.block 4 (call "ls_gen::NativeGenerators::new"
          [D.text "vec!" <> D.delimitTrailing 4 "[" "]" entries])
  pure (D.joinWith (D.hardline <> D.hardline) (registry:functions))
