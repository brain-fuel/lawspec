-- | Prettier's document model and printer, so JavaScript and TypeScript are
-- laid out exactly as Prettier lays them out. LawSpec prints the code itself:
-- no formatter runs when code is generated, and native and WASM output stay
-- byte-identical. This is a port of Prettier 3.9.10's printer
-- (src/document/printer/printer.js and the builders it reads), pinned with
-- the formatter acceptance checks generated code against.
-- ref:DEC-readable-output-default ref:prettier
module LawSpec.Code.Prettier
  ( Doc, GroupId, text, cat, indent, align, dedent, group, groupBroken, groupWithId, conditionalGroup
  , fill, ifBreak, ifBreakFor, indentIfBreak, line, softline, hardline, hardlineWithoutBreakParent, allmanLine
  , literalline, breakParent, label, labelOf, join, willBreak, canBreak, removeLines, isEmpty, isGroup
  , render, stringWidth
  ) where

import Data.Char (ord)
import Data.List (intersperse)
import qualified Data.IntMap.Strict as IM
import LawSpec.DisplayWidthData (displayWidthRanges)

-- | A group's identity, for ifBreak and indentIfBreak.
type GroupId = Int

data LineKind = Soft | Plain | Hard | Literal deriving (Eq, Show)

data Doc
  = Str String
  | Cat [Doc]
  | Indent Doc
  | Align (Maybe Int) Doc  -- Nothing: dedent one level
  | Group (Maybe GroupId) Bool Doc [Doc]  -- id, broken, contents, expanded states
  | Fill [Doc]
  | IfBreak Doc Doc (Maybe GroupId)
  | IndentIfBreak Doc GroupId Bool
  | AllmanLine
  | Line LineKind
  | BreakParent
  | Label String Doc
  deriving (Eq, Show)

instance Semigroup Doc where
  a <> b = cat [a, b]

instance Monoid Doc where
  mempty = Cat []

text :: String -> Doc
text = Str

cat :: [Doc] -> Doc
cat [d] = d
cat ds = Cat ds

indent :: Doc -> Doc
indent = Indent

-- | Align by a number of spaces.
align :: Int -> Doc -> Doc
align n = Align (Just n)

dedent :: Doc -> Doc
dedent = Align Nothing

