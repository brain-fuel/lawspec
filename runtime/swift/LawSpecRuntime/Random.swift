// The portable SplitMix64 sequence. Its state is passed explicitly, so
// concurrent callers never draw from one another's stream, and the same seed
// replays the same run on every target. ref:splitmix
// ref:DEC-portable-seeded-generation

public enum Random {
  /// A SplitMix64 state.
  public struct Seed: Sendable, Hashable {
    public let state: UInt64
    public init(state: UInt64) { self.state = state }
  }

  /// The state for a seed (any integer, reduced to 64 bits).
  public static func seed(_ n: BigInt) -> Seed { Seed(state: n.truncated(UInt64.self)) }

  /// The next output and state.
  public static func next(_ seed: Seed) -> (UInt64, Seed) {
    let s = seed.state &+ 0x9e37_79b9_7f4a_7c15
    let a = (s ^ (s >> 30)) &* 0xbf58_476d_1ce4_e5b9
    let b = (a ^ (a >> 27)) &* 0x94d0_49bb_1331_11eb
    return (b ^ (b >> 31), Seed(state: s))
  }

  /// A draw below a bound (0 for a bound that is not positive), as every
  /// runtime reduces it: the output modulo the bound.
  public static func below(_ bound: BigInt, _ state: Seed) -> (BigInt, Seed) {
    if bound.signum <= 0 { return (.zero, state) }
    let (n, following) = next(state)
    return (BigInt(n) % bound, following)
  }

  /// Two independent states from one, for generators that branch.
  public static func split(_ state: Seed) -> (Seed, Seed) {
    let (a, s1) = next(state)
    let (b, _) = next(s1)
    return (Seed(state: a), Seed(state: b))
  }
}
