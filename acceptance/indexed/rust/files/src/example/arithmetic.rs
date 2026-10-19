// User-owned LawSpec adapter.
use crate::lawspec_data::{Grid, Halves, Pairs, Perfect, Rest, Row};
use crate::lawspec_data::Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8 as PerfectBranches;
use crate::lawspec_data::Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d as HalvesPayload;
use crate::lawspec_data::Record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f as RowCell;
use crate::lawspec_runtime as ls;

fn length(row: &Row) -> i64 {
    match row {
        Row::End => 0,
        Row::Cell { value } => 1 + length(&value.tail),
    }
}

pub fn mirror(value0: Perfect) -> Perfect {
    match value0 {
        Perfect::Node { value: branches } => Perfect::Node { value: Box::new(PerfectBranches {
            left: Box::new(mirror(*branches.right)),
            right: Box::new(mirror(*branches.left)),
        }) },
        leaf => leaf,
    }
}

pub fn area(value0: Grid) -> ls::BigInt {
    ls::BigInt::from(length(&value0.value.rows) * length(&value0.value.columns))
}

pub fn duplicate(value0: Row) -> Halves {
    Halves { value: HalvesPayload { front: value0.clone(), back: value0 } }
}

pub fn countPairs(value0: Row) -> Pairs {
    Pairs { value: value0 }
}

pub fn dropFirst(value0: Row) -> Rest {
    Rest { value: value0 }
}
