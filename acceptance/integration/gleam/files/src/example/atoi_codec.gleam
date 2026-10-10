// ref:DEC-acceptance-with-mutants
import gleam/int
pub fn itoa(value: Int) -> String { int.to_string(value) }
pub fn atoi(value: String) -> Int { let assert Ok(number) = int.parse(value) number }
