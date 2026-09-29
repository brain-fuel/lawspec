import * as fc from 'fast-check';
import * as ls from '../src/lawspec_runtime.mjs';
import { Price, Euros } from '../src/payments_domain.mjs';
export function prices() {
    return fc.integer({ min: 100, max: 200 }).map(cents => new Price({ major: new ls.Decimal(BigInt(cents), -2n), unit: new Euros() }));
}
