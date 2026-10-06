-- | The concrete syntax of LawSpec, keywords first with symbols as aliases, so a
-- specification reads as prose to someone who is not a mathematician.
-- ref:DEC-readable-notation
module LawSpec.Parser (parseSource, parseSources, parseSourcesWith, sourceUnit) where

import LawSpec.Core.Policy (StagePolicy(..), Retry(..), Strategy(..), Jitter(..), Limit(..), Breaker(..), Bulkhead(..), Hedge(..), emptyPolicy)
import LawSpec.Resilience (resilienceName)
import LawSpec.Collections (collectionsUnit, collectionsAlias)
import LawSpec.Time (timeUnit, timeAlias, durationSuffixes, durationFactor, durationLimit, usesTime, timeTypes)
import LawSpec.Flow (desugarFlows, flowTypeName)
import LawSpec.Model
import LawSpec.Indexed
import LawSpec.Railway (railwayUnit)
import LawSpec.DomainModel
import LawSpec.StatefulModel (ModelDeclaration(..), ModelCommand(..), elaborateModels, checkSupervisors)
import LawSpec.Scenario (Protocol(..), Scenario(..), Statement(..), Step(..), Argument(..), checkScenarios, toProgram)
import LawSpec.Core.Program (Program(..))
import LawSpec.Core.Machine (Machine(..), Supervisor(..), SupervisionStrategy(..), Lifetime(..), Consistency(..))
import Data.Functor (($>))
import LawSpec.Scalar
import Control.Monad.Combinators.Expr
import Control.Monad (void, unless, when, forM_)
import Control.Monad.Reader (Reader, asks, runReader)
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as Lazy
import Data.Char (isLower, isUpper, isControl, toUpper)
import Data.List (uncons, intercalate)
import Data.Void (Void)
import Text.Megaparsec hiding (SourcePos, parse)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

data Header = RefinementHeader [Bool] | DataHeader [Bool] | AliasHeader
type P = ParsecT Void String (Reader (M.Map String Header))
spaceP :: P ()
spaceP = L.space space1 (L.skipLineComment "--") empty
lexeme :: P a -> P a
lexeme = L.lexeme spaceP
symbol :: String -> P String
symbol = L.symbol spaceP
keyword :: String -> P ()
keyword s = lexeme (try (string s *> notFollowedBy (alphaNumChar <|> char '_')))
ident :: P String
ident = lexeme $ try $ do
  x <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
  if x `elem` ["unit","law","requires","is","end","definition","description","rationale","example","expect","implies","and","true","false","references","are","Eq","where","refinement","type","match","with"] then fail "reserved identifier" else pure x
-- | A name, or alias.name for a name exported by an imported unit. The alias and
-- the dot are adjacent; write f . g with spaces to compose a function named
-- like an alias.
qualifiedName :: P String
qualifiedName = try (do
    alias <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
    known <- asks (M.member ("alias:" ++ alias))
    unless known (fail "not an import alias")
    void (char '.')
    n <- ident
    pure (alias ++ "." ++ n))
  <|> ident
-- | The declared name without its import alias.
baseName :: String -> String
baseName = reverse . takeWhile (/= '.') . reverse
-- | Constructors start with an uppercase letter; prelude.Int32 is a conversion.
startsUpper :: String -> Bool
startsUpper name = take 8 name /= "prelude." && maybe False (isUpper . fst) (uncons (baseName name))
lawReference :: P String
lawReference = try (do
    alias <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
    known <- asks (M.member ("alias:" ++ alias))
    unless known (fail "not an import alias")
    void (char '.')
    n <- quoted
    pure (alias ++ ".`" ++ n ++ "`"))
  <|> quoted
quoted :: P String
quoted = lexeme (char '`' *> some (satisfy (\c -> c /= '`' && not (isControl c))) <* char '`')
str :: P String
str = lexeme (char '"' *> manyTill L.charLiteral (char '"'))
parens :: P a -> P a
parens = between (symbol "(") (symbol ")")
typeP :: P Type
typeP = do
  a <- typeAtom
  -- A / A' is a flow parameter: the call takes the state at A to A'.
  a' <- option a (do void (symbol "/"); b <- typeAtom; pure (Application flowTypeName [a, b]))
  option a' (Arrow a' <$> (symbol "->" *> typeP))
typeAtom :: P Type
typeAtom = try (parens $ do
    n <- ident; void (symbol "::"); t <- typeP
    p <- optional (keyword "where" *> expr)
    pure (Refined n t p))
  <|> parens typeP
  -- _ leaves a type for the compiler to fill: a workflow's Either _ T asks
  -- for a generated error type.
  <|> (Variable "_" <$ try (lexeme (char '_' <* notFollowedBy (alphaNumChar <|> char '_'))))
  <|> do
    n <- qualifiedName
    headers <- asks (M.lookup n)
    case headers of
      Just (RefinementHeader kinds) -> RefinementApp n <$> mapM argument kinds
      Just (DataHeader kinds)
        | and kinds -> application n <$> mapM (const typeAtom) kinds
        | otherwise -> RefinementApp (indexedRefinementName n) <$> mapM indexArgument kinds
      Nothing | n == naturalRefinementName -> pure (RefinementApp n [])
              | n `elem` ["Nullable","Optional","List","Maybe"] -> Applied n <$> typeAtom
              | n == "Either" -> Application n <$> sequence [typeAtom, typeAtom]
              | '.' `elem` n -> pure (Named n)
              | otherwise -> pure (if maybe False (isLower . fst) (uncons n) then Variable n else Named n)
  where indexArgument True = TypeArgument <$> typeAtom
        indexArgument False = ValueArgument <$> (parens indexExpr <|> try numeric <|> (Var <$> ident))
        argument True = TypeArgument <$> typeAtom
        argument False = ValueArgument <$> (parens expr <|> try numeric <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Var <$> ident))
        application n [] = Named n
        application n [a] = Applied n a
        application n args = Application n args
param :: P (String,Type)
param = parens $ do
  n <- ident; void (symbol "::"); t <- typeP
  p <- optional (keyword "where" *> expr)
  pure (n,maybe t (\e -> Refined n t (Just e)) p)
constraintsP :: P [Constraint]
constraintsP = option [] (keyword "requires" *> some (do
  n <- choice [name <$ keyword name | name <- ["Eq","Integer","Ordered","Bounded","Keyed"]]
  Capability n <$> typeP))
refinementP :: P Refinement
refinementP = do
  keyword "refinement"; n <- ident; ps <- many param; cs <- constraintsP
  t <- keyword "is" *> typeP <* keyword "end"
  pure (Refinement n ps cs t)
dataTypeP :: P DataTypeDeclaration
dataTypeP = either erased id <$> declarationP
  where erased f = DataTypeDeclaration (familyName f) (map fst (familyParameters f))
          (map indexedDeclaration (familyConstructors f)) (familySpan f) Nothing

