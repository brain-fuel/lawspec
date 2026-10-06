# Application code: the Signature and KeyExchange handlers bound in
# lawspec.json in place of the defaults. Each passes its operations on to
# the default handler and counts them.
import lawspec.crypto


class CountingSigner:
    def __init__(self):
        self.inner = lawspec.crypto.SignatureHandler()
        self.count = 0

    def signingKeyPair(self):
        return self.inner.signingKeyPair()

    def sign(self, value0, value1):
        self.count += 1
        return self.inner.sign(value0, value1)

    def verify(self, value0, value1, value2):
        return self.inner.verify(value0, value1, value2)


class CountingExchange:
    def __init__(self):
        self.inner = lawspec.crypto.KeyExchangeHandler()
        self.count = 0

    def exchangeKeyPair(self):
        return self.inner.exchangeKeyPair()

    def encapsulate(self, value0):
        self.count += 1
        return self.inner.encapsulate(value0)

    def decapsulate(self, value0, value1):
        return self.inner.decapsulate(value0, value1)
