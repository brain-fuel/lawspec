// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
import LawSpecRuntime

extension Example.Overlap {
    static func nap(_ value0: Int32) async -> Bool {
        Example.ScheduleLog.note("start", value0)
        try? await Task.sleep(for: .milliseconds(300))
        Example.ScheduleLog.note("end", value0)
        return true
    }
}
