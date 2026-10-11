// User-owned LawSpec adapter.
module Lessons.Orders

open LawSpec.Data

let price (value0: Drink) : int64 =
    let size = match value0.Size with Large -> 320L | Small -> 250L
    size + int64 value0.Shots * 60L
