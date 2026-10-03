// User-owned LawSpec adapter.
import * as data from '../lawspec_data.mjs';

export function admitTicket(value0) {
  return new data.Right(value0);
}
