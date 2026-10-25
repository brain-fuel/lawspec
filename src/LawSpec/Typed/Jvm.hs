-- | Typed Java for checked definitions (see LawSpec.Typed.Plan), shared by the
-- Java and Kotlin targets: lawspec.runtime.LawSpecTyped holds a Java class
-- per typed data type and a static method per class of typed definitions,
-- over lawspec.runtime.LawSpecFast's persistent structures. Bounded integers
-- are longs, Integer a BigInteger and Text a String; codecs convert to and
-- from the dynamic Value where typed and dynamic code meet.
-- ref:DEC-typed-native-definitions
module LawSpec.Typed.Jvm (jvmPerformName, JvmTyped(..), JvmStyle(..), emitJvmTyped, jvmScalars) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, toUpper)
import Data.Binary (Binary)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.CorePersist ()
import LawSpec.Memo (Table, newPersistentTable, memoized)
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as Context
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Core.Positional (positionalLabel)
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.JavaData as JavaData
import qualified LawSpec.KotlinData as KotlinData
import qualified LawSpec.ScalaData as ScalaData
import qualified LawSpec.ScalaLayout as SL
import qualified LawSpec.JavaLayout as J
import LawSpec.DataNames (isProduct, caseNames)
import LawSpec.Time (isDurationType)
import LawSpec.JvmNames (jvmClaim, jvmClaimAll, jvmLocal, jvmMethod, javadoc)
import LawSpec.RecordNames (recordDisplayNames)
import LawSpec.Naming (sourceDefinitionName, nameWords)

data JvmTyped = JvmTyped
  { jvmTypedSource :: String
    -- The typed method of a typed definition, qualified.
  , jvmTypedFunction :: Id -> Maybe String
    -- A type's typed Java form (boxed), qualified.
  , jvmTypedType :: Type -> Either String String
  , jvmTypedTypeDoc :: Type -> Either String D.Doc
    -- The codec of a type, qualified: a static field of LawSpecTyped.
  , jvmTypedCodec :: Type -> Either String String
    -- A closed expression (a handler's start value), qualified.
  , jvmTypedValue :: Expr -> Either String String
    -- The method giving a typed handler's start state, qualified.
  , jvmTypedStart :: Id -> Maybe String
    -- Direct conversions from and to a native type, when it has them.
  , jvmTypedNative :: Type -> Maybe (String, String)
  , jvmTypedPlan :: TypedPlan
    -- Scala's direct conversions (LawSpecTypedScala), empty for Java and
    -- Kotlin, whose conversions are LawSpecTyped's own.
  , jvmTypedScalaSource :: String
  }

-- | Whose native types the typed code converts to: Java's records or
-- Kotlin's data classes. Scala's case classes and enums meet typed code
-- through their codecs, so ScalaStyle has no direct conversions.
data JvmStyle = JavaStyle | KotlinStyle | ScalaStyle deriving (Eq, Show, Generic)

instance Binary JvmStyle

-- | The scalars with a typed JVM form: UInt64 has no long.
jvmScalars :: [String]
jvmScalars = filter (/= "UInt64") scalarTypes

typedClassName :: String
typedClassName = "lawspec.runtime.LawSpecTyped"

fixedBounds :: [(String, (Integer, Integer))]
fixedBounds =
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)) ]

isFixed :: Type -> Bool
isFixed (Constructor n []) = n `elem` map fst fixedBounds
isFixed _ = False

data Env = Env
  { envPlan :: TypedPlan
  , envNames :: M.Map String String
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envPrefix :: String
  , envFast :: String
  , envStyle :: JvmStyle
  , envDeclarations :: [DataDeclaration]
  , envIdentity :: Identity.Graph
  , envNative :: M.Map Id String
  , envHelperNames :: M.Map (String,String) String
  }

-- | Fresh names, and the per-type native conversions the code asks for.
data St = St
  { stTaken :: S.Set String
  , stHelpers :: M.Map String Type
  , stWanted :: S.Set (String, String)
  } deriving (Show, Generic)

instance Binary St

type M = StateT St (Either String)

initial :: St
initial = St (S.fromList (javaKeywords ++ localReserved)) M.empty S.empty

localReserved :: [String]
localReserved = words "symbols LawSpecFast LawSpecRuntime LawSpecTyped String Long Boolean Object Integer Math Character Arrays Objects BigInteger java kotlin scala lawspec"

fresh :: String -> M String
fresh base = do
  s <- get
  let (name,taken) = jvmClaim (stTaken s) (jvmLocal "java" [] base)
  put s { stTaken = taken }
  pure name

-- | Conversion requests are replayable deltas; allocation never depends on
-- which definition happened to request a conversion first.
helper :: Env -> String -> Type -> M String
helper env kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key ty (stHelpers st),
    stWanted = S.insert (kind,key) (stWanted st) })
  pure (helperName env kind ty)

helperName :: Env -> String -> Type -> String
helperName env kind ty = M.findWithDefault fallback (kind,show ty) (envHelperNames env)
  where fallback = helperBase env kind ty ++ "hash" ++ Identity.fullKey (envIdentity env) "typed-jvm-helper-fallback" ty

helperBase :: Env -> String -> Type -> String
helperBase env kind ty = kind ++ typeWords ty
  where
    typeWords (Constructor name arguments) =
      capital (jvmLocal "java" [] (M.findWithDefault (lastName name) name (envNames env))) ++
      concat [typeWords t | TypeArgument t <- arguments]
    typeWords (TypeVariable _) = "Parameter"
    typeWords (Arrow a b) = "Function" ++ typeWords a ++ typeWords b
    lastName = reverse . takeWhile (/= ':') . reverse
    capital (c:cs) = toUpper c : cs
    capital [] = "Value"

-- | A header and its block, the brace on a line of its own.
braced :: String -> D.Doc -> D.Doc
braced header body = D.text header <> D.hardline <> D.block 2 body

javaKeywords :: [String]
javaKeywords = words "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var yield record sealed permits _"

identifier :: String -> String
identifier name = let n = [c | c <- name, isAlphaNum c || c == '_'] in
  if null n then "f" else if n `elem` javaKeywords then n ++ "_" else n

lift' :: Either String a -> M a
lift' = lift

-- | The static method of LawSpecDefinitionBodies that performs an operation
-- for typed code, over dynamic values.
jvmPerformName :: Operation -> String
jvmPerformName op = jvmMethod "typedPerform" (idText (operationId op))

emitJvmTyped :: JvmStyle -> [DataDeclaration] -> [Unit] -> Either String JvmTyped
emitJvmTyped style declarations units = do
  nativeNames <- case style of
    JavaStyle -> map (\(name,value) -> (Id name,value)) <$> JavaData.namesFor declarations
    KotlinStyle -> KotlinData.namesFor declarations
    ScalaStyle -> ScalaData.namesFor declarations
  let plan = typedPlanPerforming jvmScalars declarations units
      datas = typedData plan
      names = dataNames datas
      -- Each typed function is named after its definition, numbered only
      -- on a clash. ref:DEC-readable-generated-names
      functions = M.fromList (zip (map fst (typedRepresentatives plan))
        (fst (jvmClaimAll (S.fromList (javaKeywords ++ reservedMembers)) [functionName c d | (c, d) <- typedRepresentatives plan])))
      env = Env plan names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions "" "LawSpecFast" style declarations graph (M.fromList nativeNames) helperNames
      graph = Identity.dependencyGraph declarations units
      allTypes = Context.typeClosure (envData env)
        (concatMap (Context.definitionTypes . snd) (typedRepresentatives plan) ++ handlerTypes)
      helperNames = Context.helperAllocationWith (\name digest -> name ++ "hash" ++ digest)
        graph (M.elems functions ++ javaKeywords ++ reservedMembers) (helperBase env) helperKinds allTypes
      handlerTypes = [ t | h <- concatMap unitHandlers units, isTypedHandler plan h
                         , ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
      -- Scala's conversions live outside LawSpecTyped, so they name it in full.
      scalaEnv = env { envPrefix = typedClassName ++ ".", envFast = "lawspec.runtime.LawSpecFast" }
  dataDocs <- mapM (memoData env) datas
  let signatureTypes = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                              | d <- M.elems (typedDefinitions plan) ]
  ((functionDocs, natives, nativeDocs), _) <- flip runStateT initial $ do
    fs <- mapM (\(c, d) -> memoFunction env c d) (typedRepresentatives plan)
    direct <- forM [t | t <- nub (handlerTypes ++ signatureTypes), nativeDirect env S.empty t] $ \t -> do
      f <- helper env "fromNative" t
      g <- helper env "toNative" t
      pure (show t, (conversionOwner ++ "." ++ f, conversionOwner ++ "." ++ g))
    hs <- nativeHelpers (if style == ScalaStyle then scalaEnv else env)
    pure (fs, M.fromList direct, hs)
  -- Codecs every boundary needs, hoisted: one per type.
  boundary <- forM (nub (concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                                 | d <- M.elems (typedDefinitions plan) ] ++
                         [ t | h <- concatMap unitHandlers units, isTypedHandler plan h, (_, ty) <- handlerOperations h
                             , let (args, result) = functionType ty, t <- result : args ]))
    (\t -> (,) t <$> memoCodec env t)
  -- Each typed stateful handler's start state, made in Java for Java and
  -- Kotlin alike.
  let startable = [ (h, t, e) | h <- [x | x <- concatMap unitHandlers units, isTypedHandler plan x]
                             , Just (t, e) <- [handlerState h] ]
      startNames = fst (jvmClaimAll (S.fromList (M.elems functions ++ javaKeywords ++ reservedMembers))
        [jvmLocal "java" [] ("start " ++ handlerName h) | (h, _, _) <- startable])
      starting = [ (handlerId h, n, t, e) | ((h, t, e), n) <- zip startable startNames ]
  startDocs <- forM starting $ \(_, name, t, e) -> do
    jt <- javaTypeDoc env True t
    (body, _) <- runStateT (cstmt env Nothing [] Return e) initial
    pure (J.block (J.signature "public static " jt name
      [J.parameter (J.applied "java.util.Map" [D.text "String", D.text "Object"]) "symbols"]) body)
  let boundaryNames = M.fromList [(show ty,name) | ((_,key),name) <- M.toList allocatedCodecs,
        (ty,_) <- boundary, show ty == key]
      allocatedCodecs = Context.helperAllocationWith (\name digest -> name ++ "_" ++ map toUpper digest)
        graph reservedMembers (\_ ty -> intercalate "_" (map (map toUpper) (nameWords (helperBase env "codec" ty)))) ["codec"] (map fst boundary)
      codecDocs = [ J.assigned
                      (D.text "public static final " <> J.applied "LawSpecFast.Codec"
                        [either (const (D.text "?")) id (javaTypeDoc env True t)] <>
                        D.text (" " ++ boundaryNames M.! show t)) expr
                  | (t, expr) <- boundary ]
      helpers = entryHelpers env ++ orderingHelper env
      line = D.text
      source = line "// Generated by LawSpec. Do not edit." <> D.hardline <> D.hardline <>
        line "package lawspec.runtime;" <> D.hardline <> D.hardline <>
        line "/** Typed checked definitions: see LawSpecFast. */" <> D.hardline <>
        line "@SuppressWarnings({\"unchecked\", \"rawtypes\", \"unused\"})" <> D.hardline <>
        line "public final class LawSpecTyped" <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
          ([line "private LawSpecTyped() {}"] ++ dataDocs ++ helpers ++ codecDocs ++ startDocs ++ functionDocs ++ [d | style /= ScalaStyle, d <- nativeDocs]))
      scalaSource = if style /= ScalaStyle || null nativeDocs then "" else D.render (D.PrettyPoints 80)
        (line "// Generated by LawSpec. Do not edit." <> D.hardline <>
         line "package lawspec.runtime" <> D.hardline <> D.hardline <>
         line "// Direct conversions between Scala's native types and typed checked" <> D.hardline <>
         line "// definitions' (LawSpecTyped)." <> D.hardline <>
         line "object LawSpecTypedScala " <> D.block 2 (D.joinWith (D.hardline <> D.hardline) nativeDocs)) ++ "\n"
      lookupFunction identity = do
        c <- definitionClass plan identity
        (\n -> typedClassName ++ "." ++ n) <$> M.lookup c functions
      outside = env { envPrefix = typedClassName ++ ".", envFast = "lawspec.runtime.LawSpecFast" }
  pure JvmTyped
    { jvmTypedSource = D.render (D.Pretty 100) source ++ "\n"
    , jvmTypedFunction = lookupFunction
    , jvmTypedType = javaType outside True
    , jvmTypedTypeDoc = javaTypeDoc outside True
    , jvmTypedCodec = \t -> maybe (Left ("no typed codec for " ++ show t)) (Right . ((typedClassName ++ ".") ++)) (M.lookup (show t) boundaryNames)
    , jvmTypedValue = \e -> do
        ((statements, value), _) <- runStateT (cexpr outside [] e) initial
        if null statements then pure (D.render D.Compact value) else Left "a typed start value needs statements"
    , jvmTypedNative = \t -> M.lookup (show t) natives
    , jvmTypedStart = \identity -> lookup identity [(i, typedClassName ++ "." ++ n ++ "(symbols)") | (i, n, _, _) <- starting]
    , jvmTypedPlan = plan
    , jvmTypedScalaSource = scalaSource }
  where
    conversionOwner = if style == ScalaStyle then "lawspec.runtime.LawSpecTypedScala" else typedClassName
    functionName _ d = jvmLocal "java" [] (shortName (declarationName (definitionDeclaration d)))
    -- Names LawSpecTyped's own members use.
    reservedMembers = words "keyValOf entriesOf ordering codec"
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed
    handlerOperations h = [ (op, ty) | ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref], (op, ty) <- abilityOperations a ]

