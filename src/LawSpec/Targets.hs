-- | Target names have one order across the compiler, scaffolds, API and local
-- CI, so a new backend cannot disappear from one of those entry points.
-- ref:DEC-generated-javascript
module LawSpec.Targets (targets, beamTargets, dotnetTargets, targetLabel) where

targets :: [String]
targets = ["java", "python", "javascript", "typescript", "go", "haskell",
  "kotlin", "rust"] ++ beamTargets ++ dotnetTargets

-- | The BEAM languages share the Erlang runtime and OTP process semantics.
-- ref:DEC-actors-otp-supervision
beamTargets :: [String]
beamTargets = ["erlang", "elixir", "gleam"]

-- | F# is the .NET runtime; C# runs over it.
-- ref:DEC-fsharp-runtime-from-scratch ref:DEC-csharp-over-fsharp
dotnetTargets :: [String]
dotnetTargets = ["fsharp", "csharp"]

-- | Display names are independent of the lowercase names in requests.
targetLabel :: String -> String
targetLabel target = maybe target id (lookup target
  [("java", "Java"), ("python", "Python"), ("javascript", "JavaScript"),
   ("typescript", "TypeScript"), ("go", "Go"), ("haskell", "Haskell"),
   ("kotlin", "Kotlin"), ("rust", "Rust"), ("erlang", "Erlang"),
   ("elixir", "Elixir"), ("gleam", "Gleam"), ("fsharp", "F#"), ("csharp", "C#")])
