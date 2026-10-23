-- | Spec handlers as native classes, the embedding entry point for a
-- reference model: LawSpec.Handlers.<Unit>.<Handler> conforms to the native
-- protocol of every ability the handler answers, with a method per operation
-- (an operation that fails throws its failure, typed), and a stateful
-- handler's state in native types, to read, force, reset or restore. The
-- class runs the handler's checked clauses; when every clause is typed its
-- state is native and persistent, so a snapshot is shared, never copied.
-- ref:DEC-typed-native-definitions ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Handlers (emitHandlers) where

import qualified LawSpec.Core as C
import qualified LawSpec.AbilityNames as N
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..))
import LawSpec.Swift.Code
import LawSpec.SourceLink (generatedHeader, unitSourceFile, labelled, sourceLink)
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.Swift.Effects as Effects
import qualified LawSpec.Swift.Abilities as Abilities
import LawSpec.Typed.Swift (SwiftTyped(..))
import LawSpec.Typed.Plan (isTypedHandler)
import Control.Monad (forM)
import Data.List (intercalate)

-- | A type's documentation, wrapped to fit in its enum.
docComment :: String -> D.Doc
docComment = D.lineComment 96 "/// "

-- | One file per unit with spec handlers.
emitHandlers :: D.Layout -> Int -> SwiftTyped -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emitHandlers layout bits typed declarations units = do
  names <- dataNames declarations
  fmap concat $ forM [u | u <- units, not (null (owned u))] $ \u -> do
    classes <- forM (owned u) (handlerClass names)
    let unitName = concatMap pascal (splitDots (C.idText (C.unitId u)))
        doc = fileHeader (generatedHeader (unitSourceFile u)) [["import LawSpecRuntime"], ["import class Foundation.NSRecursiveLock"]] <> D.hardline <>
          D.text "extension LawSpec.Handlers {" <> D.nest 2 (D.hardline <>
            D.text ("/// The spec handlers of " ++ C.idText (C.unitId u) ++ ", as native classes.") <> D.hardline <>
            D.text ("public enum " ++ unitName ++ " {") <> D.nest 2 (D.hardline <> D.joinWith (D.hardline <> D.hardline) classes) <>
            D.hardline <> D.text "}") <> D.hardline <> D.text "}" <> D.hardline
    pure [Artifact ("src/LawSpec/Handlers/" ++ unitName ++ "Handlers.swift") (D.render layout doc) "generated" "source"]
  where
    -- A handler's class is in the unit whose generated enum makes it, once.
    owned u = [h | h <- C.unitHandlers u, fst (Effects.specFunction units h) == generatedName (C.unitId u)]
    handlerClass names h = do
      answered <- forM (C.handlerAbilities h) $ \ref ->
        maybe (Left ("unknown Swift ability of handler " ++ C.handlerName h)) Right (N.abilityOf units ref)
      let cls = pascal (N.specName h)
          (owner, factory) = Effects.specFunction units h
          protocols = [Effects.protocolType a | a <- answered]
          summary = labelled ("The spec handler " ++ C.handlerName h ++ " for " ++ intercalate ", " (map N.displayName answered)) (sourceLink (C.handlerOrigin h)) ++ "."
          stateful = C.handlerState h /= Nothing
      operations <- fmap concat $ forM answered $ \a -> forM (C.abilityOperations a) $ \(op, ty) -> do
        signature <- Abilities.operationSignature bits names a (op, ty)
        pure (a, op, ty, signature)
      stateCodec <- traverse (Data.codec bits names [] . fst) (C.handlerState h)
      stateType <- traverse (Data.nativeType bits names [] . fst) (C.handlerState h)
      let method op (ps, r, e) = signature ("public func " ++ Effects.operationMember op) ["_ " ++ p ++ ": " ++ t | (p, t) <- ps]
            (maybe "" (\x -> " throws(" ++ x ++ ")") e ++ (if r == "Void" then "" else " -> " ++ r))
          locked body = D.text "gate.lock()" <> D.hardline <> D.text "defer { gate.unlock() }" <> D.hardline <> body
          -- A value the runtime computes, outside any law.
          embedded ty x = renderExpr (Pure "Embedding.run" [Lambda [] (Ty ty) x])
          typedClauses = isTypedHandler (swiftTypedPlan typed) h
      if typedClauses then do
        clauses <- forM operations $ \(a, op, ty, signature@(ps, r, e)) -> do
          clause <- maybe (Left (C.handlerName h ++ ": no clause for " ++ op)) Right (lookup op (C.handlerClauses h))
          function <- maybe (Left ("untyped clause " ++ C.idText clause)) Right (swiftTypedFunction typed clause)
          failure <- case lookup op (C.abilityFailures a) of
            Just failing@(C.AbilityRef _ [failureType]) -> (\c -> Just (C.abilityKey failing, c)) <$> Data.codec bits names [] failureType
            _ -> pure Nothing
          let (args, _) = C.functionType ty
              restoreUnits [] [] = Right []
              restoreUnits (t : ts) ns
                | t == C.Constructor "Unit" [] = ("Unit()" :) <$> restoreUnits ts ns
                | n : rest <- ns = (n :) <$> restoreUnits ts rest
              restoreUnits _ _ = Left ("Swift handler parameter mismatch: " ++ C.handlerName h ++ "." ++ op)
          clauseArgs <- restoreUnits args (map fst ps)
          let contextual = swiftTypedContextual typed clause
              arguments = concat [["self.schema", "self.symbols"] | contextual] ++ ["self.stateValue" | stateful] ++
                (if null args && not stateful then ["Unit()"] else clauseArgs)
              invoke = Call function (map Raw arguments)
              void = r == "Void"
              resultTy = Ty (if void then "Void" else r)
              body = if stateful
                then Let "pair" (Ty "") invoke (Do [Statement (Raw "self.stateValue = pair.second")] (if void then Raw "()" else Raw "pair.first"))
                else invoke
              closure = Lambda [] resultTy body
              run = case (failure, e) of
                (Just (key, codec), Just _) -> Call "Embedding.inlineFailing" [Str key, Raw ("{ try " ++ codec ++ ".toNative($0) }"), closure]
                _ -> Pure "Embedding.inline" [closure]
          pure (D.text ("/// " ++ op ++ ".") <> D.hardline <> method op signature (locked
            (if void then renderStatements (Statement run) else renderBody resultTy run)))
        let start = case swiftTypedStart typed (C.handlerId h) of
              Just f -> embedded (maybe "Unit" id stateType) (Call f [Var "schema", Var "symbols"])
              Nothing -> D.text ("Embedding.run { () throws -> " ++ maybe "Unit" id stateType ++ " in throw Fail.with(\"NoStartState\") }")
            stateMembers = case stateType of
              Just t ->
                [ D.text ("private var stateValue: " ++ t)
                , D.text "/// The handler's state: a snapshot to show or keep, or one to force, reset or restore." <> D.hardline <>
                  D.text ("public var state: " ++ t) <> blockDoc (
                    D.text "get" <> blockDoc (locked (D.text "return stateValue")) <> D.hardline <>
                    D.text "set" <> blockDoc (locked (D.text "stateValue = newValue"))) ]
              Nothing -> []
            members =
              [ D.text "private let gate = NSRecursiveLock()", D.text "private let schema: Schema", D.text "private let symbols: SymbolContext" ] ++
              stateMembers ++
              [ D.text "/// Outside any law: the program's schema and fresh symbols." <> D.hardline <>
                D.text "public convenience init() { self.init(LawSpec.Program.schema, SymbolContext()) }"
              , D.text "public init(_ schema: Schema, _ symbols: SymbolContext)" <> blockDoc (
                  D.joinWith D.hardline (map D.text ["self.schema = schema", "self.symbols = symbols"] ++ [hangValue "self.stateValue =" start | stateful])) ] ++ clauses
        pure (docComment (summary ++ " It runs typed: its state is native, and shared, not copied, by a snapshot.") <>
          typeDeclaration ("public final class " ++ cls) (protocols ++ ["@unchecked Sendable"]) (D.joinWith (D.hardline <> D.hardline) members))
      else do
        let field a = camel (N.interfaceName a)
            members =
              [ D.text "/// The handler as the runtime runs it." <> D.hardline <> D.text "public let handler: Effects.Handler" ] ++
              [ D.text ("private let " ++ field a ++ ": any " ++ Effects.protocolType a) | a <- answered ] ++
              [ D.text "/// Outside any law: the program's schema and fresh symbols." <> D.hardline <>
                D.text "public convenience init() { self.init(LawSpec.Program.schema, SymbolContext()) }"
              , D.text "public init(_ schema: Schema, _ symbols: SymbolContext)" <> blockDoc (
                  hangValue "let made =" (embedded "Effects.Handler" (Call (owner ++ "." ++ factory) [Var "schema", Var "symbols"])) <> D.hardline <>
                  D.text "handler = made" <> D.hardline <>
                  D.joinWith D.hardline [ hangValue (field a ++ " =") (embedded ("any " ++ Effects.protocolType a)
                    (Call ("LawSpec.AbilityBridges." ++ Effects.bridgeName a "ToNative") [Var "schema", Var "symbols", Var "made"])) | a <- answered ]) ] ++
              [ D.text "/// The handler's state in native types: a snapshot to show or keep, or one to force, reset or restore." <> D.hardline <>
                D.text ("public var state: " ++ t) <> blockDoc (
                  D.text "get" <> blockDoc (embedded t (Call (c ++ ".toNative") [Raw ("Effects.handlerState(self." ++ field first ++ ").1")])) <> D.hardline <>
                  D.text "set" <> blockDoc (renderExpr (Pure "Embedding.run" [Lambda [] tVoid
                    (Statement (Call "Effects.setHandlerState" [Raw ("self." ++ field first), Call (c ++ ".fromNative") [Raw "newValue"]]))])))
              | Just c <- [stateCodec], Just t <- [stateType], first : _ <- [answered] ] ++
              [ D.text ("/// " ++ op ++ ".") <> D.hardline <> method op signature
                  (callDoc ((case e of Just _ -> "try "; Nothing -> "") ++ field a ++ "." ++ Effects.operationMember op) (map (D.text . fst) ps))
              | (a, op, _, signature@(ps, _, e)) <- operations ]
        pure (docComment (summary ++ " A new one starts from the handler's start state.") <>
          typeDeclaration ("public final class " ++ cls) (protocols ++ ["@unchecked Sendable"]) (D.joinWith (D.hardline <> D.hardline) members))
