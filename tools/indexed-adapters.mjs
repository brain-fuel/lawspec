// Native adapters and index-breaking mutants for examples/specs/indexed_families.lawspec.
// Each mutant changes a result index: an extra replicated element, a dropped
// appended element, a zip that loses pairs, and a flatten that loses a subtree.

const python = `# User-owned LawSpec adapter.
import lawspec_data as data


def replicate(value0, value1):
    result = data.VecVNil()
    for _ in range(value0):
        result = data.VecVCons(value1, result)
    return result


def append(value0, value1):
    if isinstance(value0, data.VecVNil):
        return value1
    return data.VecVCons(value0.head, append(value0.tail, value1))


def zip(value0, value1):
    if isinstance(value0, data.VecVNil):
        return data.VecVNil()
    return data.VecVCons(value1.head, zip(value0.tail, value1.tail))


def flatten(value0):
    if isinstance(value0, data.TreeTip):
        return data.VecVNil()
    right = data.VecVCons(value0.value, flatten(value0.right))
    return append(flatten(value0.left), right)
`;

const web = (typed) => {
  const t = (annotation) => (typed ? annotation : '');
  return `// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.${typed ? 'js' : 'mjs'}';

export function replicate(value0${t(': bigint')}, value1${t(': number')})${t(': data.Vec<number>')} {
  let result${t(': data.Vec<number>')} = new data.VecVNil();
  for (let i = 0n; i < BigInt(value0); i++) result = new data.VecVCons(value1, result);
  return result;
}

export function append(value0${t(': data.Vec<number>')}, value1${t(': data.Vec<number>')})${t(': data.Vec<number>')} {
  if (value0 instanceof data.VecVNil) return value1;
  return new data.VecVCons(value0.head, append(value0.tail, value1));
}

export function zip(value0${t(': data.Vec<number>')}, value1${t(': data.Vec<boolean>')})${t(': data.Vec<boolean>')} {
  if (!(value0 instanceof data.VecVCons) || !(value1 instanceof data.VecVCons)) return new data.VecVNil();
  return new data.VecVCons(value1.head, zip(value0.tail, value1.tail));
}

export function flatten(value0${t(': data.Tree<number>')})${t(': data.Vec<number>')} {
  if (!(value0 instanceof data.TreeBin)) return new data.VecVNil();
  const right = new data.VecVCons(value0.value, flatten(value0.right));
  return append(flatten(value0.left), right);
}
`;
};

const java = `// User-owned LawSpec adapter.
package example;

import lawspec.data.Tree;
import lawspec.data.Vec;

public final class Indexed {
  public static Vec<Byte> replicate(java.math.BigInteger value0, byte value1) {
    Vec<Byte> result = new Vec.VNilCase<>();
    for (var i = java.math.BigInteger.ZERO; i.compareTo(value0) < 0; i = i.add(java.math.BigInteger.ONE)) {
      result = new Vec.VConsCase<>(value1, result);
    }
    return result;
  }

  public static Vec<Byte> append(Vec<Byte> value0, Vec<Byte> value1) {
    if (!(value0 instanceof Vec.VConsCase<Byte> cons)) return value1;
    return new Vec.VConsCase<>(cons.head, append(cons.tail, value1));
  }

  public static Vec<Boolean> zip(Vec<Byte> value0, Vec<Boolean> value1) {
    if (value0 instanceof Vec.VConsCase<Byte> a && value1 instanceof Vec.VConsCase<Boolean> b) {
      return new Vec.VConsCase<>(b.head, zip(a.tail, b.tail));
    }
    return new Vec.VNilCase<>();
  }

  public static Vec<Byte> flatten(Tree<Byte> value0) {
    if (!(value0 instanceof Tree.BinCase<Byte> node)) return new Vec.VNilCase<>();
    Vec<Byte> right = new Vec.VConsCase<>(node.value, flatten(node.right));
    return append(flatten(node.left), right);
  }
}
`;

const kotlin = `// User-owned LawSpec adapter.
package example

import lawspec.data.Tree
import lawspec.data.Vec

object Indexed {
    fun replicate(value0: java.math.BigInteger, value1: Byte): Vec<Byte> {
        var result: Vec<Byte> = Vec.VNilCase()
        var i = java.math.BigInteger.ZERO
        while (i < value0) {
            result = Vec.VConsCase(value1, result)
            i += java.math.BigInteger.ONE
        }
        return result
    }

    fun append(value0: Vec<Byte>, value1: Vec<Byte>): Vec<Byte> =
        if (value0 is Vec.VConsCase) Vec.VConsCase(value0.head, append(value0.tail, value1)) else value1

    fun zip(value0: Vec<Byte>, value1: Vec<Boolean>): Vec<Boolean> =
        if (value0 is Vec.VConsCase && value1 is Vec.VConsCase) {
            Vec.VConsCase(value1.head, zip(value0.tail, value1.tail))
        } else {
            Vec.VNilCase()
        }

    fun flatten(value0: Tree<Byte>): Vec<Byte> {
        if (value0 !is Tree.BinCase) return Vec.VNilCase()
        val right: Vec<Byte> = Vec.VConsCase(value0.value, flatten(value0.right))
        return append(flatten(value0.left), right)
    }
}
`;

