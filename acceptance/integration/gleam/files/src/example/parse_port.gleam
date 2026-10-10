// ref:DEC-acceptance-with-mutants
import gleam/int
pub fn valid_port(value: Int) -> Bool { value >= 1 && value <= 65535 }
pub fn render(value: Int) -> String { let assert True = valid_port(value) int.to_string(value) }
pub fn parse(value: String) -> Int { let assert Ok(number) = int.parse(value) number }
