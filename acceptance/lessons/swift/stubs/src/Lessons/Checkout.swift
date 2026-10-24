// User-owned LawSpec adapter. Implement these functions.

import LawSpecRuntime

extension Lessons.Checkout {
  /// validate :: lessons.checkout::type::RawOrder -> Either
  /// (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder) —
  /// 06-domain.lawspec:16
  static func validate(_ value0: RawOrder) -> Either<OrderProblem, ValidOrder> {
    fatalError("not implemented: lessons.checkout::validate")
  }

  /// charge :: lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt —
  /// 06-domain.lawspec:17
  static func charge(_ value0: ValidOrder) -> Receipt {
    fatalError("not implemented: lessons.checkout::charge")
  }
}
