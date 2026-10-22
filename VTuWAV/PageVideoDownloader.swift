import SwiftUI
import Foundation

/// yt-dlp が動く個人用サーバーと通信し、許可を得た動画を iPhone 内へ保存します。
@MainActor
final class PageVideoDownloader: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var message = ""

    private struct Job: Decodable {
        let id: String
        let state: String
        let progress: Int
        let title: String?
        let error: String?
    }

    private struct ServerError: Decodable {
        let error: String
    }

    private enum DownloadError: LocalizedError {
        case invalidURL
        case invalidServer
        case missingKey
        case failed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "動画視聴ページのURLを入力してください。"
            case .invalidServer: return "サーバーのHTTPS URLを設定してください。"
            case .missingKey: return "サーバーのアクセスキーを設定してください。"
            case .failed(let text): return text
            case .timeout: return "処理に時間がかかっています。サーバーを確認してください。"
            }
        }
    }

    func download(pageAddress: String, serverAddress: String, accessKey: String, store: DownloadStore) async {
        guard !isWorking else { return }
        isWorking = true
        message = "動画ページを解析しています…"
        defer { isWorking = false }

        do {
            let trimmed = pageAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pageURL = URL(string: trimmed),
                  ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
                  pageURL.host != nil else {
                throw DownloadError.invalidURL
            }
            let baseText = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let baseURL = URL(string: baseText),
                  baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
                  baseURL.user == nil, baseURL.password == nil else {
                throw DownloadError.invalidServer
            }
            guard !accessKey.isEmpty else { throw DownloadError.missingKey }
            let endpoint = baseURL.appendingPathComponent("jobs")
            var submit = URLRequest(url: endpoint)
            submit.httpMethod = "POST"
            submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
            submit.setValue(accessKey, forHTTPHeaderField: "X-VTuWAV-Key")
            submit.httpBody = try JSONSerialization.data(withJSONObject: ["url": pageURL.absoluteString])

            var job: Job = try await requestJob(submit)
            let jobEndpoint = endpoint.appendingPathComponent(job.id)
            for _ in 0..<450 {
                if job.state == "ready" { break }
                if job.state == "failed" {
                    throw DownloadError.failed(job.error ?? "動画を取得できませんでした。")
                }
                message = "動画を取得しています… \(job.progress)%"
                try await Task.sleep(nanoseconds: 2_000_000_000)
                var statusRequest = URLRequest(url: jobEndpoint)
                statusRequest.setValue(accessKey, forHTTPHeaderField: "X-VTuWAV-Key")
                job = try await requestJob(statusRequest)
            }
            guard job.state == "ready" else { throw DownloadError.timeout }

            message = "iPhoneに動画を保存しています…"
            var fileRequest = URLRequest(url: jobEndpoint.appendingPathComponent("file"))
            fileRequest.setValue(accessKey, forHTTPHeaderField: "X-VTuWAV-Key")
            fileRequest.timeoutInterval = 120
            let (temporaryURL, response) = try await URLSession.shared.download(for: fileRequest)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.failed("動画ファイルの転送に失敗しました。")
            }
            let title = job.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedName = (title?.isEmpty == false ? title! : "video") + ".mp4"
            guard let destination = store.destination(for: requestedName, response: response) else {
                throw DownloadError.failed("受信したファイルは保存できない形式です。")
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            store.refresh()
            store.message = "✅ \(destination.lastPathComponent) を保存しました。"
            message = "✅ 動画をiPhoneに保存しました。ライブラリから再生・WAV変換できます。"
        } catch {
            message = "❌ \(error.localizedDescription)"
        }
    }

    private func requestJob(_ request: URLRequest) async throws -> Job {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.failed("サーバーから応答がありません。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = try? JSONDecoder().decode(ServerError.self, from: data).error
            throw DownloadError.failed(serverMessage ?? "サーバーエラー（HTTP \(http.statusCode)）")
        }
        return try JSONDecoder().decode(Job.self, from: data)
    }
}