dataNames :: [DataDeclaration] -> M.Map String String
dataNames datas = M.fromList (snd (foldl pick (reserved, []) datas))
  where
    display = M.map (filter (/= '_')) (recordDisplayNames datas)
    reserved = S.fromList (javaKeywords ++ words "LawSpecTyped LawSpecFast LawSpecRuntime Value Data String Long Boolean Object Integer Math Character Arrays Objects Override Number BigInteger Iterable Comparable Exception RuntimeException Unit")
    pick (taken, acc) d =
      let base = identifier (M.findWithDefault (dataName d) (dataId d) display)
          chosen = firstOf [n | n <- base : [base ++ show k | k <- [2 :: Int ..]], n `S.notMember` taken]
      in (S.insert chosen taken, (idText (dataId d), chosen) : acc)

fieldless :: DataDeclaration -> Bool
fieldless d = not (null (dataConstructors d)) && all (null . constructorFields) (dataConstructors d)

isProductType :: DataDeclaration -> Bool
isProductType d = length (dataConstructors d) == 1 && not (fieldless d)

-- | A type's Java form; boxed in generic positions.
-- | Java type layout comes directly from checked type structure. Strings
-- remain only as the compact public ABI projection.
javaType :: Env -> Bool -> Type -> Either String String
javaType env boxed = fmap (D.render D.Compact) . javaTypeDoc env boxed

javaTypeDoc :: Env -> Bool -> Type -> Either String D.Doc
javaTypeDoc env = javaTypeDocP env []

javaTypeDocP :: Env -> [(Id, String)] -> Bool -> Type -> Either String D.Doc
javaTypeDocP env parameters boxed ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> pure (D.text p)
  Constructor "Bool" [] -> atom (if boxed then "Boolean" else "boolean")
  Constructor "Unit" [] -> atom (envFast env ++ ".Unit")
  _ | isFixed ty -> atom (if boxed then "Long" else "long")
  Constructor "Integer" [] -> atom "java.math.BigInteger"
  Constructor "Text" [] -> atom "String"
  Constructor "Bytes" [] -> atom (envFast env ++ ".Bytes")
  Constructor "List" [TypeArgument a] -> apply (envFast env ++ ".List") [a]
  Constructor "Maybe" [TypeArgument a] -> apply (envFast env ++ ".Maybe") [a]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> apply (envFast env ++ ".Either") [a,b]
  _ | Just ("KeyVal", [k,v]) <- collectionArguments ty -> apply (envFast env ++ ".Map") [k,v]
    | Just ("Set", [a]) <- collectionArguments ty -> apply (envFast env ++ ".Set") [a]
  Constructor n args | Just name <- M.lookup n (envNames env) -> do
    types <- mapM (\a -> case a of TypeArgument t -> pure t; _ -> Left "typed Java: index argument") args
    apply (envPrefix env ++ name) types
  _ -> Left ("no typed Java form for " ++ show ty)
  where
    atom = pure . D.text
    apply name args = J.applied name <$> mapM (javaTypeDocP env parameters True) args

-- | A codec is layout, not Java source to be read back by its consumer.
codecExpression :: Env -> [(Id, String)] -> Type -> Either String D.Doc
codecExpression env parameters ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> atom p
  Constructor "Bool" [] -> atom "LawSpecFast.BOOL"
  Constructor "Unit" [] -> atom "LawSpecFast.UNIT"
  Constructor n [] | Just (lo, hi) <- lookup n fixedBounds -> pure $ J.call "LawSpecFast.integer"
    [E.quoted n, D.text (longLiteral lo), D.text (longLiteral hi)]
  Constructor "Integer" [] -> atom "LawSpecFast.INTEGER"
  Constructor "Text" [] -> atom "LawSpecFast.TEXT"
  Constructor "Bytes" [] -> atom "LawSpecFast.BYTES"
  Constructor "List" [TypeArgument a] -> apply "LawSpecFast.list" [a]
  Constructor "Maybe" [TypeArgument a] -> apply "LawSpecFast.maybe" [a]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> apply "LawSpecFast.either" [a,b]
  _ | Just ("KeyVal", [k,v]) <- collectionArguments ty -> apply "LawSpecFast.keyVal" [k,v]
    | Just ("Set", [a]) <- collectionArguments ty -> apply "LawSpecFast.set" [a]
  Constructor n args | Just name <- M.lookup n (envNames env) -> do
    types <- mapM (\a -> case a of TypeArgument t -> pure t; _ -> Left "typed Java: index argument") args
    if null types then atom (envPrefix env ++ name ++ ".CODEC") else apply (envPrefix env ++ name ++ ".codec") types
  _ -> Left ("no typed Java codec for " ++ show ty)
  where
    atom = pure . D.text
    apply name args = J.call name <$> mapM (codecExpression env parameters) args

longLiteral :: Integer -> String
longLiteral n
  | n == -(2 ^ (63 :: Int)) = "Long.MIN_VALUE"
  | otherwise = show n ++ "L"

parameterNames :: DataDeclaration -> [(Id, String)]
parameterNames d = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]

fieldName :: Binder -> String
fieldName b = identifier (binderName b)

-- | Field comparisons and equality, by the field's Java form.
fieldEquals :: Type -> D.Doc -> D.Doc -> D.Doc
fieldEquals ty a b
  | primitiveType ty = D.group (a <> D.text " ==" <> D.nest 4 (D.softline <> b))
  | otherwise = J.call "java.util.Objects.equals" [a,b]

fieldCompare :: Type -> D.Doc -> D.Doc -> D.Doc
fieldCompare ty a b = J.call name [a,b]
  where
    name | isFixed ty = "Long.compare"
         | ty == Constructor "Bool" [] = "Boolean.compare"
         | otherwise = "LawSpecFast.compare"

primitiveType :: Type -> Bool
primitiveType ty = isFixed ty || ty == Constructor "Bool" []