const go = `// User-owned LawSpec adapter.
package indexed

import "math/big"

// Replicate returns value0 copies of value1.
func Replicate(value0 *LawSpecBigInt, value1 int8) Vec[int8] {
	var result Vec[int8] = VecVNil[int8]{}
	for i := new(big.Int); i.Cmp(value0) < 0; i.Add(i, big.NewInt(1)) {
		result = VecVCons[int8]{Head: value1, Tail: result}
	}
	return result
}

// Append concatenates two vectors.
func Append(value0 Vec[int8], value1 Vec[int8]) Vec[int8] {
	cons, ok := value0.(VecVCons[int8])
	if !ok {
		return value1
	}
	return VecVCons[int8]{Head: cons.Head, Tail: Append(cons.Tail, value1)}
}

// Zip keeps the second vector's elements in pairs with the first.
func Zip(value0 Vec[int8], value1 Vec[bool]) Vec[bool] {
	a, ok := value0.(VecVCons[int8])
	b, ok2 := value1.(VecVCons[bool])
	if !ok || !ok2 {
		return VecVNil[bool]{}
	}
	return VecVCons[bool]{Head: b.Head, Tail: Zip(a.Tail, b.Tail)}
}

// Flatten lists the values of a tree in order.
func Flatten(value0 Tree[int8]) Vec[int8] {
	node, ok := value0.(TreeBin[int8])
	if !ok {
		return VecVNil[int8]{}
	}
	right := VecVCons[int8]{Head: node.Value, Tail: Flatten(node.Right)}
	return Append(Flatten(node.Left), right)
}
`;

const haskell = `-- User-owned LawSpec adapter.
module Example.Indexed (replicate, append, zip, flatten) where

import Prelude hiding (replicate, zip)
import qualified Data.Int as I
import qualified LawSpecData as Data

replicate :: Integer -> I.Int8 -> Data.Vec I.Int8
replicate n x = if n <= 0 then Data.VecVNil else Data.VecVCons x (replicate (n - 1) x)

append :: Data.Vec I.Int8 -> Data.Vec I.Int8 -> Data.Vec I.Int8
append Data.VecVNil ys = ys
append (Data.VecVCons x xs) ys = Data.VecVCons x (append xs ys)

zip :: Data.Vec I.Int8 -> Data.Vec Bool -> Data.Vec Bool
zip (Data.VecVCons _ xs) (Data.VecVCons y ys) = Data.VecVCons y (zip xs ys)
zip _ _ = Data.VecVNil

flatten :: Data.Tree I.Int8 -> Data.Vec I.Int8
flatten Data.TreeTip = Data.VecVNil
flatten (Data.TreeBin left value right) =
  append (flatten left) (Data.VecVCons value (flatten right))
`;

const rust = `// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{Tree, Vec};
use crate::lawspec_runtime as ls;

pub fn replicate(value0: ls::BigInt, value1: i8) -> Vec<i8> {
    let mut result = Vec::VNil;
    let mut count = value0;
    while count > ls::BigInt::from(0) {
        result = Vec::VCons { head: value1, tail: Box::new(result) };
        count -= 1;
    }
    result
}

pub fn append(value0: Vec<i8>, value1: Vec<i8>) -> Vec<i8> {
    match value0 {
        Vec::VNil => value1,
        Vec::VCons { head, tail } => Vec::VCons { head, tail: Box::new(append(*tail, value1)) },
    }
}

pub fn zip(value0: Vec<i8>, value1: Vec<bool>) -> Vec<bool> {
    match (value0, value1) {
        (Vec::VCons { tail: a, .. }, Vec::VCons { head, tail: b }) => Vec::VCons { head, tail: Box::new(zip(*a, *b)) },
        _ => Vec::VNil,
    }
}

pub fn flatten(value0: Tree<i8>) -> Vec<i8> {
    match value0 {
        Tree::Tip => Vec::VNil,
        Tree::Bin { left, value, right } => {
            let right = Vec::VCons { head: value, tail: Box::new(flatten(*right)) };
            append(flatten(*left), right)
        }
    }
}
`;

const adapters = {
  python, javascript: web(false), typescript: web(true), java, kotlin, go, haskell, rust,
};

