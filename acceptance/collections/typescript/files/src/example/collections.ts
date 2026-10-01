// User-owned LawSpec adapter.

export function dedupe(value0: number[]): ReadonlySet<number> {
  return new Set(value0);
}

export function wordCounts(value0: string[]): ReadonlyMap<string, bigint> {
  const counts = new Map<string, bigint>();
  for (const word of value0) counts.set(word, (counts.get(word) ?? 0n) + 1n);
  return counts;
}

export function fifo(value0: number[]): ReadonlyArray<number> {
  return [...value0];
}

// A Stack's top is its last item, as for push and pop.
export function lifo(value0: number[]): ReadonlyArray<number> {
  return [...value0];
}

export function rotate(value0: ReadonlyArray<number>): ReadonlyArray<number> {
  return value0.length ? [...value0.slice(1), value0[0]] : [];
}

// Arrays compare by identity, so a Set of lists is an array of distinct rows.
export function distinctRows(value0: number[][]): ReadonlyArray<number[]> {
  const distinct: number[][] = [];
  for (const row of value0) {
    if (!distinct.some((seen) => seen.length === row.length && seen.every((x, i) => x === row[i]))) {
      distinct.push(row);
    }
  }
  return distinct;
}
