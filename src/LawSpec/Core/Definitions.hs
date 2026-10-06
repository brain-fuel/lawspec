-- Closed execution of validated total definitions. The returned function has
-- no adapter hook, so a definition cannot acquire effects during evaluation.
module LawSpec.Core.Definitions (prepareDefinitions, prepareResolvingDefinitions, prepareHookedDefinitions) where

import Control.Monad (unless)
import qualified Data.Map.Strict as M
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.Eval (evaluateValue, validateValueWithContracts)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.DefinitionContracts (definitionContracts)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Core.Value (Value(..))

prepareDefinitions :: Program -> Either [Diagnostic] (Id -> [Value] -> Either String Value)
prepareDefinitions program = ($ const Nothing) <$> prepareResolvingDefinitions program

-- With a resolver for ability operations: an operation it maps to a clause
-- definition is evaluated as a call of that clause, at any depth.
prepareResolvingDefinitions :: Program -> Either [Diagnostic] ((Id -> Maybe Id) -> Id -> [Value] -> Either String Value)
prepareResolvingDefinitions program = do
  hooked <- prepareHookedDefinitions program
  pure (\resolver -> hooked (\invoke name -> case resolver name of
    Just clause -> Just (\values -> invoke clause (if null values then [ScalarValue (SAbsent "Unit")] else values))
    Nothing -> Nothing))

-- With a hook that may answer a call itself, given the evaluator (a spec
-- handler with state answers its operations this way: LawSpec.Discharge).
prepareHookedDefinitions :: Program -> Either [Diagnostic]
  (((Id -> [Value] -> Either String Value) -> Id -> Maybe ([Value] -> Either String Value)) -> Id -> [Value] -> Either String Value)
prepareHookedDefinitions program = do
  validateProgram program
  let boundaries = definitionContracts (programUnits program)
  registry <- either (Left . pure . (\message -> Diagnostic "core" message Nothing)) Right
    (makeRegistry (programDataDeclarations program))
  let bits = programMachineBits program
      -- Orchestrations call adapters and are run natively, never here.
      definitions = M.fromList [(declarationId (definitionDeclaration d), d)
        | u <- programUnits program, d <- unitDefinitions u, not (definitionOrchestrates d)]
      contracts = M.fromList [(contractDeclaration c,c) | c <- boundaries]
      invoke resolver name values = case resolver (invoke resolver) name of
       Just answer -> answer values
       Nothing -> do
        definition <- maybe (Left ("unknown total definition: " ++ idText name)) Right
          (M.lookup name definitions)
        let arguments = definitionArguments definition
            (_, result) = functionType (declarationType (definitionDeclaration definition))
        unless (length arguments == length values)
          (Left (idText name ++ ": definition argument count mismatch"))
        checked <- sequence [validateValueWithContracts registry bits (binderType b) value
          | (b, value) <- zip arguments values]
        let contract = M.lookup name contracts
            contractScope c = zip (map binderId (contractArguments c)) checked
            require stage scope predicate = do
              value <- either (Left . ((idText name ++ ": " ++ stage ++ ": ") ++)) Right
                (evaluateValue registry bits (invoke resolver) scope predicate)
              unless (value == ScalarValue (SBool True))
                (Left (idText name ++ ": " ++ stage ++ " failed"))
        -- Check in declaration order: a false guard must stop before a later
        -- predicate (or the body) that is only defined under that guard.
        mapM_ (\c -> mapM_ (require "precondition" (contractScope c)) (contractPreconditions c)) contract
        value <- evaluateValue registry bits (invoke resolver) (zip (map binderId arguments) checked)
          (definitionBody definition) >>= validateValueWithContracts registry bits result
        mapM_ (\c -> mapM_ (require "postcondition"
          ((binderId (contractResult c),value) : contractScope c)) (contractPostconditions c ++ contractRuntimePostconditions c)) contract
        pure value
  pure invoke
