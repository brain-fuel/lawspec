-- | Formatting services operate on compiler types, without an external codec.
-- The JSON adapter and component use the same parsing and rechecking path.
-- ref:DEC-haskell-application-port
module LawSpec.Service.Formatting (FormatResult (..), formatStandalone, formatSyntax, formatCompiled) where

import LawSpec.Common
import LawSpec.Compile (compileWithSourceOrigins, parseSourceSyntaxWithContext)
import qualified LawSpec.Core.Verification as V
import LawSpec.Discharge (bindingEvidence, defaultHandlerEvidence, refutations)
import LawSpec.LawClaims (Expiry (..), analysisEvidence)
import LawSpec.Memo (Table, memoized, newTable)
import LawSpec.NativeRequest (emptyNativeRequest)
import LawSpec.Packages
import LawSpec.Service.Compilation (stagesWithInput)
import LawSpec.SourceSyntax (SourceSyntax (..))
import LawSpec.SourceText (formatSourceWithSyntax, formatSourcesUsing)
import System.IO.Unsafe (unsafePerformIO)

-- | A diagnostic response may retain formatted sources, as the public formatter
-- does for refuted law analysis. File workflows still refuse every write.
data FormatResult = FormatResult
  { formattedSources :: [Source],
    formatDiagnostics :: [Diagnostic]
  }
  deriving (Eq, Show)

-- | The standalone formatter selects no optional law layers. Checked mode still
-- admits definitions, validates law declarations, and rechecks formatted syntax.
formatStandalone :: Bool -> [Source] -> FormatResult
formatStandalone checked sources =
  memoized formatTable (show (checked, sources)) (formatUncached checked sources)

-- | Two pure results per instance. Both checking mode and original source paths
-- and contents participate in the key. File reads and writes stay outside this
-- cache, so a hit never bypasses a fresh read or a write capability check.
formatTable :: Table FormatResult
formatTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE formatTable #-}

-- | Compute a complete result before its external projection. Retaining the
-- small result avoids keeping an additional pair of compiled Core programs.
formatUncached :: Bool -> [Source] -> FormatResult
formatUncached checked sources =
  either (FormatResult []) id $
    if checked
      then do
        ((_, _, core, bindings, (evidence, rows), _, _), syntax) <-
          stagesWithInput True True emptyProject [] sources 64 defaultGeneration emptyNativeRequest (Just V.noVerification)
        analysed <- analysisEvidence False False False (Expiry Nothing Nothing) rows
        formatted <- formatCompiled emptyProject [] sources 64 defaultGeneration syntax
        pure
          ( FormatResult
              formatted
              ( refutations
                  core
                  (evidence ++ map fst analysed ++ bindingEvidence bindings ++ defaultHandlerEvidence core bindings)
              )
          )
      else (`FormatResult` []) <$> formatSourcesUsing (formatSyntax emptyProject []) sources

-- | Available package headers disambiguate arities even while wiring is
-- unfinished; syntax-only formatting must remain usable during editing.
formatSyntax :: Project -> [Package] -> [Source] -> Either [Diagnostic] [SourceSyntax]
formatSyntax project packages sources = case preparePackagesWithOrigins True project packages sources of
  Right (prepared, origins, _, _, _) ->
    let (dependencies, own) = splitAt (length prepared - length sources) prepared
     in parseSourceSyntaxWithContext origins dependencies own
  Left _ -> parseSourceSyntaxWithContext [] (concatMap packageSources packages) sources

-- | Recheck the output using the same package visibility and original source
-- coordinates as checked formatting at the existing API boundary.
formatCompiled :: Project -> [Package] -> [Source] -> Int -> Generation -> [SourceSyntax] -> Either [Diagnostic] [Source]
formatCompiled project packages sources bits settings syntax = do
  let formatted =
        [ formatSourceWithSyntax
            (concat [syntaxNodes item | item <- syntax, syntaxPath item == path source])
            source
        | source <- sources
        ]
  (prepared, origins, visible, referenceUnit, _) <- preparePackagesWithOrigins True project packages formatted
  _ <- compileWithSourceOrigins origins False True referenceUnit visible bits settings prepared
  pure formatted
