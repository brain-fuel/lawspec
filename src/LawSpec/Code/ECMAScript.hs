-- | JavaScript and TypeScript as a syntax tree, printed exactly as Prettier
-- prints it (default options: width 80, two-space indent, double quotes,
-- semicolons, trailing commas everywhere, arrow parentheses always). The
-- printer is a port of the parts of Prettier 3.9.10's estree printer that
-- generated code uses (src/language-js/print), over LawSpec.Code.Prettier's
-- port of its document printer. Emitters build trees; they never write
-- layout. ref:DEC-readable-output-default ref:prettier
module LawSpec.Code.ECMAScript
  ( Expr(..), Body(..), Param(..), Pattern(..), Prop(..), Key(..), Stmt(..), Member(..)
  , Import(..), Type(..), Dialect(..)
  , str, ident, num, call, method, new', arrow, arrowBlock, asyncArrow, asyncArrowBlock, param, typedParam
  , member, index, notE, binary, and', or', constDecl, letDecl, ret, exprStmt, comment, blank
  , printModule, printModuleWidth, printExpression, printFlat, printType, javascriptLiteral, isIdentifierName
  ) where

import Control.Monad (forM, zipWithM)
import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf)
import Data.Maybe (isJust, isNothing, fromMaybe)
import LawSpec.Code.Literal (literalFor)
import LawSpec.Code.Prettier (Doc, text, cat, indent, align, dedent, group, groupBroken, groupWithId
  , conditionalGroup, fill, ifBreak, ifBreakFor, indentIfBreak, line, softline, hardline
  , breakParent, label, labelOf, join, willBreak, canBreak, removeLines, isEmpty, render, stringWidth)
import qualified LawSpec.Code.Prettier as P

