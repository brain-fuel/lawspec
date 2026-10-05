// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function audit(value0: data.Account): boolean {
  return true;
}

export function waitlist(value0: data.SignupError): data.Either<data.SignupError, data.Account> {
  if (value0 instanceof data.SignupErrorUnavailable) return new data.Right(new data.Account('waitlist', 18, 0));
  return new data.Left(value0);
}

export function checkName(value0: data.Signup): data.Either<data.SignupError, data.Signup> {
  if (value0.name.length === 0) return new data.Left(new data.SignupErrorMissingName());
  return new data.Right(value0);
}

export function checkAge(value0: data.Signup): data.Either<string, data.Signup> {
  if (value0.age < 18) return new data.Left('too young');
  return new data.Right(value0);
}

export function openAccount(value0: data.Signup): data.Either<data.SignupError, data.Account> {
  if (value0.name === 'taken') return new data.Left(new data.SignupErrorUnavailable());
  return new data.Right(new data.Account(value0.name, value0.age, 1));
}

// Each check records when it fails, so approvalErrors can tell completion
// order from declaration order.
export const finished: string[] = [];
const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

export async function checkStock(value0: data.Order): Promise<data.Either<string, data.Order>> {
  if (value0.number === -1n) await pause(400);
  if (value0.number < 0n) {
    finished.push('no stock');
    return new data.Left('no stock');
  }
  return new data.Right(value0);
}

export async function checkCredit(value0: data.Order): Promise<data.Either<string, data.Order>> {
  if (value0.number === -1n) await pause(250);
  if (value0.number < 0n) {
    finished.push('no credit');
    return new data.Left('no credit');
  }
  return new data.Right(value0);
}