-- | A group breaks when a hard line or breakParent inside it does
-- (Prettier's propagateBreaks); conditional groups stop the propagation.
group :: Doc -> Doc
group d = Group Nothing (propagates d) d []

groupBroken :: Bool -> Doc -> Doc
groupBroken shouldBreak d = Group Nothing (shouldBreak || propagates d) d []

groupWithId :: GroupId -> Bool -> Doc -> Doc
groupWithId gid shouldBreak d = Group (Just gid) (shouldBreak || propagates d) d []

-- | The first state that fits, from the least expanded to the most.
conditionalGroup :: [Doc] -> Doc
conditionalGroup states = case states of
  first : _ -> Group Nothing False first states
  [] -> Cat []

fill :: [Doc] -> Doc
fill = Fill

ifBreak :: Doc -> Doc -> Doc
ifBreak broken flat = IfBreak broken flat Nothing

ifBreakFor :: GroupId -> Doc -> Doc -> Doc
ifBreakFor gid broken flat = IfBreak broken flat (Just gid)

indentIfBreak :: GroupId -> Doc -> Doc
indentIfBreak gid d = IndentIfBreak d gid False

line, softline, hardline, hardlineWithoutBreakParent, literalline, breakParent :: Doc
line = Line Plain
softline = Line Soft
hardline = Cat [Line Hard, BreakParent]
hardlineWithoutBreakParent = Line Hard
literalline = Cat [Line Literal, BreakParent]
breakParent = BreakParent

-- | The brace-style plugin lays out with Prettier first, then moves braces.
-- Measure its original space, but print a newline without propagating a break
-- or changing the logical column used for subsequent layout choices. Syntax
-- nodes choose this delimiter; no generated source is reparsed or rewritten.
-- ref:DEC-google-style-allman
allmanLine :: Doc
allmanLine = AllmanLine

label :: String -> Doc -> Doc
label = Label

labelOf :: Doc -> Maybe String
labelOf (Label l _) = Just l
labelOf _ = Nothing

join :: Doc -> [Doc] -> Doc
join separator = cat . intersperse separator

isGroup :: Doc -> Bool
isGroup d = case d of
  Group {} -> True
  _ -> False

isEmpty :: Doc -> Bool
isEmpty d = case d of
  Str s -> null s
  Cat ds -> all isEmpty ds
  _ -> False

-- | Whether a break inside marks the enclosing group broken.
propagates :: Doc -> Bool
propagates d = case d of
  BreakParent -> True
  Group _ broken _ _ -> broken
  Cat ds -> any propagates ds
  Fill ds -> any propagates ds
  Indent a -> propagates a
  Align _ a -> propagates a
  Label _ a -> propagates a
  IndentIfBreak a _ _ -> propagates a
  IfBreak a b _ -> propagates a || propagates b
  _ -> False

-- | Prettier's willBreak: a broken group, a hard line or breakParent.
willBreak :: Doc -> Bool
willBreak d = case d of
  BreakParent -> True
  Line Hard -> True
  Line Literal -> True
  Group _ broken contents _ -> broken || willBreak contents
  Cat ds -> any willBreak ds
  Fill ds -> any willBreak ds
  Indent a -> willBreak a
  Align _ a -> willBreak a
  Label _ a -> willBreak a
  IndentIfBreak a _ _ -> willBreak a
  IfBreak a b _ -> willBreak a || willBreak b
  _ -> False

-- | Whether the document has any line.
canBreak :: Doc -> Bool
canBreak d = case d of
  Line _ -> True
  Group _ _ contents _ -> canBreak contents
  Cat ds -> any canBreak ds
  Fill ds -> any canBreak ds
  Indent a -> canBreak a
  Align _ a -> canBreak a
  Label _ a -> canBreak a
  IndentIfBreak a _ _ -> canBreak a
  IfBreak a b _ -> canBreak a || canBreak b
  _ -> False

-- | Soft and plain lines as nothing and spaces; ifBreak as its flat form.
removeLines :: Doc -> Doc
removeLines d = case d of
  Line Soft -> Str ""
  Line Plain -> Str " "
  IfBreak _ flat _ -> removeLines flat
  Group gid broken contents states -> Group gid broken (removeLines contents) (map removeLines states)
  Cat ds -> Cat (map removeLines ds)
  Fill ds -> Fill (map removeLines ds)
  Indent a -> Indent (removeLines a)
  Align n a -> Align n (removeLines a)
  Label l a -> Label l (removeLines a)
  IndentIfBreak a gid negate' -> IndentIfBreak (removeLines a) gid negate'
  _ -> d

-- | Prettier's getStringWidth: ASCII by length; otherwise control
-- characters, combining marks and variation selectors take no column and
-- East Asian wide and full-width characters two, from LawSpec's pinned
-- Unicode tables.
stringWidth :: String -> Int
stringWidth s
  | all (\c -> c >= ' ' && c <= '\x7f') s = length s
  | otherwise = sum (map width s)
  where
    width c
      | n <= 0x1f || (n >= 0x7f && n <= 0x9f) = 0
      | n >= 0x300 && n <= 0x36f = 0
      | n >= 0xfe00 && n <= 0xfe0f = 0
      | otherwise = case IM.lookupLE n wideTable of
          Just (_, hi) | n <= hi -> 2
          _ -> 1
      where n = ord c

wideTable :: IM.IntMap Int
wideTable = IM.fromList [(lo, hi) | (lo, hi, 2) <- displayWidthRanges]

data Mode = Flat | Break deriving (Eq, Show)

-- | Indentation as the widths pushed so far.
type Indentation = [Int]

type Command = (Indentation, Mode, Doc)

data Output = Output
  { outText :: String      -- reversed
  , outPosition :: Int
  }

-- | Prettier's printDocToString, for spaces of the given width.
render :: Int -> Int -> Doc -> String
render width tabWidth root = reverse (go IM.empty False (Output "" 0) [([], Break, root)])
  where
    indentLength = sum
    go :: IM.IntMap Mode -> Bool -> Output -> [Command] -> String
    go _ _ out [] = outText out
    go modes remeasure out ((ind, mode, doc) : rest) = case doc of
      Str s -> go modes remeasure (write s out) rest
      Cat ds -> go modes remeasure out ([(ind, mode, d) | d <- ds] ++ rest)
      Indent a -> go modes remeasure out ((tabWidth : ind, mode, a) : rest)
      Align (Just n) a -> go modes remeasure out ((n : ind, mode, a) : rest)
      Align Nothing a -> go modes remeasure out ((drop 1 ind, mode, a) : rest)
      Label _ a -> go modes remeasure out ((ind, mode, a) : rest)
      BreakParent -> go modes remeasure out rest
      Group gid broken contents states ->
        let (command, remeasure') =
              if mode == Flat && not remeasure
                then ((ind, if broken then Break else Flat, contents), remeasure)
                else
                  let remaining = width - outPosition out
                      flat = (ind, Flat, contents)
                  in if not broken && fits flat rest remaining modes False
                       then (flat, False)
                       else if null states
                         then ((ind, Break, contents), False)
                         else if broken
                           then ((ind, Break, last states), False)
                           else case [s | s <- drop 1 (init states), fits (ind, Flat, s) rest remaining modes False] of
                             s : _ -> ((ind, Flat, s), False)
                             [] -> ((ind, Break, last states), False)
            (_, chosenMode, _) = command
            modes' = maybe modes (\i -> IM.insert i chosenMode modes) gid
        in go modes' remeasure' out (command : rest)
      Fill parts -> case parts of
        [] -> go modes remeasure out rest
        [content] ->
          let contentFits = fits (ind, Flat, content) [] (width - outPosition out) modes True
          in go modes remeasure out ((ind, if contentFits then Flat else Break, content) : rest)
        [content, whitespace] ->
          let contentFits = fits (ind, Flat, content) [] (width - outPosition out) modes True
              m = if contentFits then Flat else Break
          in go modes remeasure out ((ind, m, content) : (ind, m, whitespace) : rest)
        content : whitespace : second : more ->
          let remaining = width - outPosition out
              contentFits = fits (ind, Flat, content) [] remaining modes True
              bothFit = fits (ind, Flat, Cat [content, whitespace, second]) [] remaining modes True
              remainder = (ind, mode, Fill (second : more))
              chosen
                | bothFit = [(ind, Flat, content), (ind, Flat, whitespace)]
                | contentFits = [(ind, Flat, content), (ind, Break, whitespace)]
                | otherwise = [(ind, Break, content), (ind, Break, whitespace)]
          in go modes remeasure out (chosen ++ remainder : rest)
      IfBreak broken flat gid ->
        let groupMode = maybe (Just mode) (`IM.lookup` modes) gid
            next = case groupMode of
              Just Break -> [(ind, mode, broken)]
              Just Flat -> [(ind, mode, flat)]
              Nothing -> []
        in go modes remeasure out (next ++ rest)
      IndentIfBreak contents gid negate' ->
        let next = case IM.lookup gid modes of
              Just Break -> [(ind, mode, if negate' then contents else Indent contents)]
              Just Flat -> [(ind, mode, if negate' then Indent contents else contents)]
              Nothing -> []
        in go modes remeasure out (next ++ rest)
      AllmanLine ->
        let trimmed = dropWhile (`elem` (" \t" :: String)) (outText out)
            spaces = replicate (indentLength ind) ' '
        in go modes remeasure (Output (reverse spaces ++ '\n' : trimmed) (outPosition out + 1)) rest
      Line kind -> case (mode, kind) of
        (Flat, Plain) -> go modes remeasure (write " " out) rest
        (Flat, Soft) -> go modes remeasure out rest
        (Flat, _) -> newline True kind
        (Break, _) -> newline remeasure kind
      where
        newline remeasure' kind
          | kind == Literal = go modes remeasure' (Output ('\n' : outText out) 0) rest
          | otherwise =
              let trimmed = dropWhile (`elem` (" \t" :: String)) (outText out)
              in go modes remeasure' (Output (reverse (replicate (indentLength ind) ' ') ++ '\n' : trimmed) (indentLength ind)) rest
    write s (Output o p) = Output (reverse s ++ o) (p + stringWidth s)

    -- Prettier's fits: whether the next command, and the rest up to the
    -- first line break, fit in the remaining width.
    fits :: Command -> [Command] -> Int -> IM.IntMap Mode -> Bool -> Bool
    fits next restCommands remaining0 modes mustBeFlat = loop remaining0 False [(m, d)] restCommands
      where
        (_, m, d) = next
        loop remaining pending stack rest'
          | remaining < 0 = False
          | otherwise = case stack of
              [] -> case rest' of
                [] -> True
                (_, rm, rd) : more -> loop remaining pending [(rm, rd)] more
              (mode, doc) : more -> case doc of
                Str s
                  | null s -> loop remaining pending more rest'
                  | otherwise -> loop (remaining - stringWidth s - (if pending then 1 else 0)) False more rest'
                Cat ds -> loop remaining pending ([(mode, x) | x <- ds] ++ more) rest'
                Fill ds -> loop remaining pending ([(mode, x) | x <- ds] ++ more) rest'
                Indent a -> loop remaining pending ((mode, a) : more) rest'
                Align _ a -> loop remaining pending ((mode, a) : more) rest'
                Label _ a -> loop remaining pending ((mode, a) : more) rest'
                IndentIfBreak a _ _ -> loop remaining pending ((mode, a) : more) rest'
                BreakParent -> loop remaining pending more rest'
                Group _ broken contents states
                  | mustBeFlat && broken -> False
                  | otherwise ->
                      let groupMode = if broken then Break else mode
                          chosen = if not (null states) && groupMode == Break then last states else contents
                      in loop remaining pending ((groupMode, chosen) : more) rest'
                IfBreak broken flat gid ->
                  let groupMode = maybe mode (\i -> IM.findWithDefault Flat i modes) gid
                      chosen = if groupMode == Break then broken else flat
                  in loop remaining pending ((mode, chosen) : more) rest'
                AllmanLine -> loop (remaining - 1) pending more rest'
                Line kind
                  | mode == Break || kind == Hard || kind == Literal -> True
                  | kind == Soft -> loop remaining pending more rest'
                  | otherwise -> loop remaining True more rest'
