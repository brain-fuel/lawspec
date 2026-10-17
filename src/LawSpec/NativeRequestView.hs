-- | Documentary native request JSON, shared after typed resolution.
module LawSpec.NativeRequestView (nativeRequestView) where

import Data.Aeson (Value,object,(.=))
import qualified LawSpec.Core as C
import LawSpec.NativeBinding
import LawSpec.NativeRequest

fieldView field=object (["field" .= boundField field,"native" .= nativeField field]++case field of
  FieldBinding{}->[]
  NestedFieldBinding{..}->["path" .= nestedFieldPath,"argument" .= fieldArgument])

nativeRequestView :: NativeRequest -> Value
nativeRequestView request=object
  (["types" .= map typeView (typeBindings (requestBindings request)),
    "generators" .= map generatorView (generatorBindings (requestBindings request)),
    "functions" .= map functionView (requestFunctions request),
    "goImports" .= [object ["alias" .= goImportAlias item,"path" .= goImportPath item] | item<-requestGoImports request],
    "erlangIncludes" .= [object ["path" .= erlangIncludePath item,"library" .= erlangIncludeLibrary item] | item<-requestErlangIncludes request],
    "handlers" .= [object ["ability" .= boundAbility item,"native" .= referenceParts (boundNative item)] | item<-requestHandlers request],
    "failures" .= [object ["failure" .= mappedFailure item,"native" .= referenceParts (mappedNative item)] | item<-requestFailures request],
    "names" .= [object ["declaration" .= C.idText (nameDeclaration item),"name" .= nameOverride item] | item<-requestNames request]] ++
    ["rustCrate" .= name | Just name<-[requestRustCrate request]]++
    ["network" .= object (["identity" .= name | Just name<-[networkIdentity item]]++
      ["trusted" .= name | Just name<-[networkTrusted item]]) | Just item<-[requestNetwork request]])
  where
    typeView item=object (["type" .= C.idText (boundType item),"native" .= referenceParts (nativeType item),
      "constructors" .= [object ["constructor" .= boundConstructor constructor,
        "native" .= referenceParts (nativeConstructor constructor),"style" .= style (constructorStyle constructor),
        "fields" .= map fieldView (boundFields constructor)] | constructor<-boundConstructors item]]++
      ["codec" .= object ["toNative" .= referenceParts (codecToNative codec),"fromNative" .= referenceParts (codecFromNative codec)] | Just codec<-[boundCodec item]]++
      ["arguments" .= arguments | Just arguments<-[boundArguments item]])
    generatorView item=object ["type" .= C.idText (generatorType item),"factory" .= referenceParts (generatorFactory item),"stub" .= generatorStub item]
    functionView item=object (["declaration" .= C.idText (functionDeclaration item)]++case functionNative item of
      StaticCall ref->["native" .= referenceParts ref]
      MethodCall name->["method" .= name]
      ConstructorCall ref->["constructor" .= referenceParts ref])
    style RecordConstructor="record"::String
    style VariantConstructor="variant"
    style UnitConstructor="unit"
