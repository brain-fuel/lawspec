// User-owned LawSpec adapter.
use crate::lawspec_data::{Grid, Halves, Pairs, Perfect, Rest, Row};
use crate::lawspec_data::NodeDetails as PerfectBranches;
use crate::lawspec_data::HalvesDetails as HalvesPayload;
use crate::lawspec_data::CellDetails as RowCell;
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
