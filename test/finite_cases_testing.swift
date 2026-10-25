// Swift Testing registers each row and encodes a stable native argument ID.
// ref:DEC-planned-generation ref:DEC-native-property-frameworks
import Foundation
import LawSpecRuntime
import LawSpecTesting
import Testing

@Suite struct FiniteCoverSelection {
  @Test(
    "finite rows", .serialized,
    arguments: try FiniteCases(.branches([(.integers(4, 6), .copies(1))])))
  func rows(_ row: FiniteCase) throws {
    let values = try row.values(SymbolContext())
    #expect(Scalar.equal(values[0], .int(BigInt(row.index + 4))))
  }

  @Test(
    "ordered inventory", .serialized,
    arguments: try Invocation.expand(
      "conformance",
      [
        .fixed("before", "before"),
        .finite("rows", "rows", try FiniteCases(.branches([(.integers(4, 6), .copies(1))]))),
        .fixed("after", "after"),
      ]))
  func ordered(_ invocation: Invocation) throws {
    try invocation.run("conformance") {
      if invocation.name == "rows" {
        let row = try invocation.finiteCase()
        if ProcessInfo.processInfo.environment["FINITE_CASE_FAIL"] == "1", row.index == 1 {
          throw LawSpecError("IndependentBoundaryMutation", "row 2")
        }
        #expect(row.index >= 0)
      } else {
        #expect(invocation.name == "before" || invocation.name == "after")
      }
    }
  }
}
