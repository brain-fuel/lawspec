-- | Natural-indexed families are elaborated before inference. Each family becomes
-- erased data, one checked structural measure per index, and a named refinement
-- relating the measure to the index. Core and the eight emitters never see an
-- index: every index claim is evidence discharged by the refinement machinery.
module LawSpec.Indexed
  ( IndexedFamily(..), IndexedConstructor(..)
  , indexedRefinementName, naturalRefinementName, measureName
  , elaborateFamilies, elaborateFamiliesWith
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.List (elemIndex, intercalate, nub, (\\))
import qualified Data.Map.Strict as M
import LawSpec.IndexTerm
import LawSpec.Model

-- | A constructor of an indexed family with the equations its index satisfies.
-- ref:DEC-indexed-families-as-evidence
data IndexedConstructor = IndexedConstructor
  { indexedDeclaration :: ConstructorDeclaration
  , indexedEquations :: [(String, Expr)]
  } deriving (Eq, Show)

-- | Parameters keep declaration order; True marks a type parameter and False a
-- Natural index.
data IndexedFamily = IndexedFamily
  { familyName :: String
  , familyParameters :: [(String, Bool)]
  , familyConstructors :: [IndexedConstructor]
  , familySpan :: Span
  } deriving (Eq, Show)

-- | '@' cannot occur in a source identifier, so generated refinements never
-- collide with user declarations, including the erased data type itself.
indexedRefinementName :: String -> String
indexedRefinementName family = family ++ "@index"

-- | Indices are natural numbers, stated as a refinement every target checks.
naturalRefinementName :: String
naturalRefinementName = "Natural"

-- | An imported family keeps its alias: v.Vec's measure is v.nOfVec.
measureName :: String -> String -> String
measureName family index = case break (== '.') (reverse family) of
  (base, '.' : alias) -> reverse alias ++ "." ++ index ++ "Of" ++ reverse base
  _ -> index ++ "Of" ++ family

-- | Indexed families are elaborated into erased data, measures and refinements,
-- so Core needs no dependent types. ref:DEC-elaborate-before-core
elaborateFamilies :: [IndexedFamily] -> Unit -> Either String Unit
elaborateFamilies = elaborateFamiliesWith []

-- | Imported families, under the names this unit uses for them, take part in
-- erasure and implicit index binding; their declarations stay with their unit.
elaborateFamiliesWith :: [IndexedFamily] -> [IndexedFamily] -> Unit -> Either String Unit
elaborateFamiliesWith imported families u = do
  let names = map familyName families
      table = M.union (M.fromList [(familyName f, f) | f <- families])
        (M.fromList [(familyName f, f) | f <- imported])
  forM_ families (validateFamily table)
  declarations <- mapM (erasedDeclaration table) families
  measures <- concat <$> mapM (familyMeasures table) families
  let refinementsFor = map familyRefinement families
      natural = [naturalRefinement | usesNatural u || not (null families)]
      clashes = [n | n <- names, n `elem` map dataTypeName (dataTypes u)]
  unless (null clashes) (Left ("duplicate data type: " ++ intercalate ", " clashes))
  let definitionSignatures =
        [ (functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d)))
        | d <- measures ]
      known = map fst (functions u) ++ map functionName (functionDefinitions u) ++
        map functionName measures
      bind = bindImplicitIndices table known
  userDefinitions <- forM (map (completeMatches table) (functionDefinitions u)) $ \d -> do
    (arguments, substitution) <- bindBinders table known (functionArguments d)
    pure d { functionArguments = arguments
           , functionResult = substituteIndices substitution (functionResult d)
           , functionBody = replaceExprVars substitution (functionBody d) }
  let definitionNames = map functionName (functionDefinitions u)
  userFunctions <- forM (functions u) $ \(n, t) -> case lookup n
      [(functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))) | d <- userDefinitions] of
    Just t' | n `elem` definitionNames -> pure (n, t')
    _ -> (,) n <$> bind t
  userLaws <- mapM (bindLaw table known) (laws u)
  pure u
    { functions = definitionSignatures ++ userFunctions
    , laws = userLaws
    , refinements = natural ++ refinementsFor ++ refinements u
    , declarationSpans = [(functionName d, functionSpan d) | d <- measures] ++ declarationSpans u
    , dataTypes = declarations ++ dataTypes u
    , functionDefinitions = measures ++ userDefinitions
    }