-- | wrapper Name (a :: Type)* is <type> [where <predicate over value>] end
wrapperP :: P Wrapper
wrapperP = do
  ((name, parameters, base, predicate), range) <- withSpan $ do
    keyword "wrapper"
    name <- ident
    unless (maybe False (isUpper . fst) (uncons name)) (fail "wrapper names must start with an uppercase letter")
    parameters <- many $ parens $ do
      parameter <- ident
      unless (maybe False (isLower . fst) (uncons parameter)) (fail "type parameters must start with a lowercase letter")
      void (symbol "::")
      keyword "Type"
      pure parameter
    keyword "is"
    base <- typeP
    predicate <- optional (keyword "where" *> expr)
    keyword "end"
    pure (name, parameters, base, predicate)
  pure (Wrapper name parameters base predicate range)

-- | workflow name :: Input -> Result is stage+ end. A stage is a step, written
-- `name :: Type` (an adapter it declares) or `then name` / `>>= name` (an
-- existing function); `map f` / `<$> f`; `mapError f` / `<!> f`;
-- `orElse f` / `recover f` / `<|> f`; `fallback f` / `?? f`; `tap f`; or
-- `ensure p else f`.
workflowP :: P Workflow
workflowP = do
  ((name, ty, stages), range) <- withSpan $ do
    keyword "workflow"
    name <- ident
    void (symbol "::")
    ty <- typeP
    keyword "is"
    stages <- some (do stage <- stageP; policies <- many policyP; pure (stage, policies))
    keyword "end"
    pure (name, ty, stages)
  pure (Workflow name ty (map fst stages) range
    [(index, foldl (flip ($)) (emptyPolicy "") (map fst policies)) | (index, (_, policies)) <- zip [0 ..] stages, not (null policies)]
    [(index, concatMap snd policies) | (index, (_, policies)) <- zip [0 ..] stages, any (not . null . snd) policies])
  where
    -- A stage's policies follow it, each beginning with its keyword. A
    -- policy that can fail may name, after else, the value of a declared
    -- error type its failure becomes.
    policyP = choice [try retryP <|> try timeoutP, try rateLimitP, try breakerP, try bulkheadP, try cacheP, try compensateP, try hedgeP]
    hedgeP = plain $ do
      keyword "hedge"
      d <- durationP
      most <- option 2 (keyword "max" *> count')
      pure (\p -> p { policyHedge = Just (Hedge d most) })
    compensateP = plain (keyword "compensate" *> ((\undo p -> p { policyCompensate = Just undo }) <$> qualifiedName))
    plain p = (\f -> (f, [])) <$> p
    elseP kind = maybe [] (\e -> [(kind, e)]) <$> optional (keyword "else" *> (constant <$> qualifiedName))
    constant name = if startsUpper name then ConstructLit name [] else Var name
    waitP = (Nothing <$ keyword "reject") <|> (keyword "wait" *> (Just <$> optional (keyword "max" *> durationP)))
    rateLimitP = do
      keyword "rateLimit"
      kind <- choice [k <$ keyword k | k <- ["tokenBucket", "leakyBucket", "fixedWindow", "slidingWindow"]]
      n <- count'
      period <- durationP
      wait <- waitP
      failure <- elseP "RateLimited"
      pure (\p -> p { policyLimit = Just (Limit kind n period wait (resilienceName (kind ++ "Start")) (resilienceName (kind ++ "Admit"))) }, failure)
    breakerP = do
      keyword "circuitBreaker"
      failures <- count'
      window <- durationP
      keyword "cooldown"
      cooldown <- durationP
      failure <- elseP "CircuitOpen"
      pure (\p -> p { policyBreaker = Just (Breaker failures window cooldown
        (resilienceName "breakerStart") (resilienceName "breakerAdmit") (resilienceName "breakerRecord")) }, failure)
    bulkheadP = do
      keyword "bulkhead"
      n <- count'
      wait <- waitP
      failure <- elseP "Saturated"
      pure (\p -> p { policyBulkhead = Just (Bulkhead n wait
        (resilienceName "bulkheadStart") (resilienceName "bulkheadAdmit") (resilienceName "bulkheadRelease")) }, failure)
    cacheP = plain (keyword "cache" *> ((\ttl p -> p { policyCache = Just ttl }) <$> durationP))
    retryP = plain $ do
      keyword "retry"
      (strategy, attempts) <- choice
        [ (,) Immediate <$> (keyword "immediate" *> count')
        , (\d n -> (Fixed d, n)) <$> (keyword "fixed" *> durationP) <*> count'
        , (\d s n -> (Linear d s, n)) <$> (keyword "linear" *> durationP) <*> durationP <*> count'
        , (\d f n m -> (Exponential d f m, n)) <$> (keyword "exponential" *> durationP) <*> count' <*> count'
            <*> optional (keyword "max" *> durationP)
        , (\d n -> (Fibonacci d, n)) <$> (keyword "fibonacci" *> durationP) <*> count'
        , (\f n -> (Custom f, maybe 0 id n)) <$> (keyword "custom" *> qualifiedName) <*> optional count' ]
      jitter <- option NoJitter (keyword "jitter" *> choice
        [FullJitter <$ keyword "full", EqualJitter <$ keyword "equal", DecorrelatedJitter <$ keyword "decorrelated"])
      condition <- optional (keyword "when" *> qualifiedName)
      pure (\p -> p { policyRetry = Just (Retry strategy attempts jitter condition) })
    timeoutP = do
      keyword "timeout"
      d <- durationP
      failure <- elseP "TimedOut"
      pure (\p -> p { policyTimeout = Just d }, failure)
    count' = lexeme L.decimal
    durationP = do
      e <- numeric
      case e of
        ConstructLit "Duration" [Number micros] -> pure micros
        _ -> fail "expected a duration, such as 250ms"
    stageP = do
      (stage, stageRange) <- withSpan $ choice
        [ try (DeclaredStep <$> ident <* symbol "::" <*> typeP)
        , try ((keyword "then" <|> void (symbol ">>=")) *> (DeclaredStep <$> ident <* symbol "::" <*> typeP))
        , StepStage <$> ((keyword "then" <|> void (symbol ">>=")) *> qualifiedName)
        , MapStage <$> ((keyword "map" <|> void (symbol "<$>")) *> qualifiedName)
        , MapErrorStage <$> ((keyword "mapError" <|> void (symbol "<!>")) *> qualifiedName)
        , OrElseStage <$> ((keyword "orElse" <|> keyword "recover" <|> void (symbol "<|>")) *> qualifiedName)
        , FallbackStage <$> ((keyword "fallback" <|> void (symbol "??")) *> qualifiedName)
        , TapStage <$> (keyword "tap" *> qualifiedName)
        , do
            keyword "all"
            accumulate <- option False (True <$ keyword "accumulate")
            steps <- some (choice
              [ try ((\n t -> (n, Just t)) <$> ident <* symbol "::" <*> typeP)
              , (\n -> (n, Nothing)) <$> ((keyword "then" <|> void (symbol ">>=")) *> qualifiedName) ])
            keyword "end"
            keyword "combine"
            AllStage accumulate steps <$> qualifiedName
        , EnsureStage <$> (keyword "ensure" *> qualifiedName) <*> (keyword "else" *> qualifiedName) ]
      pure (WorkflowStage stage stageRange)

-- | model name :: [shared] S by M is ... end: commands paired with reference
-- definitions over the model state M. Each line is a command, `start`,
-- `abstract` or `invariant`; `~` and `by` both read "modelled by".
-- protocol Name is (send T | receive T | ! T | ? T)* end: what one end of a
-- channel sends and receives, in order. `.` may separate steps.
protocolP :: P Protocol
protocolP = do
  ((name, steps), range) <- withSpan $ do
    keyword "protocol"
    name <- ident
    keyword "is"
    steps <- many (step <* optional (symbol "."))
    keyword "end"
    pure (name, steps)
  pure (Protocol name steps range)
  where
    step = (Send <$> ((keyword "send" <|> void (symbol "!")) *> typeAtom))
      <|> (Receive <$> ((keyword "receive" <|> void (symbol "?")) *> typeAtom))

-- | scenario `name` in model is (channel c :: Protocol)* statement* end. A
-- command's arguments are on its own line.
scenarioP :: P Scenario
scenarioP = do
  ((name, model, channels, body), range) <- withSpan $ do
    keyword "scenario"
    name <- quoted
    keyword "in"
    model <- ident
    keyword "is"
    -- channel c :: Protocol, or mailbox m of Type: many senders, one receiver.
    declared <- many $ choice
      [ do ((c, p), at) <- withSpan ((,) <$> (keyword "channel" *> ident) <*> (symbol "::" *> ident))
           pure (Left (c, p, at))
      , do ((m, t), at) <- withSpan ((,) <$> (keyword "mailbox" *> ident) <*> (keyword "of" *> typeP))
           pure (Right (m, t, at)) ]
    body <- statements
    keyword "end"
    pure (name, model, declared, body)
  pure (Scenario name model [c | Left c <- channels] body range [m | Right m <- channels])
  where
    statements = many statement
    statement = choice [parallel, sending, receiving, expecting, try binding, calling]
    parallel = do
      ((branches), at) <- withSpan $ do
        keyword "par"
        first <- statements
        rest <- many (keyword "with" *> statements)
        keyword "end"
        pure (first : rest)
      pure (Par branches at)
    sending = do
      ((c, v), at) <- withSpan ((,) <$> (keyword "send" *> ident) <*> argument)
      pure (SendTo c v at)
    -- receive c x [or else statements end]: the statements run instead of
    -- the rest of the process when c's other process has failed.
    receiving = do
      ((c, x, handler), at) <- withSpan ((,,) <$> (keyword "receive" *> ident) <*> ident
        <*> optional (try (keyword "or" *> keyword "else") *> statements <* keyword "end"))
      pure (ReceiveFrom c x handler at)
    expecting = do
      ((x, v), at) <- withSpan ((,) <$> (keyword "expect" *> ident) <*> (symbol "=" *> constant))
      pure (Expect x v at)
    binding = do
      ((x, (command, args)), at) <- withSpan ((,) <$> (ident <* symbol "<-") <*> invocation)
      pure (Bind x command args at)
    calling = do
      ((command, args), at) <- withSpan invocation
      pure (Call command args at)
    invocation = do
      line <- sourceLine <$> getSourcePos
      command <- ident
      args <- many (try (do
        here <- sourceLine <$> getSourcePos
        unless (here == line) (fail "a command's arguments are on its line")
        argument))
      pure (command, args)
    argument = (Given <$> (char '~' *> ident)) <|> (Constant <$> constant) <|> (Held <$> ident)
    constant = parens expr <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> ConstructLit n []) <$> try (ident >>= \n -> upper n >> pure n))

-- | A name that starts with an uppercase letter, as a type's does.
upper :: String -> P ()
upper n = unless (maybe False (isUpper . fst) (uncons n)) (fail "expected a type name")

modelP :: P ModelDeclaration
modelP = do
  ((name, shared, state, model, items), range) <- withSpan $ do
    keyword "model"
    name <- ident
    void (symbol "::")
    shared <- option False (True <$ keyword "shared")
    state <- typeP
    behaves <- (False <$ keyword "by") <|> (True <$ (keyword "behaves" *> keyword "like"))
    model <- typeP
    keyword "is"
    items <- many item
    keyword "end"
    pure (name, (shared, behaves), state, model, items)
  let (sharedModel, behavesLike) = shared
  pure (ModelDeclaration name sharedModel state model
    (case [s | Left (Left s) <- items] of s : _ -> Just s; [] -> Nothing)
    [c | Right (Left c) <- items]
    (case [a | Left (Right (Left a)) <- items] of a : _ -> Just a; [] -> Nothing)
    [i | Left (Right (Right i)) <- items] range behavesLike Nothing Nothing
    (case [c | Right (Right c) <- items] of c : _ -> Just c; [] -> Nothing))
  where
    modelledBy = void (symbol "~") <|> keyword "by"
    item = choice
      -- A collection model's start may leave its state out: it is empty.
      [ (\f e -> Left (Left (f, e))) <$> (keyword "start" *> ident) <*> option (Var "") (modelledBy *> value)
      , Left . Right . Left <$> (keyword "abstract" *> qualifiedName)
      , Left . Right . Right <$> (keyword "invariant" *> qualifiedName)
      , (\c r w -> Right (Left (ModelCommand c r w False))) <$> try (ident <* modelledBy) <*> qualifiedName
          <*> optional (keyword "when" *> qualifiedName)
      , (\c op -> Right (Left (ModelCommand c op Nothing True))) <$> try (ident <* keyword "as") <*> ident
      , Right . Right <$> (keyword "consistency" *> choice
          [ Linearizable <$ keyword "linearizable", Sequential <$ keyword "sequential"
          , Causal <$ keyword "causal", Eventual <$ keyword "eventual" ]) ]
    -- A model value: a literal, a name or a parenthesized expression, so it
    -- cannot run into the next line.
    value = parens expr
      <|> (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ","))
      <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> if maybe False (isUpper . fst) (uncons n) then ConstructLit n [] else Var n) <$> qualifiedName)

