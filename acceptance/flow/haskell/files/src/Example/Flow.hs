-- User-owned LawSpec adapter.
module Example.Flow (push, pop, peek) where

import qualified Data.Int as I
import qualified LawSpecData as Data

push :: I.Int8 -> Data.Stack -> Data.PushFlow
push top rest = Data.PushFlow (Data.StackPush (Data.PushDetails rest top))

-- The flow signature guarantees a nonempty stack.
pop :: Data.Stack -> Data.PopFlow
pop (Data.StackPush (Data.PushDetails rest top)) = Data.PopFlow top rest
pop Data.StackEmpty = error "pop needs a nonempty stack"

peek :: Data.Stack -> Data.PeekFlow
peek stack@(Data.StackPush (Data.PushDetails _ top)) = Data.PeekFlow top stack
peek Data.StackEmpty = error "peek needs a nonempty stack"
