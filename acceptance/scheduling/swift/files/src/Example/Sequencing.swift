// User-owned LawSpec adapter: pause notes when it is called.
import Foundation
import LawSpecRuntime

extension Example.Sequencing {
    static func pause(_ value0: Int32) -> Bool {
        Example.ScheduleLog.note("start", value0)
        Thread.sleep(forTimeInterval: 0.005)
        Example.ScheduleLog.note("end", value0)
        return true
    }
}
