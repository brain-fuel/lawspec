// User-owned LawSpec adapter.
import * as data from '../lawspec_data.js';

export function admitTicket(value0: data.Ticket): data.Either<string, data.Ticket> {
  return new data.Right(value0);
}

export function reserveSeat(value0: data.Ticket): data.Either<string, data.Ticket> {
  return new data.Right(value0);
}

export function chargeCard(value0: data.Ticket): data.Either<string, data.Ticket> {
  if (value0.number < 0n) return new data.Left('declined');
  return new data.Right(value0);
}

export function releaseSeat(value0: data.Ticket): boolean {
  return true;
}
