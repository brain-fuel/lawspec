-- | One shared Java generator implementation with an explicitly selected
-- framework import prelude. No emitted Java is inspected or rewritten.
-- ref:DEC-native-property-frameworks ref:DEC-clojure-over-java
module LawSpec.JavaTestingRuntime (dataStrategies, renderDataStrategies) where

import LawSpec.JavaTestStyle (TestStyle, propertyPackage)
import LawSpec.RuntimeSources (runtimeSource)

dataStrategies :: TestStyle -> String
dataStrategies style = renderDataStrategies style (runtimeSource "java-data-strategies-body")

renderDataStrategies :: TestStyle -> String -> String
renderDataStrategies style body = unlines
  ([ "package lawspec.testing;", "" ] ++
   map (\name -> "import " ++ name ++ ";")
     [ "java.util.ArrayList", "java.util.HashMap", "java.util.List", "java.util.Map"
     , "java.util.function.Function", "java.util.function.Predicate"
     , "lawspec.runtime.LawSpecRuntime.Data", "lawspec.runtime.LawSpecRuntime.Presence"
     , "lawspec.runtime.LawSpecRuntime.Value", "lawspec.runtime.LawSpecSchema"
     , "lawspec.runtime.LawSpecSchema.Named"
     , propertyPackage style ++ ".Generator", propertyPackage style ++ ".IntDistribution" ] ++
   [ "" ]) ++ body
