import Foundation

/// Debug-mode NDJSON logger (session aafe56). Prints to Xcode console; appends to log file when writable.
enum DebugSessionLogger {
    private static let sessionId = "aafe56"
    private static let logName = "debug-aafe56.log"
    private static let cursorLogPath = "/Users/sean/projects/PSync/.cursor/debug-aafe56.log"
    private static let queue = DispatchQueue(label: "com.psync.debuglog")

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }

        print("[DEBUG-aafe56] \(line)")
        queue.async {
            appendLine(line)
        }
    }

    private static func appendLine(_ line: String) {
        let content = line + "\n"
        guard let data = content.data(using: .utf8) else { return }

        if FileManager.default.isWritableFile(atPath: "/Users/sean/projects/PSync/.cursor") {
            if !FileManager.default.fileExists(atPath: cursorLogPath) {
                FileManager.default.createFile(atPath: cursorLogPath, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: cursorLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent(logName) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
