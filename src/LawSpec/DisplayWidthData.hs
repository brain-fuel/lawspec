{-# LANGUAGE TemplateHaskell #-}

-- | Display widths and unprintable ranges from the pinned Unicode 17.0.0
-- EastAsianWidth.txt and DerivedGeneralCategory.txt, embedded at compile time.
module LawSpec.DisplayWidthData (displayWidthRanges, unprintableRanges) where

import LawSpec.Embed (displayWidthTable, unprintableTable)

-- | Code point ranges whose display width is not one column: (first, last, width).
displayWidthRanges :: [(Int, Int, Int)]
displayWidthRanges = $(displayWidthTable)

-- | Code point ranges a string literal escapes to stay readable: controls,
-- format characters, surrogates, private use, unassigned code points and
-- separators other than the space.
unprintableRanges :: [(Int, Int)]
unprintableRanges = $(unprintableTable)