// [name, original, replacement] applied to the correct adapter.
const mutations = {
  python: [
    ['replicate', 'range(value0)', 'range(value0 + 1)'],
    ['append', 'return data.VecVCons(value0.head, append(value0.tail, value1))', 'return append(value0.tail, value1)'],
    ['zip', 'return data.VecVCons(value1.head, zip(value0.tail, value1.tail))', 'return zip(value0.tail, value1.tail)'],
    ['flatten', 'right = data.VecVCons(value0.value, flatten(value0.right))', 'right = data.VecVCons(value0.value, data.VecVNil())'],
  ],
  web: [
    ['replicate', 'i < BigInt(value0)', 'i <= BigInt(value0)'],
    ['append', 'return new data.VecVCons(value0.head, append(value0.tail, value1));', 'return append(value0.tail, value1);'],
    ['zip', 'return new data.VecVCons(value1.head, zip(value0.tail, value1.tail));', 'return zip(value0.tail, value1.tail);'],
    ['flatten', 'new data.VecVCons(value0.value, flatten(value0.right))', 'new data.VecVCons(value0.value, new data.VecVNil())'],
  ],
  java: [
    ['replicate', 'i.compareTo(value0) < 0', 'i.compareTo(value0) <= 0'],
    ['append', 'return new Vec.VConsCase<>(cons.head, append(cons.tail, value1));', 'return append(cons.tail, value1);'],
    ['zip', 'return new Vec.VConsCase<>(b.head, zip(a.tail, b.tail));', 'return zip(a.tail, b.tail);'],
    ['flatten', 'new Vec.VConsCase<>(node.value, flatten(node.right))', 'new Vec.VConsCase<>(node.value, new Vec.VNilCase<>())'],
  ],
  kotlin: [
    ['replicate', 'while (i < value0)', 'while (i <= value0)'],
    ['append', 'Vec.VConsCase(value0.head, append(value0.tail, value1)) else value1', 'append(value0.tail, value1) else value1'],
    ['zip', 'Vec.VConsCase(value1.head, zip(value0.tail, value1.tail))', 'zip(value0.tail, value1.tail)'],
    ['flatten', 'Vec.VConsCase(value0.value, flatten(value0.right))', 'Vec.VConsCase(value0.value, Vec.VNilCase())'],
  ],
  go: [
    ['replicate', 'i.Cmp(value0) < 0', 'i.Cmp(value0) <= 0'],
    ['append', 'return VecVCons[int8]{Head: cons.Head, Tail: Append(cons.Tail, value1)}', 'return Append(cons.Tail, value1)'],
    ['zip', 'return VecVCons[bool]{Head: b.Head, Tail: Zip(a.Tail, b.Tail)}', 'return Zip(a.Tail, b.Tail)'],
    ['flatten', 'VecVCons[int8]{Head: node.Value, Tail: Flatten(node.Right)}', 'VecVCons[int8]{Head: node.Value, Tail: VecVNil[int8]{}}'],
  ],
  haskell: [
    ['replicate', 'if n <= 0 then Data.VecVNil', 'if n < 0 then Data.VecVNil'],
    ['append', 'append (Data.VecVCons x xs) ys = Data.VecVCons x (append xs ys)', 'append (Data.VecVCons _ xs) ys = append xs ys'],
    ['zip', 'zip (Data.VecVCons _ xs) (Data.VecVCons y ys) = Data.VecVCons y (zip xs ys)', 'zip (Data.VecVCons _ xs) (Data.VecVCons _ ys) = zip xs ys'],
    ['flatten', '(Data.VecVCons value (flatten right))', '(Data.VecVCons value Data.VecVNil)'],
  ],
  rust: [
    ['replicate', 'while count > ls::BigInt::from(0)', 'while count >= ls::BigInt::from(0)'],
    ['append', 'Vec::VCons { head, tail } => Vec::VCons { head, tail: Box::new(append(*tail, value1)) },', 'Vec::VCons { tail, .. } => append(*tail, value1),'],
    ['zip', '=> Vec::VCons { head, tail: Box::new(zip(*a, *b)) },', '=> zip(*a, *b),'],
    ['flatten', 'Box::new(flatten(*right))', 'Box::new(Vec::VNil)'],
  ],
};

export function indexedAdapter(target) {
  return adapters[target];
}

export function indexedMutants(target) {
  const correct = adapters[target];
  const list = mutations[['javascript', 'typescript'].includes(target) ? 'web' : target];
  return list.map(([name, before, after]) => {
    if (!correct.includes(before)) throw new Error(`${target}: missing mutant marker for ${name}`);
    return {name, content: correct.replace(before, after)};
  });
}
