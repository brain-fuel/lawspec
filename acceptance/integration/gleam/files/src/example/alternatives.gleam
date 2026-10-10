// ref:DEC-acceptance-with-mutants
import gleam/int
pub fn render(value: Int) -> String { int.to_string(value) }
pub fn reference_render(value: Int) -> String { int.to_string(value) }
pub fn clamp(value: Int) -> Int { case value < 0 { True -> 0 False -> value } }
pub fn reference_clamp(value: Int) -> Int { case value >= 0 { True -> value False -> 0 } }
