-- | Code layout is independent of syntax, inference, target runtimes, and IO.
-- Emitters supply tokens and legal break points; the renderer never reparses
-- code or rewrites whitespace inside tokens (including string literals).
module LawSpec.Code.Doc
  ( Doc, Layout(..), text, utf8Text, utf8Length, displayWidth, hardline, softline, softbreak
  , nest, group, multiline, prefixChoice, hang, firstLineWidth, whenBroken, joinWith, flow, commaSep, delimit, delimitTrailing, block, render, selectLayout, lineComment
  , Style(..), Braces(..), Measure(..), ImportOrder(..), styleFor, styleLayout, styleBlock, styleDelimit, styleImports, blankLines, topLevel
  ) where

import Data.List (intersperse, sort)
import Data.Char (ord)
import qualified Data.IntMap.Strict as IM
import LawSpec.DisplayWidthData (displayWidthRanges)

-- | Generated code is laid out by the compiler itself, never by an external
-- formatter, so output is identical on every machine and in the WASM build.
-- ref:DEC-readable-output-default
data Doc
  = Empty
  | Text String
  | Utf8Text String
  | Append Doc Doc
  | Break (Maybe String)
  | Nest Int Doc
  | Group Doc
  | PrefixChoice String Doc Doc
  | Multiline Doc
  | Flow [Doc]
  | FlowTail [Doc]
  | FirstLineWidth Int Doc
  | Hang Int Doc Doc
  | WhenBroken Doc
  deriving (Eq, Show)

-- | Compact removes optional layout only. Mandatory newlines and nesting remain
-- meaningful for Python, Haskell, Go, line comments, and preprocessor directives.
-- PrettyDisplay measures width in display columns, as ruff and rustfmt do:
-- an East Asian wide character takes two, a combining mark none.
data Layout = Pretty Int | PrettyTabs Int | PrettyDisplay Int | Compact | CompactTabs deriving (Eq, Show)

-- | Keep target-required indentation when explicitly flattening optional breaks.
selectLayout :: Bool -> Layout -> Layout
selectLayout False layout = layout
selectLayout True (PrettyTabs _) = CompactTabs
selectLayout True CompactTabs = CompactTabs
selectLayout True _ = Compact

-- | Brace placement: K&R keeps the opening brace on its line, Allman puts it
-- on a line of its own.
data Braces = KAndR | Allman deriving (Eq, Show)

-- | How a formatter counts a line's width.
data Measure = CodePoints | DisplayColumns | Utf8Bytes deriving (Eq, Show)

-- | How imports are grouped: standard library, third party, then the
-- project's own, each group sorted (isort and goimports); or as written.
data ImportOrder = GroupedImports | SortedImports | WrittenImports deriving (Eq, Show)

-- | A target's layout, from its canonical formatter's default configuration
-- or, where it has none, Allman braces with Google's other rules. Generated
-- code must be a fixed point of that formatter. ref:DEC-readable-output-default
data Style = Style
  { styleTarget :: String
  , styleFormatter :: String
  , styleBraces :: Braces
  , styleIndent :: Int
  , styleTabs :: Bool
  , styleWidth :: Int
  , styleMeasure :: Measure
    -- A wrapped list ends with a comma.
  , styleTrailingCommas :: Bool
    -- Blank lines between top-level definitions, and between nested ones.
  , styleTopLevelBlankLines :: Int
  , styleNestedBlankLines :: Int
  , styleImportOrder :: ImportOrder
  } deriving (Eq, Show)

