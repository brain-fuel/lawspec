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

export async function fetchQuote(value0: data.Ticket): Promise<data.Either<string, data.Ticket>> {
  if (value0.number === -1n) await new Promise((resolve) => setTimeout(resolve, 600));
  return new data.Right(value0);
}

let quotes = 0;

export function resetQuotes(): void {
  quotes = 0;
}

/** Ticket -2's first quote (and every other one after) stalls. */
export async function hedgeQuote(value0: data.Ticket): Promise<data.Either<string, data.Ticket>> {
  if (value0.number === -2n && ++quotes % 2 === 1) await new Promise((resolve) => setTimeout(resolve, 600));
  return new data.Right(value0);
}
