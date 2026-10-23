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
import Data.Char (isAlphaNum, isUpper, toLower)
import Data.List (intercalate, isPrefixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.JavaData as JavaData
import qualified LawSpec.KotlinData as KotlinData
import qualified LawSpec.ScalaData as ScalaData
import LawSpec.DataNames (isProduct, caseNames)
import LawSpec.Time (isDurationType)
import LawSpec.JvmNames (jvmClaimAll, jvmLocal, jvmMethod)
import LawSpec.RecordNames (recordDisplayNames)

data JvmTyped = JvmTyped
  { jvmTypedSource :: String
    -- The typed method of a typed definition, qualified.
  , jvmTypedFunction :: Id -> Maybe String
    -- A type's typed Java form (boxed), qualified.
  , jvmTypedType :: Type -> Either String String
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
data JvmStyle = JavaStyle | KotlinStyle | ScalaStyle deriving (Eq)

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
  }

-- | Fresh names, and the per-type native conversions the code asks for.
data St = St { stCounter :: Int, stHelpers :: M.Map String (Int, Type), stWanted :: S.Set (String, String) }

type M = StateT St (Either String)

initial :: St
initial = St 0 M.empty S.empty

fresh :: String -> M String
fresh base = do
  s <- get
  put s { stCounter = stCounter s + 1 }
  pure (jvmLocal "java" [] (sanitize base) ++ show (stCounter s))

-- | A conversion helper of a kind (tonative, fromnative) for a type.
helper :: String -> Type -> M String
helper kind ty = do
  s <- get
  let key = show ty
  index <- case M.lookup key (stHelpers s) of
    Just (i, _) -> pure i
    Nothing -> do
      let i = M.size (stHelpers s)
      put s { stHelpers = M.insert key (i, ty) (stHelpers s) }
      pure i
  modify (\st -> st { stWanted = S.insert (kind, key) (stWanted st) })
  pure (kind ++ show index)

-- | A header and its block, the brace on a line of its own.
braced :: String -> D.Doc -> D.Doc
braced header body = D.text header <> D.hardline <> D.block 2 body

sanitize :: String -> String
sanitize name = case [c | c <- map lower name, isAlphaNum c || c == '_'] of
  [] -> "v"
  cleaned@(c : _) | isAlphaNum c && not (c >= '0' && c <= '9') -> cleaned
  cleaned -> "v" ++ cleaned
  where lower c = if isUpper c then toLower c else c

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
  let plan = typedPlanPerforming jvmScalars declarations units
      datas = typedData plan
      names = dataNames datas
      -- Each typed function is named after its definition, numbered only
      -- on a clash. ref:DEC-readable-generated-names
      functions = M.fromList (zip (map fst (typedRepresentatives plan))
        (fst (jvmClaimAll (S.fromList (javaKeywords ++ reservedMembers)) [functionName c d | (c, d) <- typedRepresentatives plan])))
      env = Env plan names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions "" "LawSpecFast" style declarations
      -- Scala's conversions live outside LawSpecTyped, so they name it in full.
      scalaEnv = env { envPrefix = typedClassName ++ ".", envFast = "lawspec.runtime.LawSpecFast" }
  dataDocs <- mapM (dataDoc env) datas
  let signatureTypes = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                              | d <- M.elems (typedDefinitions plan) ]
      handlerTypes = [ t | h <- concatMap unitHandlers units, isTypedHandler plan h
                         , ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
  ((functionDocs, natives, nativeDocs), _) <- flip runStateT initial $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    direct <- forM [t | t <- nub (handlerTypes ++ signatureTypes), nativeDirect env S.empty t] $ \t -> do
      f <- helper "fromNative" t
      g <- helper "toNative" t
      pure (show t, (conversionOwner ++ "." ++ f, conversionOwner ++ "." ++ g))
    hs <- nativeHelpers (if style == ScalaStyle then scalaEnv else env)
    pure (fs, M.fromList direct, hs)
  -- Codecs every boundary needs, hoisted: one per type.
  boundary <- forM (nub (concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                                 | d <- M.elems (typedDefinitions plan) ] ++
                         [ t | h <- concatMap unitHandlers units, isTypedHandler plan h, (_, ty) <- handlerOperations h
                             , let (args, result) = functionType ty, t <- result : args ]))
    (\t -> (,) t <$> codecExpression env [] t)
  -- Each typed stateful handler's start state, made in Java for Java and
  -- Kotlin alike.
  let startable = [ (h, t, e) | h <- [x | x <- concatMap unitHandlers units, isTypedHandler plan x]
                             , Just (t, e) <- [handlerState h] ]
      startNames = fst (jvmClaimAll (S.fromList (M.elems functions ++ javaKeywords ++ reservedMembers))
        [jvmLocal "java" [] ("start " ++ handlerName h) | (h, _, _) <- startable])
      starting = [ (handlerId h, n, t, e) | ((h, t, e), n) <- zip startable startNames ]
  startDocs <- forM starting $ \(_, name, t, e) -> do
    jt <- javaType env True t
    (body, _) <- runStateT (cstmt env Nothing [] Return e) initial
    pure (D.text ("public static " ++ jt ++ " " ++ name ++ "(java.util.Map<String, Object> symbols)") <> D.hardline <>
      D.block 2 (D.joinWith D.hardline body))
  let boundaryNames = M.fromList [ (show t, "C" ++ show i) | (i, (t, _)) <- zip [0 :: Int ..] boundary ]
      codecDocs = [ D.text ("public static final LawSpecFast.Codec<" ++ either (const "?") id (javaType env True t) ++ "> " ++ boundaryNames M.! show t ++ " =") <>
                    D.nest 8 (D.hardline <> D.text (expr ++ ";")) | (t, expr) <- boundary ]
      helpers = entryHelpers env ++ orderingHelper env
      line = D.text
      source = line "// Generated by LawSpec. Do not edit." <> D.hardline <>
        line "package lawspec.runtime;" <> D.hardline <> D.hardline <>
        line "/** Typed checked definitions: see LawSpecFast. */" <> D.hardline <>
        line "@SuppressWarnings({\"unchecked\", \"rawtypes\", \"unused\"})" <> D.hardline <>
        line "public final class LawSpecTyped" <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
          ([line "private LawSpecTyped() {}"] ++ dataDocs ++ helpers ++ codecDocs ++ startDocs ++ functionDocs ++ [d | style /= ScalaStyle, d <- nativeDocs]))
      scalaSource = if style /= ScalaStyle || null nativeDocs then "" else D.render (D.Pretty 100)
        (line "// Generated by LawSpec. Do not edit." <> D.hardline <>
         line "package lawspec.runtime" <> D.hardline <> D.hardline <>
         line "/** Direct conversions between Scala's native types and typed checked definitions' (LawSpecTyped). */" <> D.hardline <>
         line "object LawSpecTypedScala" <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline) nativeDocs)) ++ "\n"
      lookupFunction identity = do
        c <- definitionClass plan identity
        (\n -> typedClassName ++ "." ++ n) <$> M.lookup c functions
      outside = env { envPrefix = typedClassName ++ ".", envFast = "lawspec.runtime.LawSpecFast" }
  pure JvmTyped
    { jvmTypedSource = D.render (D.Pretty 100) source ++ "\n"
    , jvmTypedFunction = lookupFunction
    , jvmTypedType = javaType outside True
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
    display = recordDisplayNames datas
    reserved = S.fromList (javaKeywords ++ words "LawSpecTyped LawSpecFast LawSpecRuntime Value Data String Long Boolean Object Integer Math Character Arrays Objects Override Number BigInteger Iterable Comparable Exception RuntimeException Unit")
    pick (taken, acc) d =
      let base = identifier (M.findWithDefault (dataName d) (dataId d) display)
          chosen = firstOf [n | n <- base : [base ++ "_" ++ show k | k <- [2 :: Int ..]], n `S.notMember` taken]
      in (S.insert chosen taken, (idText (dataId d), chosen) : acc)

fieldless :: DataDeclaration -> Bool
fieldless d = not (null (dataConstructors d)) && all (null . constructorFields) (dataConstructors d)

isProductType :: DataDeclaration -> Bool
isProductType d = length (dataConstructors d) == 1 && not (fieldless d)

-- | A type's Java form; boxed in generic positions.
javaType :: Env -> Bool -> Type -> Either String String
javaType env = javaTypeP env []

javaTypeP :: Env -> [(Id, String)] -> Bool -> Type -> Either String String
javaTypeP env parameters boxed ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> pure p
  Constructor "Bool" [] -> pure (if boxed then "Boolean" else "boolean")
  Constructor "Unit" [] -> pure (envFast env ++ ".Unit")
  _ | isFixed ty -> pure (if boxed then "Long" else "long")
  Constructor "Integer" [] -> pure "java.math.BigInteger"
  Constructor "Text" [] -> pure "String"
  Constructor "Bytes" [] -> pure (envFast env ++ ".Bytes")
  Constructor "List" [TypeArgument a] -> (\t -> envFast env ++ ".List<" ++ t ++ ">") <$> javaTypeP env parameters True a
  Constructor "Maybe" [TypeArgument a] -> (\t -> envFast env ++ ".Maybe<" ++ t ++ ">") <$> javaTypeP env parameters True a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    l <- javaTypeP env parameters True a
    r <- javaTypeP env parameters True b
    pure (envFast env ++ ".Either<" ++ l ++ ", " ++ r ++ ">")
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        kt <- javaTypeP env parameters True k
        vt <- javaTypeP env parameters True v
        pure (envFast env ++ ".Map<" ++ kt ++ ", " ++ vt ++ ">")
    | Just ("Set", [a]) <- collectionArguments ty -> (\t -> envFast env ++ ".Set<" ++ t ++ ">") <$> javaTypeP env parameters True a
  Constructor n args | Just name <- M.lookup n (envNames env) -> do
    rendered <- mapM (\a -> case a of TypeArgument t -> javaTypeP env parameters True t; _ -> Left "typed Java: index argument") args
    pure (envPrefix env ++ name ++ (if null rendered then "" else "<" ++ intercalate ", " rendered ++ ">"))
  _ -> Left ("no typed Java form for " ++ show ty)

-- | The codec of a type, as a Java expression; a declaration's parameters'
-- codecs are c0, c1, ...
codecExpression :: Env -> [(Id, String)] -> Type -> Either String String
codecExpression env parameters ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> pure p
  Constructor "Bool" [] -> pure "LawSpecFast.BOOL"
  Constructor "Unit" [] -> pure "LawSpecFast.UNIT"
  Constructor n [] | Just (lo, hi) <- lookup n fixedBounds -> pure ("LawSpecFast.integer(" ++ show n ++ ", " ++ longLiteral lo ++ ", " ++ longLiteral hi ++ ")")
  Constructor "Integer" [] -> pure "LawSpecFast.INTEGER"
  Constructor "Text" [] -> pure "LawSpecFast.TEXT"
  Constructor "Bytes" [] -> pure "LawSpecFast.BYTES"
  Constructor "List" [TypeArgument a] -> (\c -> "LawSpecFast.list(" ++ c ++ ")") <$> codecExpression env parameters a
  Constructor "Maybe" [TypeArgument a] -> (\c -> "LawSpecFast.maybe(" ++ c ++ ")") <$> codecExpression env parameters a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    l <- codecExpression env parameters a
    r <- codecExpression env parameters b
    pure ("LawSpecFast.either(" ++ l ++ ", " ++ r ++ ")")
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        kc <- codecExpression env parameters k
        vc <- codecExpression env parameters v
        pure ("LawSpecFast.keyVal(" ++ kc ++ ", " ++ vc ++ ")")
    | Just ("Set", [a]) <- collectionArguments ty -> (\c -> "LawSpecFast.set(" ++ c ++ ")") <$> codecExpression env parameters a
  Constructor n args | Just name <- M.lookup n (envNames env) -> do
    cs <- mapM (\a -> case a of TypeArgument t -> codecExpression env parameters t; _ -> Left "typed Java: index argument") args
    pure (envPrefix env ++ name ++ (if null cs then ".CODEC" else ".codec(" ++ intercalate ", " cs ++ ")"))
  _ -> Left ("no typed Java codec for " ++ show ty)

longLiteral :: Integer -> String
longLiteral n
  | n == -(2 ^ (63 :: Int)) = "Long.MIN_VALUE"
  | otherwise = show n ++ "L"

parameterNames :: DataDeclaration -> [(Id, String)]
parameterNames d = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]

