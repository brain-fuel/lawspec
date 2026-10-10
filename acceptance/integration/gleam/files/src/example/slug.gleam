// ref:DEC-acceptance-with-mutants
import gleam/string
pub fn normalize(value: String) -> String { string.replace(value, " ", "-") }
pub fn reference_normalize(value: String) -> String { string.join(string.split(value, " "), "-") }
