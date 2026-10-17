-- | A program's data in Swift: its schema (what the runtime checks), its
-- native types (structs and enums with associated values, indirect where
-- recursive), and the codecs between them. Values compare and order as
-- LawSpec does, through the runtime's Portable protocol.
-- ref:DEC-idiomatic-generated-types ref:DEC-typed-core-boundary
-- ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Data
  ( Names, nativeType, codec, emitData, emitSchema, isRecord, isStruct, caseName, fieldName
  , nativeCollection, recursiveTypes, comparedParameters, typeParameterDeclarations
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D
import LawSpec.Core.Types (makeRegistry, freeExistentials)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Scalar (Scalar(..), primitive, primitives, primitiveName)
import LawSpec.Testing (GeneratorRequirement(..), domainHints)
import LawSpec.Regex (parseRegex, regexSamples)
import LawSpec.Common (Artifact(..))
import LawSpec.Swift.Code
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Expr as X
import qualified LawSpec.BeamGenerators as BeamGenerators
import LawSpec.NativeBinding (NativeRef(..), ConstructorStyle(..), ResolvedTypeBinding(..), ResolvedConstructorBinding(..), NativeLayout(..), foldNativeLayoutM)
import Control.Monad (forM)
import Data.List (intercalate, nub, sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set

-- | Each data declaration's native name.
type Names = [(C.Id, String)]

-- | The native Swift type of a LawSpec type.
nativeType :: Int -> Names -> [(C.Id, String)] -> C.Type -> Either String String
nativeType bits names parameters ty = case ty of
  C.TypeVariable identity -> Right (maybe "Value" id (lookup identity parameters))
  C.Constructor n args -> do
    ts <- mapM argument [t | C.TypeArgument t <- args]
    case (n, ts) of
      ("List", [t]) -> pure ("PersistentList<" ++ t ++ ">")
      ("Maybe", [t]) -> pure (optional t)
      ("Either", [a, b]) -> pure ("Either<" ++ a ++ ", " ++ b ++ ">")
      ("Nullable", [t]) -> pure ("Nullable<" ++ t ++ ">")
      ("Optional", [t]) -> pure ("Undefinable<" ++ t ++ ">")
      ("lawspec.time::type::Duration", []) -> pure "Duration"
      ("lawspec.collections::type::Set", [t]) -> pure ("SortedSet<" ++ t ++ ">")
      ("lawspec.collections::type::KeyVal", [k, v]) -> pure ("SortedMap<" ++ k ++ ", " ++ v ++ ">")
      (_, []) | Just _ <- primitive n -> pure (scalarType n)
      _ -> case lookup (C.Id n) names of
        Just name -> pure (if null ts then name else name ++ "<" ++ intercalate ", " ts ++ ">")
        Nothing -> Left ("no Swift native type for " ++ n)
  C.Arrow _ _ -> Left "function-valued data has no Swift native type"
  where
    argument = nativeType bits names parameters
    optional t = if any (`elem` (" &" :: String)) t then "(" ++ t ++ ")?" else t ++ "?"
    _ = bits

scalarType :: String -> String
scalarType n = case n of
  "Bool" -> "Bool"
  "Int8" -> "Int8"; "Int16" -> "Int16"; "Int32" -> "Int32"; "Int64" -> "Int64"
  "UInt8" -> "UInt8"; "UInt16" -> "UInt16"; "UInt32" -> "UInt32"; "UInt64" -> "UInt64"
  -- The machine-sized integers are Swift's own, checked against the
  -- profile's range by the schema.
  "IntSize" -> "Int"; "UIntSize" -> "UInt"; "UIntPtr" -> "UInt"
  "Unit" -> "Unit"; "Null" -> "Null"; "Undefined" -> "Undefined"
  "Text" -> "String"; "Bytes" -> "[UInt8]"
  "Char" -> "Unicode.Scalar"; "CodePoint" -> "UInt32"; "CodeUnit16" -> "UInt16"
  "CodePointText" -> "[UInt32]"; "Utf16Text" -> "[UInt16]"
  "Float32" -> "Float"; "Float64" -> "Double"
  "Complex64" -> "Complex64"; "Complex128" -> "Complex128"
  "Decimal" -> "ExactDecimal"; "Rational" -> "Rational"; "Symbol" -> "Symbol"
  _ -> "BigInt"

-- | The codec between a LawSpec type and its native type, as an expression.
codec :: Int -> Names -> [(C.Id, String)] -> C.Type -> Either String String
codec bits names parameters ty = case ty of
  C.TypeVariable identity -> Right (maybe "Codecs.portable" id (lookup identity parameters))
  C.Constructor n args -> do
    cs <- mapM argument [t | C.TypeArgument t <- args]
    case (n, cs) of
      ("List", [c]) -> pure ("Codecs.list(" ++ c ++ ")")
      ("Maybe", [c]) -> pure ("Codecs.maybe(" ++ c ++ ")")
      ("Either", [a, b]) -> pure ("Codecs.either(" ++ a ++ ", " ++ b ++ ")")
      ("Nullable", [c]) -> pure ("Codecs.nullable(" ++ c ++ ")")
      ("Optional", [c]) -> pure ("Codecs.optional(" ++ c ++ ")")
      ("lawspec.time::type::Duration", []) -> pure "Codecs.duration"
      ("lawspec.collections::type::Set", [c]) -> pure ("Codecs.set(" ++ c ++ ")")
      ("lawspec.collections::type::KeyVal", [k, v]) -> pure ("Codecs.keyVal(" ++ k ++ ", " ++ v ++ ")")
      (_, []) | Just p <- primitive n -> pure ("Codecs." ++ scalarCodec (primitiveName p))
      _ -> case lookup (C.Id n) names of
        Just name -> pure ("LawSpec.DataCodecs." ++ codecName name ++ "(" ++ intercalate ", " cs ++ ")")
        Nothing -> Left ("no Swift codec for " ++ n)
  C.Arrow _ _ -> Left "function-valued data has no Swift codec"
  where
    argument = codec bits names parameters

codecName :: String -> String
codecName = escape . camel

scalarCodec :: String -> String
scalarCodec n = case n of
  "Bool" -> "bool"; "Unit" -> "unit"; "Null" -> "null"; "Undefined" -> "undefined"
  "Text" -> "text"; "Bytes" -> "bytes"; "Char" -> "char"; "CodePoint" -> "codePoint"
  "CodeUnit16" -> "codeUnit16"; "CodePointText" -> "codePointText"; "Utf16Text" -> "utf16Text"
  "Float32" -> "float32"; "Float64" -> "float64"; "Complex64" -> "complex64"; "Complex128" -> "complex128"
  "Decimal" -> "decimal"; "Rational" -> "rational"; "Symbol" -> "symbol"
  "Int8" -> "int8"; "Int16" -> "int16"; "Int32" -> "int32"; "Int64" -> "int64"
  "UInt8" -> "uint8"; "UInt16" -> "uint16"; "UInt32" -> "uint32"; "UInt64" -> "uint64"
  "IntSize" -> "intSize"; "UIntSize" -> "uintSize"; "UIntPtr" -> "uintSize"
  _ -> "bigInt"

-- | Set, KeyVal and Duration are the runtime's SortedSet, SortedMap and
-- Swift's Duration, so they have no generated type.
nativeCollection :: C.DataDeclaration -> Bool
nativeCollection d = C.idText (C.dataId d) `elem` ["lawspec.collections::type::Set", "lawspec.collections::type::KeyVal", "lawspec.time::type::Duration"]

-- | A constructor's case: lowerCamelCase.
caseName :: C.DataConstructor -> String
caseName c = escape (camel (C.constructorName c))

-- | A field's label: lowerCamelCase.
fieldName :: String -> String
fieldName = escape . camel

-- | A record: one constructor with fields and no existentials.
isRecord :: C.DataDeclaration -> Bool
isRecord d = case C.dataConstructors d of
  [c] -> not (null (C.constructorFields c)) && null (C.constructorExistentials c)
  _ -> False

-- | A record that is a struct: one not on a cycle of types stored inline
-- (a struct cannot hold itself; an indirect enum can).
isStruct :: Set.Set C.Id -> C.DataDeclaration -> Bool
isStruct recursive d = isRecord d && not (Set.member (C.dataId d) recursive)

-- | The types that reach themselves through fields stored inline: directly,
-- or through Maybe, Either, presence and other data, but not through a list
-- or a sorted collection, which store their items apart.
recursiveTypes :: [C.DataDeclaration] -> Set.Set C.Id
recursiveTypes declarations = Set.fromList [C.dataId d | d <- declarations, reaches (C.dataId d)]
  where
    table = M.fromList [(C.dataId d, d) | d <- declarations]
    direct identity = case M.lookup identity table of
      Just d -> nub (concatMap (inline . C.binderType) (concatMap C.constructorFields (C.dataConstructors d)))
      Nothing -> []
    inline t = case t of
      C.Constructor n args
        | n `elem` ["List", "lawspec.collections::type::Set", "lawspec.collections::type::KeyVal"] -> []
        | M.member (C.Id n) table -> C.Id n : concat [inline a | C.TypeArgument a <- args]
        | otherwise -> concat [inline a | C.TypeArgument a <- args]
      _ -> []
    reaches start = go Set.empty (direct start)
      where
        go _ [] = False
        go seen (x : rest)
          | x == start = True
          | Set.member x seen = go seen rest
          | otherwise = go (Set.insert x seen) (direct x ++ rest)

-- | The parameters of a data type that must be Portable where the type is
-- declared: those a Set holds or a KeyVal keys on, directly or through
-- another type's such parameter.
comparedParameters :: [C.DataDeclaration] -> C.Id -> [Int]
comparedParameters declarations = \identity -> maybe [] id (lookup identity final)
  where
    final = go [(C.dataId d, []) | d <- declarations]
    go known =
      let next = [(C.dataId d, [i | (i, p) <- zip [0 ..] (C.dataParameters d), any (needs known p . C.binderType) (concatMap C.constructorFields (C.dataConstructors d))]) | d <- declarations]
      in if next == known then known else go next
    needs known p ty = case ty of
      C.Constructor "lawspec.collections::type::Set" [C.TypeArgument t] -> mentions p t || needs known p t
      C.Constructor "lawspec.collections::type::KeyVal" [C.TypeArgument k, C.TypeArgument v] -> mentions p k || needs known p k || needs known p v
      C.Constructor n args -> or [ (i `elem` maybe [] id (lookup (C.Id n) known) && mentions p t) || needs known p t
                                 | (i, C.TypeArgument t) <- zip [0 :: Int ..] args ]
      _ -> False
    mentions p ty = case ty of
      C.TypeVariable v -> v == p
      C.Constructor _ args -> any (\a -> case a of C.TypeArgument t -> mentions p t; _ -> False) args
      C.Arrow a b -> mentions p a || mentions p b

-- | A data type's generic parameters as declared: <T0: Portable, T1>.
typeParameterDeclarations :: [C.DataDeclaration] -> C.DataDeclaration -> String
typeParameterDeclarations declarations d
  | null (C.dataParameters d) = ""
  | otherwise = "<" ++ intercalate ", " [typeParameter i ++ (if i `elem` compared then ": Portable" else "") | (i, _) <- zip [0 ..] (C.dataParameters d)] ++ ">"
  where compared = comparedParameters declarations (C.dataId d)

-- | The types that hold one of some types: directly, or through other data.
reaching :: [C.Id] -> [C.DataDeclaration] -> Set.Set C.Id
reaching targets declarations = go (Set.fromList targets)
  where
    go found =
      let next = Set.union found (Set.fromList [C.dataId d | d <- declarations, any (mentions found . C.binderType) (concatMap C.constructorFields (C.dataConstructors d))])
      in if Set.size next == Set.size found then found else go next
    mentions found t = case t of
      C.Constructor n args -> Set.member (C.Id n) found || any (\a -> case a of C.TypeArgument x -> mentions found x; _ -> False) args
      _ -> False

-- | The data types file and the codecs file.
emitData :: D.Layout -> Int -> [ResolvedTypeBinding] -> [C.DataDeclaration] -> Either String [Artifact]
emitData layout bits bound declarations
  | null declarations = pure []
  | otherwise = do
      names <- dataNames declarations
      let boundIds = map (C.dataId . resolvedDeclaration) bound
          shapes = [d | d <- declarations, not (C.dataHandle d), not (nativeCollection d), C.dataId d `notElem` boundIds]
          handles = [d | d <- declarations, C.dataHandle d]
          recursive = recursiveTypes declarations
          -- Types that hold an application's own type compare as it does:
          -- they get no portable order of their own.
          opaque = reaching boundIds declarations
      types <- mapM (dataType names recursive opaque) shapes
      codecs <- mapM (dataCodec names recursive) shapes
      handleTypes <- forM handles $ \d -> do
        name <- named names d
        let native = maybe "AnyHandle" (refText . resolvedNativeType) (boundOf d)
        pure (D.text ("/// " ++ C.idText (C.dataId d) ++ ": a handle, a native object whose identity LawSpec keeps.") <> D.hardline <>
          D.text ("public typealias " ++ name ++ typeParams d ++ " = " ++ native))
      handleCodecs <- forM handles $ \d -> do
        name <- named names d
        let ps = [(typeParameter i, "t" ++ show i) | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
            tag = stringLiteral (C.idText (C.dataId d))
            (native, made) = case boundOf d of
              Just b -> (refText (resolvedNativeType b), "Codecs.handle(" ++ tag ++ ", " ++ refText (resolvedNativeType b) ++ ".self)")
              Nothing -> ("AnyHandle", "Codecs.anyHandle(" ++ tag ++ ")")
        pure (D.text ("/// " ++ C.idText (C.dataId d)) <> D.hardline <>
          D.text ("public static func " ++ codecName name ++ genericClause ps ++ "(" ++ intercalate ", " ["_ " ++ v ++ ": Codec<" ++ p ++ ">" | (p, v) <- ps] ++
            ") -> Codec<" ++ native ++ "> {") <> D.nest 4 (D.hardline <> D.text made) <>
          D.hardline <> D.text "}")
      boundTypes <- forM [b | b <- bound, not (C.dataHandle (resolvedDeclaration b))] $ \b -> do
        let d = resolvedDeclaration b
        name <- named names d
        pure (D.text ("/// " ++ C.idText (C.dataId d) ++ ": the application's own type, bound in lawspec.json.") <> D.hardline <>
          D.text ("public typealias " ++ name ++ typeParams d ++ " = " ++ refText (resolvedNativeType b) ++ typeParams d))
      boundCodecs <- mapM (boundCodec names) [b | b <- bound, not (C.dataHandle (resolvedDeclaration b))]
      let typesDoc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "import LawSpecRuntime" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (handleTypes ++ boundTypes ++ types) <> D.hardline
          codecsDoc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "import LawSpecRuntime" <> D.hardline <> D.hardline <>
            D.text "extension LawSpec {" <> D.nest 4 (D.hardline <>
              D.text "/// Conversions between portable values and the native data types." <> D.hardline <>
              D.text "public enum DataCodecs {" <> D.nest 4 (D.hardline <>
                D.joinWith (D.hardline <> D.hardline) (handleCodecs ++ boundCodecs ++ codecs)) <> D.hardline <> D.text "}") <> D.hardline <>
            D.text "}" <> D.hardline
      pure [ Artifact "src/LawSpec/LawSpecData.swift" (D.render layout typesDoc) "generated" "source"
           , Artifact "src/LawSpec/LawSpecDataCodecs.swift" (D.render layout codecsDoc) "generated" "source" ]
  where
    named names d = maybe (Left ("unnamed data " ++ C.idText (C.dataId d))) Right (lookup (C.dataId d) names)
    typeParams d = if null (C.dataParameters d) then "" else "<" ++ intercalate ", " [typeParameter i | (i, _) <- zip [0 ..] (C.dataParameters d)] ++ ">"
    genericClause ps = if null ps then "" else "<" ++ intercalate ", " (map fst ps) ++ ">"
    -- Each constructor's rank: its position among the type's constructors
    -- ordered by identity, as LawSpec orders them.
    ranks d = zip (sortOn C.idText (map C.constructorId (C.dataConstructors d))) [0 :: Int ..]
    rankOf d c = maybe 0 id (lookup (C.constructorId c) (ranks d))
    witnessCount d c = length (freeExistentials d c)
    witnessLabels d c = [S.witnessFieldName (witnessCount d c) k | k <- [0 .. witnessCount d c - 1]]
    scopeOf d c = zip (C.dataParameters d) [typeParameter i | i <- [0 ..]] ++ [(e, "Value") | e <- C.constructorExistentials c]
    codecScope d c = [(p, "t" ++ show i) | (i, p) <- zip [0 :: Int ..] (C.dataParameters d)] ++ [(e, "Codecs.portable") | e <- C.constructorExistentials c]
    selfType names d = do
      name <- named names d
      pure (name ++ typeParams d)
    conformances d = if null (C.dataParameters d) then ": Sendable" else ""
    whereClause d = intercalate ", " [typeParameter i ++ ": Portable" | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
    refText = intercalate "." . referenceParts
    boundOf d = case [b | b <- bound, C.dataId (resolvedDeclaration b) == C.dataId d] of
      b : _ -> Just b
      [] -> Nothing
    -- A bound type's codec builds and takes apart the application's values:
    -- a struct by its initializer and properties, an enum case, or a case
    -- without fields.
    boundCodec names b = do
      let d = resolvedDeclaration b
          native = refText (resolvedNativeType b) ++ typeParams d
          single = length (resolvedConstructors b) == 1
      name <- named names d
      arms <- forM (resolvedConstructors b) $ \rc -> do
        let c = resolvedConstructor rc
            tag = stringLiteral (C.idText (C.constructorId c))
            ctor = refText (resolvedNativeConstructor rc)
            nativeNames = map snd (resolvedFields rc)
        fieldCodecs <- forM (resolvedFields rc) $ \(binder, _) -> codec bits names (codecScope d c) (C.binderType binder)
        let converted = [n ++ ": try " ++ cd ++ ".toNative(f[" ++ show i ++ "])" | (i, (n, cd)) <- zip [0 :: Int ..] (zip nativeNames fieldCodecs)]
            count = show (length fieldCodecs)
            caseName' = last (resolvedNativeConstructor rc `seq` referenceParts (resolvedNativeConstructor rc))
            vars = ["f" ++ show i | (i, _) <- zip [0 :: Int ..] fieldCodecs]
        case resolvedFieldLayout rc of
          Just tree -> do
            let project parent nodes = concat [case node of
                  NativeLeaf _ argument -> ["let f" ++ show argument ++ " = " ++ value]
                  NativeRecord _ constructor children ->
                    ("guard case .data(" ++ stringLiteral (C.idText (C.constructorId constructor)) ++ ", let " ++ child ++ ") = " ++ value ++
                      ", " ++ child ++ ".count == " ++ show (length children) ++ " else { throw Codecs.invalid(" ++ stringLiteral name ++ ", value) }") : project child children
                  | (index,node) <- zip [0 :: Int ..] nodes,
                    let child = parent ++ "_" ++ show index,
                    let value = parent ++ "[" ++ show index ++ "]"]
                lets prefix expressions = ["let " ++ prefix ++ show i ++ " = " ++ expression | (i,expression) <- zip [0 :: Int ..] expressions]
                sequenceText = intercalate "; "
                nativeValues = ["nativeField" ++ show i | (i,_) <- zip [0 :: Int ..] fieldCodecs]
                toValues = ["try " ++ cd ++ ".toNative(" ++ v ++ ")" | (cd,v) <- zip fieldCodecs vars]
                toArm result = "case .data(" ++ tag ++ ", let f) where f.count == " ++ show (length tree) ++ ": " ++
                  sequenceText (project "f" tree ++ lets "nativeField" toValues ++ ["return " ++ result])
                leaf index = pure ("logicalField" ++ show index)
                record _ constructor children = pure (".data(" ++ stringLiteral (C.idText (C.constructorId constructor)) ++ ", [" ++ intercalate ", " children ++ "])")
            values <- foldNativeLayoutM leaf record tree
            let packed = ".data(" ++ tag ++ ", [" ++ intercalate ", " values ++ "])"
                convertedFields = intercalate ", " [n ++ ": " ++ v | (n,v) <- zip nativeNames nativeValues]
                fromArm inputs = sequenceText (lets "logicalField" ["try " ++ cd ++ ".fromNative(" ++ v ++ ")" | (cd,v) <- zip fieldCodecs inputs] ++ ["return " ++ packed])
            case resolvedConstructorStyle rc of
              RecordConstructor | not single -> Left ("Swift binds a record style only to a type with one constructor: " ++ C.idText (C.dataId d))
              RecordConstructor -> pure (toArm (ctor ++ "(" ++ convertedFields ++ ")"), fromArm ["native." ++ n | n <- nativeNames])
              _ -> pure
                (toArm (ctor ++ if null nativeValues then "" else "(" ++ convertedFields ++ ")"),
                 "case ." ++ caseName' ++ (if null vars then "" else "(" ++ intercalate ", " ["let " ++ v | v <- vars] ++ ")") ++ ": " ++ fromArm vars)
          Nothing -> case resolvedConstructorStyle rc of
            RecordConstructor | not single -> Left ("Swift binds a record style only to a type with one constructor: " ++ C.idText (C.dataId d))
            RecordConstructor -> pure
              ( "case .data(" ++ tag ++ ", let f) where f.count == " ++ count ++ ": return " ++ ctor ++ "(" ++ intercalate ", " converted ++ ")"
              , "return .data(" ++ tag ++ ", [" ++ intercalate ", " ["try " ++ cd ++ ".fromNative(native." ++ n ++ ")" | (n, cd) <- zip nativeNames fieldCodecs] ++ "])" )
            _ -> pure
              ( "case .data(" ++ tag ++ ", let f) where f.count == " ++ count ++ ": return " ++ ctor ++ (if null converted then "" else "(" ++ intercalate ", " converted ++ ")")
              , "case ." ++ caseName' ++ (if null vars then "" else "(" ++ intercalate ", " ["let " ++ v | v <- vars] ++ ")") ++ ": return .data(" ++ tag ++ ", [" ++
                  intercalate ", " ["try " ++ cd ++ ".fromNative(" ++ v ++ ")" | (cd, v) <- zip fieldCodecs vars] ++ "])" )
      let params = [(typeParameter i, "t" ++ show i) | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
          record = all (\rc -> resolvedConstructorStyle rc == RecordConstructor) (resolvedConstructors b)
          fromBody = if record then map (D.text . snd) arms
            else [D.text "switch native {", D.joinWith D.hardline (map (D.text . snd) arms), D.text "}"]
      pure (D.text ("/// " ++ C.idText (C.dataId d) ++ ", bound to " ++ native ++ ".") <> D.hardline <>
        D.text ("public static func " ++ codecName name ++ genericClause params ++ "(" ++ intercalate ", " ["_ " ++ v ++ ": Codec<" ++ p ++ ">" | (p,v) <- params] ++ ") -> Codec<" ++ native ++ "> {") <> D.nest 4 (D.hardline <>
          D.text ("Codec<" ++ native ++ ">(") <> D.nest 4 (D.hardline <>
            D.text ("toNative: { (value: Value) throws -> " ++ native ++ " in") <> D.nest 4 (D.hardline <>
              D.text "switch value {" <> D.hardline <> D.joinWith D.hardline (map (D.text . fst) arms) <> D.hardline <>
              D.text "default:" <> D.nest 4 (D.hardline <> D.text ("throw Codecs.invalid(" ++ stringLiteral name ++ ", value)")) <> D.hardline <> D.text "}") <>
            D.hardline <> D.text "}," <> D.hardline <>
            D.text ("fromNative: { (native: " ++ native ++ ") throws -> Value in") <> D.nest 4 (D.hardline <> D.joinWith D.hardline fromBody) <>
            D.hardline <> D.text "})")) <> D.hardline <> D.text "}")
    dataType names recursive opaque d = do
      name <- named names d
      self <- selfType names d
      let header = "/// " ++ C.idText (C.dataId d)
          portableWhere = if null (C.dataParameters d) then "" else " where " ++ whereClause d
          sendableWhere = intercalate ", " [typeParameter i ++ ": Sendable" | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
          -- Any data type may be a failure (fails with E), thrown as E.
          sendableExtension = if null (C.dataParameters d) then [D.text ("extension " ++ name ++ ": Error {}")] else
            [ D.text ("extension " ++ name ++ ": Sendable where " ++ sendableWhere ++ " {}") ]
      if isStruct recursive d then do
        c <- case C.dataConstructors d of { [one] -> Right one; _ -> Left "a Swift struct has one constructor" }
        fields <- forM (C.constructorFields c) $ \b -> do
          t <- nativeType bits names (scopeOf d c) (C.binderType b)
          pure (fieldName (C.binderName b), t)
        let declaration = D.text header <> D.hardline <>
              D.text ("public struct " ++ name ++ typeParameterDeclarations declarations d ++ conformances d ++ " {") <> D.nest 4 (D.hardline <>
                D.joinWith D.hardline [D.text ("public var " ++ f ++ ": " ++ t) | (f, t) <- fields] <> D.hardline <> D.hardline <>
                D.text ("public init(" ++ intercalate ", " [f ++ ": " ++ t | (f, t) <- fields] ++ ") {") <> D.nest 4 (D.hardline <>
                  D.joinWith D.hardline [D.text ("self." ++ unescaped f ++ " = " ++ f) | (f, _) <- fields]) <> D.hardline <> D.text "}") <> D.hardline <>
              D.text "}"
            access f = "a." ++ unescaped f
            other f = "b." ++ unescaped f
            portable = D.text ("extension " ++ name ++ ": Portable" ++ portableWhere ++ " {") <> D.nest 4 (D.hardline <>
              D.joinWith (D.hardline <> D.hardline)
                [ D.text ("public static func portableEqual(_ a: " ++ self ++ ", _ b: " ++ self ++ ") -> Bool {") <> D.nest 4 (D.hardline <>
                    D.text (intercalate " && " [ "Typed.equal(" ++ access f ++ ", " ++ other f ++ ")" | (f, _) <- fields ])) <> D.hardline <> D.text "}"
                , D.text ("public static func portableCompare(_ a: " ++ self ++ ", _ b: " ++ self ++ ") -> Int {") <> D.nest 4 (D.hardline <>
                    D.joinWith D.hardline (
                      [ D.text ("let c" ++ show i ++ " = Typed.compare(" ++ access f ++ ", " ++ other f ++ ")") <> D.hardline <>
                        D.text ("if c" ++ show i ++ " != 0 { return c" ++ show i ++ " }") | (i, (f, _)) <- zip [0 :: Int ..] fields ] ++
                      [ D.text "return 0" ])) <> D.hardline <> D.text "}"
                , D.text "public func portableHash(into hasher: inout Hasher) {" <> D.nest 4 (D.hardline <>
                    D.joinWith D.hardline [D.text (unescaped f ++ ".portableHash(into: &hasher)") | (f, _) <- fields]) <> D.hardline <> D.text "}" ]) <>
              D.hardline <> D.text "}"
        pure (D.joinWith (D.hardline <> D.hardline) ([declaration] ++ sendableExtension ++
          (if Set.member (C.dataId d) opaque then [] else [portable] ++ equatable name self portableWhere)))
      else do
        cases <- forM (C.dataConstructors d) $ \c -> do
          fields <- forM (C.constructorFields c) $ \b -> do
            t <- nativeType bits names (scopeOf d c) (C.binderType b)
            pure (fieldName (C.binderName b), t)
          let all' = fields ++ [(fieldName w, "String") | w <- witnessLabels d c]
          pure (c, all')
        let indirect = if Set.member (C.dataId d) recursive then "indirect " else ""
            declaration = D.text header <> D.hardline <>
              D.text ("public " ++ indirect ++ "enum " ++ name ++ typeParameterDeclarations declarations d ++ conformances d ++ " {") <> D.nest 4 (D.hardline <>
                D.joinWith D.hardline [ D.text ("case " ++ caseName c ++ (if null fs then "" else "(" ++ intercalate ", " [f ++ ": " ++ t | (f, t) <- fs] ++ ")"))
                                      | (c, fs) <- cases ]) <> D.hardline <> D.text "}"
            binds prefix fs = if null fs then "" else "(" ++ intercalate ", " [prefix ++ show i | (i, _) <- zip [0 :: Int ..] fs] ++ ")"
            pattern prefix c fs = "." ++ unescaped (caseName c) ++ binds prefix fs
            single = length cases == 1
            letCase fs = if null fs then "case (" else "case let ("
            equalArms = [ D.text (letCase fs ++ pattern "x" c fs ++ ", " ++ pattern "y" c fs ++ "):") <> D.nest 4 (D.hardline <>
                            D.text ("return " ++ (if null fs then "true" else intercalate " && " ["Typed.equal(x" ++ show i ++ ", y" ++ show i ++ ")" | (i, _) <- zip [0 :: Int ..] fs])))
                        | (c, fs) <- cases ] ++ [D.text "default:" <> D.nest 4 (D.hardline <> D.text "return false") | not single]
            compareArms = [ D.text (letCase fs ++ pattern "x" c fs ++ ", " ++ pattern "y" c fs ++ "):") <> D.nest 4 (D.hardline <>
                              D.joinWith D.hardline (
                                [ D.text ("let c" ++ show i ++ " = Typed.compare(x" ++ show i ++ ", y" ++ show i ++ ")") <> D.hardline <>
                                  D.text ("if c" ++ show i ++ " != 0 { return c" ++ show i ++ " }") | (i, _) <- zip [0 :: Int ..] fs ] ++
                                [ D.text "return 0" ]))
                          | (c, fs) <- cases ] ++
                          [D.text "default:" <> D.nest 4 (D.hardline <> D.text "return a.lawSpecRank < b.lawSpecRank ? -1 : 1") | not single]
            casePattern c fs = "." ++ unescaped (caseName c) ++ (if null fs then "" else "(" ++ intercalate ", " ["let x" ++ show i | (i, _) <- zip [0 :: Int ..] fs] ++ ")")
            rankArms = [ D.text ("case ." ++ unescaped (caseName c) ++ ": return " ++ show (rankOf d c)) | (c, _) <- cases ]
            hashArms = [ D.text ("case " ++ casePattern c fs ++ ":") <> D.nest 4 (D.hardline <>
                           D.joinWith D.hardline (D.text ("hasher.combine(" ++ show (rankOf d c) ++ ")") :
                             [D.text ("x" ++ show i ++ ".portableHash(into: &hasher)") | (i, _) <- zip [0 :: Int ..] fs]))
                       | (c, fs) <- cases ]
            portable = D.text ("extension " ++ name ++ ": Portable" ++ portableWhere ++ " {") <> D.nest 4 (D.hardline <>
              D.joinWith (D.hardline <> D.hardline) (
                [ D.text "/// The constructor's rank: its place among the type's constructors by identity." <> D.hardline <>
                  D.text "var lawSpecRank: Int {" <> D.nest 4 (D.hardline <> D.text "switch self {" <> D.hardline <> D.joinWith D.hardline rankArms <> D.hardline <> D.text "}") <>
                  D.hardline <> D.text "}" | not single ] ++
                [ D.text ("public static func portableEqual(_ a: " ++ self ++ ", _ b: " ++ self ++ ") -> Bool {") <> D.nest 4 (D.hardline <>
                    D.text "switch (a, b) {" <> D.hardline <> D.joinWith D.hardline equalArms <> D.hardline <> D.text "}") <> D.hardline <> D.text "}"
                , D.text ("public static func portableCompare(_ a: " ++ self ++ ", _ b: " ++ self ++ ") -> Int {") <> D.nest 4 (D.hardline <>
                    D.text "switch (a, b) {" <> D.hardline <> D.joinWith D.hardline compareArms <> D.hardline <> D.text "}") <> D.hardline <> D.text "}"
                , D.text "public func portableHash(into hasher: inout Hasher) {" <> D.nest 4 (D.hardline <>
                    D.text "switch self {" <> D.hardline <> D.joinWith D.hardline hashArms <> D.hardline <> D.text "}") <> D.hardline <> D.text "}" ])) <>
              D.hardline <> D.text "}"
        pure (D.joinWith (D.hardline <> D.hardline) ([declaration] ++ sendableExtension ++
          (if Set.member (C.dataId d) opaque then [] else [portable] ++ equatable name self portableWhere)))
    equatable name self portableWhere =
      [ D.text ("extension " ++ name ++ ": Equatable" ++ portableWhere ++ " {") <> D.nest 4 (D.hardline <>
          D.text ("public static func == (a: " ++ self ++ ", b: " ++ self ++ ") -> Bool { portableEqual(a, b) }")) <> D.hardline <> D.text "}"
      , D.text ("extension " ++ name ++ ": Hashable" ++ portableWhere ++ " {") <> D.nest 4 (D.hardline <>
          D.text "public func hash(into hasher: inout Hasher) { portableHash(into: &hasher) }") <> D.hardline <> D.text "}" ]
    unescaped f = filter (/= '`') f
    dataCodec names recursive d = do
      name <- named names d
      self <- selfType names d
      let params = [(typeParameter i, "t" ++ show i) | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
          signature = "public static func " ++ codecName name ++ typeParameterDeclarations declarations d ++ "(" ++
            intercalate ", " ["_ " ++ v ++ ": Codec<" ++ p ++ ">" | (p, v) <- params] ++ ") -> Codec<" ++ self ++ "> {"
      arms <- forM (C.dataConstructors d) $ \c -> do
        fieldCodecs <- forM (C.constructorFields c) $ \b -> codec bits names (codecScope d c) (C.binderType b)
        let witnessCodecs = replicate (witnessCount d c) "Codecs.text"
            allCodecs = fieldCodecs ++ witnessCodecs
            labels = map (fieldName . C.binderName) (C.constructorFields c) ++ map fieldName (witnessLabels d c)
            tag = stringLiteral (C.idText (C.constructorId c))
            converted = ["try " ++ cd ++ ".toNative(f[" ++ show i ++ "])" | (i, cd) <- zip [0 :: Int ..] allCodecs]
            made = if isStruct recursive d
              then name ++ "(" ++ intercalate ", " [unescaped l ++ ": " ++ v | (l, v) <- zip labels converted] ++ ")"
              else "." ++ unescaped (caseName c) ++ (if null converted then "" else "(" ++ intercalate ", " [unescaped l ++ ": " ++ v | (l, v) <- zip labels converted] ++ ")")
            toArm = D.text ("case .data(" ++ tag ++ ", let f) where f.count == " ++ show (length allCodecs) ++ ":") <>
              D.nest 4 (D.hardline <> D.text ("return " ++ made))
            fromValues vars = "[" ++ intercalate ", " ["try " ++ cd ++ ".fromNative(" ++ v ++ ")" | (cd, v) <- zip allCodecs vars] ++ "]"
            fromArm
              | isStruct recursive d = D.text ("return .data(" ++ tag ++ ", " ++ fromValues ["native." ++ unescaped l | l <- labels] ++ ")")
              | otherwise =
                  let vars = ["f" ++ show i | (i, _) <- zip [0 :: Int ..] allCodecs]
                  in D.text ("case ." ++ unescaped (caseName c) ++ (if null vars then "" else "(" ++ intercalate ", " ["let " ++ v | v <- vars] ++ ")") ++ ":") <>
                     D.nest 4 (D.hardline <> D.text ("return .data(" ++ tag ++ ", " ++ fromValues vars ++ ")"))
        pure (toArm, fromArm, null allCodecs)
      let allEmpty = all (\(_, _, e) -> e) arms
          toNative = D.text ("toNative: { (value: Value) throws -> " ++ self ++ " in") <> D.nest 4 (D.hardline <>
            D.text "switch value {" <> D.hardline <> D.joinWith D.hardline [a | (a, _, _) <- arms] <> D.hardline <>
            D.text "default:" <> D.nest 4 (D.hardline <> D.text ("throw Codecs.invalid(" ++ stringLiteral name ++ ", value)")) <> D.hardline <> D.text "}") <>
            D.hardline <> D.text "},"
          fromNative = if isStruct recursive d
            then D.text ("fromNative: { (native: " ++ self ++ ") throws -> Value in") <> D.nest 4 (D.hardline <> D.joinWith D.hardline [b | (_, b, _) <- arms]) <> D.hardline <> D.text "})"
            else D.text ("fromNative: { (native: " ++ self ++ ") " ++ (if allEmpty then "" else "throws ") ++ "-> Value in") <> D.nest 4 (D.hardline <>
              D.text "switch native {" <> D.hardline <> D.joinWith D.hardline [b | (_, b, _) <- arms] <> D.hardline <> D.text "}") <> D.hardline <> D.text "})"
      pure (D.text ("/// " ++ C.idText (C.dataId d)) <> D.hardline <> D.text signature <> D.nest 4 (D.hardline <>
        D.text ("Codec<" ++ self ++ ">(") <> D.nest 4 (D.hardline <> toNative <> D.hardline <> fromNative)) <> D.hardline <> D.text "}")

-- | The program's schema, built through the runtime: every constructor with
-- its field types, contracts, generation hints, index terms and witnesses.
emitSchema :: D.Layout -> Int -> Bool -> [C.DataDeclaration] -> Either String Artifact
emitSchema layout bits crypto declarations = do
  _ <- makeRegistry declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas, contracts) <- S.dataSchemasWithContracts declarations
  definitions <- forM schemas $ \definition -> do
    cs <- forM (S.constructors definition) $ \c -> do
      predicates <- sequence [predicate contract expression | contract <- contracts,
        S.contractTag contract == S.constructorTag c, expression <- S.contractPredicates contract]
      generators <- fmap concat $ mapM fieldGenerators
        [contract | contract <- contracts, S.contractTag contract == S.constructorTag c]
      let base = pure' "Schema" "constructor" [Str (S.constructorTag c), ListOf (Ty "[(String, TypeRef)]")
            [call "Schema" "field" [Str (S.fieldName f), Str (refKey (S.fieldType f))] | f <- S.fields c]]
          extras = [\acc -> pure' "Schema" "withPredicates" [ListOf (Ty "[FieldPredicate]") predicates, acc] | not (null predicates)] ++
            [\acc -> pure' "Schema" "withGenerators" [ListOf (Ty "[(Int, FieldGenerator)]") generators, acc] | not (null generators)] ++
            [\acc -> pure' "Schema" "withIndices" [ListOf (Ty "[String]") (map Str (S.constructorIndex c)), acc] | not (null (S.constructorIndex c))] ++
            [\acc -> pure' "Schema" "withRefinements" [ListOf (Ty "[(Int, TypeRef)]") [call "Schema" "refinement" [IntLit (toInteger i), Str (refKey t)] | (i, t) <- S.constructorRefinements c], acc] | not (null (S.constructorRefinements c))] ++
            [\acc -> pure' "Schema" "withExistentials" [IntLit (toInteger (S.constructorExistentials c)), acc] | S.constructorExistentials c > 0] ++
            [\acc -> pure' "Schema" "withWitnesses" [ListOf (Ty "[Int]") (map (IntLit . toInteger) (S.constructorWitnesses c)), acc] | not (null (S.constructorWitnesses c))]
      pure (foldl (\acc extra -> extra acc) base extras)
    let handle = any (\d -> C.idText (C.dataId d) == S.typeName definition && C.dataHandle d) declarations
    pure (pure' "Schema" "definition" [Str (S.typeName definition), IntLit (toInteger (S.parameterCount definition)),
      ListOf (Ty "[Schema.Constructor]") cs, BoolLit handle])
  let names = ["definition" ++ show i | (i, _) <- zip [0 :: Int ..] definitions]
      schema = foldr (\(n, d) rest -> Let n (Ty "Schema.DataDefinition") d rest)
        (call "Schema" "create" [ListOf (Ty "[Schema.DataDefinition]") (map Var names),
          ListOf (Ty "[String]") (map (Str . primitiveName) primitives), IntLit (toInteger bits)]) (zip names definitions)
      body = renderBody tSchema schema
      doc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
        D.text "import LawSpecRuntime" <> D.hardline <> D.hardline <>
        D.text "extension LawSpec {" <> D.nest 4 (D.hardline <>
          D.text "/// The program's data, as the runtime checks it." <> D.hardline <>
          D.text "public enum Program {" <> D.nest 4 (D.hardline <>
            D.text "/// Every data type of the program, its constructors and their contracts." <> D.hardline <>
            D.text "public static let schema: Schema = {" <> D.nest 4 (D.hardline <>
              (if crypto then D.text "// lawspec.crypto's default handlers answer through the runtime's Defaults." <> D.hardline <>
                D.text "Crypto.install()" <> D.hardline else mempty) <>
              D.text "do {" <> D.nest 4 (D.hardline <> D.text "return try build()") <> D.hardline <>
              D.text "} catch {" <> D.nest 4 (D.hardline <> D.text "fatalError(\"the program's schema is invalid: \\(error)\")") <> D.hardline <>
              D.text "}") <> D.hardline <> D.text "}()" <> D.hardline <> D.hardline <>
            D.text "private static func build() throws -> Schema {" <> D.nest 4 (D.hardline <> body) <> D.hardline <> D.text "}") <>
            D.hardline <> D.text "}") <> D.hardline <>
        D.text "}" <> D.hardline
  pure (Artifact "src/LawSpec/LawSpecProgram.swift" (D.render layout doc) "generated" "source")
  where
    refKey (S.Parameter i) = "$" ++ show i
    refKey (S.Named n []) = n
    refKey (S.Named n args) = n ++ concat [" (" ++ refKey a ++ ")" | a <- args]
    contractRender contract = do
      let local identity = maybe (error "unbound Swift constructor field") id
            (lookup identity [(C.binderId b, "field" ++ show i) | (i, b) <- zip [0 :: Int ..] (S.contractFields contract)])
          ref ty = do
            raw <- S.typeReference (S.contractParameters contract) ty
            pure (pure' "Schema" "substitute" [X.typeOfKey (refKey raw), Var "known"])
          key ty = (\r -> pure' "Scalar" "typeKey" [r]) <$> ref ty
      pure (X.Context bits (Var "schema") (Var "symbols") local
        (\_ _ _ -> Left "external call in a Swift constructor predicate") ref key)
    withFields contract = withEarlier (length (S.contractFields contract)) contract
    withEarlier count contract inner = Let "known" (Ty "[Int: TypeRef]") (pure' "Schema" "known" [Var "types"])
      (Let "symbols" tSymbols (Raw "SymbolContext()")
        (foldr (\(i, _) rest -> Let ("field" ++ show i) tValue (pure' "Runtime" "item" [IntLit i, Var "fields"]) rest)
          inner (zip [0 :: Integer ..] (take count (S.contractFields contract)))))
    predicate contract expression = do
      context <- contractRender contract
      body <- X.render context expression
      pure (Lambda [("schema", tSchema), ("types", Ty "[TypeRef]"), ("fields", tValues)] tBool (withFields contract (X.truth body)))
    -- Safe constructor-field bounds may depend on fields already drawn; the
    -- full predicate remains authoritative. ref:DEC-shrink-within-domain
    fieldGenerators contract = fmap concat $ forM (zip [0 :: Int ..] (S.contractFields contract)) $ \(i, binder) -> do
      let predicates = S.contractPredicates contract
          q = C.Quantifier binder predicates []
          requirement = GeneratorRequirement binder predicates [] [] (domainHints q) Nothing
          earlier = map C.binderId (take i (S.contractFields contract))
          available expression = all (`elem` earlier) (C.freeBinders expression)
          bounds = filter (available . snd) (BeamGenerators.directBounds requirement)
          lengths = filter (available . snd) (BeamGenerators.lengthBounds requirement ++ BeamGenerators.nonEmptyBounds requirement)
          hints = [hint | hint <- domainHints q ++ regexHints binder predicates, C.expressionType hint == C.binderType binder, available hint]
      if null bounds && null lengths && null hints then pure [] else do
        context <- contractRender contract
        let render = X.render context
        bs <- mapM (\(op, e) -> (\v -> TupleOf [Str (C.binaryName op), v]) <$> render e) bounds
        ls <- mapM (\(op, e) -> (\v -> TupleOf [Str (C.binaryName op), v]) <$> render e) lengths
        hs <- mapM render hints
        let pairTy = Ty "[(String, Value)]"
            hint = pure' "Schema" "hints" [ListOf pairTy bs, ListOf pairTy ls, ListOf tValues hs]
        pure [TupleOf [IntLit (toInteger (i + 1)), Lambda [("schema", tSchema), ("types", Ty "[TypeRef]"), ("fields", tValues)]
          (Ty "Schema.FieldHints") (withEarlier i contract hint)]]
    regexHints binder predicates =
      [ C.Expr (C.scalarType "Text") (C.Constant (SSequence "Text" (map fromEnum sample))) (C.GeneratedFrom (C.binderId binder))
      | C.binderType binder == C.scalarType "Text"
      , pattern <- nub (concatMap (patterns [C.binderId binder]) predicates)
      , Right regex <- [parseRegex pattern], sample <- regexSamples 24 regex ]
    patterns names e = case C.expressionNode e of
      C.ShortCircuit C.And a b -> patterns names a ++ patterns names b
      C.Let b value body | aliases names value -> patterns (C.binderId b : names) body
      C.Let _ value body -> patterns names value ++ patterns names body
      C.Helper C.RegexMatches [C.Expr _ (C.Constant (SSequence _ pattern)) _, subject] | aliases names subject -> [map toEnum pattern]
      _ -> []
    aliases names e = case C.expressionNode e of
      C.Local l -> l `elem` names
      C.Convert C.CheckedArgument _ inner -> aliases names inner
      _ -> False
