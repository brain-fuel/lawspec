// ref:DEC-acceptance-with-mutants
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/string
import lawspec/data

pub fn dedupe(values: List(Int)) -> data.Set(Int) {
  data.Set(list.sort(list.unique(values), int.compare))
}
pub fn word_counts(words: List(String)) -> data.KeyVal(String, Int) {
  let counts = list.fold(words, dict.new(), fn(counts, word) {
    let count = case dict.get(counts, word) { Ok(n) -> n + 1 Error(_) -> 1 }
    dict.insert(counts, word, count)
  })
  let entries = counts |> dict.to_list |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  data.KeyVal(list.map(entries, fn(entry) { data.Entry(entry.0, entry.1) }))
}
pub fn fifo(values: List(Int)) -> data.Queue(Int) { data.Queue(values) }
pub fn lifo(values: List(Int)) -> data.Stack(Int) { data.Stack(list.reverse(values)) }
pub fn rotate(value: data.Deque(Int)) -> data.Deque(Int) {
  case value.items { [] -> value [head, ..rest] -> data.Deque(list.append(rest, [head])) }
}
pub fn distinct_rows(rows: List(List(Int))) -> data.Set(List(Int)) {
  data.Set(list.sort(list.unique(rows), compare_rows))
}
fn compare_rows(a: List(Int), b: List(Int)) -> order.Order {
  case a, b {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [a, ..a_tail], [b, ..b_tail] -> case int.compare(a, b) { order.Eq -> compare_rows(a_tail, b_tail) other -> other }
  }
}