-- | actor name :: State by Model is ... end: a process owning a State that
-- handles one message at a time. `on message by reference [when p]` pairs a
-- handler (an adapter State -> args -> Pair Result State) with its
-- reference; `start f [by value]` makes the state; `restart from f by g`
-- gives a restarted actor's state from its last one (g, the model's). Its handle type is the actor's
-- name, capitalized, then Actor: actor account has an AccountActor.
actorP :: P ModelDeclaration
actorP = do
  ((name, own, model, items), range) <- withSpan $ do
    keyword "actor"
    name <- ident
    void (symbol "::")
    own <- typeP
    keyword "by"
    model <- typeP
    keyword "is"
    items <- many item
    keyword "end"
    pure (name, own, model, items)
  let handle = case name of
        c : cs -> toUpper c : cs ++ "Actor"
        [] -> []
      first xs = case xs of x : _ -> Just x; [] -> Nothing
  pure (ModelDeclaration name True (Named handle) model
    (first [s | Left (Left s) <- items])
    [c | Right (Left c) <- items]
    (first [a | Left (Right (Left a)) <- items])
    [i | Left (Right (Right i)) <- items] range False (Just own)
    (first [r | Right (Right r) <- items]) Nothing)
  where
    modelledBy = void (symbol "~") <|> keyword "by"
    item = choice
      [ (\f e -> Left (Left (f, e))) <$> (keyword "start" *> ident) <*> option (Var "") (modelledBy *> value)
      , Left . Right . Left <$> (keyword "abstract" *> qualifiedName)
      , Left . Right . Right <$> (keyword "invariant" *> qualifiedName)
      , (\f g -> Right (Right (f, g))) <$> (keyword "restart" *> keyword "from" *> qualifiedName) <*> (modelledBy *> qualifiedName)
      , (\c r w -> Right (Left (ModelCommand c r w False))) <$> (keyword "on" *> ident) <*> (modelledBy *> qualifiedName)
          <*> optional (keyword "when" *> qualifiedName) ]
    value = parens expr
      <|> (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ","))
      <|> try numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
      <|> ((\n -> if maybe False (isUpper . fst) (uncons n) then ConstructLit n [] else Var n) <$> qualifiedName)

