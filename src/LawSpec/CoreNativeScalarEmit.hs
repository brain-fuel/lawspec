module LawSpec.CoreNativeScalarEmit (nativeScalarEmit, nativeScalarEmitWithData, nativeScalarEmitWithDefinitions, nativeScalarEmitWithFormat, nativeScalarEmitWithNativeGenerators, nativeScalarEmitWithAdapterBindings, dataBudget) where
import LawSpec.Collections (isCollectionsType)
import qualified LawSpec.JavaData as JavaData
import qualified LawSpec.JavaExpr as JavaExpr
import qualified LawSpec.JavaTestHelpers as JavaTestHelpers
import qualified LawSpec.JavaProperties as JavaProperties
import qualified LawSpec.GoData as GoData
import qualified LawSpec.GoExpr as GoExpr
import qualified LawSpec.GoTestHelpers as GoTestHelpers
import qualified LawSpec.GoProperties as GoProperties
import qualified LawSpec.HaskellData as HaskellData
import qualified LawSpec.HaskellExpr as HaskellExpr
import qualified LawSpec.HaskellTestHelpers as HaskellTestHelpers
import qualified LawSpec.HaskellProperties as HaskellProperties
import qualified LawSpec.KotlinData as KotlinData
import qualified LawSpec.KotlinExpr as KotlinExpr
import qualified LawSpec.KotlinProperties as KotlinProperties
import qualified LawSpec.KotlinTestHelpers as KotlinTestHelpers
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import LawSpec.Core.Value (toScalarValue)
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core as C
import LawSpec.Scalar
import LawSpec.RuntimeSources
import qualified LawSpec.Code.Doc as Doc
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (intercalate, isPrefixOf, isInfixOf, find)

q :: String -> String
q = T.unpack . T.decodeUtf8 . encode
builtinKey :: Type -> String
builtinKey (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) =
  "Either (" ++ builtinKey a ++ ") (" ++ builtinKey b ++ ")"
