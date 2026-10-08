-- | Checked BEAM definitions are reusable production code. Tests and native
-- entry points call the same implementations and cross the same schema bridge.
-- ref:DEC-total-definitions ref:DEC-native-bindings-typed-identity
module LawSpec.BeamDefinitions
  ( emitDefinitions, external, declarationSpec, adapterModule ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import LawSpec.Core.DefinitionContracts (checkedDefinitionContracts)
import LawSpec.Core.Evidence (runtimePostconditions)
import LawSpec.Common (Artifact(..))
import Control.Monad (forM)

entries :: [C.Unit] -> [(C.Id,String)]
entries units = [(C.declarationId d,"evaluate_" ++ show i)
  | (i,d) <- zip [0::Int ..] (concatMap C.unitDeclarations units)]

adapterModule :: C.Unit -> String
adapterModule = E.moduleName . C.unitId

external :: [C.Unit] -> D.Doc -> D.Doc -> C.Expr -> [D.Doc] -> Either String D.Doc
external units schema symbols expression args = case C.expressionNode expression of
  C.ExternalCall identity _ -> maybe (Left ("unresolved BEAM call: " ++ C.idText identity))
    (\name -> pure (E.remote "lawspec_definitions" name (schema : symbols : args))) (lookup identity (entries units))
  _ -> Left "BEAM ability handlers are not implemented yet"

declarationSpec :: Int -> [(C.Id,String)] -> C.Declaration -> Either String D.Doc
declarationSpec bits names declaration = do
  let (arguments,result) = C.functionType (C.declarationType declaration)
  parameters <- mapM (E.nativeType bits names []) arguments
  returns <- E.nativeType bits names [] result
  pure (D.group (D.text "-spec " <> E.call (E.functionName declaration) parameters <>
    D.text " ->" <> D.nest 4 (D.softline <> returns) <> D.text "."))

emitDefinitions :: D.Layout -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitDefinitions layout bits declarations units = do
  verified <- checkedDefinitionContracts bits declarations units
  names <- E.dataNames declarations
  bodies <- mapM (implementation verified) [(u,d) | u <- units, d <- C.unitDeclarations u]
  wrappers <- mapM (nativeUnit names) [u | u <- units, not (null (C.unitDefinitions u))]
  let exports = [(name,2 + length (fst (C.functionType (C.declarationType d))))
        | u <- units, d <- C.unitDeclarations u, Just name <- [lookup (C.declarationId d) callees]]
  pure (file "lawspec_definitions" exports bodies : wrappers)
  where
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    callees = entries units
    definitions = [(C.declarationId (C.definitionDeclaration d),d) | u <- units, d <- C.unitDefinitions u]
    file name exports body = Artifact ("src/" ++ name ++ ".erl")
      (D.render layout (E.moduleDoc name exports body)) "generated" "source"
    bridge method ty value = do
      ref <- E.typeReference ty
      pure (E.remote "lawspec_beam_schema" method [value,ref,schema])
    implementation verified (unit,declaration) = do
      let identity = C.declarationId declaration
          (parameterTypes,resultType) = C.functionType (C.declarationType declaration)
          arguments = ["_LsArgument" ++ show i | (i,_) <- zip [0::Int ..] parameterTypes]
          definition = lookup identity definitions
          locals = maybe [] (\d -> zip (map C.binderId (C.definitionArguments d)) arguments) definition
          resolve table variable = maybe (error ("unbound BEAM binder: " ++ C.idText variable)) id (lookup variable table)
          render table = Expr.renderExpression bits schema symbols (resolve table) (external units schema symbols)
      body <- case definition of
        Just d -> render locals (C.definitionBody d)
        Nothing -> do
          nativeArguments <- sequence [bridge "to_native" ty (D.text arg) | (ty,arg) <- zip parameterTypes arguments]
          bridge "from_native" resultType (E.remote (adapterModule unit) (E.functionName declaration) nativeArguments)
      let candidates = case definition of Just _ -> verified; Nothing -> C.unitContracts unit
          contracts = [c | c <- candidates, C.contractDeclaration c == identity]
      pre <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments
        mapM (require (render aliases) "precondition") (C.contractPreconditions c)
      post <- fmap concat $ forM contracts $ \c -> do
        let aliases = zip (map C.binderId (C.contractArguments c)) arguments ++
              [(C.binderId (C.contractResult c),"_LsResult")]
        mapM (require (render aliases) "postcondition")
          (case definition of Just _ -> runtimePostconditions c; Nothing -> C.contractPostconditions c ++ C.contractRuntimePostconditions c)
      name <- maybe (Left "missing BEAM declaration entry") Right (lookup identity callees)
      pure (E.function name (schema : symbols : map D.text arguments)
        [E.remote "lawspec_beam_runtime" "contextual" [E.binary (C.idText identity),E.lambda []
          (E.sequenceDoc (pre ++ [D.text "_LsResult = " <> body] ++ post ++ [D.text "_LsResult"]))]])
    require render label predicate = do
      body <- render predicate
      pure (E.remote "lawspec_beam_runtime" "require" [body,E.binary label])
    nativeUnit names unit = do
      functions <- fmap concat $ forM (C.unitDefinitions unit) $ \definition -> do
        let d = C.definitionDeclaration definition
            (parameterTypes,resultType) = C.functionType (C.declarationType d)
            arguments = [D.text ("_LsNative" ++ show i) | (i,_) <- zip [0::Int ..] parameterTypes]
        signature <- declarationSpec bits names d
        converted <- sequence [bridge "from_native" ty arg | (ty,arg) <- zip parameterTypes arguments]
        name <- maybe (Left "missing BEAM definition entry") Right (lookup (C.declarationId d) callees)
        result <- bridge "to_native" resultType (E.remote "lawspec_definitions" name (schema : symbols : converted))
        pure [signature,E.function (E.functionName d) arguments
          [D.text "_LsSymbols = make_ref()",D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [symbols],result]]
      let name = adapterModule unit ++ "_definitions"
          exports = [(E.functionName d,length (fst (C.functionType (C.declarationType d))))
            | definition <- C.unitDefinitions unit, let d = C.definitionDeclaration definition]
      pure (file name exports functions)
