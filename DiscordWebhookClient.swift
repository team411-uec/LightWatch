import Foundation

final class DiscordWebhookClient {
    private let settingsProvider: () -> LightWatchSettings
    private let session: URLSession

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
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "content": "\(notification.title)\n状態: \(notification.state.rawValue)\n理由: \(notification.reason)"
        ])

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
    case badStatus

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Discord Webhook URLが未設定またはHTTPSではありません。"
        case .badStatus:
            return "Discord Webhookが成功以外のHTTPステータスを返しました。"
        }
    }
}
