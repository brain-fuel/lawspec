-- | Typed F# for checked definitions (see LawSpec.Typed.Plan), in
-- src/LawSpec/Typed.fs, the module LawSpec.TypedProgram: a function per class of
-- typed definitions over the program's native F# types, the same records,
-- unions, lists, options, Map and Set the adapters and the embedding API
-- use, so a typed definition converts nothing, at its boundary or within.
-- Bounded integers are .NET's own, checked (LawSpec.Runtime.Typed), Integer
-- is bigint, Text is string by code point. A definition that performs an
-- operation takes the handler context (the schema whose scope holds the
-- handlers, and the symbols) first; raise and attempt throw and catch the
-- dynamic code's RaisedFailure. A self-recursive call in tail position is a
-- loop (the generated project compiles with tail calls). Each function is
-- named for its definition, with _2, _3 only on a clash; locals keep their
-- source names. The module is laid out as Fantomas lays it out.
-- ref:DEC-typed-native-definitions ref:DEC-fsharp-runtime-from-scratch
module LawSpec.Typed.FSharp (FSharpTyped(..), emitFSharpTyped, dotnetTypedDeclarations) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.Char (isLower)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.AbilityNames as N
import LawSpec.DotNet.Code (stringLiteral, Lang(..))
import LawSpec.DotNet.Names (pascal, camel, dataNames, localName, fsharpKeywords)
import LawSpec.DotNet.Layout (F(A, App, Method, List, Record, Fun, Cond, Block, Infix, Paren, Prefix, Annotated), Stmt(..))
import qualified LawSpec.DotNet.Layout as L
import LawSpec.Naming (Scope, claim, claimAll, scopeWith, readableDefinitionName, localIdentifier)
import LawSpec.SourceLink (labelled, sourceLink)
import qualified LawSpec.DotNet.Data as Data
import qualified LawSpec.DotNet.Effects as Effects

data FSharpTyped = FSharpTyped
  { fsTypedSource :: Maybe String
    -- The typed function of a typed definition, qualified.
  , fsTypedFunction :: Id -> Maybe String
    -- The same, by its compiled name, for C#.
  , fsTypedCsFunction :: Id -> Maybe String
    -- Whether a typed definition takes the handler context.
  , fsTypedContextual :: Id -> Bool
    -- The function giving a typed handler's start state, qualified.
  , fsTypedStart :: Id -> Maybe String
  , fsTypedCsStart :: Id -> Maybe String
  , fsTypedPlan :: TypedPlan
  }

-- | The declarations whose native F# type is their typed form: not a type
-- the runtime gives its own .NET type (Duration), nor one bound to an
-- application's type.
dotnetTypedDeclarations :: [Id] -> [DataDeclaration] -> [DataDeclaration]
dotnetTypedDeclarations bound declarations =
  [ d | d <- declarations, idText (dataId d) /= "lawspec.time::type::Duration", dataId d `notElem` bound ]

data Env = Env
  { envPlan :: TypedPlan
  , envBits :: Int
  , envNames :: Data.Names
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envUnits :: [Unit]
  }

-- | The names taken in the module (functions, literals) and in the function
-- being written, and the literals made so far.
data St = St { stModule :: Scope, stLocals :: Scope, stLiterals :: M.Map String (String, F) }

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

-- | A local named after a source binder or what it holds, unique in its
-- function. Names the module declares are never shadowed.
fresh :: String -> M String
fresh base = do
  s <- get
  let (name, locals) = claim (stLocals s) (localName FSharp (localIdentifier "fsharp" base))
  put s { stLocals = locals }
  pure name

-- | A function's locals start from the module's names.
enterFunction :: M ()
enterFunction = modify (\s -> s { stLocals = stModule s })

-- | A byte array, made once.
literal :: String -> F -> M String
literal key definition = do
  st <- get
  case M.lookup key (stLiterals st) of
    Just (name, _) -> pure name
    Nothing -> do
      let (name, scope) = claim (stModule st) "bytes"
      put st { stLiterals = M.insert key (name, definition) (stLiterals st), stModule = scope }
      pure name