-- | Source uses of Natural parse as a refinement application. Only units that
-- mention it receive the declaration, keeping existing outputs unchanged.
usesNatural :: Unit -> Bool
usesNatural u = ("RefinementApp \"" ++ naturalRefinementName ++ "\"") `isInfix` show u
  where isInfix needle haystack = any (startsWith needle) (suffixes haystack)
        startsWith p s = take (length p) s == p
        suffixes s = s : case s of [] -> []; _:rest -> suffixes rest

naturalRefinement :: Refinement
naturalRefinement = Refinement naturalRefinementName [] []
  (Refined "value" (Named "BigInt") (Just (Binary ">=" (Var "value") (Number 0))))

typeParameters, indexParameters :: IndexedFamily -> [String]
typeParameters f = [p | (p, True) <- familyParameters f]
indexParameters f = [p | (p, False) <- familyParameters f]

erasedType :: IndexedFamily -> Type
erasedType f = applied (familyName f) (map Variable (typeParameters f))

applied :: String -> [Type] -> Type
applied n [] = Named n
applied n [a] = Applied n a
applied n args = Application n args

-- | A field of indexed type binds each variable index argument to that field.
data Binding = Binding { boundField :: String, boundFamily :: String, boundIndex :: String }

familyReference :: M.Map String IndexedFamily -> Type -> Maybe (IndexedFamily, [RefinementArgument])
familyReference table (RefinementApp n args) =
  case [f | f <- M.elems table, indexedRefinementName (familyName f) == n] of
    f:_ -> Just (f, args)
    [] -> Nothing
familyReference _ _ = Nothing

validateFamily :: M.Map String IndexedFamily -> IndexedFamily -> Either String ()
validateFamily table f = do
  let name = familyName f
      indices = indexParameters f
  when (null indices) (Left (name ++ ": an indexed family requires a Natural index"))
  unless (length (nub (map fst (familyParameters f))) == length (familyParameters f))
    (Left (name ++ ": duplicate type parameter"))
  when (null (familyConstructors f)) (Left (name ++ ": an indexed family requires constructors"))
  forM_ (familyConstructors f) $ \c -> do
    let tag = dataConstructorName (indexedDeclaration c)
        equations = indexedEquations c
        stated = map fst equations
        context = name ++ "." ++ tag
    unless (length (nub stated) == length stated)
      (Left (context ++ ": duplicate index equation"))
    forM_ (stated \\ indices) $ \extra ->
      Left (context ++ ": " ++ extra ++ " is not an index of " ++ name)
    forM_ (indices \\ stated) $ \missing ->
      Left (context ++ ": missing index equation for " ++ missing)
    bindings <- constructorBindings table f c
    let bound = map fst bindings
    forM_ equations $ \(index, e) -> do
      checkIndexExpr context index e
      forM_ (indexVariables e) $ \v -> unless (v `elem` bound)
        (Left (context ++ ": index variable " ++ v ++ " is not bound by a field of indexed type"))

constructorBindings :: M.Map String IndexedFamily -> IndexedFamily -> IndexedConstructor -> Either String [(String, Binding)]
constructorBindings table f c = do
  let context = familyName f ++ "." ++ dataConstructorName (indexedDeclaration c)
  pairs <- fmap concat $ forM (dataConstructorFields (indexedDeclaration c)) $ \(field, ty) ->
    case familyReference table ty of
      Nothing -> do
        when (mentionsFamily table ty)
          (Left (context ++ ": field " ++ field ++ " nests an indexed family; bind indices through a direct field"))
        pure []
      Just (g, args) -> fmap concat $ forM (zip (familyParameters g) args) $ \((parameter, isType), argument) ->
        case (isType, argument) of
          (False, ValueArgument e) -> case unlocated e of
            Var v -> pure [(v, Binding field (familyName g) parameter)]
            _ -> Left (context ++ ": field " ++ field ++ " must use an index variable, not an expression")
          _ -> pure []
  -- A variable bound by several fields is a sibling equality: the measure
  -- reads the first binder, and the others are guarded equal to it.
  let variables = nub (map fst pairs)
  forM_ variables $ \v -> when (v `elem` map fst (familyParameters f))
    (Left (context ++ ": index variable " ++ v ++ " shadows a family parameter"))
  pure pairs

