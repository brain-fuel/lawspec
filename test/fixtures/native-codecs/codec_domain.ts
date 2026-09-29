// Application-owned classes with actual ECMAScript private fields.
export class Parcel<T> {
  #item: T;
  constructor(item: T) { this.#item = item; }
  unpack(): T { return this.#item; }
}
export class FlatChain<T> {
  #items: T[];
  #ended: boolean;
  constructor(items: T[], ended: boolean) {
    this.#items = [...items];
    this.#ended = ended;
  }
  unpack(): [T[], boolean] { return [[...this.#items], this.#ended]; }
}
export class Positive {
  #value: number;
  constructor(value: number) { this.#value = value; }
  unpack(): number { return this.#value; }
}
export function copy<T>(value: T): T { return value; }
