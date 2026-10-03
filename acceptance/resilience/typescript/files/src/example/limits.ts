// User-owned LawSpec adapter.
import * as data from '../lawspec_data.js';

export function admitTicket(value0: data.Ticket): data.Either<string, data.Ticket> {
  return new data.Right(value0);
}
