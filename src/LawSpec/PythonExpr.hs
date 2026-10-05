-- Typed expression documents shared by Python properties and source definitions.
module LawSpec.PythonExpr (renderExpression, renderExpressionWithContext, literalValue, call, array, quoted, typeKey, suite, lambdaExpression, scalarLiteral) where

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
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

quoted :: String -> D.Doc
quoted value = D.prefixChoice (encodeToken value) (token value)
  (parenthesized (D.joinWith D.softline (map token (chunks value))))
  where
    encodeToken = T.unpack . T.decodeUtf8 . encode
    token = D.text . encodeToken
    chunks [] = []
    chunks rest = take 4 rest : chunks (drop 4 rest)

call :: String -> [D.Doc] -> D.Doc
call name args = D.text name <> D.delimitTrailing 4 "(" ")" args

array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 4 "[" "]"

suite :: D.Doc -> D.Doc -> D.Doc
suite header body = header <> D.text ":" <> D.nest 4 (D.hardline <> body)

-- Parentheses provide legal breaks after a lambda header and around its body.
parenthesized :: D.Doc -> D.Doc
parenthesized value = D.group (D.text "(" <> D.nest 4
  (D.softbreak <> value) <> D.softbreak <> D.text ")")

lambdaExpression :: [D.Doc] -> D.Doc -> D.Doc
lambdaExpression parameters body = D.group (
  D.text (if null parameters then "lambda" else "lambda ") <>
  D.commaSep parameters <> D.text ": " <> parenthesized body)

typeKey :: Type -> String
typeKey = Backend.scalarTypeKey

-- Render the tagged wire value as Python syntax so fields can wrap naturally.
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

-- Faithful native literals keep deeply nested examples readable. Other scalar
-- encodings still go through the runtime's lossless tagged decoder.
scalarLiteral :: Scalar -> D.Doc
scalarLiteral value = case value of
  SInteger _ n | length (show n) <= 12 -> D.text (show n)
  SInteger _ n -> call "ls.integer_literal" [quoted (show n)]
  SCharacter kind n | kind `elem` ["CodePoint", "CodeUnit16"] -> D.text (show n)
  SBool b -> D.text (if b then "True" else "False")
  SSequence "Bytes" values -> call "ls.bytes_literal" [array (map (D.text . show) values)]
  _ -> call "ls.literal" [literalValue (A.toJSON value),D.text "symbols"]

renderExpression :: [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits = renderExpressionWithContext declarations
  (D.text (show bits)) Native.pythonTypeReferenceDoc (Right . quoted . typeKey)

-- Schema callbacks use instantiated type references and a runtime width.
-- Ordinary definitions/properties keep the same renderer with closed types.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderExpressionWithContext declarations width reference key outerLocal external root = render root
  where
    boundIds = collect root
    collect term = (case expressionNode term of
      AllElements _ binder _ -> [binderId binder]
      AllPayloads _ predicates -> map (binderId . fst) predicates
      Match _ cases -> concatMap (map binderId . caseBinders) cases
      _ -> []) ++ concatMap collect (children term)
    occupied = [outerLocal identity | term <- descendants root,
      Local identity <- [expressionNode term], identity `notElem` boundIds]
    descendants term = term : concatMap descendants (children term)
    names = zip boundIds (filter (`notElem` occupied)
      ["_m" ++ show i | i <- [0 :: Int ..]])
    local identity = maybe (outerLocal identity) id (lookup identity names)
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
          steps <- mapM render fields
          inner <- render body
          pure (D.text "(" <> lambdaExpression (map (D.text . local . binderId) binders) inner <> D.text ")(*" <>
            runtime "concurrently" [array (map (lambdaExpression []) steps)] <> D.text ")")
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) ->
          lambdaExpression [D.text (local (binderId binder))] <$> render predicate) predicates
        pure (schema "all_payloads" [ref,argument,array callbacks,width])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (runtime "all_elements" [argument,
          lambdaExpression [D.text (local (binderId binder))] body])
      Local identity -> pure (D.text (local identity))
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
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (parenthesized (yes <> D.softline <> D.text "if " <> condition <> D.softline <> D.text "else " <> no))
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (parenthesized (left <> D.softline <>
          D.text (if op == And then "and " else "or ") <> right))
      Unary Not a -> do
        value <- render a
        pure (D.text "(not " <> value <> D.text ")")
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
          pure (if op == NotEqual then D.text "(not " <> equality <> D.text ")" else equality)
        else do
          leftType <- key (expressionType a)
          rightType <- key (expressionType b)
          pure (runtime "binary" [quoted (binaryName op),left,right,leftType,rightType])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        types <- mapM (key . expressionType) args
        pure (runtime "helper" [quoted (builtinName builtin),array values,array types,width])
    branch matched = do
      body <- render (caseBody matched)
      let parameters = map (D.text . local . binderId) (caseBinders matched)
      pure (array [quoted (idText (caseConstructor matched)),lambdaExpression parameters body])
