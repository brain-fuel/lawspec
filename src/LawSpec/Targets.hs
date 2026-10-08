-- | Target names have one order across the compiler, scaffolds, API and local
-- CI, so a new backend cannot disappear from one of those entry points.
-- ref:DEC-generated-javascript
module LawSpec.Targets (targets, beamTargets, targetLabel) where

targets :: [String]
targets = ["java", "python", "javascript", "typescript", "go", "haskell",
  "kotlin", "rust"] ++ beamTargets

-- | The BEAM languages share the Erlang runtime and OTP process semantics.
-- ref:DEC-actors-otp-supervision
beamTargets :: [String]
beamTargets = ["erlang", "elixir", "gleam"]

-- | Display names are independent of the lowercase names in requests.
targetLabel :: String -> String
targetLabel target = maybe target id (lookup target
  [("java", "Java"), ("python", "Python"), ("javascript", "JavaScript"),
   ("typescript", "TypeScript"), ("go", "Go"), ("haskell", "Haskell"),
   ("kotlin", "Kotlin"), ("rust", "Rust"), ("erlang", "Erlang"),
   ("elixir", "Elixir"), ("gleam", "Gleam")])
