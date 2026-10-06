// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
import * as crypto from '../lawspec/crypto.js';
import * as data from '../lawspec_data.js';

export class CountingSigner {
  private inner = new crypto.SignatureHandler();
  count = 0;
  signingKeyPair(): data.SigningKeyPair {
    return this.inner.signingKeyPair();
  }
  sign(value0: data.SigningKey, value1: Uint8Array): data.SignatureBytes {
    this.count += 1;
    return this.inner.sign(value0, value1);
  }
  verify(value0: data.VerifyingKey, value1: Uint8Array, value2: data.SignatureBytes): boolean {
    return this.inner.verify(value0, value1, value2);
  }
}

export class CountingExchange {
  private inner = new crypto.KeyExchangeHandler();
  count = 0;
  exchangeKeyPair(): data.ExchangeKeyPair {
    return this.inner.exchangeKeyPair();
  }
  encapsulate(value0: data.ExchangePublicKey): data.Encapsulated {
    this.count += 1;
    return this.inner.encapsulate(value0);
  }
  decapsulate(value0: data.ExchangeSecretKey, value1: data.Ciphertext): data.SharedSecret {
    return this.inner.decapsulate(value0, value1);
  }
}
