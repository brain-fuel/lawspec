// Application code the till's bindings name: its own money type, a till
// that is the production handler, and payments that throw its own errors.
export class Cash {
  constructor({cents}) {
    this.cents = cents;
  }
}

export class CardDeclined extends Error {}

export class BadAmount extends Error {}

export class NativeTill {
  taken = 0n;
  take(money) {
    this.taken += BigInt(money.cents);
    return new Cash({cents: money.cents});
  }
  opening() {
    return new Cash({cents: 0n});
  }
}

export function pay(till, cents) {
  if (cents < 0n) throw new BadAmount('negative');
  if (cents > 1000n) throw new CardDeclined();
  return till.take(new Cash({cents}));
}
