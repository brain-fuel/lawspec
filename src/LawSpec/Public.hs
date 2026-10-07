-- | Versioned wire views. Field names and discriminators are selected explicitly;
-- no internal AST or IR datatype is serialized with genericToJSON.
module LawSpec.Public (programView, typeView, expressionView) where
import qualified LawSpec.Unification as U
import Data.Aeson
import Data.List (intercalate)
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation(..), statusName)
import qualified LawSpec.Model as S
import LawSpec.Common
import LawSpec.Scalar (prettyScalar)
import LawSpec.Backend (declarationName, prettyType)

type Names = [(C.Id,String)]

-- | The compiler API exposes types as JSON in one stable shape.
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

-- | Expressions are exposed with their types and origins, so tools can point at
-- source.
expressionView :: Names -> C.Expr -> Value
expressionView names e = object ["type" .= typeView (C.expressionType e),"origin" .= originView (C.expressionOrigin e),"text" .= expressionText names e,"node" .= node] where
  expr = expressionView names
  node = case C.expressionNode e of
    C.Constant v -> object ["kind" .= str "constant", "value" .= v]
    C.Construct tag args -> object ["kind" .= str "construct", "constructor" .= C.idText tag, "arguments" .= map expr args]
    C.Match value cases -> object ["kind" .= str "match", "value" .= expr value, "cases" .=
      [object ["constructor" .= C.idText (C.caseConstructor branch),
        "binders" .= map binderView (C.caseBinders branch),
        "body" .= expressionView ([(C.binderId b, C.binderName b) | b <- C.caseBinders branch] ++ names) (C.caseBody branch)]
        | branch <- cases]]
    C.AllElements value binder predicate -> object
      ["kind" .= str "allElements", "value" .= expr value, "binder" .= binderView binder,
       "predicate" .= expressionView ((C.binderId binder,C.binderName binder):names) predicate]
    C.AllPayloads value predicates -> object
      ["kind" .= str "allPayloads", "value" .= expr value, "predicates" .=
       [object ["binder" .= binderView binder,
         "predicate" .= expressionView ((C.binderId binder,C.binderName binder):names) predicate]
         | (binder,predicate) <- predicates]]
    C.Local n -> object ["kind" .= str "local", "id" .= C.idText n]
    C.ExternalCall n args -> object ["kind" .= str "call", "declaration" .= C.idText n, "arguments" .= map expr args]
    C.Binary op ev a b -> object ["kind" .= str "binary", "operator" .= C.binaryName op, "evidence" .= evidenceView ev, "left" .= expr a, "right" .= expr b]
    C.Unary op a -> object ["kind" .= str "unary", "operator" .= unary op, "argument" .= expr a]
    C.ShortCircuit op a b -> object ["kind" .= str "shortCircuit", "operator" .= logical op, "left" .= expr a, "right" .= expr b]
    C.If c a b -> object ["kind" .= str "if", "condition" .= expr c, "then" .= expr a, "else" .= expr b]
    C.Convert mode _ a -> object ["kind" .= str "convert", "conversion" .= (if mode == C.Explicit then str "explicit" else "checked"), "argument" .= expr a]
    C.Helper name args -> object ["kind" .= str "helper", "name" .= ("prelude." ++ C.builtinName name), "arguments" .= map expr args]
    C.Perform op args -> object ["kind" .= str "perform", "ability" .= C.abilityKey (C.operationAbility op), "operation" .= C.operationName op, "arguments" .= map expr args]
    C.Handle (C.CatchFailure ability) body -> object ["kind" .= str "handle", "handling" .= str "catchFailure", "ability" .= C.abilityKey ability, "body" .= expr body]
    C.Handle (C.WithHandler ability h) body -> object ["kind" .= str "handle", "handling" .= str "withHandler", "ability" .= C.abilityKey ability, "handler" .= handlerText h, "body" .= expr body]
    C.Let binder value body -> object ["kind" .= str "let", "binder" .= binderView binder, "value" .= expr value,
      "body" .= expressionView ((C.binderId binder, C.binderName binder) : names) body]
    C.Calls op args -> object ["kind" .= str "calls", "ability" .= C.abilityKey (C.operationAbility op), "operation" .= C.operationName op, "arguments" .= fmap (map expr) args]