mentionsFamily :: M.Map String IndexedFamily -> Type -> Bool
mentionsFamily table ty = case ty of
  RefinementApp _ args -> maybe False (const True) (familyReference table ty)
    || or [mentionsFamily table t | TypeArgument t <- args]
  Applied _ a -> mentionsFamily table a
  Application _ args -> any (mentionsFamily table) args
  Arrow a b -> mentionsFamily table a || mentionsFamily table b
  Refined _ a _ -> mentionsFamily table a
  Qualified _ a -> mentionsFamily table a
  CheckedType _ a -> mentionsFamily table a
  _ -> False

-- | Index expressions are natural arithmetic over literals and index
-- variables. div, mod and ^ arrive as the prelude's quot, rem and pow.
data IndexShape = IndexLiteral Integer | IndexVariable String | IndexBinary IndexOperation Expr Expr | IndexOther

indexShape :: Expr -> IndexShape
indexShape e = case unlocated e of
  Number n -> IndexLiteral n
  Var v -> IndexVariable v
  Binary "+" a b -> IndexBinary IndexAdd a b
  Binary "-" a b -> IndexBinary IndexSubtract a b
  Binary "*" a b -> IndexBinary IndexMultiply a b
  Apply f b | Apply g a <- unlocated f, Var n <- unlocated g, Just op <- lookup n helpers -> IndexBinary op a b
  _ -> IndexOther
  where helpers = [("prelude.quot", IndexQuotient), ("prelude.rem", IndexRemainder), ("prelude.pow", IndexPower)]

checkIndexExpr :: String -> String -> Expr -> Either String ()
checkIndexExpr context index e = case indexShape e of
  IndexLiteral n | n >= 0 -> pure ()
                 | otherwise -> Left (context ++ ": index " ++ index ++ " must be a natural number")
  IndexVariable _ -> pure ()
  IndexBinary IndexPower a b | not (literal a || literal b) ->
    Left (context ++ ": index " ++ index ++ " may raise only a literal base or to a literal exponent")
  IndexBinary _ a b -> checkIndexExpr context index a >> checkIndexExpr context index b
  IndexOther -> Left (context ++ ": index " ++ index ++
    " must be natural arithmetic (+, -, *, div, mod, ^) over literals and index variables")
  where literal x = case indexShape x of IndexLiteral _ -> True; _ -> False

indexVariables :: Expr -> [String]
indexVariables e = case indexShape e of
  IndexVariable v -> [v]
  IndexBinary _ a b -> indexVariables a ++ indexVariables b
  _ -> []