builtinKey (Applied n t) = n ++ " " ++ builtinKey t
builtinKey t = prettyType t
nativeScalarEmit :: Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmit = nativeScalarEmitWithData []
nativeScalarEmitWithData :: [C.DataDeclaration] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmitWithData dataDeclarations = nativeScalarEmitWithDefinitions dataDeclarations []
nativeScalarEmitWithDefinitions :: [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmitWithDefinitions = nativeScalarEmitWithFormat False
nativeScalarEmitWithFormat :: Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmitWithFormat = nativeScalarEmitWithNativeGenerators False
nativeScalarEmitWithNativeGenerators :: Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmitWithNativeGenerators = nativeScalarEmitWithAdapterBindings []
nativeScalarEmitWithAdapterBindings :: [(C.Id,String)] -> Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
nativeScalarEmitWithAdapterBindings adapterBindings nativeGenerators minify dataDeclarations definitions bits target u allLaws = do
  if go then either (Left . pure . (\message -> Diagnostic "collision" message Nothing)) Right
    (GoData.validateGoBindings dataDeclarations (map (cap . fst) adapterFunctions)) else pure ()
  tests <- if go then goDocument <$> GoProperties.emitTests goProperties u ls
    else if target == "java" then javaDocument <$> JavaProperties.emitTests javaProperties u ls
    else if kt then ktDocument <$> KotlinProperties.emitTests kotlinProperties u ls
    else if hs then hsDocument <$> HaskellProperties.emitTests haskellProperties u ls
    else concat <$> mapM lawTests (zip [0 :: Int ..] ls)
  wrappers <- if go || kt || hs || target == "java" then pure "" else concat <$> mapM contractWrapper (contracts u)
  goFiles <- if goSchemaNeeded then do
    let emitted = [GoData.emitGoData, GoData.emitGoSchemaWithProfile bits, GoData.emitGoCodecs]
        filenames = ["lawspec_data.go", "lawspec_data_schema.go", "lawspec_data_codecs.go"]
        file placement filename content = Artifact (intercalate "/" parts ++ "/" ++ filename) content "generated" placement
    contents <- mapM (either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right .
      (\emit -> emit (Doc.selectLayout minify (Doc.PrettyTabs 100)) (last parts) dataDeclarations)) emitted
    pure ([file "source" filename content | (filename,content) <- zip filenames contents] ++
      [file placement filename (replace "RUNTIME_PACKAGE" (last parts) (runtimeSource source)) |
        (placement,filename,source) <- [("source","lawspec_schema.go","go-schema"),
          ("source","lawspec_codecs.go","go-codecs"),
          ("test","lawspec_data_strategies_test.go","go-data-strategies")]])
    else pure []
  let completeHeader = if go || kt || hs || target == "java" then "" else if hs then replace "spec :: Spec" (wrappers ++ "spec :: Spec") testHeader else if kt then replace "class " (wrappers ++ "class ") testHeader else (if go && not goSchemaNeeded && not ("rapid.Check" `isInfixOf` tests) then replace "; \"pgregory.net/rapid\"" "" testHeader else testHeader) ++ wrappers
  pure (goFiles ++ [Artifact stubPath stub "user" "source", Artifact testPath (completeHeader ++ tests ++ (if hs || go || kt || target == "java" then "" else if kt then "})\n" else "}\n")) "generated" "test"] ++ [Artifact (intercalate "/" parts ++ "/lawspec_runtime.go") (replace "RUNTIME_PACKAGE" (last parts) (runtimeSource "go")) "generated" "source" | go])
  where
    adapterFunctions = [(n,t) | (n,t) <- functions u,
      C.Id (unitName u ++ "::" ++ n) `notElem` map fst definitions]
    ktCustom = (kt &&) . KotlinData.requiresSchema dataDeclarations
    ktRef = java . KotlinData.kotlinTypeReference
    ktCodec ty = "run { val schema = _schema; val bits = " ++ show bits ++ "; " ++
      java (KotlinData.kotlinCodec dataDeclarations ty) ++ " }"
    ktConstruct ty tag fields = "LawSpecKotlinCodecs.construct(_schema, " ++ ktRef ty ++ ", " ++
      q tag ++ ", listOf(" ++ intercalate ", " fields ++ "), " ++ show bits ++ ")"
    ktDocument = Doc.render (Doc.selectLayout minify (Doc.Pretty 100))
    ktDataHelpers = ktDocument (KotlinTestHelpers.dataHelpersDoc bits kotlinGeneratorDoc <> Doc.hardline <> Doc.hardline)
    hsCustom = (hs &&) . HaskellData.requiresSchema dataDeclarations
    hsRef = java . HaskellData.haskellTypeReference
    hsCodec = replace "schema bits" ("_lawspecSchema " ++ show bits) . java . HaskellData.haskellCodec dataDeclarations
    hsChecked expression = "(either error id (" ++ expression ++ "))"
    hsConstruct ty tag fields = hsChecked ("Schema.construct _lawspecSchema (" ++ hsRef ty ++ ") " ++
      show bits ++ " " ++ q tag ++ " " ++ arr fields)
    hsImports = "import Prelude\nimport qualified Prelude as P\nimport qualified Data.Int as I\nimport qualified Data.Word as W\nimport qualified Data.Text as T\nimport qualified Data.ByteString as B\nimport qualified Data.Complex as C\nimport qualified LawSpecRuntime as LS\nimport qualified LawSpecData as Data\n" ++ hsCollectionImports
    hsSupport = "import qualified LawSpecSchema as Schema\nimport qualified LawSpecDataSchema as DataSchema\nimport qualified LawSpecCodecs as Codec\nimport qualified LawSpecDataCodecs as Codecs\nimport qualified LawSpecDataStrategies as Strategies\n" ++
      (if hsCollections then "import qualified LawSpecCollectionCodecs as Collections\n" else "")
    -- Collections need the containers package; only programs using them import it.
    hsCollections = any (isCollectionsType . C.idText . C.dataId) dataDeclarations
    hsCollectionImports = if hsCollections then "import qualified Data.Set as Set\nimport qualified Data.Map.Strict as Map\nimport qualified Data.Sequence as Seq\n" else ""
    hsDocument = Doc.render (Doc.selectLayout minify (Doc.Pretty 80))
    hsDataHelpers = hsDocument (HaskellTestHelpers.schemaDoc <> Doc.hardline <> Doc.hardline)
    goCustom = (go &&) . GoData.requiresSchema dataDeclarations
    goSchemaNeeded = go && (nativeGenerators || not (null adapterBindings) || not (null definitions) || not (null dataDeclarations) || any (goCustom . snd) (functions u) ||
      any (any (goCustom . inputType) . inputs) ls ||
      any goExpression (concatMap C.contractExpressions (contracts u) ++ concatMap (C.propertyExpressions . original) ls))
    goExpression term | C.AllPayloads _ _ <- C.expressionNode term = True
    goExpression term = goCustom (expressionType term) || any goExpression (C.children term)
    goRef = java . GoData.goTypeReference
    goCodec = replace "schema, bits" ("_lawspecSchema, " ++ show bits) . java . GoData.goCodecWithContext "symbols" dataDeclarations
    goConstruct ty tag fields = "_lawspecSchema.construct(" ++ intercalate ", " [goRef ty,q tag,arr fields,show bits] ++ ")"
    custom (C.Constructor name args) = target == "java" &&
      (any ((== C.Id name) . C.dataId) dataDeclarations || any (\a -> case a of C.TypeArgument t -> custom t; _ -> False) args)
    custom _ = False
    java = either error id
    ref = java . JavaData.javaTypeReference
    codec = java . JavaData.javaCodec dataDeclarations bits
    key t = if ktCustom t then JavaData.javaDataKey t else if goCustom t then GoData.goDataKey t else if custom t then JavaData.javaDataKey t else builtinKey t
    kt = target == "kotlin"
    hs = target == "haskell"
    go = target == "go"
    parts = split (unitName u)
    cls = concatMap cap (splitOn '_' (last parts))
    pkg = intercalate "." (init parts)
    path = intercalate "/" (init parts ++ [cls])
    root = if kt then "kotlin" else "java"
    ext = if kt then ".kt" else ".java"
    stubPath | hs = "src/" ++ intercalate "/" (map hsPart parts) ++ ".hs"
             | go = intercalate "/" parts ++ "/adapter.go"
             | otherwise = "src/main/" ++ root ++ "/" ++ path ++ ext
    testPath | hs = "test/" ++ intercalate "/" (map hsPart parts) ++ "Spec.hs"
             | go = intercalate "/" parts ++ "/lawspec_test.go"
             | otherwise = "src/test/" ++ root ++ "/" ++ path ++ "LawSpecTest" ++ ext
    ls = filter ((== unitName u) . owner) allLaws
    header | go = "package " ++ last parts ++ "\n"
           | hs = "module " ++ intercalate "." (map hsPart parts) ++ " where\n"
           | otherwise = (if null pkg then "" else "package " ++ pkg ++ ";\n") ++ "import lawspec.runtime.LawSpecRuntime;\n" ++ (if kt then "" else "import lawspec.runtime.LawSpecRuntime.Value;\n")
    valueType = if go then "LawSpecValue" else if hs then "Scalar" else if kt then "LawSpecRuntime.Value" else "Value"
    stub | go = Doc.render (Doc.selectLayout minify (Doc.PrettyTabs 100)) $
           Doc.text "// User-owned LawSpec adapter." <> Doc.hardline <>
           Doc.text ("package " ++ last parts) <> Doc.hardline <>
           mconcat [Doc.hardline <> goStubFn n t | (n,t) <- adapterFunctions]
         | hs = Doc.render (Doc.selectLayout minify (Doc.Pretty 80)) $
           Doc.text ("-- User-owned LawSpec adapter.\n" ++ header ++ "\n" ++ hsImports) <>
           Doc.hardline <> Doc.joinWith (Doc.hardline <> Doc.hardline)
             [haskellStubFn n t | (n,t) <- adapterFunctions] <> Doc.hardline
         | target == "java" = Doc.render (Doc.selectLayout minify (Doc.Pretty 100)) $
           Doc.text "// User-owned LawSpec adapter." <> Doc.hardline <>
           (if null pkg then mempty else Doc.text ("package " ++ pkg ++ ";") <> Doc.hardline <> Doc.hardline) <>
           (if any (javaUses "LawSpecRuntime.") (adapterFunctions)
            then Doc.text "import lawspec.runtime.LawSpecRuntime;" <> Doc.hardline else mempty) <>
           (if any javaNeedsValue (adapterFunctions)
            then Doc.text "import lawspec.runtime.LawSpecRuntime.Value;" <> Doc.hardline <> Doc.hardline
           else if any (javaUses "LawSpecRuntime.") (adapterFunctions) then Doc.hardline else mempty) <>
           Doc.text ("public final class " ++ cls ++ " ") <>
           (if null (adapterFunctions) then Doc.text "{}" else
             Doc.block 2 (Doc.joinWith (Doc.hardline <> Doc.hardline) [javaStubFn n t | (n,t) <- adapterFunctions])) <> Doc.hardline
         | otherwise = Doc.render (Doc.selectLayout minify (Doc.Pretty 100)) $
           Doc.text "// User-owned LawSpec adapter." <> Doc.hardline <>
           (if null pkg then mempty else Doc.text ("package " ++ pkg) <> Doc.hardline <> Doc.hardline) <>
           Doc.text "import lawspec.runtime.LawSpecRuntime" <> Doc.hardline <> Doc.hardline <>
           Doc.text ("object " ++ cls ++ " ") <>
           Doc.block 4 (Doc.joinWith (Doc.hardline <> Doc.hardline)
             [kotlinStubFn n t | (n,t) <- adapterFunctions]) <> Doc.hardline
    native t | kt = java (KotlinData.kotlinDataType dataDeclarations t)
    native t | hs = java (HaskellData.haskellDataType dataDeclarations t)
    native t | goCustom t = java (GoData.goDataType dataDeclarations t)
    native t | custom t = java (JavaData.javaDataType dataDeclarations t)
    native (Applied "List" inner) | hs = "[" ++ native inner ++ "]"
    native (Applied "List" inner) | go = "[]" ++ native inner
    native (Applied "List" inner) | kt = "MutableList<" ++ nativeArg inner ++ ">"
    native (Applied "List" inner) | target == "java" = "java.util.List<" ++ boxed (if inner == Named "Unit" then valueType else native inner) ++ ">"
    native (Applied "Maybe" inner) | hs = "(Maybe " ++ native inner ++ ")"
    native (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | hs = "(Either " ++ native a ++ " " ++ native b ++ ")"
    native (Applied "Maybe" inner) | target `elem` ["java","kotlin"] = jvmSumType "Maybe" [nativeField inner]
    native (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | target `elem` ["java","kotlin"] = jvmSumType "Either" (map nativeField [a,b])
    native (Applied "Maybe" inner) | go = "LawSpecMaybe[" ++ nativeField inner ++ "]"
    native (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | go = "LawSpecEither[" ++ nativeField a ++ ", " ++ nativeField b ++ "]"
    native t = maybe valueType id (nativeRepresentation target (key t))
    towerResult t = t == Named "Integer"
    stubResult t | kt && towerResult t = "Number"
                 | hs && towerResult t = "LS.IntegerValue"
                 | otherwise = native t
    nativeField t = if t == Named "Unit" then valueType else native t
    jvmSumType constructor fields = "LawSpecRuntime." ++ constructor ++ "<" ++ intercalate ", " (map (if kt then id else boxed) fields) ++ ">"
    nativeArg t | kt = native t
    nativeArg t | hs = native t
    nativeArg t | goCustom t = native t
    nativeArg t | custom t = native t
    nativeArg (Applied "List" inner) | hs = "[" ++ nativeArg inner ++ "]"
    nativeArg (Applied "List" inner) | go = "[]" ++ nativeArg inner
    nativeArg (Applied "List" inner) | kt = "MutableList<" ++ nativeArg inner ++ ">"
    nativeArg (Applied "List" inner) | target == "java" = "java.util.List<" ++ boxed (nativeArg inner) ++ ">"
    nativeArg (Applied "Maybe" inner) | hs = "(Maybe " ++ nativeArg inner ++ ")"
    nativeArg (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | hs = "(Either " ++ nativeArg a ++ " " ++ nativeArg b ++ ")"
    nativeArg (Applied "Maybe" inner) | target `elem` ["java","kotlin"] = jvmSumType "Maybe" [nativeArg inner]
    nativeArg (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | target `elem` ["java","kotlin"] = jvmSumType "Either" (map nativeArg [a,b])
    nativeArg (Applied "Maybe" inner) | go = "LawSpecMaybe[" ++ nativeArg inner ++ "]"
    nativeArg (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) | go = "LawSpecEither[" ++ nativeArg a ++ ", " ++ nativeArg b ++ "]"
    nativeArg t = if t == Named "Integer" then (if hs then "Integer" else if go then "*LawSpecBigInt" else "java.math.BigInteger") else if t == Named "Unit" && not hs then valueType else native t
    boxed name = maybe name ("java.lang." ++) (lookup name
      [("byte","Byte"),("short","Short"),("int","Integer"),("long","Long"),
       ("float","Float"),("double","Double"),("char","Character"),("boolean","Boolean"),
       ("String","String"),("Number","Number")])
    -- An async adapter's task is awaited where it is called.
    awaitFor name call
      | name `notElem` asyncFunctions u = call
      | go = call <> Doc.text ".Await()"
      | kt = Doc.text "kotlinx.coroutines.runBlocking { " <> call <> Doc.text " }"
      | hs = Doc.text "LS.awaitTask (" <> call <> Doc.text ")"
      | otherwise = call <> Doc.text ".join()"
    goStubFn n t =
      let (args,result) = functionType t
          params = [Doc.text ("value" ++ show i ++ " " ++ nativeArg a) | (i,a) <- zip [0::Int ..] args]
          returnType = if n `elem` asyncFunctions u then " LawSpecTask[" ++ (if result == Named "Unit" then "LawSpecUnit" else native result) ++ "]"
            else if result == Named "Unit" then "" else " " ++ native result
      in Doc.lineComment 100 "// " (cap n ++ " implements " ++ n ++ " :: " ++ prettyType t ++ ".") <>
         Doc.text ("func " ++ cap n) <> Doc.delimitTrailing 8 "(" ")" params <>
         Doc.text (returnType ++ " ") <>
         Doc.block 8 (Doc.text ("panic(" ++ q n ++ ")")) <> Doc.hardline
    javaNeedsValue = javaUses "Value"
    javaUses needle (_,t) =
      let (args,result) = functionType t
      in any (isInfixOf needle) (native result : map nativeArg args)
    javaStubFn n t =
      let (args,result) = functionType t
          params = [Doc.group (javaTypeDoc True False 8 a <> Doc.nest 4 (Doc.softline <> Doc.text ("value" ++ show i))) | (i,a) <- zip [0::Int ..] args]
          asyncStub = n `elem` asyncFunctions u
          resultText = if asyncStub then "java.util.concurrent.CompletableFuture<" ++ boxed (native result) ++ ">" else native result
          flatHeader = "public static " ++ resultText ++ " " ++ n ++ "("
          signature = Doc.group $ if length flatHeader <= 98 || asyncStub
            then Doc.text flatHeader <> Doc.nest 4 (Doc.softbreak <> Doc.group (Doc.commaSep params)) <> Doc.text ") "
            else Doc.text "public static " <> javaTypeDoc False False 8 result <>
              Doc.nest 4 (Doc.softline <> Doc.group (Doc.text (n ++ "(") <>
                Doc.nest 4 (Doc.softbreak <> Doc.group (Doc.commaSep params)) <> Doc.text ") "))
          body = Doc.group $ Doc.text "throw new UnsupportedOperationException(" <>
            Doc.nest 4 (Doc.softbreak <> Doc.text (q (n ++ " -> " ++ prettyType result))) <> Doc.text ");"
      in javaComment (prettyType t) <> Doc.hardline <> signature <> Doc.block 2 body
    javaTypeDoc argument nested indentation t = case t of
      Applied "List" inner -> generic "java.util.List" [inner]
      Applied "Maybe" inner -> generic "LawSpecRuntime.Maybe" [inner]
      C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b] -> generic "LawSpecRuntime.Either" [a,b]
      _ -> Doc.text ((if nested then boxed else id) (if argument then nativeArg t else if nested then nativeField t else native t))
      where
        generic constructor fields = Doc.group $ Doc.text (constructor ++ "<") <>
          Doc.nest indentation (Doc.softbreak <> Doc.group (Doc.commaSep (map (javaTypeDoc argument True 4) fields))) <> Doc.text ">"
    javaComment content = Doc.joinWith Doc.hardline (map (Doc.text . ("// " ++)) (wrap [] (words content)))
      where
        wrap current [] = [unwords current | not (null current)]
        wrap current (word:rest)
          | not (null current) && length (unwords (current ++ [word])) > 95 = unwords current : wrap [word] rest
          | otherwise = wrap (current ++ [word]) rest
    haskellStubFn n t =
      let (args,result) = functionType t
          types = map (Doc.text . nativeArg) args ++
            [Doc.text (if n `elem` asyncFunctions u then "P.IO " ++ parenthesized (stubResult result) else stubResult result)]
          parenthesized text = if ' ' `elem` text && take 1 text /= "(" then "(" ++ text ++ ")" else text
          signature = Doc.group (Doc.text (n ++ " ::") <>
            Doc.nest 2 (Doc.softline <> Doc.joinWith (Doc.softline <> Doc.text "-> ") types))
          body = Doc.group (Doc.text (n ++ concatMap (const " _") args ++ " =") <>
            Doc.nest 2 (Doc.softline <> Doc.text ("error " ++ q n)))
      in Doc.lineComment 80 "-- " (prettyType t) <> signature <> Doc.hardline <> body
    kotlinStubFn n t =
      let (args,result) = functionType t
          typeDoc = java . KotlinData.kotlinDataTypeDoc dataDeclarations
          arguments = [Doc.text ("value" ++ show i ++ ": ") <> typeDoc ty |
            (i,ty) <- zip [0::Int ..] args]
          signature = Doc.text ((if n `elem` asyncFunctions u then "suspend fun " else "fun ") ++ n) <> Doc.delimitTrailing 4 "(" ")" arguments <>
            Doc.text ": " <> (if towerResult result then Doc.text (stubResult result) else typeDoc result)
      in Doc.lineComment 96 "// " (prettyType t) <>
        Doc.group (signature <> Doc.text " =" <>
          Doc.nest 4 (Doc.softline <> Doc.text ("TODO(" ++ quote n ++ ")")))
    testHeader = testHeaderBase ++
      (if target == "java" && javaSchemaNeeded then
        "  private static final lawspec.runtime.LawSpecSchema _schema = lawspec.runtime.LawSpecDataSchema.create();\n" else "") ++
      (if hs || kt then "" else testHelpers) ++
      (if target == "java" && javaSchemaNeeded then javaDataHelpers else "") ++
      (if goSchemaNeeded then goDataHelpers else "")
    testHeaderBase | go = "// Generated by LawSpec.\n" ++ header ++ (if goSchemaNeeded then "import \"fmt\"\n" else "") ++ "import (\"testing\"; \"pgregory.net/rapid\")\n"
               | hs = "-- Generated by LawSpec.\nmodule " ++ intercalate "." (map hsPart parts) ++ "Spec (spec) where\nimport qualified Prelude as P\nimport Prelude\nimport Test.Hspec\nimport Control.Exception (SomeException, catch, displayException)\nimport Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)\nimport Hedgehog (forAll, evalIO, footnote)\nimport qualified Hedgehog.Gen as Gen\nimport qualified Hedgehog.Range as Range\nimport LawSpecRuntime (Scalar(..))\nimport qualified LawSpecRuntime as LS\nimport qualified " ++ intercalate "." (map hsPart parts) ++ " as Impl\n" ++ (if null definitions then "" else "import qualified LawSpecDefinitionBodies as Definitions\n") ++ hsSupport ++ hsDataHelpers ++ testHelpers ++ "spec :: Spec\nspec = do\n"
               | otherwise = "// Generated by LawSpec.\n" ++ header ++ if kt then "import io.kotest.core.spec.style.StringSpec\nimport io.kotest.property.checkAll\nimport io.kotest.property.Arb\nimport io.kotest.property.arbitrary.int\nimport io.kotest.property.arbitrary.boolean\nimport io.kotest.property.arbitrary.float\nimport io.kotest.property.arbitrary.double\nimport lawspec.testing.lawspecList\nimport io.kotest.property.arbitrary.map\nimport io.kotest.property.arbitrary.bind\nimport io.kotest.property.arbitrary.filter\nimport lawspec.testing.lawspecChoice\nimport io.kotest.property.arbitrary.constant\nimport io.kotest.property.arbitrary.element\nimport lawspec.runtime.LawSpecSchema\nimport lawspec.runtime.LawSpecDataSchema\nimport lawspec.runtime.LawSpecDataCodecs\nimport lawspec.runtime.LawSpecKotlinCodecs\nimport lawspec.testing.LawSpecKotlinStrategies\n" ++ testHelpers ++ ktDataHelpers ++ "class " ++ cls ++ "LawSpecTest : StringSpec({\n" else "import org.junit.jupiter.api.Test;\nimport static org.junit.jupiter.api.Assertions.assertTrue;\nimport java.util.*;\nimport org.jetbrains.jetCheck.Generator;\nimport org.jetbrains.jetCheck.PropertyChecker;\npublic final class " ++ cls ++ "LawSpecTest {\n"
    testHelpers
      | hs = hsDocument (HaskellTestHelpers.assertionDoc <> Doc.hardline <> Doc.hardline)
      | go = goDocument GoTestHelpers.assertionDoc
      | kt = ktDocument (KotlinTestHelpers.assertionDoc <> Doc.hardline <> Doc.hardline)
      | otherwise = javaHelperDocument JavaTestHelpers.scalarHelpersDoc
    goDataHelpers = goDocument (GoTestHelpers.dataHelpersDoc bits goGeneratorDoc)
    javaHelperDocument doc = Doc.render (Doc.selectLayout minify (Doc.Pretty 100))
      (Doc.text "  " <> Doc.nest 2 doc <> Doc.hardline <> Doc.hardline)
    javaDataHelpers = javaHelperDocument (JavaTestHelpers.dataHelpersDoc bits javaGeneratorDoc)
    quote = if kt then concatMap (\c -> if c == '$' then "\\$" else [c]) . q else q
    call n args | hs = "(LS." ++ n ++ concatMap (\a -> " (" ++ a ++ ")") args ++ ")"
                | go = "ls" ++ cap n ++ "(" ++ intercalate ", " args ++ ")"
                | otherwise = "LawSpecRuntime." ++ n ++ "(" ++ intercalate ", " args ++ ")"
    arr xs | hs = "[" ++ intercalate ", " xs ++ "]"
           | go = "[]LawSpecValue{" ++ intercalate ", " xs ++ "}"
           | otherwise = (if kt then "arrayOf(" else "new Value[]{") ++ intercalate ", " xs ++ (if kt then ")" else "}")
    scalar s | hs = "(" ++ show s ++ ")"
             | otherwise = case s of
      SInteger t n -> call "integer" [q t,q (show n)]
      SBool b -> call "bool" [if b then "true" else "false"]
      SDecimal c e -> call "decimal" [q (show c),q (show e)]
      SRational n d -> call "rational" [q (show n),q (show d)]
      SFloat t bits' -> call "floating" [q t,q bits']
      SComplex t r i -> call "complex" [q t,scalar r,scalar i]
      SCharacter t c -> call "character" [q t,show c]
      SSequence t xs -> call "sequence" [q t,(if go then "[]int{" else if kt then "intArrayOf(" else "new int[]{") ++ intercalate "," (map show xs) ++ (if kt then ")" else "}")]
      SSymbol i d -> call "symbol" [quote i,quote d,"symbols"]
      SAbsent t -> call "absent" [q t]
      SPresent t v -> call "present" [q t,if go then maybe "nil" (\x -> "lsPointer(" ++ scalar x ++ ")") v else maybe "null" scalar v]
    convert t v | ktCustom t = "_schema.validate(" ++ ktRef t ++ ", " ++ v ++ ", " ++ show bits ++ ")"
    convert t v | hsCustom t = hsChecked ("Schema.validate _lawspecSchema (" ++ hsRef t ++ ") " ++ show bits ++ " (" ++ v ++ ")")
    convert t v | goCustom t = "_lawspecSchema.validate(" ++ goRef t ++ ", " ++ v ++ ", " ++ show bits ++ ")"
    convert t v | custom t = "_schema.validate(" ++ ref t ++ ", " ++ v ++ ", " ++ show bits ++ ")"
    convert t v = call "convert" [q (key t),v,show bits]
    goTypedScalar ty@(Applied _ inner) (SPresent _ payload) =
      call "present" [q (key ty), maybe "nil" (\value -> call "pointer" [goTypedScalar inner value]) payload]
    goTypedScalar _ value = scalar value
    render term | target == "java" = java (Doc.render (Doc.Pretty 100) <$>
      JavaExpr.renderExpression dataDeclarations bits localName javaExternal term)
    render term | go = java (Doc.render Doc.Compact <$>
      GoExpr.renderExpression dataDeclarations bits "_lawspecSchema" localName goExternal term)
    render term | hs = java (Doc.render Doc.Compact <$>
      HaskellExpr.renderExpression dataDeclarations bits "_lawspecSchema" "symbols" localName hsExternal term)
    render term | kt = java (ktDocument <$>
      KotlinExpr.renderExpression dataDeclarations bits localName ktExternal term)
    render term = renderLegacy term
    ktRender = java . KotlinExpr.renderExpression dataDeclarations bits localName ktExternal
    ktChecked ty = java . KotlinExpr.checked dataDeclarations bits ty
    ktNativeArgument ty value = java (KotlinExpr.codec dataDeclarations bits ty) <>
      Doc.text ".decode" <> Doc.delimitTrailing 4 "(" ")" [value]
    -- The abstract Integer result is tower-polymorphic: adapters may return any
    -- integral Number, and the runtime bridge discharges the logical domain.
    ktNativeResult ty value | towerResult ty = KotlinExpr.call "LawSpecRuntime.fromNative"
      [Doc.text (q "Integer"),value,Doc.text (show bits)]
    ktNativeResult ty value = java (KotlinExpr.codec dataDeclarations bits ty) <>
      Doc.text ".encode" <> Doc.delimitTrailing 4 "(" ")" [value]
    ktExternal term values = case C.expressionNode term of
      C.ExternalCall identity _ | Just evaluator <- lookup identity definitions ->
        Right (KotlinExpr.call evaluator (Doc.text "symbols" : values))
      C.ExternalCall identity args ->
        let name = declarationName identity
            typed = zip (map expressionType args) values
        in Right $ if name `elem` map contractName (contracts u)
          then KotlinExpr.call ("_lawspec_call_" ++ name)
            (Doc.text "symbols" : [ktChecked ty value | (ty,value) <- typed])
          else ktNativeResult (expressionType term) (awaitFor name (KotlinExpr.call (cls ++ "." ++ name)
            [ktNativeArgument ty value | (ty,value) <- typed]))
      _ -> Left "expected checked Kotlin external call"
    ktValueLiteral value = case value of
      V.ScalarValue scalarValue -> either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
        (KotlinExpr.scalarLiteral (C.scalarType (scalarName scalarValue)) scalarValue)
      V.DataValue ty tag fields -> do
        rendered <- mapM ktValueLiteral fields
        pure (KotlinExpr.call "LawSpecKotlinCodecs.construct"
          [Doc.text "_schema",java (KotlinExpr.reference ty),KotlinExpr.quoted (C.idText tag),
           KotlinExpr.call "listOf" rendered,Doc.text (show bits),Doc.text "symbols"])
      V.PresenceValue ty payload -> do
        rendered <- traverse ktValueLiteral payload
        pure (KotlinExpr.call "LawSpecRuntime.present" [KotlinExpr.quoted (key ty),
          maybe (Doc.text "null") id rendered])
    kotlinProperties = KotlinProperties.Config
      { KotlinProperties.packageName = pkg
      , KotlinProperties.className = cls
      , KotlinProperties.machineBits = bits
      , KotlinProperties.awaitResult = awaitFor
      , KotlinProperties.constructorContracts = any (not . null . C.constructorPredicates) (concatMap C.dataConstructors dataDeclarations)
      , KotlinProperties.nativeGenerators = nativeGenerators
      , KotlinProperties.nodeBudget = javaDataBudget
      , KotlinProperties.expression = ktRender
      , KotlinProperties.literal = ktValueLiteral
      , KotlinProperties.checked = ktChecked
      , KotlinProperties.structural = ktCustom
      , KotlinProperties.reference = java . KotlinExpr.reference
      , KotlinProperties.typeKey = key
      , KotlinProperties.generator = kotlinGeneratorDoc
      , KotlinProperties.nativeArgument = ktNativeArgument
      , KotlinProperties.nativeResult = ktNativeResult
      }
    hsRender = java . HaskellExpr.renderExpression dataDeclarations bits "_lawspecSchema" "symbols" localName hsExternal
    hsScope = HaskellExpr.apply "P.Just" [Doc.text "symbols"]
    hsCheckedDoc ty value
      | hsCustom ty = HaskellExpr.checked (HaskellExpr.apply "Schema.validateWith"
          [hsScope,Doc.text "_lawspecSchema",java (HaskellData.haskellTypeReferenceDoc ty),Doc.text (show bits),value])
      | otherwise = HaskellExpr.apply "LS.convert" [Doc.text (show (key ty)),value,Doc.text (show bits)]
    hsNativeArgument ty value = HaskellExpr.checked (HaskellExpr.apply "Codec.decode"
      [java (HaskellData.haskellCodecDocWithContext hsScope dataDeclarations "_lawspecSchema" (show bits) ty),value])
    hsNativeResult ty value | towerResult ty = HaskellExpr.apply "LS.fromNative"
      [Doc.text (q "Integer"),value,Doc.text (show bits)]
    hsNativeResult ty value = HaskellExpr.checked (HaskellExpr.apply "Codec.encode"
      [java (HaskellData.haskellCodecDocWithContext hsScope dataDeclarations "_lawspecSchema" (show bits) ty),value])
    hsNativeCall name arguments = case lookup (C.Id (unitName u ++ "::" ++ name)) adapterBindings of
      Just bridge -> HaskellExpr.apply ("Impl." ++ bridge) (Doc.text "symbols" : arguments)
      Nothing -> HaskellExpr.apply ("Impl." ++ name) arguments
    hsCallChecked values invocation =
      let names = ["_lawspecArgument" ++ show i | i <- [0::Int .. length values - 1]]
          bindingsDoc = Doc.joinWith (Doc.text ";" <> Doc.softline)
            [Doc.group (Doc.text (n ++ " =") <> Doc.nest 2 (Doc.softline <> value)) | (n,value) <- zip names values]
          forced = foldr (\n body -> Doc.group (HaskellExpr.apply "LS.forceScalar" [Doc.text n] <>
            Doc.text " `seq`" <> Doc.nest 2 (Doc.softline <> body))) (invocation (map Doc.text names)) names
      in if null names then forced else Doc.group (Doc.text "let {" <> Doc.nest 2 (Doc.softline <> bindingsDoc) <>
        Doc.softline <> Doc.text "} in" <> Doc.nest 2 (Doc.softline <> forced))
    hsExternal term values = case C.expressionNode term of
      C.ExternalCall identity _ | Just evaluator <- lookup identity definitions ->
        Right (HaskellExpr.checked (HaskellExpr.apply evaluator (Doc.text "symbols" : values)))
      C.ExternalCall identity args ->
        let name = declarationName identity
            types = map expressionType args
            converted = zipWith hsCheckedDoc types values
            result = if name `elem` map contractName (contracts u)
              then hsCallChecked converted (\names -> HaskellExpr.apply ("_lawspec_call_" ++ name) (Doc.text "symbols" : names))
              else hsNativeResult (expressionType term) (hsCallChecked converted (\names ->
                awaitFor name (hsNativeCall name (zipWith hsNativeArgument types names))))
        in Right $ if any hsNativeMachine (expressionType term : types)
          then Doc.group (HaskellExpr.apply "LS.checkMachineBits" [Doc.text (show bits)] <> Doc.text " `seq`" <>
            Doc.nest 2 (Doc.softline <> result))
          else result
      _ -> Left "expected checked Haskell external call"
    hsValueLiteral value = case value of
      V.ScalarValue scalarValue -> pure (HaskellExpr.apply "LS.scopeSymbols"
        [Doc.text "symbols",HaskellExpr.scalarLiteral scalarValue])
      V.DataValue (C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM hsValueLiteral items
        pure (HaskellExpr.apply "SList" [HaskellExpr.array rendered])
      V.DataValue ty tag fields -> do
        rendered <- mapM hsValueLiteral fields
        pure (HaskellExpr.checked (HaskellExpr.apply "Schema.constructWith"
          [hsScope,Doc.text "_lawspecSchema",java (HaskellData.haskellTypeReferenceDoc ty),Doc.text (show bits),
           HaskellExpr.quoted (C.idText tag),HaskellExpr.array rendered]))
      V.PresenceValue (C.Constructor wrapper _) payload -> do
        rendered <- traverse hsValueLiteral payload
        pure (HaskellExpr.apply "SPresent" [Doc.text (show wrapper),
          maybe (Doc.text "Nothing") (HaskellExpr.apply "Just" . pure) rendered])
      _ -> Left [Diagnostic "target" "unsupported Haskell structural literal" Nothing]
    haskellProperties = HaskellProperties.Config
      { HaskellProperties.moduleName = intercalate "." (map hsPart parts)
      , HaskellProperties.nativeGenerators = nativeGenerators
      , HaskellProperties.hasDefinitions = not (null definitions)
      , HaskellProperties.awaitResult = awaitFor
      , HaskellProperties.constructorContracts = any (not . null . C.constructorPredicates) (concatMap C.dataConstructors dataDeclarations)
      , HaskellProperties.usesCollections = hsCollections
      , HaskellProperties.nodeBudget = javaDataBudget
      , HaskellProperties.reference = java . HaskellData.haskellTypeReferenceDoc
      , HaskellProperties.machineBits = bits
      , HaskellProperties.expression = hsRender
      , HaskellProperties.literal = hsValueLiteral
      , HaskellProperties.checked = hsCheckedDoc
      , HaskellProperties.structural = containsStructural
      , HaskellProperties.typeKey = key
      , HaskellProperties.generator = hsGeneratorDoc
      , HaskellProperties.nativeArgument = hsNativeArgument
      , HaskellProperties.nativeCall = hsNativeCall
      , HaskellProperties.nativeResult = hsNativeResult
      }
    goChecked ty value
      | goCustom ty = GoExpr.call "_lawspecSchema.validate" [Doc.text (goRef ty),value,Doc.text (show bits),Doc.text "symbols"]
      | otherwise = GoExpr.call "lsConvert" [GoExpr.quoted (key ty),value,Doc.text (show bits)]
    goNativeArgument ty value
      | not (null adapterBindings) = GoExpr.call (goCodec ty ++ ".toNative") [value]
      | goCustom ty = GoExpr.call (goCodec ty ++ ".toNative") [value]
      | ty == Named "Unit" = value
      | Nothing <- nativeRepresentation target (key ty) = GoExpr.call "lsClone" [goChecked ty value]
      | otherwise = GoExpr.call "lsToNative" [GoExpr.quoted (key ty),value,Doc.text (show bits)] <>
          Doc.text (".(" ++ nativeArg ty ++ ")")
    goNativeResult ty invocation
      | goCustom ty = GoExpr.call (goCodec ty ++ ".fromNative") [invocation]
      | ty == Named "Unit" = Doc.text "func() LawSpecValue " <> Doc.block 8
          (invocation <> Doc.hardline <> Doc.text "return lsAbsent(\"Unit\")") <> Doc.text "()"
      | not (null adapterBindings) = GoExpr.call (goCodec ty ++ ".fromNative") [invocation]
      | otherwise = GoExpr.call "lsFromNative" [GoExpr.quoted (key ty),invocation,Doc.text (show bits)]
    goRender term = java (GoExpr.renderExpression dataDeclarations bits "_lawspecSchema" localName goExternal term)
    goValueLiteral value = case value of
      V.ScalarValue scalarValue -> either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
        (GoExpr.scalarLiteral (C.scalarType (scalarName scalarValue)) scalarValue)
      V.DataValue ty@(C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM goValueLiteral items
        pure (GoExpr.call "lsList" [GoExpr.quoted (key ty),GoExpr.array rendered])
      V.DataValue ty tag fields -> do
        rendered <- mapM goValueLiteral fields
        pure (GoExpr.call "_lawspecSchema.construct"
          [Doc.text (goRef ty),GoExpr.quoted (C.idText tag),GoExpr.array rendered,Doc.text (show bits),Doc.text "symbols"])
      V.PresenceValue ty payload -> do
        rendered <- traverse goValueLiteral payload
        pure (GoExpr.call "lsPresent" [GoExpr.quoted (key ty),
          maybe (Doc.text "nil") (GoExpr.call "lsPointer" . pure) rendered])
    goProperties = GoProperties.Config
      { GoProperties.packageName = last parts
      , GoProperties.schemaNeeded = goSchemaNeeded
      , GoProperties.awaitResult = awaitFor
      , GoProperties.constructorContracts = any (not . null . C.constructorPredicates) (concatMap C.dataConstructors dataDeclarations)
      , GoProperties.nativeGenerators = nativeGenerators
      , GoProperties.nodeBudget = javaDataBudget
      , GoProperties.machineBits = bits
      , GoProperties.expression = goRender
      , GoProperties.literal = goValueLiteral
      , GoProperties.checked = goChecked
      , GoProperties.structural = goCustom
      , GoProperties.reference = Doc.text . goRef
      , GoProperties.typeKey = key
      , GoProperties.generator = goGeneratorDoc
      , GoProperties.nativeFunction = goAdapterName
      , GoProperties.nativeArgument = goNativeArgument
      , GoProperties.nativeResult = goNativeResult
      }
    goAdapterName n = maybe (cap n) id (lookup (C.Id (unitName u ++ "::" ++ n)) adapterBindings)
    goExternal term values = case C.expressionNode term of
      C.ExternalCall identity _ | Just evaluator <- lookup identity definitions ->
        Right (GoExpr.call evaluator (Doc.text "symbols" : values))
      C.ExternalCall identity args ->
        let n = declarationName identity
            typed = zip (map expressionType args) values
        in Right $ if n `elem` map contractName (contracts u)
          then GoExpr.call ("_lawspec_call_" ++ n) (Doc.text "symbols" : [goChecked ty v | (ty,v) <- typed])
          else goNativeResult (expressionType term) (awaitFor n (GoExpr.call (goAdapterName n) [goNativeArgument ty v | (ty,v) <- typed]))
      _ -> Left "expected checked Go external call"
    javaDocument = Doc.render (Doc.selectLayout minify (Doc.Pretty 100))
    javaRender term = java (JavaExpr.renderExpression dataDeclarations bits localName javaExternal term)
    javaRuntime name = JavaExpr.call ("LawSpecRuntime." ++ name)
    javaRef = java . JavaExpr.reference
    javaChecked ty value
      | custom ty = JavaExpr.call "_schema.validate" [javaRef ty,value,Doc.text (show bits),Doc.text "symbols"]
      | otherwise = javaRuntime "convert" [JavaExpr.quoted (key ty),value,Doc.text (show bits)]
    javaMethod value name args = Doc.group (Doc.nest 4 value <>
      Doc.nest 4 (Doc.softbreak <> JavaExpr.call ("." ++ name) args))
    javaNativeArgument ty value
      | custom ty = javaMethod (java (JavaData.javaCodecDocWithContext (Doc.text "symbols") dataDeclarations bits ty)) "decode" [value]
      | ty == Named "Unit" = value
    javaNativeArgument ty@(Applied name inner) value | name `elem` ["List","Maybe"] =
      let local = "_element" ++ show (length (key ty))
      in javaRuntime (if name == "List" then "listToNative" else "maybeToNative")
        [JavaExpr.quoted (key ty),value,Doc.text (show bits),
         Doc.group (Doc.text (local ++ " ->") <> Doc.nest 4 (Doc.softline <> javaNativeArgument inner (Doc.text local)))]
    javaNativeArgument ty@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) value =
      let local = "_element" ++ show (length (key ty))
      in javaRuntime "eitherToNative" ([JavaExpr.quoted (key ty),value,Doc.text (show bits)] ++
        [Doc.group (Doc.text (local ++ " ->") <> Doc.nest 4 (Doc.softline <> javaNativeArgument inner (Doc.text local))) | inner <- [a,b]])
    javaNativeArgument ty value = case nativeRepresentation target (key ty) of
      Nothing -> javaChecked ty value
      Just _ -> Doc.group (Doc.text ("((" ++ nativeArg ty ++ ")") <>
        Doc.nest 4 (Doc.softline <> javaRuntime "toNative" [JavaExpr.quoted (key ty),value,Doc.text (show bits)]) <> Doc.text ")")
    javaNativeResult ty invocation
      | custom ty = javaMethod (java (JavaData.javaCodecDocWithContext (Doc.text "symbols") dataDeclarations bits ty)) "encode" [invocation]
      | ty == Named "Unit" = javaRuntime "unit" [Doc.text "() -> " <> invocation]
      | otherwise = javaRuntime "fromNative" [JavaExpr.quoted (key ty),invocation,Doc.text (show bits)]
    javaValueLiteral value = case value of
      V.ScalarValue scalarValue -> either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
        (JavaExpr.scalarLiteral (C.scalarType (scalarName scalarValue)) scalarValue)
      V.DataValue ty@(C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM javaValueLiteral items
        pure (javaRuntime "list" [JavaExpr.quoted (key ty),JavaExpr.call "java.util.List.of" rendered])
      V.DataValue ty tag fields -> do
        rendered <- mapM javaValueLiteral fields
        pure $ if custom ty then JavaExpr.call "_schema.construct"
          [javaRef ty,JavaExpr.quoted (C.idText tag),JavaExpr.call "java.util.List.of" rendered,Doc.text (show bits),Doc.text "symbols"]
          else javaRuntime "construct" [JavaExpr.quoted (key ty),JavaExpr.quoted (C.idText tag),JavaExpr.array rendered]
      V.PresenceValue ty payload -> do
        rendered <- traverse javaValueLiteral payload
        pure (javaRuntime "present" [JavaExpr.quoted (key ty),maybe (Doc.text "null") id rendered])
    javaSchemaNeeded = nativeGenerators || not (null dataDeclarations) || any payloadExpression
      (concatMap C.contractExpressions (contracts u) ++ concatMap (C.propertyExpressions . original) ls)
    payloadExpression term = case C.expressionNode term of
      C.AllPayloads _ _ -> True
      _ -> any payloadExpression (C.children term)
    javaProperties = JavaProperties.Config
      { JavaProperties.packageName = pkg
      , JavaProperties.className = cls
      , JavaProperties.schemaNeeded = javaSchemaNeeded
      , JavaProperties.nativeGenerators = nativeGenerators
      , JavaProperties.machineBits = bits
      , JavaProperties.constructorContracts = any (not . null . C.constructorPredicates) (concatMap C.dataConstructors dataDeclarations)
      , JavaProperties.nodeBudget = javaDataBudget
      , JavaProperties.awaitResult = awaitFor
      , JavaProperties.expression = javaRender
      , JavaProperties.literal = javaValueLiteral
      , JavaProperties.checked = javaChecked
      , JavaProperties.structural = containsStructural
      , JavaProperties.custom = custom
      , JavaProperties.reference = javaRef
      , JavaProperties.typeKey = key
      , JavaProperties.generator = javaGeneratorDoc
      , JavaProperties.nativeArgument = javaNativeArgument
      , JavaProperties.nativeResult = javaNativeResult
      }
    javaExternal term values = case C.expressionNode term of
      C.ExternalCall identity _ | Just evaluator <- lookup identity definitions ->
        Right (JavaExpr.call evaluator (Doc.text "symbols" : values))
      C.ExternalCall identity args ->
        let n = declarationName identity
            typed = zip (map expressionType args) values
        in Right $ if n `elem` map contractName (contracts u)
          then JavaExpr.call ("_lawspec_call_" ++ n) (Doc.text "symbols" : [javaChecked ty v | (ty,v) <- typed])
          else javaNativeResult (expressionType term) (awaitFor n (JavaExpr.call (cls ++ "." ++ n) [javaNativeArgument ty v | (ty,v) <- typed]))
      _ -> Left "expected checked Java external call"
    renderLegacy term = case C.expressionNode term of
      C.Local n -> localName n
      C.Constant s -> convert (expressionType term) ((if go then goTypedScalar (expressionType term) else scalar) s)
      C.Construct tag fields | hsCustom (expressionType term) -> hsConstruct (expressionType term) (C.idText tag) (map render fields)
      C.Construct tag fields | goCustom (expressionType term) -> goConstruct (expressionType term) (C.idText tag) (map render fields)
      C.Construct tag fields | custom (expressionType term), C.idText tag `notElem` ["List::Nil", "List::Cons"] ->
        "_schema.construct(" ++ ref (expressionType term) ++ ", " ++ q (C.idText tag) ++ ", java.util.List.of(" ++ intercalate ", " (map render fields) ++ "), " ++ show bits ++ ")"
      C.Construct tag fields -> call "construct" ([q (key (expressionType term)) | not hs] ++ [q (C.idText tag),arr (map render fields)])
      C.Match scrutinee branches | go -> goMatch scrutinee branches
      C.Match scrutinee branches | target `elem` ["java","kotlin"] -> jvmMatch scrutinee branches
      C.Match scrutinee branches -> "(case " ++ convert (expressionType scrutinee) (render scrutinee) ++ " of { " ++
        intercalate "; " (map renderBranch branches) ++ "; _ -> error \"invalid constructor in match\" })"
      C.Convert C.CheckedArgument t e -> convert t (render e)
      C.Convert C.Explicit t e -> call "helper" [q (key t),arr [render e],show bits]
      C.ShortCircuit op a b -> call "bool" ["(" ++ call "truth" [render a] ++ (if op == C.And then " && " else " || ") ++ call "truth" [render b] ++ ")"]
      C.Unary C.Not a -> call "bool" [(if hs then "not (" else "!(") ++ call "truth" [render a] ++ ")"]
      C.Binary op _ a b | hsCustom (expressionType a) -> call "bool"
        [(if op == C.NotEqual then "not " else "") ++ hsChecked ("Schema.equal _lawspecSchema (" ++
          hsRef (expressionType a) ++ ") " ++ show bits ++ " (" ++ render a ++ ") (" ++ render b ++ ")")]
      C.Binary op _ a b | goCustom (expressionType a) -> call "bool"
        [(if op == C.NotEqual then "!" else "") ++ "_lawspecSchema.equal(" ++ intercalate ", " [goRef (expressionType a),render a,render b,show bits] ++ ")"]
      C.Binary op _ a b | custom (expressionType a) -> call "bool"
        [(if op == C.NotEqual then "!" else "") ++ "_schema.equal(" ++ ref (expressionType a) ++ ", " ++ render a ++ ", " ++ render b ++ ", " ++ show bits ++ ")"]
      C.Binary op _ a b -> call "binary" [q (C.binaryName op),render a,render b]
      C.Unary C.Negate a -> call "helper" [q "negate",arr [render a],show bits]
      C.Helper builtin args -> call "helper" [q (C.builtinName builtin),arr (map render args),show bits]
      C.ExternalCall decl args ->
        let n = declarationName decl
            t = expressionType term
            values = [convert (expressionType a) (render a) | a <- args]
            callee = if hs then "Impl." ++ n else if go then cap n else cls ++ "." ++ n
            invocation = if hs then checkedHsCall values (\names -> callee ++
              concat [" (" ++ nativeValue (expressionType a) n' ++ ")" | (a,n') <- zip args names])
              else callee ++ "(" ++ intercalate ", " (map adapterArg args) ++ ")"
            result = if n `elem` map contractName (contracts u)
              then if hs then checkedHsCall values (\names -> "_lawspec_call_" ++ n ++ " symbols" ++ concatMap (\v -> " (" ++ v ++ ")") names)
                else "_lawspec_call_" ++ n ++ "(" ++ intercalate ", " ("symbols":values) ++ ")"
              else wrapResult t invocation
        in if hs && any hsNativeMachine (t : map expressionType args)
             then "(LS.checkMachineBits " ++ show bits ++ " `seq` " ++ result ++ ")"
             else result
    hsNativeMachine (Named name) = name `elem` ["IntSize","UIntSize","UIntPtr"]
    hsNativeMachine (C.Constructor name arguments) | name `elem` ["List","Maybe","Either"] =
      any (\argument -> case argument of C.TypeArgument t -> hsNativeMachine t; _ -> False) arguments
    hsNativeMachine _ = False
    goMatch scrutinee branches | goCustom (expressionType scrutinee),
      C.Constructor name _ <- expressionType scrutinee, name /= "List" =
      "func() LawSpecValue { _lawspecData := " ++ convert (expressionType scrutinee) (render scrutinee) ++ "; " ++
      "_lawspecFields := _lawspecData.Data.(lawSpecData); switch _lawspecFields.tag { " ++
      concat ["case " ++ q (C.idText (C.caseConstructor branch)) ++ ": " ++
        concat [localName (C.binderId binder) ++ " := _lawspecFields.fields[" ++ show index ++ "]; _ = " ++ localName (C.binderId binder) ++ "; " |
          (index,binder) <- zip [0::Int ..] (C.caseBinders branch)] ++
        "return " ++ render (C.caseBody branch) ++ "; " | branch <- branches] ++
      "default: panic(\"invalid checked match constructor\") } }()"
    goMatch scrutinee branches | Applied "Maybe" _ <- expressionType scrutinee =
      goSumMatch "matchMaybe" ["Maybe::Nothing","Maybe::Just"] scrutinee branches
    goMatch scrutinee branches | C.Constructor "Either" _ <- expressionType scrutinee =
      goSumMatch "matchEither" ["Either::Left","Either::Right"] scrutinee branches
    goMatch scrutinee branches = case (find ((== C.Id "List::Nil") . C.caseConstructor) branches,
                                       find ((== C.Id "List::Cons") . C.caseConstructor) branches) of
      (Just nilBranch,Just consBranch) | [headBinder,tailBinder] <- C.caseBinders consBranch ->
        "func() LawSpecValue { _lawspecValue := " ++ render scrutinee ++ "; _lawspecItems, _lawspecOK := _lawspecValue.Data.([]LawSpecValue); " ++
        "if !_lawspecOK { panic(\"List required in match\") }; if len(_lawspecItems) == 0 { return " ++ render (C.caseBody nilBranch) ++ " }; " ++
        localName (C.binderId headBinder) ++ " := _lawspecItems[0]; " ++ localName (C.binderId tailBinder) ++ " := lsList(" ++ q (key (expressionType scrutinee)) ++ ", _lawspecItems[1:]); " ++
        "_ = " ++ localName (C.binderId headBinder) ++ "; _ = " ++ localName (C.binderId tailBinder) ++ "; return " ++ render (C.caseBody consBranch) ++ " }()"
      _ -> error "unsupported Go match"
    goSumMatch helperName tags scrutinee branches =
      let branch tag = case find ((== C.Id tag) . C.caseConstructor) branches of
            Nothing -> error "missing checked Go match branch"
            Just matched -> "func(" ++ intercalate ", " [localName (C.binderId binder) ++ " LawSpecValue" | binder <- C.caseBinders matched] ++
              ") LawSpecValue { return " ++ render (C.caseBody matched) ++ " }"
      in call helperName (render scrutinee : map branch tags)
    jvmMatch scrutinee branches | custom (expressionType scrutinee),
      C.Constructor name _ <- expressionType scrutinee,
      any ((== C.Id name) . C.dataId) dataDeclarations =
      let dataName = "_data" ++ show (length (show (scrutinee, branches)))
          branch matched = "case " ++ q (C.idText (C.caseConstructor matched)) ++ " -> { " ++
            concat ["var " ++ localName (C.binderId binder) ++ " = " ++ dataName ++ ".fields().get(" ++ show i ++ "); "
              | (i,binder) <- zip [0::Int ..] (C.caseBinders matched)] ++
            "yield " ++ render (C.caseBody matched) ++ "; }"
      in "_schema.match(" ++ ref (expressionType scrutinee) ++ ", " ++ render scrutinee ++ ", " ++ show bits ++ ", " ++ dataName ++
         " -> { return switch (" ++ dataName ++ ".tag()) { " ++ concatMap branch branches ++
         " default -> throw new IllegalArgumentException(\"invalid constructor\"); }; })"
    jvmMatch scrutinee branches =
      let (helperName,tags) = case expressionType scrutinee of
            Applied "List" _ -> ("matchList", ["List::Nil","List::Cons"])
            Applied "Maybe" _ -> ("matchMaybe", ["Maybe::Nothing","Maybe::Just"])
            C.Constructor "Either" _ -> ("matchEither", ["Either::Left","Either::Right"])
            _ -> error "unsupported JVM match"
          branch tag = case find ((== C.Id tag) . C.caseConstructor) branches of
            Nothing -> error "missing checked JVM match branch"
            Just matched -> jvmLambda (map (localName . C.binderId) (C.caseBinders matched)) (render (C.caseBody matched))
      in call helperName (render scrutinee : map branch tags)
    jvmLambda names body = if kt
      then "{ " ++ (if null names then "" else intercalate ", " names ++ " -> ") ++ body ++ " }"
      else "(" ++ intercalate ", " names ++ ") -> " ++ body
    checkedHsCall values invocation =
      let names = ["_lawspecArgument" ++ show i | i <- [0::Int .. length values - 1]]
          bindings' = intercalate "; " [n ++ " = " ++ value | (n,value) <- zip names values]
      in "(" ++ (if null values then "" else "let { " ++ bindings' ++ " } in ") ++
         concat ["LS.forceScalar " ++ n ++ " `seq` " | n <- names] ++ invocation names ++ ")"
    renderBranch branch = case (C.idText (C.caseConstructor branch),C.caseBinders branch) of
      ("List::Nil",[]) -> "SList [] -> " ++ render (C.caseBody branch)
      ("List::Cons",[headBinder,tailBinder]) ->
        "SList (" ++ localName (C.binderId headBinder) ++ ":_lawspecTail) -> let " ++
        localName (C.binderId tailBinder) ++ " = SList _lawspecTail in " ++ render (C.caseBody branch)
      ("Maybe::Nothing",[]) -> "SData \"Maybe::Nothing\" [] -> " ++ render (C.caseBody branch)
      (tag,[binder]) | tag `elem` ["Maybe::Just","Either::Left","Either::Right"] ->
        "SData " ++ q tag ++ " [" ++ localName (C.binderId binder) ++ "] -> " ++ render (C.caseBody branch)
      (tag,binders) -> "SData " ++ q tag ++ " [" ++ intercalate ", " (map (localName . C.binderId) binders) ++
        "] -> " ++ render (C.caseBody branch)
    wrapResult t invocation
      | (kt || hs) && towerResult t = call "fromNative" [q "Integer",invocation,show bits]
      | kt = ktCodec t ++ ".encode(" ++ invocation ++ ")"
      | hs = hsChecked ("Codec.encode (" ++ hsCodec t ++ ") (" ++ invocation ++ ")")
      | goCustom t = goCodec t ++ ".fromNative(" ++ invocation ++ ")"
      | custom t = codec t ++ ".encode(" ++ invocation ++ ")"
      | t == Named "Unit" && not hs =
          if go then "func() LawSpecValue { " ++ invocation ++ "; return lsAbsent(\"Unit\") }()"
          else if kt then "run { " ++ invocation ++ "; LawSpecRuntime.absent(\"Unit\") }" else "LawSpecRuntime.unit(() -> " ++ invocation ++ ")"
      | otherwise = call "fromNative" [q (key t),invocation,show bits]
    adapterArg a = nativeValue (expressionType a) (render a)
    nativeValue t value | kt = ktCodec t ++ ".decode(" ++ value ++ ")"
    nativeValue t value | hs = hsChecked ("Codec.decode (" ++ hsCodec t ++ ") (" ++ value ++ ")")
    nativeValue t value | goCustom t = goCodec t ++ ".toNative(" ++ value ++ ")"
    nativeValue t value | custom t = codec t ++ ".decode(" ++ value ++ ")"
    nativeValue t value | t == Named "Unit" && not hs = value
    nativeValue t@(Applied "List" inner) value | go =
      "lsListToNative[" ++ nativeArg inner ++ "](" ++ q (key t) ++ ", " ++ value ++ ", " ++ show bits ++
      ", func(_element LawSpecValue) " ++ nativeArg inner ++ " { return " ++ nativeValue inner "_element" ++ " })"
    nativeValue t@(Applied "List" inner) value | kt =
      let element = "_element" ++ show (length (key t))
      in call "listToNative" [q (key t),value,show bits,"{ " ++ element ++ " -> " ++ nativeValue inner element ++ " }"]
    nativeValue t@(Applied "List" inner) value | target == "java" =
      let element = "_element" ++ show (length (key t))
      in call "listToNative" [q (key t),value,show bits,element ++ " -> " ++ nativeValue inner element]
    nativeValue t@(Applied "Maybe" inner) value | target `elem` ["java","kotlin"] =
      let element = "_element" ++ show (length (key t))
      in call "maybeToNative" [q (key t),value,show bits,jvmLambda [element] (nativeValue inner element)]
    nativeValue t@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) value | target `elem` ["java","kotlin"] =
      let element = "_element" ++ show (length (key t))
      in call "eitherToNative" ([q (key t),value,show bits] ++ [jvmLambda [element] (nativeValue inner element) | inner <- [a,b]])
    nativeValue t@(Applied "Maybe" inner) value | go =
      "lsMaybeToNative[" ++ nativeArg inner ++ "](" ++ q (key t) ++ ", " ++ value ++ ", " ++ show bits ++
      ", func(_element LawSpecValue) " ++ nativeArg inner ++ " { return " ++ nativeValue inner "_element" ++ " })"
    nativeValue t@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) value | go =
      "lsEitherToNative[" ++ nativeArg a ++ ", " ++ nativeArg b ++ "](" ++ intercalate ", "
        ([q (key t),value,show bits] ++ ["func(_element LawSpecValue) " ++ nativeArg inner ++ " { return " ++ nativeValue inner "_element" ++ " }" | inner <- [a,b]]) ++ ")"
    nativeValue t value | kt = ktCodec t ++ ".decode(" ++ value ++ ")"
    nativeValue t value | hs = call "toNative" [q (key t),value,show bits]
    nativeValue t value = case nativeRepresentation target (key t) of
      Nothing -> if go then "lsClone(" ++ convert t value ++ ")" else convert t value
      Just _ -> let nativeType = nativeArg t; converted = call "toNative" [q (key t),value,show bits] in
        if hs then converted else if go then converted ++ ".(" ++ nativeType ++ ")" else if kt then "(" ++ converted ++ " as " ++ nativeType ++ ")" else "((" ++ nativeType ++ ") " ++ converted ++ ")"
    assign n v | hs = "    let " ++ n ++ " = " ++ v ++ "\n"
               | go = "    " ++ n ++ " := " ++ v ++ "; _ = " ++ n ++ "\n"
               | otherwise = "    " ++ (if kt then "val " else "var ") ++ n ++ " = " ++ v ++ ";\n"
    code indent context proposition = case proposition of
      AssertAll ps -> concat <$> mapM (code indent context) ps
      AssertImplies g body -> do
        rest <- code (indent ++ "  ") context body
        pure (if hs then indent ++ "if " ++ call "truth" [render g] ++ " then do\n" ++ rest ++ indent ++ "else pure ()\n" else indent ++ "if (" ++ call "truth" [render g] ++ ") {\n" ++ rest ++ indent ++ "}\n")
      AssertEqual a b ->
        let av = render a; bv = render b; explanation = context ++ " | expect " ++ prettyExpr a ++ " = " ++ prettyExpr b in
        pure $ indent ++ if hs then "_lawspecAssert " ++ quote explanation ++ " (" ++ convert (expressionType a) av ++ ") (" ++ convert (expressionType b) bv ++ ")\n"
          else if go && goCustom (expressionType a) then "_lawspecDataAssert(" ++ quote explanation ++ ", " ++ goRef (expressionType a) ++ ", func() LawSpecValue { return " ++ av ++ " }, func() LawSpecValue { return " ++ bv ++ " })\n"
          else if go then "_lawspecAssert(t, " ++ quote explanation ++ ", func() LawSpecValue { return " ++ av ++ " }, func() LawSpecValue { return " ++ bv ++ " })\n"
          else if kt && ktCustom (expressionType a) then "_lawspecDataAssert(" ++ quote explanation ++ ", " ++ ktRef (expressionType a) ++ ", { " ++ av ++ " }, { " ++ bv ++ " })\n"
          else if kt then "_lawspecAssert(" ++ quote explanation ++ ", { " ++ av ++ " }, { " ++ bv ++ " })\n"
          else "_lawspecAssert(" ++ quote explanation ++ (if custom (expressionType a) then ", " ++ ref (expressionType a) else "") ++ ", () -> " ++ av ++ ", () -> " ++ bv ++ ");\n"
    block n body | hs = "  it " ++ q n ++ " $ do\n    symbols <- LS.newSymbolContext\n" ++ body
                 | go = "func Test" ++ cap n ++ "(t *testing.T) {\n    symbols := map[string]*lawSpecSymbol{}; _ = symbols\n" ++ body ++ "}\n"
                 | kt = "  " ++ q n ++ " {\n    val symbols = mutableMapOf<String, Any>();\n" ++ body ++ "  }\n"
                 | otherwise = "  @Test " ++ (if kt then "fun " ++ n ++ "()" else "void " ++ n ++ "()") ++ " {\n" ++ (if kt then "    val symbols = mutableMapOf<String, Any>();\n" else "    var symbols = new HashMap<String,Object>();\n") ++ body ++ "  }\n"
    boundaries (Named n) = scalarBoundaries bits n
    boundaries (Applied n t) = SPresent n Nothing : map (SPresent n . Just) (boundaries t)
    boundaries _ = []
    valueLiteral value | hs = case value of
      V.ScalarValue s -> Right ("(LS.scopeSymbols symbols " ++ scalar s ++ ")")
      V.DataValue (C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM valueLiteral items
        pure ("(SList " ++ arr rendered ++ ")")
      V.DataValue ty tag fields -> do
        rendered <- mapM valueLiteral fields
        pure (hsConstruct ty (C.idText tag) rendered)
      V.PresenceValue (C.Constructor wrapper _) payload -> do
        field <- traverse valueLiteral payload
        pure ("(SPresent " ++ q wrapper ++ " " ++ maybe "Nothing" (\v -> "(Just " ++ v ++ ")") field ++ ")")
      _ -> Left [Diagnostic "target" "unsupported Haskell structural literal" Nothing]
    valueLiteral value | go = case value of
      V.DataValue t@(C.Constructor name _) tag fields | goCustom t && name /= "List" -> do
        rendered <- mapM valueLiteral fields
        pure (goConstruct t (C.idText tag) rendered)
      V.DataValue t@(C.Constructor name _) tag fields | custom t && name /= "List" -> do
        rendered <- mapM valueLiteral fields
        pure ("_schema.construct(" ++ ref t ++ ", " ++ q (C.idText tag) ++ ", java.util.List.of(" ++ intercalate ", " rendered ++ "), " ++ show bits ++ ")")
      V.DataValue t@(C.Constructor name _) tag fields | name `elem` ["Maybe","Either"] -> do
        rendered <- mapM valueLiteral fields
        pure (call "construct" [q (key t),q (C.idText tag),arr rendered])
      V.ScalarValue s -> Right (scalar s)
      V.DataValue t@(C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM valueLiteral items
        pure (call "list" [q (key t),arr rendered])
      V.PresenceValue ty@(C.Constructor _ _) payload -> do
        field <- traverse valueLiteral payload
        pure (call "present" [q (key ty), maybe "nil" (\v -> call "pointer" [v]) field])
      _ -> Left [Diagnostic "target" "unsupported Go structural literal" Nothing]
    valueLiteral value | target `elem` ["java","kotlin"] = case value of
      V.DataValue t tag fields | ktCustom t -> do
        rendered <- mapM valueLiteral fields
        pure (ktConstruct t (C.idText tag) rendered)
      V.DataValue t@(C.Constructor name _) tag fields | custom t && name /= "List" -> do
        rendered <- mapM valueLiteral fields
        pure ("_schema.construct(" ++ ref t ++ ", " ++ q (C.idText tag) ++ ", java.util.List.of(" ++ intercalate ", " rendered ++ "), " ++ show bits ++ ")")
      V.DataValue t@(C.Constructor name _) tag fields | name `elem` ["Maybe","Either"] -> do
        rendered <- mapM valueLiteral fields
        pure (call "construct" [q (key t),q (C.idText tag),arr rendered])
      V.ScalarValue s -> Right (scalar s)
      V.DataValue t@(C.Constructor "List" _) _ _ -> do
        items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
        rendered <- mapM valueLiteral items
        pure (call "list" [q (key t),(if kt then "listOf(" else "java.util.List.of(") ++ intercalate ", " rendered ++ ")"])
      V.PresenceValue t@(C.Constructor wrapper _) payload -> do
        field <- traverse valueLiteral payload
        pure (call "present" [q (key t),maybe "null" id field])
      _ -> Left [Diagnostic "target" "unsupported Java structural literal" Nothing]
    valueLiteral value = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) (Right . scalar) (toScalarValue value)
    containsStructural t | ktCustom t = True
    containsStructural t | hsCustom t = True
    containsStructural t | goCustom t = True
    containsStructural t | custom t = True
    containsStructural (C.Constructor name args) = name `elem` ["List","Maybe","Either"] ||
      any (\arg -> case arg of C.TypeArgument inner -> containsStructural inner; _ -> False) args
    containsStructural _ = False
    hsGeneratorDoc = HaskellTestHelpers.generatorDoc bits javaDataBudget hsCustom
      (java . HaskellData.haskellTypeReferenceDoc) key
    -- Legacy compatibility templates retain inline parentheses; the main
    -- property document emitter consumes hsGeneratorDoc directly.
    hsGenerator = Doc.render Doc.Compact . HaskellExpr.parens . hsGeneratorDoc
    hsStructuralProperty label e check =
      let names = arr (map inputId (inputs e))
          predicates = [call "truth" [render predicate] | input <- inputs e, predicate <- inputRefinements input]
          base = "fmap (map (LS.scopeSymbols symbols)) (sequence " ++ arr (map (hsGenerator . inputType) (inputs e)) ++ ")"
          gen = if null predicates then base else "Gen.filter (\\" ++ names ++ " -> " ++ conjunction predicates ++ ") (" ++ base ++ ")"
      in "  modifyMaxSuccess (const " ++ show (cases (generation e)) ++ ") $ it " ++ q (label ++ " property") ++ " $ hedgehog $ do\n" ++
         "    symbols <- evalIO LS.newSymbolContext\n    " ++ names ++ " <- forAll (" ++ gen ++ ")\n    footnote " ++ q label ++ "\n    evalIO $ do\n" ++
         unlines ["  " ++ line | line <- lines check]
    goDocument = Doc.render (Doc.selectLayout minify (Doc.PrettyTabs 100))
    goGeneratorDoc = GoTestHelpers.generatorDoc bits javaDataBudget goCustom (Doc.text . goRef)
    goGenerator = goDocument . goGeneratorDoc
    goStructuralProperty fn label e check =
      let draws = concat ["      " ++ inputId input ++ " := " ++ goGenerator (inputType input) ++ ".Draw(t, " ++ q (inputId input) ++ ");\n" | input <- inputs e]
          names = arr (map inputId (inputs e))
          bindings' = concat ["    " ++ inputId input ++ " := _values[" ++ show i ++ "]; _ = " ++ inputId input ++ ";\n" | (i,input) <- zip [0::Int ..] (inputs e)]
          predicates = [call "truth" [render p] | input <- inputs e, p <- inputRefinements input]
          generator = "rapid.Custom(func(t *rapid.T) []LawSpecValue {\n" ++ draws ++ "      return " ++ names ++ "\n    })" ++
            (if null predicates then "" else ".Filter(func(_values []LawSpecValue) bool {\n" ++ bindings' ++ "      return " ++ conjunction predicates ++ "\n    })")
      in "func Test" ++ cap fn ++ "Property(t *testing.T) {\n  rapid.Check(t, func(t *rapid.T) {\n    symbols := map[string]*lawSpecSymbol{}; _ = symbols\n" ++
         "    _values := " ++ generator ++ ".Draw(t, " ++ q label ++ ")\n" ++ bindings' ++ check ++ "  })\n}\n"
    kotlinGeneratorDoc = KotlinTestHelpers.generatorDoc bits javaDataBudget ktCustom (java . KotlinExpr.reference) key
    kotlinGenerator = ktDocument . kotlinGeneratorDoc
    kotlinStructuralProperty label e check =
      let bindings' = concat ["    val " ++ inputId input ++ " = _inputs.first[" ++ show i ++ "]\n" | (i,input) <- zip [0::Int ..] (inputs e)]
          predicates = [call "truth" [render p] | input <- inputs e, p <- inputRefinements input]
          tuple = foldl (\prior input -> "Arb.bind(" ++ prior ++ ", " ++ kotlinGenerator (inputType input) ++ ") { _values, _value -> _values + _value }")
            "Arb.constant(emptyList<LawSpecRuntime.Value>())" (inputs e)
          generator = tuple ++ ".map { _values -> Pair(_values, mutableMapOf<String, Any>()) }" ++
            (if null predicates then "" else ".filter { _inputs -> val symbols = _inputs.second\n" ++ bindings' ++ "    " ++ conjunction predicates ++ "\n }")
      in "  " ++ quote (label ++ " property") ++ " {\n    checkAll(" ++ show (cases (generation e)) ++ ", " ++ generator ++ ") { _inputs ->\n" ++
         "    val symbols = _inputs.second\n" ++ bindings' ++ check ++ "    }\n  }\n"
    javaDataBudget = dataBudget allLaws
    javaGeneratorDoc = JavaTestHelpers.generatorDoc bits javaDataBudget (cls ++ "LawSpecTest") custom
      (java . JavaExpr.reference) key
    javaGenerator = Doc.render (Doc.selectLayout minify (Doc.Pretty 100)) . javaGeneratorDoc
    javaStructuralProperty fn e check =
      let bindings' = concat ["    var " ++ inputId input ++ " = _inputs.values().get(" ++ show i ++ ");\n" | (i,input) <- zip [0::Int ..] (inputs e)]
          predicates = [call "truth" [render p] | input <- inputs e, p <- inputRefinements input]
          values = "java.util.List.of(" ++ intercalate ", " ["_environment.<Value>generate(" ++ javaGenerator (inputType input) ++ ")" | input <- inputs e] ++ ")"
          generator = "Generator.from(_environment -> new _LawSpecInputs(" ++ values ++ ", new HashMap<String,Object>()))" ++
            (if null predicates then "" else ".suchThat(_inputs -> { var symbols = _inputs.symbols();\n" ++ bindings' ++ "    return " ++ conjunction predicates ++ "; })")
      -- JetCheck deduplicates generation trees. Its default size hint cycles at
      -- 100, which exhausts distinct lengths for lists of singleton elements.
      -- Grow the native list budget with iterations, with room for generator
      -- wrappers and retries; keep JetCheck's own list shrinking intact.
      in "  @Test void " ++ fn ++ "Property() {\n    PropertyChecker.customized().withIterationCount(" ++ show (cases (generation e)) ++ ").withSizeHint(_iteration -> (int) Math.min(java.lang.Integer.MAX_VALUE, 2L * _iteration + 8)).forAll(" ++ generator ++
         ", _inputs -> {\n    var symbols = _inputs.symbols();\n" ++ bindings' ++ check ++ "    return true;\n    });\n  }\n"
    lawTests (i,e) = do
      let label = owner e ++ "::" ++ name e; fn = "law" ++ show i
      exs <- concat <$> mapM (\(j,ex) -> do
        let assignments = [assign n (render v) | (n,v) <- bindings ex]
        expectedChecks <- concat <$> mapM (code "    " (label ++ " example " ++ exampleName ex)) (expectations ex)
        lawCheck <- code "    " label (assertion e)
        pure (block (fn ++ "Example" ++ show j) (concat assignments ++ expectedChecks ++ lawCheck))) (zip [0 :: Int ..] (examples (original e)))
      let finite = finiteCases e
          cases' = maybe (boundaryCases e) id finite
      boundariesTests <- concat <$> mapM (\(j,vs) -> do
        values <- mapM valueLiteral vs
        check <- code "    " (label ++ " boundary " ++ show j) (assertion e)
        pure (block (fn ++ "Boundary" ++ show j) (concat [assign (inputId inp) (convert (inputType inp) v) | (inp,v) <- zip (inputs e) values] ++ check))) (zip [0 :: Int ..] cases')
      propertyCheck <- code "    " (label ++ " property") (assertion e)
      let assignments = concat [assign (inputId inp) (call "sample" [q (key (inputType inp)),if go then "int(seed) + " ++ show j else if hs then "seed + " ++ show j else "seed + " ++ show j,show bits]) | (j,inp) <- zip [0 :: Int ..] (inputs e)]
          propertyBody = assignments ++ propertyCheck
          propertyTest
            | target == "java" && any (containsStructural . inputType) (inputs e) = javaStructuralProperty fn e propertyCheck
            | go && any (containsStructural . inputType) (inputs e) = goStructuralProperty fn label e propertyCheck
            | hs && any (containsStructural . inputType) (inputs e) = hsStructuralProperty label e propertyCheck
            | hs = hsStructuralProperty label e propertyCheck
            | go = "func Test" ++ cap fn ++ "Property(t *testing.T) { rapid.Check(t, func(t *rapid.T) {\n    seed := rapid.Int32().Draw(t, \"seed\"); _ = seed\n    symbols := map[string]*lawSpecSymbol{}; _ = symbols\n" ++ propertyBody ++ "}) }\n"
            | kt && any (containsStructural . inputType) (inputs e) = kotlinStructuralProperty label e propertyCheck
            | kt = kotlinStructuralProperty label e propertyCheck
            | otherwise = "  @Test void " ++ fn ++ "Property() { PropertyChecker.forAll(Generator.integers(), seed -> {\n    var symbols = new HashMap<String,Object>();\n" ++ propertyBody ++ "    return true;\n  }); }\n"
      refined <- if (hs || go || target `elem` ["java","kotlin"]) && any (containsStructural . inputType) (inputs e)
        then pure (if hs then hsStructuralProperty label e propertyCheck else if go then goStructuralProperty fn label e propertyCheck else if kt then kotlinStructuralProperty label e propertyCheck else javaStructuralProperty fn e propertyCheck)
        else refinedProperty fn label e propertyCheck
      pure (metadata (if hs then "--" else "//") e ++ exs ++ boundariesTests ++ if maybe False (const True) finite then "" else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract" then refined else propertyTest)
    conjunction [] = if hs then "True" else "true"
    conjunction xs = intercalate " && " ["(" ++ x ++ ")" | x <- xs]
    contractWrapper c = do
      let args = contractArguments c
          (rn,rt) = contractResult c
          invoke = (if hs then "Impl." else if go then "" else cls ++ ".") ++ (if go then cap (contractName c) else contractName c) ++
            (if hs then concatMap (\(n,t) -> " (" ++ nativeValue t n ++ ")") args
             else "(" ++ intercalate ", " [nativeValue t n | (n,t) <- args] ++ ")")
          result = wrapResult rt invoke
          context stage ps = contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map prettyExpr ps)
          symbolParam = if go then "symbols map[string]*lawSpecSymbol" else if kt then "symbols: MutableMap<String, Any>" else "Map<String,Object> symbols"
          params = symbolParam:[if go then n ++ " LawSpecValue" else if kt then n ++ ": LawSpecRuntime.Value" else "Value " ++ n | (n,_) <- args]
      let pre = [call "truth" [render v] | v <- contractPreconditions c]
          post = [call "truth" [render v] | v <- contractPostconditions c]
      let preContext = context "precondition" (contractPreconditions c); postContext = context "postcondition" (contractPostconditions c)
      pure $ if hs then "_lawspec_call_" ++ contractName c ++ " :: LS.SymbolContext -> " ++ intercalate " -> " (replicate (length args+1) "Scalar") ++ "\n_lawspec_call_" ++ contractName c ++ " symbols" ++ concatMap ((" " ++) . fst) args ++ " =\n  LS.contract " ++ quote preContext ++ " (" ++ conjunction pre ++ ") $\n    let " ++ rn ++ " = " ++ result ++ "\n    in " ++ rn ++ " `seq` LS.contract " ++ quote postContext ++ " (" ++ conjunction post ++ ") " ++ rn ++ "\n"
        else (if go then "func " else if kt then "private fun " else "  private static Value ") ++ "_lawspec_call_" ++ contractName c ++ "(" ++ intercalate ", " params ++ ")" ++ (if go then " LawSpecValue" else if kt then ": LawSpecRuntime.Value" else "") ++ " {\n" ++
          "    " ++ call "requireContract" [conjunction pre,quote preContext] ++ ";\n" ++ assign rn result ++ "    " ++ call "requireContract" [conjunction post,quote postContext] ++ ";\n    return " ++ rn ++ ";\n  }\n"
    domainCode e (index,plan) = do
      scalarSeeds <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (mapM toScalarValue (generatorBoundaries plan))
      let inp=domainInput plan; prior=take index (inputs e)
          bindings' xs = concat [if hs then inputId i ++ " = _values !! " ++ show j ++ "; " else if go then inputId i ++ " := _values[" ++ show j ++ "]; _ = " ++ inputId i ++ "; " else if kt then "val " ++ inputId i ++ " = _values[" ++ show j ++ "]; " else "var " ++ inputId i ++ " = _values.get(" ++ show j ++ "); " | (j,i) <- zip [0::Int ..] xs]
          lambda xs seed value = if hs then "(\\_values" ++ (if seed then " _seed" else "") ++ " -> " ++ (if null xs then "" else "let { " ++ bindings' xs ++ "} in ") ++ value ++ ")"
            else if go then "func(_values []LawSpecValue" ++ (if seed then ", _seed int" else "") ++ ") " ++ (if seed then "[]LawSpecValue" else "bool") ++ " { " ++ bindings' xs ++ "return " ++ value ++ " }"
            else if kt then "{ _values" ++ (if seed then ", _seed" else "") ++ " -> " ++ bindings' xs ++ value ++ " }"
            else "(_values" ++ (if seed then ", _seed" else "") ++ ") -> { " ++ bindings' xs ++ "return " ++ value ++ "; }"
      bs <- mapM (\(op,v) -> let value = render v in pure (if hs then "(" ++ q op ++ "," ++ value ++ ")" else if go then "{" ++ q op ++ "," ++ value ++ "}" else (if kt then "LawSpecRuntime.Bound(" else "new LawSpecRuntime.Bound(") ++ q op ++ "," ++ value ++ ")")) (domainBounds plan)
      let hints = map render (generatorHints plan)
          ps = [call "truth" [render v] | v <- inputRefinements inp]
      let restrictions = (if hs then "[" else if go then "[]lawSpecBound{" else if kt then "arrayOf(" else "new LawSpecRuntime.Bound[]{") ++ intercalate "," bs ++ (if hs then "]" else if kt then ")" else "}")
          candidates = call "domainCandidates" [q (key (inputType inp)),"_seed",show bits,restrictions,arr (map scalar scalarSeeds ++ hints)]
      pure $ if hs then "LS.Domain " ++ lambda prior True candidates ++ " " ++ lambda (prior++[inp]) False (conjunction ps)
        else (if go then "lawSpecDomain{" else if kt then "LawSpecRuntime.Domain(" else "new LawSpecRuntime.Domain(") ++ lambda prior True candidates ++ ", " ++ lambda (prior++[inp]) False (conjunction ps) ++ (if go then "}" else ")")
    refinedProperty fn label e check = do
      ds <- mapM (domainCode e) (zip [0::Int ..] (generationPlan e))
      let cfg=generation e
          domains = (if hs then "[" else if go then "[]lawSpecDomain{" else if kt then "arrayOf(" else "new LawSpecRuntime.Domain[]{") ++ intercalate ", " ds ++ (if hs then "]" else if kt then ")" else "}")
          binds = concat [assign (inputId inp) (if hs then "_values !! " ++ show j else if go || kt then "_values[" ++ show j ++ "]" else "_values.get(" ++ show j ++ ")") | (j,inp) <- zip [0::Int ..] (inputs e)]
          callback = if hs then "_check"
                     else if go then "func(_values []LawSpecValue) {\n" ++ binds ++ check ++ "  }"
                     else if kt then "{ _values ->\n" ++ binds ++ check ++ "  }"
                     else "_values -> {\n" ++ binds ++ check ++ "  }"
          invocation = call "refinedCase" [domains,"seed",show (maxAttempts cfg),show (maxShrinks cfg),callback,quote (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))]
      pure $ if hs then "  modifyMaxSuccess (const " ++ show (cases cfg) ++ ") $ it " ++ q (label ++ " property") ++ " $ hedgehog $ do\n    seed <- forAll (Gen.int (Range.linear 0 2147483647))\n    footnote " ++ q label ++ "\n    let _check _values = do\n" ++ unlines ["      " ++ line | line <- lines (binds ++ check)] ++ "    evalIO $ " ++ invocation ++ "\n"
        else if go then "func Test" ++ cap fn ++ "Property(t *testing.T) {\n    defer func(){if err:=recover();err!=nil{t.Fatalf(\"%v\",err)}}()\n    for seed := 0; seed < " ++ show (cases cfg) ++ "; seed++ {\n    symbols := map[string]*lawSpecSymbol{}; _ = symbols\n    " ++ invocation ++ "\n  }\n}\n"
        else if kt then "  " ++ q (label ++ " property") ++ " { checkAll(" ++ show (cases cfg) ++ ", Arb.int()) { seed ->\n    val symbols = mutableMapOf<String, Any>();\n    " ++ invocation ++ "\n  } }\n"
        else "  @Test void " ++ fn ++ "Property() { PropertyChecker.customized().withIterationCount(" ++ show (cases cfg) ++ ").forAll(Generator.integers(), seed -> {\n    var symbols = new HashMap<String,Object>();\n    " ++ invocation ++ ";\n    return true;\n  }); }\n"
    hsPart = concatMap cap . splitOn '_'
    split = splitOn '.'
    splitOn c s = case break (== c) s of (a,[]) -> [a]; (a,_:b) -> a:splitOn c b
    cap [] = []
    cap (c:cs) = (if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c):cs

replace :: String -> String -> String -> String
replace old new text | old `isPrefixOf` text = new ++ replace old new (drop (length old) text)
replace _ _ [] = []
replace old new (c:cs) = c:replace old new cs

-- Java's generated data budget: the largest boundary value of any law in the
-- program, so every unit's tests size their generators alike.
dataBudget :: [Expanded] -> Integer
dataBudget laws = maximum (64 : [valueNodes v | law <- laws, tuple <- boundaryCases law, v <- tuple])
  where
    valueNodes (V.DataValue _ _ fields) = 1 + sum (map valueNodes fields)
    valueNodes (V.PresenceValue _ payload) = 1 + maybe 0 valueNodes payload
    valueNodes _ = 1
