-- | Checked finite-cover data shared by Java, Kotlin and Scala emitters.
-- Target callbacks supply syntax, while the runtime preserves the planner's
-- ordering and creates values in each invocation's fresh symbol context.
-- ref:DEC-planned-generation
module LawSpec.JvmCases (coverDoc, coverBindings) where

import qualified Control.Monad.State.Strict as S
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core.Value as V
import LawSpec.Common (Diagnostic)
import qualified LawSpec.Testing.Cover as C

coverDoc :: (String -> [D.Doc] -> D.Doc) -> (D.Doc -> D.Doc)
  -> (V.Value -> Either [Diagnostic] D.Doc) -> C.FiniteCover
  -> Either [Diagnostic] D.Doc
coverDoc call factory literal = cover
  where cover = coverLayer call factory literal cover

-- | Name shared suffixes in dependency order. A cover with many inputs must
-- not become a deeply nested constructor expression in generated source.
-- Materialization remains deferred to each case's fresh symbol context.
coverBindings :: (String -> [D.Doc] -> D.Doc) -> (D.Doc -> D.Doc)
  -> (V.Value -> Either [Diagnostic] D.Doc) -> (String -> D.Doc -> D.Doc)
  -> String -> C.FiniteCover -> Either [Diagnostic] ([D.Doc], D.Doc)
coverBindings call factory literal bind prefix root = do
  (reference, (_, declarations)) <- S.runStateT (cover root) ([], [])
  pure (reverse declarations, reference)
  where
    cover :: C.FiniteCover -> S.StateT ([(C.FiniteCover, String)], [D.Doc]) (Either [Diagnostic]) D.Doc
    cover node = do
      (known, _) <- S.get
      case lookup node known of
        Just name -> pure (D.text name)
        Nothing -> do
          value <- coverLayer call factory (S.lift . literal) cover node
          (known', declarations) <- S.get
          let name = prefix ++ show (length known' + 1)
          S.put ((node, name) : known', bind name value : declarations)
          pure (D.text name)

coverLayer :: Monad m => (String -> [D.Doc] -> D.Doc) -> (D.Doc -> D.Doc)
  -> (V.Value -> m D.Doc) -> (C.FiniteCover -> m D.Doc)
  -> C.FiniteCover -> m D.Doc
coverLayer call factory literal cover node = case node of
  C.Complete count -> pure (runtime "finiteEnd" [D.text (show count)])
  C.Alternatives alternatives -> runtime "finiteChoices" <$> mapM branch alternatives
  where
    runtime name = call ("LawSpecRuntime." ++ name)
    string = D.text . show
    branch (values, suffix) = do
      domain <- case values of
        C.Values items -> runtime "finiteValues" . map factory <$> mapM literal items
        C.IntegerInterval name first last' -> pure (runtime "finiteRange"
          [string name, string (show first), string (show last')])
      rest <- cover suffix
      pure (runtime "finiteBranch" [domain, rest])
