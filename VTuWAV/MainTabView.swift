import SwiftUI
import AVKit

struct MainTabView: View {
    @StateObject private var store = DownloadStore()

    var body: some View {
        TabView {
            NavigationStack {
                InAppBrowserView(store: store)
            }
            .tabItem { Label("ダウンロード", systemImage: "arrow.down.circle") }

            NavigationStack {
                DownloadLibraryView(store: store)
            }
            .tabItem { Label("ライブラリ", systemImage: "folder") }

            ContentView()
                .tabItem { Label("WAV変換", systemImage: "waveform") }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DownloadLibraryView: View {
    @ObservedObject var store: DownloadStore
    @State private var playerURL: URL?
    @State private var wavURL: URL?
    @State private var converting = false

    var body: some View {
        List {
            Section {
                if store.files.isEmpty {
                    Text("保存済みの動画・音声はまだありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.files, id: \.self) { file in
                        VStack(alignment: .leading, spacing: 9) {
                            Label(file.lastPathComponent, systemImage: "play.rectangle")
                                .lineLimit(2)
                            HStack {
                                Button("再生") { playerURL = file }
                                ShareLink(item: file) {
                                    Label("共有", systemImage: "square.and.arrow.up")
                                }
                                Button("WAV変換") { Task { await convert(file) } }
                                    .disabled(converting)
                                Button(role: .destructive) { store.delete(file) } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 5)
                    }
                }
            } header: {
                Text("このiPhone内 / VTuWAV / Downloads")
            }

            if converting {
                Section { ProgressView("WAVを作成しています…") }
            }

            if let wavURL {
                Section("変換結果") {
                    ShareLink(item: wavURL) {
                        Label("\(wavURL.lastPathComponent) を保存・共有", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if !store.message.isEmpty {
                Section { Text(store.message).font(.footnote) }
            }
        }
        .navigationTitle("ライブラリ")
        .toolbar {
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
        }
        .onAppear { store.refresh() }
        .sheet(isPresented: Binding(
            get: { playerURL != nil },
            set: { if !$0 { playerURL = nil } }
        )) {
            if let playerURL {
                NavigationStack {
                    VideoPlayer(player: AVPlayer(url: playerURL))
                        .navigationTitle(playerURL.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            Button("閉じる") { self.playerURL = nil }
                        }
                }
            }
        }
    }

    @MainActor
    private func convert(_ file: URL) async {
        guard !converting else { return }
        converting = true
        wavURL = nil
        store.message = "音声をWAVに変換しています…"
        defer { converting = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await WAVConverter.convert(file)
            }.value
            wavURL = result
            store.message = "✅ WAV変換が完了しました。"
        } catch {
            store.message = "変換できませんでした：\(error.localizedDescription)"
        }
    }
}
