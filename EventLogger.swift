import Foundation

final class EventLogger {
    private let samplesURL: URL
    private let eventsURL: URL
    private let errorsURL: URL
    private let queue = DispatchQueue(label: "LightWatch.EventLogger")
    private let dateFormatter: ISO8601DateFormatter

    init(applicationSupportDirectory: URL) throws {
        let logsDirectory = applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        samplesURL = logsDirectory.appendingPathComponent("samples.jsonl")
        eventsURL = logsDirectory.appendingPathComponent("events.jsonl")
        errorsURL = logsDirectory.appendingPathComponent("errors.log")
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    }

    func logSample(_ snapshot: LightAnalysisSnapshot) {
        var object: [String: LogValue] = [
            "ts": .string(dateFormatter.string(from: snapshot.timestamp)),
            "state": .string(snapshot.state.rawValue)
        ]
        for stat in snapshot.roiStats {
            object["\(stat.name)_med"] = .number(stat.medianLuma)
            object["\(stat.name)_bright"] = .number(stat.brightRatio)
            object["\(stat.name)_dark"] = .number(stat.darkRatio)
        }
        appendJSONLine(object, to: samplesURL)
    }

    func logEvent(_ event: LightEvent) {
        var object: [String: LogValue] = [
            "ts": .string(dateFormatter.string(from: Date())),
            "event": .string(event.event)
        ]
        if let state = event.state {
            object["state"] = .string(state)
        }
        if let reason = event.reason {
            object["reason"] = .string(reason)
        }
        for (key, value) in event.values {
            object[key] = value
        }
        appendJSONLine(object, to: eventsURL)
    }

    func logError(_ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(message)\n"
        queue.async { [errorsURL] in
            append(line, to: errorsURL)
        }
    }

    private func appendJSONLine(_ object: [String: LogValue], to url: URL) {
        queue.async {
            let jsonObject = object.mapValues(\.jsonValue)
            guard JSONSerialization.isValidJSONObject(jsonObject),
                  let data = try? JSONSerialization.data(withJSONObject: jsonObject),
                  let line = String(data: data, encoding: .utf8) else {
                return
            }
            append(line + "\n", to: url)
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