-- | Names the module itself uses.
moduleReserved :: [String]
moduleReserved = fsharpKeywords ++ ["schema", "symbols", "subject", "e", "k", "v", "c", "s", "x", "native", "value", "result"]

emitFSharpTyped :: Int -> [Id] -> [DataDeclaration] -> [Unit] -> Either String FSharpTyped
emitFSharpTyped bits bound allDeclarations units = do
  let declarations = dotnetTypedDeclarations bound allDeclarations
      plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      -- Each typed function is named after its definition.
      (functionNames, moduleScope) = claimAll (scopeWith moduleReserved)
        [ localName FSharp (readableDefinitionName (declarationName (definitionDeclaration d))
            (fst (functionType (declarationType (definitionDeclaration d)))))
        | (_, d) <- typedRepresentatives plan ]
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
  names <- dataNames allDeclarations
  let env = Env plan bits names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions units
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      started = [ (h, ty, start) | h <- typedHandlers, Just (ty, start) <- [handlerState h] ]
      (startNames, startScope) = claimAll moduleScope [ "start" ++ pascal (handlerName h) | (h, _, _) <- started ]
      starts = [ (handlerId h, name, ty, start) | ((h, ty, start), name) <- zip started startNames ]
  (docs, st) <- flip runStateT (St startScope startScope M.empty) $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      enterFunction
      (statements, result) <- cstmt env [] start
      t <- lift' (nativeType env ty)
      pure (["/// A typed handler's start state.", "[<CompiledName(\"" ++ compiledName name ++ "\")>]"] ++
        L.function 0 ("let " ++ name) ["(schema: Schema.Schema)", "(symbols: Scalar.SymbolContext)"] (Just t) (Block statements result))
    pure (fs ++ ss)
  let aliases = [[Data.fsharpTypeAbbreviation allDeclarations d (constructorAlias d) ("LawSpec.Data." ++ dataNameOf env d)] |
        d<-datas,needsConstructorAlias env d]
      literals = [ L.binding 0 ("let private " ++ name) definition | (name, definition) <- M.elems (stLiterals st) ]
      header =
        [ "// Generated by LawSpec. Do not edit."
        , "/// Typed checked definitions over the program's native types (see"
        , "/// docs/how-to/targets/fsharp.md). Each is named for its definition."
        , "module rec LawSpec.TypedProgram"
        , ""
        , "#nowarn \"25\""
        , ""
        , "open LawSpec.Runtime"
        , "" ]
      source = unlines (header ++ L.separatedBy [""] (aliases ++ literals ++ docs))
  pure FSharpTyped
    { fsTypedSource = if null docs then Nothing else Just source
    , fsTypedFunction = \i -> ("LawSpec.TypedProgram." ++) <$> (definitionClass plan i >>= (`M.lookup` functions))
    , fsTypedCsFunction = \i -> ("LawSpec.TypedProgram." ++) . compiledName <$> (definitionClass plan i >>= (`M.lookup` functions))
    , fsTypedContextual = isContextual plan
    , fsTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just ("LawSpec.TypedProgram." ++ n)
        [] -> Nothing
    , fsTypedCsStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just ("LawSpec.TypedProgram." ++ compiledName n)
        [] -> Nothing
    , fsTypedPlan = plan }

-- | A typed function's name in C#: its F# name, capitalized.
compiledName :: String -> String
compiledName name = case take 1 name of
  [c] | isLower c -> toEnum (fromEnum c - 32) : drop 1 name
  _ -> name

type Scope' = [(Id, String)]

nativeType :: Env -> Type -> Either String String
nativeType env = Data.nativeType FSharp (envBits env) (envNames env) []

