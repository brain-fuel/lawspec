-- Go expression documents for checked Core, shared by definitions and properties.
module LawSpec.GoExpr (renderExpression, renderExpressionWithContext, scalarLiteral, call, array, quoted) where

import LawSpec.Core
import qualified LawSpec.GoTypeRefs as Native
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (find)

quoted :: String -> D.Doc
quoted = D.text . T.unpack . T.decodeUtf8 . encode

call :: String -> [D.Doc] -> D.Doc
-- gofmt does not wrap calls to a column limit. Keeping their arguments inline
-- also keeps nested function-literal blocks at the correct lexical indentation.
call name values = D.text (name ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")"

array :: [D.Doc] -> D.Doc
array values = D.text "[]LawSpecValue{" <> D.joinWith (D.text ", ") values <> D.text "}"

scalarLiteral :: Type -> Scalar -> Either String D.Doc
scalarLiteral ty value = case value of
  SInteger name number -> pure (call "lsInteger" [quoted name,quoted (show number)])
  SBool valueBool -> pure (call "lsBool" [D.text (if valueBool then "true" else "false")])
  SDecimal c e -> pure (call "lsDecimal" [quoted (show c),quoted (show e)])
  SRational n d -> pure (call "lsRational" [quoted (show n),quoted (show d)])
  SFloat name pattern -> pure (call "lsFloating" [quoted name,quoted pattern])
  SComplex name real imaginary -> do
    a <- scalarLiteral (scalarType (scalarName real)) real
    b <- scalarLiteral (scalarType (scalarName imaginary)) imaginary
    pure (call "lsComplex" [quoted name,a,b])
  SCharacter name point -> pure (call "lsCharacter" [quoted name,D.text (show point)])
  SSequence name units -> pure (call "lsSequence" [quoted name,
    D.delimitTrailing 8 "[]int{" "}" (map (D.text . show) units)])
  SSymbol identity description -> pure (call "lsSymbol" [quoted identity,quoted description,D.text "symbols"])
  SAbsent name -> pure (call "lsAbsent" [quoted name])
  SPresent name payload -> do
    let inner = case ty of Constructor _ [TypeArgument valueType] -> valueType; _ -> ty
    child <- maybe (pure (D.text "nil")) (fmap (call "lsPointer" . pure) . scalarLiteral inner) payload
    pure (call "lsPresent" [case ty of Constructor _ [_] -> quoted (Native.goDataKey ty); _ -> quoted name,child])

renderExpression :: [DataDeclaration] -> Int -> String -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits schema = renderExpressionWithContext declarations
  (D.text (show bits)) schema (fmap D.text . Native.goTypeReference)
  (pure . quoted . Native.goDataKey)

renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> String
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc) -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionWithContext declarations width schema ref key local external = render
  where
    structural (TypeVariable _) = True
    structural ty = Native.requiresSchema declarations ty
    checked ty value
      | structural ty = do
          reference <- ref ty
          pure (call (schema ++ ".validate") [reference,value,width,D.text "symbols"])
      | otherwise = do
          name <- key ty
          pure (call "lsConvert" [name,value,width])
    render term = case expressionNode term of
      AllPayloads value predicates -> do
        argument <- render value
        reference <- ref (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.text ("func(" ++ local (binderId binder) ++ " LawSpecValue) LawSpecValue ") <>
            D.block 8 (D.text "return " <> body))) predicates
        let functions = D.text "[]func(LawSpecValue) LawSpecValue{" <>
              D.joinWith (D.text ", ") callbacks <> D.text "}"
        pure (call (schema ++ ".allPayloads")
          [reference,argument,functions,width,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (call "lsAllElements" [argument,
          D.text ("func(" ++ local (binderId binder) ++ " LawSpecValue) LawSpecValue ") <>
            D.block 8 (D.text "return " <> body)])
      Local identity -> pure (D.text (local identity))
      Constant value -> scalarLiteral (expressionType term) value >>= checked (expressionType term)
      Construct tag args -> do
        values <- mapM render args
        if structural (expressionType term) then do
          reference <- ref (expressionType term)
          pure (call (schema ++ ".construct") [reference,quoted (idText tag),array values,width,D.text "symbols"])
        else do
          name <- key (expressionType term)
          pure (call "lsConstruct" [name,quoted (idText tag),array values])
      ExternalCall _ args -> mapM render args >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument -> checked target argument
          Explicit -> do
            name <- key target
            pure (call "lsHelper" [name,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (D.text "func() LawSpecValue { if " <> call "lsTruth" [condition] <> D.text " { return " <> yes <>
          D.text " }; return " <> no <> D.text " }()")
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (call "lsBool" [call "lsTruth" [left] <>
          D.text (if op == And then " && " else " || ") <> call "lsTruth" [right]])
      Unary Not value -> do
        argument <- render value
        pure (call "lsBool" [D.text "!" <> call "lsTruth" [argument]])
      Unary Negate value -> do
        argument <- render value
        pure (call "lsHelper" [quoted "negate",array [argument],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) then do
          reference <- ref (expressionType a)
          pure (call "lsBool" [(if op == NotEqual then D.text "!" else mempty) <>
            call (schema ++ ".equal") [reference,left,right,width,D.text "symbols"]])
        else pure (call "lsBinary" [quoted (binaryName op),left,right])
      Helper builtin args -> do
        values <- mapM render args
        pure (call "lsHelper" [quoted (builtinName builtin),array values,width])
      Match scrutinee branches -> do
        -- Values are checked where they are built, decoded or drawn.
        value <- render scrutinee
        let matchedName = "matched" ++ show (length (show term))
            fieldsName = matchedName ++ "Fields"
            bind binder expression = [D.text (local (binderId binder) ++ " := ") <> expression,
              D.text ("_ = " ++ local (binderId binder))]
            invoke body = D.text "func() LawSpecValue " <> D.block 8 body <> D.text "()"
        case expressionType scrutinee of
          Constructor "List" _ -> do
            nil <- lookupBranch branches "List::Nil"
            cons <- lookupBranch branches "List::Cons"
            nilBody <- render (caseBody nil)
            consBody <- render (caseBody cons)
            name <- key (expressionType scrutinee)
            bindings <- case caseBinders cons of
              [headBinder,tailBinder] -> pure (bind headBinder (D.text (fieldsName ++ "[0]")) ++
                bind tailBinder (call "lsList" [name,D.text (fieldsName ++ "[1:]")]))
              _ -> Left "invalid Go list match binders"
            pure (invoke (D.joinWith D.hardline
              ([D.text (matchedName ++ " := ") <> value,
                D.text (fieldsName ++ " := " ++ matchedName ++ ".Data.([]LawSpecValue)"),
                D.text ("if len(" ++ fieldsName ++ ") == 0 ") <> D.block 8 (D.text "return " <> nilBody)] ++
               bindings ++ [D.text "return " <> consBody])))
          Constructor name _ | name `elem` ["Maybe","Either"] -> do
            let (helper,tags) = if name == "Maybe" then ("lsMatchMaybe",["Maybe::Nothing","Maybe::Just"])
                  else ("lsMatchEither",["Either::Left","Either::Right"])
            arms <- mapM (\tag -> lookupBranch branches tag >>= closure) tags
            pure (call helper (value:arms))
          Constructor _ _ -> do
            arms <- mapM (\branch -> do
              body <- render (caseBody branch)
              let bindings = concat [bind binder (D.text (fieldsName ++ ".fields[" ++ show i ++ "]"))
                    | (i,binder) <- zip [0::Int ..] (caseBinders branch)]
              pure (D.text "case " <> quoted (idText (caseConstructor branch)) <> D.text ":" <>
                D.nest 8 (D.hardline <> D.joinWith D.hardline (bindings ++ [D.text "return " <> body])))) branches
            pure (invoke (D.joinWith D.hardline
              [D.text (matchedName ++ " := ") <> value,
               D.text (fieldsName ++ " := " ++ matchedName ++ ".Data.(lawSpecData)"),
               D.text ("switch " ++ fieldsName ++ ".tag {") <> D.hardline <>
                 D.joinWith D.hardline (arms ++ [D.text "default:" <> D.nest 8
                   (D.hardline <> D.text "panic(\"invalid constructor in match\")")]) <>
                 D.hardline <> D.text "}"]))
          _ -> Left "matching requires a Go data type"
    lookupBranch branches tag = maybe (Left "non-exhaustive Go match") Right (find ((== Id tag) . caseConstructor) branches)
    closure branch = do
      body <- render (caseBody branch)
      pure (D.text "func" <> D.delimitTrailing 8 "(" ")"
        [D.text (local (binderId binder) ++ " LawSpecValue") | binder <- caseBinders branch] <>
        D.text " LawSpecValue " <> D.block 8 (D.text "return " <> body))
