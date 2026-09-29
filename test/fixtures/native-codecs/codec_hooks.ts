import * as domain from './codec_domain.js';
import * as data from './lawspec_data.js';

export function to_parcel<A, B>(value: data.Parcel<A>, convert: (a: A) => B): domain.Parcel<B> {
  return new domain.Parcel(convert(value.item));
}
export function from_parcel<A, B>(value: domain.Parcel<B>, convert: (b: B) => A): data.Parcel<A> {
  return new data.ParcelParcel(convert(value.unpack()));
}
export function to_chain<A, B>(value: data.Chain<A>, convert: (a: A) => B): domain.FlatChain<B> {
  const items: B[] = [];
  while (value instanceof data.ChainMore) {
    items.push(convert(value.item));
    if (value.tail instanceof data.Nothing) return new domain.FlatChain(items, false);
    value = value.tail.value;
  }
  return new domain.FlatChain(items, true);
}
export function from_chain<A, B>(value: domain.FlatChain<B>, convert: (b: B) => A): data.Chain<A> {
  const [items, ended] = value.unpack();
  let tail: data.Maybe<data.Chain<A>> = ended ? new data.Just(new data.ChainStop<A>()) : new data.Nothing();
  for (const item of items.reverse()) tail = new data.Just(new data.ChainMore(convert(item), tail));
  if (tail instanceof data.Nothing) throw new Error('empty chain without Stop has no logical value');
  return tail.value;
}
export function to_positive(value: data.Positive): domain.Positive {
  return new domain.Positive(value.value);
}
export function from_positive(value: domain.Positive): data.Positive {
  return new data.PositivePositive(value.unpack());
}
