-- | Target names have one order across the compiler, scaffolds, API and local
-- CI, so a new backend cannot disappear from one of those entry points.
-- ref:DEC-generated-javascript
module LawSpec.Targets (targets, programTargets, artifactTargets, beamTargets, dotnetTargets, scalaTargets, overJavaTargets, jvmTargets, targetLabel) where

targets :: [String]
targets = programTargets ++ artifactTargets

-- | Executable backends participate in native law execution and its evidence.
programTargets :: [String]
programTargets = ["java", "python", "javascript", "typescript", "go", "haskell",
  "kotlin", "rust"] ++ beamTargets ++ dotnetTargets ++ scalaTargets ++ overJavaTargets ++ ["swift", "prolog"]

-- | Configuration and build artifacts do not execute application laws.
artifactTargets :: [String]
artifactTargets = ["hcl", "yaml", "antlr4", "make"]

-- | Scala runs over the shared JVM runtime, as Kotlin does.
-- ref:DEC-scala-on-the-jvm-runtime
scalaTargets :: [String]
scalaTargets = ["scala"]

-- | The BEAM languages share the Erlang runtime and OTP process semantics.
-- ref:DEC-actors-otp-supervision
beamTargets :: [String]
beamTargets = ["erlang", "elixir", "gleam"]

-- | F# is the .NET runtime; C# runs over it.
-- ref:DEC-fsharp-runtime-from-scratch ref:DEC-csharp-over-fsharp
dotnetTargets :: [String]
dotnetTargets = ["fsharp", "csharp"]

-- | JVM languages over the Java target's model and runtime: the generated
-- Java project is theirs, with their adapters and tests over it.
-- ref:DEC-groovy-over-java ref:DEC-clojure-over-java
overJavaTargets :: [String]
overJavaTargets = ["groovy", "clojure"]

-- | Every target on the JVM runtime (LawSpecRuntime.java): Java's own, the
-- languages with emitters of their own over it (Kotlin, Scala), and those
-- over the Java target's model (Groovy, Clojure).
jvmTargets :: [String]
jvmTargets = ["java", "kotlin"] ++ scalaTargets ++ overJavaTargets

-- | Display names are independent of the lowercase names in requests.
targetLabel :: String -> String
targetLabel target = maybe target id (lookup target
  [("java", "Java"), ("python", "Python"), ("javascript", "JavaScript"),
   ("typescript", "TypeScript"), ("go", "Go"), ("haskell", "Haskell"),
   ("kotlin", "Kotlin"), ("rust", "Rust"), ("erlang", "Erlang"),
   ("elixir", "Elixir"), ("gleam", "Gleam"), ("fsharp", "F#"), ("csharp", "C#"),
   ("scala", "Scala"), ("groovy", "Groovy"), ("clojure", "Clojure"), ("swift", "Swift"),
   ("prolog", "Prolog"), ("hcl", "HCL"), ("yaml", "YAML"), ("antlr4", "ANTLR"), ("make", "Make")])
