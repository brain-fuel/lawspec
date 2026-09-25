-- Versioned wire views. Field names and discriminators are selected explicitly;
-- no internal AST or IR datatype is serialized with genericToJSON.
module LawSpec.Public (programView, typeView, expressionView) where
import Data.Aeson
import qualified LawSpec.Core as C
import qualified LawSpec.Model as S
import LawSpec.Common
import LawSpec.Scalar (prettyScalar)
import LawSpec.Backend (declarationName, prettyType)

type Names = [(C.Id,String)]

typeView :: C.Type -> Value
typeView (C.Constructor name args) = object ["kind" .= str "constructor", "name" .= name, "arguments" .= map argument args] where
  argument (C.TypeArgument t) = object ["kind" .= str "type", "type" .= typeView t]
  argument (C.IndexArgument (C.Natural n)) = object ["kind" .= str "natural", "value" .= show n]
  argument (C.IndexArgument (C.IndexVariable n)) = object ["kind" .= str "indexVariable", "id" .= C.idText n]
typeView (C.TypeVariable n) = object ["kind" .= str "variable", "id" .= C.idText n]
typeView (C.Arrow a b) = object ["kind" .= str "function", "parameter" .= typeView a, "result" .= typeView b]
str :: String -> String
str = id

originView :: C.Origin -> Value
originView (C.SourceSpan range) = object ["kind" .= str "source", "span" .= object ["start" .= spanStart range,"end" .= spanEnd range]]
originView (C.GeneratedFrom n) = object ["kind" .= str "generated", "declaration" .= C.idText n]
evidenceView :: C.Evidence -> Value
evidenceView evidence = case evidence of
  C.Numeric t -> object ["kind" .= str "numeric", "type" .= typeView t]
  C.Structural t -> object ["kind" .= str "structural", "type" .= typeView t]

expressionView :: Names -> C.Expr -> Value
expressionView names e = object ["type" .= typeView (C.expressionType e),"origin" .= originView (C.expressionOrigin e),"text" .= expressionText names e,"node" .= node] where
  expr = expressionView names
  node = case C.expressionNode e of
    C.Constant v -> object ["kind" .= str "constant", "value" .= v]
    C.Local n -> object ["kind" .= str "local", "id" .= C.idText n]
    C.ExternalCall n args -> object ["kind" .= str "call", "declaration" .= C.idText n, "arguments" .= map expr args]
    C.Binary op ev a b -> object ["kind" .= str "binary", "operator" .= C.binaryName op, "evidence" .= evidenceView ev, "left" .= expr a, "right" .= expr b]
    C.Unary op a -> object ["kind" .= str "unary", "operator" .= unary op, "argument" .= expr a]
    C.ShortCircuit op a b -> object ["kind" .= str "shortCircuit", "operator" .= logical op, "left" .= expr a, "right" .= expr b]
    C.Convert mode _ a -> object ["kind" .= str "convert", "conversion" .= (if mode == C.Explicit then str "explicit" else "checked"), "argument" .= expr a]
    C.Helper name args -> object ["kind" .= str "helper", "name" .= ("prelude." ++ C.builtinName name), "arguments" .= map expr args]
unary :: C.UnaryOp -> String
unary C.Negate = "-"
unary C.Not = "!"
logical :: C.LogicalOp -> String
logical C.And = "&&"
logical C.Or = "||"
expressionText :: Names -> C.Expr -> String
expressionText names e = case C.expressionNode e of
  C.Constant v -> prettyScalar v
  C.Local n -> maybe (C.idText n) id (lookup n names)
  C.ExternalCall n args -> unwords (declarationName n:map ((\v -> "(" ++ go v ++ ")")) args)
  C.Binary op _ a b -> "(" ++ go a ++ " " ++ C.binaryName op ++ " " ++ go b ++ ")"
  C.Unary op a -> unary op ++ "(" ++ go a ++ ")"
  C.ShortCircuit op a b -> "(" ++ go a ++ " " ++ logical op ++ " " ++ go b ++ ")"
  C.Convert _ t a -> "(" ++ go a ++ " :: " ++ prettyType t ++ ")"
  C.Helper name args -> "prelude." ++ C.builtinName name ++ concatMap (\v -> " (" ++ go v ++ ")") args
  where go = expressionText names

