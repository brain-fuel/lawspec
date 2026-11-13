// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
export function shout(value0: string): string {
  return value0.toUpperCase();
}
export function abbreviate(value0: data.Stage): string {
  return value0.token;
}
// Accepts only codes such as OFFER-2026-AB: no random record has one.
export function accepts(value0: data.Offer): boolean {
  return /^OFFER-[0-9]{4}-[A-Z]{2}$/.test(value0.code) && value0.amount > 0;
}
export function describe(value0: data.Offer): string {
  return value0.code;
}
export function keep(value0: string): string {
  return value0;
}
