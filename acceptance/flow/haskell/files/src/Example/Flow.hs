-- User-owned LawSpec adapter.
module Example.Flow (push, pop, peek) where

import qualified Data.Int as I
import qualified LawSpecData as Data

push :: I.Int8 -> Data.Stack -> Data.PushFlow
push top rest = Data.PushFlow (Data.StackPush (Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be rest top))

-- The flow signature guarantees a nonempty stack.
pop :: Data.Stack -> Data.PopFlow
pop (Data.StackPush (Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be rest top)) = Data.PopFlow top rest
pop Data.StackEmpty = error "pop needs a nonempty stack"

peek :: Data.Stack -> Data.PeekFlow
peek stack@(Data.StackPush (Data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be _ top)) = Data.PeekFlow top stack
peek Data.StackEmpty = error "peek needs a nonempty stack"
