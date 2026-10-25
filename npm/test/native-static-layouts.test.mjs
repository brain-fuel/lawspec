// Generated from templates/npm/test/native-static-layouts.test.mjs by lawspec-dev generate. Do not edit.
import {extendUnit} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,mkdir,writeFile,readdir,rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {templates} from '../templates.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]}};
const source=`unit layouts

type Packet (a :: Type) is one of Packed of type record{
  last :: a first :: record{count :: (n :: UInt8 where n > 0) flag :: Bool}
} end type
copy :: Packet UInt8 -> Packet UInt8

end unit
`;
const chainSource=extendUnit(source,`
type Chain is one of | Stop | Link of type record{next :: Chain item :: Bool} end type
copyChain :: Chain -> Chain`);
const bindings={types:[{type:'layouts::type::Packet',native:['application','Packet'],constructors:[
  {constructor:'Packed',native:['application','Packed'],style:'variant',fields:[
    {field:'value',path:['first','count'],argument:2,native:'quantity'},
    {field:'value',path:['last'],argument:0,native:'tail'},
    {field:'value',path:['first','flag'],argument:1,native:'enabled'},
  ]},
]}],functions:[{declaration:'layouts::copy',native:['application','Operations','copy']}]};
const run=(command,args,options={})=>{
  const result=spawnSync(command,args,{encoding:'utf8',maxBuffer:32e6,...options});
  assert.equal(result.status,0,command+' '+args.join(' ')+'\n'+result.stdout+'\n'+result.stderr);
  return result.stdout;
};
const selected=process.env.LAWSPEC_NATIVE_LAYOUT_TARGET;
const required=target=>selected===target||selected==='all';
const available=command=>spawnSync(command,command==='erl'?['-noshell','-eval','halt(0).']:command==='go'?['version']:[command==='kotlinc'?'-version':'--version'],{stdio:'ignore'}).status===0;
async function files(root,extension){
  const found=[];
  for(const item of await readdir(root,{withFileTypes:true})){
    const child=path.join(root,item.name);
    if(item.isDirectory())found.push(...await files(child,extension));
    else if(child.endsWith(extension))found.push(child);
  }
  return found;
}
const jvmBindings=()=>{
  const made=structuredClone(bindings);
  made.types.push({type:'layouts::type::Chain',native:['application','Chain'],constructors:[
    {constructor:'Stop',native:['application','Chain','STOP'],style:'unit',fields:[]},
    {constructor:'Link',native:['application','Link'],style:'variant',fields:[
      {field:'value',path:['next'],argument:0,native:'next'},
      {field:'value',path:['item'],argument:1,native:'flag'},
    ]},
  ]});
  made.functions.push({declaration:'layouts::copyChain',native:['application','Operations','copyChain']});
  return made;
};
const application={
  'application/Chain.java':`package application; public interface Chain { Chain STOP=new Chain(){}; }`,
  'application/Link.java':`package application; public record Link(Chain next,boolean flag) implements Chain {}`,
  'application/Packet.java':`package application; public interface Packet<T> {}`,
  'application/Packed.java':`package application;
public record Packed<T>(T tail, boolean enabled, short quantity) implements Packet<T> {
  public T tail(){Fixture.order.add("tail");return tail;}
  public boolean enabled(){Fixture.order.add("enabled");return enabled;}
  public short quantity(){Fixture.order.add("quantity");return quantity;}
}`,
  'application/Operations.java':`package application;
public final class Operations {
  public static boolean mutate=false;
  public static Chain copyChain(Chain value){return value;}
  public static <T> Packet<T> copy(Packet<T> value){
    var packed=(Packed<T>)value;
    return mutate ? new Packed<>(packed.tail(),packed.enabled(),(short)0) : value;
  }
}`,
  'application/Fixture.java':`package application;
import java.util.*; import java.math.BigInteger; import lawspec.runtime.LawSpecRuntime;
public final class Fixture {
  public static final List<String> order=new ArrayList<>();
  public static void require(boolean value){if(!value)throw new AssertionError("native layout mismatch");}
  public static void orderCorrect(){require(order.equals(List.of("tail","enabled","quantity")));order.clear();}
  public static void inspect(LawSpecRuntime.Value value){
    var payload=(LawSpecRuntime.Data)((LawSpecRuntime.Data)value.data()).fields().get(0).data();
    var nested=(LawSpecRuntime.Data)payload.fields().get(0).data();
    require(nested.fields().get(0).data().equals(BigInteger.valueOf(3)));
    require(nested.fields().get(1).data().equals(true));
    require(payload.fields().get(1).data().equals(BigInteger.valueOf(7)));
  }
  public static void inspectChain(Chain value){
    var link=(Link)value;require(link.flag()&&link.next()==Chain.STOP);
  }
  public static void inspectPacket(Packet<?> value){
    var packed=(Packed<?>)value;
    require(packed.tail().equals((short)7)&&packed.enabled()&&packed.quantity()==3);order.clear();
  }
}`,
};
const javaCheck=bits=>`import application.*; import lawspec.runtime.*;
public class Check {
  public static void main(String[] args){
    var schema=LawSpecDataSchema.create();var symbols=new java.util.HashMap<String,Object>();
    var scalar=schema.scalar("UInt8",${bits},Short.class);
    var nativeCodec=LawSpecNativeCodecs.type0(schema,${bits},symbols,scalar);
    var canonical=LawSpecDataCodecs.packetCodec(schema,${bits},symbols,scalar);
    var logical=nativeCodec.encode(new Packed<Short>((short)7,true,(short)3));
    Fixture.orderCorrect();Fixture.inspect(logical);Fixture.inspectPacket(nativeCodec.decode(logical));
    for(short invalid:new short[]{0,256}){
      try{nativeCodec.encode(new Packed<Short>((short)7,true,invalid));throw new AssertionError("invalid count admitted");}
      catch(IllegalArgumentException expected){}
    }
    Fixture.inspectPacket(nativeCodec.decode(canonical.encode(Layouts.copy(canonical.decode(logical)))));
    Operations.mutate=true;
    try{Layouts.copy(canonical.decode(logical));throw new AssertionError("invalid native result admitted");}
    catch(IllegalArgumentException expected){}
    var chainCodec=LawSpecNativeCodecs.type1(schema,${bits},symbols);
    var canonicalChain=LawSpecDataCodecs.chainCodec(schema,${bits},symbols);
    var chain=chainCodec.encode(new Link(Chain.STOP,true));
    Fixture.inspectChain(chainCodec.decode(chain));
    Fixture.inspectChain(chainCodec.decode(canonicalChain.encode(Layouts.copyChain(canonicalChain.decode(chain)))));
    System.out.println("checked native layout passed");
  }
}`;
const kotlinCheck=bits=>`import application.*
import lawspec.runtime.*
fun main(){
  val schema=LawSpecDataSchema.create()
  val scalar=schema.scalar("UInt8",${bits},Short::class.javaObjectType)
  val nativeCodec=LawSpecNativeCodecs.packetCodec(schema,${bits},scalar)
  val canonical=LawSpecDataCodecs.packetCodec(schema,${bits},scalar)
  val logical=nativeCodec.encode(Packed<Short>(7,true,3))
  Fixture.orderCorrect();Fixture.inspect(logical);Fixture.inspectPacket(nativeCodec.decode(logical))
  for(invalid in listOf<Short>(0,256)){
    try{nativeCodec.encode(Packed<Short>(7,true,invalid));throw AssertionError("invalid count admitted")}
    catch(expected:IllegalArgumentException){}
  }
  Fixture.inspectPacket(nativeCodec.decode(canonical.encode(Layouts.copy(canonical.decode(logical)))))
  Operations.mutate=true
  try{Layouts.copy(canonical.decode(logical));throw AssertionError("invalid native result admitted")}
  catch(expected:IllegalArgumentException){}
  val chainCodec=LawSpecNativeCodecs.chainCodec(schema,${bits})
  val canonicalChain=LawSpecDataCodecs.chainCodec(schema,${bits})
  val chain=chainCodec.encode(Link(Chain.STOP,true))
  Fixture.inspectChain(chainCodec.decode(chain))
  Fixture.inspectChain(chainCodec.decode(canonicalChain.encode(Layouts.copyChain(canonicalChain.decode(chain)))))
  println("checked native layout passed")
}`;
const scalaCheck=bits=>`import application.*
import lawspec.runtime.*
object Check {
  def main(args:Array[String]):Unit = {
    val schema=LawSpecDataSchema.create()
    val scalar=LawSpecScalaCodecs.scalar[Short](schema,"UInt8",${bits})
    val nativeCodec=LawSpecNativeCodecs.packetCodec(schema,${bits},scalar)
    val canonical=LawSpecDataCodecs.packetCodec(schema,${bits},scalar)
    val logical=nativeCodec.encode(new Packed[Short](7.toShort,true,3.toShort))
    Fixture.orderCorrect();Fixture.inspect(logical);Fixture.inspectPacket(nativeCodec.decode(logical))
    for(invalid <- List(0.toShort,256.toShort)) {
      try {nativeCodec.encode(new Packed[Short](7.toShort,true,invalid));throw new AssertionError("invalid count admitted")}
      catch {case expected:IllegalArgumentException => ()}
    }
    Fixture.inspectPacket(nativeCodec.decode(canonical.encode(Layouts.copy(canonical.decode(logical)))))
    Operations.mutate=true
    try {Layouts.copy(canonical.decode(logical));throw new AssertionError("invalid native result admitted")}
    catch {case expected:IllegalArgumentException => ()}
    val chainCodec=LawSpecNativeCodecs.chainCodec(schema,${bits})
    val canonicalChain=LawSpecDataCodecs.chainCodec(schema,${bits})
    val chain=chainCodec.encode(new Link(Chain.STOP,true))
    Fixture.inspectChain(chainCodec.decode(chain))
    Fixture.inspectChain(chainCodec.decode(canonicalChain.encode(Layouts.copyChain(canonicalChain.decode(chain)))))
    println("checked native layout passed")
  }
}`;
for(const target of ['java','kotlin','scala','groovy']){
  const compilerTool=target==='kotlin'?'kotlinc':target==='scala'?'scala':'javac';
  test(`${target} native layouts compile and enforce nested boundary refinements`,
    {skip:!required(target)&&(!available(compilerTool)?`${compilerTool} is not installed`:
      target==='scala'&&!existsSync(new URL('../../.integration/scala/lawspec.json',import.meta.url))?'Scala acceptance environment is not installed':false)},async()=>{
    for(const machineBits of [32,64])for(const minify of [false,true]){
      const result=await compiler.planGeneration({...options,target,machineBits,minify,
        sources:[{path:'layouts.lawspec',content:chainSource}],nativeBindings:jvmBindings()});
      assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-static-layout-'));
      try{
        for(const file of result.files.filter(file=>file.placement==='source')){
          const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);
        }
        for(const [name,content] of Object.entries(application)){
          const destination=path.join(root,'src/main/java',name);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,content);
        }
        if(target==='java'||target==='groovy'){
          await writeFile(path.join(root,'src/main/java/Check.java'),javaCheck(machineBits));
          run('javac',['-d','out',...await files(path.join(root,'src'),'.java')],{cwd:root});
          run('java',['-cp','out','Check'],{cwd:root});
        }else if(target==='kotlin'){
          await writeFile(path.join(root,'Check.kt'),kotlinCheck(machineBits));
          run('javac',['-d','out',...await files(path.join(root,'src'),'.java')],{cwd:root});
          run('kotlinc',['-classpath','out','-d','out',...await files(path.join(root,'src'),'.kt'),'Check.kt'],{cwd:root});
          run('kotlin',['-classpath','out','CheckKt'],{cwd:root});
        }else{
          await writeFile(path.join(root,'Check.scala'),scalaCheck(machineBits));
          // Compile the Java runtime and fixture first; Scala CLI's mixed-source
          // compilation may only typecheck Java sources when running a main.
          run('javac',['-d','out',...await files(path.join(root,'src'),'.java')],{cwd:root});
          run('scala',['--power','run','--server=false','--offline','--classpath','out',
            ...await files(path.join(root,'src'),'.scala'),'Check.scala','--main-class','Check'],{cwd:root});
        }
      }finally{await rm(root,{recursive:true,force:true});}
    }
  });
}

