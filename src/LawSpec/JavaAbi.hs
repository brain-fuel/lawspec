-- | Checked Java-facing signatures and test identities. JVM-backed targets
-- consume these descriptions directly; generated Java is never an input.
-- ref:DEC-readable-output-default ref:DEC-clojure-over-java
module LawSpec.JavaAbi where

import Data.Binary (Binary)
import GHC.Generics (Generic)
import qualified LawSpec.Code.Doc as D

-- | An adapter class and the signatures the native emitter actually exposes.
data Stub = Stub
  { stubPackage :: String, stubImports :: [String], stubClass :: String
  , stubItems :: [Item] }
  deriving (Eq, Show, Generic)

data Item
  = Function { itemComments :: [String], itemOperation :: Operation }
  | Handler { itemComments :: [String], handlerClass :: String, handlerInterface :: String
            , handlerResource :: Bool, handlerResourceLayout :: Maybe D.Doc, handlerOperations :: [Operation] }
  deriving (Eq, Show, Generic)

-- | Types are Java ABI names supplied by the checked emitter, not parsed
-- declarations. Labels and parameter names remain presentation metadata.
data Operation = Operation
  { opResult :: String, opName :: String, opParameters :: [(String, String)], opLabel :: String
  , opResultLayout :: D.Doc, opParameterLayouts :: [(D.Doc, String)] }
  deriving (Eq, Show, Generic)

-- | Preserve native type layout and its ABI spelling together. Rendering a
-- descriptor does not need to parse a previously rendered Java type.
operation :: D.Doc -> String -> [(D.Doc, String)] -> String -> Operation
operation result name parameters label = Operation
  (D.render D.Compact result) name [(D.render D.Compact ty, parameter) | (ty, parameter) <- parameters] label
  result parameters

-- Used only by the legacy adapter reader until its callers consume products.
plainOperation :: String -> String -> [(String, String)] -> String -> Operation
plainOperation result name parameters = operation (D.text result) name [(D.text ty, parameter) | (ty, parameter) <- parameters]

data InterfaceAbi = InterfaceAbi
  { interfaceName :: String, interfaceOperations :: [Operation] }
  deriving (Eq, Show, Generic)

-- | One metadata entry represents either one test or an ordered finite source.
-- The latter is registered by the target runner, with one test per case.
data CaseKind
  = SingleCase
  | FiniteCases { finiteSource :: String, finiteAction :: String, finiteCount :: Integer }
  deriving (Eq, Show, Generic)

data CaseInfo = CaseInfo
  { caseName :: String, caseMethod :: String, caseSkip :: Maybe String
  , caseOwner :: Maybe String, caseKind :: CaseKind }
  deriving (Eq, Show, Generic)

data CaseClass = CaseClass
  { casePath :: String, casePackage :: String, caseClass :: String
  , caseUnit :: Maybe String, caseTests :: [CaseInfo]
  , caseOrderRandom :: Bool, caseParallel :: Bool }
  deriving (Eq, Show, Generic)

instance Binary Stub
instance Binary Item
instance Binary Operation
instance Binary InterfaceAbi
instance Binary CaseKind
instance Binary CaseInfo
instance Binary CaseClass
