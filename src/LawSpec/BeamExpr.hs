-- | Core expressions become native Erlang expressions. All shared semantics
-- go through the BEAM runtime; this module never reads source syntax.
-- ref:DEC-typed-core-boundary
module LawSpec.BeamExpr (renderExpression, renderExpressionWithContext, proposition, assertion, assertionLabelled) where

import qualified LawSpec.Core as C
import LawSpec.Core.ListLiteral (constantListElements)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import LawSpec.Backend (scalarTypeKey)
import Data.List (nubBy)
import qualified LawSpec.BeamNames as Names
import LawSpec.Scalar (scalarName, primitive, family, Family(..))

renderExpression :: Int -> D.Doc -> D.Doc -> (C.Id -> String)
  -> (D.Doc -> C.Expr -> [D.Doc] -> Either String D.Doc) -> C.Expr -> Either String D.Doc
renderExpression bits = renderExpressionWithContext (D.text (show bits))
  E.typeReference (Right . E.binary . scalarTypeKey)

-- | Constructor predicates refer to the schema's instantiated parameters.
renderExpressionWithContext :: D.Doc -> (C.Type -> Either String D.Doc)
  -> (C.Type -> Either String D.Doc) -> D.Doc -> D.Doc -> (C.Id -> String)
  -> (D.Doc -> C.Expr -> [D.Doc] -> Either String D.Doc) -> C.Expr -> Either String D.Doc
renderExpressionWithContext width reference key initialSchema symbols outer external root = renderScoped (0 :: Int) initialSchema root
  where
    binders = nubBy (\a b -> C.binderId a == C.binderId b) [binder | term <- terms root, binder <- case C.expressionNode term of
      C.AllElements _ b _ -> [b]
      C.SearchElements _ _ b _ -> [b]
      C.AllPayloads _ ps -> map fst ps
      C.Match _ cs -> concatMap C.caseBinders cs
      C.Let b _ _ -> [b]
      _ -> []]
    ids = map C.binderId binders
    terms term = term : concatMap terms (C.children term)
    occupied = [outer identity | term <- terms root, C.Local identity <- [C.expressionNode term], identity `notElem` ids]
    -- Binders keep their source names, apart from every name around them.
    bindings = zip ids (Names.variables (Names.generatedVariables ++ occupied) (map C.binderName binders))
    local identity = maybe (outer identity) id (lookup identity bindings)
    renderScoped depth schema = render
      where
        checked ty v = do
          ref <- reference ty
          pure (E.remote "lawspec_beam_schema" "validate" [v,ref,schema])
        render term
          | Just (fields,binders,body) <- C.concurrentGroup term = do
              steps <- mapM render fields
              inner <- render body
              pure (E.remote "lawspec_beam_runtime" "bind"
                [E.remote "lawspec_beam_runtime" "concurrently" [E.array (map (E.lambda []) steps)],
                 E.lambda [E.array (map (bound inner) binders)] inner])
        render term
          | Just values <- constantListElements term = E.array <$> mapM render values
        render term = case C.expressionNode term of
          -- A literal of its own primitive type needs no validation.
          C.Constant scalar
            | C.Constructor n [] <- C.expressionType term, n == scalarName scalar, n /= "Symbol" -> pure (E.literal symbols scalar)
            | otherwise -> checked (C.expressionType term) (E.literal symbols scalar)
          C.Local identity -> pure (D.text (local identity))
          C.Construct tag args -> do
            values <- mapM render args
            ref <- reference (C.expressionType term)
            pure (E.remote "lawspec_beam_schema" "construct" [E.binary (C.idText tag),E.array values,ref,schema])
          C.Match scrutinee branches -> do
            value <- render scrutinee
            cases <- mapM branch branches
            pure (E.remote "lawspec_beam_schema" "match" [value,E.record cases])
          C.Let binder value body -> do
            argument <- render value
            inner <- render body
            -- let x = value in body: the value, then the body with it.
            pure (E.remote "lawspec_beam_runtime" "bind" [argument,E.lambda [bound inner binder] inner])
          C.AllElements value binder predicate -> do
            argument <- render value
            body <- render predicate
            pure (E.remote "lists" "all" [E.lambda [bound body binder] body,argument])
          C.SearchElements universal value binder predicate -> do
            argument <- render value
            body <- render predicate
            pure (E.remote "lawspec_beam_runtime" "search_elements"
              [E.atom (if universal then "true" else "false"),argument,E.lambda [bound body binder] body])
          C.AllPayloads value predicates -> do
            argument <- render value
            ref <- reference (C.expressionType value)
            callbacks <- mapM (\(b,p) -> (\body -> E.lambda [bound body b] body) <$> render p) predicates
            pure (E.remote "lawspec_beam_schema" "all_payloads" [argument,ref,E.array callbacks,schema])
          C.ExternalCall _ args -> mapM render args >>= external schema term
          C.Perform _ args -> mapM render args >>= external schema term
          C.Handle (C.WithHandler _ _) body -> do
            let innerSchema = D.text ("_HandledSchema" ++ show depth)
            inner <- renderScoped (depth + 1) innerSchema body
            external schema term [E.lambda [innerSchema] inner]
          C.Handle (C.CatchFailure _) body -> render body >>= external schema term . pure . E.lambda []
          C.Calls _ args -> mapM render (maybe [] id args) >>= external schema term
          C.Convert mode ty source -> do
            value <- render source
            case mode of
              C.CheckedArgument | ty == C.expressionType source -> checked ty value
              -- Exact numeric bridges can change the portable representation.
              -- Retain schema validation after the existing scalar conversion.
              C.CheckedArgument -> do
                ref <- reference ty
                checked ty (E.remote "lawspec_beam_scalar" "convert" [value,ref,width])
              C.Explicit -> do
                ref <- reference ty
                pure (E.remote "lawspec_beam_scalar" "convert" [value,ref,width])
          C.If condition yes no -> do
            c <- render condition
            a <- render yes
            b <- render no
            pure (E.caseOf c [(E.atom "true",a),(E.atom "false",b)])
          C.ShortCircuit op a b -> infixDoc (if op == C.And then "andalso" else "orelse") <$> render a <*> render b
          C.Unary C.Not a -> (\v -> D.text "(not " <> v <> D.text ")") <$> render a
          C.Unary C.Negate a -> E.remote "lawspec_beam_scalar" "negate" . pure <$> render a
          -- Integer arithmetic and comparison are Erlang's own operators;
          -- other operations are the runtime's functions, named for what
          -- they do.
          C.Binary op _ a b -> do
            left <- render a
            right <- render b
            case lookup op integerOperators of
              Just symbol | integral (C.expressionType a) && integral (C.expressionType b) ->
                pure (infixDoc symbol left right)
              _ | op == C.Equal -> pure (E.remote "lawspec_beam_scalar" "equal" [left,right])
                | op == C.NotEqual -> pure (E.remote "lawspec_beam_scalar" "not_equal" [left,right])
                | otherwise -> do
                    ta <- key (C.expressionType a)
                    tb <- key (C.expressionType b)
                    pure (E.remote "lawspec_beam_scalar" (operatorFunction op) [left,right,ta,tb])
          C.Helper C.Concurrently [arg] -> render arg
          C.Helper C.Recorded [keyValue,value] -> do
            name <- render keyValue
            argument <- render value
            ref <- reference (C.expressionType value)
            pure (E.remote "lawspec_beam_runtime" "recorded" [name,argument,ref,schema])
          C.Helper builtin args -> do
            values <- mapM render args
            types <- mapM (key . C.expressionType) args
            pure (E.remote "lawspec_beam_runtime" "helper" [E.binary (C.builtinName builtin),E.array values,E.array types,width])
        branch c = do
          body <- render (C.caseBody c)
          pure (E.binary (C.idText (C.caseConstructor c)),E.lambda
            [E.array (map (bound body) (C.caseBinders c))] body)
        bound scope binder = E.variable (local (C.binderId binder)) scope

