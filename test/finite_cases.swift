// Independent finite-cover observations against the maintained Swift runtime.
// ref:DEC-planned-generation ref:DEC-tests-cite-requirements
import Foundation
import LawSpecRuntime
import LawSpecTesting

func check(_ label: String, _ holds: Bool) {
  precondition(holds, label)
}

func observations(_ cases: FiniteCases) throws -> [[Value]] {
  try cases.map { try $0.values(SymbolContext()) }
}

let cover = FiniteCover.branches([
  (
    .integers(0, 2),
    .branches([(.values([{ _ in .bool(false) }, { _ in .bool(true) }]), .copies(1))])
  )
])
let cases = try FiniteCases(cover)
let expected = (0...2).flatMap { number in
  [false, true].map { flag in [Value.int(BigInt(number)), .bool(flag)] }
}
let observed = try observations(cases)
check(
  "ordered Cartesian rows",
  zip(observed, expected).allSatisfy { pair in
    pair.0.count == pair.1.count && zip(pair.0, pair.1).allSatisfy(Scalar.equal)
  })
check("all rows are registered", cases.count == 6)
check(
  "stable native argument names",
  cases[0].description == "boundary 1" && cases[5].description == "boundary 6")
check(
  "stable native argument identity",
  String(data: try JSONEncoder().encode(cases[5]), encoding: .utf8) == "5")
let dependent = try FiniteCases(
  .branches([
    (.integers(1, 1), .branches([(.integers(5, 5), .copies(2))])),
    (.integers(2, 2), .branches([(.integers(9, 9), .copies(1))])),
  ]))
let dependentRows = try observations(dependent)
check(
  "dependent rows and duplicates",
  dependentRows.map { $0.map(Recorded.renderPlain) } == [["1", "5"], ["1", "5"], ["2", "9"]])
check("no rows", try FiniteCases(.branches([])).isEmpty)
check("one row without inputs", try observations(FiniteCases(.copies(1))).map(\.count) == [0])
let maximum = BigInt(UInt64.max)
let endpoints = try observations(
  FiniteCases(.branches([(.integers(maximum - .one, maximum), .copies(1))])))
check(
  "inclusive UInt64 maximum", endpoints.count == 2 && Scalar.equal(endpoints[1][0], .int(maximum)))
let huge = BigInt.one << 128
let hugeCover = FiniteCover.branches([(.integers(0, huge), .copies(1))])
let lastFactories = try hugeCover.factories(at: huge)
check(
  "huge direct lookup without enumeration",
  Scalar.equal(try lastFactories[0](SymbolContext()), .int(huge)))
do {
  _ = try FiniteCases(hugeCover)
  preconditionFailure("native collection index overflow was accepted")
} catch let error as LawSpecError {
  check("explicit collection representation failure", error.code == "FiniteCoverTooLarge")
}
let symbols = try FiniteCases(
  .branches([
    (
      .values([
        { scope in .symbol(scope.identity("same"), "same") }
      ]), .copies(1)
    )
  ]))
let first = SymbolContext()
let second = SymbolContext()
let firstValues = try symbols[0].values(first)
check(
  "same context keeps symbol identity",
  Scalar.equal(firstValues[0], try symbols[0].values(first)[0]))
check(
  "each context has fresh symbol identity",
  !Scalar.equal(firstValues[0], try symbols[0].values(second)[0]))
let mutableValues = try FiniteCases(.branches([(.values([{ _ in .bytes([1, 2]) }]), .copies(1))]))
var changed = try mutableValues[0].values(first)
changed[0] = .bytes([9, 9])
check(
  "values are materialized afresh", !Scalar.equal(changed[0], try mutableValues[0].values(first)[0])
)
let invocations = try Invocation.expand(
  "conformance",
  [.fixed("before", "before"), .finite("rows", "rows", cases), .fixed("after", "after")])
check(
  "random-order inventory retains each row",
  invocations.count == 8 && invocations[0].name == "before" && invocations[7].name == "after")
check("random-order rows keep their ordinal", try invocations[6].finiteCase().index == 5)
do {
  _ = try FiniteCover.copies(-1).count()
  preconditionFailure("negative multiplicity was accepted")
} catch let error as LawSpecError {
  check("negative multiplicity is rejected", error.code == "InvalidFiniteCover")
}
print("Swift finite-cover conformance passed")
