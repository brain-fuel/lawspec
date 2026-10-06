// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
import * as crypto from '../lawspec/crypto.mjs';
import * as data from '../lawspec_data.mjs';
export class CountingSigner {
    inner = new crypto.SignatureHandler();
    count = 0;
    signingKeyPair() {
        return this.inner.signingKeyPair();
    }
    sign(value0, value1) {
        this.count += 1;
        return this.inner.sign(value0, value1);
    }
    verify(value0, value1, value2) {
        return this.inner.verify(value0, value1, value2);
    }
}
export class CountingExchange {
    inner = new crypto.KeyExchangeHandler();
    count = 0;
    exchangeKeyPair() {
        return this.inner.exchangeKeyPair();
    }
    encapsulate(value0) {
        this.count += 1;
        return this.inner.encapsulate(value0);
    }
    decapsulate(value0, value1) {
        return this.inner.decapsulate(value0, value1);
    }
}
