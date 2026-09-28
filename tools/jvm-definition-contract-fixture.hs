module Main where

import Control.Monad (forM_, unless)
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import Data.Either (isLeft)
import LawSpec.Core
import qualified LawSpec.KotlinExpr as KE
import LawSpec.Common
import DefinitionContractFixture
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaData as J
import qualified LawSpec.JavaDefinitions as J
import qualified LawSpec.KotlinData as K
import qualified LawSpec.KotlinDefinitions as K

main = do
  [directory] <- getArgs
  forM_ [32,64] $ \bits -> forM_ [("pretty",D.Pretty 100),("compact",D.Compact)] $ \(mode,layout) -> do
    forM_ invalidUnits $ \units ->
      unless (isLeft (J.emitJavaDefinitions layout bits [] units))
        (fail "invalid definition contract accepted")
    forM_ [("java",J.emitJavaData,J.emitJavaDefinitions),("kotlin",K.emitKotlinData,K.emitKotlinDefinitions)] $ \(target,dat,defs) -> do
      units <- fixtureUnits bits
      support <- either fail pure (dat layout [])
      bodies <- either fail pure (defs layout bits [] units)
      kotlinExpressions <- if target /= "kotlin" then pure [] else do
        let selected = [d | u <- units, d <- unitDefinitions u,
              declarationName (definitionDeclaration d) `elem` ["allpositive","nestedabove"]]
        methods <- mapM (\d -> do
          body <- either fail pure (KE.renderExpression [] bits idText
            (\_ _ -> Left "unexpected external fixture call") (definitionBody d))
          pure (D.text ("fun " ++ declarationName (definitionDeclaration d) ++
            "(listInput: LawSpecRuntime.Value): LawSpecRuntime.Value = ") <> body)) selected
        let content = D.text "package lawspec.runtime" <> D.hardline <>
              D.joinWith D.hardline methods <> D.hardline <>
              D.text "fun main() {" <> D.hardline <>
              D.text "  fun values(vararg xs: Int) = LawSpecRuntime.list(\"List Int8\", xs.map { LawSpecRuntime.integer(\"Int8\", it.toString()) })" <> D.hardline <>
              D.text "  check(LawSpecRuntime.truth(allpositive(values())))" <> D.hardline <>
              D.text "  check(LawSpecRuntime.truth(allpositive(values(1, 2))))" <> D.hardline <>
              D.text "  check(!LawSpecRuntime.truth(allpositive(values(0, -1))))" <> D.hardline <>
              D.text "  check(LawSpecRuntime.truth(nestedabove(LawSpecRuntime.list(\"List List Int8\", listOf(values(), values(3, 4))))))" <> D.hardline <>
              D.text "  check(!LawSpecRuntime.truth(nestedabove(LawSpecRuntime.list(\"List List Int8\", listOf(values(1, 2))))))" <> D.hardline <>
              D.text "}" <> D.hardline
        pure [Artifact "src/main/kotlin/lawspec/runtime/ListPredicateFixture.kt" (D.render layout content) "generated" "source"]
      let files = kotlinExpressions ++ support ++ bodies ++ [Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java"
            (runtimeSource "java") "generated" "source"]
      forM_ files $ \file -> do
        let destination = directory </> target </> show bits </> mode </> artifactPath file
        createDirectoryIfMissing True (takeDirectory destination)
        writeFile destination (artifactContent file)
