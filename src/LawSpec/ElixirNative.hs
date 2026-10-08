{-# LANGUAGE NoOverloadedStrings #-}
-- | Structs, typed adapter functions, checked public definitions and ExUnit
-- tests for the Elixir target. Shared Core bodies remain in Erlang modules.
-- ref:DEC-total-definitions ref:DEC-native-property-frameworks
module LawSpec.ElixirNative (emitNative, unitTests) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import LawSpec.Core.Types (freeExistentials)
import LawSpec.Common (Artifact(..))
import Control.Monad (forM, unless)
import Data.List (nub)

emitNative :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitNative layout bits declarations units = do
  names <- E.dataNames declarations
  let modules = [E.elixirDataModule tag | d <- declarations, c <- C.dataConstructors d,
        Just tag <- [lookup (C.constructorId c) names]]
  unless (length modules == length (nub modules) && all ((<= 248) . length) modules)
    (Left "Elixir data modules collide after PascalCase conversion or exceed the atom limit")
  structs <- concat <$> mapM (dataStructs names) declarations
  types <- mapM (dataType names) declarations
  adapters <- mapM (adapter names) [u | u <- units, not (null (adapterDeclarations u) && null (Abilities.productionAbilities u))]
  definitions <- mapM (nativeUnit names) [u | u <- units, not (null (C.unitDefinitions u))]
  let dataModule = Artifact "lib/lawspec/data.ex" (D.render layout (X.moduleDoc "LawSpec.Data" False types)) "generated" "source"
  pure (dataModule : structs ++ adapters ++ definitions)
  where
    named names identity = maybe (Left ("missing Elixir native name: " ++ C.idText identity)) Right (lookup identity names)
    moduleName = drop (length "Elixir.") . E.nativeModule "elixir"
    functionName = E.nativeFunction "elixir"
    parameters d = zip (C.dataParameters d) ["t" ++ show i | i <- [0::Int ..]]
    adapterDeclarations u = [d | d <- C.unitDeclarations u,
      C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]
    signature names d = do
      let (args,result) = C.functionType (C.declarationType d)
      handlers <- mapM (Abilities.nativeType "elixir" units) (Effects.uses d)
      inputs <- mapM (X.nativeType bits names []) args
      output <- X.nativeType bits names [] result
      pure (D.group (D.text "@spec " <> X.call (functionName d) (handlers ++ inputs) <> D.text " ::" <> D.nest 2 (D.softline <> output)))
    adapter names unit = do
      bodies <- concat <$> forM (adapterDeclarations unit) (\d -> do
        spec <- signature names d
        let args = [D.text ("_argument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d)))]
            handlers = [D.text ("_handler" ++ show i) | (i,_) <- zip [0::Int ..] (Effects.uses d)]
        pure [spec,X.function (functionName d) (handlers ++ args) [D.text "raise " <> X.string ("Not implemented: " ++ C.idText (C.declarationId d))]])
      production <- concat <$> mapM (Abilities.productionStub "elixir" bits names) (Abilities.productionAbilities unit)
      let body = X.moduleDoc (moduleName unit) (not (Abilities.defaultUnit unit)) (bodies ++ production)
          path = "lib/" ++ E.moduleName (C.unitId unit) ++ ".ex"
      pure (if Abilities.defaultUnit unit then Artifact path (D.render layout body) "generated" "source"
        else AdapterArtifact path (D.render layout body) "user" "source" (D.render (D.Pretty 100) body))
    nativeUnit names unit = do
      bodies <- concat <$> forM (C.unitDefinitions unit) (\definition -> do
        let d = C.definitionDeclaration definition
            (arguments,_) = C.functionType (C.declarationType d)
            args = [D.text ("native" ++ show i) | (i,_) <- zip [0::Int ..] arguments]
            handlers = [D.text ("handler" ++ show i) | (i,_) <- zip [0::Int ..] (Effects.uses d)]
        spec <- signature names d
        pure [spec,X.function (functionName d) (handlers ++ args)
          [X.remote (":" ++ E.moduleName (C.unitId unit) ++ "_definitions_ffi") (functionName d) (handlers ++ args)]])
      pure (Artifact ("lib/" ++ E.moduleName (C.unitId unit) ++ "_definitions.ex")
        (D.render layout (X.moduleDoc (moduleName unit ++ ".Definitions") False bodies)) "generated" "source")
    dataStructs names d = forM [c | c <- C.dataConstructors d, not (C.dataHandle d)] $ \c -> do
      tag <- named names (C.constructorId c)
      let fields = E.elixirFields d c
          scope = parameters d ++ [(i,"term()") | i <- C.constructorExistentials c]
          used = [p | p@(identity,_) <- parameters d, any (occurs identity . C.binderType) (C.constructorFields c)]
      types <- mapM (X.nativeType bits names scope . C.binderType) (C.constructorFields c)
      let allTypes = types ++ [X.call "binary" [] | _ <- freeExistentials d c]
          body = [D.text "@enforce_keys " <> X.array (map X.atom fields),
            D.text "defstruct " <> X.array (map X.atom fields),
            D.text "@type " <> X.call "t" (map (D.text . snd) used) <> D.text " :: " <>
              D.delimit 2 "%__MODULE__{" "}" [X.atom field <> D.text " => " <> ty | (field,ty) <- zip fields allTypes]]
      pure (Artifact ("lib/lawspec/data/" ++ tag ++ ".ex")
        (D.render layout (X.moduleDoc (E.elixirDataModule tag) False body)) "generated" "source")
    dataType names d = do
      name <- named names (C.dataId d)
      cases <- forM (C.dataConstructors d) $ \c -> do
        tag <- named names (C.constructorId c)
        pure (X.remote (E.elixirDataModule tag) "t" [D.text p | (identity,p) <- parameters d,
          any (occurs identity . C.binderType) (C.constructorFields c)])
      let handles = map (\n -> X.call n []) ["pid","reference","port"]
          variants = if C.dataHandle d then handles else if null cases then [X.call "none" []] else cases
          params = [D.text (if any (any (occurs identity . C.binderType) . C.constructorFields) (C.dataConstructors d)
              then p else "_" ++ p) | (identity,p) <- parameters d]
      pure (D.group (D.text "@type " <> X.call name params <> D.text " ::" <>
        D.nest 2 (D.softline <> D.joinWith (D.softline <> D.text "| ") variants)))

occurs :: C.Id -> C.Type -> Bool
occurs identity ty = case ty of
  C.TypeVariable i -> i == identity
  C.Constructor _ args -> any (\a -> case a of C.TypeArgument t -> occurs identity t; _ -> False) args
  C.Arrow a b -> occurs identity a || occurs identity b

unitTests :: D.Layout -> C.Unit -> [String] -> Artifact
unitTests layout unit names = Artifact ("test/" ++ E.moduleName (C.unitId unit) ++ "_lawspec_test.exs")
  (D.render layout (X.moduleDoc (drop (length "Elixir.") (E.nativeModule "elixir" unit) ++ ".LawSpecTest") False
    (D.text "use ExUnit.Case, async: false" : map law names))) "generated" "test"
  where
    cases name = X.remote (":" ++ E.moduleName (C.unitId unit) ++ "_lawspec_cases") (name ++ "_test_") []
    law name = D.text "for {{label, _}, index} <- Enum.with_index(" <> cases name <> D.text ") do" <>
      D.nest 2 (D.hardline <> D.text "@tag lawspec: " <> X.string name <>
        D.hardline <> D.text "@tag lawspec_label: List.to_string(label)" <>
        D.hardline <> D.text "test " <> X.string (name ++ "__case_") <> D.text " <> Integer.to_string(index) do" <>
        D.nest 2 (D.hardline <> D.text "{_, run} = Enum.at(" <> cases name <> D.text ", unquote(index))" <>
          D.hardline <> D.text "run.()") <> D.hardline <> D.text "end") <> D.hardline <> D.text "end"