const rustApplication=`use std::sync::atomic::{AtomicBool,AtomicUsize,Ordering};
pub static MUTATE:AtomicBool=AtomicBool::new(false);
pub static CALLS:AtomicUsize=AtomicUsize::new(0);
#[derive(Debug)] pub struct Packed<T>{pub tail:T,pub enabled:bool,pub quantity:u8}
pub type Packet<T> = Packed<T>;
pub fn copy<T>(mut value:Packet<T>)->Packet<T>{
  CALLS.fetch_add(1,Ordering::SeqCst);
  if MUTATE.load(Ordering::SeqCst){value.quantity=0;} value
}
#[derive(Debug)] pub enum Chain{Stop,Link{next:Box<Chain>,enabled:bool}}
pub fn copy_chain(value:Chain)->Chain{value}
`;
const rustCheck=`include!("lawspec_modules.rs");
pub mod application;
#[cfg(test)] mod tests {
  use super::*;use std::sync::atomic::Ordering;
  fn packet(quantity:u8)->lawspec_data::Packet<u8>{
    lawspec_native::_lawspec_from_native_0(application::Packed{tail:7,enabled:true,quantity},&|v|v)
  }
  #[test] fn checked_layouts_and_recursive_boxes(){
    let logical=packet(3);
    assert_eq!(logical.value.first.count,3);assert!(logical.value.first.flag);assert_eq!(logical.value.last,7);
    let returned=layouts::copy(logical);
    let restored=lawspec_native::_lawspec_to_native_0(returned,&|v|v);
    assert_eq!(restored.tail,7);assert!(restored.enabled);assert_eq!(restored.quantity,3);
    let previous=application::CALLS.load(Ordering::SeqCst);
    assert!(std::panic::catch_unwind(||layouts::copy(packet(0))).is_err());
    assert_eq!(application::CALLS.load(Ordering::SeqCst),previous,"invalid argument reached native implementation");
    application::MUTATE.store(true,Ordering::SeqCst);
    assert!(std::panic::catch_unwind(||layouts::copy(packet(3))).is_err(),"invalid native result admitted");
    application::MUTATE.store(false,Ordering::SeqCst);
    let chain=application::Chain::Link{next:Box::new(application::Chain::Stop),enabled:true};
    let logical=lawspec_native::_lawspec_from_native_1(chain);
    match &logical {
      lawspec_data::Chain::Link{value}=>{assert!(value.item);assert!(matches!(value.next.as_ref(),lawspec_data::Chain::Stop));},
      _=>panic!("wrong logical branch")
    }
    let returned=layouts::copyChain(logical);
    match lawspec_native::_lawspec_to_native_1(returned){
      application::Chain::Link{next,enabled}=>{assert!(enabled);assert!(matches!(*next,application::Chain::Stop));},
      _=>panic!("wrong native branch")
    }
  }
}
`;
test('rust native layouts preserve recursive boxes and reject invalid adapter boundaries',
  {skip:!required('rust')&&'requires the Rust acceptance environment'},async()=>{
  const content=extendUnit(source,`
type Chain is one of | Stop | Link of type record{next :: Chain item :: Bool} end type
copyChain :: Chain -> Chain`);
  const nativeBindings=structuredClone(bindings);nativeBindings.rustCrate='native_layout_fixture';
  nativeBindings.types[0].native.unshift('crate');nativeBindings.types[0].constructors[0].native.unshift('crate');
  nativeBindings.functions[0].native=['crate','application','copy'];
  nativeBindings.types.push({type:'layouts::type::Chain',native:['crate','application','Chain'],constructors:[
    {constructor:'Stop',native:['crate','application','Chain','Stop'],style:'unit',fields:[]},
    {constructor:'Link',native:['crate','application','Chain','Link'],style:'variant',fields:[
      {field:'value',path:['item'],argument:1,native:'enabled'},
      {field:'value',path:['next'],argument:0,native:'next'},
    ]},
  ]});
  nativeBindings.functions.push({declaration:'layouts::copyChain',native:['crate','application','copy_chain']});
  const targetRoot=await mkdtemp(path.join(os.tmpdir(),'lawspec-layout-rust-target-'));
  try{for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...options,target:'rust',machineBits,minify,
      sources:[{path:'layouts.lawspec',content}],nativeBindings});
    assert.deepEqual(result.diagnostics,[]);
    const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-layout-rust-'));
    try{
      for(const file of result.files.filter(file=>file.placement==='source')){
        const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);
      }
      await writeFile(path.join(root,'Cargo.toml'),templates('rust')['Cargo.toml'].replace('name = "lawspec-example"','name = "native_layout_fixture"'));
      await writeFile(path.join(root,'src/lib.rs'),rustCheck);
      await writeFile(path.join(root,'src/application.rs'),rustApplication);
      run('cargo',['test','--offline','--lib'],{cwd:root,env:{...process.env,CARGO_TARGET_DIR:targetRoot}});
    }finally{await rm(root,{recursive:true,force:true});}
  }}finally{await rm(targetRoot,{recursive:true,force:true});}
});