-- | Every target's profile. Widths and indents are the formatters' defaults:
-- gofmt tabs, rustfmt 100, ruff and black 88, Prettier 80, ktfmt 100,
-- Google Java 100, ormolu 80 (by convention), mix format 98, gleam format 80,
-- erlfmt 100, scalafmt 80, swift-format 100, Fantomas 120, dotnet format 120,
-- cljfmt 80 (by convention) and tofu fmt.
styleFor :: String -> Style
styleFor target = case target of
  "python" -> profile "ruff format" KAndR 4 False 88 DisplayColumns True 2 1 GroupedImports
  "go" -> profile "gofmt" KAndR 8 True 100 CodePoints True 1 1 GroupedImports
  "rust" -> profile "rustfmt" KAndR 4 False 100 DisplayColumns True 1 1 SortedImports
  "javascript" -> profile "prettier" KAndR 2 False 80 DisplayColumns True 1 1 WrittenImports
  "typescript" -> profile "prettier" KAndR 2 False 80 DisplayColumns True 1 1 WrittenImports
  "kotlin" -> profile "ktfmt (kotlinlang)" KAndR 4 False 100 CodePoints True 1 1 SortedImports
  "java" -> profile "checkstyle (Allman, Google)" Allman 4 False 100 CodePoints False 1 1 SortedImports
  "groovy" -> profile "checkstyle (Allman, Google)" Allman 4 False 100 CodePoints False 1 1 SortedImports
  "scala" -> profile "scalafmt" KAndR 2 False 80 CodePoints False 1 1 SortedImports
  "clojure" -> profile "cljfmt" KAndR 2 False 80 CodePoints False 1 1 SortedImports
  "haskell" -> profile "ormolu" KAndR 2 False 80 CodePoints False 1 1 SortedImports
  "erlang" -> profile "erlfmt" KAndR 4 False 100 CodePoints False 1 1 WrittenImports
  "elixir" -> profile "mix format" KAndR 2 False 98 CodePoints False 1 1 WrittenImports
  "gleam" -> profile "gleam format" KAndR 2 False 80 CodePoints True 1 1 SortedImports
  "fsharp" -> profile "fantomas" KAndR 4 False 120 CodePoints False 1 1 WrittenImports
  "csharp" -> profile "dotnet format" Allman 4 False 120 CodePoints True 1 1 SortedImports
  "swift" -> profile "swift-format" KAndR 2 False 100 CodePoints True 1 1 SortedImports
  "hcl" -> profile "tofu fmt" KAndR 2 False 100 CodePoints False 1 1 WrittenImports
  _ -> profile "" KAndR 2 False 100 CodePoints False 1 1 WrittenImports
  where profile = Style target

-- | The renderer's layout for a profile.
styleLayout :: Style -> Layout
styleLayout style
  | styleTabs style = PrettyTabs (styleWidth style)
  | styleMeasure style == DisplayColumns = PrettyDisplay (styleWidth style)
  | otherwise = Pretty (styleWidth style)

-- | A braced block placed as the profile asks.
styleBlock :: Style -> Doc -> Doc
styleBlock style body = case styleBraces style of
  KAndR -> text " " <> block (styleIndent style) body
  Allman -> hardline <> block (styleIndent style) body

-- | A delimited list, with the profile's trailing comma when it wraps.
styleDelimit :: Style -> String -> String -> [Doc] -> Doc
styleDelimit style
  | styleTrailingCommas style = delimitTrailing (styleIndent style)
  | otherwise = delimit (styleIndent style)

