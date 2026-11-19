-- | The native facts of a source, by its extension: authoring.mjs parse,
-- over the Haskell extractors in LawSpec.Authoring.Languages.
-- ref:DEC-authoring-advisories
module LawSpec.Authoring.Extract
  ( languageOf,
    extract,
  )
where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified LawSpec.Authoring.Languages.CSharp as CSharp
import qualified LawSpec.Authoring.Languages.Clojure as Clojure
import qualified LawSpec.Authoring.Languages.Elixir as Elixir
import qualified LawSpec.Authoring.Languages.Erlang as Erlang
import qualified LawSpec.Authoring.Languages.FSharp as FSharp
import qualified LawSpec.Authoring.Languages.Gleam as Gleam
import qualified LawSpec.Authoring.Languages.Go as Go
import qualified LawSpec.Authoring.Languages.Groovy as Groovy
import qualified LawSpec.Authoring.Languages.Haskell as Haskell
import qualified LawSpec.Authoring.Languages.Java as Java
import qualified LawSpec.Authoring.Languages.Kotlin as Kotlin
import qualified LawSpec.Authoring.Languages.Prolog as Prolog
import qualified LawSpec.Authoring.Languages.Python as Python
import qualified LawSpec.Authoring.Languages.Rust as Rust
import qualified LawSpec.Authoring.Languages.Scala as Scala
import qualified LawSpec.Authoring.Languages.Script as Script
import qualified LawSpec.Authoring.Languages.Swift as Swift
import LawSpec.Authoring.Syntax

-- | authoring.mjs extensions: the language each native extension selects.
languageOf :: FilePath -> Maybe String
languageOf path = lookup (extname path) table
  where
    table =
      [ (".java", "java"),
        (".py", "python"),
        (".js", "javascript"),
        (".mjs", "javascript"),
        (".cjs", "javascript"),
        (".ts", "typescript"),
        (".mts", "typescript"),
        (".cts", "typescript"),
        (".tsx", "tsx"),
        (".jsx", "javascript"),
        (".go", "go"),
        (".hs", "haskell"),
        (".lhs", "literate-haskell"),
        (".kt", "kotlin"),
        (".kts", "kotlin"),
        (".rs", "rust"),
        (".erl", "erlang"),
        (".hrl", "erlang"),
        (".ex", "elixir"),
        (".exs", "elixir"),
        (".gleam", "gleam"),
        (".fs", "fsharp"),
        (".fsx", "fsharp"),
        (".fsi", "fsharp"),
        (".cs", "csharp"),
        (".scala", "scala"),
        (".groovy", "groovy"),
        (".clj", "clojure"),
        (".cljc", "clojure"),
        (".swift", "swift"),
        (".pl", "prolog")
      ]

-- | path.extname: from the last dot of the base name, unless that dot
-- starts it.
extname :: FilePath -> String
extname path =
  let base = reverse (takeWhile (/= '/') (reverse path))
   in case break (== '.') (reverse base) of
        (after, '.' : before@(_ : _)) | any (/= '.') before || not (null after) -> '.' : reverse after
        _ -> ""

-- | authoring.mjs parse: the facts of one source, or why there are none.
extract :: FilePath -> Text -> Facts
extract path content = case languageOf path of
  Nothing -> (failed "No grammar selected for this file extension") {factsStatus = "unsupported"}
  Just language
    | B.length (T.encodeUtf8 content) > 2 * 1024 * 1024 -> failed "Native file exceeds the 2 MiB analysis limit"
    | otherwise -> case lookup language extractors of
        Just extractor -> extractor content
        -- TSX and literate Haskell have no extractor, as they had no
        -- bundled grammar.
        Nothing -> failed ("No bundled parser for " <> textOf language)
  where
    textOf = T.pack
    extractors =
      [ ("java", Java.facts),
        ("python", Python.facts),
        ("javascript", Script.facts False),
        ("typescript", Script.facts True),
        ("go", Go.facts),
        ("haskell", Haskell.facts),
        ("kotlin", Kotlin.facts),
        ("rust", Rust.facts),
        ("erlang", Erlang.facts),
        ("elixir", Elixir.facts),
        ("gleam", Gleam.facts),
        ("fsharp", FSharp.facts),
        ("csharp", CSharp.facts),
        ("scala", Scala.facts),
        ("groovy", Groovy.facts),
        ("clojure", Clojure.facts),
        ("swift", Swift.facts),
        ("prolog", Prolog.facts)
      ]
