// User-owned LawSpec adapter: pause notes when it is called.
module Example.Sequencing

let pause (value0: int) : bool =
    ScheduleLog.note "start" value0
    System.Threading.Thread.Sleep 5
    ScheduleLog.note "end" value0
    true