-- | Import lines grouped and ordered as the profile asks. Each group is a
-- list of complete import lines; groups are separated by a blank line.
styleImports :: Style -> [[String]] -> Doc
styleImports style groups = joinWith (hardline <> hardline)
  [joinWith hardline (map text (order lines')) | lines' <- groups, not (null lines')]
  where order = if styleImportOrder style == WrittenImports then id else sort

-- | n blank lines.
blankLines :: Int -> Doc
blankLines n = mconcat (replicate (n + 1) hardline)

-- | Top-level definitions separated as the profile asks.
topLevel :: Style -> [Doc] -> Doc
topLevel style = joinWith (blankLines (styleTopLevelBlankLines style))

instance Semigroup Doc where
  Empty <> b = b
  a <> Empty = a
  a <> b = Append a b

instance Monoid Doc where
  mempty = Empty

-- | Empty text is no document, so joins never leave stray separators.
text :: String -> Doc
text "" = Empty
text s = Text s

-- | Some native formatters measure literal tokens in UTF-8 bytes. This changes
-- layout measurement only; the rendered Unicode text is preserved verbatim.
utf8Text :: String -> Doc
utf8Text "" = Empty
utf8Text s = Utf8Text s

-- | Some targets measure line width in bytes, so a line's UTF-8 length decides
-- where it breaks.
utf8Length :: String -> Int
utf8Length = sum . map (\c -> let n = ord c in
  if n < 0x80 then 1 else if n < 0x800 then 2 else if n < 0x10000 then 3 else 4)

-- | Display columns, as the unicode-width crate counts them for ruff and
-- rustfmt, from LawSpec's pinned Unicode tables rather than the host's.
displayWidth :: String -> Int
displayWidth = sum . map columns
  where
    columns c
      | ord c < 0x300 = 1
      | otherwise = case IM.lookupLE (ord c) widthTable of
          Just (_, (hi, w)) | ord c <= hi -> w
          _ -> 1

widthTable :: IM.IntMap (Int, Int)
widthTable = IM.fromList [(lo, (hi, w)) | (lo, hi, w) <- displayWidthRanges]

-- | A hard line always breaks; a soft line is a space and a soft break nothing
-- when their group fits on one line.
hardline, softline, softbreak :: Doc
hardline = Break Nothing
softline = Break (Just " ")
softbreak = Break (Just "")

-- | Negative indentation would move code left of its block, so it is clamped.
nest :: Int -> Doc -> Doc
nest amount = Nest (max 0 amount)

-- | A group is laid out flat when it fits the width, broken otherwise, as in
-- Wadler's prettier printer.
group :: Doc -> Doc
group = Group

-- | Prevent enclosing pretty groups from flattening a block-valued argument.
-- Nested groups still choose their own layout; compact mode retains its normal
-- optional-break behavior, and mandatory line breaks are never removed.
multiline :: Doc -> Doc
multiline = Multiline

-- | Prefer a layout while its opening token fits. Qualified calls can wrap
-- arguments first, moving the member name only when the opening itself is long.
prefixChoice :: String -> Doc -> Doc -> Doc
prefixChoice = PrefixChoice

-- | Move a short right-hand side onto its own line when necessary. If it must
-- wrap internally anyway, keep its opening on the same line as the prefix.
hang :: Int -> Doc -> Doc -> Doc
hang amount = Hang (max 0 amount)

-- | Limit a subdocument's first line relative to its starting column. After a
-- break, nested groups can use the full page width. Tokens remain unchanged.
-- Compact layout ignores optional width constraints.
firstLineWidth :: Int -> Doc -> Doc
firstLineWidth width = FirstLineWidth (max 1 width)

-- | Some punctuation, such as a trailing comma, belongs only to the broken
-- layout of its group.
whenBroken :: Doc -> Doc
whenBroken = WhenBroken

-- | The separator goes between documents, never after the last.
joinWith :: Doc -> [Doc] -> Doc
joinWith separator = mconcat . intersperse separator

-- | Greedily pack independent tokens (for example numeric array elements).
-- Unlike commaSep, a wrapped sequence may retain several items on each line.
flow :: [Doc] -> Doc
flow = Flow

-- | Comma-separated lists break after the comma, as every target's style asks.
commaSep :: [Doc] -> Doc
commaSep = joinWith (text "," <> softline)

-- | Closing delimiters return to the surrounding indentation when a group wraps.
delimit :: Int -> String -> String -> [Doc] -> Doc
delimit _ opening closing [] = text (opening ++ closing)
delimit indentation opening closing items = group $
  text opening <> nest indentation (softbreak <> commaSep items)
    <> softbreak <> text closing

-- | Languages such as Rust require a trailing comma in a wrapped argument list
-- to match their standard formatter, but omit it in a one-line list.
delimitTrailing :: Int -> String -> String -> [Doc] -> Doc
delimitTrailing _ opening closing [] = text (opening ++ closing)
delimitTrailing indentation opening closing items = group $
  text opening <> nest indentation (softbreak <> commaSep items <> whenBroken (text ","))
    <> softbreak <> text closing

-- | Braced blocks put the closing brace on its own line, as the brace languages'
-- styles ask. ref:google-style-guides
block :: Int -> Doc -> Doc
block indentation body =
  text "{" <> nest indentation (hardline <> body) <> hardline <> text "}"

-- | Wrap explanatory comment words, never executable source or literal text.
lineComment :: Int -> String -> String -> Doc
lineComment width prefix content = mconcat
  [text (prefix ++ line) <> hardline | line <- wrap [] (concatMap pieces (words content))]
  where
    capacity = max 1 (width - length prefix)
    pieces word
      | length word <= capacity = [word]
      | otherwise = let (part,rest) = splitAt capacity word
                    in part : pieces rest
    wrap current [] = [unwords current | not (null current)]
    wrap current (word:rest)
      | not (null current) && length (prefix ++ unwords (current ++ [word])) > width =
          unwords current : wrap [word] rest
      | otherwise = wrap (current ++ [word]) rest

data Mode = Flat | Broken deriving (Eq)
type Work = [(Int, Mode, Int, Doc)]

-- | One renderer for readable and compact output, so the two layouts differ only
-- in width, never in content. ref:DEC-readable-output-default
render :: Layout -> Doc -> String
render layout doc = layoutWork 0 [(0, initialMode, pageWidth, doc)]
  where
    pageWidth = case layout of Pretty width -> max 1 width; PrettyTabs width -> max 1 width; PrettyDisplay width -> max 1 width; _ -> maxBound
    measure = case layout of PrettyDisplay _ -> displayWidth; _ -> length
    initialMode = case layout of Compact -> Flat; CompactTabs -> Flat; _ -> Broken
    indentationText amount = case layout of
      PrettyTabs _ -> tabs amount
      CompactTabs -> tabs amount
      _ -> replicate amount ' '
    tabs amount = replicate (amount `div` 8) '\t' ++ replicate (amount `mod` 8) ' '
    layoutWork :: Int -> Work -> String
    layoutWork _ [] = ""
    layoutWork column ((indentation, mode, margin, current):rest) = case current of
      Empty -> layoutWork column rest
      Text s -> s ++ layoutWork (lastColumnWith measure column s) rest
      Utf8Text s -> s ++ layoutWork (lastColumnWith utf8Length column s) rest
      Append a b -> layoutWork column ((indentation, mode, margin, a):(indentation, mode, margin, b):rest)
      Nest amount a -> layoutWork column ((indentation + amount, mode, margin, a):rest)
      WhenBroken a -> layoutWork column (if mode == Broken then (indentation, mode, margin, a):rest else rest)
      -- Compact layout already fixes optional breaks to spaces. Hanging can
      -- therefore neither change a line choice nor add block indentation;
      -- avoid rescanning the remaining flat expression at each assignment.
      Hang _ left right | initialMode == Flat ->
        layoutWork column ((indentation, mode, margin, left <> text " " <> right):rest)
      Hang amount left right ->
        let canHang = singleLine right && fits (indentation + amount)
              ((indentation + amount, Flat, margin, right):rest)
            contents = if canHang then group (left <> nest amount (softline <> right))
              else left <> text " " <> right
        in layoutWork column ((indentation, mode, margin, contents):rest)
      PrefixChoice prefix first second ->
        let selected = case layout of
              Compact -> first
              CompactTabs -> first
              _ -> if column + length prefix <= margin &&
                (not (opaqueToken first) ||
                  fits column ((indentation, mode, margin, first):rest))
                then first else second
        in layoutWork column ((indentation, mode, margin, selected):rest)
      Flow [] -> layoutWork column rest
      Flow (a:as) -> layoutWork column ((indentation, mode, margin, a):(indentation, mode, margin, FlowTail as):rest)
      FlowTail [] -> layoutWork column rest
      FlowTail (a:as) ->
        let separator = if mode == Flat || fits (column + 1) [(indentation, Flat, margin, a)]
              then text " " else hardline
        in layoutWork column ((indentation, mode, margin, separator):(indentation, mode, margin, a):
          (indentation, mode, margin, FlowTail as):rest)
      Multiline a -> layoutWork column ((indentation,
        case layout of Compact -> Flat; CompactTabs -> Flat; _ -> Broken, margin, a):rest)
      FirstLineWidth width a -> case layout of
        Compact -> layoutWork column ((indentation, mode, margin, a):rest)
        CompactTabs -> layoutWork column ((indentation, mode, margin, a):rest)
        _ -> layoutWork column ((indentation, Broken, min margin (column + width), a):rest)
      Break replacement -> case (mode, replacement) of
        (Flat, Just s) -> s ++ layoutWork (column + length s) rest
        _ -> let afterBreak = if margin < pageWidth then [(i,m,pageWidth,d) | (i,m,_,d) <- rest] else rest
                 remaining = layoutWork indentation afterBreak
             in '\n' : (if null remaining || head remaining == '\n' then "" else indentationText indentation) ++ remaining
      Group a ->
        let flat = (indentation, Flat, margin, a):rest
            useFlat = case layout of
              Compact -> True
              CompactTabs -> True
              _ -> mode == Flat || fits column flat
        in layoutWork column (if useFlat then flat else (indentation, Broken, margin, a):rest)

    -- Inspect the next physical line, including local width constraints and
    -- following suffixes. Literal contents remain opaque to the renderer.
    fits :: Int -> Work -> Bool
    fits _ [] = True
    fits column ((_, _, margin, _):_) | column > margin = False
    fits column ((indentation, mode, margin, current):rest) = case current of
      Empty -> fits column rest
      Text s -> case break (== '\n') s of
        (prefix, []) -> column + measure prefix <= margin && fits (column + measure prefix) rest
        (prefix, _) -> column + measure prefix <= margin
      Utf8Text s -> case break (== '\n') s of
        (prefix, []) -> column + utf8Length prefix <= margin && fits (column + utf8Length prefix) rest
        (prefix, _) -> column + utf8Length prefix <= margin
      Append a b -> fits column ((indentation, mode, margin, a):(indentation, mode, margin, b):rest)
      Nest amount a -> fits column ((indentation + amount, mode, margin, a):rest)
      WhenBroken a -> fits column (if mode == Broken then (indentation, mode, margin, a):rest else rest)
      Hang _ left right -> fits column ((indentation, mode, margin, left <> text " " <> right):rest)
      FirstLineWidth width a -> fits column ((indentation, Flat, min margin (column + width), a):rest)
      Break (Just s) | mode == Flat -> column + length s <= margin && fits (column + length s) rest
      Break _ -> True
      PrefixChoice prefix first second -> fits column ((indentation, mode, margin,
        if column + length prefix <= margin &&
          (not (opaqueToken first) ||
            fits column ((indentation, mode, margin, first):rest))
          then first else second):rest)
      Flow items -> fits column ((indentation, mode, margin, joinWith (text " ") items):rest)
      FlowTail items -> fits column ((indentation, mode, margin, mconcat [text " " <> item | item <- items]):rest)
      Multiline _ -> False
      Group a -> fits column ((indentation, Flat, margin, a):rest)

    -- An opaque token cannot wrap internally; its following comma or closing
    -- delimiter must fit too. Compound call layouts still test only the prefix.
    opaqueToken (Text _) = True
    opaqueToken (Utf8Text _) = True
    opaqueToken _ = False

    singleLine = line False
      where
        line flat current = case current of
          Empty -> True
          Text s -> '\n' `notElem` s
          Utf8Text s -> '\n' `notElem` s
          Append a b -> line flat a && line flat b
          Break replacement -> case replacement of Just _ -> flat; Nothing -> False
          Nest _ a -> line flat a
          PrefixChoice _ first second -> line flat first && line flat second
          Flow items -> all (line flat) items
          FlowTail items -> all (line flat) items
          Multiline _ -> False
          Group a -> line True a
          FirstLineWidth _ a -> line False a
          Hang _ a b -> line flat a && line flat b
          WhenBroken a -> flat || line flat a

    lastColumnWith measure column s = case break (== '\n') s of
      (_, []) -> column + measure s
      (_, _:rest) -> lastColumnWith measure 0 rest
