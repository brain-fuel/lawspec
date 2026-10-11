-- | A program's data on .NET: its schema (what the runtime checks), its
-- native types (F# records and unions, C# records), and the codecs between
-- them. Records and unions order and compare as LawSpec does.
-- ref:DEC-idiomatic-generated-types ref:DEC-typed-core-boundary
-- ref:DEC-fsharp-runtime-from-scratch
module LawSpec.DotNet.Data
  ( Names, nativeType, codec, typeParameter, emitData, emitSchema, schemaModule, dataDeclarationsOf
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D
import LawSpec.Core.Types (makeRegistry, freeExistentials)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Scalar (Scalar(..), primitive, primitives, primitiveName, family, Family(..))
import LawSpec.Testing (GeneratorRequirement(..), domainHints)
import LawSpec.Regex (parseRegex, regexSamples)
import LawSpec.Common (Artifact(..))
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import qualified LawSpec.DotNet.Expr as X
import qualified LawSpec.BeamGenerators as BeamGenerators
import LawSpec.NativeBinding (NativeRef(..), ConstructorStyle(..), ResolvedTypeBinding(..), ResolvedConstructorBinding(..))
import Control.Monad (forM)
import Data.List (intercalate, nub, sortOn)

-- | Each data declaration's native name.
type Names = [(C.Id, String)]

typeParameter :: Lang -> Int -> String
typeParameter FSharp i = "'T" ++ show i
typeParameter CSharp i = "T" ++ show i

dataDeclarationsOf :: [C.DataDeclaration] -> [C.DataDeclaration]
dataDeclarationsOf = id

-- | The native .NET type of a LawSpec type.
nativeType :: Lang -> Int -> Names -> [(C.Id, String)] -> C.Type -> Either String String
nativeType lang bits names parameters ty = case ty of
  C.TypeVariable identity -> maybe (Right (portableType lang)) Right (lookup identity parameters)
  C.Constructor n args -> do
    ts <- mapM argument args
    case (n, ts) of
      ("List", [t]) -> pure (generic "list" "FSharpList" [t])
      ("Maybe", [t]) -> pure (generic "option" "FSharpOption" [t])
      ("Either", [a, b]) -> pure (applied "LawSpec.Either" [a, b])
      ("Nullable", [t]) -> pure (applied "LawSpec.Nullable" [t])
      ("Optional", [t]) -> pure (applied "LawSpec.Optional" [t])
      ("lawspec.time::type::Duration", []) -> pure "System.TimeSpan"
      ("lawspec.collections::type::Set", [t]) -> pure (generic' "Set" "FSharpSet" [t])
      ("lawspec.collections::type::KeyVal", [k, v]) -> pure (generic' "Map" "FSharpMap" [k, v])
      (_, []) | Just _ <- primitive n -> scalarType n
      _ | lang == CSharp, Just _ <- lookup (handleKey (C.Id n)) names -> pure "object"
      _ -> case lookup (C.Id n) names of
        Just name -> pure (applied ("LawSpec.Data." ++ name) ts)
        Nothing -> Left ("no .NET native type for " ++ n)
  C.Arrow _ _ -> Left "function-valued data has no .NET native type"
  where
    argument (C.TypeArgument t) = nativeType lang bits names parameters t
    argument (C.IndexArgument _) = Right ""
    applied name [] = name
    applied name xs = name ++ "<" ++ intercalate ", " (filter (not . null) xs) ++ ">"
    generic fs cs [t] = case lang of
      FSharp -> (if ' ' `elem` t && not (isApplied t) then "(" ++ t ++ ")" else t) ++ " " ++ fs
      CSharp -> cs ++ "<" ++ t ++ ">"
    generic _ cs xs = applied cs xs
    generic' fs cs xs = applied (if lang == FSharp then fs else cs) xs
    isApplied t = last t == '>'
    scalarType n = Right $ case (lang, n) of
      (FSharp, "Bool") -> "bool"
      (CSharp, "Bool") -> "bool"
      (FSharp, "Int8") -> "sbyte"
      (CSharp, "Int8") -> "sbyte"
      (FSharp, "Int16") -> "int16"
      (CSharp, "Int16") -> "short"
      (FSharp, "Int32") -> "int"
      (CSharp, "Int32") -> "int"
      (FSharp, "Int64") -> "int64"
      (CSharp, "Int64") -> "long"
      (FSharp, "UInt8") -> "byte"
      (CSharp, "UInt8") -> "byte"
      (FSharp, "UInt16") -> "uint16"
      (CSharp, "UInt16") -> "ushort"
      (FSharp, "UInt32") -> "uint32"
      (CSharp, "UInt32") -> "uint"
      (FSharp, "UInt64") -> "uint64"
      (CSharp, "UInt64") -> "ulong"
      -- The machine-sized integers are 64-bit natively on both profiles, so
      -- one adapter serves both; the schema checks the profile's range.
      (FSharp, "IntSize") -> "int64"
      (CSharp, "IntSize") -> "long"
      (FSharp, "UIntSize") -> "uint64"
      (CSharp, "UIntSize") -> "ulong"
      (FSharp, "UIntPtr") -> "uint64"
      (CSharp, "UIntPtr") -> "ulong"
      (FSharp, "Unit") -> "unit"
      (CSharp, "Unit") -> "Unit"
      (_, "Null") -> "LawSpec.Null"
      (_, "Undefined") -> "LawSpec.Undefined"
      (FSharp, "Text") -> "string"
      (CSharp, "Text") -> "string"
      (FSharp, "Bytes") -> "byte[]"
      (CSharp, "Bytes") -> "byte[]"
      (_, "Char") -> "System.Text.Rune"
      (FSharp, "CodePoint") -> "int"
      (CSharp, "CodePoint") -> "int"
      (FSharp, "CodeUnit16") -> "char"
      (CSharp, "CodeUnit16") -> "char"
      (FSharp, "CodePointText") -> "int list"
      (CSharp, "CodePointText") -> "FSharpList<int>"
      (FSharp, "Utf16Text") -> "string"
      (CSharp, "Utf16Text") -> "string"
      (FSharp, "Float32") -> "float32"
      (CSharp, "Float32") -> "float"
      (FSharp, "Float64") -> "float"
      (CSharp, "Float64") -> "double"
      (_, "Complex64") -> "LawSpec.Complex64"
      (_, "Complex128") -> "System.Numerics.Complex"
      (_, "Decimal") -> "LawSpec.ExactDecimal"
      (_, "Rational") -> "LawSpec.Rational"
      (_, "Symbol") -> "LawSpec.Symbol"
      (FSharp, _) -> "bigint"
      (CSharp, _) -> "System.Numerics.BigInteger"

portableType :: Lang -> String
portableType _ = "LawSpec.Runtime.Value"

-- | The codec between a LawSpec type and its native type, as an expression.
codec :: Lang -> Int -> Names -> [(C.Id, String)] -> C.Type -> Either String String
codec lang bits names parameters ty = case ty of
  C.TypeVariable identity -> Right (maybe portable id (lookup identity parameters))
  C.Constructor n args -> do
    cs <- mapM argument [t | C.TypeArgument t <- args]
    case (n, cs) of
      ("List", [c]) -> pure (applied "list" "List" [c])
      ("Maybe", [c]) -> pure (applied "option" "Maybe" [c])
      ("Either", [a, b]) -> pure (applied "either" "Either" [a, b])
      ("Nullable", [c]) -> pure (applied "nullable" "Nullable" [c])
      ("Optional", [c]) -> pure (applied "optional" "Optional" [c])
      ("lawspec.time::type::Duration", []) -> pure (if lang == FSharp then "Codec.duration" else "Codecs.Duration")
      ("lawspec.collections::type::Set", [c]) -> pure (applied "set" "Set" [c])
      ("lawspec.collections::type::KeyVal", [k, v]) -> pure (applied "map" "KeyVal" [k, v])
      (_, []) | Just p <- primitive n -> pure (scalar p)
      _ -> case lookup (C.Id n) names of
        Just name -> pure (dataCodec name cs)
        Nothing -> Left ("no .NET codec for " ++ n)
  C.Arrow _ _ -> Left "function-valued data has no .NET codec"
  where
    argument = codec lang bits names parameters
    portable = case lang of FSharp -> "Codec.portable"; CSharp -> "Codecs.Portable"
    applied fs cs xs = case lang of
      FSharp -> "(Codec." ++ fs ++ " " ++ unwords xs ++ ")"
      CSharp -> "Codecs." ++ cs ++ "(" ++ intercalate ", " xs ++ ")"
    dataCodec name xs = case lang of
      FSharp -> "(LawSpec.Data.Codecs." ++ escapeFSharp (camel name) ++ " " ++ (if null xs then "()" else unwords xs) ++ ")"
      CSharp -> "LawSpec.Data.Codecs." ++ name ++ "(" ++ intercalate ", " xs ++ ")"
    scalar p = case lang of
      FSharp -> "Codec." ++ fsScalar (primitiveName p)
      CSharp -> "Codecs." ++ csScalar (primitiveName p)
    fsScalar n = case n of
      "Bool" -> "bool"; "Unit" -> "unit"; "Null" -> "nullValue"; "Undefined" -> "undefinedValue"
      "Text" -> "text"; "Bytes" -> "bytes"; "Char" -> "rune"; "CodePoint" -> "codePoint"
      "CodeUnit16" -> "codeUnit16"; "CodePointText" -> "codePointText"; "Utf16Text" -> "utf16Text"
      "Float32" -> "float32"; "Float64" -> "float64"; "Complex64" -> "complex64"; "Complex128" -> "complex128"
      "Decimal" -> "exactDecimal"; "Rational" -> "rational"; "Symbol" -> "symbol"
      "Int8" -> "int8"; "Int16" -> "int16"; "Int32" -> "int32"; "Int64" -> "int64"
      "UInt8" -> "uint8"; "UInt16" -> "uint16"; "UInt32" -> "uint32"; "UInt64" -> "uint64"
      "IntSize" -> "int64"
      "UIntSize" -> "uint64"
      "UIntPtr" -> "uint64"
      _ -> "bigint"
    csScalar n = case n of
      "Bool" -> "Bool"; "Unit" -> "Unit"; "Null" -> "Null"; "Undefined" -> "Undefined"
      "Text" -> "Text"; "Bytes" -> "Bytes"; "Char" -> "Char"; "CodePoint" -> "CodePoint"
      "CodeUnit16" -> "CodeUnit16"; "CodePointText" -> "CodePointText"; "Utf16Text" -> "Utf16Text"
      "Float32" -> "Float32"; "Float64" -> "Float64"; "Complex64" -> "Complex64"; "Complex128" -> "Complex128"
      "Decimal" -> "Decimal"; "Rational" -> "Rational"; "Symbol" -> "Symbol"
      "Int8" -> "Int8"; "Int16" -> "Int16"; "Int32" -> "Int32"; "Int64" -> "Int64"
      "UInt8" -> "UInt8"; "UInt16" -> "UInt16"; "UInt32" -> "UInt32"; "UInt64" -> "UInt64"
      "IntSize" -> "Int64"
      "UIntSize" -> "UInt64"
      "UIntPtr" -> "UInt64"
      _ -> "BigInteger"
    _ = family

-- ---------------------------------------------------------------------------
-- Native data types and codecs

data Shape = Shape
  { shapeDeclaration :: C.DataDeclaration
  , shapeName :: String
  , shapeParameters :: [(C.Id, String)]
  , shapeCases :: [Case] }

data Case = Case
  { caseTag :: String
  , caseName :: String
  , caseRank :: Int
  , caseFields :: [(String, C.Type)]
  , caseWitnesses :: Int }

shapes :: Lang -> Names -> [C.DataDeclaration] -> Either String [Shape]
shapes lang names declarations = forM [d | d <- declarations, not (C.dataHandle d), not (nativeCollection d)] $ \d -> do
  name <- maybe (Left ("unnamed data " ++ C.idText (C.dataId d))) Right (lookup (C.dataId d) names)
  let parameters = zip (C.dataParameters d) [typeParameter lang i | i <- [0 ..]]
      ranks = zip (sortOn C.idText (map C.constructorId (C.dataConstructors d))) [0 :: Int ..]
  cases <- forM (C.dataConstructors d) $ \c -> do
    let witnesses = length (freeExistentials d c)
    pure (Case (C.idText (C.constructorId c)) (pascal (C.constructorName c))
      (maybe 0 id (lookup (C.constructorId c) ranks))
      [(C.binderName b, C.binderType b) | b <- C.constructorFields c] witnesses)
  pure (Shape d name parameters cases)

-- | Set and KeyVal are F#'s persistent Set and Map (C#'s read-only set and
-- dictionary), so they have no generated type. ref:DEC-typed-native-definitions
nativeCollection :: C.DataDeclaration -> Bool
nativeCollection d = C.idText (C.dataId d) `elem` ["lawspec.collections::type::Set", "lawspec.collections::type::KeyVal", "lawspec.time::type::Duration"]

-- | The parameters of a data type that F# must compare: those a Set holds
-- or a KeyVal keys on, directly or through another type's such parameter.
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

isRecord :: Shape -> Bool
isRecord s = case shapeCases s of
  [c] -> not (null (caseFields c)) && caseWitnesses c == 0
  _ -> False

-- | The data types file and the codecs file.
emitData :: Lang -> D.Layout -> Int -> [ResolvedTypeBinding] -> [C.DataDeclaration] -> Either String [Artifact]
emitData FSharp layout bits bound declarations
  | null declarations = pure []
  | otherwise = do
      names <- dataNames declarations
      ss <- shapes FSharp names [d | d <- declarations, C.dataId d `notElem` boundIds]
      types <- mapM (fsharpType names) ss
      codecs <- mapM (fsharpCodec names) ss
      boundCodecs <- mapM (boundCodec names) [b | b <- bound, not (C.dataHandle (resolvedDeclaration b))]
      let handles = [d | d <- declarations, C.dataHandle d]
      handleTypes <- forM handles $ \d -> do
        name <- maybe (Left "unnamed handle") Right (lookup (C.dataId d) names)
        pure (D.text ("/// A handle: a native object whose identity LawSpec keeps.") <> D.hardline <>
          D.text ("type " ++ name ++ typeParams d ++ " = " ++ maybe "obj" boundHandleType (boundOf d)))
      handleCodecs <- forM handles $ \d -> do
        name <- maybe (Left "unnamed handle") Right (lookup (C.dataId d) names)
        let ps = [("t" ++ show i) | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
            native = maybe "obj" (const (name ++ typeParams d)) (boundOf d)
        pure (D.text ("[<CompiledName(\"" ++ name ++ "\")>]") <> D.hardline <> D.text ("let " ++ escapeFSharp (camel name) ++ typeParams d ++ " " ++ (if null ps then "()" else unwords ["(_" ++ p ++ ": Codec<'T" ++ drop 1 p ++ ">)" | p <- ps]) ++
          " : Codec<" ++ native ++ "> = Codec.handle<" ++ native ++ "> " ++ stringLiteral FSharp (C.idText (C.dataId d))))
      aliases <- forM [b | b <- bound, not (C.dataHandle (resolvedDeclaration b))] $ \b -> do
        let d = resolvedDeclaration b
        name <- maybe (Left "unnamed data") Right (lookup (C.dataId d) names)
        pure (D.text ("/// " ++ C.idText (C.dataId d) ++ ": the application's own type, bound in lawspec.json.") <> D.hardline <>
          D.text ("type " ++ name ++ typeParams d ++ " = " ++ refText (resolvedNativeType b)))
      let typesDoc = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
            D.text "namespace LawSpec.Data" <> D.hardline <> D.hardline <>
            D.text "open LawSpec.Runtime" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (handleTypes ++ aliases ++ zipWith (\i (doc, attrs, t) -> D.text doc <> D.hardline <>
              (if i == (0 :: Int) then D.text attrs <> D.hardline <> D.text "type " else D.text ("and " ++ attrs ++ " ")) <> t) [0 ..] types) <> D.hardline
          codecsHeader = "// Generated by LawSpec. Do not edit.\n/// Conversions between portable values and the native data types.\nmodule LawSpec.Data.Codecs\n\n"
          codecsDoc = D.text "open LawSpec.Runtime" <> D.hardline <> D.text "open LawSpec.Data" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) (handleCodecs ++ zipWith (\i c -> (if i == (0 :: Int) then D.text "let rec " else D.text "and ") <> c) [0 ..] (codecs ++ boundCodecs)) <> D.hardline
      -- A recursive group names its own members unqualified.
      pure [ Artifact "src/LawSpec/Data.fs" (unqualify "LawSpec.Data." (D.render layout typesDoc)) "generated" "source"
           , Artifact "src/LawSpec/DataCodecs.fs" (codecsHeader ++ unqualify "LawSpec.Data." (unqualify "LawSpec.Data.Codecs." (D.render layout codecsDoc))) "generated" "source" ]
  where
    boundIds = map (C.dataId . resolvedDeclaration) bound
    boundOf d = case [b | b <- bound, C.dataId (resolvedDeclaration b) == C.dataId d] of
      b : _ -> Just b
      [] -> Nothing
    typeParams d = if null (C.dataParameters d) then "" else "<" ++ intercalate ", " [typeParameter FSharp i | (i, _) <- zip [0 ..] (C.dataParameters d)] ++ ">"
    refText = intercalate "." . referenceParts
    boundHandleType b = refText (resolvedNativeType b) ++ case resolvedArguments b of
      Just args@(_ : _) -> "<" ++ intercalate ", " args ++ ">"
      _ -> ""
    -- A bound type's codec builds and takes apart the application's values:
    -- an F# record by its field names, a union case, or a case without fields.
    boundCodec names b = do
      let d = resolvedDeclaration b
      name <- maybe (Left "unnamed data") Right (lookup (C.dataId d) names)
      let codecParams = [(identity, "t" ++ show i) | (i, identity) <- zip [0 :: Int ..] (C.dataParameters d)]
          native = refText (resolvedNativeType b)
          single = length (resolvedConstructors b) == 1
      cases <- forM (resolvedConstructors b) $ \rc -> do
        let c = resolvedConstructor rc
            tag = C.idText (C.constructorId c)
            ctor = refText (resolvedNativeConstructor rc)
        fieldCodecs <- forM (resolvedFields rc) $ \(binder, _) -> codec FSharp bits names codecParams (C.binderType binder)
        let vars = ["f" ++ show i | (i, _) <- zip [0 :: Int ..] fieldCodecs]
            nativeNames = map snd (resolvedFields rc)
        case resolvedConstructorStyle rc of
          RecordConstructor | not single -> Left (".NET binds a record style only to a type with one constructor: " ++ C.idText (C.dataId d))
          RecordConstructor -> pure
            ( "| Value.Data(" ++ stringLiteral FSharp tag ++ ", " ++ listText vars ++ ") -> ({ " ++
                intercalate "; " [n ++ " = " ++ cd ++ ".ToNative " ++ v | (n, cd, v) <- zip3 nativeNames fieldCodecs vars] ++ " } : " ++ native ++ ")"
            , "| r -> Value.Data(" ++ stringLiteral FSharp tag ++ ", " ++ listText [cd ++ ".FromNative r." ++ n | (n, cd) <- zip nativeNames fieldCodecs] ++ ")" )
          _ -> pure
            ( "| Value.Data(" ++ stringLiteral FSharp tag ++ ", " ++ listText vars ++ ") -> " ++ ctor ++
                (if null vars then "" else "(" ++ intercalate ", " [cd ++ ".ToNative " ++ v | (cd, v) <- zip fieldCodecs vars] ++ ")")
            , "| " ++ ctor ++ (if null vars then "" else "(" ++ intercalate ", " vars ++ ")") ++ " -> Value.Data(" ++ stringLiteral FSharp tag ++ ", " ++
                listText [cd ++ ".FromNative " ++ v | (cd, v) <- zip fieldCodecs vars] ++ ")" )
      let ps = [("t" ++ show i, typeParameter FSharp i) | (i, _) <- zip [0 :: Int ..] (C.dataParameters d)]
          self = name ++ typeParams d
          header = "[<CompiledName(\"" ++ name ++ "\")>] " ++ escapeFSharp (camel name) ++ typeParams d ++ " " ++ (if null ps then "()" else unwords ["(" ++ n ++ ": Codec<" ++ p ++ ">)" | (n, p) <- ps]) ++ " : Codec<" ++ self ++ "> ="
      pure (D.text header <> D.nest 4 (D.hardline <>
        D.text "{ ToNative =" <> D.nest 4 (D.hardline <> D.text "fun value ->" <> D.nest 4 (D.hardline <> D.text "match value with" <> D.hardline <>
          D.joinWith D.hardline (map (D.text . fst) cases) <> D.hardline <> D.text ("| _ -> Fail.raiseWith \"InvalidNativeValue\" " ++ stringLiteral FSharp name))) <> D.hardline <>
        D.text "  FromNative =" <> D.nest 4 (D.hardline <> D.text ("fun (native: " ++ self ++ ") ->") <> D.nest 4 (D.hardline <> D.text "match native with" <> D.hardline <>
          D.joinWith D.hardline (map (D.text . snd) cases))) <> D.text " }"))
    fsharpType names s = do
      let compared = comparedParameters declarations (C.dataId (shapeDeclaration s))
          constraint ps = case [p | (i, (_, p)) <- zip [0 :: Int ..] ps, i `elem` compared] of
            [] -> ""
            cs -> " when " ++ intercalate " and " [c ++ ": comparison" | c <- cs]
          params = if null (shapeParameters s) then "" else "<" ++ intercalate ", " (map snd (shapeParameters s)) ++ constraint (shapeParameters s) ++ ">"
          self = shapeName s ++ (if null (shapeParameters s) then "" else "<" ++ intercalate ", " (map snd (shapeParameters s)) ++ ">")
          scope c = shapeParameters s ++ [(e, portableType FSharp) | e <- concatMap existentialsOf [c]]
          existentialsOf c = [e | dc <- C.dataConstructors (shapeDeclaration s), C.idText (C.constructorId dc) == caseTag c, e <- C.constructorExistentials dc]
          fieldName f = escapeFSharp (camel f)
          witnessNames c = [S.witnessFieldName (caseWitnesses c) k | k <- [0 .. caseWitnesses c - 1]]
          qualified = needsQualification s
      body <- if isRecord s then do
          let c = head (shapeCases s)
          fields <- forM (caseFields c) $ \(n, t) -> do
            nt <- nativeType FSharp bits names (scope c) t
            pure (pascal n ++ ": " ++ nt)
          pure (D.text "{ " <> D.joinWith (D.hardline <> D.text "  ") [D.text f | f <- fields] <> D.text " }")
        else do
          cases <- forM (shapeCases s) $ \c -> do
            fields <- forM (caseFields c) $ \(n, t) -> do
              nt <- nativeType FSharp bits names (scope c) t
              pure (fieldName n ++ ": " ++ nt)
            let all' = fields ++ [w ++ ": string" | w <- witnessNames c]
            pure (D.text ("| " ++ caseName c ++ if null all' then "" else " of " ++ intercalate " * " all'))
          pure (D.joinWith D.hardline cases)
      let fieldValues c = if isRecord s then ["this." ++ pascal n | (n, _) <- caseFields c]
            else ["f" ++ show i | (i, _) <- zip [0 :: Int ..] (caseFields c ++ [("", C.Constructor "Text" []) | _ <- witnessNames c])]
          pattern c = if null (fieldValues c) then caseName c else caseName c ++ "(" ++ intercalate ", " (fieldValues c) ++ ")"
          prefix = if qualified then shapeName s ++ "." else ""
          rank = if isRecord s then D.text "0" else
            D.text "match this with" <> mconcat [D.hardline <> D.text ("| " ++ prefix ++ (if null (fieldValues c) then caseName c else caseName c ++ " _") ++ " -> " ++ show (caseRank c)) | c <- shapeCases s]
          fields = if isRecord s then D.text ("[ " ++ intercalate "; " ["box " ++ v | v <- fieldValues (head (shapeCases s))] ++ " ]") else
            D.text "match this with" <> mconcat [D.hardline <> D.text ("| " ++ prefix ++ pattern c ++ " -> " ++ listText ["box " ++ v | v <- fieldValues c]) | c <- shapeCases s]
          members = D.joinWith D.hardline
            [ D.text "member private this.LawSpecRank: int =" <> D.nest 4 (D.hardline <> rank)
            , D.text "member private this.LawSpecFields: obj list =" <> D.nest 4 (D.hardline <> fields)
            , D.text "override this.Equals(other: obj) =" <> D.nest 4 (D.hardline <> D.text "match other with" <> D.hardline <>
                D.text ("| :? " ++ self ++ " as o -> Portable.equalData this.LawSpecRank this.LawSpecFields o.LawSpecRank o.LawSpecFields") <> D.hardline <>
                D.text "| _ -> false")
            , D.text "override this.GetHashCode() = Portable.hashData this.LawSpecRank this.LawSpecFields"
            , D.text "interface Portable.IPortable"
            , D.text "interface System.IComparable with" <> D.nest 4 (D.hardline <>
                D.text "member this.CompareTo(other: obj) =" <> D.nest 4 (D.hardline <> D.text "match other with" <> D.hardline <>
                  D.text ("| :? " ++ self ++ " as o -> Portable.compareData this.LawSpecRank this.LawSpecFields o.LawSpecRank o.LawSpecFields") <> D.hardline <>
                  D.text ("| _ -> invalidArg \"other\" \"a " ++ shapeName s ++ " compares with a " ++ shapeName s ++ "\""))) ]
          attributes = "[<CustomEquality; CustomComparison" ++ (if qualified then "; RequireQualifiedAccess" else "") ++ ">]"
      pure ("/// " ++ C.idText (C.dataId (shapeDeclaration s)), attributes,
        D.text (shapeName s ++ params) <> D.text " =" <> D.nest 4 (D.hardline <> body <> D.hardline <> D.hardline <> members))
    needsQualification s = not (isRecord s) && any (\c -> caseName c `elem` otherNames s) (shapeCases s)
    otherNames s = concat [caseName c : [] | d <- declarations, C.dataId d /= C.dataId (shapeDeclaration s), c <- maybe [] id (casesOf d)]
      ++ [n | (_, n) <- maybe [] id (either (const Nothing) Just (dataNames declarations))]
    casesOf d = Just [Case "" (pascal (C.constructorName c)) 0 [] 0 | c <- C.dataConstructors d]
    fsharpCodec names s = do
      let params = [("t" ++ show i, p) | (i, (_, p)) <- zip [0 :: Int ..] (shapeParameters s)]
          codecParams = [(identity, "t" ++ show i) | (i, (identity, _)) <- zip [0 :: Int ..] (shapeParameters s)]
          self = shapeName s ++ (if null params then "" else "<" ++ intercalate ", " (map snd params) ++ ">")
          prefix = if needsQualification s || not (isRecord s) then shapeName s ++ "." else ""
      cases <- forM (shapeCases s) $ \c -> do
        let existentials = [e | dc <- C.dataConstructors (shapeDeclaration s), C.idText (C.constructorId dc) == caseTag c, e <- C.constructorExistentials dc]
        fieldCodecs <- forM (caseFields c) $ \(_, t) -> codec FSharp bits names (codecParams ++ [(e, "Codec.portable") | e <- existentials]) t
        let witnessCodecs = replicate (caseWitnesses c) "Codec.text"
            all' = fieldCodecs ++ witnessCodecs
            vars = ["f" ++ show i | (i, _) <- zip [0 :: Int ..] all']
            toNative = D.text ("| Value.Data(" ++ stringLiteral FSharp (caseTag c) ++ ", " ++ listText vars ++ ") ->") <> D.nest 4 (D.hardline <>
              D.text (if isRecord s then "{ " ++ intercalate "; " [pascal n ++ " = " ++ cd ++ ".ToNative " ++ v | ((n, _), cd, v) <- zip3 (caseFields c) all' vars] ++ " }"
                else prefix ++ caseName c ++ (if null vars then "" else "(" ++ intercalate ", " [cd ++ ".ToNative " ++ v | (cd, v) <- zip all' vars] ++ ")")))
            fromPattern = if isRecord s then "r" else prefix ++ caseName c ++ (if null vars then "" else "(" ++ intercalate ", " vars ++ ")")
            fromValues = if isRecord s then [cd ++ ".FromNative r." ++ pascal n | ((n, _), cd) <- zip (caseFields c) all']
              else [cd ++ ".FromNative " ++ v | (cd, v) <- zip all' vars]
            fromNative = D.text ("| " ++ fromPattern ++ " -> Value.Data(" ++ stringLiteral FSharp (caseTag c) ++ ", " ++ listText fromValues ++ ")")
        pure (toNative, fromNative)
      let compared = comparedParameters declarations (C.dataId (shapeDeclaration s))
          constraint = case [p | (i, (_, p)) <- zip [0 :: Int ..] params, i `elem` compared] of
            [] -> ""
            cs -> " when " ++ intercalate " and " [c ++ ": comparison" | c <- cs]
          header = "[<CompiledName(\"" ++ shapeName s ++ "\")>] " ++ escapeFSharp (camel (shapeName s)) ++ (if null params then "" else "<" ++ intercalate ", " (map snd params) ++ constraint ++ ">") ++ " " ++ (if null params then "()" else unwords ["(" ++ n ++ ": Codec<" ++ p ++ ">)" | (n, p) <- params]) ++ " : Codec<" ++ self ++ "> ="
      pure (D.text header <> D.nest 4 (D.hardline <>
        D.text "{ ToNative =" <> D.nest 4 (D.hardline <> D.text "fun value ->" <> D.nest 4 (D.hardline <> D.text "match value with" <> D.hardline <>
          D.joinWith D.hardline (map fst cases) <> D.hardline <> D.text ("| _ -> Fail.raiseWith \"InvalidNativeValue\" " ++ stringLiteral FSharp (shapeName s)))) <> D.hardline <>
        D.text "  FromNative =" <> D.nest 4 (D.hardline <> D.text "fun native ->" <> D.nest 4 (D.hardline <> D.text "match native with" <> D.hardline <>
          D.joinWith D.hardline (map snd cases))) <> D.text " }"))
emitData CSharp _ _ _ declarations
  | null declarations = pure []
  | otherwise = Left "C# data types are not emitted yet"

-- | An F# list literal.
listText :: [String] -> String
listText [] = "[]"
listText xs = "[ " ++ intercalate "; " xs ++ " ]"

-- | Drop a qualifier wherever it prefixes a name.
unqualify :: String -> String -> String
unqualify prefix = go
  where
    go [] = []
    go text@(c : rest)
      | take (length prefix) text == prefix = go (drop (length prefix) text)
      | otherwise = c : go rest

-- ---------------------------------------------------------------------------
-- The schema

schemaModule :: String
schemaModule = "LawSpec.Generated.Program"

-- | The program's schema, built through the runtime: every constructor with
-- its field types, contracts, generation hints, index terms and witnesses.
emitSchema :: Lang -> D.Layout -> Int -> Bool -> [C.DataDeclaration] -> Either String Artifact
emitSchema lang layout bits crypto declarations = do
  _ <- makeRegistry declarations
  _ <- either (Left . show) Right (constructorProofContracts bits declarations)
  (schemas, contracts) <- S.dataSchemasWithContracts declarations
  definitions <- forM schemas $ \definition -> do
    cs <- forM (S.constructors definition) $ \c -> do
      predicates <- sequence [predicate contract expression | contract <- contracts,
        S.contractTag contract == S.constructorTag c, expression <- S.contractPredicates contract]
      generators <- fmap concat $ mapM fieldGenerators
        [contract | contract <- contracts, S.contractTag contract == S.constructorTag c]
      let base = call "Schema" "constructor" [Str (S.constructorTag c), ListOf (Ty "string * TypeRef" "Tuple<string, TypeRef>")
            [call "Schema" "field" [Str (S.fieldName f), Str (refKey (S.fieldType f))] | f <- S.fields c]]
          extras = [call "Schema" "withPredicates" [ListOf (tFun [tSchema, tList tType, tValues] tBool) predicates] | not (null predicates)] ++
            [call "Schema" "withGenerators" [ListOf (Ty "int * (Schema.Schema -> TypeRef list -> Value list -> Schema.FieldHints)" "Tuple<int, FSharpFunc<Schema.Schema, FSharpFunc<FSharpList<TypeRef>, FSharpFunc<FSharpList<Value>, Schema.FieldHints>>>>") generators] | not (null generators)] ++
            [call "Schema" "withIndices" [ListOf tString (map Str (S.constructorIndex c))] | not (null (S.constructorIndex c))] ++
            [call "Schema" "withRefinements" [ListOf (Ty "int * TypeRef" "Tuple<int, TypeRef>") [call "Schema" "refinement" [IntLit (toInteger i), Str (refKey t)] | (i, t) <- S.constructorRefinements c]] | not (null (S.constructorRefinements c))] ++
            [call "Schema" "withExistentials" [IntLit (toInteger (S.constructorExistentials c))] | S.constructorExistentials c > 0] ++
            [call "Schema" "withWitnesses" [ListOf tInt (map (IntLit . toInteger) (S.constructorWitnesses c))] | not (null (S.constructorWitnesses c))]
      pure (foldl (\acc extra -> case extra of { Call f args -> Call f (args ++ [acc]); other -> other }) base extras)
    let handle = any (\d -> C.idText (C.dataId d) == S.typeName definition && C.dataHandle d) declarations
    pure (call "Schema" "definition" [Str (S.typeName definition), IntLit (toInteger (S.parameterCount definition)),
      ListOf (Ty "Schema.Constructor" "Schema.Constructor") cs, BoolLit handle])
  let schema = call "Schema" "create" [ListOf (Ty "Schema.DataDefinition" "Schema.DataDefinition") definitions,
        ListOf tString (map (Str . primitiveName) primitives), IntLit (toInteger bits)]
      body = renderBody lang tSchema schema
      doc = case lang of
        FSharp -> D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "/// The program's data, as the runtime checks it." <> D.hardline <>
          D.text ("module " ++ schemaModule) <> D.hardline <> D.hardline <>
          D.text "open LawSpec.Runtime" <> D.hardline <> D.hardline <>
          (if crypto then D.text "// lawspec.crypto's default handlers answer through the runtime's Defaults." <> D.hardline <>
            D.text "Crypto.install ()" <> D.hardline <> D.hardline else mempty) <>
          D.text "/// Every data type of the program, its constructors and their contracts." <> D.hardline <>
          D.text "[<CompiledName(\"Schema\")>]" <> D.hardline <> D.text "let schema: Schema.Schema =" <> D.nest 4 (D.hardline <> body) <> D.hardline
        CSharp -> D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "using LawSpec.Runtime;" <> D.hardline <> D.text "using LawSpec.CSharp;" <> D.hardline <>
          D.text "using Microsoft.FSharp.Core;" <> D.hardline <> D.text "using Microsoft.FSharp.Collections;" <> D.hardline <>
          D.text "using System;" <> D.hardline <> D.hardline <>
          D.text "namespace LawSpec.Generated;" <> D.hardline <> D.hardline <>
          D.text "/// <summary>The program's data, as the runtime checks it.</summary>" <> D.hardline <>
          D.text "public static class Program" <> D.hardline <> D.block 4
            (D.text "public static readonly Schema.Schema Schema = Build();" <> D.hardline <> D.hardline <>
             D.text "private static Schema.Schema Build()" <> D.hardline <> D.block 4 body) <> D.hardline
  pure (Artifact ("src/LawSpec/Program" ++ extension lang) (D.render layout doc) "generated" "source")
  where
    refKey (S.Parameter i) = "$" ++ show i
    refKey (S.Named n []) = n
    refKey (S.Named n args) = n ++ concat [" (" ++ refKey a ++ ")" | a <- args]
    contractRender contract = do
      let local identity = maybe (error "unbound .NET constructor field") id
            (lookup identity [(C.binderId b, "field" ++ show i) | (i, b) <- zip [0 :: Int ..] (S.contractFields contract)])
          ref ty = do
            raw <- S.typeReference (S.contractParameters contract) ty
            pure (call "Schema" "substitute" [X.typeOfKey (refKey raw), Var "known"])
          key ty = (\r -> call "Scalar" "typeKey" [r]) <$> ref ty
      pure (X.Context bits (Var "schema") (Var "symbols") local
        (\_ _ _ -> Left "external call in a .NET constructor predicate") ref key)
    withFields contract = withEarlier (length (S.contractFields contract)) contract
    withEarlier count contract inner = Let "known" (Ty "Map<int, TypeRef>" "FSharpMap<int, TypeRef>") (call "Schema" "known" [Var "types"])
      (Let "symbols" tSymbols (Raw "Scalar.SymbolContext()" "new Scalar.SymbolContext()")
        (foldr (\(i, _) rest -> Let ("field" ++ show i) tValue (call "Runtime" "item" [IntLit i, Var "fields"]) rest)
          inner (zip [0 :: Integer ..] (take count (S.contractFields contract)))))
    predicate contract expression = do
      context <- contractRender contract
      body <- X.render context expression
      pure (Lambda [("schema", tSchema), ("types", tList tType), ("fields", tValues)] tBool (withFields contract (X.truth body)))
    -- Safe constructor-field bounds may depend on fields already drawn; the
    -- full predicate remains authoritative. ref:DEC-shrink-within-domain
    fieldGenerators contract = fmap concat $ forM (zip [0 :: Int ..] (S.contractFields contract)) $ \(i, binder) -> do
      let predicates = S.contractPredicates contract
          q = C.Quantifier binder predicates []
          requirement = GeneratorRequirement binder predicates [] [] (domainHints q) Nothing
          earlier = map C.binderId (take i (S.contractFields contract))
          available expression = all (`elem` earlier) (C.freeBinders expression)
          bounds = filter (available . snd) (BeamGenerators.directBounds requirement)
          lengths = filter (available . snd) (BeamGenerators.lengthBounds requirement)
          hints = [hint | hint <- domainHints q ++ regexHints binder predicates, C.expressionType hint == C.binderType binder, available hint]
      if null bounds && null lengths && null hints then pure [] else do
        context <- contractRender contract
        let render = X.render context
        bs <- mapM (\(op, e) -> (\v -> TupleOf [Str (C.binaryName op), v]) <$> render e) bounds
        ls <- mapM (\(op, e) -> (\v -> TupleOf [Str (C.binaryName op), v]) <$> render e) lengths
        hs <- mapM render hints
        let pairTy = Ty "string * Value" "Tuple<string, Value>"
            hint = call "Schema" "hints" [ListOf pairTy bs, ListOf pairTy ls, ListOf tValue hs]
        pure [TupleOf [IntLit (toInteger (i + 1)), Lambda [("schema", tSchema), ("types", tList tType), ("fields", tValues)]
          (Ty "Schema.FieldHints" "Schema.FieldHints") (withEarlier i contract hint)]]
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