-- | supervisor name is [strategy] [at most n restarts in d] child... end:
-- children are actors or supervisors, each permanent, transient or
-- temporary. The default strategy is one for one, and the default limit 3
-- restarts in 5s.
supervisorP :: P Supervisor
supervisorP = do
  keyword "supervisor"
  name <- ident
  keyword "is"
  strategy <- option OneForOne $ choice
    [ try (keyword "one" *> keyword "for" *> keyword "one") $> OneForOne
    , try (keyword "one" *> keyword "for" *> keyword "all") $> OneForAll
    , (keyword "rest" *> keyword "for" *> keyword "one") $> RestForOne ]
  (restarts, period) <- option (3, 5000000) $ do
    keyword "at"
    keyword "most"
    n <- lexeme L.decimal
    void (keyword "restarts" <|> keyword "restart")
    keyword "in"
    e <- numeric
    case e of
      ConstructLit "Duration" [Number micros] -> pure (n, micros)
      _ -> fail "expected a duration, such as 5s"
  children <- many ((,) <$> choice [Permanent <$ keyword "permanent", Transient <$ keyword "transient", Temporary <$ keyword "temporary"] <*> ident)
  keyword "end"
  pure (Supervisor name strategy restarts period children)

-- | Declarations with a Natural parameter or an index equation are indexed
-- families; LawSpec.Indexed elaborates them after the unit is parsed.
declarationP :: P (Either IndexedFamily DataTypeDeclaration)
declarationP = do
  ((name, parameters, constructors), range) <- withSpan $ do
    keyword "type"
    name <- upperName
    parameters <- many $ parens $ do
      parameter <- ident
      unless (maybe False (isLower . fst) (uncons parameter)) (fail "type parameters must start with a lowercase letter")
      void (symbol "::")
      isType <- (True <$ keyword "Type") <|> (False <$ keyword naturalRefinementName)
      pure (parameter, isType)
    keyword "is"
    let typeParameters = [p | (p, True) <- parameters]
        equation = do
          lhs <- ident
          void (symbol "=")
          if lhs `elem` typeParameters then (,) lhs . Left <$> typeP else (,) lhs . Right <$> indexExpr
    constructors <- many $ do
      void (optional (symbol "|"))
      ((tag, fields, equations), constructorRange) <- withSpan $ do
        tag <- upperName
        fields <- many $ try $ do
          field <- ident
          unless (maybe False (isLower . fst) (uncons field)) (fail "field names must start with a lowercase letter")
          void (symbol "::")
          (,) field <$> typeP
        -- An equation on a Type parameter refines it (a GADT constructor); on
        -- a Natural parameter it states the index.
        equations <- option [] (keyword "where" *> (equation `sepBy1` symbol ","))
        pure (tag, fields, equations)
      let indexEquations = [(n, e) | (n, Right e) <- equations]
          typeEquations = [(n, t) | (n, Left t) <- equations]
      pure (IndexedConstructor (ConstructorDeclaration tag fields constructorRange typeEquations) indexEquations)
    keyword "end"
    pure (name, parameters, constructors)
  pure $ if all snd parameters && all (null . indexedEquations) constructors
    then Right (DataTypeDeclaration name (map fst parameters) (map indexedDeclaration constructors) range Nothing)
    else Left (IndexedFamily name parameters constructors range)
  where
    upperName = do
      name <- ident
      unless (maybe False (isUpper . fst) (uncons name)) (fail "type and constructor names must start with an uppercase letter")
      pure name
-- | Index expressions are natural arithmetic, written only where an index is
-- expected. div, mod and ^ elaborate to the prelude's quot, rem and pow, which
-- agree with them on naturals.
indexExpr :: P Expr
indexExpr = located $ makeExprParser indexAtom
  [ [InfixR (helper "pow" <$ symbol "^")]
  , [InfixL (Binary "*" <$ symbol "*"), InfixL (helper "quot" <$ keyword "div"), InfixL (helper "rem" <$ keyword "mod")]
  , [InfixL (Binary "+" <$ symbol "+"), InfixL (Binary "-" <$ try (symbol "-" <* notFollowedBy (char '>')))]
  ]
  where
    helper name a b = Apply (Apply (Var ("prelude." ++ name)) a) b
    indexAtom = located (parens indexExpr <|> try numeric <|> (Var <$> ident))

-- | `e1; e2` sequences at the lowest precedence, and `~s := e` updates a
-- definition's flow parameter just above it.
expr :: P Expr
expr = do
  first <- statement
  option first (located (Binary ";" first <$> (symbol ";" *> expr)))
  where
    statement = do
      e <- operatorExpr
      option e (located (Binary ":=" e <$> (symbol ":=" *> operatorExpr)))

