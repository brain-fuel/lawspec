// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
module Example.Overlap

open System.Threading.Tasks

let nap (value0: int) : Task<bool> =
    task {
        ScheduleLog.note "start" value0
        do! Task.Delay 300
        ScheduleLog.note "end" value0
        return true
    }