fieldName :: Binder -> String
fieldName b = identifier (binderName b)

-- | Field comparisons and equality, by the field's Java form.
fieldEquals :: Type -> String -> String -> String
fieldEquals ty a b
  | primitiveType ty = a ++ " == " ++ b
  | otherwise = "java.util.Objects.equals(" ++ a ++ ", " ++ b ++ ")"

fieldCompare :: Type -> String -> String -> String
fieldCompare ty a b
  | isFixed ty = "Long.compare(" ++ a ++ ", " ++ b ++ ")"
  | ty == Constructor "Bool" [] = "Boolean.compare(" ++ a ++ ", " ++ b ++ ")"
  | otherwise = "LawSpecFast.compare(" ++ a ++ ", " ++ b ++ ")"

primitiveType :: Type -> Bool
primitiveType ty = isFixed ty || ty == Constructor "Bool" []

dataDoc :: Env -> DataDeclaration -> Either String D.Doc
dataDoc env d = do
  let name = envNames env M.! idText (dataId d)
      parameters = parameterNames d
      generics = if null parameters then "" else "<" ++ intercalate ", " (map snd parameters) ++ ">"
      ranks = constructorRanks d
      rank c = fromMaybe 0 (lookup (constructorId c) ranks)
      tagOf c = D.render D.Compact (E.quoted (idText (constructorId c)))
      variants = dataConstructors d
      line = D.text
      header = line ("/** " ++ dataName d ++ " (" ++ idText (dataId d) ++ "). */")
      codecParams = [("LawSpecFast.Codec<" ++ p ++ "> c" ++ show k) | (k, (_, p)) <- zip [0 :: Int ..] parameters]
      keyDoc = if null parameters then show (idText (dataId d))
        else "LawSpecFast.dataKey(" ++ show (idText (dataId d)) ++ concat [", c" ++ show k | k <- [0 .. length parameters - 1]] ++ ")"
      codecParamMap = [(v, "c" ++ show k) | (k, (v, _)) <- zip [0 :: Int ..] parameters]
  fieldTypes <- forM variants $ \c -> forM (constructorFields c) $ \f -> javaTypeP env parameters False (binderType f)
  fieldCodecs <- forM variants $ \c -> forM (constructorFields c) $ \f -> codecExpression env codecParamMap (binderType f)
  let codecHead = if null parameters
        then "public static final LawSpecFast.Codec<" ++ name ++ "> CODEC = codec();" ++ "\n\n" ++
             "private static LawSpecFast.Codec<" ++ name ++ "> codec()"
        else "public static " ++ generics ++ " LawSpecFast.Codec<" ++ name ++ generics ++ "> codec(" ++ intercalate ", " codecParams ++ ")"
      variantClass c = if isProductType d then name else name ++ "." ++ variantName env d c
      encodeArm c codecs = line ("case " ++ show (index c) ++ " -> ") <> D.block 2 (
        (if null (constructorFields c) then mempty else line ("var m = (" ++ variantClass c ++ generics ++ ") value;") <> D.hardline) <>
        line ("return LawSpecFast.value(key, " ++ tagOf c ++ concat [", " ++ codec ++ ".encode(m." ++ fieldName f ++ ")" | (f, codec) <- zip (constructorFields c) codecs] ++ ");"))
      decodeArm c codecs = line ("case " ++ tagOf c ++ " -> ") <> D.block 2 (line ("return " ++
        construction c [codec ++ ".decode(d.fields().get(" ++ show k ++ "))" | (k, codec) <- zip [0 :: Int ..] codecs] ++ ";"))
      construction c args
        | fieldless d = name ++ "." ++ variantName env d c
        | otherwise = "new " ++ variantClass c ++ (if null parameters then "" else "<>") ++ "(" ++ intercalate ", " args ++ ")"
      index c = length (takeWhile ((/= constructorId c) . constructorId) variants)
      codecDoc = line codecHead <> D.hardline <> D.block 2 (D.joinWith D.hardline
        [ line ("String key = " ++ keyDoc ++ ";")
        , line ("return new LawSpecFast.Codec<" ++ name ++ generics ++ ">()") <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
          [ braced "public String key()" (line "return key;")
          , line ("public LawSpecRuntime.Value encode(" ++ name ++ generics ++ " value)") <> D.hardline <> D.block 2
              (if fieldless d
                then line ("return LawSpecFast.value(key, switch (value) { " ++ concat ["case " ++ variantName env d c ++ " -> " ++ tagOf c ++ "; " | c <- variants] ++ "});")
                else line ("switch (" ++ (if isProductType d then "0" else "value.tag") ++ ")") <> D.hardline <> D.block 2 (D.joinWith D.hardline
                  (zipWith encodeArm variants fieldCodecs ++ [line "default -> throw LawSpecFast.unreachable();"])))
          , line ("public " ++ name ++ generics ++ " decode(LawSpecRuntime.Value value)") <> D.hardline <> D.block 2 (
              line "var d = LawSpecFast.fields(value);" <> D.hardline <>
              line "switch (d.tag())" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                (zipWith decodeArm variants fieldCodecs ++ [line ("default -> throw new IllegalArgumentException(\"expected " ++ dataName d ++ ", found \" + d.tag());")]))) ]) <> line ";" ])
      toStringDoc c = line "@Override" <> D.hardline <> braced "public String toString()"
        (D.group (line ("return " ++ show (constructorName c) ++ " +") <> D.nest 4 (D.softline <>
          E.call "java.util.List.of" (map (line . fieldName) (constructorFields c)))) <> line ";")
      fieldsDoc c ts = D.joinWith D.hardline [line ("public final " ++ t ++ " " ++ fieldName f ++ ";") | (f, t) <- zip (constructorFields c) ts]
      constructorDoc cls c ts superCall = line ("public " ++ cls ++ "(" ++ intercalate ", " [t ++ " " ++ fieldName f | (f, t) <- zip (constructorFields c) ts] ++ ")") <> D.hardline <>
        D.block 2 (D.joinWith D.hardline (superCall ++ [line ("this." ++ fieldName f ++ " = " ++ fieldName f ++ ";") | f <- constructorFields c]))
      equalsDoc cls c = line "@Override" <> D.hardline <> line "public boolean equals(Object other)" <> D.hardline <> D.block 2
        (braced ("if (!(other instanceof " ++ cls ++ " o))") (line "return false;") <> D.hardline <>
         line ("return " ++ intercalate " && " ("true" : [fieldEquals (binderType f) (fieldName f) ("o." ++ fieldName f) | f <- constructorFields c]) ++ ";"))
      hashDoc c = line "@Override" <> D.hardline <> line "public int hashCode()" <> D.hardline <> D.block 2
        (line ("return java.util.Objects.hash(" ++ intercalate ", " (show (rank c) : map fieldName (constructorFields c)) ++ ");"))
      compareFieldsDoc cls c = line "int compareFields(Object other)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
        ([line ("var o = (" ++ cls ++ ") other;") | not (null (constructorFields c))] ++
         concat [[line ("int c" ++ show k ++ " = " ++ fieldCompare (binderType f) (fieldName f) ("o." ++ fieldName f) ++ ";"),
                  braced ("if (c" ++ show k ++ " != 0)") (line ("return c" ++ show k ++ ";"))] | (k, f) <- zip [0 :: Int ..] (constructorFields c)] ++
         [line "return 0;"]))
  pure $ header <> D.hardline <> if fieldless d
    then line ("public enum " ++ name ++ " implements LawSpecFast.Ordered") <> D.hardline <> D.block 2 (D.joinWith D.hardline
      [ line (intercalate ", " [variantName env d c ++ "(" ++ show (rank c) ++ ")" | c <- variants] ++ ";")
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
           , line "if (tag != o.tag) return Integer.compare(RANKS[tag], RANKS[o.tag]);"
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
    [ D.text ("public static <K, V> LawSpecFast.Map<K, V> keyValOf(LawSpecFast.List<" ++ name ++ "<K, V>> entries)") <> D.hardline <> D.block 2
        (D.text "LawSpecFast.Map<K, V> map = LawSpecFast.Map.empty();" <> D.hardline <>
         braced ("for (" ++ name ++ "<K, V> e : entries)") (D.text "map = map.put(e.key, e.value);") <> D.hardline <> D.text "return map;")
    , D.text ("public static <K, V> LawSpecFast.List<" ++ name ++ "<K, V>> entriesOf(LawSpecFast.Map<K, V> map)") <> D.hardline <> D.block 2
        (D.text ("return map.toList((k, v) -> new " ++ name ++ "<>(k, v));")) ]

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envNames env) of
  Nothing -> []
  Just name ->
    [ D.text ("public static " ++ name ++ " ordering(int c)") <> D.hardline <> D.block 2
        (D.text ("return c < 0 ? " ++ name ++ ".Less : c == 0 ? " ++ name ++ ".Equal : " ++ name ++ ".Greater;")) ]

-- Functions.

data Target = Return | Assign String

type Scope = [(Id, String)]

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (_, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    ty <- lift' (javaType env False (binderType b))
    pure (binderId b, local, ty)
  resultType <- lift' (javaType env False result)
  let scope = [(i, l) | (i, l, _) <- params]
      selfCall = Just (c, map (\(_, l, _) -> l) params)
      looping = hasTailSelf env c (definitionBody d)
      contextual = isContextual (envPlan env) (declarationId declaration)
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l, _), b) <- zip params (definitionArguments d)]
      pure [D.text "return " <> x <> D.text ";"]
    Nothing -> cstmt env (if looping then selfCall else Nothing) scope Return (definitionBody d)
  let signature = D.text ("public static " ++ resultType ++ " " ++ name ++ "(" ++
        intercalate ", " (["java.util.Map<String, Object> symbols" | contextual] ++ [t ++ " " ++ l | (_, l, t) <- params]) ++ ")")
  pure (D.text ("/** " ++ idText (declarationId declaration) ++ " */") <> D.hardline <> signature <> D.hardline <> D.block 2
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
deliver Return x = D.text "return " <> x <> D.text ";"
deliver (Assign v) x = D.text (v ++ " = ") <> x <> D.text ";"

-- | Statements delivering an expression's value to a target.
cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    ty <- lift' (javaType env False (binderType binder))
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [D.text ("final " ++ ty ++ " " ++ local ++ " = ") <> x <> D.text ";"] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [D.text "if (" <> x <> D.text ")" <> D.hardline <> D.block 2 (D.joinWith D.hardline yes) <> D.text " else" <> D.hardline <> D.block 2 (D.joinWith D.hardline no)])
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
          pure (s ++ [D.text ("final " ++ ty ++ " " ++ t ++ " = ") <> x <> D.text ";"], D.text (p ++ " = " ++ t ++ ";"))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue;"])
  Helper Unreachable _ -> pure [D.text "throw LawSpecFast.unreachable();"]
  -- raise e delivers nothing: it throws.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    codec <- lift' (codecExpression env [] (expressionType x))
    pure (s ++ [D.text ("throw new LawSpecRuntime.Failure(" ++ D.render D.Compact (E.quoted (abilityKey ref)) ++ ", " ++ codec ++ ".encode(") <> v <> D.text "));"])
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
            pure (concatMap fst parts, D.text (envPrefix env ++ envFunctions env M.! c ++ "(") <> D.joinWith (D.text ", ") (context ++ map snd parts) <> D.text ")")
      ShortCircuit op a b -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        if null sb
          then pure (sa, D.text "(" <> xa <> D.text (if op == And then " && " else " || ") <> xb <> D.text ")")
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
        pure (sa ++ sb, D.text (envPrefix env ++ "ordering(LawSpecFast.compare(") <> xa <> D.text ", " <> xb <> D.text "))")
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
        pure (sa ++ sb, D.text "LawSpecRuntime.regexMatches(" <> xa <> D.text ", " <> xb <> D.text ".codePoints().toArray())")
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
        pure (concatMap fst parts, D.text (resultCodec ++ ".decode(lawspec.runtime.LawSpecDefinitionBodies." ++ jvmPerformName op ++ "(") <>
          D.joinWith (D.text ", ") (D.text "symbols" : [D.text (codec ++ ".encode(") <> x <> D.text ")" | (codec, x) <- zip codecs (map snd parts)]) <> D.text "))")
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
              , D.text "try" <> blockOf (s ++ [D.text (t ++ " = " ++ envFast env ++ ".Either." ++ witness ++ "right(") <> x <> D.text ");"]) <>
                D.hardline <> D.text "catch (LawSpecRuntime.Failure failure)" <> blockOf
                  [ braced ("if (!failure.ability.equals(" ++ D.render D.Compact (E.quoted (abilityKey ref)) ++ "))") (D.text "throw failure;")
                  , D.text (t ++ " = " ++ envFast env ++ ".Either." ++ witness ++ "left(" ++ codec ++ ".decode(failure.value));") ] ], D.text t)
      Helper Append [a, b] -> do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        pure (sa ++ sb, case expressionType a of
          Constructor "Text" [] -> paren (xa <> D.text " + " <> xb)
          Constructor "Bytes" [] -> D.text "LawSpecFast.appendBytes(" <> xa <> D.text ", " <> xb <> D.text ")"
          _ -> D.text "LawSpecFast.append(" <> xa <> D.text ", " <> xb <> D.text ")")
      Helper Slice [x, from, to] -> do
        (sx, v) <- cexpr env scope x
        (si, i) <- index from
        (sj, j) <- index to
        let f = case expressionType x of
              Constructor "Text" [] -> "LawSpecFast.sliceText"
              Constructor "Bytes" [] -> "LawSpecFast.sliceBytes"
              _ -> "LawSpecFast.slice"
        pure (sx ++ si ++ sj, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ", " <> j <> D.text ")")
      Helper At [x, k] -> do
        (sx, v) <- cexpr env scope x
        (si, i) <- index k
        let f = if expressionType x == Constructor "Bytes" [] then "LawSpecFast.atBytes" else "LawSpecFast.at"
        pure (sx ++ si, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ")")
      Helper Range [lo, hi] -> do
        (sa, a) <- cexpr env scope lo
        (sb, b) <- cexpr env scope hi
        pure (sa ++ sb, D.text "LawSpecFast.range(" <> a <> D.text ", " <> b <> D.text ")")
      Helper Octets [b] -> one "LawSpecFast.octets" b
      Helper BytesOf [xs] -> one "LawSpecFast.bytesOf" xs
      Helper Utf8 [t] -> one "LawSpecFast.utf8" t
      Helper TextOf [n] -> case expressionType n of
        Constructor "Integer" [] -> one "String.valueOf" n
        _ -> one "Long.toString" n
      Helper Join [sep, parts] -> do
        (sa, a) <- cexpr env scope sep
        (sb, b) <- cexpr env scope parts
        pure (sa ++ sb, D.text "LawSpecFast.join(" <> a <> D.text ", " <> b <> D.text ")")
      _ -> lift' (Left ("typed Java: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, D.text (f ++ "(") <> x <> D.text ")")
    -- An Integer index, as a long (clamped).
    index a = do
      l <- longExpr env scope a
      case l of
        Just r -> pure r
        Nothing -> do
          (s, x) <- bigExpr env scope a
          pure (s, D.text "LawSpecFast.index(" <> x <> D.text ")")
    raised ref x = do
      (s, v) <- cexpr env scope x
      codec <- lift' (codecExpression env [] (expressionType x))
      pure (s, D.text ("throw new LawSpecRuntime.Failure(" ++ D.render D.Compact (E.quoted (abilityKey ref)) ++ ", " ++ codec ++ ".encode(") <> v <> D.text "));")
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
      pure (sa ++ sb, xa <> D.text ("." ++ name ++ "(") <> xb <> D.text ")")

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

