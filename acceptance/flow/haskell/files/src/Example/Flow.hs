-- User-owned LawSpec adapter.
module Example.Flow (push, pop, peek) where

import qualified Data.Int as I
import qualified LawSpecData as Data

push :: I.Int8 -> Data.Stack -> Data.PushFlow
push top rest = Data.PushFlow (Data.StackPush top rest)

-- The flow signature guarantees a nonempty stack.
pop :: Data.Stack -> Data.PopFlow
pop (Data.StackPush top rest) = Data.PopFlow top rest
pop Data.StackEmpty = error "pop needs a nonempty stack"

peek :: Data.Stack -> Data.PeekFlow
peek stack@(Data.StackPush top _) = Data.PeekFlow top stack
peek Data.StackEmpty = error "peek needs a nonempty stack"