const recursiveSource=extendUnit(source,`
copyBad :: Packet UInt8 -> Packet UInt8
type Chain is one of | Stop | Link of type record{next :: Chain item :: Bool} end type
copyChain :: Chain -> Chain`);
function recursiveBindings(target){
  const go=target==='go',module=go?'application':'Application';
  const nativeBindings=structuredClone(bindings);
  for(const item of nativeBindings.types){item.native[0]=module;for(const constructor of item.constructors){
    constructor.native[0]=module;
    if(go)for(const field of constructor.fields)field.native=field.native[0].toUpperCase()+field.native.slice(1);
  }}
  nativeBindings.types.push({type:'layouts::type::Chain',native:[module,'Chain'],constructors:[
    {constructor:'Stop',native:[module,'Stop'],style:'unit',fields:[]},
    {constructor:'Link',native:[module,'Link'],style:'variant',fields:[
      {field:'value',path:['item'],argument:1,native:go?'Flag':'flag'},
      {field:'value',path:['next'],argument:0,native:go?'Next':'next'},
    ]},
  ]});
  nativeBindings.functions=['copy','copyBad','copyChain'].map(name=>({declaration:'layouts::'+name,
    native:[module,go?name[0].toUpperCase()+name.slice(1):name]}));
  if(go)nativeBindings.goImports=[{alias:module,path:'native_layout_fixture/application'}];
  return nativeBindings;
}
const goApplication=`package application
// Deliberately use another native declaration order.
type Packed[T any] struct{ Quantity uint8; Enabled bool; Tail T }
type Packet[T any] = Packed[T]
var Calls int
func Copy[T any](value Packet[T]) Packet[T]{Calls++;return value}
func CopyBad[T any](value Packet[T]) Packet[T]{value.Quantity=0;return value}
type Chain interface{chain()}
type stop struct{}
func(stop)chain(){}
var Stop Chain=stop{}
type Link struct{Flag bool;Next Chain}
func(Link)chain(){}
func CopyChain(value Chain) Chain{return value}
`;
const goCheck=bits=>`package layouts
import("testing";"math/big";"native_layout_fixture/application")
func TestNativeLayouts(t *testing.T){
  schema:=lawSpecDataSchemaRegistry()
  native:=lawSpecNativePacketCodec(schema,${bits},lsScalarCodec[uint8](schema,${bits},"UInt8"))
  canonical:=lawSpecPacketCodec(schema,${bits},lsScalarCodec[uint8](schema,${bits},"UInt8"))
  good:=application.Packed[uint8]{Tail:7,Enabled:true,Quantity:3}
  logical:=native.fromNative(good)
  payload:=logical.Data.(lawSpecData).fields[0].Data.(lawSpecData)
  nested:=payload.fields[0].Data.(lawSpecData)
  if nested.fields[0].Data.(*big.Int).Int64()!=3||nested.fields[1].Data!=true||payload.fields[1].Data.(*big.Int).Int64()!=7{t.Fatal("logical fields reordered")}
  restored:=native.toNative(logical)
  if restored.Tail!=7||!restored.Enabled||restored.Quantity!=3{t.Fatal("native fields reordered")}
  rejected:=func(action func()){
    t.Helper();caught:=false
    func(){defer func(){if recover()!=nil{caught=true}}();action()}()
    if !caught{t.Fatal("invalid boundary admitted")}
  }
  rejected(func(){native.fromNative(application.Packed[uint8]{Tail:7,Enabled:true,Quantity:0})})
  original:=canonical.toNative(logical)
  if native.toNative(canonical.fromNative(lawSpecBoundCopy(original))).Quantity!=3{t.Fatal("adapter changed fields")}
  rejected(func(){lawSpecBoundCopyBad(original)})
  invalid:=original;invalid.Value.First.Count=0
  previous:=application.Calls
  rejected(func(){lawSpecBoundCopy(invalid)})
  if application.Calls!=previous{t.Fatal("invalid input reached native implementation")}
  chainCodec:=lawSpecNativeChainCodec(schema,${bits})
  chain:=chainCodec.toNative(chainCodec.fromNative(application.Link{Next:application.Stop,Flag:true}))
  link,ok:=chain.(application.Link);if !ok||!link.Flag||link.Next!=application.Stop{t.Fatal("recursive native shape changed")}
  canonicalChain:=lawSpecChainCodec(schema,${bits})
  copied:=lawSpecBoundCopyChain(canonicalChain.toNative(chainCodec.fromNative(chain)))
  link=chainCodec.toNative(canonicalChain.fromNative(copied)).(application.Link)
  if !link.Flag||link.Next!=application.Stop{t.Fatal("recursive adapter changed branches")}
}
`;
const haskellApplication=`module Application where
import qualified Prelude as P
import Data.Word(Word8)
data Packet a = Packed{quantity :: Word8,enabled :: P.Bool,tail :: a}
copy :: Packet a -> Packet a
copy value=if quantity value P.== 0 then P.error "NATIVE_BAD_INPUT" else value
copyBad :: Packet a -> Packet a
copyBad value=value{quantity=0}
data Chain = Stop | Link{flag :: P.Bool,next :: Chain}
copyChain :: Chain -> Chain
copyChain value=value
`;
function haskellCheck(bits,result){
  // The fixture's public native names come from the constructor using the
  // outer record and the inner record's fields; Core's digest names stay
  // internal to the compiler.
  const payload='PackedDetails',details='CountFlag';
  return `module Main where
import qualified Prelude as P
import Prelude (IO,($),(>>=),(>>),pure,fail,otherwise)
import qualified Application as A
import qualified LawSpecCodecs as Codec
import qualified LawSpecNativeCodecs as Native
import qualified LawSpecDataCodecs as Canonical
import qualified LawSpecDataSchema as Schema
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import qualified Layouts
import Data.Word(Word8)
import Control.Exception(SomeException,try,evaluate,displayException)
import Data.List(isInfixOf)
right :: P.Either P.String a -> a
right=P.either P.error P.id
ensure condition=if condition then pure () else fail "native layout mismatch"
reject action=do
  outcome<-try (action >> pure ()) :: IO (P.Either SomeException ())
  case outcome of
    P.Left error->ensure (P.not (isInfixOf "NATIVE_BAD_INPUT" (displayException error)))
    P.Right _->fail "invalid adapter boundary admitted"
main :: IO ()
main=do
  symbols<-LS.newSymbolContext
  let schema=right Schema.schema
      scalar=Codec.integerCodec schema ${bits} "UInt8" :: Codec.Codec Word8
      native=Native.packetCodec schema ${bits} scalar
      canonical=Canonical.packetCodec schema ${bits} scalar
      good=A.Packed{A.tail=7,A.enabled=P.True,A.quantity=3}
      logical=right (Codec.encode native good)
  case logical of
    LS.SData _ [LS.SData _ [LS.SData _ [LS.SInteger "UInt8" 3,LS.SBool P.True],LS.SInteger "UInt8" 7]]->pure ()
    _->fail "logical fields reordered"
  let restored=right (Codec.decode native logical)
  ensure (A.tail restored P.== 7 P.&& A.enabled restored P.&& A.quantity restored P.== 3)
  case Codec.encode native good{A.quantity=0} of
    P.Left _->pure ();P.Right _->fail "invalid native record admitted"
  let original=right (Codec.decode canonical logical)
      returned=Layouts.copy symbols original
  ensure (Codec.encode canonical returned P.== P.Right logical)
  reject (evaluate (Layouts.copyBad symbols original))
  let invalid=Data.Packet (Data.${payload} (Data.${details} 0 P.True) 7)
  reject (evaluate (Layouts.copy symbols invalid))
  let chainCodec=Native.chainCodec schema ${bits}
      chain=A.Link{A.next=A.Stop,A.flag=P.True}
      chainLogical=right (Codec.encode chainCodec chain)
      canonicalChain=Canonical.chainCodec schema ${bits}
      copied=Layouts.copyChain symbols (right (Codec.decode canonicalChain chainLogical))
      roundtrip=right (Codec.decode chainCodec (right (Codec.encode canonicalChain copied)))
  case roundtrip of A.Link{A.next=A.Stop,A.flag=P.True}->pure ();_->fail "recursive shape changed"
  P.putStrLn "checked native layouts passed"
`;
}
for(const target of ['go','haskell']){
  test(`${target} native layouts preserve recursive records and checked boundaries`,
    {skip:!required(target)&&(target==='haskell'?'requires the Haskell acceptance environment':!available('go')&&'go is not installed')},async()=>{
    const stackArguments=['--no-terminal','--stack-yaml',new URL('../../stack.yaml',import.meta.url).pathname,'path'];
    const ghc=target==='haskell'?(process.env.LAWSPEC_GHC??run('stack',[...stackArguments,'--compiler-exe']).trim()):null;
    const packageDb=target==='haskell'?run('stack',[...stackArguments,'--snapshot-pkg-db']).trim():null;
    for(const machineBits of [32,64])for(const minify of [false,true]){
      const result=await compiler.planGeneration({...options,target,machineBits,minify,
        sources:[{path:'layouts.lawspec',content:recursiveSource}],nativeBindings:recursiveBindings(target)});
      assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-functional-layout-'));
      try{
        for(const file of result.files.filter(file=>file.placement==='source')){
          const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);
        }
        if(target==='go'){
          await mkdir(path.join(root,'application'));
          await writeFile(path.join(root,'application/application.go'),goApplication);
          await writeFile(path.join(root,'layouts/layout_test.go'),goCheck(machineBits));
          await writeFile(path.join(root,'go.mod'),'module native_layout_fixture\n\ngo 1.24\n');
          run('go',['test','./...'],{cwd:root,env:{...process.env,GOPROXY:'off',GOTOOLCHAIN:'local'}});
        }else{
          await writeFile(path.join(root,'src/Application.hs'),haskellApplication);
          await writeFile(path.join(root,'Main.hs'),haskellCheck(machineBits,result));
          await mkdir(path.join(root,'build'));
          run(ghc,['-package-db',packageDb,'-package','network','-O0','-isrc','-odir','build','-hidir','build','Main.hs','-o','check'],{cwd:root});
          run(path.join(root,'check'),[],{cwd:root});
        }
      }finally{await rm(root,{recursive:true,force:true});}
    }
  });
}

