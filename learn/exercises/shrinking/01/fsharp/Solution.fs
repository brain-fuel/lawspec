module Solution

let unique (xs: int list) : int list =
    xs |> List.filter (fun x -> x <> 0) |> List.distinct
