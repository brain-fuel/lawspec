-- | Java source read as Groovy. Groovy 5 parses Java's statements, lambdas,
-- records, switch expressions and array initializers, so generated Java
-- becomes Groovy by its literals alone: a double-quoted string would
-- interpolate $, so every string is single-quoted, and a character literal
-- is a one-character string in Groovy, so it is cast to char. A newline
-- ends a Groovy statement where Java's continues it, so a line that starts
-- with a binary operator joins the line before.
-- ref:DEC-groovy-over-java
module LawSpec.Groovy.Source (groovyLiterals, idiomaticGroovy) where

import Data.Char (isAlpha, isAlphaNum, isSpace, isUpper)
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)

-- | Literals rewritten; code and comments unchanged.
groovyLiterals :: String -> String
groovyLiterals = code
  where
    code s = case s of
      [] -> []
      -- A comment's newline is kept: nothing joins a comment.
      '/' : '/' : rest -> let (comment, after) = break (== '\n') rest
                          in "//" ++ comment ++ (case after of '\n' : more -> '\n' : code more; _ -> code after)
      '/' : '*' : rest -> "/*" ++ blockComment rest
      '"' : '"' : '"' : rest -> "'''" ++ textBlock rest
      '\n' : rest | continues (dropWhile (== ' ') rest) -> ' ' : code (dropWhile (== ' ') rest)
      '"' : rest -> '\'' : string rest
      '\'' : rest | (literal, '\'' : after) <- character rest -> "((char) '" ++ literal ++ "')" ++ code after
      c : rest | isAlphaNum c || c == '_' -> let (word, after) = span (\x -> isAlphaNum x || x == '_' || x == '$') s
                                             in word ++ code after
        | otherwise -> c : code rest
    continues line = any (\op -> (op ++ " ") `isPrefixOf` line)
      ["+", "-", "*", "/", "%", "&&", "||", "?", ":", "==", "!=", "<", ">", "<=", ">=", "&", "|", "^", "->", "instanceof"]
    blockComment s = case s of
      '*' : '/' : rest -> "*/" ++ code rest
      c : rest -> c : blockComment rest
      [] -> []
    -- A Java string's escapes are Groovy's, but for the quotes.
    string s = case s of
      '\\' : '"' : rest -> '"' : string rest
      '\\' : c : rest -> '\\' : c : string rest
      '\'' : rest -> '\\' : '\'' : string rest
      '"' : rest -> '\'' : code rest
      c : rest -> c : string rest
      [] -> []
    textBlock s = case s of
      '"' : '"' : '"' : rest -> "'''" ++ code rest
      '\\' : c : rest -> '\\' : c : textBlock rest
      '\'' : '\'' : '\'' : rest -> "\\'\\'\\'" ++ textBlock rest
      c : rest -> c : textBlock rest
      [] -> []
    character s = case s of
      '\\' : 'u' : rest -> let (hex, after) = span isAlphaNum rest in ("\\u" ++ hex, after)
      '\\' : c : rest -> (['\\', c], rest)
      c : rest -> ([c], rest)
      [] -> ([], [])

-- | A user-owned adapter written the way Groovy is: classes and members
-- public by default, no statement semicolons, java.lang's names unqualified,
-- and the classes type-checked with @CompileStatic.
idiomaticGroovy :: String -> String
idiomaticGroovy = unlines . annotate . map line . lines . groovyLiterals
  where
    line l =
      let (indent, rest) = span (== ' ') l
          plain = dropSemicolon (unqualified (maybe rest id (stripPrefix "public " rest)))
          body = if declaration plain then qualified ' ' plain else plain
      in if null rest then l else indent ++ body
    -- Groovy's joint-compilation stubs drop the import of a class used only
    -- as an outer name, so a nested runtime type in a signature is written
    -- in full.
    declaration l =
      any (`isPrefixOf` l) ["static ", "private ", "protected ", "final ", "abstract "] ||
      ("{" `isSuffixOf` l && '(' `elem` l && '=' `notElem` takeWhile (/= '(') l &&
       takeWhile isAlpha l `notElem` ["if", "for", "while", "return", "switch", "try", "catch", "else", "new", "synchronized"])
    qualified before s = case s of
      [] -> []
      _ | not (isAlphaNum before || before == '.' || before == '_')
        , Just rest@(c : _) <- stripPrefix "LawSpecRuntime." s, isUpper c -> "lawspec.runtime.LawSpecRuntime." ++ qualified '.' rest
      c : rest -> c : qualified c rest
    dropSemicolon l
      | ";" `isSuffixOf` l, not ("for (" `isPrefixOf` l) = init l
      | otherwise = l
    unqualified s = case s of
      [] -> []
      '\'' : rest -> let (literal, after) = quoted rest in '\'' : literal ++ unqualified after
      c : _ | isAlpha c || c == '_' ->
        let (word, after) = span (\x -> isAlphaNum x || x `elem` ("_.$" :: String)) s in strip word ++ unqualified after
      c : rest -> c : unqualified rest
    strip word = case stripPrefix "java.lang." word of
      Just rest@(c : _) | isUpper c -> rest
      _ -> word
    quoted s = case s of
      '\\' : c : rest -> let (l, a) = quoted rest in ('\\' : c : l, a)
      '\'' : rest -> ("'", rest)
      c : rest -> let (l, a) = quoted rest in (c : l, a)
      [] -> ([], [])
    -- @CompileStatic on each top-level class, after the imports.
    annotate ls =
      let (before, after) = break topLevelClass ls
      in if null after then ls
         else before ++ ["@groovy.transform.CompileStatic"] ++ take 1 after ++ annotate (drop 1 after)
    topLevelClass l = any (`isPrefixOf` l) ["final class ", "class ", "interface ", "abstract class ", "enum ", "record "]
      && not (all isSpace (take 1 l))
