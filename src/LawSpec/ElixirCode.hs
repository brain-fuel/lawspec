-- | Elixir tokens and native types; the checked expression implementation is
-- shared Erlang, while public functions and data stay idiomatic Elixir.
-- ref:DEC-idiomatic-generated-types ref:DEC-readable-output-default
module LawSpec.ElixirCode
  ( string, atom, array, tuple, call, remote, function, moduleDoc, moduleDocFrom, integer, layoutFor, typeAttribute, variables
  , nativeType, typeReference, reference ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Code.Doc as D
import LawSpec.Scalar (primitive, family, Family(..), integerBounds)
import Data.Char (ord, toLower, isAscii, isAlphaNum, isLower)
import Numeric (showHex)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Naming (claimAll, scopeWith, nativeIdentifier, NameKind(..))

string :: String -> D.Doc
string s = D.text ('"' : concatMap escape s ++ "\"")
  where
    escape c | c `elem` ['"','\\','#'] = ['\\',c]
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c | ord c < 32 || ord c >= 127 = "\\u{" ++ showHex (ord c) "}"
    escape c = [c]

atom :: String -> D.Doc
atom n = D.text ":" <> (if plain n then D.text n else string n)
  where
    plain (c:cs) = (isAscii c && isLower c || c == '_') && all (\x -> isAscii x && (isAlphaNum x || x `elem` ("_@!?" :: String))) cs
    plain [] = False

array, tuple :: [D.Doc] -> D.Doc
array = D.delimit 2 "[" "]"
tuple = D.delimit 2 "{" "}"

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimit 2 "(" ")" args

remote :: String -> String -> [D.Doc] -> D.Doc
remote owner name args = D.text owner <> D.text "." <> call name args

-- | def name(args) do ... end, its body on lines of its own, as mix
-- format writes a do block.
function :: String -> [D.Doc] -> [D.Doc] -> D.Doc
function name args body = header <> D.text " do" <>
  D.nest 2 (D.hardline <> D.joinWith D.hardline body) <> D.hardline <> D.text "end"
  where
    -- mix fits the function's signature without its trailing do token.
    -- Keep both layouts structured; compact rendering only measures it.
    flat = D.text ("def " ++ name ++ "(") <> D.joinWith (D.text ", ") args <> D.text ")"
    header = D.prefixChoice (D.render D.Compact flat) flat (D.text "def " <> D.nest 4 (call name args))

-- | @spec or @type, Left :: Right, in a module body, laid out as mix format
-- lays it out at width 98: on one line when it fits; otherwise a union's
-- alternatives one to a line, a container's items one to a line, or the
-- left side's arguments one to a line, indented from the attribute.
typeAttribute :: String -> D.Doc -> D.Doc -> D.Doc
typeAttribute attribute left right
  | 2 + length flat <= 98 = D.text flat
  | length alternatives > 1, 2 + length (prefix ++ l ++ " ::") <= 98 = D.text (prefix ++ l ++ " ::") <> D.hardline <> rightAlone
  | Just (open, items, close) <- container r, 2 + length (prefix ++ l ++ " :: " ++ open) <= 98 =
      D.text (prefix ++ l ++ " :: " ++ open) <>
      mconcat [D.hardline <> item i (if k < length items then "," else "") | (k, i) <- zip [1 :: Int ..] items] <>
      D.hardline <> D.text (replicate 6 ' ' ++ close)
  -- mix format measures the left side without its operator.
  | 2 + length (prefix ++ l) <= 98 = D.text (prefix ++ l ++ " ::") <> D.hardline <> rightAlone
  -- A sole list argument hugs the parentheses.
  | Just (name, [a]) <- calledWith l, Just ("[", items, "]") <- container a =
      D.text (prefix ++ name ++ "([") <>
      mconcat [D.hardline <> D.text (replicate 8 ' ' ++ i ++ (if k < length items then "," else "")) | (k, i) <- zip [1 :: Int ..] items] <>
      D.hardline <> closing "])"
  | Just (name, args) <- calledWith l =
      D.text (prefix ++ name ++ "(") <>
      mconcat [D.hardline <> argument a (if k < length args then "," else "") | (k, a) <- zip [1 :: Int ..] args] <>
      D.hardline <> closing ")"
  | otherwise = D.text flat
  where
    -- After broken arguments: ") :: R", or R on lines of its own.
    closing bracket
      | 8 + length (bracket ++ " :: " ++ r) <= 98 = D.text (replicate 6 ' ' ++ bracket ++ " :: " ++ r)
      | otherwise = D.text (replicate 6 ' ' ++ bracket ++ " ::") <> D.hardline <> rightAlone
    -- A broken argument; a union breaks into its alternatives.
    argument a suffix = case splitTop " | " a of
      alternative : rest@(_ : _) -> D.joinWith D.hardline
        [D.text (replicate 8 ' ' ++ (if i == 0 then "" else "| ") ++ x ++ (if i == length rest then suffix else ""))
        | (i, x) <- zip [0 :: Int ..] (alternative : rest)]
      _ -> D.text (replicate 8 ' ' ++ a ++ suffix)
    -- The right side on lines of its own, from column 10.
    rightAlone
      | 10 + length r <= 98 = D.text (replicate 8 ' ' ++ r)
      | length alternatives > 1 = D.joinWith D.hardline
          [D.text (replicate 8 ' ' ++ (if i == 0 then "" else "| ") ++ a) | (i, a) <- zip [0 :: Int ..] alternatives]
      | Just (name, args) <- calledWith r = D.text (replicate 8 ' ' ++ name ++ "(") <>
          mconcat [D.hardline <> D.text (replicate 10 ' ' ++ a ++ (if k < length args then "," else "")) | (k, a) <- zip [1 :: Int ..] args] <>
          D.hardline <> D.text (replicate 8 ' ' ++ ")")
      | otherwise = D.text (replicate 8 ' ' ++ r)
    prefix = "@" ++ attribute ++ " "
    l = D.render D.Compact left
    r = D.render D.Compact right
    flat = prefix ++ l ++ " :: " ++ r
    alternatives = splitTop " | " r
    -- A map item too long for its line breaks after its =>.
    item i suffix
      | 10 + length i + length suffix <= 98 = D.text (replicate 8 ' ' ++ i ++ suffix)
      -- A function type breaks after its arrow, aligned past its parenthesis.
      -- A union result breaks before each alternative, aligned with the first.
      | (key, '(' : value) <- breakOn " => " i, last value == ')', (arguments, result@(_ : _)) <- breakOn' (init value),
        first : rest@(_ : _) <- splitTop " | " result =
          let opening = replicate 8 ' ' ++ key ++ " => (" ++ arguments ++ (if null arguments then "-> " else " -> ")
              -- With arguments, the result starts a line of its own.
              resultColumn = 8 + length key + 4 + 1 + 2
              alternatives' = [(if k == 0 then "" else "| ") ++ alt ++ (if k == length rest then ")" ++ suffix else "") | (k, alt) <- zip [0 :: Int ..] (first : rest)]
          in if null arguments
            then D.text (opening ++ concat (take 1 alternatives')) <> mconcat [D.hardline <> D.text (replicate (length opening) ' ' ++ alt) | alt <- drop 1 alternatives']
            else D.text (replicate 8 ' ' ++ key ++ " => (" ++ arguments ++ " ->") <>
              mconcat [D.hardline <> D.text (replicate resultColumn ' ' ++ alt) | alt <- alternatives']
      | (key, '(' : value) <- breakOn " => " i, last value == ')', (arguments, result@(_ : _)) <- breakOn " -> " (init value) =
          D.text (replicate 8 ' ' ++ key ++ " => (" ++ arguments ++ " ->") <> D.hardline <>
          D.text (replicate (8 + length key + 4 + 1 + 2) ' ' ++ result ++ ")" ++ suffix)
      | (key, value@(_ : _)) <- breakOn " => " i = D.text (replicate 8 ' ' ++ key ++ " =>") <> D.hardline <> D.text (replicate 10 ' ' ++ value ++ suffix)
      | otherwise = D.text (replicate 8 ' ' ++ i ++ suffix)
    container t = case t of
      '[' : rest | last t == ']' -> Just ("[", splitTop ", " (init rest), "]")
      '{' : rest | last t == '}' -> Just ("{", splitTop ", " (init rest), "}")
      '%' : _ | (opening, '{' : rest) <- span (/= '{') t, last t == '}' -> Just (opening ++ "{", splitTop ", " (init rest), "}")
      _ -> Nothing
    calledWith t = case span (/= '(') t of
      (name@(_ : _), '(' : rest) | last t == ')' -> Just (name, splitTop ", " (init rest))
      _ -> Nothing
    -- A function type's arguments and result: "-> R" has no arguments.
    breakOn' t = case t of
      '-' : '>' : ' ' : r -> ("", r)
      _ -> breakOn " -> " t
    breakOn separator t = go "" t
      where
        go acc rest@(c : cs)
          | take (length separator) rest == separator = (reverse acc, drop (length separator) rest)
          | otherwise = go (c : acc) cs
        go acc [] = (reverse acc, "")

-- | Text split at a separator outside brackets and strings.
splitTop :: String -> String -> [String]
splitTop separator = go (0 :: Int) False ""
  where
    go _ _ acc [] = [reverse acc]
    go depth quoted acc s@(c : cs)
      | quoted = go depth (c /= '"' || take 1 (reverse acc) == "\\") (c : acc) cs
      | c == '"' = go depth True (c : acc) cs
      | depth == 0, take (length separator) s == separator = reverse acc : go depth False "" (drop (length separator) s)
      | c `elem` ("([{" :: String) = go (depth + 1) False (c : acc) cs
      | c `elem` (")]}" :: String) = go (depth - 1) False (c : acc) cs
      | otherwise = go depth False (c : acc) cs

moduleDoc :: String -> Bool -> [D.Doc] -> D.Doc
moduleDoc name editable = moduleWith (if editable then "# User-owned LawSpec adapter. Implement these functions." else "# " ++ generatedHeader Nothing) name

-- | A generated module whose header names its specification.
moduleDocFrom :: Maybe FilePath -> String -> [D.Doc] -> D.Doc
moduleDocFrom source = moduleWith ("# " ++ generatedHeader source)

moduleWith :: String -> String -> [D.Doc] -> D.Doc
moduleWith header name body = D.text header <>
  D.hardline <> D.text ("defmodule " ++ name ++ " do") <>
  (if null body then mempty else D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) body)) <> D.hardline <> D.text "end" <> D.hardline

-- | mix format's line width, 98, for the BEAM layout.
layoutFor :: D.Layout -> D.Layout
layoutFor layout = case layout of
  D.Pretty _ -> D.Pretty 98
  other -> other

-- | An integer as mix format writes it: digits grouped by underscores from
-- six digits on.
integer :: Integer -> D.Doc
integer n = D.text ((if n < 0 then "-" else "") ++ grouped (show (abs n)))
  where
    grouped digits
      | length digits < 6 = digits
      | otherwise = reverse (go (reverse digits))
    go (a : b : c : rest@(_ : _)) = a : b : c : '_' : go rest
    go rest = rest

reference :: S.TypeRef -> D.Doc
reference (S.Parameter i) = tuple [atom "parameter",D.text (show i)]
reference (S.Named n ts) = tuple [string n,array (map reference ts)]

typeReference :: C.Type -> Either String D.Doc
typeReference ty = reference <$> S.typeReference [] ty

nativeType :: Int -> [(C.Id,String)] -> [(C.Id,String)] -> C.Type -> Either String D.Doc
nativeType bits names parameters ty = case ty of
  C.TypeVariable identity -> maybe (Left "unbound Elixir type parameter") (Right . D.text) (lookup identity parameters)
  C.Constructor n args -> do
    ts <- mapM argument args
    case (n,ts) of
      ("List",[t]) -> pure (array [t])
      ("Maybe",[t]) -> pure (union [atom "absent",tuple [atom "present",t]])
      ("Either",[a,b]) -> pure (union [tuple [atom "left",a],tuple [atom "right",b]])
      ("Nullable",[t]) -> pure (union [atom "null",tuple [atom "non_null",t]])
      ("Optional",[t]) -> pure (union [atom "none",tuple [atom "some",t]])
      (_,[]) | Just p <- primitive n -> pure $ case family p of
        IntegerFamily -> case integerBounds bits n of
          Just (lo,hi) -> integer lo <> D.text ".." <> integer hi
          Nothing -> call (if n == "BigUInt" then "non_neg_integer" else "integer") []
        Boolean -> call "boolean" []
        Floating -> remote ":lawspec_beam_scalar" "ieee" []
        Complex -> remote ":lawspec_beam_scalar" "complex" []
        Exact -> remote ":lawspec_beam_scalar" (map toLower n) []
        Character -> call "non_neg_integer" []
        Sequence -> if n `elem` ["Text","Bytes"] then call "binary" [] else array [call "non_neg_integer" []]
        Identity -> remote ":lawspec_beam_scalar" "symbol" []
        Absence -> atom (case n of "Unit" -> "ok"; "Null" -> "null"; _ -> "undefined")
      _ -> maybe (Left ("no Elixir native type: " ++ n))
        (\name -> pure (remote "LawSpec.Data" name ts)) (lookup (C.Id n) names)
  C.Arrow _ _ -> Left "function-valued Elixir data is unsupported"
  where
    argument (C.TypeArgument t) = nativeType bits names parameters t
    argument (C.IndexArgument _) = Left "unerased Elixir type index"
    union = D.joinWith (D.text " | ")

-- | Elixir variables for source names, snake_case, unique in order; a
-- reserved word gets a trailing underscore.
variables :: [String] -> [String]
variables = fst . claimAll (scopeWith reserved) . map name
  where
    reserved = words "after alias and case catch cond def defmodule do else end false fn for if import in nil not or quote raise receive require rescue super true try unless unquote use when with"
    name source = let n = nativeIdentifier "elixir" ValueName source in if n `elem` reserved then n ++ "_" else n