operatorExpr :: P Expr
operatorExpr = located $ makeExprParser application
  [ [Prefix (Unary "!" <$ try (lexeme (char '!' <* notFollowedBy (char '=')))), Prefix (Unary "-" <$ try (lexeme (char '-' <* notFollowedBy digitChar)))]
  , [InfixR (Compose <$ symbol ".")]
  , [InfixL (Binary "*" <$ symbol "*"), InfixL (Binary "/" <$ symbol "/")]
  , [InfixL (Binary "+" <$ symbol "+"), InfixL (Binary "-" <$ symbol "-")]
  -- Railway combinators on Either (LawSpec.Railway), each also written as a
  -- prelude name: >=> composes, <$> <!> <*> map and pair, >>= binds, <|> and
  -- ?? recover, and |> applies.
  , [InfixR (Binary ">=>" <$ operator ">=>")]
  , [InfixL (Binary op <$ operator op) | op <- ["<$>","<!>","<*>"]]
  , [InfixL (Binary ">>=" <$ operator ">>=")]
  , [InfixL (Binary op <$ operator op) | op <- ["<|>","??"]]
  , [InfixL (Binary "|>" <$ operator "|>")]
  , [InfixN (Binary op <$ operator op) | op <- ["<=",">=","==","!=","<",">"]]
  , [InfixL (Binary "&&" <$ symbol "&&")]
  , [InfixL (Binary "||" <$ symbol "||")]
  ]
  where
    -- An operator never matches the start of a longer one: < is not <$>
    -- or <|>, > is not >>= or >=>, and >= is not >=>.
    operator op = try (symbol op <* notFollowedBy (oneOf (longer op)))
    longer op = case op of
      "<" -> "$!*|=" :: String
      ">" -> ">="
      ">=" -> ">"
      _ -> ""
    application = do
      terms <- some atom
      pure $ case terms of
        first:rest | ConstructLit name [] <- unlocated first -> ConstructLit name rest
        _ -> foldl1 Apply terms
    atom = located $ matchP <|> ifP <|> (ListLit <$> between (symbol "[") (symbol "]") (expr `sepBy` symbol ",")) <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> try scalarP
      <|> parenthesizedExpr
      <|> try (Var . ('~' :) <$> (char '~' *> ident))
      <|> try numeric <|> try (do n <- ident; alias <- asks (M.member ("alias:" ++ n)); unless (not alias) (fail "import alias"); void (char '.'); b <- ("min" <$ keyword "min") <|> ("max" <$ keyword "max"); pure (TypeBound b (if maybe False (isLower . fst) (uncons n) then Variable n else Named n))) <|> try valueAtom
    -- if, then and else are keywords inside expressions.
    valueAtom = do
      name <- valueName
      when (name `elem` ["if", "then", "else"]) (fail ("expected a value, not the keyword " ++ name))
      pure (if startsUpper name then ConstructLit name [] else Var name)
    -- if c then a else b: only the branch c selects is evaluated (it is
    -- prelude.select, which elaborates to Core's If).
    ifP = do
      keyword "if"
      condition <- expr
      keyword "then"
      yes <- expr
      keyword "else"
      no <- expr
      pure (foldl Apply (Var "prelude.select") [condition, yes, no])
    matchP = do
      keyword "match"
      value <- expr
      keyword "with"
      branches <- some $ do
        void (symbol "|")
        tag <- qualifiedName
        unless (startsUpper tag) (fail "expected constructor in match pattern")
        names <- many ident
        unless (all (maybe False (isLower . fst) . uncons) names) (fail "pattern binders must start with a lowercase letter")
        void (symbol "->")
        MatchBranch tag names <$> expr
      keyword "end"
      pure (MatchExpr value branches)
    valueName = try (do keyword "prelude"; void (symbol "."); n <- ident; pure ("prelude." ++ n)) <|> qualifiedName
    -- An adjacent sign remains part of a numeric argument: f -42. For subtraction use x - 42.
located :: P Expr -> P Expr
located parser = do
  (value,range) <- withSpan parser
  pure (Located range value)
withSpan :: P a -> P (a,Span)
withSpan parser = do
  start <- getSourcePos
  value <- parser
  end <- getSourcePos
  let position p = Location (sourceName p) (unPos (sourceLine p)) (unPos (sourceColumn p))
  pure (value,Span (position start) (position end))
numeric :: P Expr
numeric = lexeme $ do
  sign <- option "" ((:[]) <$> oneOf ['-','+'])
  ds <- some digitChar
  fraction <- optional (try (char '.' *> some digitChar))
  powerToken <- optional (try (oneOf ['e','E'] *> L.signed (pure ()) L.decimal))
  let power = maybe 0 id powerToken
  let coefficient = read ((if sign == "+" then "" else sign) ++ ds ++ maybe "" id fraction)
  -- A duration literal: a whole number of units, as in 250ms, is the constant
  -- Duration of that many microseconds (LawSpec.Time).
  unit <- optional (try (choice [constructor <$ (string suffix <* notFollowedBy (alphaNumChar <|> char '_'))
    | (suffix, constructor) <- durationSuffixes]))
  case (unit, sign, fraction, powerToken) of
    (Just constructor, "", Nothing, Nothing)
      | coefficient * durationFactor constructor <= durationLimit -> pure (ConstructLit "Duration" [Number (coefficient * durationFactor constructor)])
      | otherwise -> fail ("a duration is at most " ++ show durationLimit ++ " microseconds")
    (Just _, _, _, _) -> fail "a duration literal is a whole number of units, without a sign"
    (Nothing, _, Nothing, Nothing) -> pure (Number coefficient)
    _ -> pure (DecimalNumber coefficient (power - maybe 0 (fromIntegral . length) fraction))
scalarP :: P Expr
scalarP = ScalarLit <$> choice
  [ SAbsent "Unit" <$ keyword "unitValue", SAbsent "Null" <$ keyword "null", SAbsent "Undefined" <$ keyword "undefined"
  , constructor "rational" (SRational <$> integer <* symbol "," <*> integer)
  , constructor "decimal" (SDecimal <$> integer <* symbol "," <*> integer)
  , constructor "symbol" (SSymbol <$> str <* symbol "," <*> str)
  , choice [constructor n (SSequence t <$> units) | (n,t) <- [("bytes","Bytes"),("codePoints","CodePointText"),("utf16","Utf16Text")]]
  , choice [constructor n (SCharacter t <$> unitInteger) | (n,t) <- [("char","Char"),("codePoint","CodePoint"),("codeUnit16","CodeUnit16")]]
  , choice [constructor n (SFloat t <$> str) | (n,t) <- [("float32Bits","Float32"),("float64Bits","Float64")]]
  , choice [constructor n (do r <- component t; void (symbol ","); i <- component t; pure (SComplex result r i)) | (n,t,result) <- [("complex64","Float32","Complex64"),("complex128","Float64","Complex128")]]
  , choice [constructor n (SPresent t . Just <$> scalarLiteral) | (n,t) <- [("nullable","Nullable"),("optional","Optional")]]
  ]
  where
    constructor n p = try (keyword n *> parens p)
    integer = lexeme (L.signed (pure ()) L.decimal)
    unitInteger = do n <- integer; if n >= 0 && n <= 1114111 then pure (fromInteger n) else fail "code point or unit outside representable range"
    units = between (symbol "[") (symbol "]") (unitInteger `sepBy` symbol ",")
    scalarLiteral = do e <- scalarP <|> numeric <|> (StringLit <$> str) <|> (BoolLit <$> boolP)
                       case e of ScalarLit v -> pure v; Number n -> pure (SInteger "BigInt" n); DecimalNumber c p -> pure (SDecimal c p); StringLit s -> pure (textScalar s); BoolLit b -> pure (SBool b); _ -> fail "concrete scalar required"
    component t = do
      e <- try numeric <|> scalarP
      let value = case e of Number n -> SInteger "BigInt" n; DecimalNumber c p -> SDecimal c p; ScalarLit s -> s; _ -> SAbsent "invalid"
      either fail pure (convertScalar 64 t value)
parenthesizedExpr :: P Expr
parenthesizedExpr = parens (do e <- expr; option e (Annotate e <$> (symbol "::" *> typeP)))

defP :: P Definition
defP = (do void (symbol "`for all`"); ps <- some param; void (symbol "."); Forall ps <$> defP)
   <|> do a <- clause
          option a (And a <$> (keyword "and" *> defP))
  where
    clause = (Invoke <$> lawReference <*> many (parenthesizedExpr <|> (BoolLit <$> boolP) <|> (StringLit <$> str) <|> (Number <$> lexeme (L.signed (pure ()) L.decimal)) <|> (Var <$> qualifiedName)))
      <|> try (do
        a <- expr
        (keyword "implies" *> (Implies a <$> defP))
          <|> (symbol "=" *> (Equal a <$> expr))
          <|> pure (Holds a))
      <|> parens defP
boolP :: P Bool
boolP = (keyword "true" *> pure True) <|> (keyword "false" *> pure False)
constructorLiteral :: P Literal
constructorLiteral = do
  name <- try $ do
    name <- qualifiedName
    unless (startsUpper name) (fail "expected constructor literal")
    pure name
  declared <- asks (M.lookup ("constructor:" ++ name))
  arity <- case declared of
    Just (DataHeader fields) -> pure (length fields)
    _ -> maybe (fail ("unknown literal constructor: " ++ name)) pure
      (lookup name [("Nothing",0),("Just",1),("Left",1),("Right",1),("Nil",0),("Cons",2)])
  ConstructorLiteral name <$> count arity literalP

literalP :: P Literal
literalP = constructorLiteral
  <|> (ListLiteral <$> between (symbol "[") (symbol "]") (literalP `sepBy` symbol ","))
  <|> try (do e <- scalarP; case e of ScalarLit v -> pure (ScalarLiteral v); _ -> fail "literal")
  <|> try (parens (do
        e <- numeric <|> scalarP
        void (symbol "::")
        t <- typeP
        case (e,t) of
          (Number n,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SInteger "BigInt" n))
          (DecimalNumber c p,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name (SDecimal c p))
          (ScalarLit v,Named name) -> either fail (pure . ScalarLiteral) (convertScalar 64 name v)
          _ -> fail "expected concrete annotated literal"))
  <|> parens literalP
  <|> (BoolLiteral <$> boolP) <|> (TextLiteral <$> str)
  <|> numericLiteral
  where
    numericLiteral = do
      e <- numeric
      case e of
        Number n -> pure (IntLiteral n)
        DecimalNumber c p -> pure (DecimalLiteral c p)
        ScalarLit v -> pure (ScalarLiteral v)
        -- A duration literal, such as 250ms.
        ConstructLit name [Number n] -> pure (ConstructorLiteral name [IntLiteral n])
        _ -> fail "literal"

