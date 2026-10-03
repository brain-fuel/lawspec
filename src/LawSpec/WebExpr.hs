-- Checked Core expression documents shared by JS/TS definitions and properties.
module LawSpec.WebExpr (renderAsyncExpression, renderExpression, renderExpressionWithContext, literalValue, call, array, quoted, quotedValue) where

import LawSpec.Core
import qualified LawSpec.Backend as Backend
import qualified LawSpec.WebTypes as Native
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.JavaScript as JS
import qualified Data.Text as Text
import Data.Aeson (encode)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

quoted :: String -> D.Doc
quoted = JS.quoted

quotedValue :: String -> D.Doc
quotedValue = JS.stringExpression

call :: String -> [D.Doc] -> D.Doc
call name values = D.text name <> D.delimitTrailing 4 "(" ")" values

array :: [D.Doc] -> D.Doc
array = D.delimitTrailing 2 "[" "]"

literalValue :: A.Value -> D.Doc
literalValue value = case value of
  A.Object fields -> D.delimitTrailing 2 "{" "}"
    [D.hang 4 (quoted (Key.toString key) <> D.text ":") (literalValue item) | (key,item) <- KeyMap.toAscList fields]
  A.Array values -> array (map literalValue (toList values))
  A.String string -> quotedValue (Text.unpack string)
  _ -> D.text (T.unpack (T.decodeUtf8 (encode value)))

renderExpression :: Bool -> [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression ts declarations bits = renderExpressionWithContext ts declarations
  (D.text (show bits)) Native.webTypeReferenceDoc (pure . quoted . Backend.scalarTypeKey)

-- In an async function: a match's branches are async, and the match is
-- awaited, so a branch may await an asynchronous call.
renderAsyncExpression :: Bool -> [DataDeclaration] -> Int -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderAsyncExpression ts declarations bits = renderWith True ts declarations
  (D.text (show bits)) Native.webTypeReferenceDoc (pure . quoted . Backend.scalarTypeKey)

renderExpressionWithContext :: Bool -> [DataDeclaration] -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderExpressionWithContext = renderWith False

renderWith :: Bool -> Bool -> [DataDeclaration] -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderWith asynchronous ts declarations width reference key local external = render
  where
    runtime name = call ("ls." ++ name)
    schema name args = call ("_lawspec_schema." ++ name) (args ++ [D.text "symbols"])
    structural (TypeVariable _) = True
    structural ty = Native.requiresSchema declarations ty
    checked ty value
      | structural ty = do
          ref <- reference ty
          pure (schema "validate" [ref,value,width])
      | otherwise = do
          target <- key ty
          pure (runtime "convert" [value,target,width])
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          let parameter = D.text (local (binderId binder)) <>
                (if ts then D.group (D.text ":" <> D.nest 4 (D.softline <> D.text "unknown")) else mempty)
          pure (D.delimitTrailing 4 "(" ")" [parameter] <> D.text " => " <> body)) predicates
        pure (schema "allPayloads" [ref,argument,array callbacks,width])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        let parameter = D.text (local (binderId binder)) <>
              (if ts then D.group (D.text ":" <> D.nest 4 (D.softline <> D.text "unknown")) else mempty)
        pure (runtime "allElements" [argument,
          D.delimitTrailing 4 "(" ")" [parameter] <> D.text " => " <> body])
      Local identity -> pure (D.text (local identity))
      Constant value -> checked (expressionType term) (runtime "literal"
        [literalValue (A.toJSON value),D.text "symbols"])
      Construct tag args -> do
        values <- mapM render args
        if structural (expressionType term) then do
          ref <- reference (expressionType term)
          pure (schema "construct" [ref,quoted (idText tag),array values,width])
        else pure (runtime "construct" [quoted (idText tag),array values])
      Match value branches -> do
        argument <- render value
        cases <- mapM branch branches
        ref <- reference (expressionType value)
        let matched = schema "match" [ref,argument,array cases,width]
        pure (if asynchronous then D.text "(await " <> matched <> D.text ")" else matched)
      ExternalCall _ args -> mapM render args >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument -> checked target argument
          Explicit -> do
            targetKey <- key target
            sourceKey <- key (expressionType value)
            pure (runtime "helper" [targetKey,array [argument],array [sourceKey],width])
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (D.group (D.text "(" <> D.nest 4 (left <> D.text (if op == And then " &&" else " ||") <>
          D.softline <> right) <> D.text ")"))
      Unary Not a -> do
        value <- render a
        pure (D.text "(!" <> value <> D.text ")")
      Unary Negate a -> do
        value <- render a
        operand <- key (expressionType a)
        pure (runtime "helper" [quoted "negate",array [value],array [operand],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) && op `elem` [Equal,NotEqual] then do
          ref <- reference (expressionType a)
          let equality = schema "equal" [ref,left,right,width]
          pure (if op == NotEqual then D.text "(!" <> equality <> D.text ")" else equality)
        else do
          leftKey <- key (expressionType a)
          rightKey <- key (expressionType b)
          pure (runtime "binary" [quoted (binaryName op),left,right,leftKey,rightKey])
      Helper builtin args -> do
        values <- mapM render args
        keys <- mapM (key . expressionType) args
        pure (runtime "helper" [quoted (builtinName builtin),array values,array keys,width])
    branch matched = do
      body <- render (caseBody matched)
      let parameters = [D.text (local (binderId binder)) <>
            (if ts then D.group (D.text ":" <> D.nest 4 (D.softline <> D.text "unknown")) else mempty) | binder <- caseBinders matched]
      pure (array [quoted (idText (caseConstructor matched)),
        D.text (if asynchronous then "async " else "") <> D.delimitTrailing 4 "(" ")" parameters <> D.text " => " <> body])