handlerText :: C.HandlerRef -> String
handlerText h = case h of
  C.ProductionHandler -> "native"
  C.SpecHandler i -> reverse (takeWhile (/= ':') (reverse (C.idText i)))
  C.RecordingHandler inner -> "recording " ++ handlerText inner
unary :: C.UnaryOp -> String
unary C.Negate = "-"
unary C.Not = "!"
logical :: C.LogicalOp -> String
logical C.And = "&&"
logical C.Or = "||"
expressionText :: Names -> C.Expr -> String
expressionText names e = case C.expressionNode e of
  C.Constant v -> prettyScalar v
  C.Construct tag args -> unwords (C.idText tag : map ((\v -> "(" ++ go v ++ ")")) args)
  C.Match value cases -> "match (" ++ go value ++ ") { " ++ unwords
    [C.idText (C.caseConstructor branch) ++ " " ++ unwords (map C.binderName (C.caseBinders branch)) ++
     " -> " ++ expressionText ([(C.binderId b, C.binderName b) | b <- C.caseBinders branch] ++ names) (C.caseBody branch) ++ ";"
      | branch <- cases] ++ " }"
  C.AllElements value binder predicate -> "allElements (" ++ go value ++ ") (" ++ C.binderName binder ++
    " -> " ++ expressionText ((C.binderId binder,C.binderName binder):names) predicate ++ ")"
  C.AllPayloads value predicates -> "allPayloads (" ++ go value ++ ") [" ++ unwords
    [C.binderName binder ++ " -> " ++
      expressionText ((C.binderId binder,C.binderName binder):names) predicate ++ ";"
      | (binder,predicate) <- predicates] ++ "]"
  C.Local n -> maybe (C.idText n) id (lookup n names)
  C.ExternalCall n args -> unwords (declarationName n:map ((\v -> "(" ++ go v ++ ")")) args)
  C.Binary op _ a b -> "(" ++ go a ++ " " ++ C.binaryName op ++ " " ++ go b ++ ")"
  C.Unary op a -> unary op ++ "(" ++ go a ++ ")"
  C.ShortCircuit op a b -> "(" ++ go a ++ " " ++ logical op ++ " " ++ go b ++ ")"
  C.If c a b -> "(if " ++ go c ++ " then " ++ go a ++ " else " ++ go b ++ ")"
  C.Convert _ t a -> "(" ++ go a ++ " :: " ++ prettyType t ++ ")"
  C.Helper name args -> "prelude." ++ C.builtinName name ++ concatMap (\v -> " (" ++ go v ++ ")") args
  C.Perform op args -> unwords (C.operationName op : map ((\v -> "(" ++ go v ++ ")")) args)
  C.Handle (C.CatchFailure _) body -> "prelude.attempt (" ++ go body ++ ")"
  C.Handle (C.WithHandler _ h) body -> "handle " ++ go body ++ " with " ++ handlerText h ++ " end"
  C.Let binder value body -> "let " ++ C.binderName binder ++ " = " ++ go value ++ " in " ++
    expressionText ((C.binderId binder, C.binderName binder) : names) body
  C.Calls op args -> "calls of " ++ C.operationName op ++ maybe "" (\xs -> " with (" ++ intercalate ", " (map go xs) ++ ")") args
  where go = expressionText names

propositionView :: Names -> C.Proposition -> Value
propositionView names p = case p of
  C.Equation ev a b -> object ["kind" .= str "equal", "evidence" .= evidenceView ev, "left" .= expr a, "right" .= expr b]
  C.Implication g body -> object ["kind" .= str "implies", "guard" .= expr g, "body" .= propositionView names body]
  C.Conjunction ps -> object ["kind" .= str "all", "items" .= map (propositionView names) ps]
  where expr = expressionView names
