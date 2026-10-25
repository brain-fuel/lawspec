-- | Pure Haskell expressions rendered from checked Core.
module LawSpec.HaskellExpr
  ( Context(..), renderExpression, renderExpressionWith, renderExpressionWithContext
  , scalarExpr, quotedExpr, plainConstant, typeReference
  , apply, parens, array, checked, quoted, integerLiteral, scalarLiteral
  ) where

import LawSpec.Core
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Backend as Backend
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H

-- | Arguments are parenthesised only when they need to be.
parens :: D.Doc -> D.Doc
parens value = D.group (D.text "(" <> value <> D.text ")")

-- | Function application, wrapping arguments when a call is too wide.
-- ref:DEC-readable-output-default
apply :: String -> [D.Doc] -> D.Doc
apply name args = D.group (D.text name <> D.nest 2 (mconcat [D.softline <> parens value | value <- args]))

-- | Lists of runtime values are written in one shape so they wrap like calls.
array :: [D.Doc] -> D.Doc
array = D.delimit 2 "[" "]"

-- | Values of types with a schema are validated as they enter a law, so an
-- adapter cannot return a value outside its declared domain.
-- ref:DEC-portable-exact-arithmetic
checked :: D.Doc -> D.Doc
checked value = apply "P.either P.error P.id" [value]

-- | A string as a Haskell literal, in one piece.
quoted :: String -> D.Doc
quoted = H.expression . H.string

quotedExpr :: String -> H.Expr
quotedExpr = H.string

integerLiteral :: Integer -> D.Doc
integerLiteral = H.expression . H.integer

-- | Literals become runtime values built from their declared type and exact
-- digits, so Haskell never reads a number at its own precision.
-- ref:DEC-portable-exact-arithmetic
scalarLiteral :: Scalar -> D.Doc
scalarLiteral = H.expression . scalarExpr

-- | A scalar as a runtime value. Text is a string literal.
scalarExpr :: Scalar -> H.Expr
scalarExpr value = case value of
  SInteger name n -> H.call "SInteger" [H.string name, H.integer n]
  SBool b -> H.call "SBool" [H.var (if b then "P.True" else "P.False")]
  SDecimal coefficient exponent -> H.call "SDecimal" [H.integer coefficient, H.integer exponent]
  SRational numerator denominator -> H.call "SRational" [H.integer numerator, H.integer denominator]
  SFloat name bits -> H.call "SFloat" [H.string name, H.string bits]
  SComplex name real imaginary -> H.call "SComplex" [H.string name, scalarExpr real, scalarExpr imaginary]
  SSequence "Text" units -> H.call "LS.textScalar" [H.string (map toEnum units)]
  SSequence name units -> H.call "SSequence" [H.string name, H.List (map (H.integer . toInteger) units)]
  SCharacter name point -> H.call "SCharacter" [H.string name, H.integer (toInteger point)]
  SSymbol identity description -> H.call "SSymbol" [H.string identity, H.string description]
  SAbsent name -> H.call "SAbsent" [H.string name]
  SPresent name payload -> H.call "SPresent" [H.string name,
    maybe (H.var "P.Nothing") (\p -> H.call "P.Just" [scalarExpr p]) payload]

-- | A constant that needs no check: a primitive's literal at its own type,
-- which the checker has already admitted.
plainConstant :: Type -> Scalar -> Bool
plainConstant ty value = case (ty, value) of
  (Constructor t [], SInteger s _) -> t == s
  (Constructor "Bool" [], SBool _) -> True
  (Constructor t [], SSequence s _) -> t == s && t `elem` ["Text", "Bytes"]
  (Constructor t [], SCharacter s _) -> t == s && t `elem` ["Char", "CodePoint", "CodeUnit16"]
  _ -> False

-- | The runtime's reference to a type.
typeReference :: Type -> Either String H.Expr
typeReference ty = reference <$> S.typeReference [] ty
  where
    reference (S.Parameter index) = H.call "Schema.Parameter" [H.integer (toInteger index)]
    reference (S.Named name arguments) = H.call "Schema.Named" [H.string name, H.List (map reference arguments)]

-- | What an expression is checked in: the case's symbols (or a contract's
-- scope), the schema, the machine width, and how types, binders and
-- external calls are written.
data Context = Context
  { contextScope :: H.Expr
  , contextSchema :: H.Expr
  , contextWidth :: H.Expr
  , contextReference :: Type -> Either String H.Expr
  , contextKey :: Type -> Either String H.Expr
  , contextLocal :: Id -> String
  , contextExternal :: Expr -> [H.Expr] -> Either String H.Expr
  }

-- | Expressions are rendered from Core, never from source, so the Haskell
-- tests check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> String -> String -> (Id -> String)
  -> (Expr -> [H.Expr] -> Either String H.Expr) -> Expr -> Either String H.Expr
renderExpression declarations bits schema symbols local external = renderExpressionWith declarations
  (Context (H.var symbols) (H.var schema) (H.integer (toInteger bits)) typeReference
    (pure . H.string . Backend.scalarTypeKey) local external)

-- | As renderExpression, with documents for the context, for callers that
-- build their own.
renderExpressionWithContext :: [DataDeclaration] -> H.Expr -> String -> H.Expr
  -> (Type -> Either String H.Expr) -> (Type -> Either String H.Expr)
  -> (Id -> String) -> (Expr -> [H.Expr] -> Either String H.Expr)
  -> Expr -> Either String H.Expr
