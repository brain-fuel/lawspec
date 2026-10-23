-- | Native Gleam tokens and types. Shared Core expressions and runtime values
-- are compiled once on BEAM, with checked bridges at every public function.
-- ref:DEC-idiomatic-generated-types ref:DEC-readable-output-default
module LawSpec.GleamCode (string, call, tuple, function, lambda, huggedLambda, external, fileDoc, fileDocFrom, nativeType, imports, layoutFor, typeAlias) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import LawSpec.Scalar (primitive, family, Family(..))
import Data.List (intercalate, isPrefixOf, sort)
import LawSpec.Code.Literal (literalFor)
import LawSpec.SourceLink (generatedHeader)

-- | A Gleam string (LawSpec.Code.Literal). ref:DEC-native-string-literals
string :: String -> D.Doc
string = D.text . literalFor "gleam"

-- | gleam format's width, 80, for the BEAM layout.
layoutFor :: D.Layout -> D.Layout
layoutFor layout = case layout of
  D.Pretty _ -> D.Pretty 80
  other -> other

-- | Arguments or fields, with gleam format's trailing comma when they wrap.
call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 2 "(" ")" args

tuple :: [D.Doc] -> D.Doc
tuple = D.delimitTrailing 2 "#(" ")"

-- | pub fn name(args) -> Result { body }, the body on lines of its own.
function :: String -> [D.Doc] -> D.Doc -> [D.Doc] -> D.Doc
function name args result body = D.text "pub fn " <> call name args <> D.text " -> " <> result <>
  D.text " {" <> D.nest 2 (D.hardline <> D.joinWith D.hardline body) <> D.hardline <> D.text "}"

-- | fn(args) { body }, the body on lines of its own when it does not fit.
-- gleam format measures an item without its trailing comma, so a fun
-- written at a known column decides its own layout.
lambda :: Int -> [D.Doc] -> D.Doc -> D.Doc
lambda column args body
  | column + length flat <= 80 = D.text flat
  | otherwise = D.multiline mempty <> D.text opening <> D.nest 2 (D.hardline <> body) <> D.hardline <> D.text "}"
  where
    opening = "fn(" ++ intercalate ", " (map (D.render D.Compact) args) ++ ") {"
    flat = opening ++ " " ++ D.render D.Compact body ++ " }"

-- | name(fn(args) { body }), a call's sole fun argument hugging its
-- parentheses when the call does not fit on one line at the column.
huggedLambda :: String -> Int -> [D.Doc] -> D.Doc -> D.Doc
huggedLambda name column args body
  | column + length flat <= 80 = D.text flat
  | otherwise = D.multiline mempty <> D.text (name ++ "(" ++ opening) <> D.nest 2 (D.hardline <> body) <> D.hardline <> D.text "})"
  where
    opening = "fn(" ++ intercalate ", " (map (D.render D.Compact) args) ++ ") {"
    flat = name ++ "(" ++ opening ++ " " ++ D.render D.Compact body ++ " })"

-- | An external function: its attribute on one line, as gleam format keeps it.
external :: String -> String -> String -> [D.Doc] -> D.Doc -> D.Doc
external owner foreignName name args result =
  D.text ("@external(erlang, " ++ literalFor "gleam" owner ++ ", " ++ literalFor "gleam" foreignName ++ ")") <>
  D.hardline <> D.text "pub fn " <> call name args <> D.text " -> " <> result

-- | pub type Name = Type, the type on the next line as gleam format puts it.
typeAlias :: String -> D.Doc -> D.Doc
typeAlias name ty = D.text ("pub type " ++ name ++ " =") <> D.nest 2 (D.hardline <> ty)

fileDoc :: Bool -> [D.Doc] -> D.Doc
fileDoc editable = fileWith (if editable then "// User-owned LawSpec adapter. Implement these functions." else "// " ++ generatedHeader Nothing)

-- | A generated file whose header names its specification.
fileDocFrom :: Maybe FilePath -> [D.Doc] -> D.Doc
fileDocFrom source = fileWith ("// " ++ generatedHeader source)

-- | Imports first, sorted as gleam format sorts them; then the rest.
fileWith :: String -> [D.Doc] -> D.Doc
fileWith header body = D.text header <> D.hardline <> D.hardline <>
  D.joinWith (D.hardline <> D.hardline) ([D.joinWith D.hardline (map D.text (sort imported)) | not (null imported)] ++ rest) <> D.hardline
  where
    rendered = [(D.render D.Compact d, d) | d <- body]
    imported = [t | (t, _) <- rendered, "import " `isPrefixOf` t]
    rest = [d | (t, d) <- rendered, not ("import " `isPrefixOf` t)]

nativeType :: Bool -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String D.Doc
nativeType localData names parameters ty = case ty of
  C.TypeVariable identity -> maybe (Left "unbound Gleam native type parameter") (Right . D.text) (lookup identity parameters)
  C.Constructor n args -> do
    ts <- mapM argument args
    let applied name = if null ts then D.text name else call name ts
    case n of
      "List" -> pure (applied "List")
      "Maybe" -> pure (applied "option.Option")
      "Either" -> pure (call "Result" (reverse ts))
      "Nullable" -> pure (applied "types.Nullable")
      "Optional" -> pure (applied "types.Optional")
      _ | Just p <- primitive n, null ts -> pure $ case family p of
        IntegerFamily -> D.text "Int"
        Boolean -> D.text "Bool"
        Floating -> D.text ("types." ++ n)
        Complex -> D.text ("types." ++ n)
        Exact -> D.text ("types." ++ n)
        Character -> D.text "Int"
        Sequence -> case n of "Text" -> D.text "String"; "Bytes" -> D.text "BitArray"; _ -> call "List" [D.text "Int"]
        Identity -> D.text "types.Symbol"
        Absence -> D.text (if n == "Unit" then "Nil" else "types." ++ n)
      _ -> maybe (Left ("no Gleam native type: " ++ n))
        (pure . applied . ((if localData then "" else "data.") ++) . E.pascal) (lookup (C.Id n) names)
  C.Arrow _ _ -> Left "function-valued Gleam data is unsupported"
  where
    argument (C.TypeArgument t) = nativeType localData names parameters t
    argument (C.IndexArgument _) = Left "unerased Gleam type index"

imports :: Bool -> [C.Type] -> [D.Doc]
imports localData types =
  [D.text "import gleam/option" | "Maybe" `elem` names] ++
  [D.text "import lawspec/types" | any (`elem` names) (words "Nullable Optional Float32 Float64 Complex64 Complex128 Rational Decimal Symbol Null Undefined")] ++
  [D.text "import lawspec/data" | not localData && any user names]
  where
    names = concatMap named types
    named (C.Constructor n args) = n : concat [named t | C.TypeArgument t <- args]
    named (C.Arrow a b) = named a ++ named b
    named _ = []
    user n = primitive n == Nothing && n `notElem` words "List Maybe Either Nullable Optional"
