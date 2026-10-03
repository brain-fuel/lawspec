-- Closed execution of validated total definitions. The returned function has
-- no adapter hook, so a definition cannot acquire effects during evaluation.
module LawSpec.Core.Definitions (prepareDefinitions) where

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
prepareDefinitions program = do
  validateProgram program
  let boundaries = definitionContracts (programUnits program)
  registry <- either (Left . pure . (\message -> Diagnostic "core" message Nothing)) Right
    (makeRegistry (programDataDeclarations program))
  let bits = programMachineBits program
      -- Orchestrations call adapters and are run natively, never here.
      definitions = M.fromList [(declarationId (definitionDeclaration d), d)
        | u <- programUnits program, d <- unitDefinitions u, not (definitionOrchestrates d)]
      contracts = M.fromList [(contractDeclaration c,c) | c <- boundaries]
      invoke name values = do
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
                (evaluateValue registry bits invoke scope predicate)
              unless (value == ScalarValue (SBool True))
                (Left (idText name ++ ": " ++ stage ++ " failed"))
        -- Check in declaration order: a false guard must stop before a later
        -- predicate (or the body) that is only defined under that guard.
        mapM_ (\c -> mapM_ (require "precondition" (contractScope c)) (contractPreconditions c)) contract
        value <- evaluateValue registry bits invoke (zip (map binderId arguments) checked)
          (definitionBody definition) >>= validateValueWithContracts registry bits result
        mapM_ (\c -> mapM_ (require "postcondition"
          ((binderId (contractResult c),value) : contractScope c)) (contractPostconditions c ++ contractRuntimePostconditions c)) contract
        pure value
  pure invoke