functionDoc :: Env -> Int -> Definition -> M L.Lines
functionDoc env c d = do
  enterFunction
  let declaration = definitionDeclaration d
      (args, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  types <- lift' (mapM (nativeType env) args)
  resultType <- lift' (nativeType env result)
  (statements, value) <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(A l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure ([], x)
    Nothing -> cstmt env params (definitionBody d)
  let parameters = concat [["(schema: Schema.Schema)", "(symbols: Scalar.SymbolContext)"] | contextual] ++
        ["(" ++ l ++ ": " ++ t ++ ")" | ((_, l), t) <- zip params types]
  pure (["/// " ++ labelled (idText (declarationId declaration)) (sourceLink (declarationOrigin declaration)),
    "[<CompiledName(\"" ++ compiledName name ++ "\")>]"] ++
    L.function 0 ("let " ++ name) (if null parameters then ["()"] else parameters) (Just resultType) (Block statements value))

-- | The statements that compute an expression, and its value.
cstmt :: Env -> Scope' -> Expr -> M ([Stmt], F)
cstmt env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    (rest, r) <- cstmt env ((binderId binder, local) : scope) body
    pure (s ++ [LetS ("let " ++ local) x] ++ rest, r)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env scope a
    no <- cstmt env scope b
    pure (s, Cond x (uncurry Block yes) (uncurry Block no))
  Helper Select [c, a, b] -> cstmt env scope (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope value cases
  _ -> cexpr env scope e

-- | An expression's value: the statements that compute it, and an atom.
cexpr :: Env -> Scope' -> Expr -> M ([Stmt], F)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> constant (expressionType e) s
  Local i -> do
    name <- lift' (maybe (Left ("typed F#: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], A name)
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
        c <- lift' (maybe (Left ("typed F#: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = [[A "schema", A "symbols"] | isContextual (envPlan env) i]
            call = App (envFunctions env M.! c) (concat context ++ map snd parts ++ [A "()" | null parts && null context])
        bindAtom (concatMap fst parts) call
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, Paren (Infix (if op == And then "&&" else "||") xa xb))
      else do
        t <- fresh "logic"
        let rest = Block sb xb
        pure (sa ++ [LetS ("let " ++ t) (if op == And then Cond xa rest (A "false") else Cond xa (A "true") rest)], A t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, App "not" [x])
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    narrow (expressionType e) (s, Paren (Prefix "-" (exact (expressionType a) x)))
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, Paren (Infix (if op == Equal then "=" else "<>") xa xb))
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
        compare' symbol = pure (sa ++ sb, if same then Paren (Infix symbol xa xb) else Paren (Infix symbol ia ib))
        native f = pure (sa ++ sb, App ("Typed." ++ f) [A (show (typeName ta)), xa, xb])
        arithmetic r = narrow te (sa ++ sb, r)
        sameNative = same && te == ta && bounded
    case op of
      Add | sameNative -> native "add"
          | otherwise -> arithmetic (Paren (Infix "+" ia ib))
      Subtract | sameNative -> native "subtract"
               | otherwise -> arithmetic (Paren (Infix "-" ia ib))
      Multiply | sameNative -> native "multiply"
               | otherwise -> arithmetic (Paren (Infix "*" ia ib))
      Quotient -> arithmetic (App "Typed.quotient" [ia, ib])
      Remainder -> arithmetic (App "Typed.remainder" [ia, ib])
      Power -> arithmetic (App "Typed.power" [ia, ib])
      Equal -> compare' "="
      NotEqual -> compare' "<>"
      Less -> compare' "<"
      LessEqual -> compare' "<="
      Greater -> compare' ">"
      GreaterEqual -> compare' ">="
      _ -> lift' (Left ("typed F#: unsupported operator " ++ show op))
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    convert target (expressionType value) (s, x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    ordering <- orderingOf env
    pure (sa ++ sb, App ordering [App "Typed.compare" [xa, xb]])
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> App "Typed.textLength" [v]
      Constructor "Bytes" [] -> App "bigint" [App "Array.length" [v]]
      _ -> App "bigint" [App "List.length" [v]])
  Helper Unreachable _ -> pure ([], App "Typed.unreachable" [])
  Helper Checked _ -> pure ([], A "true")
  Helper StartsWith [a, b] -> call2 "Typed.startsWith" a b
  Helper EndsWith [a, b] -> call2 "Typed.endsWith" a b
  Helper TextContains [a, b] -> call2 "Typed.contains" a b
  Helper RegexMatches [a, b] -> call2 "Regex.matches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    item <- fresh (binderName binder)
    (statements, holds) <- cstmt env ((binderId binder, item) : scope) predicate
    t <- fresh "all"
    pure (sx ++ [LetS ("let " ++ t) (App "List.forall" [Fun item (Block statements holds), xs])], A t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    c <- lift' (codecOf env (expressionType x))
    result <- lift' (nativeType env (expressionType e))
    pure (s, Annotated (App "Typed.raiseFailure" [A (stringLiteral FSharp (abilityKey ref)), fromNative c v]) result)
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    a <- lift' (maybe (Left ("typed F#: unknown ability " ++ abilityKey (operationAbility op))) Right (N.abilityOf (envUnits env) (operationAbility op)))
    -- The ability's native interface is bound to a local, then called.
    handler <- fresh (camel (N.interfaceName a))
    let native = App ("LawSpec.Generated.Abilities." ++ Effects.bridgeName a "ToNative")
          [A "schema", A "symbols", App "Effects.handler" [A "schema", A (stringLiteral FSharp (abilityKey (operationAbility op)))]]
        unitOnly = map expressionType args == [Constructor "Unit" []]
        call = Method (handler ++ "." ++ Effects.operationMember (operationName op)) [v | (_, v) <- parts, not unitOnly]
        evaluated = concatMap fst parts ++ [LetS "let ()" v | (_, v) <- parts, unitOnly] ++ [LetS ("let " ++ handler) native]
    invocation <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        c <- lift' (codecOf env failureType)
        pure (App "Typed.performed" [A (stringLiteral FSharp (abilityKey failing)), codecMember c "FromNative", call])
      _ -> pure call
    bindAtom evaluated invocation
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    c <- lift' (codecOf env failure)
    (statements, value) <- cstmt env scope body
    t <- fresh "attempted"
    pure ([LetS ("let " ++ t) (App "Typed.attempt" [A (stringLiteral FSharp (abilityKey ref)), codecMember c "ToNative", Fun "()" (Block statements value)])], A t)
  Helper Append [a, b] -> case expressionType a of
    Constructor "Text" [] -> infixOp "+" a b
    Constructor "Bytes" [] -> call2 "Array.append" a b
    _ -> infixOp "@" a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "Typed.sliceText"
          Constructor "Bytes" [] -> "Typed.sliceBytes"
          _ -> "Typed.sliceList"
    pure (sx ++ si ++ sj, App f [v, exact (expressionType from) i, exact (expressionType to) j])
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = if expressionType x == Constructor "Bytes" [] then "Typed.atBytes" else "Typed.atList"
    pure (sx ++ sk, App f [v, exact (expressionType k) i])
  Helper Range [lo, hi] -> do
    (sl, l) <- cexpr env scope lo
    (sh, h) <- cexpr env scope hi
    let element = case expressionType e of Constructor "List" [TypeArgument t] -> t; t -> t
        range = App "Typed.range" [exact (expressionType lo) l, exact (expressionType hi) h]
    pure (sl ++ sh, case element of
      Constructor n [] | Just f <- lookup n plainConversion, f /= "id" -> Paren (Infix "|>" range (App "List.map" [A f]))
      _ -> range)
  Helper Octets [b] -> one "Array.toList" b
  Helper BytesOf [xs] -> one "Array.ofList" xs
  Helper Utf8 [t] -> one "Typed.utf8" t
  Helper TextOf [n] -> do
    (s, x) <- cexpr env scope n
    pure (s, App "Typed.textOf" [exact (expressionType n) x])
  Helper Join [sep, parts] -> call2 "Typed.join" sep parts
  _ -> lift' (Left ("typed F#: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, App f [x])
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, App f [xa, xb])
    infixOp op a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, Paren (Infix op xa xb))
    viaStatements = do
      (statements, value) <- cstmt env scope e
      t <- fresh "value"
      pure ([LetS ("let " ++ t) (Block statements value)], A t)
    -- A call is bound to a local, so effects keep their order.
    bindAtom s call = do
      t <- fresh "result"
      pure (s ++ [LetS ("let " ++ t) call], A t)