block :: String -> P a -> P a
block n p = keyword n *> keyword "is" *> p <* keyword "end"
lawP :: P Law
lawP = do
  pos <- getSourcePos
  keyword "law"
  n <- quoted
  ps <- many param
  req <- constraintsP
  keyword "is"
  d <- block "definition" defP
  desc <- option "" (block "description" str)
  why <- option "" (block "rationale" str)
  ex <- many $ do
    keyword "example"; en <- quoted; keyword "is"
    bs <- some ((,) <$> ident <* symbol "=" <*> literalP)
    checks <- many (keyword "expect" *> (Expectation <$> expr <* symbol "=" <*> literalP))
    keyword "end"; pure (Example en bs checks)
  refs <- option [] (keyword "references" *> keyword "are" *> some str <* keyword "end")
  keyword "end"
  pure (Law n ps req d desc why ex refs (Location (sourceName pos) (unPos (sourceLine pos)) (unPos (sourceColumn pos))))
-- | Unit definitions have explicit parameter and result types. Law definitions
-- remain proposition blocks and are parsed separately by lawP.
functionDefinitionP :: P FunctionDefinition
functionDefinitionP = do
  ((name, arguments, result, requirements, body), range) <- withSpan $ do
    keyword "definition"
    name <- ident
    arguments <- some param
    void (symbol "::")
    result <- typeP
    requirements <- constraintsP
    body <- keyword "is" *> expr <* keyword "end"
    pure (name, arguments, result, requirements, body)
  pure (FunctionDefinition name arguments result requirements body range)

data UnitMember = DataMember DataTypeDeclaration | FamilyMember IndexedFamily | RefinementMember Refinement
  | WrapperMember Wrapper | WorkflowMember Workflow | ModelMember ModelDeclaration
  | SupervisorMember Supervisor
  | MailboxMember (String, Type, Span)
  | HandleMember (String, Span) | ProtocolMember Protocol | ScenarioMember Scenario
  | SignatureMember ((String, Type), Span) | AsyncMember ((String, Type), Span) | LawMember Law
  | DefinitionMember FunctionDefinition

