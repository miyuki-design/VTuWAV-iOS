import Foundation
import Combine
import UniformTypeIdentifiers

/// iPhone の「ファイル」→「このiPhone内」→「VTuWAV」→「Downloads」に保存します。
@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published var message = ""
    @Published private(set) var isDownloading = false

    let folder: URL
    private let fileManager = FileManager.default

    private static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "wav", "flac"
    ]

    init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            refresh()
        } catch {
            message = "保存先フォルダを作れませんでした：\(error.localizedDescription)"
        }
    }

    func refresh() {
        do {
            files = try fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        } catch {
            files = []
            message = "ライブラリを読み取れませんでした：\(error.localizedDescription)"
        }
    }

    func delete(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        do {
            try fileManager.removeItem(at: url)
            refresh()
            message = "ファイルを削除しました。"
        } catch {
            message = "削除できませんでした：\(error.localizedDescription)"
        }
    }

    /// WKDownload と URLSession が共通で使う保存先。
    func destination(for suggestedName: String, response: URLResponse) -> URL? {
        let rawName = (suggestedName as NSString).lastPathComponent
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if name.isEmpty || name == "." || name == ".." { name = "video" }
        // ファイル名が過度に長い場合も安全に扱う。
        if name.count > 140 { name = String(name.prefix(140)) }

        var ext = (name as NSString).pathExtension.lowercased()
        let mime = response.mimeType?.lowercased() ?? ""
        guard Self.supportedExtensions.contains(ext)
                || mime.hasPrefix("video/") || mime.hasPrefix("audio/") else {
            return nil
        }

        if !Self.supportedExtensions.contains(ext) {
            let preferred = UTType(mimeType: mime)?.preferredFilenameExtension?.lowercased()
            ext = preferred.flatMap { Self.supportedExtensions.contains($0) ? $0 : nil }
                ?? (mime.hasPrefix("audio/") ? "m4a" : "mp4")
            name = ((name as NSString).deletingPathExtension.isEmpty ? "video" : (name as NSString).deletingPathExtension) + "." + ext
        }

        let stem = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }

    /// 動画ファイルそのもののURL（.mp4等）を保存。動画視聴ページのURLは対象外。
    func downloadDirect(_ rawURL: String) async {
        guard !isDownloading else { return }
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            message = "https:// から始まる動画ファイルのURLを入力してください。"
            return
        }
        isDownloading = true
        message = "動画ファイルをダウンロードしています…"
        defer { isDownloading = false }

        do {
            let (temporaryFile, response) = try await URLSession.shared.download(from: url)
            defer { try? fileManager.removeItem(at: temporaryFile) }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                message = "ダウンロード先のサーバーがファイルを返しませんでした。"
                return
            }
            guard let destination = destination(for: response.suggestedFilename ?? url.lastPathComponent, response: response) else {
                message = "動画・音声ファイルではありません。視聴ページではなく、サイトが提供するダウンロードリンクを使ってください。"
                return
            }
            try fileManager.moveItem(at: temporaryFile, to: destination)
            refresh()
            message = "✅ \(destination.lastPathComponent) をiPhoneに保存しました。"
        } catch {
            message = "ダウンロードに失敗しました：\(error.localizedDescription)"
        }
    }
}
