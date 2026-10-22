import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var stagedInput: URL?
    @State private var sourceName = "ファイルを選択してください"
    @State private var outputURL: URL?
    @State private var message = ""

    private let background = Color(red: 0.055, green: 0.048, blue: 0.12)
    private let surface = Color(red: 0.12, green: 0.11, blue: 0.22)
    private let accent = Color(red: 0.52, green: 0.86, blue: 0.94)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background.ignoresSafeArea()
                ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    HStack(spacing: 15) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 64, height: 64)
                            .background(surface, in: RoundedRectangle(cornerRadius: 17))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("VTuWAV")
                                .font(.system(size: 33, weight: .heavy, design: .rounded))
                            Text("Audio to WAV")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Text("音楽と動画から、音声をWAVへ。")
                        .font(.title3.bold())
                    Text("iPhoneの『ファイル』に保存した、DRM保護のない音声・動画を読み込みます。")
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 15) {
                        Label("1  音声・動画を読み込む", systemImage: "doc.badge.plus")
                            .font(.headline)
                        Text(sourceName)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            isImporting = true
                        } label: {
                            Label("ファイルを選ぶ", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                    }
                    .panel(surface)

                    VStack(alignment: .leading, spacing: 15) {
                        Label("2  WAVに変換", systemImage: "waveform")
                            .font(.headline)
                        Text("16-bit PCM ・ 元ファイルのサンプルレートを維持")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            Task { await convertSelectedFile() }
                        } label: {
                            HStack {
                                if isWorking { ProgressView().tint(background) }
                                Text(isWorking ? "変換しています…" : "WAVを書き出す")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .disabled(stagedInput == nil || isWorking)
                    }
                    .panel(surface)

                    if !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let outputURL {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("3  保存・共有", systemImage: "square.and.arrow.up")
                                .font(.headline)
                            Text(outputURL.lastPathComponent)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.8))
                            ShareLink(item: outputURL) {
                                Label("ファイルに保存 / VTuRECに共有", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                        }
                        .panel(surface)
                    }

                    Text("Apple Musicサブスクの保護曲はWAV抽出できません。YouTube URLの直接ダウンロード機能も搭載していません。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .top)
                }
            }
        }
        .foregroundStyle(.white)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url):
                sourceName = url.lastPathComponent
                message = "読み込み中…"
                outputURL = nil
                isWorking = true
                Task {
                    do {
                        let localURL = try await Task.detached(priority: .userInitiated) {
                            try FileStaging.copyToSandbox(from: url)
                        }.value
                        if let old = stagedInput { try? FileManager.default.removeItem(at: old) }
                        stagedInput = localURL
                        message = "✅ 読み込み完了。WAVに変換できます。"
                    } catch {
                        stagedInput = nil
                        message = "❌ 読み込み失敗：\(error.localizedDescription)"
                    }
                    isWorking = false
                }
            case .failure(let error):
                message = "ファイルの選択に失敗しました：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func convertSelectedFile() async {
        guard let stagedInput else { return }
        isWorking = true
        outputURL = nil
        message = "音声を処理しています…"
        do {
            let wavURL = try await Task.detached(priority: .userInitiated) {
                try await WAVConverter.convert(stagedInput)
            }.value
            outputURL = wavURL
            message = "✅ WAVが完成しました。共有ボタンから保存してください。"
        } catch {
            message = "❌ \(error.localizedDescription)"
        }
        isWorking = false
    }
}

private extension View {
    func panel(_ color: Color) -> some View {
        padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 20))
    }
}