-- | Erlang's operators for integer operands: the runtime's exact integer
-- arithmetic and order are the same.
integerOperators :: [(C.BinaryOp, String)]
integerOperators = [(C.Add,"+"),(C.Subtract,"-"),(C.Multiply,"*"),(C.Equal,"=:="),(C.NotEqual,"=/="),
  (C.Less,"<"),(C.LessEqual,"=<"),(C.Greater,">"),(C.GreaterEqual,">=")]

integral :: C.Type -> Bool
integral (C.Constructor n []) | Just p <- primitive n = family p == IntegerFamily
integral _ = False

-- | The runtime function for an operation (lawspec_beam_scalar).
operatorFunction :: C.BinaryOp -> String
operatorFunction op = case op of
  C.Add -> "add"
  C.Subtract -> "subtract"
  C.Multiply -> "multiply"
  C.Divide -> "divide"
  C.Quotient -> "quotient"
  C.Remainder -> "remainder"
  C.Power -> "power"
  C.Less -> "less"
  C.LessEqual -> "less_or_equal"
  C.Greater -> "greater"
  C.GreaterEqual -> "greater_or_equal"
  C.Equal -> "equal"
  C.NotEqual -> "not_equal"

infixDoc :: String -> D.Doc -> D.Doc -> D.Doc
infixDoc = E.operator

proposition :: (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
proposition = propositionWith (\a b -> E.remote "lawspec_beam_scalar" "equal" [a,b])

-- | A failing equation retains both evaluated sides for the framework report.
-- No adapter is called again just to explain its failure.
assertion :: String -> (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
assertion label = assertionLabelled (E.binary label)

-- | As assertion, with the label written as given (a law's macro).
assertionLabelled :: D.Doc -> (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
assertionLabelled label = propositionWith (\a b -> E.remote "lawspec_beam_runtime" "assert_equal" [a,b,label])

propositionWith :: (D.Doc -> D.Doc -> D.Doc) -> (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
propositionWith equal render p = case p of
  C.Equation _ a b -> do
    left <- render a
    right <- render b
    pure (equal left right)
  C.Implication c inner -> do
    condition <- render c
    body <- propositionWith equal render inner
    pure (infixDoc "orelse" (D.text "(not " <> condition <> D.text ")") body)
  C.Conjunction [] -> pure (E.atom "true")
  C.Conjunction ps -> foldr1 (infixDoc "andalso") <$> mapM (propositionWith equal render) ps
  C.Quantified _ _ _ -> Left "a scoped proposition requires complete search planning before native emission"
  C.Negation _ -> Left "proposition negation requires execution planning before native emission"
