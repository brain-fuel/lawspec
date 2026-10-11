-- | Stateful models on .NET: each machine's portable spec, its callbacks to
-- the checked entries, and an xUnit test for each check (sequential,
-- parallel, each scenario, and supervision), in F# or C#. The runtime's model
-- runner supplies generation and shrinking, the same on every target.
-- ref:DEC-stateful-models-linearizability ref:DEC-portable-seeded-generation
module LawSpec.DotNet.Models (emitModels) where

import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import qualified LawSpec.Core.Program as P
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamModelChecks as Checks
import LawSpec.MachineSpec (machineSpec, scenarioWire)
import LawSpec.Common (Artifact(..))
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import LawSpec.DotNet.Entries
import qualified LawSpec.DotNet.Effects as Effects
import qualified LawSpec.DotNet.Policy as Policy
import Control.Monad (forM, unless)
import Data.List (nub, intercalate)

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
        pure $ if fs
          then
            let context = "Model.contextWith LawSpec.Generated.Program.schema " ++ factoriesName
                withRuntime = if policies
                  then "(fun body -> Workflow.withTestRuntime (fun () -> (" ++ context ++ ") body))"
                  else "(" ++ context ++ ")"
            in D.text ("let private " ++ factoriesName ++ " : Scalar.SymbolContext -> " ++ tyText FSharp factoryTy ++ " =") <>
              D.nest 4 (D.hardline <> renderBody FSharp (tFun [tSymbols] factoryTy) (Lambda [("symbols", tSymbols)] factoryTy made)) <>
              D.hardline <> D.hardline <> D.text ("/// The model " ++ machineName machine ++ ".") <> D.hardline <>
              D.text ("let private " ++ name ++ " () : Model.Model =") <> D.nest 4 (D.hardline <>
                D.text ("Model.create " ++ stringLiteral FSharp spec) <> D.nest 4 (D.hardline <>
                  D.text start <> D.hardline <>
                  D.text "[ " <> D.joinWith (D.hardline <> D.text "  ") (map D.text commands) <> D.text " ]" <> D.hardline <>
                  D.text abstract <> D.hardline <>
                  D.text (list invariants)) <> D.hardline <>
                D.text ("|> Model.withContextFactory " ++ withRuntime) <>
                (if machineActor machine then D.hardline <> D.text "|> Model.withActors ActorHost.host" else mempty))
          else
            let context = "LawSpec.Testing.Model.ContextWith(LawSpec.Generated.Program.Schema, " ++ pascal factoriesName ++ "())"
                withRuntime = if policies
                  then "Fn.F1((FSharpFunc<Tuple<Schema.Schema, Scalar.SymbolContext>, object> body) => Workflow.WithTestRuntime(Fn.F0(() => " ++ context ++ ".Invoke(body))))"
                  else context
                modelExpr = "LawSpec.Testing.Model.Create(" ++ stringLiteral CSharp spec ++ ", " ++ start ++ ", " ++ list commands ++ ", " ++ abstract ++ ", " ++
                  (if null invariants then "FSharpList<FSharpFunc<Tuple<Schema.Schema, Scalar.SymbolContext>, FSharpFunc<FSharpList<Value>, Value>>>.Empty" else list invariants) ++ ")"
                withContext = "LawSpec.Testing.Model.WithContext(" ++ withRuntime ++ ", " ++ modelExpr ++ ")"
            in D.text ("private static FSharpFunc<Scalar.SymbolContext, " ++ tyText CSharp factoryTy ++ "> " ++ pascal factoriesName ++ "()") <> D.hardline <>
              D.block 4 (renderBody CSharp (tFun [tSymbols] factoryTy) (Lambda [("symbols", tSymbols)] factoryTy made)) <>
              D.hardline <> D.hardline <> D.text ("/// <summary>The model " ++ machineName machine ++ ".</summary>") <> D.hardline <>
              D.text ("private static LawSpec.Testing.Model.Model " ++ pascal name ++ "() =>") <> D.nest 4 (D.hardline <>
                D.text (if machineActor machine then "LawSpec.Testing.Model.WithActors(LawSpec.Testing.ActorHost.Host, " ++ withContext ++ ");" else withContext ++ ";"))
      cases <- forM (Checks.checks unit) $ \check -> do
        let model n = if fs then "(" ++ n ++ " ())" else pascal n ++ "()"
        action <- case Checks.checkAction check of
          Checks.Sequential name _ -> pure (if fs then "Model.check " ++ model name else "LawSpec.Testing.Model.Check(" ++ model name ++ ");")
          Checks.Parallel name _ -> pure (if fs then "ModelParallel.check " ++ model name else "LawSpec.Testing.ModelParallel.Check(" ++ model name ++ ");")
          Checks.Scenario name _ program -> do
            wire <- scenarioWire bits datas (concatMap C.unitSessions units) program
            let text = P.programSpec (program { P.programWire = wire })
            pure (if fs then "Scenario.check " ++ model name ++ " " ++ stringLiteral FSharp text
              else "LawSpec.Testing.Scenario.Check(" ++ model name ++ ", " ++ stringLiteral CSharp text ++ ");")
          Checks.Supervision -> pure (if fs then "Supervision.check ()" else "LawSpec.Testing.Supervision.Check();")
        pure $ if fs
          then D.text ("[<Fact(DisplayName = " ++ stringLiteral FSharp (Checks.checkLabel check) ++ ")>]") <> D.hardline <>
            D.text ("let " ++ Checks.checkName check ++ " () : unit =") <> D.nest 4 (D.hardline <> D.text action)
          else D.text ("[Fact(DisplayName = " ++ stringLiteral CSharp (Checks.checkLabel check) ++ ")]") <> D.hardline <>
            D.text ("public void " ++ pascal (Checks.checkName check) ++ "() => " ++ action)
      let moduleName = testModule (C.unitId unit) ++ "Models"
          doc = if fs
            then D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
              D.text ("/// The models of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
              D.text "[<Xunit.Collection(\"LawSpec\")>]" <> D.hardline <>
              D.text ("module " ++ moduleName) <> D.hardline <> D.hardline <>
              D.text "open Xunit" <> D.hardline <> D.text "open LawSpec.Runtime" <> D.hardline <>
              D.text "open LawSpec.Testing" <> D.hardline <> D.hardline <>
              D.joinWith (D.hardline <> D.hardline) (prepared ++ cases) <> D.hardline
            else D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
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