unitNameP :: P String
unitNameP = foldr1 (\a b -> a ++ "." ++ b) <$>
  (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')) `sepBy1` symbol ".")

importP :: P Import
importP = do
  ((target, alias, items), range) <- withSpan $ do
    keyword "import"
    target <- unitNameP
    alias <- optional (keyword "as" *> ident)
    items <- option [] (parens (((\n -> "`" ++ n ++ "`") <$> quoted <|> ident) `sepBy1` symbol ","))
    pure (target, alias, items)
  pure (Import target (maybe (baseName target) id alias) items range)

-- | export Money, domain.add, `commutative`: names this unit imports, offered
-- to the units that import it as if declared here (a facade). It is kept with
-- the imports, as an Import of no unit.
exportP :: P Import
exportP = do
  (items, range) <- withSpan $ do
    keyword "export"
    (((\n -> "`" ++ n ++ "`") <$> quoted) <|> qualifiedExport) `sepBy1` symbol ","
  pure (Import "" "" items range)
  where
    qualifiedExport = lexeme $ try $ do
      first <- (:) <$> letterChar <*> many (alphaNumChar <|> char '_')
      rest <- optional (char '.' *> ((:) <$> letterChar <*> many (alphaNumChar <|> char '_')))
      pure (maybe first (\r -> first ++ "." ++ r) rest)

-- | Whether an Import is a unit's export line.
isExport :: Import -> Bool
isExport i = null (importUnit i)

-- | The unit header and its imports, read before the full parse so that imported
-- declaration arities are known.
preambleP :: P (String, [Import])
preambleP = do
  spaceP; keyword "unit"
  n <- unitNameP
  imports <- many (try importP <|> try exportP)
  pure (n, imports)

unitP :: P (Unit, [Import], [IndexedFamily], [Wrapper], [Workflow], [ModelDeclaration], ([Protocol], [Scenario]))
unitP = do
  (n, imports) <- preambleP
  members <- many ((either FamilyMember DataMember <$> declarationP)
    <|> (WrapperMember <$> wrapperP)
    <|> (WorkflowMember <$> workflowP)
    <|> (ProtocolMember <$> (try (lookAhead (keyword "protocol" *> ident >>= upper)) *> protocolP))
    <|> (ScenarioMember <$> (try (lookAhead (keyword "scenario" *> quoted)) *> scenarioP))
    -- handle Name: a type whose values only adapters create.
    <|> (HandleMember <$> (try (lookAhead (keyword "handle" *> ident >>= upper)) *> withSpan (keyword "handle" *> ident)))
    -- `model` begins a model only before a name; it may name a function.
    <|> (ModelMember <$> (try (lookAhead (keyword "model" *> ident)) *> modelP))
    <|> (ModelMember <$> (try (lookAhead (keyword "actor" *> ident)) *> actorP))
    <|> (SupervisorMember <$> (try (lookAhead (keyword "supervisor" *> ident)) *> supervisorP))
    -- mailbox jobs of Job: a typed queue with many senders and one receiver.
    <|> (MailboxMember <$> (try (lookAhead (keyword "mailbox" *> ident *> keyword "of")) *>
          ((\((n, t), at) -> (n, t, at)) <$> withSpan ((,) <$> (keyword "mailbox" *> ident) <*> (keyword "of" *> typeP)))))
    <|> (RefinementMember <$> refinementP)
    <|> (DefinitionMember <$> functionDefinitionP)
    <|> (AsyncMember <$> try (keyword "async" *> withSpan ((,) <$> ident <* symbol "::" <*> typeP)))
    <|> (SignatureMember <$> try (withSpan ((,) <$> ident <* symbol "::" <*> typeP)))
    <|> (LawMember <$> lawP))
  eof
  let definitions = [d | DefinitionMember d <- members]
      signatures = [signature | member <- members, signature <- case member of
          SignatureMember s -> [s]
          AsyncMember s -> [s]
          _ -> []] ++
        [((functionName d, foldr Arrow (functionResult d) (map snd (functionArguments d))), functionSpan d) | d <- definitions]
  pure (Unit n (map fst signatures) [l | LawMember l <- members]
    [r | RefinementMember r <- members] [] [(name,range) | ((name,_),range) <- signatures]
    ([d | DataMember d <- members] ++ [DataTypeDeclaration name [] [] range Nothing | HandleMember (name, range) <- members])
    definitions [name | AsyncMember ((name, _), _) <- members] [] [] [] [name | HandleMember (name, _) <- members]
    [p | ProtocolMember p <- members] [s | SupervisorMember s <- members] [m | MailboxMember m <- members], imports, [f | FamilyMember f <- members],
    [w | WrapperMember w <- members], [w | WorkflowMember w <- members], [m | ModelMember m <- members],
    ([p | ProtocolMember p <- members], [s | ScenarioMember s <- members]))

-- | A single source sees no other units, which is what the compiler API's
-- one-file requests and the tests need.
parseSource :: Source -> Either [Diagnostic] Unit
parseSource source = fst . fst <$> parseWith M.empty [] source

-- | Parse sources that may import one another. Each unit sees the declaration
-- arities of the units it imports, qualified by alias and unqualified for
-- listed names; LawSpec.Imports resolves the names themselves.
parseSources :: [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSources = parseSourcesWith [] []

-- | With the built-in collection types a program uses, every other unit imports
-- those it does not declare itself (LawSpec.Collections). Each other built-in
-- unit (LawSpec.Time, LawSpec.Resilience) is imported, with its types, by the
-- sources it says use it.
parseSourcesWith :: [String] -> [(String, String, [String], String -> Bool)] -> [Source] -> Either [Diagnostic] [(Unit, [Import])]
parseSourcesWith collections builtins sources = do
  mapM_ acyclic (M.keys graph)
  let names = [n | (_, n, _) <- preambles]
  forM_ names $ \n -> when (length (filter (== n) names) > 1)
    (Left [Diagnostic "duplicate-unit" "unit names must be unique; prelude is reserved" Nothing])
  mapM (\source -> either (const (fst <$> parseWith (imported source) [] source))
    (\(n, imports) -> (\(u, _) -> (u, imports)) . fst <$> results Lazy.! n) (preamble source)) sources
  where
    -- Parsed lazily in import order, so a unit sees its imports' indexed
    -- families under the names it uses for them.
    results = Lazy.fromList [(n, parseWith (imported s) (families imports) s) | (s, n, imports) <- preambles]
    families imports = concat
      [ [f{familyName = importAlias i ++ "." ++ familyName f} | f <- declared] ++
        [f | f <- declared, familyName f `elem` importItems i]
      | i <- imports, Just (Right (_, declared)) <- [Lazy.lookup (importUnit i) results] ]
    preambles = [(s, n, imports) | s <- sources, Right (n, imports) <- [preamble s]]
    preamble (Source p s) = implicit s <$> runReader (runParserT preambleP p s) M.empty
    implicit s (n, imports)
      | n `elem` ("prelude" : collectionsUnit : [unit | (unit, _, _, _) <- builtins]) = (n, imports)
      | otherwise =
          let local = M.keys (headers s)
              builtin unit alias types =
                let items = [t | t <- types, t `notElem` local]
                    origin = Location ("<" ++ unit ++ ">") 1 1
                in [Import unit alias items (Span origin origin) | not (null items)]
          in (n, imports ++ builtin collectionsUnit collectionsAlias collections ++
               concat [builtin unit alias types | (unit, alias, types, uses) <- builtins, uses s])
    graph = M.fromList [(n, imports) | (_, n, imports) <- preambles]
    -- Exports are computed lazily in import order, so an exported declaration
    -- may itself use its unit's imports.
    exports = Lazy.fromList [(n, reexported imports (sourceExports (imported s) s)) | (s, n, imports) <- preambles]
    -- A unit's export line offers the arities of the names it lists, from the
    -- units it imports them from, and a listed type's constructors with it.
    reexported imports (table, owners) =
      let listed = concat [importItems i | i <- imports, isExport i]
          from i item = case break (== '.') item of
            (alias, '.' : name) | alias == importAlias i -> Just name
            _ | item `elem` importItems i -> Just item
              | otherwise -> Nothing
          found = [ (name, t, o) | i <- imports, not (isExport i), item <- listed, Just name <- [from i item]
                  , Just (t, o) <- [Lazy.lookup (importUnit i) exports] ]
          entries = M.fromList $ concat
            [ [(key, h) | (key, h) <- M.toList t, key == name || key == "constructor:" ++ name ||
                maybe False (\cs -> case break (== ':') key of
                  ("constructor", ':' : c) -> c `elem` cs
                  _ -> False) (lookup name o)]
            | (name, t, o) <- found ]
          ownersOut = [(name, cs) | (name, _, o) <- found, Just cs <- [lookup name o]]
      in (M.union table entries, owners ++ ownersOut)
    imported source = case preamble source of
      Left _ -> M.empty
      Right (_, imports) -> M.unions
        [ M.insert ("alias:" ++ importAlias i) AliasHeader (M.unions
            [ M.fromList [(qualify (importAlias i) key, h) | (key, h) <- M.toList table]
            , M.fromList [(key, h) | (key, h) <- M.toList table, listed owners (importItems i) key] ])
        | i <- imports, Just (table, owners) <- [Lazy.lookup (importUnit i) exports] ]
    qualify alias key = case break (== ':') key of
      ("constructor", ':' : n) -> "constructor:" ++ alias ++ "." ++ n
      _ -> alias ++ "." ++ key
    listed owners items key = case break (== ':') key of
      ("constructor", ':' : n) -> any (\item -> maybe False (n `elem`) (lookup item owners)) items
      _ -> key `elem` items
    acyclic start = go [start] start
      where
        go path n = forM_ (M.findWithDefault [] n graph) $ \i ->
          if importUnit i == start
            then Left [Diagnostic "import" ("import cycle: " ++ intercalate " -> " (reverse path ++ [start]))
              (Just (spanStart (importSpan i)))]
            else unless (importUnit i `elem` path) (go (importUnit i : path) (importUnit i))

-- | The unit a source declares.
sourceUnit :: Source -> Either String String
sourceUnit (Source p s) = either (Left . errorBundlePretty) (Right . fst)
  (runReader (runParserT preambleP p s) M.empty)

-- | The headers a unit exports: its type, wrapper and refinement arities and its
-- constructor arities, with each data type's constructors.
sourceExports :: M.Map String Header -> Source -> (M.Map String Header, [(String, [String])])
sourceExports extra (Source _ s) =
  (M.filterWithKey (\key _ -> not ('.' `elem` key)) (literalHeaders s (M.union (headers s) extra)),
   constructorOwners extra s)

parseWith :: M.Map String Header -> [IndexedFamily] -> Source -> Either [Diagnostic] ((Unit, [Import]), [IndexedFamily])
parseWith extra importedFamilies (Source p s) = case runReader (runParserT unitP p s) (literalHeaders s (M.union (headers s) extra)) of
  Left e -> Left [Diagnostic "parse" (errorBundlePretty e) Nothing]
  Right (u, imports, families, wrappers, workflows, models, (protocols, scenarios)) -> do
    domained <- either (\(at, message) -> Left [Diagnostic "domain" message at]) Right
      (elaborateDomain wrappers workflows (railwayUnit u))
    -- Models read typestate from flow parameters, so they come first.
    modeled <- either (\(at, message) -> Left [Diagnostic "model" message (spanStart <$> at)]) Right
      (elaborateModels models domained >>= \m -> m <$ checkSupervisors m)
    programs <- either (\(at, message) -> Left [Diagnostic "scenario" message (spanStart <$> at)]) Right
      (checkScenarios protocols scenarios modeled >>= \cyclic -> mapM (uncurry (toProgram modeled)) (zip cyclic scenarios))
    let scenarioed = modeled { machines = [m { machineScenarios = [p | p <- programs, programMachine p == machineName m] }
                                          | m <- machines modeled] }
    (families', flowed) <- either (\(at, message) -> Left [Diagnostic "flow" message at]) Right
      (desugarFlows importedFamilies families scenarioed)
    elaborated <- either (\message -> Left [Diagnostic "indexed" (p ++ ": " ++ message) Nothing]) Right
      (elaborateFamiliesWith importedFamilies families' flowed)
    pure ((elaborated, imports), families')

-- | Read declaration arities before parsing applications, including forward references.
-- Strings, quoted law names and comments are consumed atomically.
headers :: String -> M.Map String Header
headers source = M.fromList (scan tokens) where
  tokens = either (const []) id $ runReader (runParserT (spaceP *> many token <* eof) "headers" source) M.empty
  token = ("<string>" <$ str) <|> ("<quoted>" <$ quoted)
      <|> lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))
      <|> symbol "::" <|> ((:[]) <$> lexeme anySingle)
  scan ("unit":_:rest) = scan (dropUnit rest)
  scan ("refinement":n:rest) = let (ks,remaining) = parametersH rest in (n,RefinementHeader ks):scan remaining
  scan ("type":n:rest) = let (ks,remaining) = parametersH rest in (n,DataHeader ks):scan remaining
  scan ("wrapper":n:rest) = let (ks,remaining) = parametersH rest in (n,DataHeader ks):scan remaining
  scan ("handle":n:rest) | maybe False (isUpper . fst) (uncons n) = (n,DataHeader []):scan rest
  scan (_:rest) = scan rest
  scan [] = []
  dropUnit (".":_:rest) = dropUnit rest
  dropUnit rest = rest
  parametersH ("(":rest) = let (inside,remaining) = group (1 :: Int) [] rest
                               (ks,remaining') = parametersH remaining
                           in ((case inside of [_ ,"::","Type"] -> True; _ -> False):ks,remaining')
  parametersH rest = ([],rest)
  group _ acc [] = (reverse acc,[])
  group depth acc (t:rest)
    | t == ")" && depth == 1 = (reverse acc,rest)
    | otherwise = group (depth + if t == "(" then 1 else if t == ")" then -1 else 0) (t:acc) rest

-- | Each data type or wrapper with its constructor names.
constructorOwners :: M.Map String Header -> String -> [(String, [String])]
constructorOwners extra source = either (const []) id $
  runReader (runParserT scan "constructor owners" source) (M.union (headers source) extra)
  where
    scan = spaceP *> (concat <$> many ((pure . owner <$> try dataTypeP)
      <|> ((\w -> [(wrapperName w, [wrapperName w])]) <$> try wrapperP) <|> ([] <$ token))) <* eof
    owner d = (dataTypeName d, map dataConstructorName (dataTypeConstructors d))
    token = void str <|> void quoted <|>
      void (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))) <|> void (lexeme anySingle)

-- | Reuse the declaration parser to discover fixture constructor arities. This
-- pass skips other tokens atomically; the full parse remains authoritative for
-- errors and source ranges, including malformed declarations.
literalHeaders :: String -> M.Map String Header -> M.Map String Header
literalHeaders source initial = case runReader (runParserT scan "constructor headers" source) initial of
  Left _ -> initial
  Right declarations -> M.union (M.fromList
    [("constructor:" ++ dataConstructorName c, DataHeader (replicate (length (dataConstructorFields c)) True))
      | Just d <- declarations, c <- dataTypeConstructors d]) initial
  where
    -- A wrapper's constructor shares its name and takes the single value field.
    wrapped w = DataTypeDeclaration (wrapperName w) (wrapperParameters w)
      [ConstructorDeclaration (wrapperName w) [("value", wrapperBase w)] (wrapperSpan w) []] (wrapperSpan w) Nothing
    scan = spaceP *> many ((Just <$> try dataTypeP) <|> (Just . wrapped <$> try wrapperP) <|> (Nothing <$ token)) <* eof
    token = void str <|> void quoted <|>
      void (lexeme ((:) <$> letterChar <*> many (alphaNumChar <|> char '_'))) <|> void (lexeme anySingle)