-- | A codec's conversion; a codec built by an expression goes through
-- Codec.toNative or Codec.fromNative.
codecMember :: String -> String -> F
codecMember c member
  | take 1 c == "(" = App (if member == "ToNative" then "Codec.toNative" else "Codec.fromNative") [A c]
  | otherwise = A (c ++ "." ++ member)

fromNative :: String -> F -> F
fromNative c v
  | take 1 c == "(" = App "Codec.fromNative" [A c, v]
  | otherwise = App (c ++ ".FromNative") [v]

boundedTypes :: [String]
boundedTypes = ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"]

typeName :: Type -> String
typeName (Constructor n _) = n
typeName _ = ""

-- | A bigint to a bounded type, where the value is known to fit.
plainConversion :: [(String, String)]
plainConversion =
  [ ("Int8", "sbyte"), ("Int16", "int16"), ("Int32", "int32"), ("Int64", "int64"), ("UInt8", "byte")
  , ("UInt16", "uint16"), ("UInt32", "uint32"), ("UInt64", "uint64"), ("Integer", "id") ]

-- | An integral value as a bigint.
exact :: Type -> F -> F
exact ty x = if ty == Constructor "Integer" [] then x else App "bigint" [x]

-- | A bigint result into the expression's type, checked.
narrow :: Type -> ([Stmt], F) -> M ([Stmt], F)
narrow ty (s, x) = case ty of
  Constructor t [] | t `elem` boundedTypes -> pure (s, App ("Typed." ++ checkedName t) [x])
  _ -> pure (s, x)

