-- | Typed Swift for checked definitions (see LawSpec.Typed.Plan), in
-- src/LawSpec/TypedProgram.swift, the enum LawSpec.TypedProgram: a function
-- per class of typed definitions over the program's native Swift types, the
-- same structs, enums, arrays, optionals, SortedMap and SortedSet the
-- adapters and the embedding API use, so a typed definition converts
-- nothing, at its boundary or within. Bounded integers are Swift's own,
-- checked (LawSpecRuntime's Typed), Integer is BigInt, Text is a String by
-- code point. A definition that performs an operation takes the handler
-- context (the schema whose scope holds the handlers, and the symbols)
-- first; raise and attempt throw and catch the dynamic code's RaisedFailure.
-- Swift does not promise tail calls, so a self-recursive call in tail
-- position is a loop. Names are stable: each function is named for its
-- definition and a digest of its identity.
-- ref:DEC-typed-native-definitions ref:DEC-swift-runtime-from-scratch
module LawSpec.Typed.Swift (SwiftTyped(..), emitSwiftTyped, swiftTypedDeclarations) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.AbilityNames as N
import qualified LawSpec.Code.Doc as D
import LawSpec.Swift.Code (stringLiteral, swiftLayout, intLiteral, signature, callDoc, arrayDoc, sourceDoc)
import qualified LawSpec.Naming as Nm
import LawSpec.RecordNames (recordDisplayNames)
import LawSpec.SourceLink (generatedHeader)
import LawSpec.Swift.Names (dataNames, escape, localName, pascal, splitDigest)
import Data.Char (isHexDigit)
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.Swift.Effects as Effects

data SwiftTyped = SwiftTyped
  { swiftTypedSource :: Maybe String
    -- The typed function of a typed definition, qualified.
  , swiftTypedFunction :: Id -> Maybe String
    -- Whether a typed definition takes the handler context.
  , swiftTypedContextual :: Id -> Bool
    -- The function giving a typed handler's start state, qualified.
  , swiftTypedStart :: Id -> Maybe String
  , swiftTypedPlan :: TypedPlan
  }

-- | The declarations whose native Swift type is their typed form: not a type
-- the runtime gives a Swift type of its own (Duration), nor one bound to an
-- application's type.
swiftTypedDeclarations :: [Id] -> [DataDeclaration] -> [DataDeclaration]
swiftTypedDeclarations bound declarations =
  [ d | d <- declarations, idText (dataId d) /= "lawspec.time::type::Duration", dataId d `notElem` bound ]

data Env = Env
  { envPlan :: TypedPlan
  , envBits :: Int
  , envNames :: Data.Names
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envUnits :: [Unit]
  , envDeclarations :: [DataDeclaration]
  -- The function being emitted: its class and its parameters' names, for
  -- self calls in tail position, which become a loop.
  , envSelf :: Maybe (Int, [String])
  -- The names a function's locals may not take: the enum's functions and
  -- the handler context.
  , envBase :: Nm.Scope
  }

-- | The names taken in the function being emitted, and the parameters a
-- self tail call has reassigned in it (they become vars).
type M = StateT (Nm.Scope, [String]) (Either String)

lift' :: Either String a -> M a
lift' = lift

-- | A local's name: its source name, or what it holds, with _2 on a clash.
fresh :: String -> M String
fresh base = do
  (scope, assigned) <- get
  let (name, scope') = Nm.claim scope (localName base)
  put (scope', assigned)
  pure name

emitSwiftTyped :: Int -> [Id] -> [DataDeclaration] -> [Unit] -> Either String SwiftTyped
emitSwiftTyped bits bound allDeclarations units = do
  let declarations = swiftTypedDeclarations bound allDeclarations
      plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      -- Each function is named for its definition (a specialised copy for
      -- its definition and argument types), with _2 only on a clash.
      (functionNames, moduleScope) = Nm.claimAll (Nm.scopeWith ["schema", "symbols"])
        ([ functionName d | (_, d) <- typedRepresentatives plan ] ++
         [ "start" ++ pascal (handlerName h) | h <- typedHandlers, Just _ <- [handlerState h] ])
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
      starts = [ (handlerId h, name, ty, start)
               | (h, name) <- zip [h | h <- typedHandlers, Just _ <- [handlerState h]] (drop (length (typedRepresentatives plan)) functionNames)
               , Just (ty, start) <- [handlerState h] ]
  names <- dataNames allDeclarations
  let env = Env plan bits names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions units allDeclarations Nothing moduleScope
  docs <- flip evalStateT (moduleScope, []) $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      t <- lift' (nativeType env ty)
      modify (\(_, _) -> (moduleScope, []))
      body <- statements env [] (Just t) Return start
      pure (D.text "/// A typed handler's start state." <> D.hardline <>
        signature ("static func " ++ name) ["_ schema: Schema", "_ symbols: SymbolContext"] (" throws -> " ++ t) (D.joinWith D.hardline body))
    pure (fs ++ ss)
  let header = D.joinWith D.hardline (map D.text
        [ "// " ++ generatedHeader Nothing
        , "// Typed checked definitions over the program's native types (see"
        , "// docs/how-to/targets/swift.md). Each is named for its definition."
        , ""
        , "import LawSpecRuntime"
        , ""
        , "extension LawSpec {"
        , "  /// The program's typed definitions, on native values."
        , "  enum TypedProgram {" ])
      source = D.render swiftLayout (header <> D.nest 4 (D.hardline <> D.joinWith (D.hardline <> D.hardline) docs) <> D.hardline <>
        D.text "  }" <> D.hardline <> D.text "}") ++ "\n"
  pure SwiftTyped
    { swiftTypedSource = if null docs then Nothing else Just source
    , swiftTypedFunction = \i -> ("LawSpec.TypedProgram." ++) <$> (definitionClass plan i >>= (`M.lookup` functions))
    , swiftTypedContextual = isContextual plan
    , swiftTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just ("LawSpec.TypedProgram." ++ n)
        [] -> Nothing
    , swiftTypedPlan = plan }
  where
    functionName d = let declaration = definitionDeclaration d in
      escape (Nm.cased Nm.Camel (case concatMap shown (dropMade (concatMap splitDigest (Nm.nameWords (Nm.readableDefinitionName (declarationName declaration)
          (map displayed (fst (functionType (declarationType declaration)))))))) of
        [] -> ["definition"]
        ws -> ws))
    -- A digest in a compiler-made name (lawspecRecordView<digest>) reads
    -- as its record's display name.
    shown w = case M.lookup (Id ("lawspec::structural::record::" ++ w)) display of
      Just n | length w >= 16 -> Nm.nameWords n
      _ | length w >= 16, all isHexDigit w -> ["record"]
      _ -> [w]
    dropMade ws = case ws of
      "lawspec" : rest@(_ : _) -> rest
      _ -> ws
    -- An anonymous record reads by its display name (LawSpec.RecordNames).
    display = recordDisplayNames allDeclarations
    displayed ty = case ty of
      Constructor n args -> Constructor (M.findWithDefault n (Id n) display) [case a of TypeArgument t -> TypeArgument (displayed t); _ -> a | a <- args]
      Arrow a b -> Arrow (displayed a) (displayed b)
      _ -> ty

block :: [D.Doc] -> D.Doc
block body = D.nest 2 (D.hardline <> D.joinWith D.hardline body)

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

-- | A condition without the parentheses swift-format drops around one.
condition :: D.Doc -> D.Doc
condition x = case D.render D.Compact x of
  '(' : rest | not (null rest), last rest == ')', closesAtEnd (init rest) -> D.text (init rest)
  _ -> x
  where
    -- The opening parenthesis is closed only by the last one.
    closesAtEnd = go (0 :: Int)
      where
        go depth (c : cs)
          | c == '(' = go (depth + 1) cs
          | c == ')' = depth > 0 && go (depth - 1) cs
          | c == '"' = go depth (skipString cs)
          | otherwise = go depth cs
        go depth [] = depth == 0
        skipString ('\\' : _ : cs) = skipString cs
        skipString ('"' : cs) = cs
        skipString (_ : cs) = skipString cs
        skipString [] = []

type Scope = [(Id, String)]

nativeType :: Env -> Type -> Either String String
nativeType env = Data.nativeType (envBits env) (envNames env) []

-- | Where a block's value goes: returned, or assigned to a constant.
data Sink = Return | Assign String

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (args, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  modify (\(_, _) -> (envBase env, []))
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  types <- lift' (mapM (nativeType env) args)
  resultType <- lift' (nativeType env result)
  let self = Just (c, map snd params)
      selfEnv = env { envSelf = self }
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure [D.text "return " <> x]
    Nothing -> statements selfEnv params (Just resultType) Return (definitionBody d)
  assigned <- gets snd
  let looped = loops body
      reassigned = [l | (_, l) <- params, l `elem` assigned]
      parameters = concat [["_ schema: Schema", "_ symbols: SymbolContext"] | contextual] ++
        ["_ " ++ l ++ ": " ++ t | ((_, l), t) <- zip params types]
      bodyDoc = if looped
        then [D.text ("var " ++ l ++ " = " ++ l) | l <- reassigned] ++
             [D.text "while true {" <> block body <> D.hardline <> D.text "}"]
        else body
  pure (sourceDoc (idText (declarationId declaration)) (declarationOrigin declaration) <>
    signature ("static func " ++ name) parameters (" throws -> " ++ resultType) (D.joinWith D.hardline bodyDoc))
  where
    loops docs = any (\doc -> "continue" `elem` words (D.render D.Compact doc)) docs

-- | Lines that compute an expression into a sink.
statements :: Env -> Scope -> Maybe String -> Sink -> Expr -> M [D.Doc]
statements env scope resultType sink e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    if binderId binder `elem` freeBinders body
      then do
        local <- fresh (binderName binder)
        rest <- statements env ((binderId binder, local) : scope) resultType sink body
        pure (s ++ [D.text ("let " ++ local ++ " = ") <> x] ++ rest)
      else do
        rest <- statements env scope resultType sink body
        pure (s ++ discard value x ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- statements env scope resultType sink a
    no <- statements env scope resultType sink b
    pure (s ++ [D.text "if " <> condition x <> D.text " {" <> block yes <> D.hardline <> D.text "} else {" <> block no <> D.hardline <> D.text "}"])
  Helper Select [c, a, b] -> statements env scope resultType sink (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope resultType sink value cases
  ExternalCall i args
    | Return <- sink, Just (c, params) <- envSelf env, Just c' <- definitionClass (envPlan env) i, c == c'
    , M.notMember i (typedIntrinsics (envPlan env)), not (isContextual (envPlan env) i) -> do
        -- A self call in tail position: the next round of the loop.
        parts <- mapM (cexpr env scope) args
        let changed = [(p, x) | (p, (_, x)) <- zip params parts, D.render D.Compact x /= p]
            assignment = case changed of
              [] -> []
              [(p, x)] -> [D.text (p ++ " = ") <> x]
              _ -> [D.text ("(" ++ intercalate ", " (map fst changed) ++ ") = (") <> D.joinWith (D.text ", ") (map snd changed) <> D.text ")"]
        modify (\(n, assigned) -> (n, map fst changed ++ assigned))
        pure (concatMap fst parts ++ assignment ++ [D.text "continue"])
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [finish x])
  where
    finish x = case sink of
      Return -> D.text "return " <> x
      Assign name -> D.text (name ++ " = ") <> x
    -- A value computed for its effects only.
    discard value x = case expressionNode value of
      Local _ -> []
      Constant _ -> []
      _ -> [D.text "_ = " <> x]

-- | An expression's value: the lines that compute it, and an atom.
cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> constant env (expressionType e) s
  Local i -> do
    name <- lift' (maybe (Left ("typed Swift: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], D.text name)
  -- A list of items is an array literal.
  Construct tag _ | idText tag == "List::Cons", Just items <- listItems e -> do
    parts <- mapM (cexpr env scope) items
    typeText <- lift' (nativeType env (expressionType e))
    pure (concatMap fst parts, D.text typeText <> D.text "(" <> arrayDoc (map snd parts) <> D.text ")")
  Construct tag args -> do
    parts <- mapM (cexpr env scope) args
    x <- construct env (expressionType e) tag (map snd parts)
    pure (concatMap fst parts, x)
  ExternalCall i args
    | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
        parts <- mapM (cexpr env scope) args
        x <- intrinsicCall env intrinsic (zip (map snd parts) (map expressionType args))
        bindAtom (concatMap fst parts) x
    | otherwise -> do
        c <- lift' (maybe (Left ("typed Swift: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = concat [[D.text "schema", D.text "symbols"] | isContextual (envPlan env) i]
            invocation = callDoc ("try " ++ envFunctions env M.! c) (context ++ map snd parts)
        bindAtom (concatMap fst parts) invocation
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, paren (xa <> D.text (if op == And then " && " else " || ") <> xb))
      else do
        t <- fresh "logic"
        let rest = sb ++ [D.text (t ++ " = ") <> xb]
        pure (sa ++ [D.text ("let " ++ t ++ ": Bool"), D.text "if " <> condition xa <> D.text " {" <>
          (if op == And then block rest <> D.hardline <> D.text "} else {" <> block [D.text (t ++ " = false")]
           else block [D.text (t ++ " = true")] <> D.hardline <> D.text "} else {" <> block rest) <> D.hardline <> D.text "}"], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "!" <> x)
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    narrow (expressionType e) (s, D.text "(-" <> exact (expressionType a) x <> D.text ")")
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let equal = callDoc "Typed.equal" [xa, xb]
    pure (sa ++ sb, if op == Equal then equal else D.text "!" <> equal)
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let ta = expressionType a
        tb = expressionType b
        te = expressionType e
        same = ta == tb
        bounded = case ta of Constructor n [] -> n `elem` boundedTypes; _ -> False
        ia = exact ta xa
        ib = exact tb xb
        compare' symbol = pure (sa ++ sb, if same then paren (xa <> D.text symbol <> xb) else paren (ia <> D.text symbol <> ib))
        native f = bindAtom (sa ++ sb) (callDoc ("try Typed." ++ f) [D.text (stringLiteral (typeName ta)), xa, xb])
        arithmetic r = narrow te (sa ++ sb, r)
        sameNative = same && te == ta && bounded
    case op of
      Add | sameNative -> native "add"
          | otherwise -> arithmetic (paren (ia <> D.text " + " <> ib))
      Subtract | sameNative -> native "subtract"
               | otherwise -> arithmetic (paren (ia <> D.text " - " <> ib))
      Multiply | sameNative -> native "multiply"
               | otherwise -> arithmetic (paren (ia <> D.text " * " <> ib))
      Quotient -> bindAtom (sa ++ sb) (callDoc "try Typed.quotient" [ia, ib]) >>= narrow te
      Remainder -> bindAtom (sa ++ sb) (callDoc "try Typed.remainder" [ia, ib]) >>= narrow te
      Power -> bindAtom (sa ++ sb) (callDoc "try Typed.power" [ia, ib]) >>= narrow te
      Equal -> compare' " == "
      NotEqual -> compare' " != "
      Less -> compare' " < "
      LessEqual -> compare' " <= "
      Greater -> compare' " > "
      GreaterEqual -> compare' " >= "
      _ -> lift' (Left ("typed Swift: unsupported operator " ++ show op))
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    convert target (expressionType value) (s, x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    ordering <- orderingOf env
    t <- fresh "order"
    pure (sa ++ sb ++ [D.text ("let " ++ t ++ " = ") <> callDoc "Typed.compare" [xa, xb]],
      D.text ("(" ++ t ++ " < 0 ? " ++ ordering ++ ".less : (" ++ t ++ " == 0 ? " ++ ordering ++ ".equal : " ++ ordering ++ ".greater))"))
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> D.text "Typed.textLength(" <> v <> D.text ")"
      _ -> D.text "BigInt(" <> v <> D.text ".count)")
  Helper Unreachable _ -> do
    t <- lift' (nativeType env (expressionType e))
    bindAtom [] (D.text ("try Typed.unreachable() as " ++ t))
  Helper Checked _ -> pure ([], D.text "true")
  Helper StartsWith [a, b] -> call2 "Typed.startsWith" a b
  Helper EndsWith [a, b] -> call2 "Typed.endsWith" a b
  Helper TextContains [a, b] -> call2 "Typed.contains" a b
  Helper RegexMatches [a, b] -> do
    (s, x) <- call2 "try Regex.matches" a b
    bindAtom s x
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    item <- fresh (binderName binder)
    itemType <- lift' (nativeType env (binderType binder))
    lines' <- statements env ((binderId binder, item) : scope) (Just "Bool") Return predicate
    t <- fresh "all"
    pure (sx ++ [D.text ("let " ++ t ++ " = try ") <> xs <> D.text (".allSatisfy { (" ++ item ++ ": " ++ itemType ++ ") throws -> Bool in") <>
      block lines' <> D.hardline <> D.text "}"], D.text t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    c <- lift' (codecOf env (expressionType x))
    result <- lift' (nativeType env (expressionType e))
    t <- fresh "result"
    pure (s ++ [D.text ("let " ++ t ++ ": " ++ result ++ " = ") <> callDoc "try Typed.raiseFailure" [D.text (stringLiteral (abilityKey ref)), callDoc (c ++ ".fromNative") [v]]], D.text t)
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    a <- lift' (maybe (Left ("typed Swift: unknown ability " ++ abilityKey (operationAbility op))) Right (N.abilityOf (envUnits env) (operationAbility op)))
    handler <- fresh "handler"
    let native = callDoc ("try LawSpec.AbilityBridges." ++ Effects.bridgeName a "ToNative") [D.text "schema", D.text "symbols",
          callDoc "Effects.handler" [D.text "schema", D.text (stringLiteral (abilityKey (operationAbility op)))]]
        valueArgs = [x | (x, arg) <- zip (map snd parts) args, expressionType arg /= Constructor "Unit" []]
        operationCall = callDoc (handler ++ "." ++ Effects.operationMember (operationName op)) valueArgs
        isUnit' = expressionType e == Constructor "Unit" []
    invocation <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        c <- lift' (codecOf env failureType)
        e' <- lift' (nativeType env failureType)
        r <- if isUnit' then pure "Void" else lift' (nativeType env (expressionType e))
        pure (callDoc "try Typed.performed" [D.text (stringLiteral (abilityKey failing)), D.text ("{ try " ++ c ++ ".fromNative($0) }")] <>
          D.text (" { () throws(" ++ e' ++ ") -> " ++ r ++ " in") <> block [D.text "try " <> operationCall] <> D.hardline <> D.text "}")
      _ -> pure operationCall
    if isUnit'
      then pure (concatMap fst parts ++ [D.text ("let " ++ handler ++ " = ") <> native, invocation], D.text "Unit()")
      else bindAtom (concatMap fst parts ++ [D.text ("let " ++ handler ++ " = ") <> native]) invocation
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    c <- lift' (codecOf env failure)
    bodyType <- case expressionType e of
      Constructor "Either" [_, TypeArgument t] -> lift' (nativeType env t)
      _ -> lift' (Left "typed Swift: attempt without Either")
    lines' <- statements env scope (Just bodyType) Return body
    t <- fresh "attempted"
    pure ([D.text ("let " ++ t ++ " = ") <> callDoc "try Typed.attempt" [D.text (stringLiteral (abilityKey ref)), D.text ("{ try " ++ c ++ ".toNative($0) }")] <>
      D.text (" { () throws -> " ++ bodyType ++ " in") <> block lines' <> D.hardline <> D.text "}"], D.text t)
  Helper Append [a, b] -> infixOp " + " a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "Typed.sliceText"
          Constructor "Bytes" [] -> "Typed.sliceBytes"
          _ -> "Typed.sliceList"
    pure (sx ++ si ++ sj, callDoc f [v, exact (expressionType from) i, exact (expressionType to) j])
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = if expressionType x == Constructor "Bytes" [] then "Typed.atBytes" else "Typed.atList"
    pure (sx ++ sk, callDoc f [v, exact (expressionType k) i])
  Helper Range [lo, hi] -> do
    (sl, l) <- cexpr env scope lo
    (sh, h) <- cexpr env scope hi
    let element = case expressionType e of Constructor "List" [TypeArgument t] -> t; t -> t
        back = case element of
          Constructor n [] | n `elem` boundedTypes -> ".map { $0.truncated(" ++ boundedNative n ++ ".self) }"
          _ -> ""
        wrap d = if null back then d else D.text "PersistentList(" <> d <> D.text ")"
    pure (sl ++ sh, wrap (callDoc "Typed.range" [exact (expressionType lo) l, exact (expressionType hi) h] <> D.text back))
  Helper Octets [b] -> one "PersistentList" b
  Helper BytesOf [xs] -> one "[UInt8]" xs
  Helper Utf8 [t] -> one "Typed.utf8" t
  Helper TextOf [n] -> do
    (s, x) <- cexpr env scope n
    pure (s, callDoc "Typed.textOf" [exact (expressionType n) x])
  Helper Join [sep, parts] -> call2 "Typed.join" sep parts
  _ -> lift' (Left ("typed Swift: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, callDoc f [x])
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, callDoc f [xa, xb])
    infixOp op a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, paren (xa <> D.text op <> xb))
    viaStatements = do
      t <- fresh "value"
      ty <- lift' (nativeType env (expressionType e))
      lines' <- statements env { envSelf = Nothing } scope (Just ty) (Assign t) e
      pure ([D.text ("let " ++ t ++ ": " ++ ty)] ++ lines', D.text t)
    -- A call is bound to a constant, so effects keep their order.
    bindAtom s invocation = do
      t <- fresh "result"
      pure (s ++ [D.text ("let " ++ t ++ " = ") <> invocation], D.text t)

-- | A list's items, when it is made of Cons cells ending in Nil.
listItems :: Expr -> Maybe [Expr]
listItems e = case expressionNode e of
  Construct tag [] | idText tag == "List::Nil" -> Just []
  Construct tag [h, t] | idText tag == "List::Cons" -> (h :) <$> listItems t
  _ -> Nothing

boundedTypes :: [String]
boundedTypes = ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"]

boundedNative :: String -> String
boundedNative = id

typeName :: Type -> String
typeName (Constructor n _) = n
typeName _ = ""

-- | An integral value as a BigInt.
exact :: Type -> D.Doc -> D.Doc
exact ty x = if ty == Constructor "Integer" [] then x else D.text "BigInt(" <> x <> D.text ")"

-- | A BigInt result into the expression's type, checked. A call that may
-- throw is bound to a constant of its own, so try is always a statement's
-- first word, as Swift requires beside an operator.
narrow :: Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
narrow ty (s, x) = case ty of
  Constructor t [] | t `elem` boundedTypes -> do
    n <- fresh "narrowed"
    pure (s ++ [D.text ("let " ++ n ++ " = ") <> callDoc "try Typed.narrow" [D.text (stringLiteral t), x, D.text (t ++ ".self")]], D.text n)
  _ -> pure (s, x)

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

convert :: Type -> Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
convert target source (s, x)
  | target == source = pure (s, x)
  | target == Constructor "Integer" [] = pure (s, exact source x)
  | Constructor t [] <- target, Just (lo, hi) <- boundsOf t =
      let inside = case source of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, D.text (t ++ "(") <> x <> D.text ")")
         else narrow target (s, exact source x)
  | otherwise = pure (s, x)

constant :: Env -> Type -> Scalar -> M ([D.Doc], D.Doc)
constant _ _ s = case s of
  SBool b -> pure ([], D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure ([], D.text "Unit()")
  SInteger t n -> pure ([], D.text (integerLiteral t n))
  SSequence "Text" units -> pure ([], D.text (stringLiteral (map toEnum units)))
  SSequence "Bytes" units -> pure ([], D.text ("[UInt8]([" ++ intercalate ", " (map show units) ++ "])"))
  _ -> lift' (Left ("typed Swift: unsupported constant " ++ show s))

integerLiteral :: String -> Integer -> String
integerLiteral t n
  | t `elem` boundedTypes = case boundsOf t of
      Just (lo, _) | n == lo && n < 0 -> t ++ ".min"
      _ -> t ++ "(" ++ intLiteral n ++ ")"
  | abs n < 2 ^ (62 :: Int) = "BigInt(" ++ intLiteral n ++ ")"
  | otherwise = "BigInt(\"" ++ show n ++ "\")!"

-- | A constructor of a typed data type, a built-in container, or a
-- collection made from its items.
construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = do
  typeText <- lift' (nativeType env ty)
  case (idText tag, values) of
    ("List::Nil", []) -> pure (D.text (typeText ++ "()"))
    ("List::Cons", [h, t]) -> pure (paren t <> D.text ".prepending(" <> h <> D.text ")")
    ("Maybe::Absent", []) -> pure (D.text ("(nil as " ++ typeText ++ ")"))
    ("Maybe::Present", [x]) -> pure (paren (callDoc (typeText ++ ".some") [x]))
    ("Either::Left", [x]) -> pure (callDoc (typeText ++ ".left") [x])
    ("Either::Right", [x]) -> pure (callDoc (typeText ++ ".right") [x])
    (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty ->
      pure (D.text (typeText ++ "(") <> items <> D.text ".map { ($0.key, $0.value) })")
    (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (D.text (typeText ++ "(") <> items <> D.text ")")
    _ -> case M.lookup tag (envConstructors env) of
      Just (d, c) -> pure $ if Data.isStruct (Data.recursiveTypes (envDeclarations env)) d
        then callDoc typeText [D.text (filter (/= '`') (Data.fieldName (binderName b)) ++ ": ") <> v | (b, v) <- zip (constructorFields c) values]
        else if null values then D.text (typeText ++ "." ++ filter (/= '`') (Data.caseName c))
        else callDoc (typeText ++ "." ++ filter (/= '`') (Data.caseName c))
          [D.text (filter (/= '`') (Data.fieldName (binderName b)) ++ ": ") <> v | (b, v) <- zip (constructorFields c) values]
      Nothing -> lift' (Left ("typed Swift: unknown constructor " ++ idText tag))

dataNameOf :: Env -> DataDeclaration -> String
dataNameOf env d = maybe (dataName d) id (lookup (dataId d) (envNames env))

orderingOf :: Env -> M String
orderingOf env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Just d -> pure (dataNameOf env d)
  Nothing -> lift' (Left "typed Swift: no typed Ordering")

codecOf :: Env -> Type -> Either String String
codecOf env = Data.codec (envBits env) (envNames env) []

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, t)]) -> do
    entryType <- case t of
      Constructor "List" [TypeArgument et] -> lift' (nativeType env et)
      _ -> lift' (Left "typed Swift: keyValOf of a non-list")
    _ <- pure entryType
    pure (D.text "SortedMap(" <> es <> D.text ".map { ($0.key, $0.value) })")
  (KeyValLookup, [(k, _), (m, _)]) -> pure (m <> D.text "[" <> k <> D.text "]")
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> pure (m <> D.text ".putting(" <> k <> D.text ", " <> v <> D.text ")")
  (KeyValDelete, [(k, _), (m, _)]) -> pure (m <> D.text ".removing(" <> k <> D.text ")")
  (KeyValKeys, [(m, _)]) -> pure (D.text "PersistentList(" <> m <> D.text ".keys)")
  (KeyValValues, [(m, _)]) -> pure (D.text "PersistentList(" <> m <> D.text ".values)")
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryName env
    pure (D.text "PersistentList(" <> m <> D.text (".entries.map { " ++ entry ++ "(key: $0.key, value: $0.value) })"))
  (SetOf, [(xs, _)]) -> pure (D.text "SortedSet(" <> xs <> D.text ")")
  (SetMember, [(x, _), (s, _)]) -> pure (s <> D.text ".contains(" <> x <> D.text ")")
  (SetInsert, [(x, _), (s, _)]) -> pure (s <> D.text ".inserting(" <> x <> D.text ")")
  (SetRemove, [(x, _), (s, _)]) -> pure (s <> D.text ".removing(" <> x <> D.text ")")
  (SetUnion, [(s, _), (t, _)]) -> pure (s <> D.text ".union(" <> t <> D.text ")")
  (SetIntersection, [(s, _), (t, _)]) -> pure (s <> D.text ".intersection(" <> t <> D.text ")")
  (SetDifference, [(s, _), (t, _)]) -> pure (s <> D.text ".subtracting(" <> t <> D.text ")")
  _ -> lift' (Left ("typed Swift: bad intrinsic " ++ show intrinsic))

entryName :: Env -> M String
entryName env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d -> pure (dataNameOf env d)
  Nothing -> lift' (Left "typed Swift: no typed Entry")

matchStatements :: Env -> Scope -> Maybe String -> Sink -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env scope resultType sink value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      binders c = forM (caseBinders c) $ \b -> if used c b
        then do
          n <- fresh (binderName b)
          pure (Just (binderId b, n), n)
        else pure (Nothing, "_")
      bound c = [x | (Just x, _) <- c]
      armBody c bs = statements env (bound bs ++ scope) resultType sink (caseBody c)
      unreachableArm = D.text "default:" <> block [D.text "throw Typed.unreachableFailure()"]
      letPattern names = if all (== "_") names then "" else "let "
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], D.text name)
    _ -> cexpr env { envSelf = Nothing } scope value
  arms <- case ty of
    Constructor "List" _ -> do
      nilCase <- case [c | c <- cases, idText (caseConstructor c) == "List::Nil"] of
        c : _ -> armBody c []
        [] -> pure [D.text "throw Typed.unreachableFailure()"]
      consCase <- case [c | c <- cases, idText (caseConstructor c) == "List::Cons"] of
        c : _ -> do
          bs <- binders c
          let names = map snd bs
              heads = case names of
                (h : _) | h /= "_" -> [D.text ("let " ++ h ++ " = ") <> subject <> D.text ".first!"]
                _ -> []
              tails = case names of
                (_ : t : _) | t /= "_" -> [D.text ("let " ++ t ++ " = ") <> subject <> D.text ".rest"]
                _ -> []
          rest <- armBody c bs
          pure (heads ++ tails ++ rest)
        [] -> pure [D.text "throw Typed.unreachableFailure()"]
      pure [D.text "if " <> subject <> D.text ".isEmpty {" <> block nilCase <> D.hardline <> D.text "} else {" <> block consCase <> D.hardline <> D.text "}"]
    Constructor n _ | n `elem` ["Maybe", "Either"] -> do
      arms <- forM cases $ \c -> do
        bs <- binders c
        let names = map snd bs
            pattern' = case (idText (caseConstructor c), names) of
              ("Maybe::Absent", _) -> ".none"
              ("Maybe::Present", [x]) -> ".some(" ++ letPattern [x] ++ x ++ ")"
              ("Either::Left", [x]) -> ".left(" ++ letPattern [x] ++ x ++ ")"
              ("Either::Right", [x]) -> ".right(" ++ letPattern [x] ++ x ++ ")"
              _ -> "_"
        body <- armBody c bs
        pure (D.text ("case " ++ pattern' ++ ":") <> block body)
      pure [D.text "switch " <> subject <> D.text " {" <> D.hardline <> D.joinWith D.hardline (arms ++ [unreachableArm | length cases < 2]) <> D.hardline <> D.text "}"]
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          bs <- binders c
          entry <- if kind == "KeyVal" then Just <$> entryName env else pure Nothing
          let items = case entry of
                Just e -> D.text ".entries.map { " <> D.text (e ++ "(key: $0.key, value: $0.value) }")
                Nothing -> D.text ".items"
              binding = case bs of
                [(_, n')] | n' /= "_" -> [D.text ("let " ++ n' ++ " = PersistentList(") <> subject <> items <> D.text ")"]
                _ -> []
          body <- armBody c bs
          pure (binding ++ body)
    Constructor n _ | Just d <- M.lookup n (envData env) ->
      if Data.isStruct (Data.recursiveTypes (envDeclarations env)) d
        then case cases of
          [c] -> do
            bs <- binders c
            let ctor = snd (envConstructors env M.! caseConstructor c)
                fields = [D.text ("let " ++ name ++ " = ") <> subject <> D.text ("." ++ filter (/= '`') (Data.fieldName (binderName b))) | ((_, name), b) <- zip bs (constructorFields ctor), name /= "_"]
            body <- armBody c bs
            pure (fields ++ body)
          _ -> lift' (Left "typed Swift: a record has one constructor")
        else do
          arms <- forM cases $ \c -> do
            bs <- binders c
            let ctor = snd (envConstructors env M.! caseConstructor c)
                names = map snd bs
                caseText = "." ++ filter (/= '`') (Data.caseName ctor) ++
                  (if null names then "" else "(" ++ intercalate ", " [if v == "_" then v else "let " ++ v | v <- names] ++ ")")
            body <- armBody c bs
            pure (D.text ("case " ++ caseText ++ ":") <> block body)
          pure [D.text "switch " <> subject <> D.text " {" <> D.hardline <>
            D.joinWith D.hardline (arms ++ [unreachableArm | length cases < length (dataConstructors d)]) <> D.hardline <> D.text "}"]
    _ -> lift' (Left ("typed Swift: cannot match on " ++ show ty))
  pure (prelude ++ arms)