dataDoc :: Env -> DataDeclaration -> Either String D.Doc
dataDoc env d = do
  let name = envNames env M.! idText (dataId d)
      parameters = parameterNames d
      generics = if null parameters then "" else "<" ++ intercalate ", " (map snd parameters) ++ ">"
      ranks = constructorRanks d
      rank c = fromMaybe 0 (lookup (constructorId c) ranks)
      tagOf c = E.quoted (idText (constructorId c))
      variants = dataConstructors d
      line = D.text
      header = if length (dataName d ++ idText (dataId d)) > 80
        then D.joinWith D.hardline (map line (["/**", " * " ++ dataName d] ++ [" * " ++ w | w <- idLines (idText (dataId d))] ++ [" */"]))
        else line ("/** " ++ dataName d ++ " (" ++ idText (dataId d) ++ "). */")
      codecParams = [J.parameter (J.applied "LawSpecFast.Codec" [D.text p]) ("c" ++ show k) | (k, (_, p)) <- zip [0 :: Int ..] parameters]
      keyLiteral = if null parameters then E.quoted (idText (dataId d)) else
        J.call "LawSpecFast.dataKey" (E.quoted (idText (dataId d)) : [D.text ("c" ++ show k) | k <- [0 .. length parameters - 1]])
      codecParamMap = [(v, "c" ++ show k) | (k, (v, _)) <- zip [0 :: Int ..] parameters]
  fieldTypes <- forM variants $ \c -> forM (constructorFields c) $ \f -> javaTypeDocP env parameters False (binderType f)
  fieldCodecs <- forM variants $ \c -> forM (constructorFields c) $ \f -> codecExpression env codecParamMap (binderType f)
  let codecType = J.applied "LawSpecFast.Codec" [J.applied name (map (D.text . snd) parameters)]
      codecSignature = J.signature
        (if null parameters then "private static " else "public static " ++ generics ++ " ")
        codecType "codec" codecParams
      variantClass c = if isProductType d then name else name ++ "." ++ variantName env d c
      encodeArm c codecs = line ("case " ++ show (index c) ++ " -> ") <> D.block 2 (
        (if null (constructorFields c) then mempty else J.bind "m" (castDoc (J.applied (variantClass c) (map (D.text . snd) parameters)) (D.text "value")) <> D.hardline) <>
        line "return " <> jcall "LawSpecFast.value" (line "key" : tagOf c : [J.method codec "encode" [line ("m." ++ fieldName f)] | (f, codec) <- zip (constructorFields c) codecs]) <> line ";")
      decodeArm c codecs = line "case " <> tagOf c <> line " -> " <> D.block 2 (line "return " <>
        construction c [J.method codec "decode" [line ("d.fields().get(" ++ show k ++ ")")] | (k, codec) <- zip [0 :: Int ..] codecs] <> line ";")
      construction c args
        | fieldless d = line (name ++ "." ++ variantName env d c)
        | otherwise = J.call ("new " ++ variantClass c ++ (if null parameters then "" else "<>")) args
      index c = length (takeWhile ((/= constructorId c) . constructorId) variants)
      codecField = [J.assigned (line "public static final " <> codecType <> line " CODEC") (J.call "codec" []) | null parameters]
      codecDoc = D.joinWith (D.hardline <> D.hardline) (codecField ++ [codecSignature]) <> D.hardline <> D.block 2 (D.joinWith D.hardline
        [ D.group (line "String key =" <> D.nest 4 (D.softline <> keyLiteral <> line ";"))
        , line "return new " <> codecType <> line "()" <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
          [ braced "public String key()" (line "return key;")
          , line ("public LawSpecRuntime.Value encode(" ++ name ++ generics ++ " value)") <> D.hardline <> D.block 2
              (if fieldless d
                then line "return switch (value)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                  [D.group (line ("case " ++ variantName env d c ++ " ->") <> D.nest 4 (D.softline <> jcall "LawSpecFast.value" [line "key", tagOf c])) <> line ";" | c <- variants]) <> line ";"
                else line ("switch (" ++ (if isProductType d then "0" else "value.tag") ++ ")") <> D.hardline <> D.block 2 (D.joinWith D.hardline
                  (zipWith encodeArm variants fieldCodecs ++ [line "default -> throw LawSpecFast.unreachable();"])))
          , line ("public " ++ name ++ generics ++ " decode(LawSpecRuntime.Value value)") <> D.hardline <> D.block 2 (
              line "var d = LawSpecFast.fields(value);" <> D.hardline <>
              line "switch (d.tag())" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                (zipWith decodeArm variants fieldCodecs ++ [D.group (line "default ->" <> D.nest 4 (D.softline <> line "throw " <> jcall "new IllegalArgumentException" [E.quoted ("expected " ++ dataName d ++ ", found ") <> line " + d.tag()"] <> line ";"))]))) ]) <> line ";" ])
      toStringDoc c = line "@Override" <> D.hardline <> braced "public String toString()"
        (D.group (line ("return " ++ show (constructorName c)) <> D.nest 4 (D.softline <> line "+ " <>
          E.call "java.util.List.of" (map (line . fieldName) (constructorFields c)))) <> line ";")
      fieldsDoc c ts = D.joinWith D.hardline
        [J.statement (line "public final " <> J.parameter ty (fieldName f)) | (f,ty) <- zip (constructorFields c) ts]
      parameterName f = fromMaybe (fieldName f) (positionalLabel (binderName f))
      constructorDoc cls c ts superCall = J.block
        (J.call ("public " ++ cls) [J.parameter ty (parameterName f) | (f,ty) <- zip (constructorFields c) ts])
        (superCall ++ [J.assigned (line ("this." ++ fieldName f)) (line (parameterName f)) | f <- constructorFields c])
      equalsDoc cls c = line "@Override" <> D.hardline <> line "public boolean equals(Object other)" <> D.hardline <> D.block 2
        (braced ("if (!(other instanceof " ++ cls ++ " o))") (line "return false;") <> D.hardline <>
         (case [fieldEquals (binderType f) (line (fieldName f)) (line ("o." ++ fieldName f)) | f <- constructorFields c] of
            [] -> line "return true;"
            first : rest -> line "return " <> D.group (first <> D.nest 4 (mconcat [D.softline <> line "&& " <> r | r <- rest])) <> line ";"))
      hashDoc c = line "@Override" <> D.hardline <> line "public int hashCode()" <> D.hardline <> D.block 2
        (J.returned (J.call "java.util.Objects.hash" (line (show (rank c)) : map (line . fieldName) (constructorFields c))))
      compareFieldsDoc cls c = line "int compareFields(Object other)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
        ([line ("var o = (" ++ cls ++ ") other;") | not (null (constructorFields c))] ++
         concat [[J.assigned (line ("int c" ++ show k)) (fieldCompare (binderType f) (line (fieldName f)) (line ("o." ++ fieldName f))),
                  braced ("if (c" ++ show k ++ " != 0)") (line ("return c" ++ show k ++ ";"))] | (k, f) <- zip [0 :: Int ..] (constructorFields c)] ++
         [line "return 0;"]))
  pure $ header <> D.hardline <> if fieldless d
    then line ("public enum " ++ name ++ " implements LawSpecFast.Ordered") <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
      [ D.group (D.commaSep [line (variantName env d c ++ "(" ++ show (rank c) ++ ")") | c <- variants]) <> line ";"
      , line "private final int rank;"
      , braced (name ++ "(int rank)") (line "this.rank = rank;")
      , braced "public int compareWith(Object other)" (line ("return Integer.compare(rank, ((" ++ name ++ ") other).rank);"))
      , codecDoc ])
    else if isProductType d
    then let c = firstOf variants; ts = firstOf fieldTypes in
      line ("public static final class " ++ name ++ generics ++ " implements LawSpecFast.Ordered") <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
        [ fieldsDoc c ts, constructorDoc name c ts [], equalsDoc name c, hashDoc c, compareFieldsDoc name c
        , braced "public int compareWith(Object other)" (line "return this == other ? 0 : compareFields(other);")
        , toStringDoc c
        , codecDoc ])
    else line ("public abstract static class " ++ name ++ generics ++ " implements LawSpecFast.Ordered") <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
      ([ line "public final int tag;"
       , braced ("private " ++ name ++ "(int tag)") (line "this.tag = tag;")
       , line ("private static final int[] RANKS = {" ++ intercalate ", " (map (show . rank) variants) ++ "};")
       , line "abstract int compareFields(Object other);"
       , line ("public int compareWith(Object other)") <> D.hardline <> D.block 2 (D.joinWith D.hardline
           [ braced "if (this == other)" (line "return 0;")
           , line ("var o = (" ++ name ++ generics ++ ") other;")
           , braced "if (tag != o.tag)" (line "return Integer.compare(RANKS[tag], RANKS[o.tag]);")
           , line "return compareFields(other);" ]) ] ++
       [ line ("public static final class " ++ variantName env d c ++ generics ++ " extends " ++ name ++ generics ) <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
           ([fieldsDoc c ts | not (null ts)] ++
            [ constructorDoc (variantName env d c) c ts [line ("super(" ++ show (index c) ++ ");")]
            , equalsDoc (variantName env d c) c, hashDoc c, compareFieldsDoc (variantName env d c) c
            , toStringDoc c ]))
       | (c, ts) <- zip variants fieldTypes ] ++ [codecDoc]))

-- The typed representation is private, but its nested classes still obey
-- Java's enclosing-type collision rule, as the public model already does.
variantName :: Env -> DataDeclaration -> DataConstructor -> String
variantName env d c = identifier (fromMaybe (constructorName c)
  (lookup (constructorId c) (caseNames (envNames env M.! idText (dataId d)) (dataConstructors d))))

entryHelpers :: Env -> [D.Doc]
entryHelpers env = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
  Nothing -> []
  Just name ->
    let key = D.text "K"
        value = D.text "V"
        entry = J.applied name [key,value]
        entries = J.applied "LawSpecFast.List" [entry]
        mapping = J.applied "LawSpecFast.Map" [key,value]
    in [ J.block (J.signature "public static <K, V> " mapping "keyValOf" [J.parameter entries "entries"])
           [ J.assigned (mapping <> D.text " map") (J.call "LawSpecFast.Map.empty" [])
           , J.block (D.text "for (" <> J.parameter entry "entry" <> D.text " : entries)")
               [J.assigned (D.text "map") (J.call "map.put" [D.text "entry.key", D.text "entry.value"])]
           , J.returned (D.text "map") ]
       , J.block (J.signature "public static <K, V> " entries "entriesOf" [J.parameter mapping "map"])
           [J.returned (J.call "map.toList" [J.lambdaValue ["k", "v"] (J.call ("new " ++ name ++ "<>") [D.text "k", D.text "v"])])] ]

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envNames env) of
  Nothing -> []
  Just name ->
    [ D.text ("public static " ++ name ++ " ordering(int c)") <> D.hardline <> D.block 2
        (D.text ("return c < 0 ? " ++ name ++ ".Less : c == 0 ? " ++ name ++ ".Equal : " ++ name ++ ".Greater;")) ]

-- Functions.

data Target = Return | Assign String

type Scope = [(Id, String)]

helperKinds :: [String]
helperKinds = ["toNative","fromNative"]

functionTable :: Table (Either String (D.Doc,St))
functionTable = unsafePerformIO (newPersistentTable "typed-jvm-function" (8 * 1024 * 1024) (length . show))
{-# NOINLINE functionTable #-}

dataTable :: Table (Either String D.Doc)
dataTable = unsafePerformIO (newPersistentTable "typed-jvm-data" (4 * 1024 * 1024) (length . show))
{-# NOINLINE dataTable #-}

helperTable :: Table (Either String (D.Doc,St))
helperTable = unsafePerformIO (newPersistentTable "typed-jvm-helper" (8 * 1024 * 1024) (length . show))
{-# NOINLINE helperTable #-}

codecTable :: Table (Either String D.Doc)
codecTable = unsafePerformIO (newPersistentTable "typed-jvm-codec" (4 * 1024 * 1024) (length . show))
{-# NOINLINE codecTable #-}

-- Exact allocated interfaces of just the types this chunk can name.
chunkContext :: Env -> [Type] -> String
chunkContext env types = show
  (envStyle env,envPrefix env,envFast env,
   [(name,M.lookup name (envNames env),M.lookup (Id name) (envNative env)) | Constructor name _ <- types],
   [(kind,show ty,helperName env kind ty) | ty <- types, kind <- helperKinds])

memoData :: Env -> DataDeclaration -> Either String D.Doc
memoData env declaration = memoized dataTable key (dataDoc env declaration)
  where
    types = Context.typeClosure (envData env) [Constructor (idText (dataId declaration)) []]
    key = Identity.fullKey (envIdentity env) ("typed-jvm-data:" ++ chunkContext env types) declaration

memoCodec :: Env -> Type -> Either String D.Doc
memoCodec env ty = memoized codecTable key (codecExpression env [] ty)
  where
    types = Context.typeClosure (envData env) [ty]
    key = Identity.fullKey (envIdentity env) ("typed-jvm-codec:" ++ chunkContext env types) ty

replay :: St -> M ()
replay requested = modify (\before -> before
  {stHelpers = M.union (stHelpers requested) (stHelpers before),
   stWanted = S.union (stWanted requested) (stWanted before)})

memoFunction :: Env -> Int -> Definition -> M D.Doc
memoFunction env classification definition = do
  let calls = Context.calledFunctions (envPlan env) (envFunctions env) classification definition
      types = Context.typeClosure (envData env) (Context.definitionTypes definition)
      own = initial {stTaken = S.union (stTaken initial)
        (S.fromList [name | Constructor name _ <- types, Just name <- [M.lookup name (envNames env)]])}
      key = Identity.fullKey (envIdentity env)
        ("typed-jvm-function:" ++ show calls ++ chunkContext env types) definition
  (document,requested) <- lift' (memoized functionTable key (runStateT (functionDoc env classification definition) own))
  replay requested
  pure document

memoHelper :: Env -> String -> Type -> M D.Doc
memoHelper env kind ty = do
  let types = Context.typeClosure (envData env) [ty]
      key = Identity.fullKey (envIdentity env) ("typed-jvm-helper:" ++ kind ++ chunkContext env types) ty
  (document,requested) <- lift' (memoized helperTable key (runStateT (nativeHelper env kind ty) initial))
  replay requested
  pure document

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (_, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    ty <- lift' (javaTypeDoc env False (binderType b))
    pure (binderId b, local, ty)
  resultType <- lift' (javaTypeDoc env False result)
  let scope = [(i, l) | (i, l, _) <- params]
      selfCall = Just (c, map (\(_, l, _) -> l) params)
      looping = hasTailSelf env c (definitionBody d)
      contextual = isContextual (envPlan env) (declarationId declaration)
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l, _), b) <- zip params (definitionArguments d)]
      pure [J.returned x]
    Nothing -> cstmt env (if looping then selfCall else Nothing) scope Return (definitionBody d)
  let signature = J.signature "public static " resultType name
        ([J.parameter (J.applied "java.util.Map" [D.text "String", D.text "Object"]) "symbols" | contextual] ++
          [J.parameter t l | (_, l, t) <- params])
  pure (javadoc 98 (sourceDefinitionName (declarationName declaration)) <> D.hardline <> signature <> D.hardline <> D.block 2
    (if looping then D.text "while (true)" <> D.hardline <> D.block 2 (D.joinWith D.hardline body) else D.joinWith D.hardline body))

hasTailSelf :: Env -> Int -> Expr -> Bool
hasTailSelf env c e = case expressionNode e of
  ExternalCall i _ -> definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env))
  If _ a b -> hasTailSelf env c a || hasTailSelf env c b
  Match _ cases -> any (hasTailSelf env c . caseBody) cases
  Let _ _ body -> hasTailSelf env c body
  Helper Select [_, a, b] -> hasTailSelf env c a || hasTailSelf env c b
  _ -> False

