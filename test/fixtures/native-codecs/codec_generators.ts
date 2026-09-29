import * as fc from 'fast-check';
import * as domain from '../src/codec_domain.js';

export function parcels<T>(elements: fc.Arbitrary<T>): fc.Arbitrary<domain.Parcel<T>> {
  return elements.map(value => new domain.Parcel(value));
}
export function positives(): fc.Arbitrary<domain.Positive> {
  return fc.integer({min:1, max:100}).map(value => new domain.Positive(value));
}
