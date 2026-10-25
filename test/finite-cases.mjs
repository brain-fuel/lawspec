import assert from "node:assert/strict";
import {
  finiteCases,
  searchElements,
  searchElementsAsync,
} from "../runtime/lawspec_runtime.mjs";

const constant = (value) => () => value;
const decode = (cover) =>
  Array.from(finiteCases(cover), ([index, values]) => [
    index,
    values.map((factory) => factory(new Map())),
  ]);

assert.deepEqual(decode([]), []);
assert.deepEqual(decode(1), [[0, []]]);
assert.deepEqual(decode(2), [
  [0, []],
  [1, []],
]);
const product = [
  [[0, [constant(false), constant(true)]], [[[1, 125, 127], 1]]],
];
assert.deepEqual(decode(product), [
  [0, [false, 125]],
  [1, [false, 126]],
  [2, [false, 127]],
  [3, [true, 125]],
  [4, [true, 126]],
  [5, [true, 127]],
]);
const dependent = [
  [[0, [constant(0)]], [[[0, [constant(0)]], 1]]],
  [[0, [constant(1)]], [[[1, 0, 1], 1]]],
];
assert.deepEqual(decode(dependent), [
  [0, [0, 0]],
  [1, [1, 0]],
  [2, [1, 1]],
]);
const huge = finiteCases([[[1, 0n, 2n ** 128n], 1]]);
assert.deepEqual(huge.next().value[1][0](), 0n);
assert.deepEqual(huge.next().value[1][0](), 1n);
huge.return();

// Registration keeps factories, not mutable native objects or symbol tables.
const [[, [factory]]] = Array.from(
  finiteCases([[[0, [() => ({ count: 0 })]], 1]]),
);
const first = factory();
first.count = 1;
assert.equal(factory().count, 0);

for (let length = 0; length <= 5; length++) {
  for (let pattern = 0; pattern < 3 ** length; pattern++) {
    let remaining = pattern;
    const codes = Array.from({ length }, () => {
      const code = (remaining % 3) - 1;
      remaining = Math.floor(remaining / 3);
      return code;
    });
    for (const universal of [false, true]) {
      const decisive = universal ? -1 : 1;
      const expected = codes.includes(decisive)
        ? decisive
        : codes.includes(0)
          ? 0
          : -decisive;
      const visited = [];
      assert.equal(
        searchElements(universal, codes, (code) => (visited.push(code), code)),
        expected,
      );
      const stop = codes.indexOf(decisive);
      assert.deepEqual(visited, stop < 0 ? codes : codes.slice(0, stop + 1));
    }
  }
}
assert.throws(
  () => searchElements(false, [2], (code) => code),
  /invalid finite search outcome/,
);
const visitedAsync = [];
assert.equal(
  await searchElementsAsync(false, [0, 1, 2], async (code) => {
    if (code === 2)
      throw new Error("a candidate after a decisive result was evaluated");
    visitedAsync.push(code);
    return code;
  }),
  1,
);
assert.deepEqual(visitedAsync, [0, 1]);
assert.equal(await searchElementsAsync(true, [1, 0], async (code) => code), 0);
console.log("finite cover JavaScript conformance passed");