renderExpressionWithContext declarations width schema scope reference key local external =
  renderExpressionWith declarations (Context scope (H.var schema) width reference key local external)

renderExpressionWith :: [DataDeclaration] -> Context -> Expr -> Either String H.Expr
renderExpressionWith declarations Context{..} = render
  where
    structural (TypeVariable _) = True
    structural ty = requiresSchema ty
    requiresSchema ty = case ty of
      Constructor name arguments -> name `elem` ["List","Maybe","Either","Nullable","Optional"] ||
        any ((== Id name) . dataId) declarations ||
        any (\a -> case a of TypeArgument v -> requiresSchema v; _ -> False) arguments
      Arrow a b -> requiresSchema a || requiresSchema b
      _ -> False
    -- Schema.checked scope schema ref width ...
    inSchema name ty rest = do
      ref <- contextReference ty
      pure (H.call ("Schema." ++ name) ([contextScope, contextSchema, ref, contextWidth] ++ rest))
    shortCircuitTerms wanted term = case expressionNode term of
      ShortCircuit op left right | op == wanted -> shortCircuitTerms wanted left ++ shortCircuitTerms wanted right
      _ -> [term]
    truth x = H.call "LS.truth" [x]
    lam binder body = H.lambda [contextLocal (binderId binder)] body
    render term
      -- An all group's steps run side by side, each on a thread of its own.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          pure (H.LetIn [("steps", H.call "LS.concurrently" [H.List steps])] $ H.Case (H.var "steps")
            [ ("[" ++ commaList (map (contextLocal . binderId) binders) ++ "]", inner)
            , ("_", H.call "P.error" [H.string "invalid all group"]) ])
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        callbacks <- mapM (\(binder,predicate) -> lam binder <$> render predicate) predicates
        inSchema "allSatisfy" (expressionType value) [argument, H.List callbacks]
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (H.call "LS.allElements" [argument, lam binder body])
      SearchElements universal value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (H.call "LS.searchElements" [H.var (if universal then "P.True" else "P.False"), argument, lam binder body])
      Local identity -> pure (H.var (contextLocal identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- render body
        pure (H.call "LS.letIn" [argument, lam binder inner])
      Constant value | plainConstant (expressionType term) value -> pure (scalarExpr value)
      Constant value -> inSchema "literal" (expressionType term) [scalarExpr value]
      Construct tag fields -> do
        values <- mapM render fields
        inSchema "built" (expressionType term) [H.string (idText tag), H.List values]
      ExternalCall _ args -> mapM render args >>= contextExternal term
      -- Ability nodes go to the caller, which knows where handlers are.
      Perform _ args -> mapM render args >>= contextExternal term
      Handle _ body -> render body >>= contextExternal term . pure
      Calls _ args -> mapM render (maybe [] id args) >>= contextExternal term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument | structural target -> inSchema "checked" target [argument]
                          | otherwise -> do
                              name <- contextKey target
                              pure (H.call "LS.converted" [contextWidth, name, argument])
          Explicit -> do
            name <- contextKey target
            pure (H.call "LS.helper" [name, H.List [argument], contextWidth])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (H.If (truth condition) yes no)
      ShortCircuit op a b -> do
        -- Intermediate Bool boxes are redundant. One lazy operator chain
        -- keeps the same ordered, short-circuiting observations, including
        -- effectful temporal leaves, without quadratic indentation.
        values <- mapM render (shortCircuitTerms op a ++ shortCircuitTerms op b)
        pure (H.call "SBool" [H.operator (if op == And then "P.&&" else "P.||") (map truth values)])
      Unary Not value -> do
        argument <- render value
        pure (H.call "SBool" [H.call "P.not" [truth argument]])
      Unary Negate value -> do
        argument <- render value
        pure (H.call "LS.helper" [H.string "negate", H.List [argument], contextWidth])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) then do
          equality <- inSchema "same" (expressionType a) [left, right]
          pure (H.call "SBool" [if op == NotEqual then H.call "P.not" [equality] else equality])
        else pure (H.call "LS.binary" [H.string (binaryName op), left, right])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (H.call "LS.helper" [H.string (builtinName builtin), H.List values, contextWidth])
      Match value branches -> do
        -- Values are checked where they are built, decoded or drawn.
        argument <- render value
        arms <- mapM branch branches
        let alternatives = arms ++ [("_", H.call "P.error" [H.string "invalid checked match constructor"])]
        -- A computed subject is named first, so the case reads from it.
        pure (case argument of
          H.Var _ -> H.Case argument alternatives
          _ -> H.LetIn [("subject", argument)] (H.Case (H.var "subject") alternatives))
    branch matched = do
      body <- render (caseBody matched)
      let names = map (contextLocal . binderId) (caseBinders matched)
      pure $ case (idText (caseConstructor matched),names) of
        ("List::Nil",[]) -> ("SList []", body)
        -- The tail is a list of values; the law sees it as a List.
        ("List::Cons",[headName,tailName]) ->
          ("SList (" ++ headName ++ " : " ++ tailName ++ "Items)", H.LetIn [(tailName, H.call "SList" [H.var (tailName ++ "Items")])] body)
        (tag,_) -> ("SData " ++ H.renderString tag ++ " [" ++ commaList names ++ "]", body)
    commaList = foldr1' (\a b -> a ++ ", " ++ b)
    foldr1' _ [] = ""
    foldr1' f xs = foldr1 f xs
