// Generated from templates/npm/test/native-static-layouts.test.mjs by lawspec-dev generate. Do not edit.
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
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const source=`unit layouts
type Packet (a :: Type) is one of Packed of type record{
  last :: a first :: record{count :: (n :: UInt8 where n > 0) flag :: Bool}
} end type
copy :: Packet UInt8 -> Packet UInt8`;
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
const available=command=>spawnSync(command,[command==='kotlinc'?'-version':'--version'],{stdio:'ignore'}).status===0;
async function files(root,extension){
  const found=[];
  for(const item of await readdir(root,{withFileTypes:true})){
    const child=path.join(root,item.name);
    if(item.isDirectory())found.push(...await files(child,extension));
    else if(child.endsWith(extension))found.push(child);
  }
  return found;
}
const application={
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
        sources:[{path:'layouts.lawspec',content:source}],nativeBindings:bindings});
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
  const content=source+`
type Chain is one of | Stop | Link of type record{next :: Chain item :: Bool} end type
copyChain :: Chain -> Chain`;
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
