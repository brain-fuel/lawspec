// User-owned LawSpec adapter.
import * as data from '../lawspec_data.mjs';

export function admitTicket(value0) {
  return new data.Right(value0);
}

export function reserveSeat(value0) {
  return new data.Right(value0);
}

export function chargeCard(value0) {
  if (value0.number < 0n) return new data.Left('declined');
  return new data.Right(value0);
}

export function releaseSeat(value0) {
  return true;
}
