{-# LANGUAGE FlexibleContexts, FlexibleInstances, TypeOperators, UndecidableInstances #-}
-- | A comparison view of the authoritative Core, never executable code.
-- Generic traversal retains fields that the documentary public JSON omits,
-- including constructor predicates, GADT equations and runtime contracts.
module LawSpec.Core.Migration
  ( migrationSnapshot, normalizedProgram, transformProgram, transformProgramWithTypes
  , Project(..), GenericProject(..), Context(..), semanticName ) where

import Control.Monad (unless)
import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import Data.Int
import Data.List (isPrefixOf,isSuffixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word
import GHC.Generics
import qualified LawSpec.Common as Common
import qualified LawSpec.Core as C
import LawSpec.CorePersist ()
import LawSpec.Digest (digest,digestHex)

data Context = Context
  { canonicalSource :: Bool, omitDomainPolicy :: Bool
  , globalIds :: M.Map C.Id C.Id, localIds :: M.Map C.Id C.Id
  , traceNames :: M.Map String String
  , ownerId :: C.Id, nextBinder :: Int
  , preserveSyntax :: Bool
  , rewriteExpression :: C.Expr -> Either String C.Expr
  , rewriteDeclaration :: C.DataDeclaration -> Either String C.DataDeclaration
  , structuralConstructors :: S.Set C.Id
  , rewriteType :: C.Type -> Either String C.Type }

class Project a where
  project :: Context -> a -> Either String a

class GenericProject f where
  genericProject :: Context -> f p -> Either String (f p)
instance GenericProject U1 where genericProject _ = Right
instance (Project a) => GenericProject (K1 i a) where
  genericProject context (K1 value) = K1 <$> project context value
instance (GenericProject f) => GenericProject (M1 i c f) where
  genericProject context (M1 value) = M1 <$> genericProject context value
instance (GenericProject f,GenericProject g) => GenericProject (f :*: g) where
  genericProject context (a :*: b) = (:*:) <$> genericProject context a <*> genericProject context b
instance (GenericProject f,GenericProject g) => GenericProject (f :+: g) where
  genericProject context (L1 value) = L1 <$> genericProject context value
  genericProject context (R1 value) = R1 <$> genericProject context value
instance {-# OVERLAPPABLE #-} (Generic a,GenericProject (Rep a)) => Project a where
  project context = fmap to . genericProject context . from

instance Project Char where project _ = Right
instance Project Bool where project _ = Right
instance Project Int where project _ = Right
instance Project Integer where project _ = Right
instance Project Int8 where project _ = Right
instance Project Int16 where project _ = Right
instance Project Int32 where project _ = Right
instance Project Int64 where project _ = Right
instance Project Word8 where project _ = Right
instance Project Word16 where project _ = Right
instance Project Word32 where project _ = Right
instance Project Word64 where project _ = Right
instance Project Float where project _ = Right
instance Project Double where project _ = Right
instance Project a => Project [a] where project context = mapM (project context)
instance (Ord k,Project k,Project v) => Project (M.Map k v) where
  project context values = do
    pairs <- mapM (project context) (M.toList values)
    let made=M.fromList pairs
    unless (M.size made==M.size values) (Left "migration normalization collides map identities")
    pure made
instance (Ord a,Project a) => Project (S.Set a) where
  project context values = do
    entries <- mapM (project context) (S.toList values)
    let made=S.fromList entries
    unless (S.size made==S.size values) (Left "migration normalization collides set identities")
    pure made

instance Project Common.Location where
  project context value = Right (if preserveSyntax context then value else Common.Location "<comparison>" 1 1)
instance Project Common.Span where
  project context (Common.Span start end) = Common.Span <$> project context start <*> project context end
instance Project C.Origin where
  project context value = Right (if preserveSyntax context then value else C.GeneratedFrom (C.Id "<comparison>"))
instance Project C.Type where
  project context original = do
    value <- rewriteType context original
    to <$> genericProject context (from value)

instance Project C.Id where
  project context identity = pure $ case M.lookup identity (localIds context) of
    Just made -> made
    Nothing -> case M.lookup identity (globalIds context) of
      Just made -> made
      Nothing -> case [(old,new) | (old,new) <- M.toList (globalIds context),
                        (C.idText old ++ "::") `isPrefixOf` C.idText identity] of
        [(old,new)] -> C.Id (C.idText new ++ drop (length (C.idText old)) (C.idText identity))
        _ -> identity

-- Law and named-example delimiters change; literal values never pass here.
semanticName :: Bool -> String -> String
semanticName True ('"':'|':rest) = maybe ('"':'|':rest) id (body [] rest)
  where
    body acc ('\\':c:more) | c `elem` ("\\|"::String) = body (c:acc) more
    body acc ('|':suffix) = Just (reverse acc ++ suffix)
    body acc (c:more) = body (c:acc) more
    body _ [] = Nothing
semanticName _ name = name

scope :: Context -> C.Id -> Context
scope context owner = context{ownerId=owner,localIds=M.empty,nextBinder=0}

bind :: Bool -> Context -> C.Binder -> Either String (C.Binder,Context)
bind _ context binder | preserveSyntax context = do
  made <- project context binder
  pure (made,context)
bind keepName context binder = do
  let index=nextBinder context
      identity=C.Id (C.idText (ownerId context) ++ "::bound::" ++ show index)
      inner=context{localIds=M.insert (C.binderId binder) identity (localIds context),nextBinder=index+1}
  ty <- project inner (C.binderType binder)
  pure (C.Binder identity (if keepName then C.binderName binder else "bound" ++ show index) ty,inner)

bindMany :: Bool -> Context -> [C.Binder] -> Either String ([C.Binder],Context)
bindMany _ context [] = pure ([],context)
bindMany names context (binder:rest) = do
  (made,inner) <- bind names context binder
  (others,final) <- bindMany names inner rest
  pure (made:others,final)

instance Project C.Definition where
  project context value = do
    declaration <- project context (C.definitionDeclaration value)
    (arguments,inner) <- bindMany False (scope context (C.declarationId declaration)) (C.definitionArguments value)
    body <- project inner (C.definitionBody value)
    policy <- project inner (C.definitionPolicy value)
    pure value{C.definitionDeclaration=declaration,C.definitionArguments=arguments,C.definitionBody=body,C.definitionPolicy=policy}

instance Project C.Contract where
  project context value = do
    identity <- project context (C.contractDeclaration value)
    (arguments,inner) <- bindMany False (scope context identity) (C.contractArguments value)
    (result,resultScope) <- bind False inner (C.contractResult value)
    pre <- project inner (C.contractPreconditions value)
    post <- project resultScope (C.contractPostconditions value)
    runtime <- project resultScope (C.contractRuntimePostconditions value)
    pure value{C.contractDeclaration=identity,C.contractArguments=arguments,C.contractResult=result,
      C.contractPreconditions=pre,C.contractPostconditions=post,C.contractRuntimePostconditions=runtime}

instance Project C.Quantifier where
  project context value = fst <$> quantify context value

quantify :: Context -> C.Quantifier -> Either String (C.Quantifier,Context)
quantify context value = do
  (binder,inner) <- bind False context (C.quantifiedBinder value)
  predicates <- project inner (C.quantifiedPredicates value)
  bounds <- project inner (C.quantifiedBounds value)
  pure (value{C.quantifiedBinder=binder,C.quantifiedPredicates=predicates,C.quantifiedBounds=bounds},inner)

quantifiers :: Context -> [C.Quantifier] -> Either String ([C.Quantifier],Context)
quantifiers context [] = pure ([],context)
quantifiers context (value:rest) = do
  (made,inner) <- quantify context value
  (others,final) <- quantifiers inner rest
  pure (made:others,final)

instance Project C.Property where
  project context value = do
    identity <- project context (C.propertyId value)
    (inputs,inner) <- quantifiers (scope context identity) (C.propertyInputs value)
    -- Project every other field generically: new Core fields cannot silently
    -- disappear from the comparison. Inputs already introduced their scopes.
    made <- to <$> genericProject inner (from value{C.propertyInputs=[]})
    pure made{C.propertyId=identity,C.propertyName=M.findWithDefault (C.propertyName value) (C.propertyName value) (traceNames context),
      C.propertyInputs=inputs,C.propertyTrace=map (\name -> M.findWithDefault name name (traceNames context)) (C.propertyTrace value),
      C.propertyInputDomain=if omitDomainPolicy context then Common.UniversalDomain else C.propertyInputDomain value}

instance Project C.Example where
  project context value = do
    made <- to <$> genericProject context (from value)
    pure made{C.exampleName=semanticName (canonicalSource context) (C.exampleName value)}

instance Project C.DataDeclaration where
  project context original = do
    value <- rewriteDeclaration context original
    made <- to <$> genericProject context (from value)
    -- The library identity and implementation stay the legacy ordered set.
    -- Its canonical public spelling is a documented migration, not a new type.
    pure (if not (preserveSyntax context) && C.dataId value==C.Id "lawspec.collections::type::Set"
      then made{C.dataName="Set"} else made)

instance Project C.Draw where
  project context value = case value of
    C.DrawBind binder from body -> do
      from' <- project context from
      (binder',inner) <- bind False context binder
      C.DrawBind binder' from' <$> project inner body
    C.DrawSuchThat from binder predicate limit -> do
      from' <- project context from
      (binder',inner) <- bind False context binder
      predicate' <- project inner predicate
      pure (C.DrawSuchThat from' binder' predicate' limit)
    _ -> to <$> genericProject context (from value)

instance Project C.Proposition where
  project context value = case value of
    C.Quantified kind quantifier body -> do
      (made,inner) <- quantify context quantifier
      C.Quantified kind made <$> project inner body
    C.Conjunction items | not (preserveSyntax context) -> C.Conjunction . concatMap flatten <$> project context items
    _ -> to <$> genericProject context (from value)
    where flatten (C.Conjunction xs) = concatMap flatten xs
          flatten other = [other]

instance Project C.Expr where
  project context original = do
    rewritten <- rewriteExpression context original
    let value=if preserveSyntax context then rewritten else reduce context rewritten
    ty <- project context (C.expressionType value)
    origin <- project context (C.expressionOrigin value)
    node <- case C.expressionNode value of
      C.Let binder initializer body -> do
        initializer' <- project context initializer
        (binder',inner) <- bind False context binder
        C.Let binder' initializer' <$> project inner body
      C.Match selected branches -> do
        selected' <- project context selected
        branches' <- mapM (branch context) branches
        pure (C.Match selected' branches')
      C.AllElements selected binder predicate -> do
        selected' <- project context selected
        (binder',inner) <- bind False context binder
        C.AllElements selected' binder' <$> project inner predicate
      C.AllPayloads selected predicates -> do
        selected' <- project context selected
        callbacks <- mapM (\(binder,predicate) -> do
          (binder',inner) <- bind False context binder
          (,) binder' <$> project inner predicate) predicates
        pure (C.AllPayloads selected' callbacks)
      other -> project context other
    pure (C.Expr ty node origin)
    where
      branch outer value = do
        tag <- project outer (C.caseConstructor value)
        (binders,inner) <- bindMany False outer (C.caseBinders value)
        body <- project inner (C.caseBody value)
        pure value{C.caseConstructor=tag,C.caseBinders=binders,C.caseBody=body}

-- These identities preserve strict, once-only evaluation, including
-- effects. No arbitrary let substitution or reordering is permitted.
reduce :: Context -> C.Expr -> C.Expr
reduce context expression = case C.expressionNode expression of
  -- Strict identity binding evaluates the initializer exactly once. Dependent
  -- type occurrences count as uses, so eliminating it cannot unbind an index.
  C.Let binder initializer body | C.expressionNode body==C.Local (C.binderId binder),
    uses (C.binderId binder) initializer==0,uses (C.binderId binder) body==1,
    C.binderType binder==C.expressionType initializer,
    C.expressionType body==C.expressionType initializer,
    C.expressionType expression==C.expressionType initializer -> initializer
  -- A projection of an already checked structural value is total and pure.
  -- Do not generalize this to arbitrary unused initializers or nominal reads.
  C.Let binder initializer body | C.Project tag _ selected <- C.expressionNode initializer,
    C.Local{} <- C.expressionNode selected,tag `S.member` structuralConstructors context,
    C.binderType binder==C.expressionType initializer,
    uses (C.binderId binder) body==0,C.expressionType expression==C.expressionType body -> body
  C.Let binder value body | C.Match selected branches <- C.expressionNode body,
    C.Local identity <- C.expressionNode selected,identity==C.binderId binder,
    uses identity body==1,C.expressionType expression==C.expressionType body ->
      expression{C.expressionNode=C.Match value branches}
  C.Let{} | Just made <- record expression -> made
  _ -> expression
  where
    record outer = gather [] outer
      where
        gather entries current = case C.expressionNode current of
          C.Let binder value body
            | all (\(earlier,_) -> uses (C.binderId earlier) value==0) entries -> gather (entries++[(binder,value)]) body
          C.Construct tag arguments
            | length entries==length arguments,
              and [C.expressionNode argument==C.Local (C.binderId binder) &&
                   C.expressionType argument==C.binderType binder && uses (C.binderId binder) current==1
                  | ((binder,_),argument) <- zip entries arguments],
              C.expressionType outer==C.expressionType current ->
                Just outer{C.expressionNode=C.Construct tag (map snd entries)}
          _ -> Nothing

uses :: C.Id -> C.Expr -> Int
uses identity expression = length (filter (==identity) (C.freeBinders expression)) + sum
  [length (filter (==identity) (typeIds ty)) | term <- walk expression,ty <- types term]
  where
    walk term=term:concatMap walk (C.children term)
    types term=C.expressionType term:case C.expressionNode term of
      C.Let binder _ _ -> [C.binderType binder]
      C.Match _ branches -> [C.binderType binder | branch<-branches,binder<-C.caseBinders branch]
      C.AllElements _ binder _ -> [C.binderType binder]
      C.AllPayloads _ predicates -> map (C.binderType . fst) predicates
      _ -> []
    typeIds (C.TypeVariable name)=[name]
    typeIds (C.Arrow a b)=typeIds a++typeIds b
    typeIds (C.Constructor _ arguments)=concatMap argumentIds arguments
    argumentIds (C.TypeArgument ty)=typeIds ty
    argumentIds (C.IndexArgument (C.IndexVariable name))=[name]
    argumentIds _=[]

normalizedProgram :: Bool -> Bool -> [(C.Id,String)] -> C.Program -> Either String C.Program
normalizedProgram canonical bodyOnly names program = do
  unless (S.size (S.fromList (M.elems targets))==M.size targets)
    (Left "migration normalization collides law identities")
  project context program
  where
    properties=[(C.propertyId property,C.propertyName property) | unit<-C.programUnits program,property<-C.unitProperties unit,
      ("::law::" ++ C.propertyName property) `isSuffixOf` C.idText (C.propertyId property)]
    targets=M.fromList [(identity,target identity name) | (identity,name)<-names++properties]
    target identity name
      | semanticName canonical name==name = identity
      | name `isSuffixOf` C.idText identity = C.Id (owner identity name++semanticName canonical name)
      | otherwise = identity
    owner identity name=take (length (C.idText identity)-length name) (C.idText identity)
    traces=M.fromList [(name,semanticName canonical name) | (_,name)<-names++properties]
    context=Context canonical bodyOnly targets M.empty traces (C.Id "program") 0 False Right Right
      (S.fromList [C.constructorId constructor | declaration<-C.programDataDeclarations program,
        C.dataStructural declaration/=Nothing,constructor<-C.dataConstructors declaration]) Right

-- | Traverse the complete typed representation without normalization, alpha
-- renaming, origin erasure or execution. Only the supplied checked transport
-- rules change terms. The resulting copy must pass ordinary Core validation.
transformProgram :: M.Map C.Id C.Id -> (C.Expr -> Either String C.Expr)
  -> (C.DataDeclaration -> Either String C.DataDeclaration) -> C.Program -> Either String C.Program
transformProgram names expressions declarations = transformProgramWithTypes names Right expressions declarations

transformProgramWithTypes :: M.Map C.Id C.Id -> (C.Type -> Either String C.Type)
  -> (C.Expr -> Either String C.Expr) -> (C.DataDeclaration -> Either String C.DataDeclaration)
  -> C.Program -> Either String C.Program
transformProgramWithTypes names types expressions declarations = project
  (Context False False names M.empty M.empty (C.Id "transport") 0 True expressions declarations S.empty types)

migrationSnapshot :: Bool -> [(C.Id,String)] -> C.Program -> Either String Value
migrationSnapshot canonical names program = do
  full <- normalizedProgram canonical False names program
  bodies <- normalizedProgram canonical True names program
  definitions <- normalizedProgram canonical False names program{C.programUnits=
    [unit{C.unitProperties=[]} | unit<-C.programUnits program]}
  let fingerprint value=digestHex (digest (BL.toStrict (encode (("core-migration-v1"::String),value))))
  pure (object
    [ "version" .= (1::Int),"algorithm" .= ("sha256"::String)
    , "scope" .= ("checked concrete Core; source templates and native binding correspondence remain separate"::String)
    , "machineBits" .= C.programMachineBits program
    , "programDigest" .= fingerprint full
    , "definitionPlaneDigest" .= fingerprint definitions
    , "lawBodiesDigest" .= fingerprint bodies
    , "definitions" .= [part (C.declarationId (C.definitionDeclaration definition)) definition |
        unit<-C.programUnits full,definition<-C.unitDefinitions unit]
    , "contracts" .= [part (C.contractDeclaration contract) contract |
        unit<-C.programUnits full,contract<-C.unitContracts unit]
    , "dataTypes" .= [part (C.dataId declaration) declaration | declaration<-C.programDataDeclarations full]
    , "domainPolicies" .= [object ["comparisonId" .= C.idText (C.propertyId property),"policy" .= C.propertyInputDomain property] |
        unit<-C.programUnits full,property<-C.unitProperties unit]
    ])
  where
    part identity value=object ["comparisonId" .= C.idText identity,
      "digest" .= digestHex (digest (BL.toStrict (encode (("core-migration-part-v1"::String),value))))]
