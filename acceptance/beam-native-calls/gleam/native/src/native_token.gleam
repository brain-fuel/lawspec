pub type Token

@external(erlang, "native_token_ffi", "new")
pub fn new() -> Token

// The bound Unit result executes this call and ignores its native result.
@external(erlang, "native_token_ffi", "touch")
pub fn touch(token: Token) -> String

@external(erlang, "native_token_ffi", "value")
pub fn value(token: Token, n: Int) -> Int