constant :: Env -> Type -> Scalar -> Either String D.Doc
constant env _ s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (D.text (envFast env ++ ".Unit.UNIT"))
  SInteger "Integer" n
    | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) -> pure (D.text ("java.math.BigInteger.valueOf(" ++ longLiteral n ++ ")"))
    | otherwise -> pure (D.text ("new java.math.BigInteger(\"" ++ show n ++ "\")"))
  SInteger _ n -> pure (D.text (longLiteral n))
  SSequence "Text" units -> pure (E.quoted (map toEnum units))
  SSequence "Bytes" units -> pure (D.text (envFast env ++ ".Bytes.of(" ++ intercalate ", " (map show units) ++ ")"))
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
    Just (s, x) -> pure (s, D.text "java.math.BigInteger.valueOf(" <> x <> D.text ")")
    Nothing -> case expressionNode e of
      Unary Negate a -> do
        (s, x) <- big a
        pure (s, x <> D.text ".negate()")
      Binary op _ a b | not (isComparison op) -> do
        (sa, xa) <- big a
        (sb, xb) <- big b
        pure (sa ++ sb, case op of
          Add -> xa <> D.text ".add(" <> xb <> D.text ")"
          Subtract -> xa <> D.text ".subtract(" <> xb <> D.text ")"
          Multiply -> xa <> D.text ".multiply(" <> xb <> D.text ")"
          Quotient -> D.text "LawSpecFast.quot(" <> xa <> D.text ", " <> xb <> D.text ")"
          Remainder -> D.text "LawSpecFast.rem(" <> xa <> D.text ", " <> xb <> D.text ")"
          _ -> D.text "LawSpecFast.pow(" <> xa <> D.text ", " <> xb <> D.text ")")
      _ -> cexpr env scope e
  where
    big a = case expressionType a of
      Constructor "Integer" [] -> bigExpr env scope a
      _ -> do
        (s, x) <- cexpr env scope a
        pure (s, D.text "java.math.BigInteger.valueOf(" <> x <> D.text ")")

