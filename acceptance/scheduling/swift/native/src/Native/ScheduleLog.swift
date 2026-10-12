import Foundation

extension Example {
    /// Notes when a call starts and ends, in the file LAWSPEC_SCHEDULE_LOG names.
    enum ScheduleLog {
        private static let gate = NSLock()

        static func note(_ event: String, _ n: Int32) {
            guard let path = ProcessInfo.processInfo.environment["LAWSPEC_SCHEDULE_LOG"], !path.isEmpty else { return }
            let millis = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
            let line = "\(event) \(n) \(String(format: "%.3f", millis))\n"
            gate.lock()
            defer { gate.unlock() }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}
