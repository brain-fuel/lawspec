-- | Recursive representation changes are ordinary checked definitions. Their
-- bodies contain only exhaustive matching, reconstruction and smaller views.
module LawSpec.Core.RecordViewFunctions
  ( viewUnitId, viewId, viewDeclaration, viewArgument, viewSignature, buildViewDefinition ) where

import Control.Monad (unless,zipWithM)
import LawSpec.Core
import qualified LawSpec.Core.Types as Types
import LawSpec.Core.RecordViews (adaptStructuralWith)
import LawSpec.Digest (digestHex,digestString)

viewUnitId :: Id
viewUnitId=Id "lawspecRecordViews"

viewName :: Type -> Type -> String
viewName from to="lawspecRecordView"++digestHex (digestString (show ("checked-record-view-v1"::String,from,to)))

viewId :: Type -> Type -> Id
viewId from to=Id (idText viewUnitId++"::"++viewName from to)

viewDeclaration :: Type -> Type -> Declaration
viewDeclaration from to=Declaration (viewId from to) (viewName from to) (Arrow from to) (GeneratedFrom (viewId from to))

viewArgument :: Type -> Type -> Binder
viewArgument from to=Binder (Id (idText (viewId from to)++"::argument::0")) "value" from

-- Source declarations carry a source association. A private-looking name alone
-- never authorizes erasing a user function or trusting its implementation.
viewSignature :: Definition -> Maybe (Type,Type)
viewSignature definition = case declarationType declaration of
  Arrow from to | declaration==viewDeclaration from to,
    definitionArguments definition==[viewArgument from to],
    not (definitionOrchestrates definition),definitionPolicy definition==Nothing -> Just (from,to)
  _ -> Nothing
  where declaration=definitionDeclaration definition

buildViewDefinition :: Monad m => (Type -> m Type) -> [DataDeclaration]
  -> (Type -> Expr -> m (Either String Expr)) -> Type -> Type -> m (Either String Definition)
buildViewDefinition canonical declarations request from to = do
  original<-canonical from;target<-canonical to
  if original/=target then pure (Left "structural representation types differ") else
    case context of
      Left reason -> pure (Left reason)
      Right (registry,constructors) -> do
        bodies<-mapM (branch registry) (zip [0::Int ..] constructors)
        pure $ do
          branches<-sequence bodies
          pure (Definition (viewDeclaration from to) [argument]
            (Expr to (Match (local argument) branches) origin))
  where
    identity=viewId from to
    origin=GeneratedFrom identity
    argument=viewArgument from to
    local binder=Expr (binderType binder) (Local (binderId binder)) origin
    context=do
      registry<-Types.makeRegistry declarations
      case (from,to) of
        (Constructor parent _,Constructor other _) | parent==other -> do
          declaration<-Types.lookupData registry (Id parent)
          unless (not (dataHandle declaration)) (Left "a structural view cannot reconstruct opaque storage")
          before<-Types.compatibleConstructors registry from
          after<-Types.compatibleConstructors registry to
          unless (map constructorId before==map constructorId after)
            (Left "structural representation changes must preserve accessible constructors")
          pure (registry,before)
        _ -> Left "a recursive structural view requires the same nominal container"
    branch registry (index,constructor) = case do
      fields<-Types.constructorFieldsAt registry from (constructorId constructor) []
      targets<-Types.constructorFieldsAt registry to (constructorId constructor) []
      unless (length fields==length targets) (Left "structural container field arity differs")
      pure (fields,targets) of
        Left reason -> pure (Left reason)
        Right (fields,targets) -> do
          let bound=[Binder (Id (idText identity++"::case::"++show index++"::field::"++show position))
                ("field"++show position) (binderType field) | (position,field)<-zip [0::Int ..] fields]
          results<-zipWithM (\wanted value -> adaptStructuralWith canonical declarations request (binderType wanted) (local value)) targets bound
          pure $ do
            values<-sequence results
            pure (MatchCase (constructorId constructor) bound (Expr to (Construct (constructorId constructor) values) origin))
