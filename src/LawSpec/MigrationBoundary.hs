-- | Compare native call contracts from resolved Core and bindings. These are
-- conditional boundary facts, not proofs about external implementations.
module LawSpec.MigrationBoundary (boundaryReceipt) where

import Control.Monad (forM)
import Data.Aeson (Value(..),ToJSON,object,(.=),encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (find,nub,sortOn)
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Types (typeVariables,freeExistentials)
import LawSpec.Digest (digest,digestHex)
import LawSpec.NativeRequestView (nativeRequestView)
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import LawSpec.RustData (rustFieldBoxed)

boundaryReceipt :: String -> C.Program -> C.Program -> NativeRequest -> Maybe NativeRequest -> Value
boundaryReceipt target before after original proposed = object
  ["version" .= (1::Int),"algorithm" .= ("sha256"::String),
   "policy" .= ("resolved-native-contract-v1"::String),
   "status" .= (if matched then "matched" else "not-established"::String),
   "scope" .= ("resolved native constructors, ordered fields, calls, handlers and unbound adapter layouts; logical semantics are separate"::String),
   "before" .= view old,"after" .= view new,
   "nativeConformance" .= ("not-established"::String),
   "lawVerification" .= ("not-established-by-boundary-correspondence"::String),
   "assumptions" .= (["existing compiler emitters","unchanged native implementations under their original binding assumptions"]::[String])]
  where
    old=contract before original
    new=maybe (Left "A complete checked destination binding proposal is required.") (contract after) proposed
    matched=case (old,new) of (Right a,Right b)->a==b;_->False
    fingerprint :: ToJSON a => a -> String
    fingerprint=digestHex . digest . BL.toStrict . encode
    view (Left reason)=object ["status" .= ("unavailable"::String),"reason" .= reason]
    view (Right value)=object ["status" .= ("available"::String),"contract" .= value,"digest" .= fingerprint value]
    contract program request = do
      plan<-resolveNativeRequest program request
      let normalized=normalizedNativeRequest request plan
          catalogue=C.programDataDeclarations program
          mappings=resolvedTypes (bindingRepresentations plan)
          allCalls=[(declaration,StaticCall reference) | (declaration,reference)<-bindingFunctions plan]++bindingCalls plan
          declarations=[declaration | unit<-C.programUnits program,declaration<-C.unitDeclarations unit,
            C.declarationId declaration `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)]
          unbound=[declaration | declaration<-declarations,C.declarationId declaration `notElem` map (C.declarationId . fst) allCalls]
          declarationTypes declaration=C.declarationType declaration:concatMap C.abilityRefArguments (C.declarationUses declaration)
          roots=concatMap (concatMap typeNames . declarationTypes) unbound
          mapped=Set.fromList (map (C.dataId . resolvedDeclaration) mappings)
          reachable stop seen []=seen
          reachable stop seen (identity:rest) | identity `Set.member` seen || identity `Set.member` stop=reachable stop seen rest
            | otherwise=reachable stop (Set.insert identity seen) (rest++concat
                [typeNames (C.binderType field) | declaration<-catalogue,C.dataId declaration==identity,
                  constructor<-C.dataConstructors declaration,field<-C.constructorFields constructor])
      types<-forM (sortOn (C.dataId . resolvedDeclaration) mappings) $ \binding -> do
        let declaration=resolvedDeclaration binding
        constructors<-forM (resolvedConstructors binding) $ \constructor -> do
          let logical=resolvedConstructor constructor
              scope=C.dataParameters declaration++C.constructorExistentials logical
          fields<-forM (resolvedFields constructor) $ \(field,native) -> do
            ty<-typeView scope (C.binderType field)
            pure (object (["native" .= native,"type" .= ty]++
              ["boxed" .= rustFieldBoxed catalogue (C.dataId declaration) (C.binderType field) | target=="rust"]))
          pure (object ["constructor" .= C.idText (C.constructorId logical),
            "native" .= referenceParts (resolvedNativeConstructor constructor),
            "style" .= style (resolvedConstructorStyle constructor),"fields" .= fields,
            "existentials" .= length (C.constructorExistentials logical),
            "witnesses" .= length (freeExistentials declaration logical)])
        pure (object ["type" .= C.idText (C.dataId declaration),"native" .= referenceParts (resolvedNativeType binding),
          "parameters" .= length (C.dataParameters declaration),"handle" .= C.dataHandle declaration,
          "arguments" .= resolvedArguments binding,"constructors" .= constructors,
          "codec" .= fmap (\codec -> object ["toNative" .= referenceParts (codecToNative codec),
            "fromNative" .= referenceParts (codecFromNative codec)]) (resolvedCodec binding)])
      calls<-mapM (callView . fst) (sortOn (C.declarationId . fst) allCalls)
      adapters<-mapM callView (sortOn C.declarationId unbound)
      handlers<-forM (sortOn fst (bindingHandlers plan)) $ \(identity,_) -> do
        ability<-maybe (Left ("missing native handler operations: "++C.idText identity)) Right
          (find ((== C.idText identity) . C.abilityKey . C.abilityInstance)
            [ability | unit<-C.programUnits program,ability<-C.unitAbilities unit])
        operations<-forM (C.abilityOperations ability) $ \(name,ty) -> do
          value<-typeView (nub (typeVariables ty)) ty
          pure (object ["name" .= name,"type" .= value])
        pure (object ["ability" .= C.idText identity,"operations" .= operations])
      let nativeRoots=concatMap (concatMap typeNames . declarationTypes . fst) allCalls++
            concat [typeNames (C.binderType field) | mapping<-mappings,constructor<-resolvedConstructors mapping,(field,_)<-resolvedFields constructor]++
            concat [typeNames ty | (identity,_)<-bindingHandlers plan,unit<-C.programUnits program,ability<-C.unitAbilities unit,
              C.abilityKey (C.abilityInstance ability)==C.idText identity,(_,ty)<-C.abilityOperations ability]
          nativeReach=reachable mapped Set.empty nativeRoots
          adapterReach=reachable (if target `elem` ["fsharp","swift"] then mapped else Set.empty) Set.empty roots
      canonical<-forM (sortOn C.dataId [declaration | declaration<-catalogue,
        C.dataId declaration `Set.member` Set.union nativeReach adapterReach]) $ \declaration -> do
          constructors<-forM (C.dataConstructors declaration) $ \constructor -> do
            fields<-forM (C.constructorFields constructor) $ \field -> do
              value<-typeView (C.dataParameters declaration++C.constructorExistentials constructor) (C.binderType field)
              pure (object ["name" .= C.binderName field,"type" .= value])
            pure (object ["constructor" .= C.idText (C.constructorId constructor),"fields" .= fields,
              "existentials" .= length (C.constructorExistentials constructor),
              "witnesses" .= length (freeExistentials declaration constructor)])
          pure (object ["type" .= C.idText (C.dataId declaration),"parameters" .= length (C.dataParameters declaration),
            "handle" .= C.dataHandle declaration,"constructors" .= constructors])
      pure (object ["configuration" .= nativeRequestView normalized{requestBindings=(requestBindings normalized){typeBindings=[]}},
        "types" .= types,"calls" .= calls,"handlers" .= handlers,"unboundAdapters" .= adapters,
        "unmappedData" .= canonical])

callView :: C.Declaration -> Either String Value
callView declaration = do
  let uses=C.declarationUses declaration
      scope=nub (typeVariables (C.declarationType declaration)++concatMap (concatMap typeVariables . C.abilityRefArguments) uses)
  ty<-typeView scope (C.declarationType declaration)
  abilities<-forM uses $ \ability -> do
    arguments<-mapM (typeView scope) (C.abilityRefArguments ability)
    pure (object ["ability" .= C.idText (C.abilityRefId ability),"arguments" .= arguments])
  pure (object ["declaration" .= C.idText (C.declarationId declaration),"type" .= ty,
    "async" .= C.declarationAsync declaration,"uses" .= abilities])

-- Runtime representation only: value indices are erased, while their logical
-- meaning and all predicates remain in the separate full-Core comparison.
typeView :: [C.Id] -> C.Type -> Either String Value
typeView scope ty=case ty of
  C.TypeVariable identity -> maybe (Left ("unbound native contract parameter: "++C.idText identity))
    (\index -> Right (object ["parameter" .= index])) (lookup identity (zip scope [0::Int ..]))
  C.Arrow a b -> do
    left<-typeView scope a
    right<-typeView scope b
    pure (object ["arrow" .= [left,right]])
  C.Constructor name arguments -> do
    values<-forM arguments $ \argument -> case argument of
      C.TypeArgument value -> typeView scope value
      C.IndexArgument _ -> pure (object ["erasedIndex" .= True])
    pure (object ["name" .= name,"arguments" .= values])

typeNames :: C.Type -> [C.Id]
typeNames (C.TypeVariable _) = []
typeNames (C.Arrow a b)=typeNames a++typeNames b
typeNames (C.Constructor name arguments)=C.Id name:concat [typeNames ty | C.TypeArgument ty<-arguments]

style :: ConstructorStyle -> String
style RecordConstructor="record"
style VariantConstructor="variant"
style UnitConstructor="unit"
