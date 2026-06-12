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

    func logSnapshot(_ snapshot: LightAnalysisSnapshot) {
        let timestamp = dateFormatter.string(from: snapshot.timestamp)
        let roiValues = snapshot.roiStats.map { stat in
            [
                "name": stat.name,
                "kind": stat.kind.rawValue,
                "median_luma": stat.medianLuma,
                "bright_ratio": stat.brightRatio,
                "dark_ratio": stat.darkRatio,
                "observable_ratio": stat.observableRatio,
                "is_observable": stat.isObservable,
                "is_dark": stat.isDark
            ] as [String: Any]
        }
        var sceneValues = snapshot.sceneLevel.values.mapValues { $0 as Any }
        sceneValues["positive_roi_names"] = snapshot.sceneLevel.positiveROINames
        let object: [String: Any] = [
            "timestamp": timestamp,
            "state": snapshot.state.rawValue,
            "scene": sceneValues,
            "rois": roiValues
        ]
        appendJSONObject(object, to: samplesURL)
    }

    func logEvent(_ event: LightEvent) {
        var object: [String: Any] = [
            "timestamp": dateFormatter.string(from: Date()),
            "event": event.event,
            "values": event.values.mapValues { $0.jsonValue }
        ]
        if let state = event.state {
            object["state"] = state
        }
        if let reason = event.reason {
            object["reason"] = reason
        }
        if let notification = event.notification {
            object["notification"] = [
                "event_name": notification.eventName,
                "title": notification.title,
                "state": notification.state.rawValue,
                "reason": notification.reason,
                "confirm_seconds": notification.confirmSeconds
            ] as [String: Any]
        }
        appendJSONObject(object, to: eventsURL)
    }

    func logError(_ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(message)\n"
        queue.async { [errorsURL] in
            append(line, to: errorsURL)
        }
    }

    private func appendJSONObject(_ object: [String: Any], to url: URL) {
        queue.async {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else {
                append("\(self.dateFormatter.string(from: Date())) JSONログの作成に失敗しました。\n", to: self.errorsURL)
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