checkedName :: String -> String
checkedName t = case t of
  "Int8" -> "int8"; "Int16" -> "int16"; "Int32" -> "int32"; "Int64" -> "int64"
  "UInt8" -> "uint8"; "UInt16" -> "uint16"; "UInt32" -> "uint32"; _ -> "uint64"

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

convert :: Type -> Type -> ([Stmt], F) -> M ([Stmt], F)
convert target source (s, x)
  | target == source = pure (s, x)
  | target == Constructor "Integer" [] = pure (s, exact source x)
  | Constructor t [] <- target, Just (lo, hi) <- boundsOf t, Just f <- lookup t plainConversion =
      let inside = case source of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, App f [x])
         else narrow target (s, exact source x)
  | otherwise = pure (s, x)

-- | A constant: text as an F# string literal (Text is a .NET string, by
-- code point), bytes as an array made once.
constant :: Type -> Scalar -> M ([Stmt], F)
constant _ s = case s of
  SBool b -> pure ([], A (if b then "true" else "false"))
  SAbsent "Unit" -> pure ([], A "()")
  SInteger t n -> pure ([], A (integerLiteral t n))
  SSequence "Text" units
    | all (\u -> u >= 0 && u <= 0x10FFFF && (u < 0xD800 || u > 0xDFFF)) units -> pure ([], A (stringLiteral FSharp (map toEnum units)))
    | otherwise -> pure ([], App "Scalar.textOfPoints" [List (map (A . show) units)])
  SSequence "Bytes" units -> do
    name <- literal ("bytes " ++ show units) (A ("[| " ++ intercalate "; " [show u ++ "uy" | u <- units] ++ " |]"))
    pure ([], A name)
  _ -> lift' (Left ("typed F#: unsupported constant " ++ show s))

integerLiteral :: String -> Integer -> String
integerLiteral t n =
  let suffix = case t of
        "Int8" -> "y"; "Int16" -> "s"; "Int32" -> ""; "Int64" -> "L"
        "UInt8" -> "uy"; "UInt16" -> "us"; "UInt32" -> "u"; "UInt64" -> "UL"; _ -> "I"
      -- The least value of a signed type has no literal of its own.
      text = case (t, n) of
        ("Int64", -9223372036854775808) -> "System.Int64.MinValue"
        ("Int32", -2147483648) -> "System.Int32.MinValue"
        ("Int16", -32768) -> "System.Int16.MinValue"
        ("Int8", -128) -> "System.SByte.MinValue"
        _ -> show n ++ suffix
  in if n < 0 then "(" ++ text ++ ")" else text

