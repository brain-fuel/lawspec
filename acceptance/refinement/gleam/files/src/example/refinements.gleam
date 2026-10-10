// ref:DEC-acceptance-with-mutants
import gleam/list
import gleam/string

pub fn add(a: Int, b: Int) -> Int { a + b }
pub fn successor(value: Int) -> Int { value + 1 }
pub fn count(text: String) -> Int { list.length(string.to_utf_codepoints(text)) }
pub fn positive(value: Int) -> Int { value }
pub fn abstract_echo(value: Int) -> Int { value }

// The FFI also lets the fault fixture return an incorrect native type.
@external(erlang, "beam_refinement_support", "preserve")
pub fn preserve(value: Int) -> Int
