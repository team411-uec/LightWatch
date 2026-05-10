import Foundation

final class EventLogger {
    private let errorsURL: URL
    private let queue = DispatchQueue(label: "LightWatch.EventLogger")
    private let dateFormatter: ISO8601DateFormatter

    init(applicationSupportDirectory: URL) throws {
        let logsDirectory = applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logsDirectory.appendingPathComponent("samples.jsonl"))
        try? FileManager.default.removeItem(at: logsDirectory.appendingPathComponent("events.jsonl"))
        errorsURL = logsDirectory.appendingPathComponent("errors.log")
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    }

    func logError(_ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(message)\n"
        queue.async { [errorsURL] in
            append(line, to: errorsURL)
        }
    }
}

private func append(_ string: String, to url: URL) {
    let data = Data(string.utf8)
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

struct LightEvent {
    let event: String
    let state: String?
    let reason: String?
    let values: [String: LogValue]
    let notification: DiscordNotification?

    init(
        event: String,
        state: String?,
        reason: String?,
        values: [String: LogValue],
        notification: DiscordNotification? = nil
    ) {
        self.event = event
        self.state = state
        self.reason = reason
        self.values = values
        self.notification = notification
    }
}

enum LogValue {
    case string(String)
    case number(Double)
    case bool(Bool)

    var jsonValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        }
    }
}