const dotnetSwiftSource=extendUnit(recursiveSource,`
type Crate (a :: Type) is a record{
  payload :: record{last :: a first :: record{count :: (n :: UInt8 where n > 0) flag :: Bool}}
} end type
copyCrate :: Crate UInt8 -> Crate UInt8`);
function dotnetSwiftBindings(target){
  const made=recursiveBindings('haskell');
  const swift=target==='swift';
  made.types[0].constructors[0].native=swift?['Application','Packet','packed']:['Application','Packed'];
  for(const constructor of made.types[1].constructors)
    constructor.native=swift?['Application','Chain',constructor.constructor.toLowerCase()]:['Application',constructor.constructor];
  made.types.push({type:'layouts::type::Crate',native:['Application','Crate'],constructors:[{
    constructor:'Crate',native:['Application','Crate'],style:'record',fields:
      made.types[0].constructors[0].fields.map(field=>({...field,field:'payload',native:swift?field.native:field.native[0].toUpperCase()+field.native.slice(1)})),
  }]});
  made.functions.push({declaration:'layouts::copyCrate',native:['Application','copyCrate']});
  return made;
}
const fsharpApplication=`module Application
[<NoEquality; NoComparison>]
type Packet<'T> = Packed of tail: 'T * enabled: bool * quantity: byte
[<NoEquality; NoComparison>]
type Chain = Stop | Link of next: Chain * flag: bool
[<NoEquality; NoComparison>]
type Crate<'T> = { Tail: 'T; Enabled: bool; Quantity: byte }
let copy (Packed(_,_,quantity) as value) =
    if quantity = 0uy then failwith "NATIVE_INPUT_REACHED"
    value
let copyBad (Packed(tail,enabled,_)) = Packed(tail,enabled,0uy)
let copyChain value = value
let copyCrate (value: Crate<byte>) =
    if value.Quantity = 0uy then failwith "NATIVE_INPUT_REACHED"
    value
`;
const fsharpCheck=`module Check
open LawSpec.Runtime
let require condition = if not condition then failwith "native layout mismatch"
let rejected code action =
    try action (); failwith "invalid value admitted"
    with :? LawSpecException as error -> require (error.Code = code)
[<EntryPoint>]
let main _ =
    let schema = LawSpec.Generated.Program.schema
    let symbols = Scalar.SymbolContext()
    let packet = LawSpec.Data.Codecs.packet Codec.uint8
    let logical = packet.FromNative (Application.Packed(7uy,true,3uy))
    match logical with
    | Value.Data(_, [Value.Data(_, [Value.Data(_, [Value.Int count; Value.Bool true]); Value.Int tail])]) -> require (count = 3I && tail = 7I)
    | _ -> failwith "wrong packed shape"
    let result = LawSpec.Generated.Layouts.copy schema symbols logical |> packet.ToNative
    match result with Application.Packed(tail,enabled,count) -> require (tail = 7uy && enabled && count = 3uy)
    let invalid = packet.FromNative (Application.Packed(7uy,true,0uy))
    rejected "RefinementViolation" (fun () -> LawSpec.Generated.Layouts.copy schema symbols invalid |> ignore)
    rejected "RefinementViolation" (fun () -> LawSpec.Generated.Layouts.copyBad schema symbols logical |> ignore)
    let chain = LawSpec.Data.Codecs.chain ()
    let recursive = chain.FromNative (Application.Link(Application.Link(Application.Stop,false),true))
    match LawSpec.Generated.Layouts.copyChain schema symbols recursive |> chain.ToNative with
    | Application.Link(Application.Link(Application.Stop,false),true) -> ()
    | _ -> failwith "recursive chain mismatch"
    let crate = LawSpec.Data.Codecs.crate Codec.uint8
    let record = crate.FromNative { Application.Tail=7uy; Application.Enabled=true; Application.Quantity=3uy }
    let result = LawSpec.Generated.Layouts.copyCrate schema symbols record |> crate.ToNative
    require (result.Tail = 7uy && result.Enabled && result.Quantity = 3uy)
    let invalid = crate.FromNative { Application.Tail=7uy; Application.Enabled=true; Application.Quantity=0uy }
    rejected "RefinementViolation" (fun () -> LawSpec.Generated.Layouts.copyCrate schema symbols invalid |> ignore)
    printfn "checked native layout passed"
    0
`;
const swiftApplication=`import LawSpecRuntime
public enum Application {
    public enum Packet<T> { case packed(tail:T, enabled:Bool, quantity:UInt8) }
    public indirect enum Chain: Sendable { case stop; case link(next:Chain, flag:Bool) }
    public struct Crate<T> {
        public let tail:T
        public let enabled:Bool
        public let quantity:UInt8
    }
    public enum Failure: Error { case nativeInputReached }
    public static func copy(_ value:Packet<UInt8>) throws -> Packet<UInt8> {
        if case .packed(_,_,0) = value { throw Failure.nativeInputReached }
        return value
    }
    public static func copyBad(_ value:Packet<UInt8>) -> Packet<UInt8> {
        switch value { case .packed(let tail,let enabled,_):return .packed(tail:tail,enabled:enabled,quantity:0) }
    }
    public static func copyChain(_ value:Chain) -> Chain { value }
    public static func copyCrate(_ value:Crate<UInt8>) throws -> Crate<UInt8> {
        if value.quantity == 0 { throw Failure.nativeInputReached }
        return value
    }
}
`;
const swiftCheck=`import LawSpecRuntime
func require(_ condition:Bool) { precondition(condition,"native layout mismatch") }
func rejected(_ code:String,_ action:() throws -> Void) {
    do { try action(); preconditionFailure("invalid value admitted") }
    catch let error as LawSpecError { require(error.code == code) }
    catch { preconditionFailure("unexpected native failure: \\(error)") }
}
@main struct Check {
    static func main() throws {
        let schema=LawSpec.Program.schema, symbols=SymbolContext()
        let packet=LawSpec.DataCodecs.packet(Codecs.uint8)
        let logical=try packet.fromNative(Application.Packet.packed(tail:7,enabled:true,quantity:3))
        guard case .data(_,let outer)=logical, outer.count==1,
              case .data(_,let payload)=outer[0], payload.count==2,
              case .data(_,let first)=payload[0], first.count==2,
              case .int(let count)=first[0], case .bool(true)=first[1], case .int(let tail)=payload[1]
        else { preconditionFailure("wrong packed shape") }
        require(count==BigInt(3) && tail==BigInt(7))
        let result=try packet.toNative(LawSpec.Generated.Layouts.copy(schema,symbols,logical))
        if case .packed(let tail,let enabled,let count)=result { require(tail==7 && enabled && count==3) }
        let invalid=try packet.fromNative(Application.Packet.packed(tail:7,enabled:true,quantity:0))
        rejected("RefinementViolation") { _ = try LawSpec.Generated.Layouts.copy(schema,symbols,invalid) }
        rejected("RefinementViolation") { _ = try LawSpec.Generated.Layouts.copyBad(schema,symbols,logical) }
        let chain=LawSpec.DataCodecs.chain()
        let recursive=try chain.fromNative(.link(next:.link(next:.stop,flag:false),flag:true))
        let back=try chain.toNative(LawSpec.Generated.Layouts.copyChain(schema,symbols,recursive))
        if case .link(.link(.stop,false),true)=back {} else { preconditionFailure("recursive chain mismatch") }
        let crate=LawSpec.DataCodecs.crate(Codecs.uint8)
        let record=try crate.fromNative(Application.Crate(tail:7,enabled:true,quantity:3))
        let recordBack=try crate.toNative(LawSpec.Generated.Layouts.copyCrate(schema,symbols,record))
        require(recordBack.tail==7 && recordBack.enabled && recordBack.quantity==3)
        let badRecord=try crate.fromNative(Application.Crate(tail:7,enabled:true,quantity:0))
        rejected("RefinementViolation") { _ = try LawSpec.Generated.Layouts.copyCrate(schema,symbols,badRecord) }
        print("checked native layout passed")
    }
}
`;
for(const target of ['fsharp','swift']){
  const tool=target==='fsharp'?'dotnet':'swift';
  test(`${target} native layouts compile generic variants, records and recursive types with checked boundaries`,
    {skip:!required(target)&&!available(tool)&&`${tool} is not installed`},async()=>{
    for(const machineBits of [32,64])for(const minify of [false,true]){
      const result=await compiler.planGeneration({...options,target,machineBits,minify,
        sources:[{path:'layouts.lawspec',content:dotnetSwiftSource}],nativeBindings:dotnetSwiftBindings(target)});
      assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-dotnet-swift-layout-'));
      try{
        for(const file of result.files.filter(file=>file.placement==='source')){
          const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);
        }
        if(target==='fsharp'){
          await mkdir(path.join(root,'src/Native/Types'),{recursive:true});
          await writeFile(path.join(root,'src/Native/Types/Application.fs'),fsharpApplication);
          await writeFile(path.join(root,'src/Check.fs'),fsharpCheck);
          await writeFile(path.join(root,'src/Check.fsproj'),`<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><NuGetAudit>false</NuGetAudit></PropertyGroup><Import Project="LawSpec.Sources.props"/><ItemGroup><Compile Include="Check.fs"/><ProjectReference Include="../lawspec/LawSpec.Runtime/LawSpec.Runtime.fsproj"/></ItemGroup></Project>`);
          assert.match(run('dotnet',['run','--project','src/Check.fsproj','--verbosity','quiet'],{cwd:root}),/checked native layout passed/);
        }else{
          await writeFile(path.join(root,'src/Application.swift'),swiftApplication);
          await writeFile(path.join(root,'src/Check.swift'),swiftCheck);
          await writeFile(path.join(root,'Package.swift'),`// swift-tools-version: 6.2\nimport PackageDescription\nlet package=Package(name:"NativeLayout",platforms:[.macOS(.v26)],targets:[.target(name:"LawSpecRuntime",path:"lawspec/LawSpecRuntime"),.executableTarget(name:"Check",dependencies:["LawSpecRuntime"],path:"src")])\n`);
          assert.match(run('swift',['run','--quiet','-j','2','Check'],{cwd:root}),/checked native layout passed/);
        }
      }finally{await rm(root,{recursive:true,force:true});}
    }
  });
}