deliver :: Target -> D.Doc -> D.Doc
deliver Return = J.returned
deliver (Assign name) = J.assigned (D.text name)

-- | Statements delivering an expression's value to a target.
cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    ty <- lift' (javaType env False (binderType binder))
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [J.assigned (D.text ("final " ++ ty ++ " " ++ local)) x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [D.text "if (" <> x <> D.text ")" <> D.hardline <> D.block 2 (D.joinWith D.hardline yes) <> D.hardline <> D.text "else" <> D.hardline <> D.block 2 (D.joinWith D.hardline no)])
  Helper Select [c, a, b] -> cstmt env selfCall scope target (e { expressionNode = If c a b })
  Match value cases -> matchStatements env selfCall scope target value cases
  ExternalCall i args
    | Just (c, params) <- selfCall, definitionClass (envPlan env) i == Just c, M.notMember i (typedIntrinsics (envPlan env)), Return <- target -> do
        let unchanged (p, a) = case expressionNode a of
              Local l -> lookup l scope == Just p
              _ -> False
            changed = [(p, a) | (p, a) <- zip params args, not (unchanged (p, a))]
        evaluated <- forM changed $ \(p, a) -> do
          (s, x) <- cexpr env scope a
          t <- fresh "next"
          ty <- lift' (javaType env False (expressionType a))
          pure (s ++ [J.assigned (D.text ("final " ++ ty ++ " " ++ t)) x], D.text (p ++ " = " ++ t ++ ";"))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue;"])
  Helper Unreachable _ -> pure [D.text "throw LawSpecFast.unreachable();"]
  -- raise e delivers nothing: it throws.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    codec <- lift' (codecExpression env [] (expressionType x))
    pure (s ++ [D.text "throw " <> jcall "new LawSpecRuntime.Failure" [E.quoted (abilityKey ref), J.method codec "encode" [v]] <> D.text ";"])
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [deliver target x])

-- | An expression, after the statements it needs.
cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e
  | isComplexNode = do
      t <- fresh "value"
      ty <- lift' (javaType env False (expressionType e))
      s <- cstmt env Nothing scope (Assign t) e
      pure (D.text (ty ++ " " ++ t ++ ";") : s, D.text t)
  | otherwise = case expressionNode e of
      Constant s -> (,) [] <$> lift' (constant env (expressionType e) s)
      Local i -> do
        name <- lift' (maybe (Left ("typed Java: unbound local " ++ idText i)) Right (lookup i scope))
        pure ([], D.text name)
      Construct tag args -> do
        parts <- mapM (cexpr env scope) args
        x <- construct env (expressionType e) tag (map snd parts) args
        pure (concatMap fst parts, x)
      ExternalCall i args
        | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
            parts <- mapM (cexpr env scope) args
            x <- intrinsicCall env intrinsic (zip (map snd parts) (map expressionType args))
            pure (concatMap fst parts, x)
        | otherwise -> do
            c <- lift' (maybe (Left ("typed Java: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
            parts <- mapM (cexpr env scope) args
            let context = [D.text "symbols" | isContextual (envPlan env) i]
            pure (concatMap fst parts, jcall (envPrefix env ++ envFunctions env M.! c) (context ++ map snd parts))
      ShortCircuit op a b -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        if null sb
          then pure (sa, D.group (D.text "(" <> xa <> D.nest 4 (D.softline <> D.text (if op == And then "&& " else "|| ") <> xb) <> D.text ")"))
          else do
            t <- fresh "logic"
            pure (sa ++ [D.text ("boolean " ++ t ++ ";"),
              D.text "if (" <> (if op == And then xa else D.text "!" <> paren xa) <> D.text ")" <> D.hardline <>
                D.block 2 (D.joinWith D.hardline (sb ++ [D.text (t ++ " = ") <> xb <> D.text ";"])) <> D.hardline <>
                braced "else" (D.text (t ++ " = " ++ (if op == And then "false" else "true") ++ ";"))], D.text t)
      Unary Not a -> do
        (s, x) <- cexpr env scope a
        pure (s, D.text "!" <> paren x)
      Unary Negate _ -> bigExpr env scope e
      Binary {} -> binary env scope e
      Convert _ target value
        | target == expressionType value -> cexpr env scope value
        | otherwise -> convert env scope target value
      Helper Compare [a, b] -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        pure (sa ++ sb, jcall (envPrefix env ++ "ordering") [jcall "LawSpecFast.compare" [xa, xb]])
      Helper Length [_] -> bigExpr env scope e
      Helper Unreachable _ -> do
        ty <- lift' (javaType env True (expressionType e))
        pure ([braced "if (true)" (D.text "throw LawSpecFast.unreachable();")], D.text ("(" ++ ty ++ ") null"))
      Helper Checked _ -> pure ([], D.text "true")
      AllElements value binder predicate -> do
        (sx, xs) <- cexpr env scope value
        t <- fresh "all"
        item <- fresh (binderName binder)
        jt <- lift' (javaType env False (binderType binder))
        (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
        pure (sx ++ [ D.text ("boolean " ++ t ++ " = true;")
                    , D.text ("for (final " ++ jt ++ " " ++ item ++ " : ") <> xs <> D.text ")" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                        (sp ++ [D.text "if (!" <> paren p <> D.text ")" <> D.hardline <> D.block 2 (D.text (t ++ " = false;") <> D.hardline <> D.text "break;")])) ], D.text t)
      Helper StartsWith [a, b] -> method "startsWith" a b
      Helper EndsWith [a, b] -> method "endsWith" a b
      Helper TextContains [a, b] -> method "contains" a b
      Helper RegexMatches [a, b] -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        pure (sa ++ sb, jcall "LawSpecRuntime.regexMatches" [xa, xb <> D.text ".codePoints().toArray()"])
      -- raise e: a failure of the Fail ability, as the dynamic raise makes it.
      Perform (Operation ref "raise") [x] | isFail ref -> do
        thrown <- raised ref x
        ty <- lift' (javaType env True (expressionType e))
        pure (fst thrown ++ [D.text "if (true)" <> D.hardline <> D.block 2 (snd thrown)], D.text ("(" ++ ty ++ ") null"))
      -- An operation of another ability: the dynamic code's call of its
      -- handler in the context (LawSpecDefinitionBodies), over the
      -- arguments' dynamic values.
      Perform op args -> do
        parts <- mapM (cexpr env scope) args
        codecs <- lift' (mapM (codecExpression env [] . expressionType) args)
        resultCodec <- lift' (codecExpression env [] (expressionType e))
        pure (concatMap fst parts, J.method resultCodec "decode" [E.call ("LawSpecDefinitionBodies." ++ jvmPerformName op)
          (D.text "symbols" : [J.method codec "encode" [x] | (codec, x) <- zip codecs (map snd parts)])])
      -- attempt e: Right of e's value, or Left of the failure it raised.
      Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType e -> do
        t <- fresh "attempted"
        ty <- lift' (javaType env False (expressionType e))
        lt <- lift' (javaType env True failure)
        rt <- lift' (javaType env True result)
        codec <- lift' (codecExpression env [] failure)
        (s, x) <- cexpr env scope body
        let witness = "<" ++ lt ++ ", " ++ rt ++ ">"
            blockOf ss = D.hardline <> D.block 2 (D.joinWith D.hardline ss)
        pure ([ D.text (ty ++ " " ++ t ++ ";")
              , D.text "try" <> blockOf (s ++ [J.assigned (D.text t) (J.call (envFast env ++ ".Either." ++ witness ++ "right") [x])]) <>
                D.hardline <> D.text "catch (LawSpecRuntime.Failure failure)" <> blockOf
                  [ braced ("if (!failure.ability.equals(" ++ show (abilityKey ref) ++ "))") (D.text "throw failure;")
                  , J.assigned (D.text t) (J.call (envFast env ++ ".Either." ++ witness ++ "left")
                      [J.method codec "decode" [D.text "failure.value"]]) ] ], D.text t)
      Helper Append [a, b] -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        pure (sa ++ sb, case expressionType a of
          Constructor "Text" [] -> paren (xa <> D.text " + " <> xb)
          Constructor "Bytes" [] -> jcall "LawSpecFast.appendBytes" [xa, xb]
          _ -> jcall "LawSpecFast.append" [xa, xb])
      Helper Slice [x, from, to] -> do
        (sx, v) <- cexpr env scope x
        (si, i) <- index from
        (sj, j) <- index to
        let f = case expressionType x of
              Constructor "Text" [] -> "LawSpecFast.sliceText"
              Constructor "Bytes" [] -> "LawSpecFast.sliceBytes"
              _ -> "LawSpecFast.slice"
        pure (sx ++ si ++ sj, jcall (f) [v, i, j])
      Helper At [x, k] -> do
        (sx, v) <- cexpr env scope x
        (si, i) <- index k
        let f = if expressionType x == Constructor "Bytes" [] then "LawSpecFast.atBytes" else "LawSpecFast.at"
        pure (sx ++ si, jcall (f) [v, i])
      Helper Range [lo, hi] -> do
        (sa, a) <- cexpr env scope lo
        (sb, b) <- cexpr env scope hi
        pure (sa ++ sb, jcall "LawSpecFast.range" [a, b])
      Helper Octets [b] -> one "LawSpecFast.octets" b
      Helper BytesOf [xs] -> one "LawSpecFast.bytesOf" xs
      Helper Utf8 [t] -> one "LawSpecFast.utf8" t
      Helper TextOf [n] -> case expressionType n of
        Constructor "Integer" [] -> one "String.valueOf" n
        _ -> one "Long.toString" n
      Helper Join [sep, parts] -> do
        (sa, a) <- cexpr env scope sep
        (sb, b) <- cexpr env scope parts
        pure (sa ++ sb, jcall "LawSpecFast.join" [a, b])
      _ -> lift' (Left ("typed Java: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, J.call f [x])
    -- An Integer index, as a long (clamped).
    index a = do
      l <- longExpr env scope a
      case l of
        Just r -> pure r
        Nothing -> do
          (s, x) <- bigExpr env scope a
          pure (s, J.call "LawSpecFast.index" [x])
    raised ref x = do
      (s, v) <- cexpr env scope x
      codec <- lift' (codecExpression env [] (expressionType x))
      pure (s, D.text "throw " <> jcall "new LawSpecRuntime.Failure" [E.quoted (abilityKey ref), J.method codec "encode" [v]] <> D.text ";")
    isComplexNode = case expressionNode e of
      Let {} -> True
      Match {} -> True
      If {} -> True
      Helper Select _ -> True
      AllElements {} -> False
      _ -> False
    method name a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, J.method xa name [xb])

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