-- | The family's index table: each constructor's index terms over the indices
-- of its fields, with guards for subtraction and shared (sibling) indices.
familyIndex :: M.Map String IndexedFamily -> IndexedFamily -> Either String FamilyIndex
familyIndex table f = do
  constructors <- forM (familyConstructors f) $ \c -> do
    bindings <- constructorBindings table f c
    let d = indexedDeclaration c
        fields = map fst (dataConstructorFields d)
        reference b = do
          position <- elemIndex (boundField b) fields
          family <- M.lookup (boundFamily b) table
          index <- elemIndex (boundIndex b) (indexParameters family)
          pure (IndexField position index)
        term e = case indexShape e of
          IndexLiteral n -> Right (IndexConstant n)
          IndexVariable v -> maybe (Left ("unbound index variable " ++ v)) Right (lookup v bindings >>= reference)
          IndexBinary op a b -> IndexApply op <$> term a <*> term b
          IndexOther -> Left "invalid index expression"
    terms <- forM (indexParameters f) $ \index -> term (maybe (Number 0) id (lookup index (indexedEquations c)))
    siblings <- fmap concat $ forM (nub (map fst bindings)) $ \v ->
      case [b | (v', b) <- bindings, v' == v] of
        first : rest -> do
          references <- maybe (Left ("unresolved index field for " ++ v)) Right (mapM reference (first : rest))
          case references of
            r : rs -> pure [IndexGuard IndexEqual r other | other <- rs]
            [] -> pure []
        [] -> pure []
    pure (dataConstructorName d, ConstructorIndex terms (siblings ++ concatMap subtractionGuards terms))
  pure (FamilyIndex (indexParameters f) constructors)

eraseType :: M.Map String IndexedFamily -> Type -> Type
eraseType table ty = case familyReference table ty of
  Just (g, args) -> applied (familyName g)
    [eraseType table t | ((_, True), TypeArgument t) <- zip (familyParameters g) args]
  Nothing -> case ty of
    Applied n a -> Applied n (eraseType table a)
    Application n args -> Application n (map (eraseType table) args)
    Arrow a b -> Arrow (eraseType table a) (eraseType table b)
    Refined n a p -> Refined n (eraseType table a) p
    Qualified cs a -> Qualified cs (eraseType table a)
    CheckedType ps a -> CheckedType ps (eraseType table a)
    RefinementApp n args -> RefinementApp n
      [(case a of TypeArgument t -> TypeArgument (eraseType table t); _ -> a) | a <- args]
    _ -> ty

erasedDeclaration :: M.Map String IndexedFamily -> IndexedFamily -> Either String DataTypeDeclaration
erasedDeclaration table f = do
  index <- familyIndex table f
  pure $ DataTypeDeclaration (familyName f) (typeParameters f)
    [ d { dataConstructorFields = [(field, eraseType table ty) | (field, ty) <- dataConstructorFields d] }
    | c <- familyConstructors f, let d = indexedDeclaration c ]
    (familySpan f) (Just index)

-- | The measure recomputes an index from the constructor equations, replacing
-- each index variable with the measure of the field that binds it.
familyMeasures :: M.Map String IndexedFamily -> IndexedFamily -> Either String [FunctionDefinition]
familyMeasures table f = forM (indexParameters f) $ \index -> do
  branches <- forM (familyConstructors f) $ \c -> do
    bindings <- constructorBindings table f c
    let d = indexedDeclaration c
        fields = map fst (dataConstructorFields d)
        equation = maybe (Number 0) id (lookup index (indexedEquations c))
        measured v = case lookup v bindings of
          Just b -> Apply (Var (measureName (boundFamily b) (boundIndex b))) (Var (boundField b))
          Nothing -> Var v
    pure (MatchBranch (dataConstructorName d) fields (replaceIndex measured equation))
  let allFields = concatMap (map fst . dataConstructorFields . indexedDeclaration) (familyConstructors f)
      subject = head [candidate | n <- [0 :: Int ..], let candidate = "indexed" ++ replicate n '_',
                                  candidate `notElem` allFields]
  pure (FunctionDefinition (measureName (familyName f) index)
    [(subject, erasedType f)] (Named "BigInt") []
    (MatchExpr (Var subject) branches) (familySpan f))

replaceIndex :: (String -> Expr) -> Expr -> Expr
replaceIndex measured e = case unlocated e of
  Var v -> measured v
  Binary op a b -> Binary op (replaceIndex measured a) (replaceIndex measured b)
  Apply a b -> Apply (replaceIndex measured a) (replaceIndex measured b)
  other -> other

familyRefinement :: IndexedFamily -> Refinement
familyRefinement f =
  let indices = indexParameters f
      binder = head [candidate | n <- [0 :: Int ..], let candidate = "value" ++ replicate n '_',
                                 candidate `notElem` map fst (familyParameters f)]
      claims = [Binary "==" (Apply (Var (measureName (familyName f) i)) (Var binder)) (Var i) | i <- indices]
      parameterType (p, True) = (p, Named "Type")
      parameterType (p, False) = (p, RefinementApp naturalRefinementName [])
  in Refinement (indexedRefinementName (familyName f)) (map parameterType (familyParameters f)) []
       (Refined binder (erasedType f) (Just (foldr1 (Binary "&&") claims)))

-- | An index variable that is not otherwise in scope is implicit: the first
-- binder whose family type mentions it as a bare index determines it. The
-- binder is erased and later occurrences read that binder's measure.
bindImplicitIndices :: M.Map String IndexedFamily -> [String] -> Type -> Either String Type
bindImplicitIndices table known ty = do
  let (arguments, result) = arrows ty
      named = [(nameOf i t, t) | (i, t) <- zip [0 :: Int ..] arguments]
  (bound, substitution) <- bindBinders table known named
  let rebuilt = [ case original of
                    Refined {} -> t'
                    _ | t' /= original -> Refined n t' Nothing
                      | otherwise -> original
                | ((n, t'), original) <- zip bound arguments ]
      finalResult = substituteIndices substitution result
  checkClosed table (known ++ map fst bound) finalResult
  pure (foldr Arrow finalResult rebuilt)
  where
    arrows (Arrow a b) = let (as, r) = arrows b in (a : as, r)
    arrows t = ([], t)
    -- Unnamed arguments that introduce an implicit index receive a binder.
    nameOf _ (Refined n _ _) = n
    nameOf i _ = "indexed" ++ show i

bindLaw :: M.Map String IndexedFamily -> [String] -> Law -> Either String Law
bindLaw table known l = do
  (parameters', outer) <- bindBinders table known (parameters l)
  definition' <- walk (known ++ map fst parameters') outer (definition l)
  pure l { parameters = parameters', definition = definition' }
  where
    walk scope substitution d = case d of
      Forall binders body -> do
        (binders', inner) <- bindBinders table scope
          [(n, substituteIndices substitution t) | (n, t) <- binders]
        Forall binders' <$> walk (scope ++ map fst binders') (substitution ++ inner) body
      Equal a b -> pure (Equal (replaceExprVars substitution a) (replaceExprVars substitution b))
      Holds e -> pure (Holds (replaceExprVars substitution e))
      Implies e rest -> Implies (replaceExprVars substitution e) <$> walk scope substitution rest
      And a b -> And <$> walk scope substitution a <*> walk scope substitution b
      Invoke n es -> pure (Invoke n (map (replaceExprVars substitution) es))

bindBinders :: M.Map String IndexedFamily -> [String] -> [(String, Type)]
            -> Either String ([(String, Type)], [(String, Expr)])
bindBinders table known = go known []
  where
    go _ substitution [] = pure ([], substitution)
    go scope substitution ((n, t) : rest) = do
      let t' = substituteIndices substitution t
      (erased, fresh) <- implicitAt table scope n t'
      (rest', substitution') <- go (scope ++ [n]) (substitution ++ fresh) rest
      pure ((n, erased) : rest', substitution')

-- | Only the outermost family application of a binder may introduce implicit
-- indices, and then every index argument must be a fresh variable.
implicitAt :: M.Map String IndexedFamily -> [String] -> String -> Type
           -> Either String (Type, [(String, Expr)])
implicitAt table scope binder ty = case ty of
  Refined n inner p -> do
    (inner', fresh) <- implicitAt table scope binder inner
    pure (Refined n inner' p, fresh)
  _ -> case familyReference table ty of
    Nothing -> pure (ty, [])
    Just (f, args) -> do
      let indices = [(p, e) | ((p, False), ValueArgument e) <- zip (familyParameters f) args]
          fresh v = v `notElem` scope
          measure p = Apply (Var (measureName (familyName f) p)) (Var binder)
          literal x = case indexShape x of IndexLiteral k -> Just k; _ -> Nothing
          -- v, v + k and k * v determine v from the binder's measure; the
          -- binder's domain then requires the measure to fit the pattern.
          invert p e = case indexShape e of
            IndexVariable v | fresh v -> Just (v, measure p, [])
            IndexBinary IndexAdd a b
              | Just (v, k) <- variablePlus a b -> Just (v, Binary "-" (measure p) (Number k),
                  [Binary ">=" (measure p) (Number k)])
            IndexBinary IndexMultiply a b
              | Just (v, k) <- variableTimes a b, k > 0 -> Just (v, helper "quot" (measure p) (Number k),
                  [Binary "==" (helper "rem" (measure p) (Number k)) (Number 0)])
            _ -> Nothing
          variablePlus a b = case (indexShape a, indexShape b) of
            (IndexVariable v, IndexLiteral k) | fresh v -> Just (v, k)
            (IndexLiteral k, IndexVariable v) | fresh v -> Just (v, k)
            _ -> Nothing
          variableTimes a b = variablePlus a b >>= \_ -> case (literal a, literal b, indexShape a, indexShape b) of
            (_, Just k, IndexVariable v, _) -> Just (v, k)
            (Just k, _, _, IndexVariable v) -> Just (v, k)
            _ -> Nothing
          helper n x y = Apply (Apply (Var ("prelude." ++ n)) x) y
          inverted = [(p, invert p e) | (p, e) <- indices]
          introduces = [r | (_, Just r) <- inverted]
          implicitMentions = [v | (_, e) <- indices, invert "" e == Nothing,
                              v <- indexVariables e, v `notElem` scope]
      unless (null implicitMentions) (Left ("index variable " ++ head implicitMentions ++
        " must first appear as v, v + k or k * v in an index of an earlier binder"))
      if null introduces then pure (ty, [])
      else if length introduces /= length indices
        then Left ("binder " ++ binder ++ " mixes implicit and explicit indices of " ++ familyName f)
        else do
          let conditions = concat [c | (_, _, c) <- introduces]
              erased = eraseType table ty
          pure (if null conditions then erased else Refined binder erased (Just (foldr1 (Binary "&&") conditions)),
            [(v, e) | (v, e, _) <- introduces])

checkClosed :: M.Map String IndexedFamily -> [String] -> Type -> Either String ()
checkClosed table scope ty = case familyReference table (stripRefined ty) of
  Just (_, args) -> forM_ [v | ValueArgument e <- args, v <- indexVariables e, v `notElem` scope] $ \v ->
    Left ("index variable " ++ v ++ " in a result must be bound by an argument")
  Nothing -> pure ()
  where stripRefined (Refined _ t _) = stripRefined t
        stripRefined t = t

substituteIndices :: [(String, Expr)] -> Type -> Type
substituteIndices [] ty = ty
substituteIndices substitution ty = case ty of
  RefinementApp n args -> RefinementApp n
    [(case a of ValueArgument e -> ValueArgument (replaceExprVars substitution e)
                TypeArgument t -> TypeArgument (substituteIndices substitution t)) | a <- args]
  Refined n t p -> Refined n (substituteIndices substitution t)
    (replaceExprVars (filter ((/= n) . fst) substitution) <$> p)
  Applied n a -> Applied n (substituteIndices substitution a)
  Application n args -> Application n (map (substituteIndices substitution) args)
  Arrow a b -> Arrow (substituteIndices substitution a) (substituteIndices substitution b)
  Qualified cs a -> Qualified cs (substituteIndices substitution a)
  CheckedType ps a -> CheckedType (map (replaceExprVars substitution) ps) (substituteIndices substitution a)
  _ -> ty

-- | A match on a parameter of an indexed family may leave out constructors its
-- index rules out: popping a Stack (n + 1) needs no branch for the empty
-- stack. Each one left out gets a branch that is unreachable, and the
-- totality audit must prove it is never reached (or names the constructor).
completeMatches :: M.Map String IndexedFamily -> FunctionDefinition -> FunctionDefinition
completeMatches table d = d { functionBody = go (functionBody d) }
  where
    families = [(name, f) | (name, ty) <- functionArguments d, Just f <- [familyOf ty]]
    familyOf ty = case ty of
      Applied n _ -> M.lookup n table
      Application n _ -> M.lookup n table
      Named n -> M.lookup n table
      -- A family applied to index terms is its index refinement, F@index.
      RefinementApp n _ -> M.lookup (takeWhile (/= '@') n) table
      Refined _ inner _ -> familyOf inner
      _ -> Nothing
    scrutinee e = case e of
      Located _ inner -> scrutinee inner
      Var v -> lookup v families
      _ -> Nothing
    go e = case e of
      Located range inner -> Located range (go inner)
      MatchExpr value branches ->
        let branches' = [MatchBranch tag names (go body) | MatchBranch tag names body <- branches]
        in case scrutinee value of
          Just f ->
            let tags = [tag | MatchBranch tag _ _ <- branches]
                missing = [c | c <- map indexedDeclaration (familyConstructors f), dataConstructorName c `notElem` tags]
                absent c = MatchBranch (dataConstructorName c)
                  ["absent" ++ show i | (i, _) <- zip [0 :: Int ..] (dataConstructorFields c)]
                  (Apply (Var "prelude.unreachable") (StringLit (dataConstructorName c)))
            in MatchExpr (go value) (branches' ++ map absent missing)
          Nothing -> MatchExpr (go value) branches'
      Apply f x -> Apply (go f) (go x)
      Binary op a b -> Binary op (go a) (go b)
      Unary op a -> Unary op (go a)
      ConstructLit n fields -> ConstructLit n (map go fields)
      ListLit xs -> ListLit (map go xs)
      Annotate inner t -> Annotate (go inner) t
      other -> other
