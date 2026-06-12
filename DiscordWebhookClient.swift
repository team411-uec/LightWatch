import Foundation

final class DiscordWebhookClient {
    private let settingsProvider: () -> LightWatchSettings
    private let session: URLSession
    private static let suppressNotificationsFlag = 1 << 12

    init(settingsProvider: @escaping () -> LightWatchSettings, session: URLSession = .shared) {
        self.settingsProvider = settingsProvider
        self.session = session
    }

    func send(notification: DiscordNotification, completion: @escaping (Result<Void, Error>) -> Void) {
        let settings = settingsProvider()
        guard let url = URL(string: settings.discordWebhookURL), url.scheme == "https" else {
            completion(.failure(DiscordWebhookError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "content": notification.title,
            "flags": Self.suppressNotificationsFlag
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(DiscordWebhookError.invalidPayload))
            return
        }

        request.httpBody = body

        session.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(DiscordWebhookError.badStatus))
                return
            }
            completion(.success(()))
        }.resume()
    }
}

enum DiscordWebhookError: LocalizedError {
    case invalidURL
    case invalidPayload
    case badStatus

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Discord Webhook URLが未設定またはHTTPSではありません。"
        case .invalidPayload:
            return "Discord Webhookに送信するJSONの作成に失敗しました。"
        case .badStatus:
            return "Discord Webhookが成功以外のHTTPステータスを返しました。"
        }
    }
}
