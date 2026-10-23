-- | Typed expression documents shared by Python properties and source definitions.
module LawSpec.PythonExpr (renderExpression, renderExpressionBody, renderExpressionWithContext, renderExpressionWithContextAt, literalValue, call, array, quoted, typeKey, suite, lambdaExpression, appliedLambda, scalarLiteral, optionalParentheses, bytesLiteral, pythonReserved, handlerSchemaCall, tuple) where

import LawSpec.Core
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.Backend as Backend
import qualified LawSpec.PythonTypes as Native
import qualified LawSpec.Code.Doc as D
import Data.Aeson (encode)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.Char (chr, ord)
import Numeric (showHex)
import LawSpec.Code.Literal (literalFor)
import LawSpec.Naming (claim, scopeWith, localIdentifier, reservedFor)

-- | Strings are Python string literals, escaped once by LawSpec's table for
-- Python, so no generated literal can end early or change meaning. A literal
-- is one token: ruff never splits one, and neither does LawSpec.
quoted :: String -> D.Doc
quoted = D.text . literalFor "python"

-- | A bytes literal: printable ASCII as it is, the rest as escapes, quoted as
-- ruff quotes it.
bytesLiteral :: [Int] -> D.Doc
bytesLiteral values = D.text ("b" ++ [quote] ++ concatMap escape values ++ [quote])
  where
    quote = if length (filter (== 34) values) > length (filter (== 39) values) then '\'' else '"'
    escape n
      | n == ord quote || n == 92 = ['\\', chr n]
      | n == 10 = "\\n"
      | n == 13 = "\\r"
      | n == 9 = "\\t"
      | n >= 32 && n < 127 = [chr n]
      | otherwise = "\\x" ++ (if n < 16 then "0" else "") ++ showHex n ""

-- | A call through the handler schema: ls.handler_schema(_lawspec_schema).name(...).
handlerSchemaCall :: String -> [D.Doc] -> D.Doc
handlerSchemaCall name args = call "ls.handler_schema" [D.text "_lawspec_schema"] <> D.text "." <> call name args

-- | A tuple; a one-tuple keeps its comma however it breaks.
tuple :: [D.Doc] -> D.Doc
tuple [] = D.text "()"
tuple [x] = D.group (D.text "(" <> D.nest 4 (D.softbreak <> x <> D.text ",") <> D.softbreak <> D.text ")")
tuple xs = D.delimitTrailing 4 "(" ")" xs

-- | Names generated Python code keeps for itself.
pythonReserved :: [String]
pythonReserved = reservedFor "python"

-- | Arguments wrap when a call is too wide, in the Python style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 4 "(" ")" (map D.argument args)

-- | Lists of runtime values are written in one shape so they wrap like calls.
array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 4 "[" "]"

-- | Python blocks are a colon and an indented body, four spaces as PEP 8 asks.
-- ref:pep-8
suite :: D.Doc -> D.Doc -> D.Doc
suite header body = header <> D.text ":" <> D.nest 4 (D.hardline <> body)

-- | Parentheses provide legal breaks after a lambda header and around its body.
parenthesized :: D.Doc -> D.Doc
parenthesized value = D.group (D.text "(" <> D.nest 4
  (D.softbreak <> value) <> D.softbreak <> D.text ")")

-- | A lambda's body is parenthesised only when it must break, as ruff
-- writes it; a call breaks inside its own parentheses instead.
lambdaExpression :: [D.Doc] -> D.Doc -> D.Doc
lambdaExpression parameters body = D.group (
  D.text (if null parameters then "lambda" else "lambda ") <>
  D.joinWith (D.text ", ") parameters <> D.text ": " <> D.lambdaBody body)

-- | A parenthesised lambda applied to arguments, Python's let: the lambda
-- moves onto its own lines when it breaks, then the arguments.
appliedLambda :: D.Doc -> [D.Doc] -> D.Doc
appliedLambda lambda arguments =
  D.group (D.text "(" <> D.nest 4 (D.softbreak <> lambda) <> D.softbreak <> D.text ")") <>
  D.delimitTrailing 4 "(" ")" arguments

-- | Parentheses that appear only when their contents break: ruff's optional
-- parentheses around a lambda body, a return value or an assignment.
optionalParentheses :: D.Doc -> D.Doc
optionalParentheses value = D.group (D.whenBroken (D.text "(") <> D.nest 4
  (D.softbreak <> D.group value) <> D.softbreak <> D.whenBroken (D.text ")"))

