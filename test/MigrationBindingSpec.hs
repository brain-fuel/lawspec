module MigrationBindingSpec (test_migrationBindings) where

import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Common (Source(..))
import LawSpec.NativeRequest (NativeRequest)
import LawSpec.MigrationBindings (nativeRequestView)

field key (Object fields)=KM.lookup key fields
field _ _=Nothing

test_migrationBindings = describe "compiler-owned native binding migration" $ do
  it "round trips every native request field without erasing external dependencies" $ do
    let input=object
          ["types" .= [object ["type" .= ("sample::type::Box"::String),"native" .= (["app","Box"]::[String]),
            "constructors" .= [object ["constructor" .= ("Box"::String),"native" .= (["app","Box"]::[String]),
              "style" .= ("record"::String),"fields" .= [object ["field" .= ("value"::String),"native" .= ("stored"::String)]]]],
            "arguments" .= (["kotlin.Int"]::[String])],
            object ["type" .= ("sample::type::Other"::String),"native" .= (["app","Other"]::[String]),
              "codec" .= object ["toNative" .= (["app","encode"]::[String]),"fromNative" .= (["app","decode"]::[String])]]]
          ,"generators" .= [object ["type" .= ("Bool"::String),"factory" .= (["app","flags"]::[String]),"stub" .= True]]
          ,"functions" .= [object ["declaration" .= ("sample::copy"::String),"native" .= (["app","copy"]::[String])],
            object ["declaration" .= ("sample::read"::String),"method" .= ("read"::String)],
            object ["declaration" .= ("sample::make"::String),"constructor" .= (["app","Box"]::[String])]]
          ,"names" .= [object ["declaration" .= ("sample::copy"::String),"name" .= ("copyValue"::String)]]
          ,"rustCrate" .= ("application"::String),"goImports" .= [object ["alias" .= ("app"::String),"path" .= ("example/app"::String)]]
          ,"erlangIncludes" .= [object ["path" .= ("app/include/box.hrl"::String),"library" .= True]]
          ,"handlers" .= [object ["ability" .= ("sample::Gateway"::String),"native" .= (["app","Gateway"]::[String])]]
          ,"failures" .= [object ["failure" .= ("sample::Failure::Invalid"::String),"native" .= (["app","Invalid"]::[String])]]
          ,"network" .= object ["identity" .= ("identity.seed"::String),"trusted" .= ("trusted.txt"::String)]]
    request<-case fromJSON input :: Result NativeRequest of Error message->fail message;Success value->pure value
    fromJSON (nativeRequestView request) `shouldBe` Success request
  it "distinguishes native configuration matching from assumed external execution" $ do
    let source content=[Source "native.lawspec" ("unit native\n"++content++"\ncopy :: Flag -> Flag")]
        original=object ["types" .= [object ["type" .= ("native::type::Flag"::String),"native" .= (["app","Flag"]::[String]),
          "constructors" .= [object ["constructor" .= ("FlagValue"::String),"native" .= (["app","FlagValue"]::[String]),
            "style" .= ("variant"::String),"fields" .= [object ["field" .= ("flag"::String),"native" .= ("stored"::String)]]]]]],
          "functions" .= [object ["declaration" .= ("native::copy"::String),"native" .= (["app","copy"]::[String])]]]
        request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
          "verification" .= object ["layers" .= ([]::[String])],"method" .= ("migrationBindings"::String),"from" .= ("0.24"::String),
          "nativeBindings" .= original,"sources" .= source "type Flag is FlagValue flag :: Bool end",
          "migrated" .= object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
            "sources" .= source "type Flag is one of FlagValue of type Bool end type"]]
    result<-either fail pure (eitherDecode (dispatch (encode request)) :: Either String Value)
    field "diagnostics" result `shouldBe` Just (Array mempty)
    let Just proposal=field "migrationBindings" result
    field "status" proposal `shouldBe` Just (String "matched")
    field "nativeConformance" proposal `shouldBe` Just (String "not-established")
    let statuses side=case field "obligations" proposal >>= field side of
          Just (Array rows)->[status | row<-toList rows,Just status<-[field "status" row]]
          _->[]
    statuses "before" `shouldMatchList` [String "runtime-checked",String "assumed"]
    statuses "after" `shouldBe` statuses "before"
  it "checks complete structural paths independently of native argument order" $ do
    let source="unit native\ntype Parcel is one of Packed of type record{last :: Bool first :: Bool} end type"
        mapped fields=object ["types" .= [object ["type" .= ("native::type::Parcel"::String),
          "native" .= (["app","Parcel"]::[String]),"constructors" .= [object [
            "constructor" .= ("Packed"::String),"native" .= (["app","Packed"]::[String]),
            "style" .= ("variant"::String),"fields" .= fields]]]]]
        entry path position=object ["field" .= ("value"::String),"native" .= (if path=="last" then "tail" else "head"::String),
          "path" .= ([path]::[String]),"argument" .= (position::Int)]
        request content fields=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
          "verification" .= object ["layers" .= ([]::[String])],"method" .= ("check"::String),
          "sources" .= [Source "native.lawspec" content],"nativeBindings" .= mapped fields]
        run content fields=either fail pure (eitherDecode (dispatch (encode (request content fields))) :: Either String Value)
    accepted<-run source [entry "first" 1,entry "last" 0]
    field "diagnostics" accepted `shouldBe` Just (Array mempty)
    mapM_ (\fields->do
      rejected<-run source fields
      field "diagnostics" rejected `shouldNotBe` Just (Array mempty))
      [[entry "first" 0],[entry "first" 0,entry "last" 0],
       [entry "first" 0,entry "last" 2],[entry "first" 0,entry "unknown" 1],
       [entry "first" 0,object ["field" .= ("value"::String),"native" .= ("whole"::String)]]]
    nominal<-run "unit native\ntype Details is a record{first :: Bool last :: Bool} end type\ntype Parcel is one of Packed of type Details end type"
      [entry "first" 1,entry "last" 0]
    field "diagnostics" nominal `shouldNotBe` Just (Array mempty)
  it "requires an explicit legacy profile and does not become a permissive check method" $ do
    let request=object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),
          "method" .= ("migrationBindings"::String),"sources" .= [Source "native.lawspec" "unit native"],
          "migrated" .= object ["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.1"::String),"sources" .= [Source "native.lawspec" "unit native"]]]
    result<-either fail pure (eitherDecode (dispatch (encode request)) :: Either String Value)
    field "diagnostics" result `shouldNotBe` Just (Array mempty)
    field "migrationBindings" result `shouldBe` Nothing