-- | name(a, b), its arguments wrapped 4 deeper when it does not fit, as
-- Google Java Style wraps them.
jcall :: String -> [D.Doc] -> D.Doc
jcall = J.call

constant :: Env -> Type -> Scalar -> Either String D.Doc
constant env _ s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (D.text (envFast env ++ ".Unit.UNIT"))
  SInteger "Integer" n
    | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) -> pure (J.call "java.math.BigInteger.valueOf" [D.text (longLiteral n)])
    | otherwise -> pure (J.call "new java.math.BigInteger" [E.quoted (show n)])
  SInteger _ n -> pure (D.text (longLiteral n))
  SSequence "Text" units -> pure (E.quoted (map toEnum units))
  SSequence "Bytes" units -> pure (J.call (envFast env ++ ".Bytes.of") (map (D.text . show) units))
  _ -> Left ("typed Java: unsupported constant " ++ show s)

-- | An integer expression whose value is a long exactly: a bounded integer,
-- a length or a small literal.
longExpr :: Env -> Scope -> Expr -> M (Maybe ([D.Doc], D.Doc))
longExpr env scope e = case (expressionNode e, expressionType e) of
  (Constant (SInteger _ n), _) | n >= -(2 ^ (62 :: Int)) && n < 2 ^ (62 :: Int) -> pure (Just ([], D.text (longLiteral n)))
  (Convert _ (Constructor "Integer" []) value, _) | isFixed (expressionType value) -> Just <$> cexpr env scope value
  (Helper Length [x], _) -> do
    (s, v) <- cexpr env scope x
    pure (Just (s, lengthOf (expressionType x) v))
  (_, ty) | isFixed ty -> Just <$> cexpr env scope e
  _ -> pure Nothing

lengthOf :: Type -> D.Doc -> D.Doc
lengthOf ty v = case ty of
  Constructor "Text" [] -> D.text "(long) LawSpecFast.textLength(" <> v <> D.text ")"
  Constructor "Bytes" [] -> D.text "(long) " <> v <> D.text ".length()"
  _ -> D.text "(long) " <> v <> D.text ".size()"

-- | An expression of type Integer, as a BigInteger.
bigExpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
bigExpr env scope e = do
  l <- longExpr env scope e
  case l of
    Just (s, x) -> pure (s, J.call "java.math.BigInteger.valueOf" [x])
    Nothing -> case expressionNode e of
      Unary Negate a -> do
        (s, x) <- big a
        pure (s, J.method x "negate" [])
      Binary op _ a b | not (isComparison op) -> do
        (sa, xa) <- big a
        (sb, xb) <- big b
        pure (sa ++ sb, case op of
          Add -> J.method xa "add" [xb]
          Subtract -> J.method xa "subtract" [xb]
          Multiply -> J.method xa "multiply" [xb]
          Quotient -> jcall "LawSpecFast.quot" [xa, xb]
          Remainder -> jcall "LawSpecFast.rem" [xa, xb]
          _ -> jcall "LawSpecFast.pow" [xa, xb])
      _ -> cexpr env scope e
  where
    big a = case expressionType a of
      Constructor "Integer" [] -> bigExpr env scope a
      _ -> do
        (s, x) <- cexpr env scope a
        pure (s, J.call "java.math.BigInteger.valueOf" [x])

binary :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
binary env scope e = case expressionNode e of
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let test = if primitiveType t
          then paren xa <> D.text " == " <> paren xb
          else jcall "java.util.Objects.equals" [xa, xb]
    pure (sa ++ sb, if op == Equal then paren test else D.text "!" <> paren test)
  Binary op (Numeric _) a b | isComparison op -> do
    let symbol = case op of Equal -> " == "; NotEqual -> " != "; Less -> " < "; LessEqual -> " <= "; Greater -> " > "; _ -> " >= "
    la <- longExpr env scope a
    lb <- longExpr env scope b
    case (la, lb) of
      (Just (sa, xa), Just (sb, xb)) -> pure (sa ++ sb, paren (paren xa <> D.text symbol <> paren xb))
      _ -> do
        (sa, xa) <- bigExpr env scope (widen a)
        (sb, xb) <- bigExpr env scope (widen b)
        pure (sa ++ sb, paren (xa <> jcall ".compareTo" [xb] <> D.text symbol <> D.text "0"))
  _ -> bigExpr env scope e
  where
    widen a = case expressionType a of
      Constructor "Integer" [] -> a
      _ -> a { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) a }

convert :: Env -> Scope -> Type -> Expr -> M ([D.Doc], D.Doc)
convert env scope target value = case (target, expressionType value) of
  (Constructor "Integer" [], _) -> bigExpr env scope (value { expressionType = target, expressionNode = Convert Explicit target value })
  (Constructor t [], source) | Just (lo, hi) <- lookup t fixedBounds -> do
    let bounds = [D.text (longLiteral lo), D.text (longLiteral hi), E.quoted t]
        inside = case source of
          Constructor s [] | Just (slo, shi) <- lookup s fixedBounds -> slo >= lo && shi <= hi
          _ -> False
    if inside then cexpr env scope value else do
      -- One checked operation on two longs, narrowed at once.
      fused <- case expressionNode value of
        Binary op (Numeric (Constructor "Integer" [])) a b | op `elem` [Add, Subtract, Multiply] -> do
          la <- longExpr env scope a
          lb <- longExpr env scope b
          pure $ case (la, lb) of
            (Just (sa, xa), Just (sb, xb)) ->
              let f = case op of Add -> "add"; Subtract -> "subtract"; _ -> "multiply"
              in Just (sa ++ sb, jcall ("LawSpecFast." ++ f) ([xa,xb] ++ bounds))
            _ -> Nothing
        _ -> pure Nothing
      case fused of
        Just r -> pure r
        Nothing -> do
          l <- longExpr env scope value
          case l of
            Just (s, x) -> pure (s, J.call "LawSpecFast.narrow" (x : bounds))
            Nothing -> do
              (s, x) <- bigExpr env scope value
              pure (s, J.call "LawSpecFast.narrow" (x : bounds))
  _ -> lift' (Left ("typed Java: unsupported conversion to " ++ show target))

construct :: Env -> Type -> Id -> [D.Doc] -> [Expr] -> M D.Doc
construct env ty tag values _ = do
  boxed <- lift' (javaType env True ty)
  let argumentsOf = case ty of Constructor _ args -> [t | TypeArgument t <- args]; _ -> []
  witnesses <- lift' (mapM (javaTypeDoc env True) argumentsOf)
  case (idText tag, values) of
    ("List::Nil", []) -> pure (witnessCall (envFast env ++ ".List") witnesses "nil" [])
    ("List::Cons", [h,t]) -> pure (witnessCall (envFast env ++ ".List") witnesses "cons" [h,t])
    ("Maybe::Absent", []) -> pure (witnessCall (envFast env ++ ".Maybe") witnesses "absent" [])
    ("Maybe::Present", [x]) -> pure (witnessCall (envFast env ++ ".Maybe") witnesses "present" [x])
    ("Either::Left", [x]) -> pure (witnessCall (envFast env ++ ".Either") witnesses "left" [x])
    ("Either::Right", [x]) -> pure (witnessCall (envFast env ++ ".Either") witnesses "right" [x])
    (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> pure (J.call (envPrefix env ++ "keyValOf") [items])
    (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (J.call (envFast env ++ ".Set.of") [items])
    _ -> case M.lookup tag (envConstructors env) of
      Just (d,c) -> do
        let name = envPrefix env ++ envNames env M.! idText (dataId d)
            cls = if isProductType d then name else name ++ "." ++ variantName env d c
        pure $ if fieldless d then D.text (name ++ "." ++ variantName env d c)
          else J.callWith (D.text "new " <> J.applied cls witnesses) values
      Nothing -> lift' (Left ("typed Java: unknown constructor " ++ idText tag ++ " for " ++ boxed))

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic,map fst args) of
  (KeyValOf,[es]) -> pure (J.call (envPrefix env ++ "keyValOf") [es])
  (KeyValLookup,[k,m]) -> pure (J.method m "get" [k])
  (KeyValPut,[k,v,m]) -> pure (J.method m "put" [k,v])
  (KeyValDelete,[k,m]) -> pure (J.method m "remove" [k])
  (KeyValKeys,[m]) -> pure (J.method m "toList" [J.lambdaValue ["k","v"] (D.text "k")])
  (KeyValValues,[m]) -> pure (J.method m "toList" [J.lambdaValue ["k","v"] (D.text "v")])
  (KeyValEntries,[m]) -> pure (J.call (envPrefix env ++ "entriesOf") [m])
  (SetOf,[xs]) -> pure (J.call "LawSpecFast.Set.of" [xs])
  (SetMember,[x,s]) -> pure (J.method s "contains" [x])
  (SetInsert,[x,s]) -> pure (J.method s "insert" [x])
  (SetRemove,[x,s]) -> pure (J.method s "remove" [x])
  (SetUnion,[s,t]) -> pure (J.method s "union" [t])
  (SetIntersection,[s,t]) -> pure (J.method s "intersection" [t])
  (SetDifference,[s,t]) -> pure (J.method s "difference" [t])
  _ -> lift' (Left ("typed Java: bad intrinsic " ++ show intrinsic))

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      bindOne c b access = if used c b
        then do
          n <- fresh (binderName b)
          t <- lift' (javaType env False (binderType b))
          pure (Just (binderId b, n), [J.assigned (D.text ("final " ++ t ++ " " ++ n)) (D.text access)])
        else pure (Nothing, [])
      arm c accesses = do
        bound <- mapM (\(b, a) -> bindOne c b a) (zip (caseBinders c) accesses)
        body <- cstmt env selfCall ([x | (Just x, _) <- bound] ++ scope) target (caseBody c)
        pure (concatMap snd bound ++ body)
      blockOf ss = D.block 2 (D.joinWith D.hardline ss)
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], name)
    _ -> do
      (s, x) <- cexpr env scope value
      t <- fresh "matched"
      jt <- lift' (javaType env False ty)
      pure (s ++ [J.assigned (D.text ("final " ++ jt ++ " " ++ t)) x], t)
  let caseOf tag = [c | c <- cases, idText (caseConstructor c) == tag]
      two yesTag noTag condition yesAccess noAccess = do
        yes <- maybe (pure [D.text "throw LawSpecFast.unreachable();"]) (\c -> arm c yesAccess) (headMaybe (caseOf yesTag))
        no <- maybe (pure [D.text "throw LawSpecFast.unreachable();"]) (\c -> arm c noAccess) (headMaybe (caseOf noTag))
        pure (prelude ++ [D.text ("if (" ++ condition ++ ")") <> D.hardline <> blockOf yes <> D.hardline <> D.text "else" <> D.hardline <> blockOf no])
  case ty of
    Constructor "Maybe" _ -> two "Maybe::Present" "Maybe::Absent" (subject ++ ".isPresent()") [subject ++ ".get()"] []
    Constructor "Either" _ -> two "Either::Left" "Either::Right" (subject ++ ".isLeft()") [subject ++ ".left()"] [subject ++ ".right()"]
    Constructor "List" _ -> two "List::Nil" "List::Cons" (subject ++ ".isEmpty()") [] [subject ++ ".head()", subject ++ ".tail()"]
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases ->
          (prelude ++) <$> arm c [if kind == "KeyVal" then envPrefix env ++ "entriesOf(" ++ subject ++ ")" else subject ++ ".toList()"]
    Constructor n args | Just d <- M.lookup n (envData env) -> do
      let name = envPrefix env ++ envNames env M.! n
      witnesses <- lift' (mapM (javaType env True) [t | TypeArgument t <- args])
      let generic = if null witnesses then "" else "<" ++ intercalate ", " witnesses ++ ">"
          conOf c = snd (envConstructors env M.! caseConstructor c)
      if fieldless d
        then do
          arms <- forM cases $ \c -> do
            body <- arm c []
            pure (D.text ("case " ++ variantName env d (conOf c) ++ " -> ") <> blockOf body)
          pure (prelude ++ [D.text ("switch (" ++ subject ++ ")") <> D.hardline <> blockOf (arms ++ [D.text "default -> throw LawSpecFast.unreachable();"])])
        else if isProductType d
        then case cases of
          [c] -> (prelude ++) <$> arm c [subject ++ "." ++ fieldName f | f <- constructorFields (conOf c)]
          _ -> lift' (Left "typed Java: product match")
        else do
          arms <- forM cases $ \c -> do
            let con = conOf c
                index = length (takeWhile ((/= constructorId con) . constructorId) (dataConstructors d))
                cls = name ++ "." ++ variantName env d con ++ generic
            m <- fresh "case"
            body <- arm c [m ++ "." ++ fieldName f | f <- constructorFields con]
            let cast = [J.assigned (D.text ("final " ++ cls ++ " " ++ m)) (D.text ("(" ++ cls ++ ") " ++ subject)) | not (null (constructorFields con))]
            pure (D.text ("case " ++ show index ++ " -> ") <> blockOf (cast ++ body))
          pure (prelude ++ [D.text ("switch (" ++ subject ++ ".tag)") <> D.hardline <> blockOf (arms ++ [D.text "default -> throw LawSpecFast.unreachable();"])])
    _ -> lift' (Left ("typed Java: cannot match on " ++ show ty))
  where
    headMaybe xs = case xs of
      x : _ -> Just x
      [] -> Nothing


