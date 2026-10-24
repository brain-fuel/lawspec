-- | Stateful models on .NET: each machine's portable spec, its callbacks to
-- the checked entries, and an xUnit test for each check (sequential,
-- parallel, each scenario, and supervision), in F# or C#. The runtime's model
-- runner supplies generation and shrinking, the same on every target.
-- ref:DEC-stateful-models-linearizability ref:DEC-portable-seeded-generation
module LawSpec.DotNet.Models (emitModels) where

import qualified LawSpec.Core as C
import LawSpec.SourceLink (generatedHeader, unitSourceFile)
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamModelChecks as Checks
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
import LawSpec.DotNet.Code
import qualified LawSpec.DotNet.Layout as L
import LawSpec.DotNet.Names
import LawSpec.DotNet.Entries
import qualified LawSpec.DotNet.Effects as Effects
import qualified LawSpec.DotNet.Policy as Policy
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)

-- | An application with one more argument.
withText :: L.F -> String -> L.F
withText (L.App f args) x = L.App f (args ++ [L.A x])
withText e _ = e

emitModels :: Lang -> D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitModels lang layout bits datas units = concat <$> mapM unitFile
  [u | u <- units, not (null (C.unitMachines u) && null (C.unitSupervisors u))]
  where
    fs = lang == FSharp
    declarations = [(C.declarationId d, d) | u <- units, d <- C.unitDeclarations u]
    declaration identity = maybe (Left ("missing .NET model declaration " ++ C.idText identity)) Right (lookup identity declarations)
    callback identity = do
      d <- declaration identity
      e <- maybe (Left ("missing .NET model callback " ++ C.idText identity)) Right (lookup identity (entries units))
      let count = length (fst (C.functionType (C.declarationType d)))
      pure $ if fs
        then "(fun (context: Model.CallbackContext) (arguments: Value list) -> " ++ entryModule e ++ "." ++ entryFs e ++
          " (fst context) (snd context)" ++ concat [" (Runtime.item " ++ show i ++ " arguments)" | i <- [0 .. count - 1]] ++ ")"
        else "Fn.F2((Tuple<Schema.Schema, Scalar.SymbolContext> context, FSharpList<Value> arguments) => " ++ entryModule e ++ "." ++ entryCs e ++
          "(" ++ intercalate ", " (["context.Item1", "context.Item2"] ++ ["Runtime.Item(" ++ show i ++ ", arguments)" | i <- [0 .. count - 1]]) ++ "))"
    -- An entry as an F# callback: Model.callN of its arity, or a function
    -- of the context and arguments.
    fsCallback identity = do
      d <- declaration identity
      e <- maybe (Left ("missing .NET model callback " ++ C.idText identity)) Right (lookup identity (entries units))
      let count = length (fst (C.functionType (C.declarationType d)))
          entry = entryModule e ++ "." ++ entryFs e
      pure $ if count <= 4 then L.App ("Model.call" ++ show count) [L.A entry]
        else L.Fun "(context: Model.CallbackContext) (arguments: Value list)" (L.App entry
          ([L.App "fst" [L.A "context"], L.App "snd" [L.A "context"]] ++ [L.App "Runtime.item" [L.A (show i), L.A "arguments"] | i <- [0 .. count - 1]]))
    fsOptional = maybe (pure (L.A "None")) (fmap (\c -> L.App "Some" [c]) . fsCallback)
    none = if fs then "None" else "FSharpOption<FSharpFunc<Tuple<Schema.Schema, Scalar.SymbolContext>, FSharpFunc<FSharpList<Value>, Value>>>.None"
    some c = if fs then "(Some " ++ c ++ ")" else "Fn.Some(" ++ c ++ ")"
    tuple xs = if fs then "(" ++ intercalate ", " xs ++ ")" else "Fn.Tuple(" ++ intercalate ", " xs ++ ")"
    list xs = if fs then "[ " ++ intercalate "; " xs ++ " ]" else "Fn.List(" ++ intercalate ", " xs ++ ")"
    optional = maybe (pure none) (fmap some . callback)
    unitFile unit = do
      let names = Checks.machineNames unit
      prepared <- forM (zip names (C.unitMachines unit)) $ \(name, machine) -> do
        unless (machineConsistency machine /= Eventual || machineAbstractRun machine /= Nothing)
          (Left (".NET eventual model " ++ machineName machine ++ " needs abstract to compare the final state"))
        spec <- machineSpec bits datas (C.unitDeclarations unit) (C.unitContracts unit) machine
        start <- case machineStart machine of
          -- F# compiles a tupled parameter as two .NET parameters.
          Just s -> (\a b -> if fs then tuple [a, b] else a ++ ", " ++ b) <$> callback (startRun s) <*> callback (startModel s)
          Nothing -> Left "a .NET model needs a start command"
        commands <- forM (machineCommands machine) $ \c -> do
          run <- callback (commandRun c)
          reference <- callback (commandReference c)
          condition <- optional (commandWhen c)
          pure (tuple [run, reference, condition])
        abstract <- optional (machineAbstractRun machine)
        let invariant (OnModel f) = f
            invariant (OnState f) = f
        invariants <- mapM (callback . invariant) (machineInvariants machine)
        ds <- mapM declaration (nub (foldr (:) [] machine))
        made <- Effects.factories units (Var "symbols") [(a, C.ProductionHandler) | a <- nub (concatMap Effects.uses ds)]
        let factoryTy = Ty "(string * (Schema.Schema -> Effects.Handler)) list" "FSharpList<Tuple<string, FSharpFunc<Schema.Schema, Effects.Handler>>>"
            factoriesName = name ++ "Factories"
            policies = Policy.usesPolicies units
        fsModel <- if not fs then pure Nothing else do
          fsStart <- case machineStart machine of
            Just st -> (\a b -> L.Tuple [a, b]) <$> fsCallback (startRun st) <*> fsCallback (startModel st)
            Nothing -> Left "a .NET model needs a start command"
          fsCommands <- forM (machineCommands machine) $ \c -> do
            run <- fsCallback (commandRun c)
            reference <- fsCallback (commandReference c)
            condition <- fsOptional (commandWhen c)
            pure (L.Tuple [run, reference, condition])
          fsAbstract <- fsOptional (machineAbstractRun machine)
          fsInvariants <- mapM (fsCallback . invariant) (machineInvariants machine)
          pure (Just (fsStart, fsCommands, fsAbstract, fsInvariants))
        pure $ case fsModel of
          Just (fsStart, fsCommands, fsAbstract, fsInvariants) ->
            let context = L.App "Model.contextWith" [L.A "LawSpec.Generated.Program.schema", L.A factoriesName]
                withRuntime = if policies
                  then L.Fun "body" (L.App "Workflow.withTestRuntime" [L.Fun "()" (L.App ("(" ++ maybe "" id (L.flat context) ++ ")") [L.A "body"])])
                  else context
                created = L.App "Model.create" [L.A (stringLiteral FSharp spec), fsStart, L.List fsCommands, fsAbstract, L.List fsInvariants]
                piped = foldl (L.Infix "|>") created
                  ([L.App "Model.withContextFactory" [withRuntime]] ++ [L.App "Model.withActors" [L.A "ActorHost.host"] | machineActor machine])
            in D.text ("let private " ++ factoriesName ++ ": Scalar.SymbolContext -> " ++ tyText FSharp factoryTy ++ " =") <>
              D.nest 4 (D.hardline <> renderBody FSharp 4 (tFun [tSymbols] factoryTy) (Lambda [("symbols", tSymbols)] factoryTy made)) <>
              D.hardline <> D.hardline <> D.text ("/// The model " ++ machineName machine ++ ".") <> D.hardline <>
              L.linesDoc 0 (L.function 0 ("let private " ++ name) ["()"] (Just "Model.Model") piped)
          Nothing ->
            let context = "LawSpec.Testing.Model.ContextWith(LawSpec.Generated.Program.Schema, " ++ pascal factoriesName ++ "())"
                withRuntime = if policies
                  then "Fn.F1((FSharpFunc<Tuple<Schema.Schema, Scalar.SymbolContext>, object> body) => Workflow.WithTestRuntime(Fn.F0(() => " ++ context ++ ".Invoke(body))))"
                  else context
                modelExpr = "LawSpec.Testing.Model.Create(" ++ stringLiteral CSharp spec ++ ", " ++ start ++ ", " ++ list commands ++ ", " ++ abstract ++ ", " ++
                  (if null invariants then "FSharpList<FSharpFunc<Tuple<Schema.Schema, Scalar.SymbolContext>, FSharpFunc<FSharpList<Value>, Value>>>.Empty" else list invariants) ++ ")"
                withContext = "LawSpec.Testing.Model.WithContext(" ++ withRuntime ++ ", " ++ modelExpr ++ ")"
            in D.text ("private static FSharpFunc<Scalar.SymbolContext, " ++ tyText CSharp factoryTy ++ "> " ++ pascal factoriesName ++ "()") <> D.hardline <>
              D.block 4 (renderBody CSharp 8 (tFun [tSymbols] factoryTy) (Lambda [("symbols", tSymbols)] factoryTy made)) <>
              D.hardline <> D.hardline <> D.text ("/// <summary>The model " ++ machineName machine ++ ".</summary>") <> D.hardline <>
              D.text ("private static LawSpec.Testing.Model.Model " ++ pascal name ++ "() =>") <> D.nest 4 (D.hardline <>
                D.text (if machineActor machine then "LawSpec.Testing.Model.WithActors(LawSpec.Testing.ActorHost.Host, " ++ withContext ++ ");" else withContext ++ ";"))
      cases <- forM (Checks.checks unit) $ \check -> do
        let model n = if fs then "(" ++ n ++ " ())" else pascal n ++ "()"
        action <- case Checks.checkAction check of
          Checks.Sequential name _ -> pure (if fs then L.A ("Model.check " ++ model name) else L.A ("LawSpec.Testing.Model.Check(" ++ model name ++ ");"))
          Checks.Parallel name _ -> pure (if fs then L.A ("ModelParallel.check " ++ model name) else L.A ("LawSpec.Testing.ModelParallel.Check(" ++ model name ++ ");"))
          Checks.Scenario name _ program -> do
            wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
            let text = P.programSpec (program { P.programWire = wire })
            pure (if fs then L.App "Scenario.check" [L.A model' | let model' = model name] `withText` stringLiteral FSharp text
              else L.A ("LawSpec.Testing.Scenario.Check(" ++ model name ++ ", " ++ stringLiteral CSharp text ++ ");"))
          Checks.Supervision -> pure (if fs then L.A "Supervision.check ()" else L.A "LawSpec.Testing.Supervision.Check();")
        pure $ if fs
          then D.text ("[<Fact(DisplayName = " ++ stringLiteral FSharp (Checks.checkLabel check) ++ ")>]") <> D.hardline <>
            L.linesDoc 0 (L.function 0 ("let " ++ Checks.checkName check) ["()"] (Just "unit") action)
          else D.text ("[Fact(DisplayName = " ++ stringLiteral CSharp (Checks.checkLabel check) ++ ")]") <> D.hardline <>
            D.text ("public void " ++ pascal (Checks.checkName check) ++ "() => " ++ maybe "" id (L.flat action))
      let moduleName = testModule (C.unitId unit) ++ "Models"
          doc = if fs
            then D.text ("// " ++ generatedHeader (unitSourceFile unit)) <> D.hardline <>
              D.text ("/// The models of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
              D.text "[<Xunit.Collection(\"LawSpec\")>]" <> D.hardline <>
              D.text ("module " ++ moduleName) <> D.hardline <> D.hardline <>
              D.text "open Xunit" <> D.hardline <> D.text "open LawSpec.Runtime" <> D.hardline <>
              D.text "open LawSpec.Testing" <> D.hardline <> D.hardline <>
              D.joinWith (D.hardline <> D.hardline) (prepared ++ cases) <> D.hardline
            else D.text ("// " ++ generatedHeader (unitSourceFile unit)) <> D.hardline <>
              D.text ("namespace " ++ intercalate "." (init (splitDots moduleName)) ++ ";") <> D.hardline <> D.hardline <>
              D.joinWith D.hardline (map D.text csUsings) <> D.hardline <> D.hardline <>
              D.text ("/// <summary>The models of " ++ C.idText (C.unitId unit) ++ ".</summary>") <> D.hardline <>
              D.text "[Collection(\"LawSpec\")]" <> D.hardline <>
              D.text ("public sealed class " ++ last (splitDots moduleName)) <> D.hardline <>
              D.block 4 (D.joinWith (D.hardline <> D.hardline) (prepared ++ cases)) <> D.hardline
      pure [Artifact ("tests/LawSpec/" ++ last (splitDots moduleName) ++ extension lang) (D.render layout doc) "generated" "test"]
    csUsings =
      [ "using System;", "using System.Collections.Generic;", "using System.Numerics;", "using Microsoft.FSharp.Core;"
      , "using Microsoft.FSharp.Collections;", "using LawSpec.Runtime;", "using LawSpec.CSharp;", "using LawSpec.Testing;", "using Xunit;"
      , "using Runtime = LawSpec.Runtime.Runtime;", "using Value = LawSpec.Runtime.Value;" ]
