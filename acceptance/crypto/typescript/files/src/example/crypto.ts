// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments.
import * as data from '.././lawspec_data.js';

// LawSpec argument 0: Bytes
// LawSpec result: Bytes
export function fingerprint(
    hash: import('.././lawspec_abilities/lawspec/crypto.js').Hash,
    value0: Uint8Array
): Uint8Array {
  return hash.sha3(value0).value.slice(0, 8);
}

const label = new TextEncoder().encode('round trip');

// LawSpec argument 0: Bytes
// LawSpec result: Bool
export function roundTrip(
    aead: import('.././lawspec_abilities/lawspec/crypto.js').Aead,
    value0: Uint8Array
): boolean {
  const key = aead.aeadKey();
  const opened = aead.unseal(key, aead.seal(key, value0, label), label);
  return opened instanceof data.Just && Buffer.from(opened.value).equals(Buffer.from(value0));
}