-- Native conversions.

-- | Whether a type converts to and from its native JVM type directly: no
-- Duration, Queue, Stack or Deque, whose native forms differ in shape.
nativeDirect :: Env -> S.Set String -> Type -> Bool
nativeDirect env seen ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Unit", "Integer", "Text", "Bytes"] || isFixed ty -> True
  Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> nativeDirect env seen a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> nativeDirect env seen a && nativeDirect env seen b
  _ | Just (_, args) <- collectionArguments ty -> all (nativeDirect env seen) args
  Constructor n args | isDurationType n || collectionContainer n /= Nothing -> False
                     | Just d <- M.lookup n (envData env) ->
      let table = zip (dataParameters d) [t | TypeArgument t <- args]
          key = show ty
      in key `S.member` seen || all (nativeDirect env (S.insert key seen) . substituteIn table . binderType) (concatMap constructorFields (dataConstructors d))
  _ -> False

substituteIn :: [(Id, Type)] -> Type -> Type
substituteIn table t = case t of
  TypeVariable v -> fromMaybe t (lookup v table)
  Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substituteIn table x); o -> o | a <- as]
  other -> other

-- | A type's native form, in Java syntax (boxed), for either style.
nativeTypeDoc :: Env -> Type -> Either String D.Doc
nativeTypeDoc env ty = case envStyle env of
  JavaStyle -> JavaData.javaDataTypeDoc (envDeclarations env) ty
  ScalaStyle -> Left "Scala's native types convert through their codecs"
  KotlinStyle -> case ty of
    Constructor n [] | Just t <- lookup n kotlinScalars -> pure (D.text t)
    Constructor "List" [TypeArgument a] -> apply "java.util.List" [a]
    Constructor "Maybe" [TypeArgument a] -> apply "lawspec.runtime.LawSpecRuntime.Maybe" [a]
    Constructor "Either" [TypeArgument a, TypeArgument b] -> apply "lawspec.runtime.LawSpecRuntime.Either" [a,b]
    _ | Just ("KeyVal", [k,v]) <- collectionArguments ty -> apply "java.util.Map" [k,v]
      | Just ("Set", [a]) <- collectionArguments ty -> apply "java.util.Set" [a]
    Constructor _ args -> do
      base <- nativeBase env ty
      types <- mapM (\a -> case a of TypeArgument t -> pure t; _ -> Left "index argument") args
      apply base types
    _ -> Left ("no native form for " ++ show ty)
  where
    apply name args = J.applied name <$> mapM (nativeTypeDoc env) args
    kotlinScalars = [ ("Bool", "Boolean"), ("Int8", "Byte"), ("Int16", "Short"), ("Int32", "Integer"), ("Int64", "Long")
                    , ("UInt8", "Short"), ("UInt16", "Integer"), ("UInt32", "Long"), ("Text", "String"), ("Bytes", "byte[]")
                    , ("Integer", "java.math.BigInteger"), ("Unit", "kotlin.Unit") ]

-- | A data type's native class, without type arguments.
nativeBase :: Env -> Type -> Either String String
nativeBase env (Constructor name _) = case envStyle env of
  JavaStyle -> JavaData.javaDataName (envDeclarations env) (Id name)
  KotlinStyle -> KotlinData.kotlinDataName (envDeclarations env) (Id name)
  ScalaStyle -> Left "Scala's native types convert through their codecs"
nativeBase _ _ = Left "no native class"

-- | A constructor's native class.
nativeVariant :: Env -> DataDeclaration -> DataConstructor -> String -> String
nativeVariant _ d c base
  | isProduct d = base
  | otherwise = base ++ "." ++ fromMaybe (constructorName c) (lookup (constructorId c) (caseNames (reverse (takeWhile (/= '.') (reverse base))) (dataConstructors d)))

-- | The scalar Java type a native field of a bounded integer type holds.
narrowCast :: Type -> String
narrowCast ty = case ty of
  Constructor n [] -> fromMaybe "" (lookup n [("Int8", "(byte) "), ("Int16", "(short) "), ("Int32", "(int) "), ("UInt8", "(short) "), ("UInt16", "(int) ")])
  _ -> ""

nativeHelpers :: Env -> M [D.Doc]
nativeHelpers env = go S.empty
  where
    go done = do
      st <- get
      let pending = [w | w <- S.toList (stWanted st), w `S.notMember` done]
      if null pending then pure [] else do
        docs <- forM pending $ \(kind, key) -> do
          let ty = stHelpers st M.! key
          memoHelper env kind ty
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

nativeHelper :: Env -> String -> Type -> M D.Doc
nativeHelper env kind ty | envStyle env == ScalaStyle = scalaHelper env kind ty
nativeHelper env kind ty = do
  t <- lift' (javaTypeDoc env True ty)
  n <- D.mapText unqualify <$> lift' (nativeTypeDoc env ty)
  let name = helperName env kind ty
      fn result parameter body = J.block
        (J.signature "public static " result name [parameter]) body
  if kind == "toNative"
    then fn n (J.parameter t "x") <$> toNative env ty
    else fn t (J.parameter n "n") <$> fromNative env ty

-- | A call with explicit generic witnesses, retained as type layout.
witnessCall :: String -> [D.Doc] -> String -> [D.Doc] -> D.Doc
witnessCall owner types name = J.callWith (D.text (owner ++ ".") <> J.applied "" types <> D.text name)

castDoc :: D.Doc -> D.Doc -> D.Doc
castDoc ty value = D.group (D.text "(" <> ty <> D.text ")" <> D.nest 4 (D.softline <> value))

