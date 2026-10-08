-- | Typed Gleam data, adapter stubs, checked public FFI wrappers and Gleeunit.
-- ref:DEC-idiomatic-generated-types ref:DEC-total-definitions
module LawSpec.GleamNative (emitNative, unitTests) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import LawSpec.Common (Artifact(..))
import LawSpec.Core.Types (freeExistentials)
import Control.Monad (forM, unless)
import Data.List (nub)

emitNative :: D.Layout -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitNative layout declarations units = do
  names <- E.dataNames declarations
  let typeNames = [E.pascal n | d <- declarations, Just n <- [lookup (C.dataId d) names]]
      tags = [E.pascal n | d <- declarations, c <- C.dataConstructors d, Just n <- [lookup (C.constructorId c) names]]
  unless (length typeNames == length (nub typeNames) && length tags == length (nub tags))
    (Left "Gleam data names collide after PascalCase conversion")
  dataTypes <- mapM (dataType names) declarations
  adapters <- mapM (adapter names) [u | u <- units, not (null (adapterDeclarations u) && null (Abilities.productionAbilities u))]
  definitions <- mapM (nativeUnit names) [u | u <- units, not (null (C.unitDefinitions u))]
  let fields = [C.binderType f | d <- declarations, c <- C.dataConstructors d, f <- C.constructorFields c]
      dynamic = [D.text "import gleam/dynamic" | any (not . null . C.constructorExistentials) (concatMap C.dataConstructors declarations)]
      dataFile = Artifact "src/lawspec/data.gleam"
        (D.render layout (G.fileDoc False (G.imports True fields ++ dynamic ++ dataTypes))) "generated" "source"
  pure ([dataFile | not (null declarations)] ++ adapters ++ definitions)
  where
    named names identity = maybe (Left ("missing Gleam native name: " ++ C.idText identity)) Right (lookup identity names)
    functionName = E.nativeFunction "gleam"
    adapterDeclarations u = [d | d <- C.unitDeclarations u,
      C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]
    signature names unused d = do
      let (args,result) = C.functionType (C.declarationType d)
      handlers <- mapM (Abilities.nativeType "gleam" units) (Effects.uses d)
      inputs <- mapM (G.nativeType False names []) args
      output <- G.nativeType False names [] result
      pure ([D.text ((if unused then "_handler" else "handler") ++ show i ++ ": ") <> t | (i,t) <- zip [0::Int ..] handlers] ++
        [D.text ((if unused then "_argument" else "argument") ++ show i ++ ": ") <> t | (i,t) <- zip [0::Int ..] inputs],output)
    adapter names unit = do
      bodies <- forM (adapterDeclarations unit) $ \d -> do
        (args,result) <- signature names True d
        pure (G.function (functionName d) args result [D.text "panic as " <> G.string ("Not implemented: " ++ C.idText (C.declarationId d))])
      production <- concat <$> mapM (Abilities.productionStub "gleam" 64 names) (Abilities.productionAbilities unit)
      imports <- Abilities.gleamImports units (concatMap Effects.uses (adapterDeclarations unit) ++
        map C.abilityInstance (Abilities.productionAbilities unit))
      let body = G.fileDoc (not (Abilities.defaultUnit unit)) (imports ++ G.imports False (map C.declarationType (adapterDeclarations unit)) ++ bodies ++ production)
          path = "src/" ++ E.gleamPath (C.unitId unit) ++ ".gleam"
      pure (if Abilities.defaultUnit unit then Artifact path (D.render layout body) "generated" "source"
        else AdapterArtifact path (D.render layout body) "user" "source" (D.render (D.Pretty 100) body))
    nativeUnit names unit = do
      let declarations' = map C.definitionDeclaration (C.unitDefinitions unit)
      bodies <- forM declarations' $ \d -> do
        (args,result) <- signature names False d
        pure (G.external (E.moduleName (C.unitId unit) ++ "_definitions_ffi") (functionName d) (functionName d) args result)
      imports <- Abilities.gleamImports units (concatMap Effects.uses declarations')
      pure (Artifact ("src/" ++ E.gleamPath (C.unitId unit) ++ "/definitions.gleam")
        (D.render layout (G.fileDoc False (imports ++ G.imports False (map C.declarationType declarations') ++ bodies))) "generated" "source")
    dataType names d = do
      name <- E.pascal <$> named names (C.dataId d)
      let parameters = zip (C.dataParameters d) ["a" ++ show i | i <- [0::Int ..]]
          applied = if null parameters then D.text name else G.call name (map (D.text . snd) parameters)
      cases <- forM (C.dataConstructors d) $ \c -> do
        tag <- E.pascal <$> named names (C.constructorId c)
        let scope = parameters ++ [(i,"dynamic.Dynamic") | i <- C.constructorExistentials c]
            fields = map (E.gleamName . E.snake . C.binderName) (C.constructorFields c) ++
              ["lawspec_type_" ++ show i | (i,_) <- zip [0::Int ..] (freeExistentials d c)]
        unless (all (not . null) fields && length fields == length (nub fields))
          (Left "Gleam fields collide after name normalization")
        ts <- mapM (G.nativeType True names scope . C.binderType) (C.constructorFields c)
        let allTypes = ts ++ [D.text "String" | _ <- freeExistentials d c]
        pure (if null allTypes then D.text tag else G.call tag [D.text (f ++ ": ") <> t | (f,t) <- zip fields allTypes])
      pure (D.text "pub type " <> applied <>
        if C.dataHandle d || null cases then mempty else
          D.text " {" <> D.nest 2 (D.hardline <> D.joinWith D.hardline cases) <> D.hardline <> D.text "}")

-- | The checked case factories live in test-only Erlang modules. Every case
-- gets a native Gleeunit function so a boundary or example cannot disappear.
unitTests :: D.Layout -> C.Unit -> [(String,Int)] -> Artifact
unitTests layout unit laws = Artifact ("test/" ++ E.moduleName (C.unitId unit) ++ "_lawspec_test.gleam")
  (D.render layout (G.fileDoc False [G.external (E.moduleName (C.unitId unit) ++ "_lawspec_cases")
    (name ++ "_case_" ++ show i) (name ++ "__case_" ++ show i ++ "_test") [] (D.text "Nil")
    | (name,count) <- laws, i <- [0..count-1]])) "generated" "test"
