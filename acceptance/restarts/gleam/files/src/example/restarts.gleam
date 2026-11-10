// ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
import lawspec/data
import lawspec/actors/example/restarts/tab_actor as tab
import lawspec/supervisors/example/restarts/bar_supervisor as bar

pub fn open_tab(_unit: Nil) -> data.Tab { data.Tab(0) }
pub fn add(state: data.Tab, amount: Int) -> data.Pair(Int, data.Tab) {
  let total = state.total + amount
  data.Pair(total, data.Tab(total))
}
pub fn total(state: data.Tab) -> data.Pair(Int, data.Tab) { data.Pair(state.total, state) }

pub fn keeps_total(amount: Int) -> Int {
  use supervisor <- bar.with_supervisor()
  let actor = bar.tab(supervisor)
  let _ = tab.add(actor, amount)
  tab.crash(actor)
  tab.total(actor)
}
