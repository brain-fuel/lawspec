{-# LANGUAGE NoOverloadedStrings #-}
-- Templates are JavaScript (or HTML) files with named holes that Haskell
-- fills. Everything outside a hole is copied verbatim.
--
--   /*@ name @*/      inline: replaced by a value; continuation lines of a
--                     multi-line value are indented to the marker's column
--   <!--@ name @-->   inline, in HTML
--   //@ name          alone on a line: replaced by lines of code, each
--                     indented like the marker
--
-- Every hole in a template must have a value; the caller checks that every
-- value is used by some template.
module Gen.Template (Fill(..), fillTemplate) where

import Control.Monad (forM)
import Data.List (isPrefixOf, nub, stripPrefix)

data Fill = Inline String | Block [String]

-- The filled text and the holes it used.
fillTemplate :: FilePath -> [(String, Fill)] -> String -> Either String (String, [String])
fillTemplate path fills source = do
  (filled, used) <- unzip <$> forM (lines source) line
  pure (unlines (concat filled), nub (concat used))
  where
    failure message = Left (path ++ ": " ++ message)
    value name = maybe (failure ("no value for hole " ++ name)) Right (lookup name fills)
    line text = case stripPrefix "//@ " (dropWhile (== ' ') text) of
      Just name | isName name -> do
        let indent = takeWhile (== ' ') text
        fill <- value name
        case fill of
          Block ls -> pure ([if null l then "" else indent ++ l | l <- ls], [name])
          Inline _ -> failure (name ++ " is an inline value used as a block")
      _ -> do
        (out, names) <- inline 0 text
        pure (lines' out, names)
    lines' out = case lines out of [] -> [""]; ls -> ls
    inline column text = case text of
      [] -> pure ("", [])
      _ | Just (name, rest) <- marker "/*@ " " @*/" text -> substitute column name rest
        | Just (name, rest) <- marker "<!--@ " " @-->" text -> substitute column name rest
        | "/*@" `isPrefixOf` text || "<!--@" `isPrefixOf` text -> failure ("malformed hole near: " ++ take 40 text)
      c : rest -> do
        (out, names) <- inline (column + 1) rest
        pure (c : out, names)
    substitute column name rest = do
      fill <- value name
      rendered <- case fill of
        Inline v -> pure (indentContinuation column v)
        Block _ -> failure (name ++ " is a block value used inline")
      (out, names) <- inline (column + length (last' (lines rendered))) rest
      pure (rendered ++ out, name : names)
    last' [] = ""
    last' ls = last ls
    indentContinuation column v = case lines v of
      first : more -> concat (first : ["\n" ++ replicate column ' ' ++ l | l <- more])
      [] -> ""
    marker open close text = do
      rest <- stripPrefix open text
      let (name, after) = break (== ' ') rest
      remaining <- stripPrefix close after
      if isName name then Just (name, remaining) else Nothing
    isName name = not (null name) && all (`elem` ('-' : '_' : ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'])) name
