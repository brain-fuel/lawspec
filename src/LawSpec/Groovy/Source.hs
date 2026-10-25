-- | Groovy adapter declarations from the checked JVM ABI. Signatures retain
-- their structured type layout; Java source is never an input.
-- ref:DEC-groovy-over-java ref:DEC-readable-output-default
module LawSpec.Groovy.Source (adapterStub) where

import Data.List (stripPrefix)
import qualified LawSpec.JavaAbi as A
import qualified LawSpec.Code.Doc as D
import LawSpec.JvmNames (jvmString)

adapterStub :: A.Stub -> String
adapterStub stub = D.render (D.Pretty 100) $
  D.text "// User-owned LawSpec adapter." <> D.hardline <> D.hardline <>
  (if null (A.stubPackage stub) then mempty else D.text ("package " ++ A.stubPackage stub) <> D.hardline <> D.hardline) <>
  D.text "@groovy.transform.CompileStatic" <> D.hardline <>
  D.text ("final class " ++ A.stubClass stub) <> D.hardline <>
  D.block 2 (D.joinWith (D.hardline <> D.hardline) (map item (A.stubItems stub))) <> D.hardline
  where
    item value = comments (A.itemComments value) <> case value of
      A.Function _ operation -> method "static " operation
      A.Handler _ name interface resource resourceLayout operations ->
        D.text ("static final class " ++ name ++ " implements " ++ interface) <> D.hardline <>
        D.block 2 (D.joinWith (D.hardline <> D.hardline)
          (concat [[D.group (D.text "private final " <> ty <> D.text " resource"),
            D.group (D.text (name ++ "(") <> ty <> D.text " resource)") <> D.hardline <>
              D.block 2 (D.text "this.resource = resource")] | resource, let ty = maybe (D.text "Object") typeLayout resourceLayout] ++
           map (method "") operations))
    comments = mconcat . map (D.lineComment 98 "// " . maybeComment)
    maybeComment text = maybe text id (stripPrefix "// " text)
    method modifiers operation =
      D.group (D.text modifiers <> typeLayout (A.opResultLayout operation) <>
        D.nest 4 (D.softline <> D.group (D.text (A.opName operation ++ "(") <>
          D.nest 4 (D.softbreak <> D.group (D.commaSep
            [D.group (typeLayout ty <> D.softline <> D.text parameter) | (ty, parameter) <- A.opParameterLayouts operation])) <> D.text ")"))) <>
      D.hardline <> D.block 2
        (D.group (D.text "throw new UnsupportedOperationException(" <>
          D.nest 4 (D.softbreak <> jvmString "groovy" (A.opLabel operation)) <> D.text ")"))

-- Type-name atoms are supplied by the ABI producer, rather than recovered
-- from Java tokens. Groovy's joint compiler needs nested runtime owners in
-- full; java.lang types use their ordinary implicit import.
typeLayout :: D.Doc -> D.Doc
typeLayout = D.mapText qualify
  where
    qualify atom
      | Just rest <- stripPrefix "java.lang." atom = rest
      | Just rest <- stripPrefix "LawSpecRuntime." atom = "lawspec.runtime.LawSpecRuntime." ++ rest
      | atom == "Value" = "lawspec.runtime.LawSpecRuntime.Value"
      | otherwise = atom
