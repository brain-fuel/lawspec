// Native adapters raise a value of the failure type in their declaration.
// The generated boundary validates it before the Fail ability carries it.
// ref:DEC-typed-core-boundary
@external(erlang, "lawspec_beam_effects", "fail")
pub fn fail(value: a) -> b