-- | A constructor of a typed data type, a built-in container, or a
-- collection made from its items. A record names its type in its first
-- field.
construct :: Env -> Type -> Id -> [F] -> M F
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (A "[]")
  ("List::Cons", [h, t]) -> pure (Paren (Infix "::" h t))
  ("Maybe::Absent", []) -> pure (A "None")
  ("Maybe::Present", [x]) -> pure (App "Some" [x])
  ("Either::Left", [x]) -> pure (App "LawSpec.Either.Left" [x])
  ("Either::Right", [x]) -> pure (App "LawSpec.Either.Right" [x])
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    entry <- entryType env
    pure (App "Typed.keyValOf" [A ("(fun (e: " ++ entry ++ ") -> e.Key)"), A ("(fun (e: " ++ entry ++ ") -> e.Value)"), items])
  (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (App "Set.ofList" [items])
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c) -> do
      let typeRef = constructorTypeRef env d
          qualified = "LawSpec.Data." ++ dataNameOf env d
      pure $ if isRecord d
        then Record [((if k == 0 then qualified ++ "." else "") ++ pascal (binderName b), v) | (k, b, v) <- zip3 [0 :: Int ..] (constructorFields c) values]
        else if null values then A (typeRef ++ "." ++ pascal (constructorName c))
        else Method (typeRef ++ "." ++ pascal (constructorName c)) values
    Nothing -> lift' (Left ("typed F#: unknown constructor " ++ idText tag))

dataNameOf :: Env -> DataDeclaration -> String
dataNameOf env d = maybe (dataName d) id (lookup (dataId d) (envNames env))

-- F# resolves Namespace.Type.Type as the union case before the type when
-- both have the same name. A private type abbreviation disambiguates both
-- constructions and patterns without changing the public native type.
needsConstructorAlias :: Env -> DataDeclaration -> Bool
needsConstructorAlias env d = not (isRecord d) &&
  any ((== dataNameOf env d) . pascal . constructorName) (dataConstructors d)

constructorAlias :: DataDeclaration -> String
constructorAlias d = "LawSpecPattern_" ++ stableSuffix (dataId d)

constructorTypeRef :: Env -> DataDeclaration -> String
constructorTypeRef env d = if needsConstructorAlias env d then constructorAlias d else "LawSpec.Data." ++ dataNameOf env d

-- | A record: one constructor with fields (as LawSpec.DotNet.Data makes it).
isRecord :: DataDeclaration -> Bool
isRecord d = case dataConstructors d of
  [c] -> not (null (constructorFields c)) && null (constructorExistentials c)
  _ -> False

orderingOf :: Env -> M String
orderingOf env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Just d ->
    let name = "LawSpec.Data." ++ dataNameOf env d
        con n = name ++ "." ++ n
    in pure ("(fun c -> if c < 0 then " ++ con "Less" ++ " elif c = 0 then " ++ con "Equal" ++ " else " ++ con "Greater" ++ ")")
  Nothing -> lift' (Left "typed F#: no typed Ordering")

codecOf :: Env -> Type -> Either String String
codecOf env = Data.codec FSharp (envBits env) (envNames env) []

