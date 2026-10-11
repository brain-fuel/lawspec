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
-- loop (the generated project compiles with tail calls). Names are stable:
-- each function is named for its definition and a digest of its identity.
-- ref:DEC-typed-native-definitions ref:DEC-fsharp-runtime-from-scratch
module LawSpec.Typed.FSharp (FSharpTyped(..), emitFSharpTyped, dotnetTypedDeclarations) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isAscii, isLower, isUpper, toLower)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.AbilityNames as N
import qualified LawSpec.Code.Doc as D
import LawSpec.DotNet.Code (stringLiteral, Lang(..))
import LawSpec.DotNet.Names (pascal, camel, escapeFSharp, dataNames)
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

data St = St { stCounter :: Int, stLiterals :: M.Map String (String, String) }

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

fresh :: String -> M String
fresh base = do
  s <- get
  put s { stCounter = stCounter s + 1 }
  pure (sanitize base ++ "_" ++ show (stCounter s))

sanitize :: String -> String
sanitize name = case [c | c <- name, isAlphaNum c && isAscii c] of
  [] -> "v"
  cleaned@(c : _) | isLower c -> cleaned
  cleaned@(c : cs) | isUpper c -> toLower c : cs
  cleaned -> "v" ++ cleaned

-- | A literal text or byte array, made once.
literal :: String -> String -> M String
literal key definition = do
  st <- get
  case M.lookup key (stLiterals st) of
    Just (name, _) -> pure name
    Nothing -> do
      let name = "literal" ++ show (M.size (stLiterals st))
      put st { stLiterals = M.insert key (name, definition) (stLiterals st) }
      pure name

emitFSharpTyped :: Int -> [Id] -> [DataDeclaration] -> [Unit] -> Either String FSharpTyped
emitFSharpTyped bits bound allDeclarations units = do
  let declarations = dotnetTypedDeclarations bound allDeclarations
      plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      functions = M.fromList [ (c, functionName d) | (c, d) <- typedRepresentatives plan ]
  names <- dataNames allDeclarations
  let env = Env plan bits names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions units
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      starts = [ (handlerId h, "start_" ++ stableSuffix (handlerId h), ty, start) | h <- typedHandlers, Just (ty, start) <- [handlerState h] ]
  (docs, st) <- flip runStateT (St 0 M.empty) $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      body <- cstmt env [] start
      t <- lift' (nativeType env ty)
      pure (D.text "/// A typed handler's start state." <> D.hardline <>
        D.text ("[<CompiledName(\"" ++ compiledName name ++ "\")>]") <> D.hardline <>
        D.text ("let " ++ name ++ " (schema: Schema.Schema) (symbols: Scalar.SymbolContext) : " ++ t ++ " =") <> block body)
    pure (fs ++ ss)
  let literals = [ D.text ("let private " ++ name ++ " = " ++ definition) | (name, definition) <- M.elems (stLiterals st) ]
      header = D.joinWith D.hardline (map D.text
        [ "// Generated by LawSpec. Do not edit."
        , "/// Typed checked definitions over the program's native types (see"
        , "/// docs/how-to/targets/fsharp.md). Each is named for its definition."
        , "module rec LawSpec.TypedProgram"
        , ""
        , "#nowarn \"25\""
        , ""
        , "open LawSpec.Runtime" ])
      source = D.render (D.Pretty 100) (header <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) (literals ++ docs)) ++ "\n"
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
  where
    functionName d = escapeFSharp (camel (shortName (declarationName (definitionDeclaration d)))) ++ "_" ++ stableSuffix (declarationId (definitionDeclaration d))
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

-- | A typed function's name in C#: its F# name, capitalized.
compiledName :: String -> String
compiledName name = case filter (/= '_') (take 1 name) of
  [c] | isLower c -> toEnum (fromEnum c - 32) : drop 1 name
  _ -> name

block :: [D.Doc] -> D.Doc
block body = D.nest 4 (D.hardline <> D.joinWith D.hardline body)

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

type Scope = [(Id, String)]

