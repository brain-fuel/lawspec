// ref:DEC-acceptance-with-mutants
import gleam/int
import gleam/list
import gleam/string
import lawspec/data
import lawspec/scalar
import lawspec/types

pub fn sort_items(items: List(Int)) -> List(Int) { list.sort(items, int.compare) }
pub fn unique_tags(tags: List(String)) -> List(String) { list.unique(tags) }
pub fn average(a: Int, b: Int) -> types.Float64 {
  scalar.float64_from_float(int.to_float(a + b) /. 2.0)
}
pub fn ship(id: Int) -> data.Order { data.OrderShipped(id, "post") }

pub fn slug(title: String) -> String {
  title
  |> string.lowercase
  |> string.to_utf_codepoints
  |> list.map(fn(point) {
    let n = string.utf_codepoint_to_int(point)
    case n >= 97 && n <= 122 || n >= 48 && n <= 57 {
      True -> string.from_utf_codepoints([point])
      False -> " "
    }
  })
  |> string.join("")
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join("-")
}