-- | JavaScript modules (Prettier's babel parser) or TypeScript.
data Dialect = JavaScript | TypeScript deriving (Eq, Show)

data Expr
  = Ident String
  | This
  | BoolLit Bool
  | Null
  | Str String
  | Num String
  | BigIntLit String           -- digits and sign, without the n
  | Template [Either String Expr]  -- raw text and interpolations
  | Member Expr String Bool    -- object, property, optional chaining
  | Index Expr Expr Bool
  | Call Expr [Type] [Expr] Bool
  | New Expr [Type] [Expr]
  | Arrow Bool [Param] (Maybe Type) Body
  | Function Bool (Maybe String) [Param] (Maybe Type) [Stmt]
  | Object [Prop]
  | Array [Expr]
  | Spread Expr
  | Unary String Expr
  | Binary String Expr Expr    -- && || ?? are logical expressions
  | Conditional Expr Expr Expr
  | Await Expr
  | Assign String Expr Expr
  | As Expr Type
  | NonNull Expr
  deriving (Eq, Show)

data Body = ExpressionBody Expr | BlockBody [Stmt] deriving (Eq, Show)

data Param = Param
  { paramPattern :: Pattern
  , paramType :: Maybe Type
  , paramDefault :: Maybe Expr
  , paramRest :: Bool
  } deriving (Eq, Show)

-- | An object pattern's properties: a key and its pattern, or a shorthand.
data Pattern = PIdent String | PArray [Pattern] | PObject [(String, Maybe Pattern)] deriving (Eq, Show)

-- | An object's property; a commented one has comment lines before it.
data Prop = Prop Key Expr | Shorthand String | SpreadProp Expr | CommentedProp [String] Prop deriving (Eq, Show)

data Key = KName String | KString String | KComputed Expr deriving (Eq, Show)

data Type
  = TRef String [Type]
  | TKeyword String
  | TLiteral Expr
  | TUnion [Type]
  | TArray Type
  | TReadonly Type
  | TTuple [Type]
  | TFunction [Param] Type
  | TObject [(String, Bool, Type)]
  | TRaw String   -- printed as written, on one line
  deriving (Eq, Show)

data Member
  = Field { fieldModifiers :: [String], fieldName :: String, fieldType :: Maybe Type, fieldValue :: Maybe Expr }
  | Method { methodStatic :: Bool, methodAsync :: Bool, methodKind :: String, methodName :: String
           , methodParams :: [Param], methodReturn :: Maybe Type, methodBody :: [Stmt] }
  | Signature { signatureName :: String, signatureParams :: [Param], signatureReturn :: Maybe Type }
  | MemberComment [String]
  | MemberBlank
  deriving (Eq, Show)

data Import
  = ImportNamespace String
  | ImportNamed [(String, Maybe String)]
  | ImportDefault String
  | ImportDefaultNamed String [(String, Maybe String)]
  | ImportEffect
  deriving (Eq, Show)

data Stmt
  = ExprStmt Expr
  | VarDecl String Pattern (Maybe Type) (Maybe Expr)
  | Return (Maybe Expr)
  | Throw Expr
  | If Expr [Stmt] (Maybe (Either Stmt [Stmt]))   -- else if, or else block
  | IfSingle Expr Stmt                             -- if (...) statement;
  | Try [Stmt] (Maybe (Maybe Pattern, [Stmt])) (Maybe [Stmt])
  | ForOf String Pattern Expr [Stmt]
  | For (Maybe (String, Pattern, Maybe Type, Maybe Expr)) (Maybe Expr) (Maybe Expr) [Stmt]
  | Switch Expr [(Maybe Expr, [Stmt])]
  | While Expr [Stmt]
  | Block [Stmt]
  | Break
  | Continue
  | FunctionDecl { declExport :: Bool, declAsync :: Bool, declName :: String, declTypeParams :: [String]
                 , declParams :: [Param], declReturn :: Maybe Type, declBody :: [Stmt] }
  | ClassDecl { classExport :: Bool, className :: String, classTypeParams :: [String]
              , classExtends :: Maybe Expr, classImplements :: [Type], classMembers :: [Member] }
  | Interface { interfaceExport :: Bool, interfaceName :: String, interfaceTypeParams :: [String], interfaceMembers :: [Member] }
  | TypeAlias { aliasExport :: Bool, aliasName :: String, aliasTypeParams :: [String], aliasType :: Type }
  | ImportDecl Bool Import String    -- type-only, specifiers, source
  | ExportNamed [(String, Maybe String)] (Maybe String)
  | ExportAll String
  | Namespace Bool String [Stmt]
  | Comment [String]
  | Blank
  deriving (Eq, Show)

-- Conveniences for emitters.
str :: String -> Expr
str = Str

ident :: String -> Expr
ident = Ident

num :: Integer -> Expr
num n = if n < 0 then Unary "-" (Num (show (negate n))) else Num (show n)

call :: String -> [Expr] -> Expr
call name args = Call (path name) [] args False

method :: Expr -> String -> [Expr] -> Expr
method object name args = Call (Member object name False) [] args False

new' :: String -> [Expr] -> Expr
new' name = New (path name) []

-- | a.b.c as members of an identifier.
path :: String -> Expr
path name = case splitDots name of
  first : rest -> foldl (\o p -> Member o p False) (Ident first) rest
  [] -> Ident name
  where
    splitDots s = case break (== '.') s of
      (a, '.' : b) -> a : splitDots b
      (a, _) -> [a]

member :: Expr -> String -> Expr
member o p = Member o p False

index :: Expr -> Expr -> Expr
index o i = Index o i False

arrow :: [Param] -> Expr -> Expr
arrow ps body = Arrow False ps Nothing (ExpressionBody body)

arrowBlock :: [Param] -> [Stmt] -> Expr
arrowBlock ps body = Arrow False ps Nothing (BlockBody body)

asyncArrow :: [Param] -> Expr -> Expr
asyncArrow ps body = Arrow True ps Nothing (ExpressionBody body)

asyncArrowBlock :: [Param] -> [Stmt] -> Expr
asyncArrowBlock ps body = Arrow True ps Nothing (BlockBody body)

param :: String -> Param
param n = Param (PIdent n) Nothing Nothing False

typedParam :: String -> Type -> Param
typedParam n t = Param (PIdent n) (Just t) Nothing False

notE :: Expr -> Expr
notE = Unary "!"

binary :: String -> Expr -> Expr -> Expr
binary = Binary

and', or' :: Expr -> Expr -> Expr
and' = Binary "&&"
or' = Binary "||"

constDecl, letDecl :: String -> Expr -> Stmt
constDecl n v = VarDecl "const" (PIdent n) Nothing (Just v)
letDecl n v = VarDecl "let" (PIdent n) Nothing (Just v)

ret :: Expr -> Stmt
ret = Return . Just

exprStmt :: Expr -> Stmt
exprStmt = ExprStmt

comment :: String -> Stmt
comment c = Comment [c]

blank :: Stmt
blank = Blank

-- | A string literal as Prettier writes it: double quotes unless single
-- quotes need fewer escapes (LawSpec.Code.Literal's table for JavaScript).
javascriptLiteral :: String -> String
javascriptLiteral = literalFor "javascript"

-- | An ES5 identifier name (Prettier unquotes such object keys).
isIdentifierName :: String -> Bool
isIdentifierName s = case s of
  c : rest -> start c && all part rest
  [] -> False
  where
    start c = isAsciiLower c || isAsciiUpper c || c == '_' || c == '$'
    part c = start c || isDigit c

-- Printing ------------------------------------------------------------------

data Node = NE Expr | NS Stmt | NProp Prop | NParam Param | NDeclarator | NMember Member | NType Type | NProgram
  deriving (Eq, Show)

-- | Where a node is: its parent and the parent's field holding it, nearest
-- first.
type Path = [(Node, String)]

data Args = Args { expandLastArg :: Bool, expandFirstArg :: Bool, assignmentLayout :: Maybe String }

noArgs :: Args
noArgs = Args False False Nothing

type P = State (Dialect, Int)

fresh :: P Int
fresh = do
  (d, n) <- get
  put (d, n + 1)
  pure n

dialect :: P Dialect
dialect = fst <$> get

width :: Int
width = 80

-- | A module: its statements, laid out by Prettier's rules.
printModule :: Dialect -> [Stmt] -> String
printModule = printModuleWidth width

-- | A module laid out for another width (maxBound for compact output).
printModuleWidth :: Int -> Dialect -> [Stmt] -> String
printModuleWidth w d stmts = render w 2 doc
  where
    doc = evalState (do
      body <- statementSequence [(NProgram, "body")] stmts
      pure (if isEmpty body then mempty else body <> hardline)) (d, 0)

-- | One expression, laid out alone (for tests and template interpolations).
printExpression :: Dialect -> Expr -> String
printExpression d e = render width 2 (evalState (expr [(NS (ExprStmt e), "expression")] noArgs e) (d, 0))

-- Statements ----------------------------------------------------------------

-- | Statements separated by line breaks, with at most one blank line between
-- two, and none at the start or end.
statementSequence :: Path -> [Stmt] -> P Doc
statementSequence p stmts = do
  let items = normalise stmts
  docs <- forM items $ \(s, blankAfter) -> do
    d <- statement p s
    pure (d, blankAfter)
  pure (cat (concat [ [d] ++ (if isLast then [] else [hardline] ++ [hardline | b])
                    | (i, (d, b)) <- zip [0 :: Int ..] docs, let isLast = i == length docs - 1 ]))
  where
    normalise ss = go (dropWhile (== Blank) ss)
      where
        go [] = []
        go (Blank : rest) = go rest
        go (s : rest) = (s, case rest of
          (Blank : more) -> any (/= Blank) more
          _ -> False) : go rest

block :: Path -> [Stmt] -> Bool -> P Doc
block p stmts emptyBare = do
  body <- statementSequence p stmts
  pure (if isEmpty body
    then (if emptyBare then text "{}" else cat [text "{", hardline, text "}"])
    else cat [text "{", indent (cat [hardline, body]), hardline, text "}"])

statement :: Path -> Stmt -> P Doc
statement p s = let here = NS s in case s of
  Comment ls -> pure (join hardline (map (text . dropWhileEnd (== ' ')) ls))
  Blank -> pure mempty
  ExprStmt e -> do
    d <- expr ((here, "expression") : p) noArgs e
    pure (cat [d, text ";"])
  VarDecl kind pat ty initial -> do
    d <- declarator ((here, "declarations") : p) pat ty initial
    pure (group (cat [text kind, text " ", d, text ";"]))
  Return Nothing -> pure (text "return;")
  Return (Just e) -> returnOrThrow "return" e
  Throw e -> returnOrThrow "throw" e
  IfSingle test consequent -> do
    condition <- ifCondition test
    body <- statement ((here, "consequent") : p) consequent
    pure (group (cat [text "if (", condition, text ")", indent (cat [line, body])]))
  If test consequent alternate -> do
    condition <- ifCondition test
    body <- block ((here, "consequent") : p) consequent False
    let opening = group (cat [text "if (", condition, text ")", text " ", body])
    case alternate of
      Nothing -> pure opening
      Just (Left elseIf) -> do
        d <- statement ((here, "alternate") : p) elseIf
        pure (cat [opening, text " else", group (cat [text " ", d])])
      Just (Right stmts) -> do
        d <- block ((here, "alternate") : p) stmts False
        pure (cat [opening, text " else", group (cat [text " ", d])])
  Try body handler finalizer -> do
    b <- block ((here, "block") : p) body False
    h <- case handler of
      Nothing -> pure mempty
      Just (pat, stmts) -> do
        hb <- block ((here, "handler") : p) stmts (isNothing finalizer)
        pp <- maybe (pure mempty) (\x -> (\d -> cat [text "(", d, text ") "]) <$> pattern' x) pat
        pure (cat [text " catch ", pp, hb])
    f <- case finalizer of
      Nothing -> pure mempty
      Just stmts -> (\d -> cat [text " finally ", d]) <$> block ((here, "finalizer") : p) stmts False
    pure (cat [text "try ", b, h, f])
  ForOf kind pat iterable body -> do
    left <- pattern' pat
    right <- expr ((here, "right") : p) noArgs iterable
    b <- block ((here, "body") : p) body False
    pure (group (cat [text "for (", text kind, text " ", left, text " of ", right, text ")", text " ", b]))
  For initial test update body -> do
    b <- block ((here, "body") : p) body True
    if isNothing initial && isNothing test && isNothing update
      then pure (group (cat [text "for (;;)", text " ", b]))
      else do
        initDoc <- case initial of
          Nothing -> pure mempty
          Just (kind, pat, ty, value) -> do
            d <- declarator ((here, "init") : p) pat ty value
            pure (group (cat [text kind, text " ", d]))
        testDoc <- maybe (pure mempty) (expr ((here, "test") : p) noArgs) test
        updateDoc <- maybe (pure mempty) (expr ((here, "update") : p) noArgs) update
        pure (group (cat [text "for (", group (cat [indent (cat [softline, initDoc, text ";", line, testDoc, text ";"
                                                                , if isJust update then cat [line, updateDoc] else mempty]), softline])
                         , text ")", text " ", b]))
  Switch discriminant cases -> do
    d <- expr ((here, "discriminant") : p) noArgs discriminant
    printed <- forM cases $ \(test, consequent) -> do
      label' <- case test of
        Just t -> (\x -> cat [text "case ", x, text ":"]) <$> expr ((here, "cases") : p) noArgs t
        Nothing -> pure (text "default:")
      let body = filter (/= Blank) consequent
      cons <- statementSequence ((here, "consequent") : p) consequent
      pure (if null body then label' else case body of
        [Block _] -> cat [label', text " ", cons]
        _ -> cat [label', indent (cat [hardline, cons])])
    pure (cat [group (cat [text "switch (", indent (cat [softline, d]), softline, text ")"]), text " {"
              , if null printed then mempty else indent (cat [hardline, join hardline printed]), hardline, text "}"])
  While test body -> do
    condition <- ifCondition test
    b <- block ((here, "body") : p) body True
    pure (group (cat [text "while (", condition, text ")", text " ", b]))
  Block stmts -> block p stmts False
  Break -> pure (text "break;")
  Continue -> pure (text "continue;")
  FunctionDecl ex async name tps ps rt body -> do
    f <- functionDoc ((here, "declaration") : p) async (Just name) tps ps rt body
    pure (exported ex f)
  ClassDecl ex name tps super implements members -> do
    c <- classDoc ((here, "declaration") : p) name tps super implements members False
    pure (exported ex c)
  Interface ex name tps members -> do
    c <- classDoc ((here, "declaration") : p) name tps Nothing [] members True
    pure (exported ex c)
  TypeAlias ex name tps ty -> do
    let left = cat [text "type ", text name, typeParameterList tps]
    d <- assignment ((here, "declaration") : p) left " =" (Just (Right ty))
    pure (exported ex (cat [d, text ";"]))
  ImportDecl typeOnly spec source -> pure (importDoc typeOnly spec source)
  ExportNamed names source -> pure (cat [text "export", specifiers names, maybe mempty (\src -> text (" from " ++ javascriptLiteral src)) source, text ";"])
  ExportAll source -> pure (text ("export * from " ++ javascriptLiteral source ++ ";"))
  Namespace ex name body -> do
    b <- block ((here, "body") : p) body False
    pure (exported ex (cat [text "namespace ", text name, text " ", b]))
  where
    exported ex d = if ex then cat [text "export ", d] else d
    returnOrThrow keyword e = do
      d <- expr ((NS s, "argument") : p) noArgs e
      let argument = if isBinaryish e
            then group (cat [ifBreak (text "(") mempty, indent (cat [softline, d]), softline, ifBreak (text ")") mempty])
            else d
      pure (cat [text keyword, text " ", argument, text ";"])
    ifCondition test = do
      d <- expr ((NS s, "test") : p) noArgs test
      pure (if shouldInlineCondition test then d else group (cat [indent (cat [softline, d]), softline]))
    shouldInlineCondition e = case e of
      Unary "!" a -> case a of
        Unary "!" b -> isLogical b
        _ -> isLogical a
      _ -> False

specifiers :: [(String, Maybe String)] -> Doc
specifiers names
  | null names = text " {}"
  | length names > 1 = cat [text " ", group (cat [text "{", indent (cat [line, join (cat [text ",", line]) (map spec names)]), ifBreak (text ",") mempty, line, text "}"])]
  | otherwise = cat [text " { ", cat (map spec names), text " }"]
  where spec (n, alias) = text (n ++ maybe "" (" as " ++) alias)

importDoc :: Bool -> Import -> String -> Doc
importDoc typeOnly spec source = cat [text "import", text (if typeOnly then " type" else ""), specs, text (" " ++ javascriptLiteral source), text ";"]
  where
    specs = case spec of
      ImportNamespace n -> text (" * as " ++ n ++ " from")
      ImportDefault n -> text (" " ++ n ++ " from")
      ImportNamed names -> cat [specifiers names, text " from"]
      ImportDefaultNamed n names -> cat [text (" " ++ n ++ ","), specifierGroup names, text " from"]
      ImportEffect -> mempty
    specifierGroup names = cat [text " ", group (cat [text "{", indent (cat [line, join (cat [text ",", line]) [text (n ++ maybe "" (" as " ++) a) | (n, a) <- names]]), ifBreak (text ",") mempty, line, text "}"])]

pattern' :: Pattern -> P Doc
pattern' = patternWith False

-- | A pattern; a function's only object pattern is hugged: its braces
-- break with the parameters rather than in a group of their own.
patternWith :: Bool -> Pattern -> P Doc
patternWith hugged pat = case pat of
  PIdent n -> pure (text n)
  PArray ps -> do
    ds <- mapM pattern' ps
    pure (if null ds then text "[]" else group (cat [text "[", indent (cat [softline, join (cat [text ",", line]) (map group ds)]), ifBreak (text ",") mempty, softline, text "]"]))
  PObject props -> do
    ds <- mapM (\(k, v) -> case v of
      Nothing -> pure (text k)
      Just x -> (\d -> cat [text k, text ": ", d]) <$> pattern' x) props
    let content = cat [text "{", indent (cat [line, join (cat [text ",", line]) ds]), ifBreak (text ",") mempty, line, text "}"]
    pure (if null ds then text "{}" else if hugged then content else group content)

declarator :: Path -> Pattern -> Maybe Type -> Maybe Expr -> P Doc
declarator p pat ty initial = do
  left <- pattern' pat
  annotation <- maybe (pure mempty) (\t -> (\d -> cat [text ": ", d]) <$> typeDoc ((NDeclarator, "id") : p) t) ty
  assignment ((NDeclarator, "init") : p) (cat [left, annotation]) " =" (Left <$> initial)

-- | Prettier's printAssignment: the layout depends on what is assigned.
-- The path's head is the assignment-like node (a declarator, an object
-- property, a class field or a type alias) and the field of its right side.
assignment :: Path -> Doc -> String -> Maybe (Either Expr Type) -> P Doc
assignment p leftDoc operator right = case right of
  Nothing -> pure leftDoc
  Just r -> do
    layout <- chooseLayout p leftDoc r
    rightDoc <- case r of
      Left e -> expr p noArgs { assignmentLayout = Just layout } e
      Right t -> typeAt p (Just layout) t
    assignmentLayoutDoc layout leftDoc operator rightDoc

chooseLayout :: Path -> Doc -> Either Expr Type -> P String
chooseLayout p leftDoc right = do
  let holder = maybe NProgram fst (headMaybe p)
      isProperty = case holder of NProp _ -> True; _ -> False
      hasShortKey = isProperty && shortKey leftDoc
  case right of
    Right t
      | isUnionType t && not (shouldHugUnion t) -> pure "break-after-operator"
      | otherwise -> pure (if not (canBreak leftDoc) && hasShortKey then "never-break-after-operator" else "fluid")
    Left e -> do
      let arrowDeclarator = holder == NDeclarator && isArrowE e
          isArrowE x = case x of Arrow {} -> True; _ -> False
      if arrowDeclarator && canBreak leftDoc then pure "break-lhs" else do
        breakAfter <- shouldBreakAfterOperator p e hasShortKey
        if breakAfter then pure "break-after-operator"
        else if not (canBreak leftDoc) && (hasShortKey || isTemplate e || isBoolLit e || isNumeric e)
          then pure "never-break-after-operator"
          else pure "fluid"
  where
    shortKey d = case flatText d of
      Just t -> stringWidth t < 2 + 3
      Nothing -> False
    isTemplate e = case e of Template _ -> True; _ -> False
    isBoolLit e = case e of BoolLit _ -> True; _ -> False
    isNumeric e = case e of Num _ -> True; BigIntLit _ -> False; _ -> False

flatText :: Doc -> Maybe String
flatText d = if canBreak d then Nothing else case render maxBound 2 d of
  t | '\n' `notElem` t -> Just t
  _ -> Nothing

shouldBreakAfterOperator :: Path -> Expr -> Bool -> P Bool
shouldBreakAfterOperator p e hasShortKey
  | isBinaryish e && not (shouldInlineLogical e) = pure True
  | Conditional test _ _ <- e = pure (isBinaryish test && not (shouldInlineLogical test))
  | hasShortKey = pure False
  | otherwise = do
      let (inner, keys) = unwrap e []
      if isStringLit inner then pure True else poorlyBreakable (keys ++ p) inner False
  where
    unwrap x ks = case x of
      Unary _ a -> unwrap a ((NE x, "argument") : ks)
      Await a -> unwrap a ((NE x, "argument") : ks)
      NonNull a -> unwrap a ((NE x, "expression") : ks)
      _ -> (x, ks)
    isStringLit x = case x of Str _ -> True; _ -> False

-- | isPoorlyBreakableMemberOrCallChain.
poorlyBreakable :: Path -> Expr -> Bool -> P Bool
poorlyBreakable p e deep = case e of
  Call callee targs args _ ->
    if memberChainLabelled p e then pure False else do
      let poor = case args of
            [] -> True
            [a] -> loneShortArgument a
            _ -> False
      if not poor || complexTypeArgs targs then pure False
        else poorlyBreakable ((NE e, "callee") : p) callee True
  Member o _ _ -> poorlyBreakable ((NE e, "object") : p) o True
  Index o _ _ -> poorlyBreakable ((NE e, "object") : p) o True
  Ident _ -> pure deep
  This -> pure deep
  _ -> pure False
  where
    complexTypeArgs ts = length ts > 1 || case ts of
      [t] -> isUnionType t || isObjectTypeT t
      _ -> False

loneShortArgument :: Expr -> Bool
loneShortArgument e = case e of
  This -> True
  Ident n -> length n <= threshold
  Unary op (Num _) | op `elem` ["-", "+"] -> True
  Str s -> length (javascriptLiteral s) <= threshold
  Template [Left raw] -> length raw <= threshold && '\n' `notElem` raw
  Template [] -> True
  Unary _ a -> loneShortArgument a
  Call (Ident n) _ [] _ -> length n <= threshold - 2
  _ -> isLiteral e
  where threshold = width `div` 4

isLiteral :: Expr -> Bool
isLiteral e = case e of
  Str _ -> True
  Num _ -> True
  BigIntLit _ -> True
  BoolLit _ -> True
  Null -> True
  _ -> False

-- Expressions ---------------------------------------------------------------

-- | An expression at a path, with its parentheses when it needs them.
expr :: Path -> Args -> Expr -> P Doc
expr p args e = do
  d <- exprBare p args e
  pure (if needsParens p e then cat [text "(", d, text ")"] else d)

exprBare :: Path -> Args -> Expr -> P Doc
exprBare p args e = let here = NE e in case e of
  Ident n -> pure (text n)
  This -> pure (text "this")
  BoolLit b -> pure (text (if b then "true" else "false"))
  Null -> pure (text "null")
  Str s -> pure (text (javascriptLiteral s))
  Num raw -> pure (text (printNumber raw))
  BigIntLit raw -> pure (text (map toLower raw ++ "n"))
  Template parts -> do
    d <- dialect
    pure (cat ([text "`"] ++ [case part of
      Left raw -> text raw
      Right x -> text ("${" ++ flatRender d ((here, "expressions") : p) x ++ "}") | part <- parts] ++ [text "`"]))
  Member {} -> memberExpression p e
  Index {} -> memberExpression p e
  Call {} -> callExpression p args e
  New {} -> callExpression p args e
  Arrow {} -> arrowFunction p args e
  Function async name ps rt body -> functionDoc p async name [] ps rt body
  Object props -> objectDoc p e props
  Array items -> arrayDoc p e items
  Spread a -> (\d -> cat [text "...", d]) <$> expr ((here, "argument") : p) noArgs a
  Unary op a -> do
    d <- expr ((here, "argument") : p) noArgs a
    pure (cat [text op, if not (null op) && isAsciiLower (last op) then text " " else mempty, d])
  Await a -> do
    d <- expr ((here, "argument") : p) noArgs a
    let parts = cat [text "await ", d]
    pure $ case p of
      (NE (Call callee _ _ _), "callee") : _ | callee == e -> awaitGroup parts
      (NE (Member o _ _), "object") : _ | o == e -> awaitGroup parts
      (NE (Index o _ _), "object") : _ | o == e -> awaitGroup parts
      _ -> parts
  Binary {} -> binaryish p e
  Conditional {} -> ternary p e
  Assign op l r -> do
    left <- expr ((here, "left") : p) noArgs l
    assignmentExpr p left (" " ++ op) r
  As a t -> do
    d <- expr ((here, "expression") : p) noArgs a
    td <- typeDoc ((here, "typeAnnotation") : p) t
    let parts = cat [d, text " as ", td]
    pure $ case p of
      (NE (Call _ _ _ _), "callee") : _ -> group (cat [indent (cat [softline, parts]), softline])
      (NE (New _ _ _), "callee") : _ -> group (cat [indent (cat [softline, parts]), softline])
      (NE (Member _ _ _), "object") : _ -> group (cat [indent (cat [softline, parts]), softline])
      (NE (Index _ _ _), "object") : _ -> group (cat [indent (cat [softline, parts]), softline])
      _ -> parts
  NonNull a -> (\d -> cat [d, text "!"]) <$> expr ((here, "expression") : p) noArgs a
  where
    awaitGroup parts = group (cat [indent (cat [softline, parts]), softline])

-- | An expression on one line, however long.
printFlat :: Dialect -> Expr -> String
printFlat d e = render maxBound 2 (evalState (expr [(NS (ExprStmt e), "expression")] noArgs e) (d, 0))

-- | A type on one line.
printType :: Type -> String
printType t = render maxBound 2 (evalState (typeDoc [] t) (TypeScript, 0))

flatRender :: Dialect -> Path -> Expr -> String
flatRender d p e = render maxBound 2 (evalState (expr p noArgs e) (d, 100000))

assignmentExpr :: Path -> Doc -> String -> Expr -> P Doc
assignmentExpr p left operator right = assignmentWith ((NE (Assign (drop 1 operator) (Ident "") right), "right") : p) left operator right

-- | printAssignment for an expression right side, with the fluid layout's id.
assignmentWith :: Path -> Doc -> String -> Expr -> P Doc
assignmentWith p leftDoc operator right = do
  layout <- chooseLayout p leftDoc (Left right)
  rightDoc <- expr p noArgs { assignmentLayout = Just layout } right
  assignmentLayoutDoc layout leftDoc operator rightDoc

assignmentLayoutDoc :: String -> Doc -> String -> Doc -> P Doc
assignmentLayoutDoc layout leftDoc operator rightDoc = case layout of
  "break-after-operator" -> pure (group (cat [group leftDoc, text operator, group (indent (cat [line, rightDoc]))]))
  "never-break-after-operator" -> pure (group (cat [group leftDoc, text operator, text " ", rightDoc]))
  "break-lhs" -> pure (group (cat [leftDoc, text operator, text " ", group rightDoc]))
  "chain" -> pure (cat [group leftDoc, text operator, line, rightDoc])
  "chain-tail" -> pure (cat [group leftDoc, text operator, indent (cat [line, rightDoc])])
  "only-left" -> pure leftDoc
  _ -> do
    gid <- fresh
    pure (group (cat [group leftDoc, text operator, groupWithId gid False (indent line), indentIfBreak gid rightDoc]))

-- Member expressions and calls ---------------------------------------------

memberExpression :: Path -> Expr -> P Doc
memberExpression p e = do
  let here = NE e
      (object, computed) = case e of
        Member o _ _ -> (o, False)
        Index o _ _ -> (o, True)
        _ -> error "member"
  objectPrinted <- expr ((here, "object") : p) noArgs object
  lookup' <- memberLookup p e
  let firstNonMember = maybe NProgram id (headMaybe [n | (n, _) <- p, not (isMemberNode n)])
      shouldInline =
        computed ||
        (isIdentifier object && not (isMemberNode (fst (headOr p)))) ||
        ((firstNonMember == NDeclarator || isAssignNode firstNonMember) && (isCallWithArguments object || labelOf objectPrinted == Just "member-chain"))
        || newCallee p
  pure (relabel objectPrinted (cat [objectPrinted, if shouldInline then lookup' else group (indent (cat [softline, lookup']))]))
  where
    headOr xs = case xs of
      x : _ -> x
      [] -> (NProgram, "")
    isIdentifier x = case x of Ident _ -> True; _ -> False
    isCallWithArguments x = case x of Call _ _ (_ : _) _ -> True; _ -> False
    relabel printed d = maybe d (`label` d) (labelOf printed)
    -- new a.b.c(): the callee's lookups stay inline.
    newCallee ((NE (Member _ _ _), "object") : rest) = newCallee rest
    newCallee ((NE (Index _ _ _), "object") : rest) = newCallee rest
    newCallee ((NE (New _ _ _), "callee") : _) = True
    newCallee _ = False

isMemberNode :: Node -> Bool
isMemberNode n = case n of
  NE (Member {}) -> True
  NE (Index {}) -> True
  NE (NonNull _) -> True
  _ -> False

isAssignNode :: Node -> Bool
isAssignNode n = case n of NE (Assign {}) -> True; _ -> False

memberLookup :: Path -> Expr -> P Doc
memberLookup p e = case e of
  Member _ name optional -> pure (cat [text (if optional then "?" else ""), text ".", text name])
  Index _ i optional -> do
    d <- expr ((NE e, "property") : p) noArgs i
    let opt = text (if optional then "?." else "")
    pure $ case i of
      Num _ -> cat [opt, text "[", d, text "]"]
      _ -> group (cat [opt, text "[", indent (cat [softline, d]), softline, text "]"])
  _ -> pure mempty

isMemberish :: Expr -> Bool
isMemberish e = case e of
  Member {} -> True
  Index {} -> True
  _ -> False

isCallExpr :: Expr -> Bool
isCallExpr e = case e of
  Call {} -> True
  _ -> False

callExpression :: Path -> Args -> Expr -> P Doc
callExpression p _ e = do
  let here = NE e
      (callee, targs, args, optional, isNew) = case e of
        Call c t a o -> (c, t, a, o, False)
        New c t a -> (c, t, a, False, True)
        _ -> error "call"
  typeArgsDoc <- typeArguments ((here, "typeArguments") : p) targs
  if not isNew && isTestCall e (fst <$> headMaybe p)
    then do
      calleeDoc <- expr ((here, "callee") : p) noArgs callee
      printed <- zipWithM (\_ a -> expr ((here, "arguments") : p) noArgs a) [0 :: Int ..] args
      pure (cat [calleeDoc, text (if optional then "?." else ""), typeArgsDoc, text "(", join (text ", ") printed, text ")"])
    else if not isNew && isMemberish callee && not (needsParens ((here, "callee") : p) callee)
      then memberChain p e
      else do
        calleeDoc <- expr ((here, "callee") : p) noArgs callee
        argsDoc <- callArguments p e
        let contents = cat [if isNew then text "new " else mempty, calleeDoc, text (if optional then "?." else ""), typeArgsDoc, argsDoc]
        pure (if isCallExpr callee then group contents else contents)

headMaybe :: [a] -> Maybe a
headMaybe xs = case xs of
  x : _ -> Just x
  [] -> Nothing

callArgumentsOf :: Expr -> [Expr]
callArgumentsOf e = case e of
  Call _ _ a _ -> a
  New _ _ a -> a
  _ -> []

-- | isTestCall: test("name", () => {...}) keeps its arguments on one line.
isTestCall :: Expr -> Maybe Node -> Bool
isTestCall e _ = case e of
  Call callee _ args False
    | length args `elem` [2, 3], all isStringOrTemplate (take 1 args), calleeName callee `elem` testCallees ->
        case args of
          [_, f] -> isFunctionOrArrow f
          [_, f, third] -> isNumberLit third && isFunctionWithBody f && length (functionParams f) <= 1
          _ -> False
  _ -> False
  where
    isStringOrTemplate x = case x of Str _ -> True; Template _ -> True; _ -> False
    isNumberLit x = case x of Num _ -> True; _ -> False
    testCallees = words "it it.only it.skip describe describe.only describe.skip test test.only test.skip test.fixme test.step test.describe test.describe.only test.describe.skip test.describe.fixme test.describe.parallel test.describe.parallel.only test.describe.serial test.describe.serial.only skip xit xdescribe xtest fit fdescribe ftest"

calleeName :: Expr -> String
calleeName e = case e of
  Ident n -> n
  Member o n False -> calleeName o ++ "." ++ n
  _ -> "\0"

isFunctionOrArrow :: Expr -> Bool
isFunctionOrArrow e = case e of
  Arrow {} -> True
  Function {} -> True
  _ -> False

isFunctionWithBody :: Expr -> Bool
isFunctionWithBody e = case e of
  Function {} -> True
  Arrow _ _ _ (BlockBody _) -> True
  _ -> False

functionParams :: Expr -> [Param]
functionParams e = case e of
  Arrow _ ps _ _ -> ps
  Function _ _ ps _ _ -> ps
  _ -> []

-- | printCallArguments.
callArguments :: Path -> Expr -> P Doc
callArguments p e = do
  let here = NE e
      args = callArgumentsOf e
      argPath = (here, "arguments") : p
  if null args then pure (text "()") else
    if reactHookCallWithDeps args then do
      printed <- mapM (expr argPath noArgs) args
      pure (cat [text "(", join (text ", ") printed, text ")"])
    else do
      -- An arrow's body is printed once; its plain and expanded forms share it.
      shared <- mapM (\a -> case a of
        Arrow _ _ _ body | not (arrowBodied body) -> do
          b <- arrowBody argPath noArgs a
          plain <- arrowWith argPath noArgs a b
          pure (plain, Just b)
        _ -> (\d -> (d, Nothing)) <$> expr argPath noArgs a) args
      let printedPlain = map fst shared
          expandedWith flags i = case (args !! i, snd (shared !! i)) of
            (a, Just b) -> arrowWith argPath flags a b
            (a, Nothing) -> expr argPath flags a
      let n = length args
          printed = [if i == n - 1 then d else cat [d, text ",", line] | (i, d) <- zip [0 ..] printedPlain]
          allBroken = groupBroken True (cat [text "(", indent (cat (line : printed)), ifBreak (text ",") mempty, line, text ")"])
      if functionCompositionArguments args then pure allBroken
      else if shouldExpandFirstArg args then do
        let tailArgs = drop 1 printed
        if any willBreak tailArgs then pure allBroken else do
          firstArg <- expandedWith noArgs { expandFirstArg = True } 0
          firstExpanded <- pure firstArg
          if willBreak firstExpanded
            then pure (cat [breakParent, conditionalGroup
              [ cat ([text "(", groupBroken True firstExpanded, text ", "] ++ tailArgs ++ [text ")"]), allBroken ]])
            else pure (conditionalGroup
              [ cat ([text "(", firstExpanded, text ", "] ++ tailArgs ++ [text ")"])
              , cat ([text "(", groupBroken True firstExpanded, text ", "] ++ tailArgs ++ [text ")"])
              , allBroken ])
      else if shouldExpandLastArg args then do
        let headArgs = init printed
        if any willBreak headArgs then pure allBroken else do
          lastArg <- expandedWith noArgs { expandLastArg = True } (length args - 1)
          bail <- expansionBails (last args)
          if bail then pure allBroken else
            if willBreak lastArg
              then pure (cat [breakParent, conditionalGroup
                [ cat ([text "("] ++ headArgs ++ [groupBroken True lastArg, text ")"]), allBroken ]])
              else pure (conditionalGroup
                [ cat ([text "("] ++ headArgs ++ [lastArg, text ")"])
                , cat ([text "("] ++ headArgs ++ [groupBroken True lastArg, text ")"])
                , allBroken ])
      else do
        let contents = cat [text "(", indent (cat (softline : printed)), ifBreak (text ",") mempty, softline, text ")"]
        if longCurried p e then pure contents
          else pure (groupBroken (any willBreak printed) contents)
  where
    -- An expanded function's parameters or return type that would break
    -- abandon the expansion (ArgExpansionBailout).
    expansionBails a = case a of
      Arrow _ ps rt _ -> paramsBreak ps rt
      Function _ _ ps rt _ -> paramsBreak ps rt
      _ -> pure False
    paramsBreak ps rt = do
      docs <- mapM (paramDoc []) ps
      rtd <- maybe (pure mempty) (typeDoc []) rt
      pure (any willBreak docs || willBreak rtd)

-- | A body whose printing depends on the expansion flags (an arrow chain).
arrowBodied :: Body -> Bool
arrowBodied body = case body of
  ExpressionBody (Arrow {}) -> True
  ExpressionBody (Function {}) -> True
  _ -> False

longCurried :: Path -> Expr -> Bool
longCurried p e = case p of
  (NE parent@(Call _ _ _ _), "callee") : _ -> isCallExpr e && not (null (callArgumentsOf parent)) && length (callArgumentsOf e) > length (callArgumentsOf parent)
  _ -> False

reactHookCallWithDeps :: [Expr] -> Bool
reactHookCallWithDeps args = case args of
  [f, Array _] -> hook f
  [Ident _, f, Array _] -> hook f
  _ -> False
  where hook f = case f of
          Arrow _ [] _ (BlockBody _) -> True
          _ -> False

functionCompositionArguments :: [Expr] -> Bool
functionCompositionArguments args
  | length args <= 1 = False
  | otherwise = go (0 :: Int) args
  where
    go _ [] = False
    go count (a : rest)
      | isFunctionOrArrow a = if count + 1 > 1 then True else go (count + 1) rest
      | isCallExpr a && any isFunctionOrArrow (callArgumentsOf a) = True
      | otherwise = go count rest

couldExpandArg :: Bool -> Expr -> Bool
couldExpandArg chainRecursion arg = case arg of
  Object (_ : _) -> True
  Array (_ : _) -> True
  As a _ -> couldExpandArg False a
  Function {} -> True
  Arrow _ _ _ body -> case body of
    BlockBody _ -> True
    ExpressionBody b -> case b of
      Object _ -> True
      Array _ -> True
      Arrow {} -> couldExpandArg True b
      Conditional {} | not chainRecursion -> True
      Call {} | not chainRecursion -> True
      New {} | not chainRecursion -> False
      _ -> False
  _ -> False

shouldExpandLastArg :: [Expr] -> Bool
shouldExpandLastArg args =
  couldExpandArg False lastArg &&
  maybe True (\pen -> exprType pen /= exprType lastArg) penultimate &&
  (length args /= 2 || maybe True (\pen -> exprType pen /= "ArrowFunctionExpression") penultimate || not (isArrayExpr lastArg)) &&
  not (length args > 1 && conciselyPrintedArray lastArg)
  where
    lastArg = last args
    penultimate = if length args >= 2 then Just (args !! (length args - 2)) else Nothing
    isArrayExpr x = case x of Array _ -> True; _ -> False

shouldExpandFirstArg :: [Expr] -> Bool
shouldExpandFirstArg args = case args of
  [first, second] ->
    (isFunctionExprE first || isArrowWithBlock first) &&
    not (isFunctionExprE second) && not (isArrowE second) && not (isConditionalE second) &&
    hopefullyShort second && not (couldExpandArg False second)
  _ -> False
  where
    isFunctionExprE x = case x of Function {} -> True; _ -> False
    isArrowWithBlock x = case x of Arrow _ _ _ (BlockBody _) -> True; _ -> False
    isArrowE x = case x of Arrow {} -> True; _ -> False
    isConditionalE x = case x of Conditional {} -> True; _ -> False
    hopefullyShort x = case x of
      Call _ _ as' _ | length as' > 1 -> False
      New _ _ as' | length as' > 1 -> False
      Binary _ l r -> simpleCallArgument 1 l && simpleCallArgument 1 r
      _ -> simpleCallArgument 2 x

conciselyPrintedArray :: Expr -> Bool
conciselyPrintedArray e = case e of
  Array items@(_ : _) -> all numeric items
  _ -> False
  where
    numeric x = case x of
      Num _ -> True
      BigIntLit _ -> False
      Unary op (Num _) -> op `elem` ["-", "+"]
      _ -> False

simpleCallArgument :: Int -> Expr -> Bool
simpleCallArgument depth node
  | depth <= 0 = False
  | otherwise = case node of
      _ | isLiteral node -> True
      Ident _ -> True
      This -> True
      Template parts -> all (\part -> either ('\n' `notElem`) child part) parts
      Object props -> all (\prop -> case prop of
        Prop (KComputed _) _ -> False
        Prop _ v -> child v
        Shorthand _ -> True
        SpreadProp _ -> False
        CommentedProp _ _ -> False) props
      Array items -> all child items
      Call callee _ args _ -> simpleCallArgument depth callee && length args <= depth && all child args
      New callee _ args -> simpleCallArgument depth callee && length args <= depth && all child args
      Member o _ _ -> simpleCallArgument depth o
      Index o i _ -> simpleCallArgument depth o && simpleCallArgument depth i
      Unary op a | op `elem` ["!", "-", "+", "~"] -> simpleCallArgument depth a
      _ -> False
  where child = simpleCallArgument (depth - 1)

exprType :: Expr -> String
exprType e = case e of
  Ident _ -> "Identifier"
  This -> "ThisExpression"
  BoolLit _ -> "BooleanLiteral"
  Null -> "NullLiteral"
  Str _ -> "StringLiteral"
  Num _ -> "NumericLiteral"
  BigIntLit _ -> "BigIntLiteral"
  Template _ -> "TemplateLiteral"
  Member {} -> "MemberExpression"
  Index {} -> "MemberExpression"
  Call {} -> "CallExpression"
  New {} -> "NewExpression"
  Arrow {} -> "ArrowFunctionExpression"
  Function {} -> "FunctionExpression"
  Object _ -> "ObjectExpression"
  Array _ -> "ArrayExpression"
  Spread _ -> "SpreadElement"
  Unary _ _ -> "UnaryExpression"
  Binary op _ _ -> if op `elem` ["&&", "||", "??"] then "LogicalExpression" else "BinaryExpression"
  Conditional {} -> "ConditionalExpression"
  Await _ -> "AwaitExpression"
  Assign {} -> "AssignmentExpression"
  As _ _ -> "TSAsExpression"
  NonNull _ -> "TSNonNullExpression"

-- | printMemberChain.
memberChain :: Path -> Expr -> P Doc
memberChain p e = do
  -- The chain's pieces, from its head to this call.
  printedNodes <- collect p e True
  let (groups, shouldMerge) = chainGroups (isExpressionStatement p) printedNodes
      printGroup g = cat (map piecePrinted g)
      printedGroups = map printGroup groups
      oneLine = cat printedGroups
      cutoff = if shouldMerge then 3 else 2
      indentedGroup gs = if null gs then mempty else indent (cat [hardline, join hardline (map printGroup gs)])
      expanded = cat [ cat (map printGroup (take 1 groups))
                     , if shouldMerge then cat (map printGroup (take 1 (drop 1 groups))) else mempty
                     , indentedGroup (drop (if shouldMerge then 2 else 1) groups) ]
      callExpressions = [n | Piece n _ True <- printedNodes]
      lastGroupWillBreakAndOtherCallsHaveFunctionArguments =
        case reverse (concat (take 1 (reverse groups))) of
          Piece _ _ True : _ -> willBreak (last printedGroups) &&
            any (any isFunctionOrArrow . callArgumentsOf) (init callExpressions)
          _ -> False
  if length groups <= cutoff
    then pure (if longCurried p e then oneLine else group oneLine)
    else do
      let result
            | (length callExpressions > 2 && any (any (not . simpleCallArgument 2) . callArgumentsOf) callExpressions)
              || any willBreak (init printedGroups)
              || lastGroupWillBreakAndOtherCallsHaveFunctionArguments = group expanded
            | otherwise = cat [if willBreak oneLine then breakParent else mempty, conditionalGroup [oneLine, expanded]]
      pure (label "member-chain" result)

isExpressionStatement :: Path -> Bool
isExpressionStatement p = case p of
  (NS (ExprStmt _), _) : _ -> True
  _ -> False

-- | Whether a call prints as a member chain labelled so (more groups than
-- fit on one line by the rule), from its shape alone.
memberChainLabelled :: Path -> Expr -> Bool
memberChainLabelled p e = case e of
  Call callee _ _ _ | not (isTestCall e Nothing), isMemberish callee, not (needsParens ((NE e, "callee") : p) callee) ->
    let (groups, shouldMerge) = chainGroups (isExpressionStatement p) (shapeOf p e True)
    in length groups > (if shouldMerge then 3 else 2)
  _ -> False

-- | The groups of a chain's pieces, and whether the first two merge.
chainGroups :: Bool -> [Piece] -> ([[Piece]], Bool)
chainGroups expressionStatement printedNodes = (groups, shouldMerge)
  where
    -- groups[0]: the head, then calls and numeric indexes right after it.
    (firstGroup, restStart) = firstGroupOf printedNodes
    groups = firstGroup : splitGroups (drop restStart printedNodes)
    shouldNotWrap gs = case gs of
      (g0 : g1 : _) ->
        let hasComputed = case g1 of
              (Piece (Index {}) _ _ : _) -> True
              _ -> False
        in if length g0 == 1
          then case map pieceNode (take 1 g0) of
            [This] -> True
            [Ident name] -> isFactory name || (expressionStatement && length name <= 2) || hasComputed
            _ -> False
          else case pieceNode (last g0) of
            Member _ name _ -> isFactory name || hasComputed
            _ -> False
      _ -> False
    shouldMerge = length groups >= 2 && not (null (groups !! 1)) && shouldNotWrap groups
    isFactory name = case name of
      c : _ | isAsciiUpper c -> True
      _ -> not (null name) && all (`elem` ("$_" :: String)) name
    firstGroupOf nodes = case nodes of
      [] -> ([], 0)
      (n0 : rest) ->
        let calls = takeWhile (\pc -> pieceIsCall pc || numericIndex pc) rest
            i = 1 + length calls
            g = n0 : calls
        in if pieceIsCall n0 then (g, i)
          else let more = membersRun (drop i nodes)
               in (g ++ more, i + length more)
    -- After a non-call head: members followed by members join the head.
    membersRun ns = case ns of
      (a : b : rest) | isMemberPiece a && isMemberPiece b -> a : membersRun (b : rest)
      _ -> []
    splitGroups ns = go [] False ns
      where
        go current _ [] = [reverse current | not (null current)]
        go current seenCall (n : rest)
          | seenCall && isMemberPiece n && not (numericIndex n) = reverse current : go [n] False rest
          | seenCall && isMemberPiece n = go (n : current) seenCall rest
          | otherwise = go (n : current) (seenCall || pieceIsCall n) rest
    numericIndex pc = case pieceNode pc of
      Index _ (Num _) _ -> not (pieceIsCall pc)
      _ -> False
    isMemberPiece pc = not (pieceIsCall pc) && isMemberish (pieceNode pc)

-- | A chain's pieces without their printing (collect's shape).
shapeOf :: Path -> Expr -> Bool -> [Piece]
shapeOf p node isRoot = case node of
  Call callee _ _ _
    | isRoot || ((isMemberish callee || isCallExpr callee) && not (needsParens p node)) ->
        (if isRoot && not (isMemberish callee || isCallExpr callee) then [Piece callee mempty False]
         else shapeOf ((NE node, "callee") : p) callee False) ++ [Piece node mempty True]
  _ | isMemberish node && not (needsParens p node) ->
        let object = case node of
              Member o _ _ -> o
              Index o _ _ -> o
              _ -> node
        in shapeOf ((NE node, "object") : p) object False ++ [Piece node mempty False]
  NonNull inner | not (needsParens p node) -> shapeOf ((NE node, "expression") : p) inner False ++ [Piece node mempty False]
  _ -> [Piece node mempty False]

data Piece = Piece { pieceNode :: Expr, piecePrinted :: Doc, pieceIsCall :: Bool }

-- | The printed pieces of a chain, head first (member-chain.js's rec).
collect :: Path -> Expr -> Bool -> P [Piece]
collect p node isRoot = case node of
  Call callee targs _ optional
    | isRoot || ((isMemberish callee || isCallExpr callee) && not (needsParens p node)) -> do
        typeArgsDoc <- typeArguments ((NE node, "typeArguments") : p) targs
        argsDoc <- callArguments p node
        let printed = cat [text (if optional then "?." else ""), typeArgsDoc, argsDoc]
        rest <- if isRoot && not (isMemberish callee || isCallExpr callee)
          then (: []) . (\d -> Piece callee d False) <$> expr ((NE node, "callee") : p) noArgs callee
          else collect ((NE node, "callee") : p) callee False
        pure (rest ++ [Piece node printed True])
  _ | isMemberish node && not (needsParens p node) -> do
        lookup' <- memberLookup p node
        let object = case node of
              Member o _ _ -> o
              Index o _ _ -> o
              _ -> node
        rest <- collect ((NE node, "object") : p) object False
        pure (rest ++ [Piece node lookup' False])
  NonNull inner | not (needsParens p node) -> do
        rest <- collect ((NE node, "expression") : p) inner False
        pure (rest ++ [Piece node (text "!") False])
  _ -> do
        d <- expr p noArgs node
        pure [Piece node d False]

-- Functions -----------------------------------------------------------------

paramDoc :: Path -> Param -> P Doc
paramDoc = paramDocWith False

paramDocWith :: Bool -> Path -> Param -> P Doc
paramDocWith hugged p (Param pat ty def rest) = do
  patDoc <- patternWith hugged pat
  tyDoc <- maybe (pure mempty) (\t -> (\d -> cat [text ": ", d]) <$> typeDoc ((NParam (Param pat ty def rest), "typeAnnotation") : p) t) ty
  defDoc <- maybe (pure mempty) (\d -> (\x -> cat [text " = ", x]) <$> expr p noArgs d) def
  pure (cat [if rest then text "..." else mempty, patDoc, tyDoc, defDoc])

-- | printFunctionParameters.
functionParameters :: Path -> [Param] -> Bool -> Bool -> P Doc
functionParameters p ps expand inTestCall = do
  printed <- mapM (paramDocWith (shouldHugTheOnlyParameter ps) p) ps
  let hasRest = any paramRest ps
      separated = concat [ if i == length printed - 1 then [d] else [d, text ",", if inTestCall || hug then text " " else line]
                         | (i, d) <- zip [0 ..] printed ]
      hug = shouldHugTheOnlyParameter ps
  if null ps then pure (text "()")
  else if expand then pure (group (cat [text "(", removeLines (cat separated), text ")"]))
  else if hug || inTestCall then pure (cat ([text "("] ++ separated ++ [text ")"]))
  else pure (cat [text "(", indent (cat (softline : separated)), if hasRest then mempty else ifBreak (text ",") mempty, softline, text ")"])

shouldHugTheOnlyParameter :: [Param] -> Bool
shouldHugTheOnlyParameter ps = case ps of
  [Param (PArray _) _ _ _] -> True
  [Param (PObject _) _ _ _] -> True
  [Param (PIdent _) (Just t) _ _] -> isObjectTypeT t
  _ -> False

isObjectTypeT :: Type -> Bool
isObjectTypeT t = case t of TObject _ -> True; _ -> False

returnTypeDoc :: Path -> Maybe Type -> P Doc
returnTypeDoc p rt = case rt of
  Nothing -> pure mempty
  Just t -> (\d -> cat [text ": ", d]) <$> typeDoc p t

shouldGroupParameters :: [String] -> [Param] -> Maybe Type -> Doc -> Bool
shouldGroupParameters tps ps rt rtDoc = case rt of
  Nothing -> False
  Just t -> length tps <= 1 && length ps == 1 && (isObjectTypeT t || willBreak rtDoc)

functionDoc :: Path -> Bool -> Maybe String -> [String] -> [Param] -> Maybe Type -> [Stmt] -> P Doc
functionDoc p async name tps ps rt body = do
  paramsDoc <- functionParameters p ps False False
  rtDoc <- returnTypeDoc p rt
  b <- block p body True
  let grouped = if shouldGroupParameters tps ps rt rtDoc then group paramsDoc else paramsDoc
  pure (cat [ if async then text "async " else mempty, text "function ", maybe mempty text name, typeParameterList tps
            , group (cat [grouped, rtDoc]), text " ", b ])

typeParameterList :: [String] -> Doc
typeParameterList tps = if null tps then mempty else text ("<" ++ commaJoined tps ++ ">")
  where commaJoined = foldr1 (\a b -> a ++ ", " ++ b)

-- | An arrow function.
arrowFunction :: Path -> Args -> Expr -> P Doc
arrowFunction p args e = arrowBody p args e >>= arrowWith p args e

-- | An arrow's body, printed once; how the arrow is laid out around it
-- depends on where it is (arrowWith).
arrowBody :: Path -> Args -> Expr -> P Doc
arrowBody p args e = case e of
  Arrow _ _ _ body -> case body of
    BlockBody stmts -> block ((NE e, "body") : p) stmts True
    ExpressionBody b -> expr ((NE e, "body") : p) args b
  _ -> pure mempty

-- | printArrowFunction, without arrow chains (generated code has none).
arrowWith :: Path -> Args -> Expr -> Doc -> P Doc
arrowWith p args e bodyDoc = case e of
  Arrow async ps rt body -> do
    let expand = expandLastArg args || expandFirstArg args
        inTestCall = case p of
          (NE parent, "arguments") : rest -> isTestCall parent (fst <$> headMaybe rest)
          _ -> False
    paramsDoc <- functionParameters p ps expand inTestCall
    rtDoc0 <- returnTypeDoc p rt
    let rtDoc = if expand then group (removeLines rtDoc0) else rtDoc0
        signature = cat [if async then text "async " else mempty, group (cat [paramsDoc, rtDoc])]
    let shouldPutBodyOnSameLine = case body of
          BlockBody _ -> True
          ExpressionBody b -> mayBreakAfterShortPrefix b || addParensIfNotBreak b
        trailingComma = if expandLastArg args then ifBreak (text ",") mempty else mempty
        trailingSpace = if expandLastArg args then softline else mempty
        printedBody = case body of
          ExpressionBody b | shouldPutBodyOnSameLine && addParensIfNotBreak b ->
            cat [text " ", group (cat [ifBreak mempty (text "("), indent (cat [softline, bodyDoc]), ifBreak mempty (text ")"), trailingComma, trailingSpace])]
          _ | shouldPutBodyOnSameLine -> cat [text " ", bodyDoc]
            | otherwise -> cat [indent (cat [line, bodyDoc]), trailingComma, trailingSpace]
    pure (group (cat [group signature, text " =>", group printedBody]))
  _ -> error "arrow"
  where
    mayBreakAfterShortPrefix b = case b of
      Array _ -> True
      Object _ -> True
      Arrow {} -> True
      _ -> False
    addParensIfNotBreak b = case b of
      Conditional {} -> not (startsWithObject b)
      _ -> False
    startsWithObject x = case x of
      Object _ -> True
      Conditional t _ _ -> startsWithObject t
      Binary _ l _ -> startsWithObject l
      Call c _ _ _ -> startsWithObject c
      Member o _ _ -> startsWithObject o
      Index o _ _ -> startsWithObject o
      As a _ -> startsWithObject a
      NonNull a -> startsWithObject a
      _ -> False

-- Objects and arrays --------------------------------------------------------

objectDoc :: Path -> Expr -> [Prop] -> P Doc
objectDoc p e props = do
  d <- dialect
  let here = NE e
  printed <- forM props (propDoc d here)
  if null printed then pure (text "{}") else
    pure (group (cat [text "{", indent (cat [line, join (cat [text ",", line]) printed]), ifBreak (text ",") mempty, line, text "}"]))
  where
    simpleNumber s = not (null s) && all isDigit s && (s == "0" || take 1 s /= "0")
    propDoc d here prop = case prop of
      CommentedProp ls inner -> do
        x <- propDoc d here inner
        pure (cat [join hardline (map text ls), hardline, x])
      _ -> propDoc' d here prop
    propDoc' d here prop = case prop of
        Shorthand n -> pure (text n)
        SpreadProp a -> (\x -> cat [text "...", x]) <$> expr ((NProp prop, "argument") : (here, "properties") : p) noArgs a
        Prop key value -> do
          keyDoc <- case key of
            KName n -> pure (text n)
            KString s
              | isIdentifierName s -> pure (text s)
              | d == JavaScript && simpleNumber s -> pure (text s)
              | otherwise -> pure (text (javascriptLiteral s))
            KComputed k -> (\x -> cat [text "[", x, text "]"]) <$> expr ((NProp prop, "key") : (here, "properties") : p) noArgs k
          assignmentWith ((NProp prop, "value") : (here, "properties") : p) keyDoc ":" value
        CommentedProp _ inner -> propDoc' d here inner

arrayDoc :: Path -> Expr -> [Expr] -> P Doc
arrayDoc p e items = do
  let here = NE e
  if null items then pure (text "[]") else do
    printed <- mapM (expr ((here, "elements") : p) noArgs) items
    gid <- fresh
    let shouldBreak = length items > 1 && all objectOrArrayWithMany items && sameTypes items
        concise = conciselyPrintedArray e
        trailing = if concise then ifBreakFor gid (text ",") mempty else ifBreak (text ",") mempty
        elements = if concise
          then fill (concat [ if i == length printed - 1 then [cat [d, trailing]] else [cat [d, text ","], line]
                            | (i, d) <- zip [0 :: Int ..] printed ])
          else cat [join (cat [text ",", line]) (map group printed), trailing]
    pure (groupWithId gid shouldBreak (cat [text "[", indent (cat [softline, elements]), softline, text "]"]))
  where
    objectOrArrayWithMany x = case x of
      Array xs -> length xs > 1
      Object ps -> length ps > 1
      _ -> False
    sameTypes xs = all (== map exprType (take 1 xs)) [[exprType x] | x <- xs]

-- Binary and logical expressions ---------------------------------------------

isBinaryish :: Expr -> Bool
isBinaryish e = case e of
  Binary {} -> True
  _ -> False

isLogical :: Expr -> Bool
isLogical e = case e of
  Binary op _ _ -> op `elem` ["&&", "||", "??"]
  _ -> False

shouldInlineLogical :: Expr -> Bool
shouldInlineLogical e = case e of
  Binary op _ r | op `elem` ["&&", "||", "??"] -> case r of
    Object (_ : _) -> True
    Array (_ : _) -> True
    _ -> False
  _ -> False

precedence :: String -> Int
precedence op = case lookup op table of
  Just n -> n
  Nothing -> -1
  where
    table = concat [[(o, i) | o <- os] | (i, os) <- zip [0 ..]
      [["|>"], ["??"], ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "===", "!=", "!=="]
      , ["<", ">", "<=", ">=", "in", "instanceof"], [">>", "<<", ">>>"], ["+", "-"], ["*", "/", "%"], ["**"]]]

shouldFlatten :: String -> String -> Bool
shouldFlatten parentOp nodeOp
  | precedence nodeOp /= precedence parentOp = False
  | parentOp == "**" = False
  | equality parentOp && equality nodeOp = False
  | (nodeOp == "%" && multiplicative parentOp) || (parentOp == "%" && multiplicative nodeOp) = False
  | nodeOp /= parentOp && multiplicative nodeOp && multiplicative parentOp = False
  | bitshift parentOp && bitshift nodeOp = False
  | otherwise = True
  where
    equality o = o `elem` ["==", "!=", "===", "!=="]
    multiplicative o = o `elem` ["*", "/", "%"]
    bitshift o = o `elem` [">>", ">>>", "<<"]

binaryish :: Path -> Expr -> P Doc
binaryish p e = do
  let (parent, key) = case p of
        x : _ -> x
        [] -> (NProgram, "")
      isInsideParenthesis = key /= "body" && case parent of
        NS (If {}) -> True
        NS (IfSingle {}) -> True
        NS (While {}) -> True
        _ -> False
  parts <- binaryishParts p e isInsideParenthesis
  let grandparent = case p of
        _ : g : _ -> Just (fst g)
        _ -> Nothing
      (op, left) = case e of
        Binary o l _ -> (o, l)
        _ -> ("", e)
  if isInsideParenthesis then pure (cat parts) else
    if (key == "callee" && isCallOrNewNode parent) || isUnaryNode parent || (isMemberNode parent && not (isIndexNode parent) && key == "object")
      then pure (group (cat [indent (cat (softline : parts)), softline]))
      else do
        let shouldNotIndent =
              isReturnOrThrow parent ||
              (key == "body" && isArrowNode parent) ||
              (isConditionalNode parent && not (maybe False isReturnOrThrow grandparent) && not (maybe False isCallOrNewNode grandparent)) ||
              isTemplateNode parent ||
              (key == "argument" && isUnaryNode parent)
            shouldIndentIfInlining = parent == NDeclarator || isAssignNode parent || isPropNode parent || isFieldNode parent
            samePrecedenceSubExpression = case left of
              Binary leftOp _ _ -> shouldFlatten op leftOp
              _ -> False
        if shouldNotIndent || (shouldInlineLogical e && not samePrecedenceSubExpression) || (not (shouldInlineLogical e) && shouldIndentIfInlining)
          then pure (group (cat parts))
          else do
            let firstGroupIndex = case [i | (i, d) <- zip [0 :: Int ..] parts, isGroupDoc d] of
                  i : _ -> i
                  [] -> -1
                headParts = take (if firstGroupIndex == -1 then 1 else firstGroupIndex + 1) parts
                rest = drop (length headParts) parts
            gid <- fresh
            pure (groupWithId gid False (cat (headParts ++ [indent (cat rest)])))
  where
    isGroupDoc = P.isGroup

isCallOrNewNode, isUnaryNode, isIndexNode, isReturnOrThrow, isArrowNode, isConditionalNode, isTemplateNode, isPropNode, isFieldNode :: Node -> Bool
isCallOrNewNode n = case n of NE (Call {}) -> True; NE (New {}) -> True; _ -> False
isUnaryNode n = case n of NE (Unary {}) -> True; _ -> False
isIndexNode n = case n of NE (Index {}) -> True; _ -> False
isReturnOrThrow n = case n of NS (Return _) -> True; NS (Throw _) -> True; _ -> False
isArrowNode n = case n of NE (Arrow {}) -> True; _ -> False
isConditionalNode n = case n of NE (Conditional {}) -> True; _ -> False
isTemplateNode n = case n of NE (Template _) -> True; _ -> False
isPropNode n = case n of NProp _ -> True; _ -> False
isFieldNode n = case n of NMember (Field {}) -> True; _ -> False

-- | printBinaryishExpressions: the operands and operators of a chain of the
-- same precedence, flattened.
binaryishParts :: Path -> Expr -> Bool -> P [Doc]
binaryishParts p e isInsideParenthesis = case e of
  Binary op left right -> do
    let here = NE e
    leftParts <- case left of
      Binary leftOp _ _ | shouldFlatten op leftOp -> binaryishParts ((here, "left") : p) left isInsideParenthesis
      _ -> (: []) . group <$> expr ((here, "left") : p) noArgs left
    rightDoc <- expr ((here, "right") : p) noArgs right
    let inline = shouldInlineLogical e
        rightPart = if inline then cat [text op, text " ", rightDoc] else cat [text op, line, rightDoc]
        parentType = case p of
          (NE parent, _) : _ -> exprType parent
          _ -> ""
        shouldGroup = not (isInsideParenthesis && isLogical e) &&
          parentType /= exprType e && exprType left /= exprType e && exprType right /= exprType e
        right' = if shouldGroup then group rightPart else rightPart
    pure (leftParts ++ [text " ", right'])
  _ -> (: []) . group <$> expr p noArgs e

-- Conditional expressions -----------------------------------------------------

-- | printTernaryOld (Prettier's default ternary formatting).
ternary :: Path -> Expr -> P Doc
ternary p e = case e of
  Conditional test consequent alternate -> do
    let here = NE e
        (parent, key) = case p of
          x : _ -> x
          [] -> (NProgram, "")
        isParentConditional = isConditionalNode parent
        isParentTest = isParentConditional && key == "test"
        forceNoIndent = isParentConditional && not isParentTest
        -- The first ancestor outside a chain of alternates.
        firstNonConditionalParent = go p
          where
            go ((NE c@(Conditional {}), k) : rest) | k /= "test" = go' c rest
            go xs = maybe NProgram fst (headMaybe xs)
            go' _ rest = go rest
        isFirstInChain = case p of
          (NE (Conditional {}), k) : _ -> k == "test"
          _ -> True
    testDoc <- expr ((here, "test") : p) noArgs test
    consequentDoc <- expr ((here, "consequent") : p) noArgs consequent
    alternateDoc <- expr ((here, "alternate") : p) noArgs alternate
    let printedTest = if isParentConditional && key == "alternate" then align 2 testDoc else testDoc
        nestedConsequent = isConditionalE consequent
        part = cat [ line, text "? "
                   , if nestedConsequent then ifBreak mempty (text "(") else mempty
                   , align 2 consequentDoc
                   , if nestedConsequent then ifBreak mempty (text ")") else mempty
                   , line, text ": ", align 2 alternateDoc ]
        parts = if not isParentConditional || key == "alternate" || isParentTest then part else align 0 part
        breakClosingParen = (isMemberNode parent && not (isIndexNode parent)) && key == "object"
        extraIndent = shouldExtraIndent p
        maybeGroup d = if isFirstInChain then group d else d
        result = maybeGroup (cat [printedTest, if forceNoIndent then parts else indent parts
                                 , if breakClosingParen && not extraIndent then softline else mempty])
    let _ = firstNonConditionalParent
    pure (if isParentTest || extraIndent then group (cat [indent (cat [softline, result]), softline]) else result)
  _ -> error "ternary"
  where
    isConditionalE x = case x of Conditional {} -> True; _ -> False

-- | shouldExtraIndentForConditionalExpression.
shouldExtraIndent :: Path -> Bool
shouldExtraIndent p = go p False
  where
    go xs moved = case xs of
      (NE (Call c _ _ _), "callee") : rest | isChild c -> go rest True
      (NE (Member {}), "object") : rest -> go rest True
      (NE (Index {}), "object") : rest -> go rest True
      (NE (New {}), "callee") : (parent, k) : _ -> ancestorHolds parent k
      (NE (As {}), "expression") : (parent, k) : _ -> ancestorHolds parent k
      (parent, k) : _ -> moved && ancestorHolds parent k
      [] -> False
    isChild _ = True
    ancestorHolds parent k = case parent of
      NE (Assign {}) -> k == "right"
      NDeclarator -> k == "init"
      NS (Return _) -> k == "argument"
      NS (Throw _) -> k == "argument"
      NE (Unary {}) -> k == "argument"
      NE (Await _) -> k == "argument"
      _ -> False

-- Parentheses ---------------------------------------------------------------

-- | The parts of needs-parentheses.js that generated code reaches.
needsParens :: Path -> Expr -> Bool
needsParens p e = case p of
  [] -> False
  (parent, key) : _ -> statementStart || arrowBodyObject || byNode parent key
  where
    statementStart = case e of
      Object _ -> startsStatement
      Function {} -> startsStatement
      _ -> False
    startsStatement = case [x | (NS (ExprStmt x), _) <- p] of
      x : _ -> leftmost x == Just e && not (isJust (findExpr p))
      [] -> False
    findExpr _ = Nothing :: Maybe ()
    arrowBodyObject = case e of
      Object _ -> case [b | (NE (Arrow _ _ _ (ExpressionBody b)), "body") <- take 1 (dropWhile (not . isArrowParent) p)] of
        b : _ -> leftmost b == Just e
        [] -> False
      _ -> False
    isArrowParent (n, _) = isArrowNode n
    byNode parent key = case e of
      Unary op _ -> case parent of
        NE (Unary pop _) -> op == pop && op `elem` ["+", "-"]
        NE (Member {}) -> key == "object"
        NE (Index {}) -> key == "object"
        NE (Call {}) -> key == "callee"
        NE (New {}) -> key == "callee"
        NE (Binary pop _ _) -> key == "left" && pop == "**"
        NE (NonNull _) -> True
        _ -> False
      Binary op _ _ -> binaryLike op parent key
      As _ _ -> binaryLike "" parent key
      Conditional {} -> case parent of
        NE (Unary {}) -> True
        NE (Spread _) -> True
        NE (Binary {}) -> True
        NE (Await _) -> True
        NE (As {}) -> True
        NE (NonNull _) -> True
        NE (Call {}) -> key == "callee"
        NE (New {}) -> key == "callee"
        NE (Conditional {}) -> key == "test"
        NE (Member {}) -> key == "object"
        NE (Index {}) -> key == "object"
        _ -> False
      Arrow {} -> case parent of
        NE (Binary {}) -> True
        NE (Call {}) -> key == "callee"
        NE (New {}) -> key == "callee"
        NE (Member {}) -> key == "object"
        NE (Index {}) -> key == "object"
        NE (As {}) -> True
        NE (NonNull _) -> True
        NE (Unary {}) -> True
        NE (Await _) -> True
        NE (Conditional {}) -> key == "test"
        _ -> False
      Function {} -> case parent of
        NE (Call {}) -> key == "callee"
        NE (New {}) -> key == "callee"
        _ -> False
      Await _ -> case parent of
        NE (Unary {}) -> True
        NE (Spread _) -> True
        NE (As {}) -> True
        NE (NonNull _) -> True
        NE (Member {}) -> key == "object"
        NE (Index {}) -> key == "object"
        NE (Call {}) -> key == "callee"
        NE (New {}) -> key == "callee"
        NE (Conditional {}) -> key == "test"
        NE (Binary op _ _) -> op `notElem` ["&&", "||", "??"] || True
        _ -> False
      Num _ -> case parent of
        NE (Member {}) -> key == "object"
        NE (Index {}) -> key == "object"
        _ -> False
      Assign {} -> case parent of
        NS (ExprStmt _) -> False
        NE (Assign {}) -> False
        _ -> True
      Call {} -> case parent of
        NE (New {}) -> key == "callee"
        _ -> False
      Member {} -> case parent of
        NE (New {}) -> key == "callee" && hasCall e
        _ -> False
      _ -> False
    hasCall x = case x of
      Call {} -> True
      Member o _ _ -> hasCall o
      Index o _ _ -> hasCall o
      _ -> False
    binaryLike op parent key = case parent of
      NE (As {}) -> not isCast
      NE (Conditional {}) -> isCast || op == "??"
      NE (Call {}) -> key == "callee"
      NE (New {}) -> key == "callee"
      NE (Spread _) -> True
      NE (Await _) -> True
      NE (NonNull _) -> True
      NE (Unary {}) -> True
      NE (Member {}) -> key == "object"
      NE (Index {}) -> key == "object"
      NE (Binary pop _ _)
        | isLogicalOp pop && isLogicalOp op && not isCast -> pop /= op || precedenceCheck pop
        | otherwise -> precedenceCheck pop
      _ -> False
      where
        isCast = case e of As _ _ -> True; _ -> False
        precedenceCheck pop
          | isCast = True
          | otherwise =
              let po = precedence op
                  pp = precedence pop
              in pp > po || (key == "right" && pp == po) || (pp == po && not (shouldFlatten pop op))
                 || (pp < po && op == "%" && pop `elem` ["+", "-"]) || pop `elem` [">>", ">>>", "<<", "|", "^", "&"]
    isLogicalOp o = o `elem` ["&&", "||", "??"]

-- | The leftmost subexpression, where a statement's first token comes from.
leftmost :: Expr -> Maybe Expr
leftmost x = Just (go x)
  where
    go y = case y of
      Binary _ l _ -> go l
      Assign _ l _ -> go l
      Conditional t _ _ -> go t
      Call c _ _ _ -> go c
      Member o _ _ -> go o
      Index o _ _ -> go o
      As a _ -> go a
      NonNull a -> go a
      _ -> y

-- Classes and interfaces ----------------------------------------------------

classDoc :: Path -> String -> [String] -> Maybe Expr -> [Type] -> [Member] -> Bool -> P Doc
classDoc p name tps super implements members isInterface' = do
  superDoc <- maybe (pure Nothing) (fmap Just . expr ((NS (Block []), "superClass") : p) noArgs) super
  implementsDocs <- mapM (typeDoc p) implements
  body <- classBody p members isInterface'
  let groupMode = case super of
        Just s -> isMemberish s
        Nothing -> case implements of
          [TRef n []] -> '.' `elem` n && length implements == 1
          _ -> False
      multiple = length (maybe [] (const [()]) super) + length implements > 1
      extendsParts = cat
        [ case superDoc of
            Just d -> if groupMode then cat [line, group (cat [text "extends ", d])] else cat [text " extends ", d]
            Nothing -> mempty
        , if null implementsDocs then mempty
          else if multiple then cat [line, text "implements", group (indent (cat [line, join (cat [text ",", line]) implementsDocs]))]
          else if groupMode then cat [line, group (cat [text "implements ", join (cat [text ",", line]) implementsDocs])]
          else cat [text " implements ", join (cat [text ",", line]) implementsDocs] ]
      header = cat [text " ", text name, typeParameterList tps]
      keyword = if isInterface' then "interface" else "class"
  if groupMode || multiple
    then do
      gid <- fresh
      let nonEmpty = not (null [m | m <- members, not (isLayoutMember m)])
      pure (cat [text keyword, groupWithId gid False (cat [header, indent extendsParts])
                , if not isInterface' && nonEmpty then ifBreakFor gid hardline (text " ") else text " ", body])
    else pure (cat [text keyword, header, extendsParts, text " ", body])
  where
    isLayoutMember m = case m of
      MemberComment _ -> False
      MemberBlank -> True
      _ -> False

classBody :: Path -> [Member] -> Bool -> P Doc
classBody p members isInterface' = do
  let items = normaliseMembers members
  docs <- forM items $ \(m, blankAfter) -> do
    d <- memberDoc p m isInterface'
    pure (d, blankAfter)
  if null docs then pure (text "{}") else
    pure (cat [text "{", indent (cat [hardline, cat (concat [ [d] ++ (if i == length docs - 1 then [] else hardline : [hardline | b])
                                                         | (i, (d, b)) <- zip [0 :: Int ..] docs ])]), hardline, text "}"])
  where
    normaliseMembers ms = go (dropWhile (== MemberBlank) ms)
      where
        go [] = []
        go (MemberBlank : rest) = go rest
        go (m : rest) = (m, case rest of
          (MemberBlank : more) -> any (/= MemberBlank) more
          _ -> False) : go rest

memberDoc :: Path -> Member -> Bool -> P Doc
memberDoc p m isInterface' = let here = NMember m in case m of
  MemberComment ls -> pure (join hardline (map (text . dropWhileEnd (== ' ')) ls))
  MemberBlank -> pure mempty
  Field modifiers name ty value -> do
    tyDoc <- maybe (pure mempty) (\t -> (\d -> cat [text ": ", d]) <$> typeDoc ((here, "typeAnnotation") : p) t) ty
    let left = cat [cat [text (m ++ " ") | m <- modifiers], text name, tyDoc]
    d <- case value of
      Nothing -> pure left
      Just v -> assignmentWith ((here, "value") : p) left " =" v
    pure (cat [d, text ";"])
  Method static async kind name ps rt body -> do
    paramsDoc <- functionParameters ((here, "params") : p) ps False False
    rtDoc <- returnTypeDoc ((here, "returnType") : p) rt
    b <- block ((here, "body") : p) body True
    let grouped = if shouldGroupParameters [] ps rt rtDoc then group paramsDoc else paramsDoc
        prefix = cat [if static then text "static " else mempty
                     , if async then text "async " else mempty
                     , if kind `elem` ["get", "set"] then text (kind ++ " ") else mempty]
    pure (cat [prefix, text name, group (cat [grouped, rtDoc]), text " ", b])
  Signature name ps rt -> do
    paramsDoc <- functionParameters ((here, "params") : p) ps False False
    rtDoc <- returnTypeDoc ((here, "returnType") : p) rt
    let grouped = if shouldGroupParameters [] ps rt rtDoc then group paramsDoc else paramsDoc
    pure (cat [group (cat [text name, grouped, if isNothing rt then mempty else group rtDoc]), text (if isInterface' then ";" else ";")])

-- Types -------------------------------------------------------------------

typeArguments :: Path -> [Type] -> P Doc
typeArguments p ts
  | null ts = pure mempty
  | otherwise = do
      docs <- mapM (typeDoc p) ts
      if case ts of [t] -> hugType t; _ -> False
        then pure (cat [text "<", join (text ", ") docs, text ">"])
        else pure (group (cat [text "<", indent (cat [softline, join (cat [text ",", line]) docs]), softline, text ">"]))

hugType :: Type -> Bool
hugType t = simpleType t || isObjectTypeT t

simpleType :: Type -> Bool
simpleType t = case t of
  TKeyword _ -> True
  TRef _ [] -> True
  _ -> False

isUnionType :: Type -> Bool
isUnionType t = case t of TUnion _ -> True; _ -> False

shouldHugUnion :: Type -> Bool
shouldHugUnion t = case t of
  TUnion ts -> case [x | x <- ts, objectLike x] of
    [o] -> all (\x -> x == o || voidType x) ts
    _ -> False
  _ -> False
  where
    objectLike x = case x of
      TObject _ -> True
      TRef _ _ -> True
      _ -> False
    voidType x = x == TKeyword "null" || x == TKeyword "void"

typeDoc :: Path -> Type -> P Doc
typeDoc p = typeAt p Nothing

typeAt :: Path -> Maybe String -> Type -> P Doc
typeAt p layout t = let here = NType t in case t of
  TKeyword k -> pure (text k)
  TRaw r -> pure (text r)
  TLiteral e -> expr ((here, "literal") : p) noArgs e
  TRef n args -> (\a -> cat [text n, a]) <$> typeArguments ((here, "typeArguments") : p) args
  TArray inner -> do
    d <- typeAt ((here, "elementType") : p) Nothing inner
    pure (cat [if needsTypeParens inner then cat [text "(", d, text ")"] else d, text "[]"])
  TReadonly inner -> (\d -> cat [text "readonly ", d]) <$> typeAt ((here, "typeAnnotation") : p) Nothing inner
  TTuple ts -> do
    docs <- mapM (typeAt ((here, "elementTypes") : p) Nothing) ts
    pure (if null docs then text "[]" else group (cat [text "[", indent (cat [softline, join (cat [text ",", line]) (map group docs)]), ifBreak (text ",") mempty, softline, text "]"]))
  TFunction ps r -> do
    paramsDoc <- functionParameters ((here, "params") : p) ps False False
    rd <- typeAt ((here, "returnType") : p) Nothing r
    pure (group (cat [paramsDoc, text " => ", rd]))
  TObject fields -> do
    docs <- forM fields $ \(n, optional, ft) -> do
      d <- typeAt ((here, "members") : p) Nothing ft
      pure (cat [text n, if optional then text "?" else mempty, text ": ", d])
    pure (if null docs then text "{}" else
      group (cat [text "{", indent (cat [line, join (cat [text ";", line]) docs]), ifBreak (text ";") mempty, line, text "}"]))
  TUnion ts
    | shouldHugUnion t -> join (text " | ") <$> mapM (typeAt ((here, "types") : p) Nothing) ts
    | otherwise -> do
        docs <- mapM (typeAt ((here, "types") : p) Nothing) ts
        let printed = group (cat [ if i == 0 then cat [ifBreak (text "| ") mempty, align 2 d] else cat [line, text "| ", align 2 d]
                                 | (i, d) <- zip [0 :: Int ..] docs ])
            shouldIndent = case p of
              (NType (TRef _ _), "typeArguments") : _ -> False
              (NType (TTuple _), _) : _ -> False
              _ -> True
        pure (if layout == Just "break-after-operator" || not shouldIndent then printed else group (indent (cat [softline, printed])))
  where
    needsTypeParens x = case x of
      TUnion _ -> True
      TFunction _ _ -> True
      _ -> False

-- Numbers -----------------------------------------------------------------

-- | Prettier's printNumber: lower case, no needless zeros or points.
printNumber :: String -> String
printNumber raw
  | length raw <= 1 = raw
  | otherwise = dropPoint (trimZeros (map toLower raw))
  where
    trimZeros s = case break (== '.') s of
      (whole, '.' : frac) ->
        let (digits, rest) = span isDigit frac
            kept = case dropWhileEnd (== '0') digits of
              "" -> ""
              d -> d
        in whole ++ (if null kept then "." else "." ++ kept) ++ rest
      _ -> s
    dropPoint s = case break (== '.') s of
      (whole, ".") -> whole
      (whole, '.' : rest@('e' : _)) -> whole ++ rest
      _ -> s

_unused :: ()
_unused = const () (isPrefixOf "" "", isSuffixOf "" "", isAlphaNum 'a', fromMaybe () Nothing, dedent mempty, labelOf mempty, P.isEmpty mempty)