function beamBindings(target){
  const made=dotnetSwiftBindings('swift'),elixir=target==='elixir';
  const owner=elixir?'LayoutApplication':'layout_application';
  for(const type of made.types){
    type.native=[owner,target==='erlang'?type.type.split('::').at(-1).toLowerCase():type.type.split('::').at(-1)];
    for(const constructor of type.constructors){
      constructor.native=target==='erlang'||(elixir&&constructor.constructor==='Stop')?
        [constructor.constructor.toLowerCase()]:[owner,constructor.constructor];
    }
  }
  made.functions=made.functions.map(binding=>({...binding,native:[owner,binding.declaration.split('::').at(-1).replace(/[A-Z]/g,c=>'_'+c.toLowerCase())]}));
  if(target==='erlang')made.erlangIncludes=[{path:'layout_application.hrl'}];
  return made;
}
const erlangLayoutApplication=`-module(layout_application).
-include("layout_application.hrl").
-export([copy/1,copy_bad/1,copy_chain/1,copy_crate/1]).
copy({packed,_,_,0}) -> error(native_input_reached);
copy(Value) -> Value.
copy_bad({packed,Tail,Enabled,_}) -> {packed,Tail,Enabled,0}.
copy_chain(Value) -> Value.
copy_crate(#crate{quantity=0}) -> error(native_input_reached);
copy_crate(Value) -> Value.
`;
const elixirLayoutApplication=`defmodule LayoutApplication.Packed do
  defstruct [:tail, :enabled, :quantity]
end
defmodule LayoutApplication.Link do
  defstruct [:next, :flag]
end
defmodule LayoutApplication.Crate do
  defstruct [:quantity, :enabled, :tail]
end
defmodule LayoutApplication do
  def copy(%{quantity: 0}), do: raise("NATIVE_INPUT_REACHED")
  def copy(value), do: value
  def copy_bad(value), do: %{value | quantity: 0}
  def copy_chain(value), do: value
  def copy_crate(%{quantity: 0}), do: raise("NATIVE_INPUT_REACHED")
  def copy_crate(value), do: value
end
`;
const gleamLayoutApplication=`pub type Packet(a) { Packed(quantity: Int, tail: a, enabled: Bool) }
pub type Chain { Stop Link(flag: Bool, next: Chain) }
pub type Crate(a) { Crate(quantity: Int, enabled: Bool, tail: a) }
pub fn copy(value: Packet(Int)) -> Packet(Int) {
  case value.quantity { 0 -> panic as "NATIVE_INPUT_REACHED" _ -> value }
}
pub fn copy_bad(value: Packet(Int)) -> Packet(Int) { Packed(tail: value.tail, enabled: value.enabled, quantity: 0) }
pub fn copy_chain(value: Chain) -> Chain { value }
pub fn copy_crate(value: Crate(Int)) -> Crate(Int) {
  case value.quantity { 0 -> panic as "NATIVE_INPUT_REACHED" _ -> value }
}
`;
function beamCheck(target){
  const packet=(quantity)=>target==='elixir'?`#{'__struct__'=>'Elixir.LayoutApplication.Packed',tail=>7,enabled=>true,quantity=>${quantity}}`:
    target==='gleam'?`{packed,${quantity},7,true}`:`{packed,7,true,${quantity}}`;
  const crate=target==='elixir'?`#{'__struct__'=>'Elixir.LayoutApplication.Crate',tail=>7,enabled=>true,quantity=>3}`:'{crate,3,true,7}';
  const chain=target==='elixir'?`#{'__struct__'=>'Elixir.LayoutApplication.Link',next=>stop,flag=>true}`:
    target==='gleam'?'{link,true,stop}':'{link,stop,true}';
  return `-module(layout_check).
-export([run/0]).
require(true) -> ok; require(false) -> error(native_layout_mismatch).
reason({Identity,Reason}) when is_binary(Identity) -> reason(Reason);
reason({Code,_}) -> Code;
reason(Code) -> Code.
rejected(Code,Action) ->
    try Action(), error(invalid_value_admitted)
    catch error:{lawspec,Reason} -> require(reason(Reason) =:= Code) end.
bad({ls_data,Tag,[{ls_data,Payload,[{ls_data,First,[_,Flag]},Tail]}]}) ->
    {ls_data,Tag,[{ls_data,Payload,[{ls_data,First,[0,Flag]},Tail]}]}.
run() ->
    Canonical=lawspec_data:schema(#{}), Native=lawspec_native_bindings:schema(Canonical),
    Packet={<<"layouts::type::Packet">>,[{<<"UInt8">>,[]}]},
    Logical=lawspec_beam_schema:from_native(${packet(3)},Packet,Native),
    {ls_data,_,[{ls_data,_,[{ls_data,_,[3,true]},7]}]}=Logical,
    require(lawspec_beam_schema:to_native(Logical,Packet,Native) =:= ${packet(3)}),
    require(lawspec_native_bindings:call_0(Canonical,#{},Logical) =:= Logical),
    rejected(refinement_violation,fun() -> lawspec_native_bindings:call_0(Canonical,#{},bad(Logical)) end),
    rejected(refinement_violation,fun() -> lawspec_native_bindings:call_1(Canonical,#{},Logical) end),
    rejected(integer_out_of_range,fun() -> lawspec_beam_schema:from_native(${packet(256)},Packet,Native) end),
    rejected(invalid_native_constructor,fun() -> lawspec_beam_schema:from_native(other_packet,Packet,Native) end),
    Chain={<<"layouts::type::Chain">>,[]},
    Recursive=lawspec_beam_schema:from_native(${chain},Chain,Native),
    require(lawspec_native_bindings:call_2(Canonical,#{},Recursive) =:= Recursive),
    require(lawspec_beam_schema:to_native(Recursive,Chain,Native) =:= ${chain}),
    Crate={<<"layouts::type::Crate">>,[{<<"UInt8">>,[]}]},
    Record=lawspec_beam_schema:from_native(${crate},Crate,Native),
    require(lawspec_native_bindings:call_3(Canonical,#{},Record) =:= Record),
    require(lawspec_beam_schema:to_native(Record,Crate,Native) =:= ${crate}),
    rejected(refinement_violation,fun() -> lawspec_native_bindings:call_3(Canonical,#{},bad(Record)) end),
    io:format("checked native layout passed~n").
`;
}
const gleamStdlib=process.env.LAWSPEC_GLEAM_STDLIB??new URL('../../.integration/gleam/build/packages/gleam_stdlib',import.meta.url).pathname;
for(const target of ['erlang','elixir','gleam']){
  const tool=target==='erlang'?'erl':target;
  test(`${target} native layouts compile generic records, variants and recursive values with checked boundaries`,
    {skip:!required(target)&&(!available(tool)?`${tool} is not installed`:
      target==='gleam'&&!existsSync(gleamStdlib)?'prepared Gleam standard library is not installed':false)},async()=>{
    for(const machineBits of [32,64])for(const minify of [false,true]){
      const result=await compiler.planGeneration({...options,target,machineBits,minify,
        sources:[{path:'layouts.lawspec',content:dotnetSwiftSource}],nativeBindings:beamBindings(target)});
      assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-beam-layout-'));
      try{
        for(const file of result.files.filter(file=>file.placement==='source')){
          const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);
        }
        await mkdir(path.join(root,'ebin'));
        await writeFile(path.join(root,'src/layout_check.erl'),beamCheck(target));
        if(target==='erlang'){
          await writeFile(path.join(root,'src/layout_application.hrl'),'-record(crate,{quantity,enabled,tail}).\n');
          await writeFile(path.join(root,'src/layout_application.erl'),erlangLayoutApplication);
        }else if(target==='elixir'){
          await writeFile(path.join(root,'src/layout_application.ex'),elixirLayoutApplication);
          run('elixirc',['-o','ebin',...await files(path.join(root,'src'),'.ex')],{cwd:root});
        }else{
          await writeFile(path.join(root,'src/layout_application.gleam'),gleamLayoutApplication);
          await writeFile(path.join(root,'gleam.toml'),`name = "native_layout_fixture"\nversion = "0.1.0"\ntarget = "erlang"\n[dependencies]\ngleam_stdlib = { path = ${JSON.stringify(gleamStdlib)} }\n`);
          run('gleam',['build'],{cwd:root});
        }
        if(target!=='gleam')run('erlc',['-Werror','-I','src','-o','ebin',...await files(path.join(root,'src'),'.erl')],{cwd:root});
        const beamDirectories=target==='gleam'?[...new Set((await files(path.join(root,'build'),'.beam')).map(file=>path.dirname(file)))]:[path.join(root,'ebin')];
        const output=target==='elixir'?run('elixir',['-pa',...beamDirectories,'-e',':layout_check.run()'],{cwd:root}):
          run('erl',['-noshell','-pa',...beamDirectories,'-eval','layout_check:run(),halt(0).'],{cwd:root});
        assert.match(output,/checked native layout passed/);
      }finally{await rm(root,{recursive:true,force:true});}
    }
  });
}
