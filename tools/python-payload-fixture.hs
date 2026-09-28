-- Shared native Core payload emission fixture; optional target and builtins flags.
module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.Expression (operationEvidence)
import LawSpec.CoreEmit (emitPlanWithFormat)
import LawSpec.Testing (planTesting)
import LawSpec.Scalar (Scalar(..))

origin = GeneratedFrom (Id "payload")
int = scalarType "Int8"
bool = scalarType "Bool"
app name types = Constructor name (map TypeArgument types)
bind name ty = Binder (Id name) name ty
local b = Expr (binderType b) (Local (binderId b)) origin
literal n = Expr int (Constant (SInteger "Int8" n)) origin
binary op left right = Expr bool
  (Binary op (either error id (operationEvidence op (expressionType left) (expressionType right))) left right) origin
variant owner tag fields = DataConstructor (Id (owner ++ "::" ++ tag)) tag
  [Binder (Id (owner ++ "::" ++ tag ++ "::" ++ name)) name ty | (name,ty) <- fields] [] origin
structure name params cs = DataDeclaration (Id name) name (map Id params) cs origin
function name args result body = Definition
  (Declaration (Id ("payload::" ++ name)) name (foldr Arrow result (map binderType args)) origin) args body
allValues value binder predicate = Expr bool (AllPayloads value [(binder,predicate)]) origin

main = do
  bitsText:compactText:directory:options <- getArgs
  let bits = read bitsText
      ty = app "Tree" [int]
      tree = structure "Tree" ["a"]
        [variant "Tree" "Leaf" [("value",TypeVariable (Id "a")),("fixed",int)],
         variant "Tree" "Node" [("children",app "List" [app "Tree" [TypeVariable (Id "a")]])]]
      member = bind "member" int
      field = bind "Pack::Pack::tree" ty
      pack = structure "Pack" [] [(variant "Pack" "Pack" [("tree",ty)])
        {constructorPredicates=[allValues (local field) member (binary Greater (local member) (literal 0))]}]
      input = bind "input" ty
      threshold = bind "threshold" int
      xs = bind "xs" (app "List" [int])
      packed = bind "packed" (app "Pack" [])
      above = function "above" [input,threshold] bool
        (allValues (local input) member (binary Greater (local member) (local threshold)))
      positive = function "positive" [xs] bool
        (allValues (local xs) member (binary Greater (local member) (literal 0)))
      identity = function "identity" [packed] (binderType packed) (local packed)
      truth = Expr bool (Constant (SBool True)) origin
      payloadTest = binary Greater (local member) (local threshold)
      body = allValues (local xs) member payloadTest
      expected = Expr bool (AllElements (local xs) member payloadTest) origin
      property = Property (Id "payload::law::all") "all" (Location "payload" 1 1)
        [Quantifier xs [] [],Quantifier threshold [] []]
        (Equation (Structural bool) body expected)
        [] defaultGeneration "" "" [] []
      parameter = TypeVariable (Id "a")
      genericField = bind "GenericPack::GenericPack::tree" (app "Tree" [parameter])
      genericMember = bind "genericMember" parameter
      genericPack = structure "GenericPack" ["a"]
        [(variant "GenericPack" "GenericPack" [("tree",binderType genericField)])
          {constructorPredicates=[allValues (local genericField) genericMember truth]}]
      genericInput = bind "genericInput" (app "GenericPack" [int])
      genericIdentity = function "genericIdentity" [genericInput] (binderType genericInput) (local genericInput)
      symbol = scalarType "Symbol"
      symbols = bind "symbolsInput" (app "List" [symbol])
      symbolMember = bind "symbolMember" symbol
      shared = function "shared" [symbols] bool (allValues (local symbols) symbolMember
        (binary Equal (local symbolMember) (Expr symbol (Constant (SSymbol "shared" "description")) origin)))
      definitions = [above,positive,identity,genericIdentity,shared]
      unit = Unit (Id "payload") (map definitionDeclaration definitions) [] [property] definitions
      target = case filter (`elem` ["javascript","typescript","rust","java","kotlin","go","haskell"]) options of
        name:_ -> name
        [] -> "python"
      program = if "builtins" `elem` options
        then Program bits [] [Unit (Id "payload") [] [] [property] []]
        else Program bits [tree,pack,genericPack] [unit]
  plan <- either (fail . show) pure (planTesting program)
  files <- either (fail . show) pure (emitPlanWithFormat (read compactText) target plan)
  mapM_ (\file -> do
    let path = directory </> artifactPath file
    createDirectoryIfMissing True (takeDirectory path)
    writeFile path (artifactContent file)) files
