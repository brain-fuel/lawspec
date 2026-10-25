-- | The same checked Java cases can have JUnit wrappers or a plain callable
-- API for another JVM runner. This affects emission, never logical planning.
-- ref:DEC-native-property-frameworks ref:DEC-clojure-over-java
module LawSpec.JavaTestStyle where

data TestStyle = JUnit | SpockCases | PlainCases deriving (Eq, Ord, Show)

propertyPackage :: TestStyle -> String
propertyPackage SpockCases = "org.jetbrains.jetCheck"
propertyPackage JUnit = "org.jetbrains.jetCheck"
propertyPackage PlainCases = "lawspec.testing.check"