binary :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
binary env scope e = case expressionNode e of
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let test = if primitiveType t
          then paren xa <> D.text " == " <> paren xb
          else D.text "java.util.Objects.equals(" <> xa <> D.text ", " <> xb <> D.text ")"
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
        pure (sa ++ sb, paren (xa <> D.text ".compareTo(" <> xb <> D.text ")" <> D.text symbol <> D.text "0"))
  _ -> bigExpr env scope e
  where
    widen a = case expressionType a of
      Constructor "Integer" [] -> a
      _ -> a { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) a }

convert :: Env -> Scope -> Type -> Expr -> M ([D.Doc], D.Doc)
convert env scope target value = case (target, expressionType value) of
  (Constructor "Integer" [], _) -> bigExpr env scope (value { expressionType = target, expressionNode = Convert Explicit target value })
  (Constructor t [], source) | Just (lo, hi) <- lookup t fixedBounds -> do
    let bounds = longLiteral lo ++ ", " ++ longLiteral hi ++ ", " ++ show t
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
              in Just (sa ++ sb, D.text ("LawSpecFast." ++ f ++ "(") <> xa <> D.text ", " <> xb <> D.text (", " ++ bounds ++ ")"))
            _ -> Nothing
        _ -> pure Nothing
      case fused of
        Just r -> pure r
        Nothing -> do
          l <- longExpr env scope value
          case l of
            Just (s, x) -> pure (s, D.text "LawSpecFast.narrow(" <> x <> D.text (", " ++ bounds ++ ")"))
            Nothing -> do
              (s, x) <- bigExpr env scope value
              pure (s, D.text "LawSpecFast.narrow(" <> x <> D.text (", " ++ bounds ++ ")"))
  _ -> lift' (Left ("typed Java: unsupported conversion to " ++ show target))

