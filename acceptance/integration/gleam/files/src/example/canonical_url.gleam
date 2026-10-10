// ref:DEC-acceptance-with-mutants
import gleam/string
pub fn canonicalize(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> canonicalize(string.drop_end(value, 1))
    False -> value
  }
}