nativeType :: Env -> Type -> Either String String
nativeType env = Data.nativeType FSharp (envBits env) (envNames env) []

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (args, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  types <- lift' (mapM (nativeType env) args)
  resultType <- lift' (nativeType env result)
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure [x]
    Nothing -> cstmt env params (definitionBody d)
  let parameters = ["(schema: Schema.Schema) (symbols: Scalar.SymbolContext)" | contextual] ++
        ["(" ++ l ++ ": " ++ t ++ ")" | ((_, l), t) <- zip params types]
  pure (D.text ("/// " ++ idText (declarationId declaration)) <> D.hardline <>
    D.text ("[<CompiledName(\"" ++ compiledName name ++ "\")>]") <> D.hardline <>
    D.text ("let " ++ name ++ " " ++ (if null parameters then "()" else unwords parameters) ++ " : " ++ resultType ++ " =") <> block body)

-- | Lines whose last is the value.
cstmt :: Env -> Scope -> Expr -> M [D.Doc]
cstmt env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env ((binderId binder, local) : scope) body
    pure (s ++ [D.text ("let " ++ local ++ " = ") <> x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env scope a
    no <- cstmt env scope b
    pure (s ++ [D.text "if " <> x <> D.text " then" <> block yes <> D.hardline <> D.text "else" <> block no])
  Helper Select [c, a, b] -> cstmt env scope (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope value cases
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [x])

-- | An expression's value: the lines that compute it, and an atom.
cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> constant (expressionType e) s
  Local i -> do
    name <- lift' (maybe (Left ("typed F#: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], D.text name)
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
        let context = [[D.text "schema", D.text "symbols"] | isContextual (envPlan env) i]
            call = D.joinWith (D.text " ") (D.text (envFunctions env M.! c) : concat context ++ map (paren . snd) parts ++ [D.text "()" | null parts && null context])
        bindAtom (concatMap fst parts) call
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, paren (xa <> D.text (if op == And then " && " else " || ") <> xb))
      else do
        t <- fresh "logic"
        let rest = sb ++ [xb]
        pure (sa ++ [D.text ("let " ++ t ++ " =") <> block [D.text "if " <> xa <> D.text " then" <>
          (if op == And then block rest <> D.hardline <> D.text "else false"
           else block [D.text "true"] <> D.hardline <> D.text "else" <> block rest)]], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "(not " <> x <> D.text ")")
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    narrow (expressionType e) (s, D.text "(-" <> exact (expressionType a) x <> D.text ")")
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, paren (xa <> D.text (if op == Equal then " = " else " <> ") <> xb))
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
        native f = pure (sa ++ sb, D.text ("(Typed." ++ f ++ " " ++ show (typeName ta) ++ " ") <> xa <> D.text " " <> xb <> D.text ")")
        arithmetic r = narrow te (sa ++ sb, r)
        sameNative = same && te == ta && bounded
    case op of
      Add | sameNative -> native "add"
          | otherwise -> arithmetic (paren (ia <> D.text " + " <> ib))
      Subtract | sameNative -> native "subtract"
               | otherwise -> arithmetic (paren (ia <> D.text " - " <> ib))
      Multiply | sameNative -> native "multiply"
               | otherwise -> arithmetic (paren (ia <> D.text " * " <> ib))
      Quotient -> arithmetic (D.text "(Typed.quotient " <> ia <> D.text " " <> ib <> D.text ")")
      Remainder -> arithmetic (D.text "(Typed.remainder " <> ia <> D.text " " <> ib <> D.text ")")
      Power -> arithmetic (D.text "(Typed.power " <> ia <> D.text " " <> ib <> D.text ")")
      Equal -> compare' " = "
      NotEqual -> compare' " <> "
      Less -> compare' " < "
      LessEqual -> compare' " <= "
      Greater -> compare' " > "
      GreaterEqual -> compare' " >= "
      _ -> lift' (Left ("typed F#: unsupported operator " ++ show op))
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    convert target (expressionType value) (s, x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    ordering <- orderingOf env
    pure (sa ++ sb, D.text ("(" ++ ordering ++ " (Typed.compare ") <> xa <> D.text " " <> xb <> D.text "))")
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> D.text "(Typed.textLength " <> v <> D.text ")"
      Constructor "Bytes" [] -> D.text "(bigint (Array.length " <> v <> D.text "))"
      _ -> D.text "(bigint (List.length " <> v <> D.text "))")
  Helper Unreachable _ -> pure ([], D.text "(Typed.unreachable ())")
  Helper Checked _ -> pure ([], D.text "true")
  Helper StartsWith [a, b] -> call2 "Typed.startsWith" a b
  Helper EndsWith [a, b] -> call2 "Typed.endsWith" a b
  Helper TextContains [a, b] -> call2 "Typed.contains" a b
  Helper RegexMatches [a, b] -> call2 "Regex.matches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    item <- fresh (binderName binder)
    lines' <- cstmt env ((binderId binder, item) : scope) predicate
    t <- fresh "all"
    pure (sx ++ [D.text ("let " ++ t ++ " =") <> block [D.text ("List.forall (fun " ++ item ++ " ->") <> block lines' <> D.text ") " <> xs]], D.text t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    c <- lift' (codecOf env (expressionType x))
    result <- lift' (nativeType env (expressionType e))
    pure (s, D.text ("(Typed.raiseFailure " ++ stringLiteral FSharp (abilityKey ref) ++ " (" ++ c ++ ".FromNative ") <> v <> D.text (") : " ++ result ++ ")"))
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    a <- lift' (maybe (Left ("typed F#: unknown ability " ++ abilityKey (operationAbility op))) Right (N.abilityOf (envUnits env) (operationAbility op)))
    let native = "(LawSpec.Generated.Abilities." ++ Effects.bridgeName a "ToNative" ++ " schema symbols (Effects.handler schema " ++
          stringLiteral FSharp (abilityKey (operationAbility op)) ++ "))"
        call = D.text ("(" ++ native ++ "." ++ Effects.operationMember (operationName op) ++ "(") <> D.joinWith (D.text ", ") (map snd parts) <> D.text "))"
    invocation <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        c <- lift' (codecOf env failureType)
        pure (D.text ("(Typed.performed " ++ stringLiteral FSharp (abilityKey failing) ++ " " ++ c ++ ".FromNative ") <> call <> D.text ")")
      _ -> pure call
    bindAtom (concatMap fst parts) invocation
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    c <- lift' (codecOf env failure)
    lines' <- cstmt env scope body
    t <- fresh "attempted"
    pure ([D.text ("let " ++ t ++ " =") <> block [D.text ("Typed.attempt " ++ stringLiteral FSharp (abilityKey ref) ++ " " ++ c ++ ".ToNative (fun () ->") <>
      block lines' <> D.text ")"]], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor "Text" [] -> infixOp " + " a b
    Constructor "Bytes" [] -> call2 "Array.append" a b
    _ -> infixOp " @ " a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "Typed.sliceText"
          Constructor "Bytes" [] -> "Typed.sliceBytes"
          _ -> "Typed.sliceList"
    pure (sx ++ si ++ sj, D.text ("(" ++ f ++ " ") <> v <> D.text " " <> exact (expressionType from) i <> D.text " " <> exact (expressionType to) j <> D.text ")")
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = if expressionType x == Constructor "Bytes" [] then "Typed.atBytes" else "Typed.atList"
    pure (sx ++ sk, D.text ("(" ++ f ++ " ") <> v <> D.text " " <> exact (expressionType k) i <> D.text ")")
  Helper Range [lo, hi] -> do
    (sl, l) <- cexpr env scope lo
    (sh, h) <- cexpr env scope hi
    let element = case expressionType e of Constructor "List" [TypeArgument t] -> t; t -> t
        back = case element of
          Constructor n [] | Just f <- lookup n plainConversion -> " |> List.map " ++ f
          _ -> ""
    pure (sl ++ sh, D.text "(Typed.range " <> exact (expressionType lo) l <> D.text " " <> exact (expressionType hi) h <> D.text (back ++ ")"))
  Helper Octets [b] -> one "Array.toList" b
  Helper BytesOf [xs] -> one "Array.ofList" xs
  Helper Utf8 [t] -> one "Typed.utf8" t
  Helper TextOf [n] -> do
    (s, x) <- cexpr env scope n
    pure (s, D.text "(Typed.textOf " <> exact (expressionType n) x <> D.text ")")
  Helper Join [sep, parts] -> call2 "Typed.join" sep parts
  _ -> lift' (Left ("typed F#: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, D.text ("(" ++ f ++ " ") <> x <> D.text ")")
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text ("(" ++ f ++ " ") <> xa <> D.text " " <> xb <> D.text ")")
    infixOp op a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, paren (xa <> D.text op <> xb))
    viaStatements = do
      t <- fresh "value"
      lines' <- cstmt env scope e
      pure ([D.text ("let " ++ t ++ " =") <> block lines'], D.text t)
    -- A call is bound to a local, so effects keep their order.
    bindAtom s call = do
      t <- fresh "result"
      pure (s ++ [D.text ("let " ++ t ++ " = ") <> call], D.text t)

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
exact :: Type -> D.Doc -> D.Doc
exact ty x = if ty == Constructor "Integer" [] then x else D.text "(bigint " <> x <> D.text ")"

-- | A bigint result into the expression's type, checked.
narrow :: Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
narrow ty (s, x) = case ty of
  Constructor t [] | t `elem` boundedTypes -> pure (s, D.text ("(Typed." ++ checkedName t ++ " ") <> x <> D.text ")")
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

convert :: Type -> Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
convert target source (s, x)
  | target == source = pure (s, x)
  | target == Constructor "Integer" [] = pure (s, exact source x)
  | Constructor t [] <- target, Just (lo, hi) <- boundsOf t, Just f <- lookup t plainConversion =
      let inside = case source of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, D.text ("(" ++ f ++ " ") <> x <> D.text ")")
         else narrow target (s, exact source x)
  | otherwise = pure (s, x)

constant :: Type -> Scalar -> M ([D.Doc], D.Doc)
constant _ s = case s of
  SBool b -> pure ([], D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure ([], D.text "()")
  SInteger t n -> pure ([], D.text (integerLiteral t n))
  SSequence "Text" units -> do
    name <- literal ("text " ++ show units) ("Scalar.textOfPoints " ++ listLiteral (map show units))
    pure ([], D.text name)
  SSequence "Bytes" units -> do
    name <- literal ("bytes " ++ show units) ("[| " ++ intercalate "; " [show u ++ "uy" | u <- units] ++ " |]")
    pure ([], D.text name)
  _ -> lift' (Left ("typed F#: unsupported constant " ++ show s))
  where listLiteral xs = "[ " ++ intercalate "; " xs ++ " ]"

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
-- collection made from its items.
construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "[]")
  ("List::Cons", [h, t]) -> pure (paren (h <> D.text " :: " <> t))
  ("Maybe::Nothing", []) -> pure (D.text "None")
  ("Maybe::Just", [x]) -> pure (D.text "(Some " <> x <> D.text ")")
  ("Either::Left", [x]) -> pure (D.text "(LawSpec.Either.Left " <> x <> D.text ")")
  ("Either::Right", [x]) -> pure (D.text "(LawSpec.Either.Right " <> x <> D.text ")")
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    entry <- entryType env
    pure (D.text ("(Typed.keyValOf (fun (e: " ++ entry ++ ") -> e.Key) (fun (e: " ++ entry ++ ") -> e.Value) ") <> items <> D.text ")")
  (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (D.text "(Set.ofList " <> items <> D.text ")")
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c) -> do
      typeText <- lift' (nativeType env ty)
      let typeRef = "LawSpec.Data." ++ dataNameOf env d
      pure $ if isRecord d
        then D.text "({ " <> D.joinWith (D.text "; ") [D.text (pascal (binderName b) ++ " = ") <> v | (b, v) <- zip (constructorFields c) values] <>
          D.text (" } : " ++ typeText ++ ")")
        else if null values then D.text (typeRef ++ "." ++ pascal (constructorName c))
        else D.text (typeRef ++ "." ++ pascal (constructorName c) ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")"
    Nothing -> lift' (Left ("typed F#: unknown constructor " ++ idText tag))

dataNameOf :: Env -> DataDeclaration -> String
dataNameOf env d = maybe (dataName d) id (lookup (dataId d) (envNames env))

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

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, _)]) -> do
    entry <- entryType env
    pure (D.text ("(Typed.keyValOf (fun (e: " ++ entry ++ ") -> e.Key) (fun (e: " ++ entry ++ ") -> e.Value) ") <> es <> D.text ")")
  (KeyValLookup, [(k, _), (m, _)]) -> apply "Map.tryFind" [k, m]
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> apply "Map.add" [k, v, m]
  (KeyValDelete, [(k, _), (m, _)]) -> apply "Map.remove" [k, m]
  (KeyValKeys, [(m, _)]) -> apply "Typed.keys" [m]
  (KeyValValues, [(m, _)]) -> apply "Typed.values" [m]
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryType env
    pure (D.text ("(Typed.entries (fun k v -> ({ Key = k; Value = v } : " ++ entry ++ ")) ") <> m <> D.text ")")
  (SetOf, [(xs, _)]) -> apply "Set.ofList" [xs]
  (SetMember, [(x, _), (s, _)]) -> apply "Set.contains" [x, s]
  (SetInsert, [(x, _), (s, _)]) -> apply "Set.add" [x, s]
  (SetRemove, [(x, _), (s, _)]) -> apply "Set.remove" [x, s]
  (SetUnion, [(s, _), (t, _)]) -> apply "Set.union" [s, t]
  (SetIntersection, [(s, _), (t, _)]) -> apply "Set.intersect" [s, t]
  (SetDifference, [(s, _), (t, _)]) -> apply "Set.difference" [s, t]
  _ -> lift' (Left ("typed F#: bad intrinsic " ++ show intrinsic))
  where apply f xs = pure (D.text ("(" ++ f ++ " ") <> D.joinWith (D.text " ") xs <> D.text ")")

entryType :: Env -> M String
entryType env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d -> pure ("LawSpec.Data." ++ dataNameOf env d ++ "<_, _>")
  Nothing -> lift' (Left "typed F#: no typed Entry")

matchStatements :: Env -> Scope -> Expr -> [MatchCase] -> M [D.Doc]
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
        body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
        pure (D.text ("| " ++ pattern' (map snd bound) ++ " ->") <> block body)
      unreachableArm = D.text "| _ -> Typed.unreachable ()"
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], D.text name)
    _ -> cexpr env scope value
  arms <- case ty of
    Constructor n _ | n `elem` ["Maybe", "Either", "List"] -> do
      arms <- forM cases $ \c -> alternative c (\names -> case (idText (caseConstructor c), names) of
        ("Maybe::Nothing", _) -> "None"
        ("Maybe::Just", [x]) -> "Some " ++ x
        ("Either::Left", [x]) -> "LawSpec.Either.Left " ++ x
        ("Either::Right", [x]) -> "LawSpec.Either.Right " ++ x
        ("List::Nil", _) -> "[]"
        ("List::Cons", [h, t]) -> h ++ " :: " ++ t
        _ -> "_")
      pure (arms ++ [unreachableArm | length cases < 2])
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          bound <- binders c
          body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
          entry <- if kind == "KeyVal" then Just <$> entryType env else pure Nothing
          let items = case entry of
                Just e -> "(Typed.entries (fun k v -> ({ Key = k; Value = v } : " ++ e ++ ")) subject)"
                Nothing -> "(Set.toList subject)"
              binding = case bound of
                [(_, n')] | n' /= "_" -> [D.text ("let " ++ n' ++ " = " ++ items)]
                _ -> []
          pure [D.text "| subject ->" <> block (binding ++ body)]
    Constructor n _ | Just d <- M.lookup n (envData env) ->
      if isRecord d
        then case cases of
          [c] -> do
            bound <- binders c
            body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
            let ctor = snd (envConstructors env M.! caseConstructor c)
                fields = [D.text ("let " ++ name ++ " = subject." ++ pascal (binderName b)) | ((_, name), b) <- zip bound (constructorFields ctor), name /= "_"]
            pure [D.text "| subject ->" <> block (fields ++ body)]
          _ -> lift' (Left "typed F#: a record has one constructor")
        else do
          let typeRef = "LawSpec.Data." ++ dataNameOf env d
          arms <- forM cases $ \c -> alternative c (\names ->
            let caseName = typeRef ++ "." ++ pascal (constructorName (snd (envConstructors env M.! caseConstructor c)))
            in if null names then caseName else caseName ++ "(" ++ intercalate ", " names ++ ")")
          pure (arms ++ [unreachableArm | length cases < length (dataConstructors d)])
    _ -> lift' (Left ("typed F#: cannot match on " ++ show ty))
  pure (prelude ++ [D.text "match " <> subject <> D.text " with" <> D.hardline <> D.joinWith D.hardline arms])

