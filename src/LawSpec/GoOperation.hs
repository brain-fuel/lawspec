-- | A structured plan for calling a native Go handler. Both dynamic and typed
-- bodies render the same plan; an emission cache keys the plan, never a closure.
-- ref:DEC-content-identity ref:DEC-typed-native-definitions
module LawSpec.GoOperation (GoOperationPlan, planGoOperation, operationDoc) where

import Data.Binary (Binary)
import GHC.Generics (Generic)
import Data.Char (toUpper)
import LawSpec.Core
import qualified LawSpec.GoData as Native
import qualified LawSpec.GoExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.AbilityNames (interfaceName)

data GoOperationPlan = GoOperationPlan
  { handlerCall :: String
  , argumentCodecs :: [String]
  , resultCodec :: String
  , unitResult :: Bool
  , machineBits :: Int
  , schemaName :: String
  , failureCodec :: Maybe (String,String,String)
  } deriving (Eq,Show,Generic)

instance Binary GoOperationPlan

planGoOperation :: Int -> [DataDeclaration] -> [Unit] -> String -> Expr -> Either String GoOperationPlan
planGoOperation bits declarations units schema term = case expressionNode term of
  Perform op arguments -> do
    codecs <- mapM (Native.goCodecWithContext "symbols" declarations . expressionType) arguments
    result <- Native.goCodecWithContext "symbols" declarations (expressionType term)
    failure <- case findAbility units (operationAbility op) >>= lookup (operationName op) . abilityFailures . snd of
      Just failing@(AbilityRef _ [ty]) -> do
        codec <- Native.goCodecWithContext "symbols" declarations ty
        native <- Native.goDataType declarations ty
        pure (Just (abilityKey failing,codec,native))
      _ -> pure Nothing
    let handler = "lsHandler(symbols, " ++ show (abilityKey (operationAbility op)) ++ ").(" ++
          maybe "any" (interfaceName . snd) (findAbility units (operationAbility op)) ++ ")." ++ capitalize (operationName op)
    pure (GoOperationPlan handler codecs result (expressionType term == Constructor "Unit" []) bits schema failure)
  _ -> Left "not an operation"
  where
    capitalize (c:cs) = toUpper c:cs
    capitalize [] = []

operationDoc :: GoOperationPlan -> [D.Doc] -> D.Doc
operationDoc plan values = case failureCodec plan of
  Just (key,codec,native) -> E.call "lsNativeFailures" [E.quoted key,
    line "func(native any) LawSpecValue " <> D.block 8 (D.joinWith D.hardline
      (E.declare [("schema",line (schemaName plan),True),("bits",line (show (machineBits plan)),True)]
       [line ("return " ++ codec ++ ".fromNative(native.(" ++ native ++ "))")])),
    line "func() LawSpecValue " <> D.block 8 (line "return " <> performed)]
  Nothing -> performed
  where
    line = D.text
    call = E.call (handlerCall plan)
      [E.call ("codec" ++ show index ++ ".toNative") [value] | (index,value) <- zip [0::Int ..] values]
    result
      | unitResult plan = line "func() LawSpecValue " <> D.block 8
          (call <> D.hardline <> line "return resultCodec.fromNative(LawSpecUnit{})") <> line "()"
      | otherwise = E.call "resultCodec.fromNative" [call]
    performed = line "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
      (E.declare ([("schema",line (schemaName plan),True),("bits",line (show (machineBits plan)),True)] ++
        [("codec" ++ show index,line codec,True) | (index,codec) <- zip [0::Int ..] (argumentCodecs plan)] ++
        [("resultCodec",line (resultCodec plan),True)]) [line "return " <> result])) <> line "()"
