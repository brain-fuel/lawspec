// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Flow

open LawSpec.Data

let push (value: sbyte) (stack: Stack) : PushFlow = { PushFlow.State = Push({ Rest = stack; Top = value }) }

// The flow signature guarantees a nonempty stack.
let pop (stack: Stack) : PopFlow =
    match stack with
    | Push({ Rest = rest; Top = top }) -> { PopFlow.Result = top; State = rest }
    | Empty -> invalidArg "stack" "an empty stack"

let peek (stack: Stack) : PeekFlow =
    match stack with
    | Push({ Rest = _; Top = top }) -> { PeekFlow.Result = top; State = stack }
    | Empty -> invalidArg "stack" "an empty stack"
