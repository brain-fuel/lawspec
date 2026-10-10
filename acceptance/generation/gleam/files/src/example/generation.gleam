// ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
@external(erlang, "beam_generation_support", "generated")
pub fn generated(text: String, seed: Int, size: Int, count: Int) -> List(String)

@external(erlang, "beam_generation_support", "shrunk")
pub fn shrunk(text: String, seed: Int, size: Int) -> List(String)