binderView :: C.Binder -> Value
binderView b = object ["id" .= C.idText (C.binderId b), "name" .= C.binderName b, "type" .= typeView (C.binderType b)]

-- | The versioned JSON view of a checked program, the contract between the
-- compiler and the CLI, editor and site. ref:DEC-wasm-distribution
programView :: Generation -> [S.Unit] -> [String] -> [Artifact] -> [Obligation] -> C.Program -> Value
programView settings surface expansions artifacts evidence C.Program{..} = object
  [ "schemaVersion" .= (3 :: Int), "machineBits" .= programMachineBits, "generation" .= settings
  , "diagnostics" .= ([] :: [Diagnostic]), "units" .= map unitView programUnits
  , "dataTypes" .= map dataView programDataDeclarations
  , "definitions" .= [definitionView u d | u <- programUnits, d <- C.unitDefinitions u]
  , "laws" .= [propertyView (C.idText (C.unitId u)) p | u <- programUnits,p <- C.unitProperties u]
  , "contracts" .= [object ["owner" .= C.idText (C.unitId u),"contract" .= contractView c] | u <- programUnits,c <- C.unitContracts u]
  , "refinements" .= [refinementView u r | u <- surface,r <- S.refinements u]
  , "evidence" .= map evidenceView evidence
  , "expansions" .= expansions, "files" .= artifacts
  ]
  where
    definitionView u d = object
      [ "owner" .= C.idText (C.unitId u)
      , "id" .= C.idText (C.declarationId (C.definitionDeclaration d))
      , "arguments" .= map binderView (C.definitionArguments d)
      , "body" .= expressionView [(C.binderId b,C.binderName b) | b <- C.definitionArguments d] (C.definitionBody d)
      ]
    dataView declaration = object
      [ "id" .= C.idText (C.dataId declaration), "name" .= C.dataName declaration
      , "parameters" .= map C.idText (C.dataParameters declaration)
      , "origin" .= originView (C.dataOrigin declaration)
      , "constructors" .= [object
          [ "id" .= C.idText (C.constructorId constructor), "name" .= C.constructorName constructor
          , "fields" .= map binderView (C.constructorFields constructor)
          , "origin" .= originView (C.constructorOrigin constructor)
          ] | constructor <- C.dataConstructors declaration]
      ]
    unitView u = object (["id" .= C.idText (C.unitId u), "declarations" .= [object (["id" .= C.idText (C.declarationId d),"name" .= C.declarationName d,"type" .= typeView (C.declarationType d),"origin" .= originView (C.declarationOrigin d)] ++ ["async" .= True | C.declarationAsync d] ++
        -- Its ability row, declared or inferred.
        ["uses" .= declarationRow d | not (null (declarationRow d))]) | d <- C.unitDeclarations u]] ++
      -- What each existing effect-like construct uses, as abilities
      -- (LawSpec.Unification).
      ["abilityRows" .= [object ["construct" .= U.rowConstruct r, "name" .= U.rowName r, "uses" .= U.rowUses r
          , "handler" .= U.rowHandler r] | r <- U.abilityRows u] | not (null (U.abilityRows u))] ++
      ["abilities" .= [object ["id" .= C.idText (C.abilityId a), "name" .= C.abilityName a
          , "operations" .= [object ["name" .= op, "type" .= typeView t] | (op, t) <- C.abilityOperations a]
          , "origin" .= originView (C.abilityOrigin a)] | a <- C.unitAbilities u] | not (null (C.unitAbilities u))] ++
      ["handlers" .= [object ["id" .= C.idText (C.handlerId h), "name" .= C.handlerName h
          , "ability" .= C.abilityKey (C.handlerAbility h)
          , "clauses" .= [object ["operation" .= op, "definition" .= C.idText d] | (op, d) <- C.handlerClauses h]
          , "state" .= fmap (typeView . fst) (C.handlerState h)
          , "origin" .= originView (C.handlerOrigin h)] | h <- C.unitHandlers u] | not (null (C.unitHandlers u))])
    -- An async declaration uses Async, whose default handler is the
    -- target's native async (abilities-mapping.md).
    declarationRow d = [U.asyncAbility | C.declarationAsync d] ++ map C.abilityKey (C.declarationUses d)
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
        ,"location" .= C.propertyLocation p, "trace" .= C.propertyTrace p, "generation" .= C.propertyGeneration p
        -- The handler the law runs under for each ability it uses.
        ,"handlers" .= [object ["ability" .= C.abilityKey a, "handler" .= handlerText h] | (a, h) <- C.propertyHandlers p]
        -- How its tests run: the harness plane, apart from the law itself.
        ,"harness" .= harnessView names (C.propertyHarness p)]
    harnessView names h = object
      [ "unit" .= C.harnessUnit h, "tags" .= C.harnessTags h, "skip" .= C.harnessSkip h
      , "knownFailing" .= C.harnessKnownFailing h, "timeoutMilliseconds" .= C.harnessTimeout h
      , "repeat" .= C.harnessRepeat h, "retries" .= C.harnessRetries h
      , "cover" .= [object ["percent" .= percent, "label" .= label, "when" .= expressionView names e] | C.Cover percent label e <- C.harnessCover h]
      , "classify" .= [object ["label" .= label, "when" .= expressionView names e] | (e, label) <- C.harnessClassify h]
      , "labels" .= map (expressionView names) (C.harnessLabels h)
      , "target" .= fmap (expressionView names) (C.harnessTarget h)
      , "strategies" .= [object ["input" .= maybe (C.idText i) id (lookup i names), "strategy" .= n] | (i, n, _) <- C.harnessDraws h]
      , "group" .= C.harnessGroup h
      -- The unit's run settings: its tests in a random order, at the same time.
      , "orderRandom" .= or [C.harnessOrderRandom s | Just s <- [unitSettingsOf h]]
      , "parallel" .= or [C.harnessParallel s | Just s <- [unitSettingsOf h]] ]
    unitSettingsOf h = case [s | u <- programUnits, Just s <- [C.unitHarnessSettings u], Just (C.unitHarnessName s) == C.harnessUnit h] of
      s : _ -> Just s
      [] -> Nothing
    evidenceView o = object (
      [ "owner" .= C.idText (obligationUnit o), "declaration" .= C.idText (obligationDeclaration o)
      , "stage" .= obligationStage o, "status" .= statusName (obligationStatus o)
      , "reason" .= obligationReason o
      , "claim" .= fmap (expressionView (declarationBinders (obligationDeclaration o))) (obligationClaim o) ] ++
      -- A law's obligation comes from the law plane; how it is discharged,
      -- from the harness plane, which is reported beside it.
      [ "harness" .= harnessView (declarationBinders (obligationDeclaration o)) (C.propertyHarness p)
      | u <- programUnits, p <- C.unitProperties u, C.propertyId p == obligationDeclaration o
      , C.harnessUnit (C.propertyHarness p) /= Nothing ])
    declarationBinders declaration = concat
      [ [(C.binderId b,C.binderName b) | b <- C.contractArguments c ++ [C.contractResult c]]
      | u <- programUnits, c <- C.unitContracts u, C.contractDeclaration c == declaration ] ++ concat
      [ [(C.binderId b,C.binderName b) | b <- C.constructorFields c]
      | d <- programDataDeclarations, c <- C.dataConstructors d, C.constructorId c == declaration ] ++ concat
      [ [(C.binderId b,C.binderName b) | q <- C.propertyInputs p, let b = C.quantifiedBinder q]
      | u <- programUnits, p <- C.unitProperties u, C.propertyId p == declaration ]
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
      C.Construct tag fields -> object ["kind" .= str "data", "type" .= typeView (C.expressionType e), "constructor" .= C.idText tag, "fields" .= map constant fields]
      _ -> error "core validator must reject non-concrete example bindings"
