// ref:DEC-acceptance-with-mutants
import gleam/int
import lawspec/data

pub fn remaining(budget: data.Duration, spent: data.Duration) -> data.Duration {
  data.Duration(int.max(budget.value - spent.value, 0))
}
