-- | Checked finite-cover data shared by Java, Kotlin and Scala emitters.
-- Target callbacks supply syntax, while the runtime preserves the planner's
-- ordering and creates values in each invocation's fresh symbol context.
-- ref:DEC-planned-generation
module LawSpec.JvmCases (coverDoc) where

import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Core.Value as V
import LawSpec.Common (Diagnostic)
import qualified LawSpec.Testing.Cover as C

coverDoc :: (String -> [D.Doc] -> D.Doc) -> (D.Doc -> D.Doc)
  -> (V.Value -> Either [Diagnostic] D.Doc) -> C.FiniteCover
  -> Either [Diagnostic] D.Doc
coverDoc call factory literal = cover
  where
    runtime name = call ("LawSpecRuntime." ++ name)
    string = D.text . show
    cover (C.Complete count) = pure (runtime "finiteEnd" [D.text (show count)])
    cover (C.Alternatives alternatives) = runtime "finiteChoices" <$> mapM branch alternatives
    branch (values, suffix) = do
      domain <- case values of
        C.Values items -> runtime "finiteValues" . map factory <$> mapM literal items
        C.IntegerInterval name first last' -> pure (runtime "finiteRange"
          [string name, string (show first), string (show last')])
      rest <- cover suffix
      pure (runtime "finiteBranch" [domain, rest])