propositionView :: Names -> C.Proposition -> Value
propositionView names p = case p of
  C.Equation ev a b -> object ["kind" .= str "equal", "evidence" .= evidenceView ev, "left" .= expr a, "right" .= expr b]
  C.Implication g body -> object ["kind" .= str "implies", "guard" .= expr g, "body" .= propositionView names body]
  C.Conjunction ps -> object ["kind" .= str "all", "items" .= map (propositionView names) ps]
  where expr = expressionView names
binderView :: C.Binder -> Value
binderView b = object ["id" .= C.idText (C.binderId b), "name" .= C.binderName b, "type" .= typeView (C.binderType b)]

programView :: Generation -> [S.Unit] -> [String] -> [Artifact] -> C.Program -> Value
programView settings surface expansions artifacts C.Program{..} = object
  [ "schemaVersion" .= (3 :: Int), "machineBits" .= programMachineBits, "generation" .= settings
  , "diagnostics" .= ([] :: [Diagnostic]), "units" .= map unitView programUnits
  , "laws" .= [propertyView (C.idText (C.unitId u)) p | u <- programUnits,p <- C.unitProperties u]
  , "contracts" .= [object ["owner" .= C.idText (C.unitId u),"contract" .= contractView c] | u <- programUnits,c <- C.unitContracts u]
  , "refinements" .= [refinementView u r | u <- surface,r <- S.refinements u]
  , "expansions" .= expansions, "files" .= artifacts
  ]
  where
    unitView u = object ["id" .= C.idText (C.unitId u), "declarations" .= [object ["id" .= C.idText (C.declarationId d),"name" .= C.declarationName d,"type" .= typeView (C.declarationType d),"origin" .= originView (C.declarationOrigin d)] | d <- C.unitDeclarations u]]
    propertyView owner p =
      let names = [(C.binderId b,C.binderName b) | q <- C.propertyInputs p, let b = C.quantifiedBinder q]
          expr = expressionView names
          input q = let b = C.quantifiedBinder q in object
            ["id" .= C.idText (C.binderId b), "name" .= C.binderName b, "type" .= typeView (C.binderType b)
            ,"predicates" .= map expr (C.quantifiedPredicates q)
            ,"bounds" .= [object ["operator" .= C.binaryName op,"value" .= expr e] | (op,e) <- C.quantifiedBounds q]]
          example e = object
            ["name" .= C.exampleName e
            ,"bindings" .= [object ["id" .= C.idText n,"name" .= maybe (C.idText n) id (lookup n names),"type" .= typeView (C.expressionType v),"value" .= constant v] | (n,v) <- C.exampleBindings e]
            ,"expectations" .= map (propositionView names) (C.exampleExpectations e)]
      in object ["id" .= C.idText (C.propertyId p), "owner" .= owner,"name" .= C.propertyName p
        ,"inputs" .= map input (C.propertyInputs p), "assertion" .= propositionView names (C.propertyBody p)
        ,"examples" .= map example (C.propertyExamples p), "description" .= C.propertyDescription p
        ,"rationale" .= C.propertyRationale p, "references" .= C.propertyReferences p
        ,"location" .= C.propertyLocation p, "trace" .= C.propertyTrace p, "generation" .= C.propertyGeneration p]
    contractView c = let names = [(C.binderId b,C.binderName b) | b <- C.contractArguments c ++ [C.contractResult c]] in object
      ["id" .= C.idText (C.contractDeclaration c),"name" .= declarationName (C.contractDeclaration c)
      ,"arguments" .= map binderView (C.contractArguments c),"result" .= binderView (C.contractResult c)
      ,"preconditions" .= map (expressionView names) (C.contractPreconditions c)
      ,"postconditions" .= map (expressionView names) (C.contractPostconditions c)]
    refinementView u r = object ["owner" .= S.unitName u,"name" .= S.refinementName r
      ,"parameters" .= [object ["name" .= n,"kind" .= (if t == S.Named "Type" then str "type" else "value"),"type" .= S.prettyType t] | (n,t) <- S.refinementParameters r]
      ,"requirements" .= [object ["capability" .= n,"type" .= S.prettyType t] | S.Capability n t <- S.refinementRequirements r]
      ,"definition" .= S.prettyType (S.refinementBody r)]
    constant e = case C.expressionNode e of
      C.Constant v -> toJSON v
      _ -> error "core validator must reject non-concrete example bindings"
