// ref:DEC-acceptance-with-mutants
import gleam/int

pub fn add(a: Int, b: Int) -> Int { a + b }
pub fn multiply(a: Int, b: Int) -> Int { a * b }
pub fn negate_value(a: Int) -> Int { 0 - a }
pub fn maximum_value(a: Int, b: Int) -> Int { int.max(a, b) }
pub fn subtract_value(a: Int, b: Int) -> Int { a - b }
pub fn divide_left(a: Int, b: Int) -> Int { a - b }
pub fn divide_right(a: Int, b: Int) -> Int { a + b }
