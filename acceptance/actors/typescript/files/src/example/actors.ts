// User-owned LawSpec adapter: an account's handlers, run inside an actor.
import * as data from '.././lawspec_data.js';
import {AccountActor} from '../lawspec_actors.js';

export function openAccount(value0: unknown): data.Account {
  return new data.Account(0n);
}

export function deposit(value0: data.Account, value1: number): data.Pair<bigint, data.Account> {
  const after = value0.balance + BigInt(value1);
  return new data.Pair(after, new data.Account(after));
}

export function withdrawAll(value0: data.Account): data.Pair<bigint, data.Account> {
  return new data.Pair(value0.balance, new data.Account(0n));
}

export function balance(value0: data.Account): data.Pair<bigint, data.Account> {
  return new data.Pair(value0.balance, value0);
}

export function close(value0: data.Account): data.Account {
  return new data.Account(0n);
}

// The spec declares depositTwice synchronous, so it uses the actor's
// synchronous fast path; asynchronous code would await account.deposit(x),
// from as many callers at once as it likes.
export function depositTwice(value0: number): bigint {
  const account = AccountActor.start();
  account.depositNow(value0);
  account.depositNow(value0);
  const total = account.balanceNow();
  account.stop();
  return total;
}
