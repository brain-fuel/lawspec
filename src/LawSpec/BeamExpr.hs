-- | Core expressions become native Erlang expressions. All shared semantics
-- go through the BEAM runtime; this module never reads source syntax.
-- ref:DEC-typed-core-boundary
module LawSpec.BeamExpr (renderExpression, renderExpressionWithContext, proposition, assertion) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import LawSpec.Backend (scalarTypeKey)
import Data.List (nub)

renderExpression :: Int -> D.Doc -> D.Doc -> (C.Id -> String)
  -> (C.Expr -> [D.Doc] -> Either String D.Doc) -> C.Expr -> Either String D.Doc
renderExpression bits = renderExpressionWithContext (D.text (show bits))
  E.typeReference (Right . E.binary . scalarTypeKey)

-- | Constructor predicates refer to the schema's instantiated parameters.
renderExpressionWithContext :: D.Doc -> (C.Type -> Either String D.Doc)
  -> (C.Type -> Either String D.Doc) -> D.Doc -> D.Doc -> (C.Id -> String)
  -> (C.Expr -> [D.Doc] -> Either String D.Doc) -> C.Expr -> Either String D.Doc
renderExpressionWithContext width reference key schema symbols outer external root = render root
  where
    ids = nub [C.binderId binder | term <- terms root, binder <- case C.expressionNode term of
      C.AllElements _ b _ -> [b]
      C.AllPayloads _ ps -> map fst ps
      C.Match _ cs -> concatMap C.caseBinders cs
      C.Let b _ _ -> [b]
      _ -> []]
    terms term = term : concatMap terms (C.children term)
    occupied = [outer identity | term <- terms root, C.Local identity <- [C.expressionNode term], identity `notElem` ids]
    bindings = zip ids [candidate | n <- [0::Int ..], let candidate = "_LsBound" ++ show n, candidate `notElem` occupied]
    local identity = maybe (outer identity) id (lookup identity bindings)
    checked ty v = do
      ref <- reference ty
      pure (E.remote "lawspec_beam_schema" "validate" [v,ref,schema])
    render term
      | Just (fields,binders,body) <- C.concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          pure (E.apply (E.lambda [E.array (map (D.text . local . C.binderId) binders)] inner)
            [E.remote "lawspec_beam_runtime" "concurrently" [E.array (map (E.lambda []) steps)]])
    render term = case C.expressionNode term of
      C.Constant scalar -> checked (C.expressionType term) (E.literal symbols scalar)
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
        pure (E.apply (E.lambda [D.text (local (C.binderId binder))] inner) [argument])
      C.AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (E.remote "lists" "all" [E.lambda [D.text (local (C.binderId binder))] body,argument])
      C.AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (C.expressionType value)
        callbacks <- mapM (\(b,p) -> E.lambda [D.text (local (C.binderId b))] <$> render p) predicates
        pure (E.remote "lawspec_beam_schema" "all_payloads" [argument,ref,E.array callbacks,schema])
      C.ExternalCall _ args -> mapM render args >>= external term
      C.Perform _ args -> mapM render args >>= external term
      C.Handle _ body -> render body >>= external term . pure . E.lambda []
      C.Calls _ args -> mapM render (maybe [] id args) >>= external term
      C.Convert mode ty source -> do
        value <- render source
        case mode of
          C.CheckedArgument -> checked ty value
          C.Explicit -> do
            ref <- reference ty
            pure (E.remote "lawspec_beam_scalar" "convert" [value,ref,width])
      C.If condition yes no -> do
        c <- render condition
        a <- render yes
        b <- render no
        pure (D.group (D.text "case " <> c <> D.text " of" <>
          D.nest 4 (D.softline <> D.text "true -> " <> a <> D.text ";" <>
            D.softline <> D.text "false -> " <> b) <> D.softline <> D.text "end"))
      C.ShortCircuit op a b -> infixDoc (if op == C.And then "andalso" else "orelse") <$> render a <*> render b
      C.Unary C.Not a -> (\v -> D.text "(not " <> v <> D.text ")") <$> render a
      C.Unary C.Negate a -> E.remote "lawspec_beam_scalar" "negate" . pure <$> render a
      C.Binary op _ a b -> do
        left <- render a
        right <- render b
        ta <- key (C.expressionType a)
        tb <- key (C.expressionType b)
        pure (E.remote "lawspec_beam_scalar" "binary" [E.binary (C.binaryName op),left,right,ta,tb])
      C.Helper C.Concurrently [arg] -> render arg
      C.Helper builtin args -> do
        values <- mapM render args
        types <- mapM (key . C.expressionType) args
        pure (E.remote "lawspec_beam_runtime" "helper" [E.binary (C.builtinName builtin),E.array values,E.array types,width])
    branch c = do
      body <- render (C.caseBody c)
      pure (E.binary (C.idText (C.caseConstructor c)),E.lambda
        [E.array (map (D.text . local . C.binderId) (C.caseBinders c))] body)

infixDoc :: String -> D.Doc -> D.Doc -> D.Doc
infixDoc op a b = D.group (D.text "(" <> a <> D.softline <> D.text (op ++ " ") <> b <> D.text ")")

proposition :: (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
proposition = propositionWith (\a b -> E.remote "lawspec_beam_scalar" "equal" [a,b])

-- | A failing equation retains both evaluated sides for the framework report.
-- No adapter is called again just to explain its failure.
assertion :: String -> (C.Expr -> Either String D.Doc) -> C.Proposition -> Either String D.Doc
assertion label = propositionWith (\a b -> E.remote "lawspec_beam_runtime" "assert_equal" [a,b,E.binary label])

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
  C.Conjunction ps -> foldr (infixDoc "andalso") (E.atom "true") <$> mapM (propositionWith equal render) ps