toNative :: Env -> Type -> M [D.Doc]
toNative env ty = case ty of
  Constructor "Bool" [] -> pure [J.returned (D.text "x")]
  Constructor "Text" [] -> pure [J.returned (D.text "x")]
  Constructor "Integer" [] -> pure [J.returned (D.text "x")]
  Constructor "Unit" [] -> pure [J.returned (if envStyle env == KotlinStyle then D.text "kotlin.Unit.INSTANCE" else J.call "LawSpecRuntime.absent" [E.quoted "Unit"])]
  Constructor "Bytes" [] -> pure [J.returned (J.call "x.toArray" [])]
  _ | isFixed ty -> pure [J.returned (D.text (narrowCast ty) <> castDoc (D.text "long") (D.text "x"))]
  Constructor "List" [TypeArgument a] -> do
    c <- helper env "toNative" a
    na <- lift' (nativeTypeDoc env a)
    pure [ J.bind "out" (J.callWith (D.text "new " <> J.applied "java.util.ArrayList" [na]) [J.call "x.size" []])
         , J.block (D.text "for (var item : x)") [J.statement (J.call "out.add" [J.call c [D.text "item"]])]
         , J.returned (J.call "java.util.Collections.unmodifiableList" [D.text "out"]) ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper env "toNative" a
    pure [ J.block (D.text "if (x.isPresent())") [J.returned (J.call "new LawSpecRuntime.Present<>" [J.call c [J.call "x.get" []]])]
         , J.returned (J.call "new LawSpecRuntime.Absent<>" []) ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper env "toNative" a
    cr <- helper env "toNative" b
    pure [ J.block (D.text "if (x.isLeft())") [J.returned (J.call "new LawSpecRuntime.Left<>" [J.call cl [J.call "x.left" []]])]
         , J.returned (J.call "new LawSpecRuntime.Right<>" [J.call cr [J.call "x.right" []]]) ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper env "toNative" k
        cv <- helper env "toNative" v
        nk <- lift' (nativeTypeDoc env k)
        nv <- lift' (nativeTypeDoc env v)
        pure [ J.bind "out" (J.callWith (D.text "new " <> J.applied "java.util.LinkedHashMap" [nk,nv]) [])
             , J.statement (J.call "x.forEach" [J.lambdaValue ["k", "v"] (J.call "out.put" [J.call ck [D.text "k"], J.call cv [D.text "v"]])])
             , J.returned (J.call "java.util.Collections.unmodifiableMap" [D.text "out"]) ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper env "toNative" a
        na <- lift' (nativeTypeDoc env a)
        pure [ J.bind "out" (J.callWith (D.text "new " <> J.applied "java.util.LinkedHashSet" [na]) [])
             , J.block (D.text "for (var item : x.toList())") [J.statement (J.call "out.add" [J.call c [D.text "item"]])]
             , J.returned (J.call "java.util.Collections.unmodifiableSet" [D.text "out"]) ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envNames env M.! n
    base <- lift' (nativeBase env ty)
    typedArgs <- lift' (mapM (javaTypeDoc env True . snd) table)
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper env "toNative" (substituteIn table (binderType f))
    let made prefix c cs
          | null (constructorFields c) && kotlinObject d c = D.text (nativeVariant env d c base ++ ".INSTANCE")
          | otherwise = J.call ("new " ++ nativeVariant env d c base ++ if null table then "" else "<>")
              [J.call cv [D.text (prefix ++ fieldName f)] | (f, cv) <- zip (constructorFields c) cs]
        switch subject arms = J.block (D.text ("switch (" ++ subject ++ ")")) (arms ++ [D.text "default -> throw LawSpecFast.unreachable();"])
    if fieldless d
      then pure [switch "x" [J.arrowBlock (D.text ("case " ++ variantName env d c ++ " ->")) [J.returned (made "" c [])] | c <- dataConstructors d]]
      else if isProductType d
        then let c = firstOf (dataConstructors d) in pure [J.returned (made "x." c (firstOf converters))]
        else pure [switch "x.tag"
          [ J.arrowBlock (D.text ("case " ++ show k ++ " ->"))
              ([J.bind "y" (castDoc (J.applied (typedName ++ "." ++ variantName env d c) typedArgs) (D.text "x")) | not (null (constructorFields c))] ++
                [J.returned (made "y." c cs)])
          | (k, (c, cs)) <- zip [0 :: Int ..] (zip (dataConstructors d) converters) ]]
  _ -> lift' (Left ("typed Java: no native conversion for " ++ show ty))
  where
    kotlinObject d c = envStyle env == KotlinStyle && null (constructorFields c) && null (dataParameters d)

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  Constructor "Bool" [] -> pure [J.returned (D.text "n")]
  Constructor "Text" [] -> pure [J.returned (D.text "n")]
  Constructor "Integer" [] -> pure [J.returned (D.group (D.text "n instanceof java.math.BigInteger b ? b :" <>
    D.nest 4 (D.softline <> J.call "java.math.BigInteger.valueOf" [J.method (D.text "((Number) n)") "longValue" []])))]
  Constructor "Unit" [] -> pure [J.returned (D.text "LawSpecFast.Unit.UNIT")]
  Constructor "Bytes" [] -> pure [J.returned (J.call "new LawSpecFast.Bytes" [J.call "n.clone" []])]
  _ | isFixed ty -> pure [J.returned (J.call "n.longValue" [])]
  Constructor "List" [TypeArgument a] -> do
    c <- helper env "fromNative" a
    at <- lift' (javaTypeDoc env True a)
    pure [ J.assigned (J.applied "LawSpecFast.List" [at] <> D.text " out") (J.call "LawSpecFast.List.nil" [])
         , J.block (D.text "for (int i = n.size() - 1; i >= 0; i--)")
             [J.assigned (D.text "out") (J.call "LawSpecFast.List.cons" [J.call c [J.call "n.get" [D.text "i"]], D.text "out"])]
         , J.returned (D.text "out") ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper env "fromNative" a
    at <- lift' (javaTypeDoc env True a)
    na <- lift' (nativeTypeDoc env a)
    pure [ J.block (D.text "if (n instanceof " <> J.applied "LawSpecRuntime.Present" [na] <> D.text " j)")
             [J.returned (witnessCall "LawSpecFast.Maybe" [at] "present" [J.call c [J.call "j.value" []]])]
         , J.returned (witnessCall "LawSpecFast.Maybe" [at] "absent" []) ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper env "fromNative" a
    cr <- helper env "fromNative" b
    lt <- lift' (javaTypeDoc env True a)
    rt <- lift' (javaTypeDoc env True b)
    nl <- lift' (nativeTypeDoc env a)
    nr <- lift' (nativeTypeDoc env b)
    pure [ J.block (D.text "if (n instanceof " <> J.applied "LawSpecRuntime.Left" [nl,nr] <> D.text " l)")
             [J.returned (witnessCall "LawSpecFast.Either" [lt,rt] "left" [J.call cl [J.call "l.value" []]])]
         , J.bind "r" (castDoc (J.applied "LawSpecRuntime.Right" [nl,nr]) (D.text "n"))
         , J.returned (witnessCall "LawSpecFast.Either" [lt,rt] "right" [J.call cr [J.call "r.value" []]]) ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper env "fromNative" k
        cv <- helper env "fromNative" v
        kt <- lift' (javaTypeDoc env True k)
        vt <- lift' (javaTypeDoc env True v)
        pure [ J.assigned (J.applied "LawSpecFast.Map" [kt,vt] <> D.text " out") (J.call "LawSpecFast.Map.empty" [])
             , J.block (D.text "for (var entry : n.entrySet())")
                 [J.assigned (D.text "out") (J.call "out.put" [J.call ck [J.call "entry.getKey" []], J.call cv [J.call "entry.getValue" []]])]
             , J.returned (D.text "out") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper env "fromNative" a
        at <- lift' (javaTypeDoc env True a)
        pure [ J.assigned (J.applied "LawSpecFast.Set" [at] <> D.text " out") (J.call "LawSpecFast.Set.empty" [])
             , J.block (D.text "for (var item : n)") [J.assigned (D.text "out") (J.call "out.insert" [J.call c [D.text "item"]])]
             , J.returned (D.text "out") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envNames env M.! n
        accessor field = case envStyle env of
          KotlinStyle -> kotlinGetter (binderName field)
          _ -> binderName field
    base <- lift' (nativeBase env ty)
    nativeArgs <- lift' (mapM (nativeTypeDoc env . snd) table)
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper env "fromNative" (substituteIn table (binderType f))
    let made prefix c cs
          | fieldless d = D.text (typedName ++ "." ++ variantName env d c)
          | otherwise = J.call ("new " ++ (if isProductType d then typedName else typedName ++ "." ++ variantName env d c) ++ if null table then "" else "<>")
              [J.call cv [J.call (prefix ++ accessor f) []] | (f, cv) <- zip (constructorFields c) cs]
    if isProduct d
      then let c = firstOf (dataConstructors d) in pure [J.returned (made "n." c (firstOf converters))]
      else pure ([J.block (D.text ("if (n instanceof " ++ nativeVariant env d c base ++ ")"))
                   ([J.bind "y" (castDoc (J.applied (nativeVariant env d c base) nativeArgs) (D.text "n")) | not (null (constructorFields c))] ++
                     [J.returned (made "y." c cs)])
                 | (c, cs) <- zip (dataConstructors d) converters] ++ [D.text "throw LawSpecFast.unreachable();"])
  _ -> lift' (Left ("typed Java: no native conversion for " ++ show ty))

-- | The Java getter of a Kotlin property: isX stays, others get get.
kotlinGetter :: String -> String
kotlinGetter name = case name of
  'i' : 's' : c : _ | not (isLowerChar c) -> name
  c : rest -> "get" ++ toUpper' c : rest
  [] -> name
  where
    isLowerChar x = x >= 'a' && x <= 'z'
    toUpper' x = if x >= 'a' && x <= 'z' then toEnum (fromEnum x - 32) else x

-- | A direct conversion between a Scala native type and its typed form, as a
-- method of LawSpecTypedScala. Scala's own types (List, Option, Either, Map,
-- Set, BigInt, IArray, case classes and enums) meet the typed structures
-- (LawSpecFast and LawSpecTyped's classes) without the dynamic Value.
scalaHelper :: Env -> String -> Type -> M D.Doc
scalaHelper env kind ty = do
  typed <- lift' (scalaTypedDoc env ty)
  native <- lift' (scalaNativeDoc env ty)
  body <- if kind == "toNative" then scalaToNative env ty else scalaFromNative env ty
  let name = helperName env kind ty
      (parameter,result) = if kind == "toNative" then (D.text "x: " <> typed,native) else (D.text "n: " <> native,typed)
      signature = SL.parameters (D.text ("def " ++ name)) [parameter] <> D.text ": " <> result
  pure (signature <> D.text " = " <> SL.block body)

-- | Scala's type application is built from checked structure, including the
-- typed Java representation's boxed java.lang scalars.
scalaApplied :: String -> [D.Doc] -> D.Doc
scalaApplied name [] = D.text name
scalaApplied name args = D.group (D.text (name ++ "[") <>
  D.nest 2 (D.softbreak <> D.commaSep args) <> D.softbreak <> D.text "]")

scalaTypedDoc :: Env -> Type -> Either String D.Doc
scalaTypedDoc env ty = case ty of
  Constructor "Bool" [] -> atom "java.lang.Boolean"
  _ | isFixed ty -> atom "java.lang.Long"
  Constructor "Text" [] -> atom "java.lang.String"
  Constructor "Integer" [] -> atom "java.math.BigInteger"
  Constructor "Unit" [] -> atom (envFast env ++ ".Unit")
  Constructor "Bytes" [] -> atom (envFast env ++ ".Bytes")
  Constructor "List" [TypeArgument a] -> apply (envFast env ++ ".List") [a]
  Constructor "Maybe" [TypeArgument a] -> apply (envFast env ++ ".Maybe") [a]
  Constructor "Either" [TypeArgument a,TypeArgument b] -> apply (envFast env ++ ".Either") [a,b]
  _ | Just ("KeyVal",[k,v]) <- collectionArguments ty -> apply (envFast env ++ ".Map") [k,v]
    | Just ("Set",[a]) <- collectionArguments ty -> apply (envFast env ++ ".Set") [a]
  Constructor name args | Just native <- M.lookup name (envNames env) -> do
    types <- mapM (\argument -> case argument of TypeArgument t -> pure t; _ -> Left "typed Scala: index argument") args
    apply (envPrefix env ++ native) types
  _ -> Left ("no typed Scala form for " ++ show ty)
  where atom = pure . D.text
        apply name args = scalaApplied name <$> mapM (scalaTypedDoc env) args

scalaNativeDoc :: Env -> Type -> Either String D.Doc
scalaNativeDoc env = ScalaData.scalaDataTypeDoc (envDeclarations env)

scalaNativeBase :: Env -> String -> Either String String
scalaNativeBase env name = do
  names <- ScalaData.namesFor (envDeclarations env)
  maybe (Left "no native Scala data class") (Right . ("lawspec.data." ++)) (lookup (Id name) names)

-- | A callback keeps its parameter and arrow inside the call's opening;
-- the complete call decides whether its body moves to the next line.
scalaLambdaCall :: String -> String -> D.Doc -> D.Doc
scalaLambdaCall name parameters body = D.group
  (D.text (name ++ "(" ++ parameters ++ " =>") <> D.nest 2 (D.softline <> body) <>
    D.softbreak <> D.text ")")

scalaCase :: D.Doc -> D.Doc -> D.Doc
scalaCase pattern body = D.multiline (D.text "case " <> pattern <> D.text " =>" <> D.nest 2 (D.hardline <> body))

scalaAssign :: String -> D.Doc -> D.Doc
scalaAssign name value = D.group (D.text (name ++ " = ") <> value)

scalaToNative :: Env -> Type -> M [D.Doc]
scalaToNative env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "x.booleanValue"]
  Constructor "Text" [] -> pure [D.text "x"]
  Constructor "Integer" [] -> pure [SL.call "scala.math.BigInt" [D.text "x"]]
  Constructor "Unit" [] -> pure [D.text "()"]
  Constructor "Bytes" [] -> pure [SL.call "scala.IArray.unsafeFromArray" [SL.call "x.toArray" []]]
  Constructor n [] | isFixed ty -> pure [D.text ("x.longValue" ++ fromMaybe "" (lookup n [("Int8", ".toByte"),("Int16", ".toShort"),("Int32", ".toInt"),("UInt8", ".toShort"),("UInt16", ".toInt")]))]
  Constructor "List" [TypeArgument a] -> do
    c <- helper env "toNative" a
    native <- lift' (scalaNativeDoc env a)
    pure [scalaAssign "val out" (scalaApplied "scala.collection.immutable.List.newBuilder" [native]),
          scalaLambdaCall "x.forEach" "item" (D.text "out += " <> SL.call c [D.text "item"]), SL.call "out.result" []]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper env "toNative" a
    pure [D.group (D.text "if (x.isPresent) " <> SL.call "scala.Some" [SL.call c [D.text "x.get"]]), D.text "else scala.None"]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper env "toNative" a
    cr <- helper env "toNative" b
    pure [D.group (D.text "if (x.isLeft) " <> SL.call "scala.util.Left" [SL.call cl [D.text "x.left"]]),
          D.group (D.text "else " <> SL.call "scala.util.Right" [SL.call cr [D.text "x.right"]])]
  _ | Just ("KeyVal",[k,v]) <- collectionArguments ty -> do
        ck <- helper env "toNative" k
        cv <- helper env "toNative" v
        nk <- lift' (scalaNativeDoc env k)
        nv <- lift' (scalaNativeDoc env v)
        let tuple = SL.call "" [SL.call ck [D.text "k"],SL.call cv [D.text "v"]]
        pure [scalaAssign "val out" (scalaApplied "scala.collection.immutable.ListMap.newBuilder" [nk,nv]),
              scalaLambdaCall "x.forEach" "(k, v)" (D.text "out += (" <> tuple <> D.text ")"), SL.call "out.result" []]
    | Just ("Set",[a]) <- collectionArguments ty -> do
        c <- helper env "toNative" a
        native <- lift' (scalaNativeDoc env a)
        pure [scalaAssign "val out" (scalaApplied "scala.collection.immutable.ListSet.newBuilder" [native]),
              scalaLambdaCall "x.toList().forEach" "item" (D.text "out += " <> SL.call c [D.text "item"]), SL.call "out.result" []]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envPrefix env ++ envNames env M.! n
    base <- lift' (scalaNativeBase env n)
    typedArgs <- lift' (mapM (scalaTypedDoc env . snd) table)
    nativeArgs <- lift' (mapM (scalaNativeDoc env . snd) table)
    let nativeCase c = if isProduct d then base else base ++ "." ++ fromMaybe (constructorName c)
          (lookup (constructorId c) (caseNames (reverse (takeWhile (/= '.') (reverse base))) (dataConstructors d)))
        singleton c = not (isProduct d) && null (constructorFields c) && null (dataParameters d)
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper env "toNative" (substituteIn table (binderType f))
    let made prefix c cs
          | singleton c = D.text (nativeCase c)
          | otherwise = SL.callWith (scalaApplied (nativeCase c) (if isProduct d then [] else nativeArgs))
              [SL.call cv [D.text (prefix ++ ScalaData.escaped (fieldName f))] | (f,cv) <- zip (constructorFields c) cs]
    if fieldless d
      then pure [D.text "x match " <> SL.block
        [scalaCase (D.text (typedName ++ "." ++ variantName env d c)) (made "" c []) | c <- dataConstructors d]]
      else if isProductType d
        then let c = firstOf (dataConstructors d) in pure [made "x." c (firstOf converters)]
        else pure [D.text "x.tag match " <> SL.block
          ([D.text ("case " ++ show k ++ " => ") <> SL.block
              ([scalaAssign "val y" (scalaApplied "x.asInstanceOf" [scalaApplied (typedName ++ "." ++ variantName env d c) typedArgs]) | not (null (constructorFields c))] ++
                [made "y." c cs])
            | (k,(c,cs)) <- zip [0 :: Int ..] (zip (dataConstructors d) converters)] ++
            [D.text "case _ => throw lawspec.runtime.LawSpecFast.unreachable()"]) ]
  _ -> lift' (Left ("typed Scala: no native conversion for " ++ show ty))

scalaFromNative :: Env -> Type -> M [D.Doc]
scalaFromNative env ty = case ty of
  Constructor "Bool" [] -> pure [SL.call "java.lang.Boolean.valueOf" [D.text "n"]]
  Constructor "Text" [] -> pure [D.text "n"]
  Constructor "Integer" [] -> pure [D.text "n.bigInteger"]
  Constructor "Unit" [] -> pure [D.text "lawspec.runtime.LawSpecFast.Unit.UNIT"]
  Constructor "Bytes" [] -> pure [SL.call "lawspec.runtime.LawSpecFast.Bytes" [D.text "scala.IArray.genericWrapArray(n).toArray"]]
  _ | isFixed ty -> pure [SL.call "java.lang.Long.valueOf" [D.text "n.toLong"]]
  Constructor "List" [TypeArgument a] -> do
    c <- helper env "fromNative" a
    typed <- lift' (scalaTypedDoc env a)
    pure [scalaAssign "var out" (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.List.nil" [typed]) []),
          scalaLambdaCall "n.reverseIterator.foreach" "item" (scalaAssign "out" (SL.call "lawspec.runtime.LawSpecFast.List.cons" [SL.call c [D.text "item"],D.text "out"])), D.text "out"]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper env "fromNative" a
    typed <- lift' (scalaTypedDoc env a)
    pure [D.text "n match " <> SL.block
      [scalaCase (D.text "scala.Some(v)") (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Maybe.present" [typed]) [SL.call c [D.text "v"]]),
       scalaCase (D.text "scala.None") (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Maybe.absent" [typed]) [])]]
  Constructor "Either" [TypeArgument a,TypeArgument b] -> do
    cl <- helper env "fromNative" a
    cr <- helper env "fromNative" b
    lt <- lift' (scalaTypedDoc env a)
    rt <- lift' (scalaTypedDoc env b)
    pure [D.text "n match " <> SL.block
      [scalaCase (D.text "scala.util.Left(v)") (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Either.left" [lt,rt]) [SL.call cl [D.text "v"]]),
       scalaCase (D.text "scala.util.Right(v)") (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Either.right" [lt,rt]) [SL.call cr [D.text "v"]])]]
  _ | Just ("KeyVal",[k,v]) <- collectionArguments ty -> do
        ck <- helper env "fromNative" k
        cv <- helper env "fromNative" v
        kt <- lift' (scalaTypedDoc env k)
        vt <- lift' (scalaTypedDoc env v)
        pure [scalaAssign "var out" (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Map.empty" [kt,vt]) []),
              scalaLambdaCall "n.foreach" "(k, v)" (scalaAssign "out" (SL.call "out.put" [SL.call ck [D.text "k"],SL.call cv [D.text "v"]])),D.text "out"]
    | Just ("Set",[a]) <- collectionArguments ty -> do
        c <- helper env "fromNative" a
        typed <- lift' (scalaTypedDoc env a)
        pure [scalaAssign "var out" (SL.callWith (scalaApplied "lawspec.runtime.LawSpecFast.Set.empty" [typed]) []),
              scalaLambdaCall "n.foreach" "item" (scalaAssign "out" (SL.call "out.insert" [SL.call c [D.text "item"]])),D.text "out"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envPrefix env ++ envNames env M.! n
    base <- lift' (scalaNativeBase env n)
    typedArgs <- lift' (mapM (scalaTypedDoc env . snd) table)
    nativeArgs <- lift' (mapM (scalaNativeDoc env . snd) table)
    let nativeCase c = if isProduct d then base else base ++ "." ++ fromMaybe (constructorName c)
          (lookup (constructorId c) (caseNames (reverse (takeWhile (/= '.') (reverse base))) (dataConstructors d)))
        singleton c = not (isProduct d) && null (constructorFields c) && null (dataParameters d)
        field f = ScalaData.escaped (binderName f)
        pattern c | singleton c = D.text (nativeCase c)
                  | otherwise = D.text "y: " <> D.nest 4 (scalaApplied (nativeCase c) (if isProduct d then [] else nativeArgs)) <>
                      (if isProduct d || null nativeArgs then mempty else D.text " @unchecked")
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper env "fromNative" (substituteIn table (binderType f))
    let made prefix c cs
          | fieldless d = D.text (typedName ++ "." ++ variantName env d c)
          | otherwise = SL.callWith (D.text "new " <> scalaApplied (if isProductType d then typedName else typedName ++ "." ++ variantName env d c) typedArgs)
              [SL.call cv [D.text (prefix ++ field f)] | (f,cv) <- zip (constructorFields c) cs]
    if isProduct d
      then let c = firstOf (dataConstructors d) in pure [made "n." c (firstOf converters)]
      else pure [D.text "(n: Any) match " <> SL.block
        ([scalaCase (pattern c) (made "y." c cs) | (c,cs) <- zip (dataConstructors d) converters] ++
         [D.text "case _ => throw lawspec.runtime.LawSpecFast.unreachable()"]) ]
  _ -> lift' (Left ("typed Scala: no native conversion for " ++ show ty))

-- | A native type as LawSpecTyped (package lawspec.runtime) writes it.
unqualify :: String -> String
unqualify s = case s of
  [] -> []
  c : rest | not (isIdentifier c) -> c : unqualify rest
  _ -> let (word, rest) = span (\x -> isIdentifier x || x == '.') s in strip word ++ unqualify rest
  where
    isIdentifier x = x `elem` ('_' : '$' : ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'])
    strip w = case [r | p <- ["java.lang.", "lawspec.runtime."], Just r@(c : _) <- [stripPrefix p w], c `elem` ['A' .. 'Z'], '.' `notElem` takeWhile (/= '.') r] of
      r : _ -> r
      [] -> w

-- | An identity for a comment, in lines broken after its ::, a hash alone.
idLines :: String -> [String]
idLines identity = case break (== ':') identity of
  _ | length identity <= 80 -> ["(" ++ identity ++ ")."]
  _ -> let (namespace, hash) = splitAtLast identity in ["(" ++ namespace, hash ++ ")."]
  where
    splitAtLast s = let cut = maximum (0 : [i + 2 | i <- [0 .. length s - 2], take 2 (drop i s) == "::"]) in splitAt cut s