construct :: Env -> Type -> Id -> [D.Doc] -> [Expr] -> M D.Doc
construct env ty tag values _ = do
  boxed <- lift' (javaType env True ty)
  let argumentsOf = case ty of
        Constructor _ args -> [t | TypeArgument t <- args]
        _ -> []
  witnesses <- lift' (mapM (javaType env True) argumentsOf)
  let witness = "<" ++ intercalate ", " witnesses ++ ">"
  case (idText tag, values) of
    ("List::Nil", []) -> pure (D.text (envFast env ++ ".List." ++ witness ++ "nil()"))
    ("List::Cons", [h, t]) -> pure (D.text (envFast env ++ ".List." ++ witness ++ "cons(") <> h <> D.text ", " <> t <> D.text ")")
    ("Maybe::Absent", []) -> pure (D.text (envFast env ++ ".Maybe." ++ witness ++ "absent()"))
    ("Maybe::Present", [x]) -> pure (D.text (envFast env ++ ".Maybe." ++ witness ++ "present(") <> x <> D.text ")")
    ("Either::Left", [x]) -> pure (D.text (envFast env ++ ".Either." ++ witness ++ "left(") <> x <> D.text ")")
    ("Either::Right", [x]) -> pure (D.text (envFast env ++ ".Either." ++ witness ++ "right(") <> x <> D.text ")")
    (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> pure (D.text (envPrefix env ++ "keyValOf(") <> items <> D.text ")")
    (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (D.text (envFast env ++ ".Set.of(") <> items <> D.text ")")
    _ -> case M.lookup tag (envConstructors env) of
      Just (d, c) -> do
        let name = envPrefix env ++ envNames env M.! idText (dataId d)
            generic = if null witnesses then "" else witness
        pure $ if fieldless d then D.text (name ++ "." ++ variantName env d c)
          else if isProductType d then D.text ("new " ++ name ++ generic ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")"
          else D.text ("new " ++ name ++ "." ++ variantName env d c ++ generic ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")"
      Nothing -> lift' (Left ("typed Java: unknown constructor " ++ idText tag ++ " for " ++ boxed))

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, map fst args) of
  (KeyValOf, [es]) -> pure (D.text (envPrefix env ++ "keyValOf(") <> es <> D.text ")")
  (KeyValLookup, [k, m]) -> pure (m <> D.text ".get(" <> k <> D.text ")")
  (KeyValPut, [k, v, m]) -> pure (m <> D.text ".put(" <> k <> D.text ", " <> v <> D.text ")")
  (KeyValDelete, [k, m]) -> pure (m <> D.text ".remove(" <> k <> D.text ")")
  (KeyValKeys, [m]) -> pure (m <> D.text ".toList((k, v) -> k)")
  (KeyValValues, [m]) -> pure (m <> D.text ".toList((k, v) -> v)")
  (KeyValEntries, [m]) -> pure (D.text (envPrefix env ++ "entriesOf(") <> m <> D.text ")")
  (SetOf, [xs]) -> pure (D.text "LawSpecFast.Set.of(" <> xs <> D.text ")")
  (SetMember, [x, s]) -> pure (s <> D.text ".contains(" <> x <> D.text ")")
  (SetInsert, [x, s]) -> pure (s <> D.text ".insert(" <> x <> D.text ")")
  (SetRemove, [x, s]) -> pure (s <> D.text ".remove(" <> x <> D.text ")")
  (SetUnion, [s, t]) -> pure (s <> D.text ".union(" <> t <> D.text ")")
  (SetIntersection, [s, t]) -> pure (s <> D.text ".intersection(" <> t <> D.text ")")
  (SetDifference, [s, t]) -> pure (s <> D.text ".difference(" <> t <> D.text ")")
  _ -> lift' (Left ("typed Java: bad intrinsic " ++ show intrinsic))

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      bindOne c b access = if used c b
        then do
          n <- fresh (binderName b)
          t <- lift' (javaType env False (binderType b))
          pure (Just (binderId b, n), [D.text ("final " ++ t ++ " " ++ n ++ " = " ++ access ++ ";")])
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
      pure (s ++ [D.text ("final " ++ jt ++ " " ++ t ++ " = ") <> x <> D.text ";"], t)
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
            let cast = [D.text ("final " ++ cls ++ " " ++ m ++ " = (" ++ cls ++ ") " ++ subject ++ ";") | not (null (constructorFields con))]
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
nativeType :: Env -> Type -> Either String String
nativeType env ty = case envStyle env of
  JavaStyle -> JavaData.javaDataType (envDeclarations env) ty
  ScalaStyle -> Left "Scala's native types convert through their codecs"
  KotlinStyle -> case ty of
    Constructor n [] | Just t <- lookup n kotlinScalars -> pure t
    Constructor "List" [TypeArgument a] -> (\x -> "java.util.List<" ++ x ++ ">") <$> nativeType env a
    Constructor "Maybe" [TypeArgument a] -> (\x -> "lawspec.runtime.LawSpecRuntime.Maybe<" ++ x ++ ">") <$> nativeType env a
    Constructor "Either" [TypeArgument a, TypeArgument b] -> do
      l <- nativeType env a
      r <- nativeType env b
      pure ("lawspec.runtime.LawSpecRuntime.Either<" ++ l ++ ", " ++ r ++ ">")
    _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
          kt <- nativeType env k
          vt <- nativeType env v
          pure ("java.util.Map<" ++ kt ++ ", " ++ vt ++ ">")
      | Just ("Set", [a]) <- collectionArguments ty -> (\x -> "java.util.Set<" ++ x ++ ">") <$> nativeType env a
    Constructor _ args -> do
      base <- nativeBase env ty
      rendered <- mapM (\a -> case a of TypeArgument t -> nativeType env t; _ -> Left "index argument") args
      pure (base ++ (if null rendered then "" else "<" ++ intercalate ", " rendered ++ ">"))
    _ -> Left ("no native form for " ++ show ty)
  where
    kotlinScalars = [ ("Bool", "Boolean"), ("Int8", "Byte"), ("Int16", "Short"), ("Int32", "Integer"), ("Int64", "Long")
                    , ("UInt8", "Short"), ("UInt16", "Integer"), ("UInt32", "Long"), ("Text", "String"), ("Bytes", "byte[]")
                    , ("Integer", "java.math.BigInteger"), ("Unit", "kotlin.Unit") ]

-- | A data type's native class, without type arguments.
nativeBase :: Env -> Type -> Either String String
nativeBase env ty = case ty of
  Constructor n args -> do
    let unitArgs = [TypeArgument (Constructor "Unit" []) | TypeArgument _ <- args]
    full <- case envStyle env of
      JavaStyle -> JavaData.javaDataType (envDeclarations env) (Constructor n unitArgs)
      KotlinStyle -> KotlinData.kotlinDataType (envDeclarations env) (Constructor n unitArgs)
      ScalaStyle -> Left "Scala's native types convert through their codecs"
    pure (takeWhile (/= '<') full)
  _ -> Left "no native class"

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
          let (index, ty) = stHelpers st M.! key
          nativeHelper env kind index ty
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

nativeHelper :: Env -> String -> Int -> Type -> M D.Doc
nativeHelper env kind index ty | envStyle env == ScalaStyle = scalaHelper env kind index ty
nativeHelper env kind index ty = do
  t <- lift' (javaType env True ty)
  n <- lift' (nativeType env ty)
  let name = kind ++ show index
      line = D.text
      fn signature body = line ("public static " ++ signature ) <> D.hardline <> D.block 2 (D.joinWith D.hardline body)
  if kind == "toNative"
    then fn (n ++ " " ++ name ++ "(" ++ t ++ " x)") <$> toNative env ty
    else fn (t ++ " " ++ name ++ "(" ++ n ++ " n)") <$> fromNative env ty

toNative :: Env -> Type -> M [D.Doc]
toNative env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "return x;"]
  Constructor "Text" [] -> pure [D.text "return x;"]
  Constructor "Integer" [] -> pure [D.text "return x;"]
  Constructor "Unit" [] -> pure [D.text (if envStyle env == KotlinStyle then "return kotlin.Unit.INSTANCE;" else "return LawSpecRuntime.absent(\"Unit\");")]
  Constructor "Bytes" [] -> pure [D.text "return x.toArray();"]
  _ | isFixed ty -> pure [D.text ("return " ++ narrowCast ty ++ "(long) x;")]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "toNative" a
    na <- lift' (nativeType env a)
    pure [ D.text ("var out = new java.util.ArrayList<" ++ na ++ ">(x.size());")
         , D.text ("for (var item : x) out.add(" ++ c ++ "(item));")
         , D.text "return java.util.Collections.unmodifiableList(out);" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "toNative" a
    na <- lift' (nativeType env a)
    pure [ D.text ("if (x.isPresent()) return new LawSpecRuntime.Present<" ++ na ++ ">(" ++ c ++ "(x.get()));")
         , D.text ("return new LawSpecRuntime.Absent<" ++ na ++ ">();") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "toNative" a
    cr <- helper "toNative" b
    nl <- lift' (nativeType env a)
    nr <- lift' (nativeType env b)
    pure [ D.text ("if (x.isLeft()) return new LawSpecRuntime.Left<" ++ nl ++ ", " ++ nr ++ ">(" ++ cl ++ "(x.left()));")
         , D.text ("return new LawSpecRuntime.Right<" ++ nl ++ ", " ++ nr ++ ">(" ++ cr ++ "(x.right()));") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "toNative" k
        cv <- helper "toNative" v
        nk <- lift' (nativeType env k)
        nv <- lift' (nativeType env v)
        pure [ D.text ("var out = new java.util.LinkedHashMap<" ++ nk ++ ", " ++ nv ++ ">();")
             , D.text ("x.forEach((k, v) -> out.put(" ++ ck ++ "(k), " ++ cv ++ "(v)));")
             , D.text "return java.util.Collections.unmodifiableMap(out);" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "toNative" a
        na <- lift' (nativeType env a)
        pure [ D.text ("var out = new java.util.LinkedHashSet<" ++ na ++ ">();")
             , D.text ("for (var item : x.toList()) out.add(" ++ c ++ "(item));")
             , D.text "return java.util.Collections.unmodifiableSet(out);" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envNames env M.! n
    base <- lift' (nativeBase env ty)
    nativeArgs <- lift' (mapM (nativeType env . snd) table)
    typedArgs <- lift' (mapM (javaType env True . snd) table)
    let nativeGeneric = if null nativeArgs then "" else "<" ++ intercalate ", " nativeArgs ++ ">"
        typedGeneric = if null typedArgs then "" else "<" ++ intercalate ", " typedArgs ++ ">"
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> do
      let ft = substituteIn table (binderType f)
      h <- helper "toNative" ft
      pure (\access -> h ++ "(" ++ access ++ ")")
    let made prefix c cs
          | null (constructorFields c) && kotlinObject d c = nativeVariant env d c base ++ ".INSTANCE"
          | otherwise = "new " ++ nativeVariant env d c base ++ nativeGeneric ++ "(" ++ intercalate ", " [cv (prefix ++ fieldName f) | (f, cv) <- zip (constructorFields c) cs] ++ ")"
    if fieldless d
      then pure [ D.text "switch (x)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                    ([D.text ("case " ++ variantName env d c ++ " -> { return " ++ made "" c [] ++ "; }") | c <- dataConstructors d] ++
                     [D.text "default -> throw LawSpecFast.unreachable();"])) ]
      else if isProductType d
        then let c = firstOf (dataConstructors d) in pure [D.text ("return " ++ made "x." c (firstOf converters) ++ ";")]
        else pure [ D.text "switch (x.tag)" <> D.hardline <> D.block 2 (D.joinWith D.hardline
                      ([ D.text ("case " ++ show k ++ " -> ") <> D.block 2 (D.joinWith D.hardline
                           ([D.text ("var y = (" ++ typedName ++ "." ++ variantName env d c ++ typedGeneric ++ ") x;") | not (null (constructorFields c))] ++
                            [D.text ("return " ++ made "y." c cs ++ ";")]))
                       | (k, (c, cs)) <- zip [0 :: Int ..] (zip (dataConstructors d) converters) ] ++
                       [D.text "default -> throw LawSpecFast.unreachable();"])) ]
  _ -> lift' (Left ("typed Java: no native conversion for " ++ show ty))
  where
    -- A Kotlin data object: a constructor without fields of a type without
    -- parameters.
    kotlinObject d c = envStyle env == KotlinStyle && null (constructorFields c) && null (dataParameters d)

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "return n;"]
  Constructor "Text" [] -> pure [D.text "return n;"]
  Constructor "Integer" [] -> pure [D.text "return n instanceof java.math.BigInteger b ? b : java.math.BigInteger.valueOf(((Number) n).longValue());"]
  Constructor "Unit" [] -> pure [D.text "return LawSpecFast.Unit.UNIT;"]
  Constructor "Bytes" [] -> pure [D.text "return new LawSpecFast.Bytes(n.clone());"]
  _ | isFixed ty -> pure [D.text "return n.longValue();"]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "fromNative" a
    at <- lift' (javaType env True a)
    pure [ D.text ("LawSpecFast.List<" ++ at ++ "> out = LawSpecFast.List.nil();")
         , D.text "for (int i = n.size() - 1; i >= 0; i--) out = LawSpecFast.List.cons(" <> D.text (c ++ "(n.get(i)), out);")
         , D.text "return out;" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "fromNative" a
    at <- lift' (javaType env True a)
    na <- lift' (nativeType env a)
    pure [ D.text ("if (n instanceof LawSpecRuntime.Present<" ++ na ++ "> j) return LawSpecFast.Maybe.<" ++ at ++ ">present(" ++ c ++ "(j.value()));")
         , D.text ("return LawSpecFast.Maybe.<" ++ at ++ ">absent();") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "fromNative" a
    cr <- helper "fromNative" b
    lt <- lift' (javaType env True a)
    rt <- lift' (javaType env True b)
    nl <- lift' (nativeType env a)
    nr <- lift' (nativeType env b)
    pure [ D.text ("if (n instanceof LawSpecRuntime.Left<" ++ nl ++ ", " ++ nr ++ "> l) return LawSpecFast.Either.<" ++ lt ++ ", " ++ rt ++ ">left(" ++ cl ++ "(l.value()));")
         , D.text ("var r = (LawSpecRuntime.Right<" ++ nl ++ ", " ++ nr ++ ">) n;")
         , D.text ("return LawSpecFast.Either.<" ++ lt ++ ", " ++ rt ++ ">right(" ++ cr ++ "(r.value()));") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "fromNative" k
        cv <- helper "fromNative" v
        kt <- lift' (javaType env True k)
        vt <- lift' (javaType env True v)
        pure [ D.text ("LawSpecFast.Map<" ++ kt ++ ", " ++ vt ++ "> out = LawSpecFast.Map.empty();")
             , D.text ("for (var e : n.entrySet()) out = out.put(" ++ ck ++ "(e.getKey()), " ++ cv ++ "(e.getValue()));")
             , D.text "return out;" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "fromNative" a
        at <- lift' (javaType env True a)
        pure [ D.text ("LawSpecFast.Set<" ++ at ++ "> out = LawSpecFast.Set.empty();")
             , D.text ("for (var item : n) out = out.insert(" ++ c ++ "(item));")
             , D.text "return out;" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envNames env M.! n
    base <- lift' (nativeBase env ty)
    nativeArgs <- lift' (mapM (nativeType env . snd) table)
    typedArgs <- lift' (mapM (javaType env True . snd) table)
    let nativeGeneric = if null nativeArgs then "" else "<" ++ intercalate ", " nativeArgs ++ ">"
        typedGeneric = if null typedArgs then "" else "<" ++ intercalate ", " typedArgs ++ ">"
        accessor f = case envStyle env of
          JavaStyle -> binderName f ++ "()"
          KotlinStyle -> kotlinGetter (binderName f) ++ "()"
          ScalaStyle -> binderName f ++ "()"
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "fromNative" (substituteIn table (binderType f))
    let made prefix c cs
          | fieldless d = typedName ++ "." ++ variantName env d c
          | isProductType d = "new " ++ typedName ++ typedGeneric ++ "(" ++ intercalate ", " [cv ++ "(" ++ prefix ++ accessor f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
          | otherwise = "new " ++ typedName ++ "." ++ variantName env d c ++ typedGeneric ++ "(" ++ intercalate ", " [cv ++ "(" ++ prefix ++ accessor f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
    if isProduct d
      then let c = firstOf (dataConstructors d) in pure [D.text ("return " ++ made "n." c (firstOf converters) ++ ";")]
      else pure ([ D.text ("if (n instanceof " ++ nativeVariant env d c base ++ ")") <> D.hardline <> D.block 2 (D.joinWith D.hardline
                     ([D.text ("var y = (" ++ nativeVariant env d c base ++ nativeGeneric ++ ") n;") | not (null (constructorFields c))] ++
                      [D.text ("return " ++ made "y." c cs ++ ";")]))
                 | (c, cs) <- zip (dataConstructors d) converters ] ++ [D.text "throw LawSpecFast.unreachable();"])
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
scalaHelper :: Env -> String -> Int -> Type -> M D.Doc
scalaHelper env kind index ty = do
  t <- scalaTyped env ty
  n <- lift' (scalaNative env ty)
  body <- if kind == "toNative" then scalaToNative env ty else scalaFromNative env ty
  let name = kind ++ show index
      signature = if kind == "toNative" then name ++ "(x: " ++ t ++ "): " ++ n else name ++ "(n: " ++ n ++ "): " ++ t
  pure (D.text ("def " ++ signature ++ " = ") <> D.block 2 (D.joinWith D.hardline body))

-- | A typed form, in Scala's syntax: java.lang's names qualified.
scalaTyped :: Env -> Type -> M String
scalaTyped env ty = scalaSyntax <$> lift' (javaType env True ty)

scalaSyntax :: String -> String
scalaSyntax = go ' '
  where
    go _ [] = []
    go previous text@(c : rest)
      | c == '<' = '[' : go c rest
      | c == '>' = ']' : go c rest
      | isAlphaNum c || c == '_' =
          let (word, after) = span (\x -> isAlphaNum x || x == '_') text
              qualified = if previous /= '.' && word `elem` words "String Long Integer Short Byte Boolean Double Float Character Object Number" then "java.lang." ++ word else word
          in qualified ++ go (last word) after
      | otherwise = c : go c rest

scalaNative :: Env -> Type -> Either String String
scalaNative env = ScalaData.scalaDataType (envDeclarations env)

scalaToNative :: Env -> Type -> M [D.Doc]
scalaToNative env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "x.booleanValue"]
  Constructor "Text" [] -> pure [D.text "x"]
  Constructor "Integer" [] -> pure [D.text "scala.math.BigInt(x)"]
  Constructor "Unit" [] -> pure [D.text "()"]
  Constructor "Bytes" [] -> pure [D.text "scala.IArray.unsafeFromArray(x.toArray())"]
  Constructor n [] | isFixed ty -> pure [D.text ("x.longValue" ++ fromMaybe "" (lookup n [("Int8", ".toByte"), ("Int16", ".toShort"), ("Int32", ".toInt"), ("UInt8", ".toShort"), ("UInt16", ".toInt")]))]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "toNative" a
    na <- lift' (scalaNative env a)
    pure [ D.text ("val out = scala.collection.immutable.List.newBuilder[" ++ na ++ "]")
         , D.text ("x.forEach(item => out += " ++ c ++ "(item))")
         , D.text "out.result()" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "toNative" a
    pure [D.text ("if (x.isPresent) scala.Some(" ++ c ++ "(x.get)) else scala.None")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "toNative" a
    cr <- helper "toNative" b
    pure [D.text ("if (x.isLeft) scala.util.Left(" ++ cl ++ "(x.left)) else scala.util.Right(" ++ cr ++ "(x.right))")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "toNative" k
        cv <- helper "toNative" v
        nk <- lift' (scalaNative env k)
        nv <- lift' (scalaNative env v)
        pure [ D.text ("val out = scala.collection.immutable.ListMap.newBuilder[" ++ nk ++ ", " ++ nv ++ "]")
             , D.text ("x.forEach((k, v) => out += ((" ++ ck ++ "(k), " ++ cv ++ "(v))))")
             , D.text "out.result()" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "toNative" a
        na <- lift' (scalaNative env a)
        pure [ D.text ("val out = scala.collection.immutable.ListSet.newBuilder[" ++ na ++ "]")
             , D.text ("x.toList().forEach(item => out += " ++ c ++ "(item))")
             , D.text "out.result()" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envPrefix env ++ envNames env M.! n
    native <- lift' (scalaNative env ty)
    typedArgs <- mapM (scalaTyped env . snd) table
    nativeArgs <- lift' (mapM (scalaNative env . snd) table)
    let typedGeneric = if null typedArgs then "" else "[" ++ intercalate ", " typedArgs ++ "]"
        nativeGeneric = if null nativeArgs then "" else "[" ++ intercalate ", " nativeArgs ++ "]"
        base = takeWhile (/= '[') native
        nativeCase c = if isProduct d then base else base ++ "." ++ fromMaybe (constructorName c) (lookup (constructorId c) (caseNames (reverse (takeWhile (/= '.') (reverse base))) (dataConstructors d)))
        singleton c = not (isProduct d) && null (constructorFields c) && null (dataParameters d)
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "toNative" (substituteIn table (binderType f))
    let made prefix c cs
          | singleton c = nativeCase c
          | otherwise = nativeCase c ++ (if isProduct d || null nativeArgs then "" else nativeGeneric) ++ "(" ++ intercalate ", " [cv ++ "(" ++ prefix ++ ScalaData.escaped (fieldName f) ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
    if fieldless d
      then pure [ D.text "x match " <> D.block 2 (D.joinWith D.hardline
                    [D.text ("case " ++ typedName ++ "." ++ variantName env d c ++ " => " ++ made "" c []) | c <- dataConstructors d]) ]
      else if isProductType d
        then let c = firstOf (dataConstructors d) in pure [D.text (made "x." c (firstOf converters))]
        else pure [ D.text "x.tag match " <> D.block 2 (D.joinWith D.hardline
                      ([ D.text ("case " ++ show k ++ " => ") <> D.block 2 (D.joinWith D.hardline
                           ([D.text ("val y = x.asInstanceOf[" ++ typedName ++ "." ++ variantName env d c ++ typedGeneric ++ "]") | not (null (constructorFields c))] ++
                            [D.text (made "y." c cs)]))
                       | (k, (c, cs)) <- zip [0 :: Int ..] (zip (dataConstructors d) converters) ] ++
                       [D.text "case _ => throw lawspec.runtime.LawSpecFast.unreachable()"])) ]
  _ -> lift' (Left ("typed Scala: no native conversion for " ++ show ty))

scalaFromNative :: Env -> Type -> M [D.Doc]
scalaFromNative env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "java.lang.Boolean.valueOf(n)"]
  Constructor "Text" [] -> pure [D.text "n"]
  Constructor "Integer" [] -> pure [D.text "n.bigInteger"]
  Constructor "Unit" [] -> pure [D.text "lawspec.runtime.LawSpecFast.Unit.UNIT"]
  Constructor "Bytes" [] -> pure [D.text "lawspec.runtime.LawSpecFast.Bytes(scala.IArray.genericWrapArray(n).toArray)"]
  _ | isFixed ty -> pure [D.text "java.lang.Long.valueOf(n.toLong)"]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "fromNative" a
    at <- scalaTyped env a
    pure [ D.text ("var out = lawspec.runtime.LawSpecFast.List.nil[" ++ at ++ "]()")
         , D.text ("n.reverseIterator.foreach(item => out = lawspec.runtime.LawSpecFast.List.cons(" ++ c ++ "(item), out))")
         , D.text "out" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "fromNative" a
    at <- scalaTyped env a
    pure [D.text ("n match { case scala.Some(v) => lawspec.runtime.LawSpecFast.Maybe.present[" ++ at ++ "](" ++ c ++ "(v)); case scala.None => lawspec.runtime.LawSpecFast.Maybe.absent[" ++ at ++ "]() }")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "fromNative" a
    cr <- helper "fromNative" b
    lt <- scalaTyped env a
    rt <- scalaTyped env b
    pure [D.text ("n match { case scala.util.Left(v) => lawspec.runtime.LawSpecFast.Either.left[" ++ lt ++ ", " ++ rt ++ "](" ++ cl ++ "(v)); case scala.util.Right(v) => lawspec.runtime.LawSpecFast.Either.right[" ++ lt ++ ", " ++ rt ++ "](" ++ cr ++ "(v)) }")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "fromNative" k
        cv <- helper "fromNative" v
        kt <- scalaTyped env k
        vt <- scalaTyped env v
        pure [ D.text ("var out = lawspec.runtime.LawSpecFast.Map.empty[" ++ kt ++ ", " ++ vt ++ "]()")
             , D.text ("n.foreach((k, v) => out = out.put(" ++ ck ++ "(k), " ++ cv ++ "(v)))")
             , D.text "out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "fromNative" a
        at <- scalaTyped env a
        pure [ D.text ("var out = lawspec.runtime.LawSpecFast.Set.empty[" ++ at ++ "]()")
             , D.text ("n.foreach(item => out = out.insert(" ++ c ++ "(item)))")
             , D.text "out" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        typedName = envPrefix env ++ envNames env M.! n
    native <- lift' (scalaNative env ty)
    typedArgs <- mapM (scalaTyped env . snd) table
    nativeArgs <- lift' (mapM (scalaNative env . snd) table)
    let typedGeneric = if null typedArgs then "" else "[" ++ intercalate ", " typedArgs ++ "]"
        nativeGeneric = if null nativeArgs then "" else "[" ++ intercalate ", " nativeArgs ++ "]"
        base = takeWhile (/= '[') native
        nativeCase c = if isProduct d then base else base ++ "." ++ fromMaybe (constructorName c) (lookup (constructorId c) (caseNames (reverse (takeWhile (/= '.') (reverse base))) (dataConstructors d)))
        singleton c = not (isProduct d) && null (constructorFields c) && null (dataParameters d)
        field f = ScalaData.escaped (binderName f)
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "fromNative" (substituteIn table (binderType f))
    let made prefix c cs
          | fieldless d = typedName ++ "." ++ variantName env d c
          | isProductType d = "new " ++ typedName ++ typedGeneric ++ "(" ++ intercalate ", " [cv ++ "(" ++ prefix ++ field f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
          | otherwise = "new " ++ typedName ++ "." ++ variantName env d c ++ typedGeneric ++ "(" ++ intercalate ", " [cv ++ "(" ++ prefix ++ field f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
        pattern c | singleton c = nativeCase c
                  | otherwise = "y: " ++ nativeCase c ++ (if isProduct d || null nativeArgs then "" else nativeGeneric ++ " @unchecked")
    if isProduct d
      then let c = firstOf (dataConstructors d) in pure [D.text (made "n." c (firstOf converters))]
      else pure [ D.text "(n: Any) match " <> D.block 2 (D.joinWith D.hardline
                    ([D.text ("case " ++ pattern c ++ " => " ++ made "y." c cs) | (c, cs) <- zip (dataConstructors d) converters] ++
                     [D.text "case _ => throw lawspec.runtime.LawSpecFast.unreachable()"])) ]
  _ -> lift' (Left ("typed Scala: no native conversion for " ++ show ty))
