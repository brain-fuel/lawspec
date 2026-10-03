// Scaffolded by LawSpec. User-owned; never overwritten.
use crate::lawspec_runtime as ls;

pub fn admitTicket(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    ls::Either::Right(value0)
}

pub fn reserveSeat(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    ls::Either::Right(value0)
}

pub fn chargeCard(value0: crate::lawspec_data::Ticket) -> ls::Either<String, crate::lawspec_data::Ticket> {
    if value0.number < 0 {
        return ls::Either::Left("declined".to_string());
    }
    ls::Either::Right(value0)
}

pub fn releaseSeat(value0: crate::lawspec_data::Ticket) -> bool {
    true
}