intrinsicCall :: Env -> Intrinsic -> [(F, Type)] -> M F
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, _)]) -> do
    entry <- entryType env
    pure (App "Typed.keyValOf" [A ("(fun (e: " ++ entry ++ ") -> e.Key)"), A ("(fun (e: " ++ entry ++ ") -> e.Value)"), es])
  (KeyValLookup, [(k, _), (m, _)]) -> apply "Map.tryFind" [k, m]
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> apply "Map.add" [k, v, m]
  (KeyValDelete, [(k, _), (m, _)]) -> apply "Map.remove" [k, m]
  (KeyValKeys, [(m, _)]) -> apply "Typed.keys" [m]
  (KeyValValues, [(m, _)]) -> apply "Typed.values" [m]
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryType env
    pure (App "Typed.entries" [A ("(fun k v -> ({ Key = k; Value = v } : " ++ entry ++ "))"), m])
  (SetOf, [(xs, _)]) -> apply "Set.ofList" [xs]
  (SetMember, [(x, _), (s, _)]) -> apply "Set.contains" [x, s]
  (SetInsert, [(x, _), (s, _)]) -> apply "Set.add" [x, s]
  (SetRemove, [(x, _), (s, _)]) -> apply "Set.remove" [x, s]
  (SetUnion, [(s, _), (t, _)]) -> apply "Set.union" [s, t]
  (SetIntersection, [(s, _), (t, _)]) -> apply "Set.intersect" [s, t]
  (SetDifference, [(s, _), (t, _)]) -> apply "Set.difference" [s, t]
  _ -> lift' (Left ("typed F#: bad intrinsic " ++ show intrinsic))
  where apply f xs = pure (App f xs)

entryType :: Env -> M String
entryType env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d -> pure ("LawSpec.Data." ++ dataNameOf env d ++ "<_, _>")
  Nothing -> lift' (Left "typed F#: no typed Entry")

matchStatements :: Env -> Scope' -> Expr -> [MatchCase] -> M ([Stmt], F)
matchStatements env scope value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      binders c = forM (caseBinders c) $ \b -> if used c b
        then do
          n <- fresh (binderName b)
          pure (Just (binderId b, n), n)
        else pure (Nothing, "_")
      alternative c pattern' = do
        bound <- binders c
        (statements, result) <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
        pure (pattern' (map snd bound), Block statements result)
      unreachableArm = ("_", App "Typed.unreachable" [])
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], A name)
    _ -> cexpr env scope value
  arms <- case ty of
    Constructor n _ | n `elem` ["Maybe", "Either", "List"] -> do
      arms <- forM cases $ \c -> alternative c (\names -> case (idText (caseConstructor c), names) of
        ("Maybe::Absent", _) -> "None"
        ("Maybe::Present", [x]) -> "Some " ++ x
        ("Either::Left", [x]) -> "LawSpec.Either.Left " ++ x
        ("Either::Right", [x]) -> "LawSpec.Either.Right " ++ x
        ("List::Nil", _) -> "[]"
        ("List::Cons", [h, t]) -> h ++ " :: " ++ t
        _ -> "_")
      pure (arms ++ [unreachableArm | length cases < 2])
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          bound <- binders c
          (statements, result) <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
          entry <- if kind == "KeyVal" then Just <$> entryType env else pure Nothing
          let items = case entry of
                Just e -> App "Typed.entries" [A ("(fun k v -> ({ Key = k; Value = v } : " ++ e ++ "))"), A "subject"]
                Nothing -> App "Typed.items" [A "subject"]
              binding = case bound of
                [(_, n')] | n' /= "_" -> [LetS ("let " ++ n') items]
                _ -> []
          pure [("subject", Block (binding ++ statements) result)]
    Constructor n _ | Just d <- M.lookup n (envData env) ->
      if isRecord d
        then case cases of
          [c] -> do
            bound <- binders c
            (statements, result) <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
            let ctor = snd (envConstructors env M.! caseConstructor c)
                fields = [LetS ("let " ++ name) (A ("subject." ++ pascal (binderName b))) | ((_, name), b) <- zip bound (constructorFields ctor), name /= "_"]
            pure [("subject", Block (fields ++ statements) result)]
          _ -> lift' (Left "typed F#: a record has one constructor")
        else do
          let typeRef = constructorTypeRef env d
          arms <- forM cases $ \c -> alternative c (\names ->
            let caseName = typeRef ++ "." ++ pascal (constructorName (snd (envConstructors env M.! caseConstructor c)))
            in if null names then caseName else caseName ++ "(" ++ intercalate ", " names ++ ")")
          pure (arms ++ [unreachableArm | length cases < length (dataConstructors d)])
    _ -> lift' (Left ("typed F#: cannot match on " ++ show ty))
  pure (prelude, L.Match subject arms)
