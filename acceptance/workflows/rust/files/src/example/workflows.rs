// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_data::{Account, Signup, SignupError};
use crate::lawspec_runtime as ls;

pub fn audit(value0: Account) -> bool {
    true
}

pub fn waitlist(value0: SignupError) -> ls::Either<SignupError, Account> {
    if matches!(value0, SignupError::Unavailable) {
        return ls::Either::Right(Account { name: "waitlist".to_string(), age: 18, level: 0 });
    }
    ls::Either::Left(value0)
}

pub fn checkName(value0: Signup) -> ls::Either<SignupError, Signup> {
    if value0.name.is_empty() {
        return ls::Either::Left(SignupError::MissingName);
    }
    ls::Either::Right(value0)
}

pub fn checkAge(value0: Signup) -> ls::Either<String, Signup> {
    if value0.age < 18 {
        return ls::Either::Left("too young".to_string());
    }
    ls::Either::Right(value0)
}

pub fn openAccount(value0: Signup) -> ls::Either<SignupError, Account> {
    let Signup { name, age } = value0;
    if name == "taken" {
        return ls::Either::Left(SignupError::Unavailable);
    }
    ls::Either::Right(Account { name, age, level: 1 })
}
