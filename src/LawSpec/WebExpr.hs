-- | Checked Core expressions as JavaScript syntax, shared by JS/TS
-- definitions and properties. Binders keep their source names, text and
-- other plain constants are native literals, and the machine width is the
-- module's MACHINE_BITS. ref:DEC-readable-generated-names
-- ref:DEC-native-string-literals
module LawSpec.WebExpr
  ( renderAsyncExpression, renderExpression, renderExpressionWithContext, literalValue, scalarLiteral
  , plainConstant, machineBits, machineBitsDeclaration, bindingNames, webReserved
  ) where

import LawSpec.Core
import LawSpec.Core.ListLiteral (constantListElements)
import qualified LawSpec.Backend as Backend
import qualified LawSpec.WebTypes as Native
import qualified LawSpec.Code.ECMAScript as E
import LawSpec.Naming (claim, scopeWith, localIdentifier, reservedFor)
import LawSpec.Scalar (Scalar(..), isInteger)
import qualified Data.Text as Text
import Data.Aeson (encode)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import Data.Char (chr)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

-- | The machine profile's integer width, named once per module.
machineBits :: E.Expr
machineBits = E.Ident "MACHINE_BITS"

machineBitsDeclaration :: Int -> [E.Stmt]
machineBitsDeclaration bits =
  [E.Comment ["// The machine profile's integer width."], E.constDecl "MACHINE_BITS" (E.num (toInteger bits))]

-- | Names generated JavaScript keeps for itself.
webReserved :: [String]
webReserved = reservedFor "javascript" ++ words "MACHINE_BITS symbols caseIndex caseValues _lawspec_schema _definitions _abilities _harness _typed"

-- | Wire values are written as JavaScript object literals.
literalValue :: A.Value -> E.Expr
literalValue value = case value of
  A.Object fields -> E.Object [E.Prop (E.KString (Key.toString key)) (literalValue item) | (key,item) <- KeyMap.toAscList fields]
  A.Array values -> E.Array (map literalValue (toList values))
  A.String string -> E.Str (Text.unpack string)
  A.Bool b -> E.BoolLit b
  A.Null -> E.Null
  _ -> E.Num (T.unpack (T.decodeUtf8 (encode value)))

-- | A plain scalar's native value, as the portable runtime holds it: small
-- integers are numbers, wider ones BigInts, text and characters strings.
scalarLiteral :: Scalar -> Maybe E.Expr
scalarLiteral value = case value of
  SBool b -> Just (E.BoolLit b)
  SInteger t n
    | t `elem` ["Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32"] -> Just (E.num n)
    | isInteger t -> Just (if n < 0 then E.Unary "-" (E.BigIntLit (show (negate n))) else E.BigIntLit (show n))
  SSequence "Text" xs -> Just (E.Str (map chr xs))
  SCharacter "Char" c -> Just (E.Str [chr c])
  SCharacter t c | t `elem` ["CodePoint", "CodeUnit16"] -> Just (E.num (toInteger c))
  SSequence "Bytes" xs -> Just (E.New (E.Ident "Uint8Array") [] [E.Array (map (E.num . toInteger) xs)])
  _ -> Nothing

-- | A constant whose type is its scalar's own, which Core has admitted, so
-- it is in its type's domain and needs no conversion.
plainConstant :: Type -> Scalar -> Bool
plainConstant ty value = case (ty, value) of
  (Constructor t [], SInteger s _) -> t == s
  (Constructor "Bool" [], SBool _) -> True
  (Constructor t [], SSequence s _) -> t == s && t `elem` ["Text", "Bytes"]
  (Constructor t [], SCharacter s _) -> t == s && t `elem` ["Char", "CodePoint", "CodeUnit16"]
  _ -> False

