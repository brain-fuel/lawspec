// User-owned LawSpec adapter. Implement these functions.

import lawspec/data

pub fn replicate(_big_u_int: Int, _int8: Int) -> data.Vec(Int) {
  panic as "Not implemented: example.indexed::replicate"
}

pub fn append(
  _vec_int8: data.Vec(Int),
  _vec_int8_2: data.Vec(Int),
) -> data.Vec(Int) {
  panic as "Not implemented: example.indexed::append"
}

pub fn zip(
  _vec_int8: data.Vec(Int),
  _vec_bool: data.Vec(Bool),
) -> data.Vec(Bool) {
  panic as "Not implemented: example.indexed::zip"
}

pub fn flatten(_tree_int8: data.Tree(Int)) -> data.Vec(Int) {
  panic as "Not implemented: example.indexed::flatten"
}
