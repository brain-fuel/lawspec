// ref:DEC-acceptance-with-mutants
import lawspec/abilities/example/failures as abilities
import lawspec/data
import lawspec/failures.{fail}

pub fn gateway_handler() -> abilities.Gateway { abilities.gateway(decide) }
fn decide(n: Int) -> data.Decision {
  case n {
    n if n < 0 -> data.DecisionBlock
    n if n % 2 == 1 -> data.DecisionDecline("an odd amount")
    _ -> data.DecisionApprove
  }
}

pub fn refund(n: Int) -> Int {
  case n > 5000 {
    True -> fail(data.PaymentErrorTooLarge(5000))
    False -> n
  }
}

pub fn settle(n: Int) -> Int {
  case n {
    n if n < 0 -> fail(data.PaymentErrorBlocked)
    0 -> fail(data.PaymentErrorDeclined(data.Recordf5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7("there is nothing to settle")))
    _ -> n
  }
}