-- | Each binder's source name, distinct from the others and from the free
-- names, in order; a repeated identity keeps its first name.
bindingNames :: [String] -> [Binder] -> Map.Map Id String
bindingNames taken binders = snd (foldl allocate (scopeWith (taken ++ webReserved), Map.empty) binders)
  where
    allocate (scope, table) binder
      | Map.member (binderId binder) table = (scope, table)
      | otherwise = let (chosen, scope') = claim scope (localIdentifier "javascript" (binderName binder))
                    in (scope', Map.insert (binderId binder) chosen table)

-- | Expressions are rendered from Core, never from source, so the JavaScript
-- tests check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: Bool -> [DataDeclaration] -> (Id -> String)
  -> (Expr -> [E.Expr] -> Either String E.Expr) -> Expr -> Either String E.Expr
renderExpression ts declarations = renderExpressionWithContext ts declarations
  machineBits (pure . Native.referenceExpr') (pure . E.Str . Backend.scalarTypeKey)

-- | In an async function: a match's branches are async, and the match is
-- awaited, so a branch may await an asynchronous call.
renderAsyncExpression :: Bool -> [DataDeclaration] -> (Id -> String)
  -> (Expr -> [E.Expr] -> Either String E.Expr) -> Expr -> Either String E.Expr
renderAsyncExpression ts declarations = renderWith True ts declarations
  machineBits (pure . Native.referenceExpr') (pure . E.Str . Backend.scalarTypeKey)

-- | Callers whose generated code already holds the machine width and type
-- references in scope pass them in, so the rendering refers to them by name.
renderExpressionWithContext :: Bool -> [DataDeclaration] -> E.Expr
  -> (Type -> Either String E.Expr) -> (Type -> Either String E.Expr)
  -> (Id -> String) -> (Expr -> [E.Expr] -> Either String E.Expr)
  -> Expr -> Either String E.Expr
renderExpressionWithContext = renderWith False

renderWith :: Bool -> Bool -> [DataDeclaration] -> E.Expr
  -> (Type -> Either String E.Expr) -> (Type -> Either String E.Expr)
  -> (Id -> String) -> (Expr -> [E.Expr] -> Either String E.Expr)
  -> Expr -> Either String E.Expr
renderWith asynchronous ts declarations width reference key outerLocal external root = render root
  where
    -- Binders inside the term are named from the source, apart from the
    -- names the term uses freely.
    bound = collect root
    names = bindingNames [outerLocal i | i <- freeBinders root] bound
    local identity = Map.findWithDefault (outerLocal identity) identity names
    collect term = (case expressionNode term of
      AllElements _ binder _ -> [binder]
      SearchElements _ _ binder _ -> [binder]
      AllPayloads _ predicates -> map fst predicates
      Match _ cases -> concatMap caseBinders cases
      Let binder _ _ -> [binder]
      _ -> []) ++ concatMap collect (children term)
    runtime name args = E.call ("ls." ++ name) args
    schema name args = E.call ("_lawspec_schema." ++ name) (args ++ [E.Ident "symbols"])
    structural (TypeVariable _) = True
    structural ty = Native.requiresSchema declarations ty
    checked ty value
      | structural ty = do
          ref <- reference ty
          pure (schema "validate" [ref,value,width])
      | otherwise = do
          target <- key ty
          pure (runtime "convert" [value,target,width])
    annotated name ty = (E.param name) { E.paramType = if ts then Just (E.TKeyword ty) else Nothing }
    render term
      -- In an async function, an all group's steps run side by side.
      | asynchronous, Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let pattern = E.Param (E.PArray [E.PIdent (local (binderId binder)) | binder <- binders])
                (if ts then Just (E.TArray (E.TKeyword "unknown")) else Nothing) Nothing False
          pure (E.Await (E.Call (E.Arrow True [pattern] Nothing (E.ExpressionBody inner)) []
            [E.Await (runtime "concurrently" [E.Array [E.asyncArrow [] step | step <- steps]])] False))
    render term | Just values <- constantListElements term = E.Array <$> mapM render values
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (E.arrow [annotated (local (binderId binder)) "unknown"] body)) predicates
        pure (schema "allPayloads" [ref,argument,E.Array callbacks,width])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        let invocation = runtime (if asynchronous then "allElementsAsync" else "allElements")
              [argument, E.Arrow asynchronous [annotated (local (binderId binder)) "unknown"] Nothing (E.ExpressionBody body)]
        pure (if asynchronous then E.Await invocation else invocation)
      SearchElements universal value binder predicate -> do
        argument <- render value
        body <- render predicate
        let invocation = runtime (if asynchronous then "searchElementsAsync" else "searchElements")
              [E.BoolLit universal, argument,
               E.Arrow asynchronous [annotated (local (binderId binder)) "unknown"] Nothing (E.ExpressionBody body)]
        pure (if asynchronous then E.Await invocation else invocation)
      Local identity -> pure (E.Ident (local identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- render body
        let invocation = E.Call (E.Arrow asynchronous [annotated (local (binderId binder)) "any"] Nothing (E.ExpressionBody inner)) [] [argument] False
        pure (if asynchronous then E.Await invocation else invocation)
      Constant value
        | plainConstant (expressionType term) value, Just native <- scalarLiteral value -> pure native
        | otherwise -> checked (expressionType term) (runtime "literal" [literalValue (A.toJSON value),E.Ident "symbols"])
      Construct tag args -> do
        values <- mapM render args
        if structural (expressionType term) then do
          ref <- reference (expressionType term)
          pure (schema "construct" [ref,E.Str (idText tag),E.Array values,width])
        else pure (runtime "construct" [E.Str (idText tag),E.Array values])
      Match value branches -> do
        argument <- render value
        cases <- mapM branch branches
        ref <- reference (expressionType value)
        let matched = schema "match" [ref,argument,E.Array cases,width]
        pure (if asynchronous then E.Await matched else matched)
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
            targetKey <- key target
            sourceKey <- key (expressionType value)
            pure (runtime "helper" [targetKey,E.Array [argument],E.Array [sourceKey],width])
      If c a b -> E.Conditional <$> render c <*> render a <*> render b
      ShortCircuit op a b -> (if op == And then E.and' else E.or') <$> render a <*> render b
      Unary Not a -> E.notE <$> render a
      Unary Negate a -> do
        value <- render a
        operand <- key (expressionType a)
        pure (runtime "helper" [E.Str "negate",E.Array [value],E.Array [operand],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) && op `elem` [Equal,NotEqual] then do
          ref <- reference (expressionType a)
          let equality = schema "equal" [ref,left,right,width]
          pure (if op == NotEqual then E.notE equality else equality)
        else do
          leftKey <- key (expressionType a)
          rightKey <- key (expressionType b)
          pure (runtime "binary" [E.Str (binaryName op),left,right,leftKey,rightKey])
      Helper Concurrently [value] -> render value
      Helper Recorded [keyValue,value] | structural (expressionType value) -> do
        name <- render keyValue
        argument <- render value
        ref <- reference (expressionType value)
        pure (schema "recorded" [ref,name,argument,width])
      Helper builtin args -> do
        values <- mapM render args
        keys <- mapM (key . expressionType) args
        pure (runtime "helper" [E.Str (builtinName builtin),E.Array values,E.Array keys,width])
    branch matched = do
      body <- render (caseBody matched)
      let parameters = [annotated (local (binderId binder)) "unknown" | binder <- caseBinders matched]
      pure (E.Array [E.Str (idText (caseConstructor matched)),
        E.Arrow asynchronous parameters Nothing (E.ExpressionBody body)])