-- | Runtime calls name a value's type by the key the portable runtime uses.
typeKey :: Type -> String
typeKey = Backend.scalarTypeKey

-- | Render the tagged wire value as Python syntax so fields can wrap naturally.
-- Strings remain opaque quoted tokens; raw Unicode travels as integer arrays.
literalValue :: A.Value -> D.Doc
literalValue value = case value of
  A.Object fields -> D.delimitTrailing 4 "{" "}"
    [quoted (Key.toString key) <> D.text ": " <> literalValue item | (key,item) <- KeyMap.toAscList fields]
  A.Array values -> array (map literalValue (toList values))
  A.String valueText -> quoted (T.unpack (T.fromStrict valueText))
  A.Number number -> D.text (T.unpack (T.decodeUtf8 (encode number)))
  A.Bool valueBool -> D.text (if valueBool then "True" else "False")
  A.Null -> D.text "None"

-- | Faithful native literals keep deeply nested examples readable. Other scalar
-- encodings still go through the runtime's lossless tagged decoder.
scalarLiteral :: Scalar -> D.Doc
scalarLiteral value = case value of
  -- Python's own limit on decimal integer literals is 4300 digits.
  SInteger _ n | length (show n) <= 4000 -> D.text (show n)
  SInteger _ n -> call "ls.integer_literal" [quoted (show n)]
  SCharacter kind n | kind `elem` ["CodePoint", "CodeUnit16"] -> D.text (show n)
  SCharacter "Char" n -> quoted [chr n]
  SBool b -> D.text (if b then "True" else "False")
  SSequence "Text" values -> quoted (map chr values)
  SSequence "Bytes" values -> bytesLiteral values
  _ -> call "ls.literal" [literalValue (A.toJSON value),D.text "symbols"]

-- | Expressions are rendered from Core, never from source, so the Python tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations _ = renderExpressionWithContext declarations
  (D.text "MACHINE_BITS") Native.pythonTypeReferenceDoc (Right . quoted . typeKey)

-- | As renderExpression, for a lambda's body, a return value or an
-- assignment, where ruff drops redundant parentheses.
renderExpressionBody :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionBody declarations _ = renderExpressionWithContextAt True declarations
  (D.text "MACHINE_BITS") Native.pythonTypeReferenceDoc (Right . quoted . typeKey)

-- | Schema callbacks use instantiated type references and a runtime width.
-- Ordinary definitions/properties keep the same renderer with closed types.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderExpressionWithContext = renderExpressionWithContextAt False

