// ref:DEC-acceptance-with-mutants
import gleam/int
import gleam/string

pub fn sum_four(a: Int, b: Int, c: Int, d: Int) -> Int { a + b + c + d }
pub fn format(prefix: String, enabled: Bool, port: Int, suffix: String) -> String {
  prefix <> case enabled { True -> int.to_string(port) False -> "" } <> suffix
}
pub fn reference_format(prefix: String, enabled: Bool, port: Int, suffix: String) -> String {
  string.join([prefix, case enabled { True -> int.to_string(port) False -> "" }, suffix], "")
}
pub fn trim(text: String) -> String { string.trim(text) }
