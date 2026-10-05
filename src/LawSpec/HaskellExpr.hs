-- Pure Haskell expressions rendered from checked Core.
module LawSpec.HaskellExpr (renderExpression, renderExpressionWithContext, apply, parens, array, checked, quoted, integerLiteral, scalarLiteral) where

import LawSpec.Core
import LawSpec.Scalar (Scalar(..))
import qualified LawSpec.HaskellTypeRefs as Native
import qualified LawSpec.Backend as Backend
import qualified LawSpec.Code.Doc as D

parens :: D.Doc -> D.Doc
parens value = D.group (D.text "(" <> value <> D.text ")")

apply :: String -> [D.Doc] -> D.Doc
apply name args = D.group (D.text name <> D.nest 2 (mconcat [D.softline <> parens value | value <- args]))

array :: [D.Doc] -> D.Doc
array = D.delimit 2 "[" "]"

checked :: D.Doc -> D.Doc
checked value = apply "P.either P.error P.id" [value]

-- Split source strings at character boundaries, then let Haskell concatenate
-- the independently escaped chunks. No encoded escape sequence is split.
quoted :: String -> D.Doc
quoted value = case chunks value of
  [] -> D.text (show ("" :: String))
  [one] -> D.text (show one)
  parts -> apply "P.concat" [array (map (D.text . show) parts)]
  where
    chunks "" = []
    chunks remaining =
      let candidates = takeWhile (\n -> length (show (take n remaining)) <= 32) [1 .. 32]
          width = case reverse candidates of n:_ -> n; [] -> 1
          (part,rest) = splitAt width remaining
      in part : chunks rest

integerLiteral :: Integer -> D.Doc
integerLiteral value
  | length (show value) <= 32 = D.text (show value)
  | otherwise = apply "P.read" [quoted (show value)]

scalarLiteral :: Scalar -> D.Doc
scalarLiteral value = case value of
  SInteger name n -> apply "SInteger" [quoted name,integerLiteral n]
  SBool b -> apply "SBool" [D.text (if b then "P.True" else "P.False")]
  SDecimal coefficient exponent -> apply "SDecimal" [integerLiteral coefficient,integerLiteral exponent]
  SRational numerator denominator -> apply "SRational" [integerLiteral numerator,integerLiteral denominator]
  SFloat name bits -> apply "SFloat" [quoted name,quoted bits]
  SComplex name real imaginary -> apply "SComplex" [quoted name,scalarLiteral real,scalarLiteral imaginary]
  SSequence name units -> apply "SSequence" [quoted name,array (map (D.text . show) units)]
  SCharacter name point -> apply "SCharacter" [quoted name,D.text (show point)]
  SSymbol identity description -> apply "SSymbol" [quoted identity,quoted description]
  SAbsent name -> apply "SAbsent" [quoted name]
  SPresent name payload -> apply "SPresent" [quoted name,
    maybe (D.text "P.Nothing") (apply "P.Just" . pure . scalarLiteral) payload]

renderExpression :: [DataDeclaration] -> Int -> String -> String -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits schema symbols = renderExpressionWithContext declarations
  (D.text (show bits)) schema (apply "P.Just" [D.text symbols])
  Native.haskellTypeReferenceDoc (pure . quoted . Backend.scalarTypeKey)

renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> String -> D.Doc
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc)
  -> (Id -> String) -> (Expr -> [D.Doc] -> Either String D.Doc)
  -> Expr -> Either String D.Doc
renderExpressionWithContext declarations width schema scope reference key local external = render
  where
    structural (TypeVariable _) = True
    structural ty = Native.requiresSchema declarations ty
    validate ty value = do
      ref <- reference ty
      pure (checked (apply "Schema.validateWith" [scope,D.text schema,ref,width,value]))
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        ref <- reference (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.group (D.text ("\\" ++ local (binderId binder) ++ " ->") <>
            D.nest 2 (D.softline <> apply "P.Right" [body])))) predicates
        pure (checked (apply "Schema.allPayloadsWith"
          [scope,D.text schema,ref,width,argument,array callbacks]))
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (apply "LS.allElements" [argument,
          D.group (D.text ("\\" ++ local (binderId binder) ++ " ->") <>
            D.nest 2 (D.softline <> body))])
      Local identity -> pure (D.text (local identity))
      Constant value -> validate (expressionType term)
        (apply "P.maybe" [D.text "P.id",D.text "LS.scopeSymbols",scope,scalarLiteral value])
      Construct tag fields -> do
        values <- mapM render fields
        ref <- reference (expressionType term)
        pure (checked (apply "Schema.constructWith" [scope,D.text schema,ref,width,quoted (idText tag),array values]))
      ExternalCall _ args -> mapM render args >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument | structural target -> validate target argument
                          | otherwise -> do
                              name <- key target
                              pure (checked (apply "LS.convertScalar" [width,name,argument]))
          Explicit -> do
            name <- key target
            pure (apply "LS.helper" [name,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (D.text "(if " <> apply "LS.truth" [condition] <> D.text " then " <> parens yes <> D.text " else " <> parens no <> D.text ")")
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (apply "SBool" [parens (apply "LS.truth" [left]) <>
          D.text (if op == And then " P.&& " else " P.|| ") <> parens (apply "LS.truth" [right])])
      Unary Not value -> do
        argument <- render value
        pure (apply "SBool" [apply "P.not" [apply "LS.truth" [argument]]])
      Unary Negate value -> do
        argument <- render value
        pure (apply "LS.helper" [D.text (show ("negate" :: String)),array [argument],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) then do
          ref <- reference (expressionType a)
          let equality = checked (apply "Schema.equalWith" [scope,D.text schema,ref,width,left,right])
          pure (apply "SBool" [if op == NotEqual then apply "P.not" [equality] else equality])
        else pure (apply "LS.binary" [D.text (show (binaryName op)),left,right])
      Helper builtin args -> do
        values <- mapM render args
        pure (apply "LS.helper" [D.text (show (builtinName builtin)),array values,width])
      Match value branches -> do
        -- Values are checked where they are built, decoded or drawn.
        argument <- render value
        arms <- mapM branch branches
        pure (D.group (D.text "(case " <> argument <> D.text " of {" <>
          D.nest 2 (D.softline <> D.joinWith (D.text ";" <> D.softline)
            (arms ++ [D.text "_ -> P.error \"invalid checked match constructor\""])) <>
          D.softline <> D.text "})"))
    branch matched = do
      body <- render (caseBody matched)
      let names = map (local . binderId) (caseBinders matched)
      pure $ case (idText (caseConstructor matched),names) of
        ("List::Nil",[]) -> D.text "SList [] ->" <> D.nest 2 (D.softline <> body)
        ("List::Cons",[headName,tailName]) ->
          D.group (D.text ("SList (" ++ headName ++ " : _tail) ->") <>
            D.nest 2 (D.softline <>
              D.text ("let { " ++ tailName ++ " = SList _tail } in") <>
              D.nest 2 (D.softline <> body)))
        (tag,_) -> D.text ("SData " ++ show tag ++ " ") <>
          array (map D.text names) <> D.text " ->" <> D.nest 2 (D.softline <> body)
