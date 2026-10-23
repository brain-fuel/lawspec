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
import LawSpec.SourceLink (unitSourceFile)
import LawSpec.Naming (typeWords)

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
  let dataModule = Artifact "lib/lawspec/data.ex" (D.render (X.layoutFor layout) (X.moduleDoc "LawSpec.Data" False types)) "generated" "source"
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
      pure (X.typeAttribute "spec" (X.call (functionName d) (handlers ++ inputs)) output)
    adapter names unit = do
      bodies <- concat <$> forM (adapterDeclarations unit) (\d -> do
        spec <- signature names d
        -- An adapter's arguments are named for their types, unused.
        let named = X.variables ([unwords (typeWords t) | t <- fst (C.functionType (C.declarationType d))] ++
              [abilityWords a ++ " handler" | a <- Effects.uses d])
            arity = length (fst (C.functionType (C.declarationType d)))
            args = [D.text ("_" ++ v) | v <- take arity named]
            handlers = [D.text ("_" ++ v) | v <- drop arity named]
        pure [spec,X.function (functionName d) (handlers ++ args) [D.text "raise " <> X.string ("Not implemented: " ++ C.idText (C.declarationId d))]])
      production <- concat <$> mapM (Abilities.productionStub "elixir" bits names) (Abilities.productionAbilities unit)
      let body = X.moduleDoc (moduleName unit) (not (Abilities.defaultUnit unit)) (bodies ++ production)
          path = "lib/" ++ E.moduleName (C.unitId unit) ++ ".ex"
      pure (if Abilities.defaultUnit unit then Artifact path (D.render (X.layoutFor layout) body) "generated" "source"
        else AdapterArtifact path (D.render (X.layoutFor layout) body) "user" "source" (D.render (D.Pretty 98) body))
    nativeUnit names unit = do
      bodies <- concat <$> forM (C.unitDefinitions unit) (\definition -> do
        let d = C.definitionDeclaration definition
            (arguments,_) = C.functionType (C.declarationType d)
            named = X.variables (map C.binderName (C.definitionArguments definition) ++ [abilityWords a ++ " handler" | a <- Effects.uses d])
            args = map D.text (take (length arguments) named)
            handlers = map D.text (drop (length arguments) named)
        spec <- signature names d
        pure [spec,X.function (functionName d) (handlers ++ args)
          [X.remote (":" ++ E.moduleName (C.unitId unit) ++ "_definitions_ffi") (functionName d) (handlers ++ args)]])
      pure (Artifact ("lib/" ++ E.moduleName (C.unitId unit) ++ "_definitions.ex")
        (D.render (X.layoutFor layout) (X.moduleDoc (moduleName unit ++ ".Definitions") False bodies)) "generated" "source")
    dataStructs names d = forM [c | c <- C.dataConstructors d, not (C.dataHandle d)] $ \c -> do
      tag <- named names (C.constructorId c)
      let fields = E.elixirFields d c
          scope = parameters d ++ [(i,"term()") | i <- C.constructorExistentials c]
          used = [p | p@(identity,_) <- parameters d, any (occurs identity . C.binderType) (C.constructorFields c)]
      types <- mapM (X.nativeType bits names scope . C.binderType) (C.constructorFields c)
      let allTypes = types ++ [X.call "binary" [] | _ <- freeExistentials d c]
          body = [D.text "@enforce_keys " <> X.array (map X.atom fields),
            D.text "defstruct " <> X.array (map X.atom fields),
            X.typeAttribute "type" (X.call "t" (map (D.text . snd) used))
              (D.delimit 2 "%__MODULE__{" "}" [X.atom field <> D.text " => " <> ty | (field,ty) <- zip fields allTypes])]
      pure (Artifact ("lib/lawspec/data/" ++ tag ++ ".ex")
        (D.render (X.layoutFor layout) (X.moduleDoc (E.elixirDataModule tag) False body)) "generated" "source")
    dataType names d = do
      name <- named names (C.dataId d)
      cases <- forM (C.dataConstructors d) $ \c -> do
        tag <- named names (C.constructorId c)
        pure (X.remote (E.elixirDataModule tag) "t" [D.text p | (identity,p) <- parameters d,
          any (occurs identity . C.binderType) (C.constructorFields c)])
      let handles = map (\n -> X.call n []) ["pid","reference","port"] ++
            [X.tuple [X.atom "lawspec_actor",X.call "pid" [],X.array [X.call "term" []]]]
          variants = if C.dataHandle d then handles else if null cases then [X.call "none" []] else cases
          params = [D.text (if any (any (occurs identity . C.binderType) . C.constructorFields) (C.dataConstructors d)
              then p else "_" ++ p) | (identity,p) <- parameters d]
      pure (X.typeAttribute "type" (X.call name params) (D.joinWith (D.text " | ") variants))

occurs :: C.Id -> C.Type -> Bool
occurs identity ty = case ty of
  C.TypeVariable i -> i == identity
  C.Constructor _ args -> any (\a -> case a of C.TypeArgument t -> occurs identity t; _ -> False) args
  C.Arrow a b -> occurs identity a || occurs identity b

unitTests :: D.Layout -> C.Unit -> [(String,Integer,String)] -> Artifact
unitTests layout unit names = Artifact ("test/" ++ E.moduleName (C.unitId unit) ++ "_lawspec_test.exs")
  (D.render (X.layoutFor layout) (X.moduleDocFrom (unitSourceFile unit) (drop (length "Elixir.") (E.nativeModule "elixir" unit) ++ ".LawSpecTest")
    (D.text "use ExUnit.Case, async: false" <> D.hardline <> D.text "import LawSpec.Beam.ExUnitCases" : setup ++ map law (zip [0::Int ..] names)))) "generated" "test"
  where
    settings = C.unitHarnessSettings unit
    random = maybe False C.harnessOrderRandom settings
    parallel = maybe False C.harnessParallel settings
    scheduled = random || parallel
    setup = [D.text "setup_all context do" <> D.nest 2 (D.hardline <>
      X.remote "LawSpec.Beam.ExUnitSchedule" "setup" [D.text "context", X.string (C.idText (C.unitId unit)),
        D.text (if random then "true" else "false"), D.text (if parallel then "true" else "false")]) <>
      D.hardline <> D.text "end" | scheduled]
    -- Each law's tests, from its cases in the shared Erlang module
    -- (LawSpec.Beam.ExUnitCases).
    law (ordinal,(name,allowance,label)) = D.text ("# " ++ label) <> D.hardline <>
      X.call "law" ([X.atom (E.moduleName (C.unitId unit) ++ "_lawspec_cases"), X.atom name, X.string (C.idText (C.unitId unit)),
        X.integer allowance] ++ [X.integer (toInteger ordinal) | scheduled])

-- | An ability's name, as words.
abilityWords :: C.AbilityRef -> String
abilityWords a = reverse (takeWhile (/= ':') (reverse (C.idText (C.abilityRefId a))))