renderExpressionWithContextAt :: Bool -> [DataDeclaration] -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderExpressionWithContextAt atBody declarations width reference key outerLocal external root =
  if atBody then renderBody root else render root
  where
    bound = collect root
    boundIds = map binderId bound
    boundSet = Set.fromList boundIds
    collect term = (case expressionNode term of
      AllElements _ binder _ -> [binder]
      AllPayloads _ predicates -> map fst predicates
      Match _ cases -> concatMap caseBinders cases
      Let binder _ _ -> [binder]
      _ -> []) ++ concatMap collect (children term)
    occupied = Set.fromList [outerLocal identity | term <- descendants root,
      Local identity <- [expressionNode term], identity `Set.notMember` boundSet]
    descendants term = term : concatMap descendants (children term)
    -- Bound names are their source names, made distinct from each other and
    -- from the free names the term uses, in traversal order; repeated binder
    -- identities in disjoint finite-search branches share the first name.
    names = snd (foldl allocate (scopeWith (Set.toList occupied ++ pythonReserved), Map.empty) bound)
    allocate (scope, table) binder
      | Map.member (binderId binder) table = (scope, table)
      | otherwise = let (chosen, scope') = claim scope (localIdentifier "python" (binderName binder))
                    in (scope', Map.insert (binderId binder) chosen table)
    local identity = Map.findWithDefault (outerLocal identity) identity names
    runtime name = call ("ls." ++ name)
    schema name arguments = call ("_lawspec_schema." ++ name)
      (arguments ++ [D.text "symbols"])
    structural ty = Native.requiresSchema declarations ty || variable ty
    variable (TypeVariable _) = True
    variable (Constructor _ args) = any (\arg -> case arg of TypeArgument ty -> variable ty; _ -> False) args
    variable (Arrow a b) = variable a || variable b
    checked ty value
      | structural ty = do
          ref <- reference ty
          pure (schema "validate" [ref,value,width])
      | otherwise = do
          target <- key ty
          pure (runtime "convert" [value,target,width])
    render term
      -- An all group's steps run side by side, each on a thread of its own.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM renderBody fields
          inner <- renderBody body
          pure (appliedLambda (lambdaExpression (map (D.text . local . binderId) binders) inner)
            [D.text "*" <> runtime "concurrently" [array (map (lambdaExpression []) steps)]])
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) ->
          lambdaExpression [D.text (local (binderId binder))] <$> renderBody predicate) predicates
        pure (schema "all_payloads" [ref,argument,array callbacks,width])
      AllElements value binder predicate -> do
        argument <- render value
        body <- renderBody predicate
        pure (runtime "all_elements" [argument,
          lambdaExpression [D.text (local (binderId binder))] body])
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- renderBody body
        pure (appliedLambda (lambdaExpression [D.text (local (binderId binder))] inner) [argument])
      -- A constant Core admitted is already in its type's domain.
      Constant value | plainConstant (expressionType term) value -> pure (scalarLiteral value)
      Constant value -> checked (expressionType term) (scalarLiteral value)
      Construct tag args -> do
        values <- mapM render args
        if structural (expressionType term) then do
          ref <- reference (expressionType term)
          pure (schema "construct" [ref,quoted (idText tag),array values,width])
        else pure (runtime "construct" [quoted (idText tag),array values])
      Match value branches -> do
        argument <- render value
        cases <- mapM branch branches
        if structural (expressionType value) then do
          ref <- reference (expressionType value)
          pure (schema "match" [ref,argument,array cases,width])
        else pure (runtime "match_value" [argument,array cases])
      ExternalCall _ args -> mapM render args >>= external term
      -- Ability nodes go to the caller, which knows where handlers are.
      Perform _ args -> mapM render args >>= external term
      Handle _ body -> render body >>= external term . pure
      Calls _ args -> mapM render (maybe [] id args) >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument -> checked target argument
          Explicit -> do
            destination <- key target
            source <- key (expressionType value)
            pure (runtime "helper" [destination,array [argument],array [source],width])
      If {} -> D.parens <$> bare term
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (D.operation [left, right] [if op == And then "and" else "or"])
      Unary Not a -> do
        value <- render a
        pure (D.parens (D.prefixed "not" value))
      Unary Negate a -> do
        value <- render a
        source <- key (expressionType a)
        pure (runtime "helper" [quoted "negate",array [value],array [source],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) && op `elem` [Equal,NotEqual] then do
          ref <- reference (expressionType a)
          let equality = schema "equal" [ref,left,right,width]
          pure (if op == NotEqual then D.parens (D.prefixed "not" equality) else equality)
        else do
          leftType <- key (expressionType a)
          rightType <- key (expressionType b)
          pure (runtime "binary" [quoted (binaryName op),left,right,leftType,rightType])
      Helper Concurrently [value] -> render value
      Helper Recorded [keyValue,value] | structural (expressionType value) -> do
        name <- render keyValue
        argument <- render value
        ref <- reference (expressionType value)
        pure (schema "recorded" [ref,name,argument,width])
      Helper builtin args -> do
        values <- mapM render args
        types <- mapM (key . expressionType) args
        pure (runtime "helper" [quoted (builtinName builtin),array values,array types,width])
    -- A conditional or boolean operator without its parentheses.
    bare term = case expressionNode term of
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (yes <> D.softline <> D.text "if " <> condition <> D.softline <> D.text "else " <> no)
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (left <> D.softline <> D.text (if op == And then "and " else "or ") <> right)
      _ -> render term
    -- A lambda's body: ruff drops parentheses there unless the body breaks.
    renderBody term = case expressionNode term of
      If {} -> D.parens <$> bare term
      ShortCircuit {} -> render term
      Unary Not a -> D.prefixed "not" <$> render a
      _ -> render term
    plainConstant ty value = case (ty, value) of
      (Constructor t [], SInteger s _) -> t == s
      (Constructor "Bool" [], SBool _) -> True
      (Constructor t [], SSequence s _) -> t == s && t `elem` ["Text", "Bytes"]
      (Constructor t [], SCharacter s _) -> t == s && t `elem` ["Char", "CodePoint", "CodeUnit16"]
      _ -> False
    branch matched = do
      body <- renderBody (caseBody matched)
      let parameters = map (D.text . local . binderId) (caseBinders matched)
      pure (array [quoted (idText (caseConstructor matched)),lambdaExpression parameters body])
